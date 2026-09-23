#if os(macOS)
import Foundation

/// Files the photos and videos the iPhone sends into the captures folder.
///
/// One per connection, used only from that connection's queue; hence `@unchecked Sendable`.
final class CaptureReceiver: @unchecked Sendable {
    struct Progress: Sendable {
        let file: CapturedFile
        let received: Int64
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private struct Incoming {
        let file: CapturedFile
        let partialURL: URL
        let handle: FileHandle
        var received: Int64 = 0
        var reported: Int64 = 0
    }

    /// Progress is reported every this many bytes, not for every chunk.
    private static let reportInterval: Int64 = 2 * 1024 * 1024

    private let folder: URL
    private var incoming: Incoming?

    init(folder: URL) {
        self.folder = folder
    }

    func start(_ file: CapturedFile) throws {
        cancel()
        let partialURL = FileManager.default.temporaryDirectory.appending(path: "\(file.id.uuidString).partial")
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw Failure(errorDescription: "Could not create a file to receive into.")
        }
        incoming = Incoming(file: file, partialURL: partialURL, handle: try FileHandle(forWritingTo: partialURL))
    }

    func append(_ chunk: FileChunk) throws -> Progress? {
        guard var incoming, incoming.file.id == chunk.id else { return nil }
        guard incoming.received + Int64(chunk.data.count) <= incoming.file.size else {
            cancel()
            throw Failure(errorDescription: "The iPhone sent more than it said it would.")
        }
        try incoming.handle.write(contentsOf: chunk.data)
        incoming.received += Int64(chunk.data.count)
        let isDue = incoming.received - incoming.reported >= Self.reportInterval
        if isDue { incoming.reported = incoming.received }
        self.incoming = incoming
        return isDue ? Progress(file: incoming.file, received: incoming.received) : nil
    }

    /// Moves the finished file into the folder, under a name no other file there has.
    func finish(_ id: UUID) throws -> (url: URL, file: CapturedFile) {
        guard let incoming, incoming.file.id == id else {
            throw Failure(errorDescription: "A file arrived that was never announced.")
        }
        self.incoming = nil
        try? incoming.handle.close()
        guard incoming.received == incoming.file.size else {
            try? FileManager.default.removeItem(at: incoming.partialURL)
            throw Failure(errorDescription: "The file arrived incomplete.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = availableURL(for: incoming.file.name)
        try FileManager.default.moveItem(at: incoming.partialURL, to: destination)
        let dates: [FileAttributeKey: Any] = [.creationDate: incoming.file.createdAt, .modificationDate: incoming.file.createdAt]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: destination.path)
        return (destination, incoming.file)
    }

    /// Drops a transfer cut short, and its partial file.
    func cancel() {
        guard let incoming else { return }
        self.incoming = nil
        try? incoming.handle.close()
        try? FileManager.default.removeItem(at: incoming.partialURL)
    }

    /// `name` comes from the other device. Only its last path component is used, and never in a
    /// form that would hide the file or step out of the folder.
    private func availableURL(for name: String) -> URL {
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(lastComponent.drop { $0 == "." }).replacingOccurrences(of: ":", with: "-")
        let safeName = cleaned.isEmpty ? "Capture" : cleaned
        let stem = (safeName as NSString).deletingPathExtension
        let pathExtension = (safeName as NSString).pathExtension
        var candidate = folder.appending(path: safeName)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: pathExtension.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(pathExtension)")
            number += 1
        }
        return candidate
    }
}
#endif
