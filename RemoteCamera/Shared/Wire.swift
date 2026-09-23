import Foundation

/// What the iPhone (the camera) and the Mac (the controller) say to each other.
///
/// Every message is one frame on a TCP stream: a 4-byte big-endian length, a kind byte, then the
/// payload. The length covers the kind byte and the payload.
enum Wire {
    static let serviceType = "_remotecam._tcp"
    /// Bump whenever a change to the messages below would confuse an older build on the other end.
    static let protocolVersion = 5
    /// Far above any real frame (a preview JPEG is tens of KB); anything larger means a corrupt stream.
    static let maxFrameLength = 8 * 1024 * 1024
}

enum FrameKind: UInt8, Sendable {
    /// A JSON-encoded `ControlMessage`.
    case control = 1
    /// One JPEG preview image, camera to controller.
    case video = 2
    /// One `AudioChunk`, camera to controller.
    case audio = 3
}

struct Frame: Sendable {
    let kind: FrameKind
    let payload: Data

    init(kind: FrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }

    init(_ message: ControlMessage) throws {
        self.init(kind: .control, payload: try JSONEncoder().encode(message))
    }

    func controlMessage() throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: payload)
    }

    var encoded: Data {
        var data = Data(capacity: 5 + payload.count)
        withUnsafeBytes(of: UInt32(1 + payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(kind.rawValue)
        data.append(payload)
        return data
    }
}

/// Cuts a byte stream back into frames. Bytes arrive in whatever pieces TCP delivers them.
struct FrameParser {
    struct CorruptStream: Error {}

    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Wire.maxFrameLength else { throw CorruptStream() }
            guard buffer.count >= 4 + length else { break }
            let end = start + 4 + length
            // A kind this build does not know comes from a newer peer; skip it rather than hang up.
            if let kind = FrameKind(rawValue: buffer[start + 4]) {
                frames.append(Frame(kind: kind, payload: buffer.subdata(in: start + 5..<end)))
            }
            buffer.removeSubrange(start..<end)
        }
        return frames
    }
}

/// Microphone audio for the controller to listen to: mono, 16-bit, little-endian PCM.
/// On the wire: the sample rate as a big-endian UInt32, then the samples.
struct AudioChunk: Sendable {
    let sampleRate: Double
    let samples: Data

    init(sampleRate: Double, samples: Data) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    init?(payload: Data) {
        guard payload.count >= 4 else { return nil }
        let start = payload.startIndex
        let rate = payload[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
        guard rate > 0 else { return nil }
        sampleRate = Double(rate)
        samples = payload.subdata(in: start + 4..<payload.endIndex)
    }

    var payload: Data {
        var data = Data(capacity: 4 + samples.count)
        withUnsafeBytes(of: UInt32(sampleRate).bigEndian) { data.append(contentsOf: $0) }
        data.append(samples)
        return data
    }
}

// MARK: - Control messages

enum CaptureMode: String, Codable, Sendable {
    case photo
    case video
}

enum CameraPosition: String, Codable, Sendable {
    case back
    case front
}

enum VideoResolution: String, Codable, Sendable, CaseIterable {
    case hd1080 = "1080p"
    case uhd4K = "4K"
}

/// Everything the controller needs to draw its controls. The camera sends the whole thing whenever
/// any of it changes.
struct CameraStatus: Codable, Sendable, Equatable {
    /// The camera is running and will act on commands.
    var isAvailable = false
    /// Why it is not, or anything else the person at the controller should know.
    var problem: String?
    var mode: CaptureMode = .photo
    /// The sides the iPhone has a camera on.
    var positions: [CameraPosition] = []
    var position: CameraPosition = .back
    /// Flipped left to right, in the preview and in what is saved alike. Each side remembers its
    /// own; the front starts mirrored, as a selfie view does.
    var isMirrored = false
    /// Used in Video mode. Kept while in Photo mode.
    var resolution: VideoResolution = .hd1080
    /// What the current camera can record at.
    var supportedResolutions: [VideoResolution] = []
    /// Cinematic mode: a simulated shallow depth of field, as in the Camera app, that blurs the
    /// background of videos. Needs iOS 26 and an iPhone with Cinematic mode, and only exists in
    /// Video mode.
    var canUseCinematic = false
    /// Chosen by the controller; takes effect in Video mode.
    var isCinematic = false
    /// The simulated f-number. Smaller blurs the background more.
    var aperture = 0.0
    var minAperture = 0.0
    var maxAperture = 0.0
    var hasAudio = false
    /// False when the iPhone's Photos access is off: shots would be taken and then lost.
    var canSaveToPhotos = true
    var isRecording = false
    /// By the iPhone's clock. Apple devices keep theirs within a fraction of a second of each other,
    /// which is all a recording timer needs.
    var recordingStartedAt: Date?
    /// Zoom factors as the Camera app shows them: 0.5 is the ultra wide, 1 the main camera. The
    /// zoom is continuous over the whole range; the iPhone moves between lenses as it crosses
    /// them, and zooms digitally in between.
    var zoom = 1.0
    var minZoom = 1.0
    var maxZoom = 1.0
    /// Where each lens starts (0.5, 1, 5 on a 16 Pro), for buttons that jump straight to one.
    var zoomPresets: [Double] = []

    var isCinematicActive: Bool {
        canUseCinematic && isCinematic && mode == .video
    }

    /// "Back · 4K", "Back · Cinematic f/2.8 · 1080p", "Front · Mirrored · Photo": the setup in a
    /// few words.
    var summary: String? {
        guard isAvailable else { return nil }
        let side = position == .front ? "Front" : "Back"
        let parts = isCinematicActive
            ? [side, "Cinematic \(fNumber(aperture))", resolution.rawValue]
            : [side, mode == .video ? resolution.rawValue : "Photo"]
        return (isMirrored ? [parts[0], "Mirrored"] + parts.dropFirst() : parts).joined(separator: " · ")
    }
}

/// "f/2.8", "f/16".
func fNumber(_ aperture: Double) -> String {
    "f/" + aperture.formatted(.number.precision(.fractionLength(0...1)))
}

/// "0.5×", "1×", "1.2×": the way the Camera app writes zoom factors.
func zoomLabel(_ zoom: Double) -> String {
    zoom.formatted(.number.precision(.fractionLength(0...1))) + "×"
}

enum Command: Codable, Sendable {
    case takePhoto
    case startRecording
    case stopRecording
    case setMode(CaptureMode)
    case setResolution(VideoResolution)
    case setPosition(CameraPosition)
    /// Flips the current side's picture left to right, preview and saved photos and videos alike.
    case setMirrored(Bool)
    case setCinematic(Bool)
    /// The simulated f-number for Cinematic mode.
    case setAperture(Double)
    case setZoom(Double)
}

enum CameraEvent: Codable, Sendable {
    case photoSaved
    case videoSaved(duration: TimeInterval)
    case failed(String)
}

enum ControlMessage: Codable, Sendable {
    // Controller to camera.
    case hello(clientID: String, name: String, version: Int)
    case command(Command)
    // Camera to controller.
    case welcome(deviceName: String)
    case rejected(reason: String)
    case status(CameraStatus)
    case event(CameraEvent)
}

/// A short message to show over the preview for a few seconds.
struct Notice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let isError: Bool

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    init(_ event: CameraEvent) {
        switch event {
        case .photoSaved:
            self.init("Photo saved to Photos")
        case .videoSaved(let duration):
            let length = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
            self.init("Video saved to Photos (\(length))")
        case .failed(let reason):
            self.init(reason, isError: true)
        }
    }
}
