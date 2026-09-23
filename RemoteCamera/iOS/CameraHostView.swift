#if os(iOS)
import AVFoundation
import SwiftUI

/// What the iPhone shows while it is being a camera: its own preview, who is in control, and the
/// prompt to allow a new Mac.
struct CameraHostView: View {
    @State private var model = HostModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.camera.session, isMirrored: model.status.isMirrored)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        linkBadge
                        if let summary = model.status.summary {
                            Text(summary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                    }
                    Spacer()
                    menu
                }
                if let startedAt = model.status.recordingStartedAt {
                    RecordingBadge(startedAt: startedAt)
                }
                Spacer()
                problems
                if let notice = model.notice {
                    NoticeBanner(notice: notice) { model.clearNotice($0) }
                }
                if model.status.isRecording {
                    Button("Stop Recording", systemImage: "stop.fill") { model.stopRecording() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .padding()
        }
        .alert(
            "Allow this Mac?",
            isPresented: Binding(get: { model.approvalRequest != nil }, set: { _ in }),
            presenting: model.approvalRequest
        ) { _ in
            Button("Allow") { model.answerApproval(allow: true) }
            Button("Don’t Allow", role: .cancel) { model.answerApproval(allow: false) }
        } message: { request in
            Text("“\(request.name)” wants to see through this camera, hear its microphone, and take photos and videos.")
        }
        .task { model.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // A camera on a tripod must not go to sleep.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var linkBadge: some View {
        let (text, color): (String, Color) = if let name = model.controllerName {
            ("Controlled by \(name)", .green)
        } else if let request = model.approvalRequest {
            ("\(request.name) is asking to connect", .orange)
        } else {
            ("Waiting for a Mac…", .gray)
        }
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var menu: some View {
        Menu {
            if model.controllerName != nil {
                Button("Disconnect Mac", systemImage: "xmark.circle") { model.disconnectController() }
            }
            Button("Forget Allowed Macs", systemImage: "trash", role: .destructive) { model.forgetTrustedMacs() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.55), in: Circle())
        }
    }

    @ViewBuilder
    private var problems: some View {
        let messages = [
            model.status.problem,
            model.networkProblem,
            model.status.canSaveToPhotos ? nil : "Photos access is off, so nothing can be saved. Turn it on in Settings › Remote Camera.",
        ].compactMap(\.self)
        ForEach(messages, id: \.self) { message in
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// The capture session's live picture. The UI is portrait-only, and a preview layer's default
/// rotation is portrait, so it needs no rotation handling of its own. Mirroring follows the
/// controller's choice rather than the layer's own habit of mirroring the front camera, so the
/// phone shows what will be saved.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        guard let connection = view.previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirrored != isMirrored {
            connection.isVideoMirrored = isMirrored
        }
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif
