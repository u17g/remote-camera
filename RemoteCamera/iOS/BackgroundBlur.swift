#if os(iOS)
import CoreImage
import CoreMedia
import Synchronization
import Vision

/// Blurs the background behind people, on top of whatever Cinematic mode has done: Vision finds
/// the people in each frame and everything else is blurred as hard as asked. There is no depth
/// here, only a person mask, so it works on people and nothing else.
///
/// Used from the capture queue only, apart from `strength`.
final class BackgroundBlur: @unchecked Sendable {
    /// At full strength the blur's radius is this share of the frame's short side, so a 1080p and
    /// a 4K frame look alike.
    private static let maxSigma = 0.04
    /// The background is blurred at this short side and scaled back up: once blurred, a small
    /// copy is as good as a full one, and far cheaper.
    private static let workingSize = 480.0

    private let strengthStore = Mutex(0.0)
    // Everything below: capture queue.
    /// No colour management: the frames go back into the same video format they came from, and
    /// a round trip through another colour space would only shift them.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    /// A sequence handler lets the segmentation keep the mask steady from one frame to the next.
    private let sequence = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var mask: CIImage?
    private var framesSinceMask = 0
    private var pool: CVPixelBufferPool?
    private var poolShape: (width: Int, height: Int, format: OSType)?

    /// 0 is off, 1 the strongest. May be set from any queue.
    var strength: Double {
        get { strengthStore.withLock { $0 } }
        set { strengthStore.withLock { $0 = newValue } }
    }

    var isActive: Bool {
        strength > 0
    }

    /// The frame with its background blurred, left lazy for the preview encoder to render small.
    func blurred(_ pixelBuffer: CVPixelBuffer) -> CIImage {
        blur(CIImage(cvPixelBuffer: pixelBuffer), mask: freshMask(for: pixelBuffer))
    }

    /// The frame with its background blurred, rendered in full into a buffer shaped like the
    /// original, for the recorder. Every other frame reuses the last mask: a person does not move
    /// far in a thirtieth of a second, and it halves the cost.
    func render(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        framesSinceMask += 1
        let mask = framesSinceMask >= 2 || self.mask == nil ? freshMask(for: pixelBuffer) : self.mask
        guard let output = makeBuffer(like: pixelBuffer) else { return nil }
        CVBufferPropagateAttachments(pixelBuffer, output)
        context.render(blur(CIImage(cvPixelBuffer: pixelBuffer), mask: mask), to: output)
        return output
    }

    private func blur(_ image: CIImage, mask: CIImage?) -> CIImage {
        let strength = self.strength
        guard strength > 0, let mask else { return image }
        let extent = image.extent
        let shortSide = min(extent.width, extent.height)
        let scale = min(1, Self.workingSize / shortSide)
        let background = image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingGaussianBlur(sigma: strength * Self.maxSigma * shortSide * scale)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
        // The mask is small and not quite the frame's shape; stretching it to fit is how Vision
        // means it to be used. A touch of blur keeps the edge of the person from looking cut out.
        let fittedMask = mask
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: mask.extent)
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: fittedMask,
        ])
    }

    /// The frames come upright (the capture connection turns them), which is how the
    /// segmentation expects people to stand.
    private func freshMask(for pixelBuffer: CVPixelBuffer) -> CIImage? {
        framesSinceMask = 0
        do {
            try sequence.perform([request], on: pixelBuffer, orientation: .up)
            if let result = request.results?.first?.pixelBuffer {
                mask = CIImage(cvPixelBuffer: result)
            }
        } catch {
            Log.camera.error("Person segmentation failed: \(error)")
        }
        return mask
    }

    private func makeBuffer(like source: CVPixelBuffer) -> CVPixelBuffer? {
        let shape = (width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source), format: CVPixelBufferGetPixelFormatType(source))
        if poolShape.map({ $0 != shape }) ?? true {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: shape.width,
                kCVPixelBufferHeightKey as String: shape.height,
                kCVPixelBufferPixelFormatTypeKey as String: shape.format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolShape = shape
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}

extension CMSampleBuffer {
    /// The same moment with a different picture: for handing a processed frame to the recorder.
    func replacingImageBuffer(_ imageBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let format = try? CMVideoFormatDescription(imageBuffer: imageBuffer),
              let timing = try? sampleTimingInfo(at: 0)
        else { return nil }
        return try? CMSampleBuffer(imageBuffer: imageBuffer, formatDescription: format, sampleTiming: timing)
    }
}
#endif
