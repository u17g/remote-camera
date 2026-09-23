#if os(iOS)
import AVFoundation
import CoreImage
import Synchronization

/// The one door from the capture pipeline to the network. Holds the connected controller, if any,
/// and drops media the network cannot keep up with rather than queueing it: a preview that is a
/// second behind is worse than one that skips.
final class MediaStreamer: Sendable {
    private struct State {
        var peer: PeerConnection?
        var videoInFlight = false
        var audioInFlight = 0
    }

    /// Roughly half a second of audio at the capture's usual buffer size.
    private static let maxAudioInFlight = 24

    private let state = Mutex(State())

    func attach(_ peer: PeerConnection?) {
        state.withLock { $0 = State(peer: peer) }
    }

    var isAttached: Bool {
        state.withLock { $0.peer != nil }
    }

    /// Claims the single video slot. Whoever gets `true` must follow with `sendVideo` or `releaseVideo`.
    func reserveVideo() -> Bool {
        state.withLock { state in
            guard state.peer != nil, !state.videoInFlight else { return false }
            state.videoInFlight = true
            return true
        }
    }

    func sendVideo(_ jpeg: Data) {
        guard let peer = state.withLock({ $0.peer }) else { return releaseVideo() }
        peer.send(Frame(kind: .video, payload: jpeg)) { [weak self] _ in self?.releaseVideo() }
    }

    func releaseVideo() {
        state.withLock { $0.videoInFlight = false }
    }

    func sendAudio(_ chunk: AudioChunk) {
        let peer: PeerConnection? = state.withLock { state in
            guard let peer = state.peer, state.audioInFlight < Self.maxAudioInFlight else { return nil }
            state.audioInFlight += 1
            return peer
        }
        peer?.send(Frame(kind: .audio, payload: chunk.payload)) { [weak self] _ in
            self?.state.withLock { $0.audioInFlight = max(0, $0.audioInFlight - 1) }
        }
    }
}

/// Makes the controller's preview: small JPEGs, a few a second. Encoding happens on a queue of
/// its own so that a slow frame never costs the recording one.
final class PreviewEncoder: @unchecked Sendable {
    static let framesPerSecond = 15.0
    static let maxDimension = 960.0
    static let quality = 0.5

    private let streamer: MediaStreamer
    private let queue = DispatchQueue(label: "remotecamera.preview", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Touched only by the caller of `offer`, which is always one serial queue.
    private var lastFrameTime = 0.0

    init(streamer: MediaStreamer) {
        self.streamer = streamer
    }

    /// Called for every captured frame. `makeImage` runs only for the ones that will be sent.
    func offer(_ makeImage: () -> CIImage?) {
        let now = CACurrentMediaTime()
        // 0.9: frames arrive with jitter, and a strict interval would halve the rate at 30 fps in.
        guard now - lastFrameTime >= 0.9 / Self.framesPerSecond, streamer.reserveVideo() else { return }
        guard let image = makeImage() else { return streamer.releaseVideo() }
        lastFrameTime = now
        queue.async { [self] in
            if let jpeg = encode(image) {
                streamer.sendVideo(jpeg)
            } else {
                streamer.releaseVideo()
            }
        }
    }

    private func encode(_ image: CIImage) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, Self.maxDimension / max(extent.width, extent.height))
        let size = CGRect(x: 0, y: 0, width: (extent.width * scale).rounded(.down), height: (extent.height * scale).rounded(.down))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: size)
        return context.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Self.quality]
        )
    }
}

/// Turns microphone sample buffers into `AudioChunk`s for the controller to listen to.
/// Used only from the capture queue.
final class AudioPreviewEncoder {
    private let streamer: MediaStreamer
    private var converter: AVAudioConverter?

    init(streamer: MediaStreamer) {
        self.streamer = streamer
    }

    func offer(_ sampleBuffer: CMSampleBuffer) {
        guard streamer.isAttached, let description = sampleBuffer.formatDescription else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        if converter?.inputFormat != inputFormat {
            guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: true) else { return }
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.downmix = true
        }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let converter, frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frames)
        else { return }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr,
              (try? converter.convert(to: output, from: input)) != nil,
              let samples = output.int16ChannelData?[0]
        else { return }
        streamer.sendAudio(AudioChunk(
            sampleRate: converter.outputFormat.sampleRate,
            samples: Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        ))
    }
}
#endif
