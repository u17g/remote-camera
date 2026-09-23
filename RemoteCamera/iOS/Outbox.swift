#if os(iOS)
import Foundation
import Network

/// Photos and videos on their way to the Mac. They are in the iPhone's photo library already; this
/// is only the delivery, kept on disk so that a shot taken while no Mac is connected still arrives
/// when one connects. A copy here is deleted once the Mac says it has saved it.
///
/// Everything happens on one serial queue.
final class Outbox: @unchecked Sendable {
    /// Undelivered files beyond this are dropped, oldest first. They are still in Photos.
    private static let sizeLimit: Int64 = 2 * 1024 * 1024 * 1024
    private static let chunkSize = 256 * 1024
    /// Chunks handed to the connection and not yet sent: enough to keep the link busy, few enough
    /// that a preview frame never waits behind more than a moment of file.
    private static let window = 3

    private struct Transfer {
        let file: CapturedFile
        let url: URL
        let handle: FileHandle
        var inFlight = 0
        /// Everything is sent; waiting for the Mac to confirm.
        var isSent = false
    }

    private let queue = DispatchQueue(label: "remotecamera.outbox", qos: .utility)
    private let directory: URL
    // queue
    private var peer: PeerConnection?
    private var transfer: Transfer?

    init() {
        var directory = URL.applicationSupportDirectory.appending(path: "Outbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        self.directory = directory
    }

    /// The Mac to deliver to, or nil. A transfer cut short starts over with the next Mac.
    func attach(_ peer: PeerConnection?) {
        queue.async { [self] in
            try? transfer?.handle.close()
            transfer = nil
            self.peer = peer
            sendNext()
        }
    }

    /// Moves the file at `url` into the outbox.
    func add(movingFileAt url: URL) {
        queue.async { [self] in
            let destination = directory.appending(path: "\(UUID().uuidString).\(url.pathExtension.lowercased())")
            do {
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                Log.net.error("Could not queue \(url.lastPathComponent) for the Mac: \(error)")
                try? FileManager.default.removeItem(at: url)
                return
            }
            added()
        }
    }

    func add(_ data: Data, fileExtension: String) {
        queue.async { [self] in
            do {
                try data.write(to: directory.appending(path: "\(UUID().uuidString).\(fileExtension)"))
            } catch {
                Log.net.error("Could not queue a photo for the Mac: \(error)")
                return
            }
            added()
        }
    }

    func delivered(_ id: UUID) {
        queue.async { [self] in
            guard let transfer, transfer.file.id == id else { return }
            try? transfer.handle.close()
            try? FileManager.default.removeItem(at: transfer.url)
            self.transfer = nil
            sendNext()
        }
    }

    private func added() {
        trim()
        sendNext()
    }

    private func sendNext() {
        guard let peer, transfer == nil, let next = pending().first else { return }
        do {
            transfer = Transfer(file: next.file, url: next.url, handle: try FileHandle(forReadingFrom: next.url))
        } catch {
            Log.net.error("Could not read \(next.url.lastPathComponent); dropping it: \(error)")
            try? FileManager.default.removeItem(at: next.url)
            return sendNext()
        }
        peer.send(.fileStart(next.file))
        pump()
    }

    /// Keeps up to `window` chunks on their way. The end marker can follow the last chunk at once:
    /// the connection delivers in order.
    private func pump() {
        guard let peer, var transfer, !transfer.isSent else { return }
        defer { self.transfer = transfer }
        while transfer.inFlight < Self.window {
            let chunk: Data
            do {
                chunk = try transfer.handle.read(upToCount: Self.chunkSize) ?? Data()
            } catch {
                Log.net.error("Could not read \(transfer.url.lastPathComponent): \(error)")
                chunk = Data()
            }
            if chunk.isEmpty {
                transfer.isSent = true
                peer.send(.fileEnd(id: transfer.file.id))
                return
            }
            transfer.inFlight += 1
            let id = transfer.file.id
            peer.send(Frame(kind: .fileChunk, payload: FileChunk(id: id, data: chunk).payload)) { [weak self] error in
                guard let self else { return }
                queue.async { self.chunkSent(of: id, error: error) }
            }
        }
    }

    private func chunkSent(of id: UUID, error: NWError?) {
        guard transfer?.file.id == id else { return }
        transfer?.inFlight -= 1
        // A failed send means the connection is going; `attach` will reset everything.
        if error == nil { pump() }
    }

    /// Oldest first.
    private func pending() -> [(url: URL, file: CapturedFile)] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls
            .compactMap { url -> (url: URL, file: CapturedFile)? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let values = try? url.resourceValues(forKeys: Set(keys))
                else { return nil }
                let createdAt = values.creationDate ?? .now
                let kind: CapturedFile.Kind = url.pathExtension == "mov" ? .video : .photo
                let stamp = createdAt.formatted(.verbatim(
                    "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                    timeZone: .current,
                    calendar: .current
                ))
                let name = "\(kind == .video ? "Video" : "Photo") \(stamp).\(url.pathExtension)"
                return (url, CapturedFile(id: id, name: name, kind: kind, size: Int64(values.fileSize ?? 0), createdAt: createdAt))
            }
            .sorted { $0.file.createdAt < $1.file.createdAt }
    }

    /// Drops the oldest files over `sizeLimit`, but never the newest one or the one being sent: a
    /// single long 4K take can be bigger than the limit on its own.
    private func trim() {
        var files = pending()
        var total = files.reduce(0) { $0 + $1.file.size }
        while total > Self.sizeLimit, files.count > 1, let oldest = files.first, oldest.url != transfer?.url {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.file.size
            files.removeFirst()
        }
    }
}
#endif
