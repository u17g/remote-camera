#if os(macOS)
import AVFoundation

/// Plays the iPhone's microphone on the Mac.
///
/// The delay stays bounded: past a quarter of a second of backlog, new audio is dropped rather
/// than queued, so a network stall costs a gap instead of a lag that never goes away.
/// Everything happens on one serial queue.
final class AudioMonitor: @unchecked Sendable {
    private static let maxBacklog = 0.25
    /// Held back before playback starts, to ride over the usual jitter of Wi-Fi delivery.
    private static let startBuffer = 0.06

    private let queue = DispatchQueue(label: "remotecamera.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // queue
    private var format: AVAudioFormat?
    private var backlog: AVAudioFrameCount = 0
    /// Bumped on every reset, so completions of buffers from before it are ignored.
    private var generation = 0
    private var isMuted = false

    init() {
        engine.attach(player)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // The output device changed under us; start over with the next chunk.
            guard let self else { return }
            queue.async { self.reset() }
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            isMuted = muted
            if muted { reset() }
        }
    }

    func stop() {
        queue.async { [self] in reset() }
    }

    func play(_ chunk: AudioChunk) {
        queue.async { [self] in
            guard !isMuted else { return }
            if format?.sampleRate != chunk.sampleRate, !start(sampleRate: chunk.sampleRate) { return }
            guard let format, Double(backlog) < Self.maxBacklog * format.sampleRate else { return }

            let frames = AVAudioFrameCount(chunk.samples.count / MemoryLayout<Int16>.size)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let output = buffer.floatChannelData?[0]
            else { return }
            buffer.frameLength = frames
            chunk.samples.withUnsafeBytes { raw in
                for index in 0..<Int(frames) {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    output[index] = Float(sample) / 32768
                }
            }

            backlog += frames
            let generation = self.generation
            player.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                queue.async {
                    if self.generation == generation { self.backlog -= frames }
                }
            }
            if !player.isPlaying, Double(backlog) >= Self.startBuffer * format.sampleRate {
                player.play()
            }
        }
    }

    private func start(sampleRate: Double) -> Bool {
        reset()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Log.audio.error("Audio engine did not start: \(error)")
            return false
        }
        self.format = format
        return true
    }

    private func reset() {
        generation += 1
        player.stop()
        engine.stop()
        format = nil
        backlog = 0
    }
}
#endif
