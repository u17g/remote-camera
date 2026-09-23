#if os(macOS)
import SwiftUI

/// The remote: the iPhones on the network on the left, the chosen one's picture and controls on
/// the right.
struct ControllerView: View {
    @State private var model = ControllerModel()

    var body: some View {
        NavigationSplitView {
            CameraList(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                PreviewPane(model: model)
                Divider()
                ControlBar(model: model)
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                if model.selectedCamera != nil {
                    Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() }
                        .help("Disconnect from this iPhone")
                }
            }
        }
        .task { model.start() }
    }

    private var title: String {
        switch model.link {
        case .idle: "Remote Camera"
        case .connecting(let name), .awaitingApproval(let name), .connected(let name): name
        }
    }

    private var subtitle: String {
        model.status?.summary ?? ""
    }
}

private struct CameraList: View {
    let model: ControllerModel

    var body: some View {
        List(selection: Binding(get: { model.selectedCamera }, set: { model.select($0) })) {
            Section("iPhones") {
                ForEach(model.cameras) { camera in
                    Label(camera.name, systemImage: "iphone")
                        .tag(camera.name)
                }
            }
        }
        .overlay {
            if model.cameras.isEmpty {
                ContentUnavailableView(
                    "No iPhone Found",
                    systemImage: "iphone.slash",
                    description: Text(model.browseProblem ?? "Open Remote Camera on your iPhone, on the same Wi-Fi as this Mac.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .connected = model.link, let status = model.status {
                CameraSettings(model: model, status: status)
            }
        }
    }
}

/// Which camera, mirrored or not, how far to zoom, what to record at, and how much to blur the
/// background. Only the zoom can change mid-recording: the movie being written has one size and
/// one source, but the iPhone moves between lenses without a break.
private struct CameraSettings: View {
    let model: ControllerModel
    let status: CameraStatus

    var body: some View {
        let isLocked = !model.isReady || status.isRecording
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            setting("Camera") {
                if status.positions.count > 1 {
                    Picker("Camera", selection: Binding(get: { status.position }, set: { model.setPosition($0) })) {
                        Text("Back").tag(CameraPosition.back)
                        Text("Front").tag(CameraPosition.front)
                    }
                }
                HStack {
                    Text("Mirror")
                    Spacer()
                    Toggle("Mirror", isOn: Binding(get: { status.isMirrored }, set: { model.setMirrored($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .help("Flip the picture left to right: the preview, and the photos and videos saved on the iPhone")
            }
            .disabled(isLocked)
            setting("Zoom") {
                ZoomControl(model: model, status: status)
            }
            .disabled(!model.isReady)
            if !status.supportedResolutions.isEmpty {
                setting("Video Resolution") {
                    Picker("Video Resolution", selection: Binding(get: { status.resolution }, set: { model.setResolution($0) })) {
                        ForEach(status.supportedResolutions, id: \.self) { resolution in
                            Text(resolution.rawValue).tag(resolution)
                        }
                    }
                }
                .disabled(isLocked)
            }
            if status.mode == .video, status.canUseCinematic {
                setting("Background Blur") {
                    HStack {
                        Text("Cinematic")
                        Spacer()
                        Toggle("Cinematic", isOn: Binding(get: { status.isCinematic }, set: { model.setCinematic($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if status.isCinematic, status.maxAperture > status.minAperture {
                        ApertureSlider(model: model, range: status.minAperture...status.maxAperture)
                    }
                }
                .disabled(isLocked)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding([.horizontal, .bottom])
    }

    private func setting(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            control()
        }
    }
}

/// The simulated f-number. Like a real lens, a lower number means a shallower depth of field.
private struct ApertureSlider: View {
    let model: ControllerModel
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                // Logarithmic, as f-stops are: f/2 to f/4 is as big a step as f/8 to f/16.
                Slider(
                    value: Binding(get: { log(min(max(model.aperture, range.lowerBound), range.upperBound)) }, set: { model.setAperture(exp($0)) }),
                    in: log(range.lowerBound)...log(range.upperBound)
                )
                Text(fNumber(model.aperture))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("More blur")
                Spacer()
                Text("Less blur")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.trailing, 48)
        }
        .help("Lower f-numbers blur the background more")
    }
}

private struct PreviewPane: View {
    let model: ControllerModel

    var body: some View {
        ZStack {
            Color.black
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .keyframeAnimator(initialValue: 0.0, trigger: model.shutterCount) { content, flash in
                        content.overlay(Color.white.opacity(flash))
                    } keyframes: { _ in
                        LinearKeyframe(0.8, duration: 0.04)
                        LinearKeyframe(0, duration: 0.3)
                    }
            } else {
                placeholder
                    .foregroundStyle(.white.opacity(0.7))
            }
            VStack(spacing: 10) {
                if let startedAt = model.status?.recordingStartedAt {
                    RecordingBadge(startedAt: startedAt)
                }
                Spacer()
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                if let notice = model.notice {
                    NoticeBanner(notice: notice) { model.clearNotice($0) }
                }
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.link {
        case .idle:
            Text(model.cameras.isEmpty ? "Waiting for an iPhone running Remote Camera…" : "Pick an iPhone on the left.")
        case .connecting(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(name)…")
            }
        case .awaitingApproval(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Tap Allow on \(name).")
            }
        case .connected:
            ProgressView()
        }
    }

    private var warnings: [String] {
        guard let status = model.status else { return [] }
        return [
            status.problem,
            status.canSaveToPhotos ? nil : "Photos access is off on the iPhone, so nothing can be saved.",
        ].compactMap(\.self)
    }
}

private struct ControlBar: View {
    @Bindable var model: ControllerModel

    var body: some View {
        let status = model.status
        let isRecording = status?.isRecording == true
        HStack(spacing: 16) {
            HStack {
                Picker("Mode", selection: Binding(get: { status?.mode ?? .photo }, set: { model.setMode($0) })) {
                    Text("Photo").tag(CaptureMode.photo)
                    Text("Video").tag(CaptureMode.video)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!model.isReady || isRecording)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            ShutterButton(mode: status?.mode ?? .photo, isRecording: isRecording) { model.shutter() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.isReady)

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Toggle("Listen", systemImage: model.isListening ? "speaker.wave.2.fill" : "speaker.slash.fill", isOn: $model.isListening)
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help(model.isListening ? "Stop listening to the iPhone’s microphone" : "Listen to the iPhone’s microphone")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.primary.opacity(0.8), lineWidth: 3)
                RoundedRectangle(cornerRadius: isRecording ? 5 : 20)
                    .fill(mode == .video ? Color.red : Color.primary)
                    .frame(width: isRecording ? 20 : 40, height: isRecording ? 20 : 40)
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isRecording)
        .help(mode == .photo ? "Take a photo (Space)" : isRecording ? "Stop recording (Space)" : "Start recording (Space)")
    }
}

/// One continuous zoom, as in the Camera app: a button to jump to each lens, and a slider and a
/// stepper for everything in between, in tenths.
private struct ZoomControl: View {
    let model: ControllerModel
    let status: CameraStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.zoomPresets.count > 1 {
                HStack(spacing: 6) {
                    ForEach(status.zoomPresets, id: \.self) { preset in
                        LensButton(label: zoomLabel(preset), isCurrent: preset == currentLens) {
                            model.setZoom(preset)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                // Logarithmic, so that 1× to 2× gets as much room as 10× to 20×.
                Slider(
                    value: Binding(get: { log(min(max(model.zoom, status.minZoom), status.maxZoom)) }, set: { model.setZoom(exp($0)) }),
                    in: log(status.minZoom)...log(max(status.maxZoom, status.minZoom * 1.01))
                )
                Text(zoomLabel(model.zoom))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                Stepper("Zoom", onIncrement: { model.setZoom(model.zoom + 0.1) }, onDecrement: { model.setZoom(model.zoom - 0.1) })
                    .help("Zoom in or out by 0.1×")
            }
        }
    }

    /// The lens the zoom is on: the last one that starts at or below it. 1.2× is the main lens,
    /// zoomed digitally.
    private var currentLens: Double? {
        status.zoomPresets.last { $0 <= model.zoom + 0.001 }
    }
}

private struct LensButton: View {
    let label: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospacedDigit().weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
