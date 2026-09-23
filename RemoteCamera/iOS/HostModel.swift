#if os(iOS)
import Network
import Observation
import UIKit

/// The iPhone side: runs the camera, advertises it on the local network, and takes orders from
/// one Mac at a time.
///
/// A Mac has to be allowed on the phone once before it can see or control anything; after that it
/// is remembered and reconnects without asking.
@MainActor @Observable
final class HostModel {
    struct ApprovalRequest: Identifiable {
        let id = UUID()
        let clientID: String
        let name: String
        let peer: PeerConnection
    }

    let camera = CameraService()
    private(set) var status = CameraStatus()
    private(set) var controllerName: String?
    private(set) var approvalRequest: ApprovalRequest?
    private(set) var notice: Notice?
    private(set) var networkProblem: String?

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var controller: PeerConnection?
    /// Connections that have not been accepted yet, held here so they stay alive until they are.
    @ObservationIgnored private var pending: [ObjectIdentifier: PeerConnection] = [:]
    @ObservationIgnored private var trustedClients = Set(UserDefaults.standard.stringArray(forKey: HostModel.trustedClientsKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(trustedClients), forKey: Self.trustedClientsKey) }
    }

    private static let trustedClientsKey = "trustedClients"

    /// Launching with `-RemoteCameraDebugAutoApprove YES` skips the prompt, so the app can be
    /// driven from a script. Debug builds only.
    private static var approvesEveryone: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "RemoteCameraDebugAutoApprove")
        #else
        false
        #endif
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        camera.onStatusChange = { [weak self] in
            Task { @MainActor in self?.cameraStatusChanged() }
        }
        camera.onEvent = { [weak self] event in
            Task { @MainActor in self?.cameraReported(event) }
        }
        camera.start()
        startListening()
    }

    func answerApproval(allow: Bool) {
        guard let request = approvalRequest else { return }
        approvalRequest = nil
        if allow {
            trustedClients.insert(request.clientID)
            makeController(request.peer, name: request.name)
        } else {
            pending[ObjectIdentifier(request.peer)] = nil
            request.peer.close(with: .rejected(reason: "Declined on the iPhone."))
        }
    }

    func disconnectController() {
        controller?.close(with: .rejected(reason: "Disconnected on the iPhone."))
    }

    func forgetTrustedMacs() {
        trustedClients = []
    }

    func stopRecording() {
        camera.perform(.stopRecording)
    }

    func clearNotice(_ id: Notice.ID) {
        if notice?.id == id { notice = nil }
    }

    // MARK: - Network

    private func startListening() {
        let listener: NWListener
        do {
            listener = try NWListener(using: .remoteCamera)
        } catch {
            networkProblem = "Cannot listen on the network: \(error.localizedDescription)"
            return
        }
        listener.service = NWListener.Service(name: UIDevice.current.name, type: Wire.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            networkProblem = nil
        case .waiting(let error):
            networkProblem = "Not visible to the Mac yet: \(error.localizedDescription). Is Local Network access on for Remote Camera?"
        case .failed(let error):
            // Happens when the app was suspended for a while; a fresh listener usually works.
            Log.net.error("Listener failed: \(error)")
            networkProblem = "Not visible to the Mac: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                if listener == nil { startListening() }
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = PeerConnection(connection: connection)
        pending[ObjectIdentifier(peer)] = peer
        // The handler holds the peer until it closes, and closing drops the handler.
        peer.start { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, from: peer) }
            }
        }
    }

    private func handle(_ event: PeerConnection.Event, from peer: PeerConnection) {
        switch event {
        case .ready:
            break
        case .frame(let frame):
            guard frame.kind == .control, let message = try? frame.controlMessage() else { return }
            received(message, from: peer)
        case .closed:
            pending[ObjectIdentifier(peer)] = nil
            if approvalRequest?.peer === peer {
                approvalRequest = nil
            }
            if controller === peer {
                // A recording carries on: a Wi-Fi hiccup should not end the take. The Mac sees it
                // still running when it reconnects, and it can be stopped from the phone too.
                controller = nil
                controllerName = nil
                camera.streamer.attach(nil)
                camera.outbox.attach(nil)
            }
        }
    }

    private func received(_ message: ControlMessage, from peer: PeerConnection) {
        switch message {
        case let .hello(clientID, name, version):
            if version != Wire.protocolVersion {
                pending[ObjectIdentifier(peer)] = nil
                peer.close(with: .rejected(reason: "The Mac and the iPhone run different versions of Remote Camera. Update both."))
            } else if trustedClients.contains(clientID) || Self.approvesEveryone {
                makeController(peer, name: name)
            } else if approvalRequest == nil {
                approvalRequest = ApprovalRequest(clientID: clientID, name: name, peer: peer)
            } else {
                pending[ObjectIdentifier(peer)] = nil
                peer.close(with: .rejected(reason: "The iPhone is already asking about another Mac."))
            }
        case .command(let command):
            guard peer === controller else { return }
            camera.perform(command)
        case .fileReceived(let id):
            guard peer === controller else { return }
            camera.outbox.delivered(id)
        case .welcome, .rejected, .status, .event, .fileStart, .fileEnd:
            break
        }
    }

    private func makeController(_ peer: PeerConnection, name: String) {
        pending[ObjectIdentifier(peer)] = nil
        if let previous = controller, previous !== peer {
            previous.close(with: .rejected(reason: "Another Mac took over the camera."))
        }
        controller = peer
        controllerName = name
        peer.send(.welcome(deviceName: UIDevice.current.name))
        peer.send(.status(status))
        camera.streamer.attach(peer)
        // Whatever was shot while no Mac was connected goes now.
        camera.outbox.attach(peer)
    }

    // MARK: - Camera

    private func cameraStatusChanged() {
        let latest = camera.status
        guard latest != status else { return }
        status = latest
        controller?.send(.status(latest))
    }

    private func cameraReported(_ event: CameraEvent) {
        notice = Notice(event)
        controller?.send(.event(event))
    }
}
#endif
