#if os(iOS) && targetEnvironment(simulator)
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import Synchronization

/// The Simulator has no camera. This stands in for one — moving stripes with a clock on them and a
/// short tick every second — so that everything between the phone and the Mac (discovery,
/// approval, preview, sound, commands) can be worked on without a phone.
final class TestPattern: @unchecked Sendable {
    private static let sampleRate = 48_000.0

    private let queue = DispatchQueue(label: "remotecamera.testpattern")
    private let context = CIContext()
    /// Zoom widens the stripes. Blur stands in for Cinematic mode: the stripes are the
    /// background, the clock the subject. Mirroring flips the lot, clock included.
    private let appearance = Mutex((zoom: 1.0, backgroundBlur: 0.0, isMirrored: false))
    // queue
    private var timer: DispatchSourceTimer?
    private var startTime = 0.0
    private var samplesSent = 0

    func start(preview: PreviewEncoder, streamer: MediaStreamer) {
        queue.async { [self] in
            guard timer == nil else { return }
            startTime = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [self] in
                let elapsed = CACurrentMediaTime() - startTime
                preview.offer { image(at: elapsed) }
                sendAudio(upTo: elapsed, to: streamer)
            }
            timer.resume()
            self.timer = timer
        }
    }

    func snapshot() -> Data? {
        let image = image(at: CACurrentMediaTime() - startTime)
        return context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    func setAppearance(zoom: Double, backgroundBlur: Double, isMirrored: Bool) {
        appearance.withLock { $0 = (zoom, backgroundBlur, isMirrored) }
    }

    private func image(at time: Double) -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let (zoom, backgroundBlur, isMirrored) = appearance.withLock { $0 }
        let stripes = CIFilter.stripesGenerator()
        stripes.center = CGPoint(x: time * 160 * zoom, y: 0)
        stripes.width = Float(80 * zoom)
        stripes.sharpness = 0.9
        stripes.color0 = CIColor(red: 0.12, green: 0.38, blue: 0.9)
        stripes.color1 = CIColor(red: 0.95, green: 0.95, blue: 0.95)

        let clock = CIFilter.textImageGenerator()
        clock.text = Date.now.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1))) + "  " + zoomLabel(zoom)
        clock.fontName = "Menlo-Bold"
        clock.fontSize = 72
        clock.scaleFactor = 1
        let label = (clock.outputImage ?? CIImage.empty())
            .applyingFilter("CIColorInvert")
            .transformed(by: CGAffineTransform(translationX: 40, y: 40))

        let background = (stripes.outputImage ?? CIImage(color: .gray))
            .applyingGaussianBlur(sigma: backgroundBlur)
        let image = label
            .composited(over: CIImage(color: .black).cropped(to: label.extent.insetBy(dx: -16, dy: -8)))
            .composited(over: background.cropped(to: frame))
            .cropped(to: frame)
        return isMirrored ? image.oriented(.upMirrored) : image
    }

    /// Everything from the last call up to `elapsed`: silence, but for a 1 kHz tick at the top of
    /// each second.
    private func sendAudio(upTo elapsed: Double, to streamer: MediaStreamer) {
        let target = Int(elapsed * Self.sampleRate)
        guard target > samplesSent else { return }
        let samples = (samplesSent..<target).map { index -> Int16 in
            let time = Double(index) / Self.sampleRate
            guard time.truncatingRemainder(dividingBy: 1) < 0.05 else { return 0 }
            return Int16(sin(2 * .pi * 1000 * time) * 0.2 * Double(Int16.max))
        }
        samplesSent = target
        streamer.sendAudio(AudioChunk(sampleRate: Self.sampleRate, samples: samples.withUnsafeBytes { Data($0) }))
    }
}
#endif
