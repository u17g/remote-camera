#if os(iOS)
import AVFoundation
import CoreImage
import Synchronization

/// The camera on the iPhone: runs the capture session and carries out the controller's commands.
///
/// Each piece of state belongs to one queue:
/// - `sessionQueue`: session configuration, zoom, the photo output and its in-flight captures.
/// - `captureQueue`: the video and audio data outputs deliver here, and the recorder lives here.
/// - the main queue: the rotation coordinator, which delivers its updates there.
/// `status` and `captureAngle` are read from all of them, so they sit behind locks.
///
/// Video buffers arrive already upright and, if asked, mirrored: the capture connection turns and
/// flips them. The preview and the recording can then use them as they are, and the movie needs no
/// rotation or mirroring metadata, which not every player honours.
final class CameraService: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let streamer: MediaStreamer
    /// Every photo and video also goes to the Mac, through this.
    let outbox = Outbox()

    /// Called on any queue after `status` changes. Set before `start()`.
    var onStatusChange: (@Sendable () -> Void)?
    /// Called on any queue when a photo or video is saved, or something failed. Set before `start()`.
    var onEvent: (@Sendable (CameraEvent) -> Void)?

    var status: CameraStatus {
        statusStore.withLock { $0 }
    }

    private let sessionQueue = DispatchQueue(label: "remotecamera.session")
    private let captureQueue = DispatchQueue(label: "remotecamera.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let previewEncoder: PreviewEncoder
    private let audioEncoder: AudioPreviewEncoder
    private let backgroundBlur = BackgroundBlur()
    private let statusStore = Mutex(CameraStatus())
    /// Degrees clockwise that turn the sensor's image upright, from the rotation coordinator.
    private let captureAngle = Mutex<CGFloat>(90)

    /// Everything the controller chooses about how the camera shoots. The session is rebuilt from
    /// this whenever it changes, rather than patched piece by piece.
    private struct Setup: Equatable, Sendable {
        var mode = CaptureMode.photo
        var position: CameraPosition
        var resolution = VideoResolution.hd1080
        var cinematic = false
        /// 0 until the device's default is known.
        var aperture = 0.0
        /// Per side, so that turning to the front brings back the selfie view.
        var mirrored: [CameraPosition: Bool] = [.front: true]
        var extraBlur = 0.0

        var isMirrored: Bool {
            mirrored[position] ?? false
        }

        /// What needs the session rebuilt. The aperture and the mirroring can change in place.
        var structure: Setup {
            var structure = self
            structure.aperture = 0
            structure.mirrored = [:]
            structure.extraBlur = 0
            return structure
        }
    }

    // sessionQueue
    private var videoInput: AVCaptureDeviceInput?
    private var setup: Setup?
    /// The device used on each side that has one.
    private var cameras: [CameraPosition: String] = [:]
    /// The device Cinematic mode runs on, on each side that has one.
    private var cinematicCameras: [CameraPosition: String] = [:]
    /// Display zoom per unit of the active device's `videoZoomFactor`.
    private var zoomScale = 1.0
    private var photoCaptures: [Int64: PhotoCapture] = [:]
    // captureQueue
    private var recorder: MovieRecorder?
    // main
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    #if targetEnvironment(simulator)
    private let testPattern = TestPattern()
    #endif

    override init() {
        let streamer = MediaStreamer()
        self.streamer = streamer
        previewEncoder = PreviewEncoder(streamer: streamer)
        audioEncoder = AudioPreviewEncoder(streamer: streamer)
        super.init()
    }

    func start() {
        #if targetEnvironment(simulator)
        startTestPattern()
        #else
        observeSession()
        Task {
            let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
            let audioAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            let photosAllowed = await PhotoLibrary.requestAccess()
            sessionQueue.async { [self] in
                configure(videoAllowed: videoAllowed, audioAllowed: audioAllowed, photosAllowed: photosAllowed)
            }
        }
        #endif
    }

    func perform(_ command: Command) {
        #if targetEnvironment(simulator)
        simulate(command)
        #else
        switch command {
        case .takePhoto: takePhoto()
        case .startRecording: startRecording()
        case .stopRecording: stopRecording()
        case .setMode(let mode): change { $0.mode = mode }
        case .setResolution(let resolution): change { $0.resolution = resolution }
        case .setPosition(let position): change { $0.position = position }
        case .setMirrored(let isOn): change { setup in setup.mirrored[setup.position] = isOn }
        case .setCinematic(let isOn): change { $0.cinematic = isOn }
        case .setAperture(let aperture): change { $0.aperture = aperture }
        case .setExtraBlur(let strength): setExtraBlur(strength)
        case .setZoom(let zoom): setZoom(zoom)
        }
        #endif
    }

    // MARK: - Session (sessionQueue)

    private func configure(videoAllowed: Bool, audioAllowed: Bool, photosAllowed: Bool) {
        updateStatus { $0.canSaveToPhotos = photosAllowed }
        guard videoAllowed else {
            return updateStatus { $0.problem = "Camera access is off. Turn it on in Settings › Remote Camera." }
        }
        cameras = Self.cameras()
        cinematicCameras = Self.cinematicCameras()
        let positions = [CameraPosition.back, .front].filter { cameras[$0] != nil }
        guard let initial = positions.first else {
            return updateStatus { $0.problem = "No camera is available." }
        }
        updateStatus { $0.positions = positions }

        session.beginConfiguration()
        var hasAudio = false
        if audioAllowed,
           let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(microphoneInput), session.canAddOutput(audioOutput) {
            session.addInput(microphoneInput)
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            hasAudio = true
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        session.commitConfiguration()
        updateStatus { $0.hasAudio = hasAudio }

        guard apply(Setup(position: initial)) else {
            return updateStatus { $0.problem = "The camera could not be opened." }
        }
        session.startRunning()
    }

    /// Carries out a change of setup. Nothing about it can change while recording: the movie
    /// being written has one size and one source.
    private func change(_ edit: @escaping @Sendable (inout Setup) -> Void) {
        sessionQueue.async { [self] in
            guard status.isAvailable, let current = setup else { return }
            var requested = current
            edit(&requested)
            guard requested != current else { return }
            guard !status.isRecording else { return emit(.failed("Stop recording before changing the camera setup.")) }

            if requested.structure == current.structure {
                let status = self.status
                let aperture = applyAperture(status.maxAperture > 0 ? min(max(requested.aperture, status.minAperture), status.maxAperture) : requested.aperture)
                setup?.aperture = aperture
                setup?.mirrored = requested.mirrored
                updateStatus {
                    $0.aperture = aperture
                    $0.isMirrored = requested.isMirrored
                }
                return updateVideoOrientation()
            }
            if !apply(requested) {
                emit(.failed("That camera is not available."))
            }
        }
    }

    /// Rebuilds the session to match `requested`: which device, which format, and whether the
    /// cinematic effect is on. Returns false, with the session as it was, if the camera could not
    /// be opened.
    @discardableResult
    private func apply(_ requested: Setup) -> Bool {
        var setup = requested
        let cinematicDevice = setup.mode == .video && setup.cinematic
            ? cinematicCameras[setup.position].flatMap { AVCaptureDevice(uniqueID: $0) }
            : nil
        guard let device = cinematicDevice ?? cameras[setup.position].flatMap({ AVCaptureDevice(uniqueID: $0) }) else { return false }
        let previousDevice = videoInput?.device

        // Not every camera records in 4K (the front one on older phones, say): drop to 1080p
        // rather than refuse.
        let resolutions = Self.resolutions(of: device, cinematic: cinematicDevice != nil)
        if !resolutions.contains(setup.resolution), let fallback = resolutions.first {
            setup.resolution = fallback
        }
        let apertures = Self.apertureRange(ofDeviceWithID: cinematicCameras[setup.position], resolution: setup.resolution)
        if apertures.max > 0 {
            setup.aperture = setup.aperture == 0 ? apertures.standard : min(max(setup.aperture, apertures.min), apertures.max)
        }

        let input: AVCaptureDeviceInput
        if let current = videoInput, current.device == device {
            input = current
        } else if let opened = try? AVCaptureDeviceInput(device: device) {
            input = opened
        } else {
            return false
        }

        session.beginConfiguration()
        if #available(iOS 26.0, *), cinematicDevice == nil, input.isCinematicVideoCaptureEnabled {
            input.isCinematicVideoCaptureEnabled = false
        }
        if input !== videoInput {
            if let current = videoInput { session.removeInput(current) }
            guard session.canAddInput(input) else {
                if let current = videoInput { session.addInput(current) }
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            videoInput = input
        }
        if cinematicDevice != nil, #available(iOS 26.0, *), let format = Self.cinematicFormat(of: device, resolution: setup.resolution) {
            // Cinematic formats are not reachable through presets.
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            } catch {
                Log.camera.error("Could not select a cinematic format: \(error)")
            }
        } else {
            let preset = Self.preset(mode: setup.mode, resolution: setup.resolution)
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
            }
        }
        session.commitConfiguration()

        if cinematicDevice != nil {
            guard enableCinematic(on: input) else {
                // The device has cinematic formats but will not run one in this session. Carry on
                // without the effect rather than leave the camera half set up.
                emit(.failed("Cinematic mode is not available right now."))
                setup.cinematic = false
                return apply(setup)
            }
            setup.aperture = applyAperture(setup.aperture)
        }

        self.setup = setup
        // A multi-lens camera counts zoom from its widest lens, the Camera app from the main one;
        // the device says how to convert (0.5 where there is an ultra wide).
        zoomScale = Double(device.displayVideoZoomFactorMultiplier)
        let zoomFactors = Self.zoomRange(of: device, cinematic: cinematicDevice != nil)
        let zoomScale = self.zoomScale
        let zoomPresets = Self.lensZoomFactors(of: device).filter { zoomFactors.contains($0) }.map { $0 * zoomScale }
        let canUseCinematic = cinematicCameras[setup.position] != nil
        updateStatus { status in
            status.mode = setup.mode
            status.position = setup.position
            status.isMirrored = setup.isMirrored
            status.resolution = setup.resolution
            status.supportedResolutions = resolutions
            status.canUseCinematic = canUseCinematic
            status.isCinematic = setup.cinematic
            status.aperture = setup.aperture
            status.minAperture = apertures.min
            status.maxAperture = apertures.max
            status.minZoom = zoomScale * zoomFactors.lowerBound
            status.maxZoom = zoomScale * zoomFactors.upperBound
            status.zoomPresets = zoomPresets
        }
        applyExtraBlur(setup)
        outputsChanged(for: device)
        // Keep the framing when only the mode or resolution changed; another camera starts at 1×.
        applyZoom(device == previousDevice ? status.zoom : 1, on: device)
        return true
    }

    private func enableCinematic(on input: AVCaptureDeviceInput) -> Bool {
        guard #available(iOS 26.0, *), input.isCinematicVideoCaptureSupported else { return false }
        session.beginConfiguration()
        input.isCinematicVideoCaptureEnabled = true
        session.commitConfiguration()
        return input.isCinematicVideoCaptureEnabled
    }

    /// Sets the simulated aperture if the cinematic effect is running, and returns what was set.
    private func applyAperture(_ aperture: Double) -> Double {
        guard #available(iOS 26.0, *), let input = videoInput, input.isCinematicVideoCaptureEnabled else { return aperture }
        let format = input.device.activeFormat
        // Outside the format's range, or on a format that has none, the setter throws.
        guard format.minSimulatedAperture > 0 else { return aperture }
        let value = min(max(Float(aperture), format.minSimulatedAperture), format.maxSimulatedAperture)
        input.simulatedAperture = value
        return Double(value)
    }

    /// Brings the outputs up to date with the active device and format.
    private func outputsChanged(for device: AVCaptureDevice) {
        if session.outputs.contains(photoOutput), let dimensions = Self.photoDimensions(for: device.activeFormat) {
            photoOutput.maxPhotoDimensions = dimensions
        }
        updateVideoOrientation()
        let deviceID = device.uniqueID
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { observeRotation(ofDeviceWithID: deviceID) }
        }
    }

    /// Turns the video buffers upright and mirrors them if asked. Left alone while recording: the
    /// movie being written has one shape, and changing it mid-take would break the file. Catches
    /// up when the recording stops.
    private func updateVideoOrientation() {
        let status = self.status
        guard !status.isRecording, let connection = videoOutput.connection(with: .video) else { return }
        let angle = captureAngle.withLock { $0 }
        if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
        Self.mirror(connection, status.isMirrored)
    }

    /// Mirroring is about the connection's vertical axis after rotation, so on an upright picture
    /// it is the left-right flip people mean.
    private static func mirror(_ connection: AVCaptureConnection, _ isMirrored: Bool) {
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirrored != isMirrored {
            connection.isVideoMirrored = isMirrored
        }
    }

    /// Unlike the rest of the setup this can change mid-recording: it is the app's own processing,
    /// and the movie keeps its shape.
    private func setExtraBlur(_ strength: Double) {
        sessionQueue.async { [self] in
            guard var setup else { return }
            setup.extraBlur = min(max(strength, 0), 1)
            self.setup = setup
            applyExtraBlur(setup)
        }
    }

    /// Video mode only: photos do not get it, so the preview should not suggest they will.
    private func applyExtraBlur(_ setup: Setup) {
        backgroundBlur.strength = setup.mode == .video ? setup.extraBlur : 0
        updateStatus { $0.extraBlur = setup.extraBlur }
    }

    private func setZoom(_ zoom: Double) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device else { return }
            applyZoom(zoom, on: device)
        }
    }

    /// `zoom` is a display factor, as in the Camera app: 1 is the main lens, so on the 5×
    /// telephoto a device zoom factor of 2 shows as 10.
    private func applyZoom(_ zoom: Double, on device: AVCaptureDevice) {
        let status = self.status
        let factor = CGFloat(min(max(zoom, status.minZoom), status.maxZoom) / zoomScale)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Zoom failed: \(error)")
        }
        let actual = Double(device.videoZoomFactor) * zoomScale
        updateStatus { $0.zoom = actual }
    }

    private func takePhoto() {
        sessionQueue.async { [self] in
            guard status.isAvailable, let connection = photoOutput.connection(with: .video) else {
                return emit(.failed("The camera is not ready."))
            }
            let angle = captureAngle.withLock { $0 }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            Self.mirror(connection, status.isMirrored)
            let isHEIF = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            let settings = isHEIF
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            let id = settings.uniqueID
            let capture = PhotoCapture { [weak self] result in
                self?.photoFinished(id, fileExtension: isHEIF ? "heic" : "jpg", result)
            }
            photoCaptures[id] = capture
            photoOutput.capturePhoto(with: settings, delegate: capture)
        }
    }

    private func photoFinished(_ id: Int64, fileExtension: String, _ result: Result<Data, Error>) {
        sessionQueue.async { [self] in photoCaptures[id] = nil }
        let data: Data
        do {
            data = try result.get()
        } catch {
            return emit(.failed("Photo not taken: \(error.localizedDescription)"))
        }
        // To the Mac even if Photos refuses it, so the shot is not lost.
        outbox.add(data, fileExtension: fileExtension)
        Task {
            do {
                try await PhotoLibrary.savePhoto(data)
                emit(.photoSaved)
            } catch {
                emit(.failed("Photo not saved to Photos: \(error.localizedDescription)"))
            }
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVCaptureSession.didStartRunningNotification,
            AVCaptureSession.didStopRunningNotification,
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.interruptionEndedNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.refreshAvailability()
            }
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            // Usually media services were reset; the session has to be started again.
            guard let self else { return }
            sessionQueue.async { [self] in
                if !session.isRunning { session.startRunning() }
            }
        }
    }

    private func refreshAvailability() {
        let interrupted = session.isInterrupted
        let available = session.isRunning && !interrupted
        if interrupted {
            // The app went to the background, a call came in, or another app took the camera.
            // Keep what was shot so far rather than lose the take.
            stopRecording()
        }
        updateStatus {
            $0.isAvailable = available
            if available {
                $0.problem = nil
            } else if interrupted {
                $0.problem = "The camera is paused. Bring Remote Camera to the front on the iPhone."
            }
        }
    }

    // MARK: - Recording (captureQueue)

    private func startRecording() {
        captureQueue.async { [self] in
            guard recorder == nil else { return }
            let status = self.status
            guard status.isAvailable else { return }
            guard status.mode == .video else { return emit(.failed("Switch to Video to record.")) }
            guard let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) else {
                return emit(.failed("The camera is not ready to record."))
            }
            let audioSettings = status.hasAudio ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) : nil
            do {
                recorder = try MovieRecorder(videoSettings: videoSettings, audioSettings: audioSettings)
                updateStatus {
                    $0.isRecording = true
                    $0.recordingStartedAt = Date()
                }
            } catch {
                emit(.failed("Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    private func stopRecording() {
        captureQueue.async { [self] in
            guard let recorder else { return }
            self.recorder = nil
            updateStatus {
                $0.isRecording = false
                $0.recordingStartedAt = nil
            }
            // The phone may have been turned during the take.
            sessionQueue.async { [self] in updateVideoOrientation() }
            recorder.finish { [weak self] result in
                guard let self else { return }
                let movie: (url: URL, duration: TimeInterval)
                do {
                    movie = try result.get()
                } catch {
                    return emit(.failed("Video not saved: \(error.localizedDescription)"))
                }
                Task {
                    do {
                        try await PhotoLibrary.saveVideo(at: movie.url)
                        self.emit(.videoSaved(duration: movie.duration))
                    } catch {
                        self.emit(.failed("Video not saved to Photos: \(error.localizedDescription)"))
                    }
                    // Photos keeps a copy of its own; this one goes to the Mac either way.
                    self.outbox.add(movingFileAt: movie.url)
                }
            }
        }
    }

    // MARK: - Rotation (main)

    @MainActor
    private func observeRotation(ofDeviceWithID id: String) {
        guard let device = AVCaptureDevice(uniqueID: id) else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            captureAngle.withLock { $0 = angle }
            sessionQueue.async { [self] in updateVideoOrientation() }
        }
    }

    // MARK: - Status

    private func updateStatus(_ change: (inout CameraStatus) -> Void) {
        let changed = statusStore.withLock { status in
            let before = status
            change(&status)
            return status != before
        }
        if changed { onStatusChange?() }
    }

    private func emit(_ event: CameraEvent) {
        onEvent?(event)
    }

    // MARK: - Helpers

    private static let backCameraTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
    ]

    /// The camera used on each side. On the back that is the multi-lens virtual camera where the
    /// iPhone has one: like the Camera app, it moves between lenses as the zoom crosses them, so
    /// 0.5× to 25× is one continuous zoom with the best lens under every factor.
    private static func cameras() -> [CameraPosition: String] {
        let cameras: [CameraPosition: AVCaptureDevice?] = [
            .back: bestCamera(at: .back, among: backCameraTypes),
            .front: bestCamera(at: .front, among: [.builtInWideAngleCamera]),
        ]
        return cameras.compactMapValues { $0?.uniqueID }
    }

    /// The device Cinematic mode runs on, on each side, if any. It needs depth: a multi-lens
    /// camera on the back, the TrueDepth one on the front.
    private static func cinematicCameras() -> [CameraPosition: String] {
        guard #available(iOS 26.0, *) else { return [:] }
        let canFilm = { (device: AVCaptureDevice) in device.formats.contains { $0.isCinematicVideoCaptureSupported } }
        let cameras: [CameraPosition: AVCaptureDevice?] = [
            .back: bestCamera(at: .back, among: backCameraTypes, where: canFilm),
            .front: bestCamera(at: .front, among: [.builtInTrueDepthCamera, .builtInWideAngleCamera], where: canFilm),
        ]
        return cameras.compactMapValues { $0?.uniqueID }
    }

    /// The first of `types`, in that order, that the iPhone has on that side and that passes `test`.
    private static func bestCamera(
        at position: CameraPosition,
        among types: [AVCaptureDevice.DeviceType],
        where test: (AVCaptureDevice) -> Bool = { _ in true }
    ) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position == .back ? .back : .front
        ).devices
        return types.lazy.compactMap { type in devices.first { $0.deviceType == type } }.first(where: test)
    }

    /// Where each lens of a multi-lens camera takes over, in device zoom factors. One entry for a
    /// single lens.
    private static func lensZoomFactors(of device: AVCaptureDevice) -> [Double] {
        [Double(device.minAvailableVideoZoomFactor)] + device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
    }

    @available(iOS 26.0, *)
    private static func cinematicFormat(of device: AVCaptureDevice, resolution: VideoResolution) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.isCinematicVideoCaptureSupported && size.width == resolution.width && size.height == resolution.height
        }
        // 8-bit first: what the preview encoder and the recorder are built around.
        let eightBit = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        return formats.first { eightBit.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription)) } ?? formats.first
    }

    private static func resolutions(of device: AVCaptureDevice, cinematic: Bool) -> [VideoResolution] {
        if cinematic, #available(iOS 26.0, *) {
            return VideoResolution.allCases.filter { cinematicFormat(of: device, resolution: $0) != nil }
        }
        return VideoResolution.allCases.filter { device.supportsSessionPreset($0.preset) }
    }

    /// The simulated f-numbers Cinematic mode offers at that resolution; zeros where it has none.
    private static func apertureRange(ofDeviceWithID id: String?, resolution: VideoResolution) -> (min: Double, max: Double, standard: Double) {
        guard #available(iOS 26.0, *), let id, let device = AVCaptureDevice(uniqueID: id),
              let format = cinematicFormat(of: device, resolution: resolution) ?? device.formats.first(where: { $0.isCinematicVideoCaptureSupported })
        else { return (0, 0, 0) }
        return (Double(format.minSimulatedAperture), Double(format.maxSimulatedAperture), Double(format.defaultSimulatedAperture))
    }

    /// In device zoom factors.
    private static func zoomRange(of device: AVCaptureDevice, cinematic: Bool) -> ClosedRange<Double> {
        let lower = Double(device.minAvailableVideoZoomFactor)
        var upper = Double(device.maxAvailableVideoZoomFactor)
        if cinematic, #available(iOS 26.0, *) {
            // Cinematic mode only works over a limited range.
            let format = device.activeFormat
            return max(lower, Double(format.videoMinZoomFactorForCinematicVideo))...max(lower, min(upper, Double(format.videoMaxZoomFactorForCinematicVideo)))
        }
        // Beyond five times the longest lens it is all digital, and mostly mush: 25× on a 5×
        // telephoto, as in the Camera app.
        let longestLens = lensZoomFactors(of: device).last ?? 1
        upper = min(upper, longestLens * 5)
        return lower...max(lower, upper)
    }

    private static func preset(mode: CaptureMode, resolution: VideoResolution) -> AVCaptureSession.Preset {
        switch mode {
        // 4:3 at full resolution, with preview-sized video buffers.
        case .photo: .photo
        // 16:9 buffers big enough to record.
        case .video: resolution.preset
        }
    }

    /// The largest photo size up to 24 MP. Beyond that (48 MP on the Pro phones) a shot takes
    /// noticeably longer, and it is not what the Camera app takes by default either.
    private static func photoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        let sizes = format.supportedMaxPhotoDimensions.sorted { pixels($0) < pixels($1) }
        return sizes.last { pixels($0) <= 25_000_000 } ?? sizes.first
    }

    private static func pixels(_ size: CMVideoDimensions) -> Int {
        Int(size.width) * Int(size.height)
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            if !backgroundBlur.isActive {
                recorder?.appendVideo(sampleBuffer)
                previewEncoder.offer { CIImage(cvPixelBuffer: pixelBuffer) }
            } else if let recorder {
                // Every frame is blurred for the movie; the preview takes some of the same.
                let blurred = backgroundBlur.render(pixelBuffer)
                recorder.appendVideo(blurred.flatMap(sampleBuffer.replacingImageBuffer) ?? sampleBuffer)
                previewEncoder.offer { CIImage(cvPixelBuffer: blurred ?? pixelBuffer) }
            } else {
                // Not recording: only the frames the preview sends are worth blurring.
                previewEncoder.offer { backgroundBlur.blurred(pixelBuffer) }
            }
        } else if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            audioEncoder.offer(sampleBuffer)
        }
    }
}

