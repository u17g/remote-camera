import Foundation
import Network
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "RemoteCamera"
    static let net = Logger(subsystem: subsystem, category: "net")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let audio = Logger(subsystem: subsystem, category: "audio")
}

extension NWParameters {
    /// TCP with Nagle off (a preview frame should leave now, not with the next one), keepalives so a
    /// peer that walked away is noticed within seconds, and peer-to-peer Wi-Fi so the two devices
    /// find each other even without a shared access point.
    static var remoteCamera: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// One framed, two-way link between the camera and the controller.
///
/// Events arrive on the connection's own serial queue; every mutable property here is touched only
/// from that queue, which is what makes the `@unchecked Sendable` honest. `send` may be called
/// from anywhere.
final class PeerConnection: @unchecked Sendable {
    enum Event: Sendable {
        case ready
        case frame(Frame)
        /// Delivered exactly once, whoever hung up. Nothing follows it.
        case closed(NWError?)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "remotecamera.peer", qos: .userInitiated)
    private var parser = FrameParser()
    private var handler: (@Sendable (Event) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: .remoteCamera))
    }

    func start(_ handler: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            self.handler = handler
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: queue)
        }
    }

    func send(_ frame: Frame, completion: (@Sendable (NWError?) -> Void)? = nil) {
        connection.send(content: frame.encoded, completion: .contentProcessed { error in completion?(error) })
    }

    func send(_ message: ControlMessage) {
        do {
            send(try Frame(message))
        } catch {
            Log.net.error("Could not encode \(String(describing: message)): \(error)")
        }
    }

    /// Sends a last word and hangs up once it is on its way.
    func close(with message: ControlMessage) {
        guard let frame = try? Frame(message) else { return cancel() }
        send(frame) { [weak self] _ in self?.cancel() }
    }

    func cancel() {
        queue.async { [self] in finish(nil) }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            handler?(.ready)
            receive()
        case .waiting(let error), .failed(let error):
            // `waiting` means the peer cannot be reached right now. Retrying is the owner's call,
            // made with a fresh connection, so treat it as the end of this one.
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, handler != nil else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try parser.append(data) {
                        handler?(.frame(frame))
                    }
                } catch {
                    Log.net.error("Corrupt stream from peer; hanging up")
                    return finish(nil)
                }
            }
            if isComplete || error != nil {
                return finish(error)
            }
            receive()
        }
    }

    private func finish(_ error: NWError?) {
        guard let handler else { return }
        self.handler = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        handler(.closed(error))
    }
}
