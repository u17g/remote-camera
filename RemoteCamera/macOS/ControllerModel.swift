#if os(macOS)
import Foundation
import ImageIO
import Network
import Observation
import SystemConfiguration

/// The Mac side: finds iPhones running Remote Camera, connects to the one picked, shows what it
/// sees and plays what it hears, and sends it commands.
@MainActor @Observable
final class ControllerModel {
    struct Camera: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum Link: Equatable {
        case idle
        case connecting(String)
        /// Connected, and waiting for the iPhone to say yes; the first time, a person has to.
        case awaitingApproval(String)
        case connected(String)
    }

    private(set) var cameras: [Camera] = []
    private(set) var browseProblem: String?
    private(set) var link: Link = .idle
    private(set) var status: CameraStatus?
    private(set) var preview: CGImage?
    private(set) var notice: Notice?
    /// Bumped for every photo, to flash the preview.
    private(set) var shutterCount = 0
    /// These two follow their sliders while they move; the camera's own values take over once
    /// they settle, so a status sent mid-drag does not yank the knob back.
    private(set) var zoom = 1.0
    private(set) var aperture = 0.0
    /// The camera the user picked. Remembered across launches, and reconnected to whenever it is
    /// on the network and we are not connected to it.
    private(set) var selectedCamera = UserDefaults.standard.string(forKey: ControllerModel.selectedCameraKey) {
        didSet { UserDefaults.standard.set(selectedCamera, forKey: Self.selectedCameraKey) }
    }
    var isListening = UserDefaults.standard.object(forKey: ControllerModel.isListeningKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isListening, forKey: Self.isListeningKey)
            audio.setMuted(!isListening)
        }
    }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var peer: PeerConnection?
    @ObservationIgnored private let audio = AudioMonitor()
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var zoomEditedAt = Date.distantPast
    @ObservationIgnored private var apertureEditedAt = Date.distantPast
    /// Who we are to the iPhone, which remembers the Macs it has allowed by this.
    @ObservationIgnored private let clientID: String = {
        if let id = UserDefaults.standard.string(forKey: ControllerModel.clientIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: ControllerModel.clientIDKey)
        return id
    }()

    private static let selectedCameraKey = "selectedCamera"
    private static let isListeningKey = "isListening"
    private static let clientIDKey = "clientID"

    var isReady: Bool {
        guard case .connected = link else { return false }
        return status?.isAvailable == true
    }

    func start() {
        guard browser == nil else { return }
        audio.setMuted(!isListening)
        let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: .remoteCamera)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserChanged(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func select(_ name: String?) {
        guard name != selectedCamera else { return }
        selectedCamera = name
        dropConnection()
        connectIfNeeded()
    }

    func disconnect() {
        select(nil)
    }

    // MARK: - Commands

    func shutter() {
        guard isReady, let status else { return }
        switch status.mode {
        case .photo:
            shutterCount += 1
            send(.takePhoto)
        case .video:
            send(status.isRecording ? .stopRecording : .startRecording)
        }
    }

    func setMode(_ mode: CaptureMode) {
        send(.setMode(mode))
    }

    func setResolution(_ resolution: VideoResolution) {
        send(.setResolution(resolution))
    }

    func setPosition(_ position: CameraPosition) {
        send(.setPosition(position))
    }

    func setMirrored(_ isOn: Bool) {
        send(.setMirrored(isOn))
    }

    func setCinematic(_ isOn: Bool) {
        send(.setCinematic(isOn))
    }

    func setAperture(_ aperture: Double) {
        self.aperture = aperture
        apertureEditedAt = .now
        send(.setAperture(aperture))
    }

    func setZoom(_ zoom: Double) {
        // In tenths, as the Camera app shows it: 1.2×, not 1.2371×.
        var zoom = (zoom * 10).rounded() / 10
        if let status {
            zoom = min(max(zoom, status.minZoom), status.maxZoom)
        }
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        zoomEditedAt = .now
        send(.setZoom(zoom))
    }

    func clearNotice(_ id: Notice.ID) {
        if notice?.id == id { notice = nil }
    }

    private func send(_ command: Command) {
        guard case .connected = link else { return }
        peer?.send(.command(command))
    }

    // MARK: - Discovery

    private func update(_ results: Set<NWBrowser.Result>) {
        cameras = results
            .compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Camera(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        connectIfNeeded()
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            browseProblem = nil
        case .waiting(let error):
            browseProblem = "Cannot look for iPhones (\(error.localizedDescription)). Allow Remote Camera under System Settings › Privacy & Security › Local Network."
        case .failed(let error):
            Log.net.error("Browser failed: \(error)")
            browseProblem = "Cannot look for iPhones: \(error.localizedDescription)"
            browser?.cancel()
            browser = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                start()
            }
        default:
            break
        }
    }

    // MARK: - Connection

    private func connectIfNeeded() {
        guard peer == nil,
              let name = selectedCamera,
              let camera = cameras.first(where: { $0.name == name })
        else { return }
        connect(to: camera)
    }

    private func connect(to camera: Camera) {
        reconnect?.cancel()
        let peer = PeerConnection(endpoint: camera.endpoint)
        self.peer = peer
        link = .connecting(camera.name)
        let audio = self.audio
        peer.start { [weak self] event in
            // Media is decoded here, off the main thread. Only finished pictures and control
            // traffic go to the main actor.
            if case .frame(let frame) = event {
                switch frame.kind {
                case .video:
                    guard let image = decodeImage(frame.payload) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.show(image, from: peer) }
                    }
                    return
                case .audio:
                    if let chunk = AudioChunk(payload: frame.payload) { audio.play(chunk) }
                    return
                case .control:
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, from: peer) }
            }
        }
        // A phone that vanished without saying goodbye still shows up for a while, and connecting
        // to it just hangs. Give up and try again later.
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard self.peer === peer, case .connecting = link else { return }
            dropConnection()
            scheduleReconnect()
        }
    }

    private func handle(_ event: PeerConnection.Event, from peer: PeerConnection) {
        guard peer === self.peer else { return }
        switch event {
        case .ready:
            if case .connecting(let name) = link { link = .awaitingApproval(name) }
            peer.send(.hello(clientID: clientID, name: Self.computerName, version: Wire.protocolVersion))
        case .frame(let frame):
            guard let message = try? frame.controlMessage() else { return }
            received(message)
        case .closed(let error):
            if let error { Log.net.info("Connection closed: \(error)") }
            dropConnection()
            // The phone may have gone to the background or switched networks; it will be back.
            scheduleReconnect()
        }
    }

    private func received(_ message: ControlMessage) {
        switch message {
        case .welcome:
            if case .awaitingApproval(let name) = link { link = .connected(name) }
        case .rejected(let reason):
            notice = Notice(reason, isError: true)
            // Do not keep asking on our own; picking the camera again asks again.
            selectedCamera = nil
            dropConnection()
        case .status(let status):
            self.status = status
            if Date.now.timeIntervalSince(zoomEditedAt) > 0.5 {
                zoom = status.zoom
            }
            if Date.now.timeIntervalSince(apertureEditedAt) > 0.5 {
                aperture = status.aperture
            }
        case .event(let event):
            notice = Notice(event)
        case .hello, .command:
            break
        }
    }

    private func show(_ image: CGImage, from peer: PeerConnection) {
        guard peer === self.peer else { return }
        preview = image
    }

    private func dropConnection() {
        reconnect?.cancel()
        peer?.cancel()
        peer = nil
        link = .idle
        status = nil
        preview = nil
        audio.stop()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        reconnect = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            connectIfNeeded()
        }
    }

    /// The name people gave this Mac, as the iPhone will show it when asking to allow it.
    private static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}

/// Decodes right away, on the calling queue, rather than lazily at first draw on the main thread.
private func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}
#endif
