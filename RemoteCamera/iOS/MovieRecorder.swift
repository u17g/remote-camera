#if os(iOS)
import AVFoundation

/// Writes the camera's sample buffers to a QuickTime movie in a temporary file.
///
/// Used only from the capture queue, except for `finish`'s completion, which only reads.
final class MovieRecorder: @unchecked Sendable {
    struct NothingRecorded: LocalizedError {
        var errorDescription: String? { "Nothing was recorded." }
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var firstVideoTime: CMTime?
    private var lastVideoTime = CMTime.zero

    /// The sample buffers must come upright and mirrored as they should be seen: the movie carries
    /// no rotation of its own.
    init(videoSettings: [String: Any], audioSettings: [String: Any]?) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.add(videoInput)

        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            audioInput = writer.canAdd(input) ? input : nil
            if let audioInput { writer.add(audioInput) }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard writer.status == .writing else { return }
        let time = sampleBuffer.presentationTimeStamp
        if firstVideoTime == nil {
            // Start at the first picture, so the movie does not open on black.
            writer.startSession(atSourceTime: time)
            firstVideoTime = time
        }
        if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
            lastVideoTime = time
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard writer.status == .writing, firstVideoTime != nil,
              let audioInput, audioInput.isReadyForMoreMediaData
        else { return }
        audioInput.append(sampleBuffer)
    }

    /// Closes the movie. `completion` gets its file and length; on failure the file is already gone.
    func finish(_ completion: @escaping @Sendable (Result<(url: URL, duration: TimeInterval), Error>) -> Void) {
        guard let firstVideoTime, writer.status == .writing else {
            let error = writer.error ?? NothingRecorded()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            return completion(.failure(error))
        }
        let duration = (lastVideoTime - firstVideoTime).seconds
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                completion(.success((url, duration)))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(writer.error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }
}
#endif