private extension VideoResolution {
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd1080: .hd1920x1080
        case .uhd4K: .hd4K3840x2160
        }
    }

    var width: Int32 {
        switch self {
        case .hd1080: 1920
        case .uhd4K: 3840
        }
    }

    var height: Int32 {
        switch self {
        case .hd1080: 1080
        case .uhd4K: 2160
        }
    }
}

#if targetEnvironment(simulator)
extension CameraService {
    /// The Simulator has no camera; see `TestPattern`.
    private func startTestPattern() {
        updateStatus {
            $0.isAvailable = true
            $0.problem = "Simulator: no camera, streaming a test pattern"
            $0.hasAudio = true
            $0.positions = [.back, .front]
            $0.supportedResolutions = VideoResolution.allCases
            $0.canUseCinematic = true
            $0.aperture = 4.5
            $0.minAperture = 2
            $0.maxAperture = 16
        }
        simulateCamera(at: .back)
        testPattern.start(preview: previewEncoder, streamer: streamer)
        Task {
            let allowed = await PhotoLibrary.requestAccess()
            updateStatus { $0.canSaveToPhotos = allowed }
        }
    }

    private func simulate(_ command: Command) {
        switch command {
        case .setMode(let mode):
            updateStatus { $0.mode = mode }
        case .setResolution(let resolution):
            updateStatus { $0.resolution = resolution }
        case .setPosition(let position):
            simulateCamera(at: position)
        case .setMirrored(let isOn):
            updateStatus { $0.isMirrored = isOn }
        case .setCinematic(let isOn):
            updateStatus { $0.isCinematic = isOn }
        case .setAperture(let aperture):
            updateStatus { $0.aperture = min(max(aperture, $0.minAperture), $0.maxAperture) }
        case .setExtraBlur(let strength):
            updateStatus { $0.extraBlur = min(max(strength, 0), 1) }
        case .setZoom(let zoom):
            updateStatus { $0.zoom = min(max(zoom, $0.minZoom), $0.maxZoom) }
        case .takePhoto:
            // Saves a frame of the pattern, so the paths into Photos and to the Mac get exercised too.
            guard let data = testPattern.snapshot() else { return }
            outbox.add(data, fileExtension: "jpg")
            Task {
                do {
                    try await PhotoLibrary.savePhoto(data)
                    emit(.photoSaved)
                } catch {
                    emit(.failed("Photo not saved: \(error.localizedDescription)"))
                }
            }
        case .startRecording, .stopRecording:
            emit(.failed("The Simulator has no camera to do that with."))
        }
        // Stand in for Cinematic mode and the extra blur by blurring the stripes behind the clock.
        let status = self.status
        let cinematicBlur = status.isCinematicActive ? 40 / status.aperture : 0
        let extraBlur = status.mode == .video ? status.extraBlur * 30 : 0
        testPattern.setAppearance(zoom: status.zoom, backgroundBlur: cinematicBlur + extraBlur, isMirrored: status.isMirrored)
    }

    /// A 16 Pro: ultra wide, wide and a 5× telephoto on the back, one lens on the front.
    private func simulateCamera(at position: CameraPosition) {
        updateStatus {
            $0.position = position
            $0.isMirrored = position == .front
            $0.zoomPresets = position == .back ? [0.5, 1, 5] : [1]
            $0.minZoom = position == .back ? 0.5 : 1
            $0.maxZoom = position == .back ? 25 : 5
            $0.zoom = 1
        }
    }
}
#endif
#endif
