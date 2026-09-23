import SwiftUI

/// "REC 01:23", counting up from when the iPhone started recording.
struct RecordingBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }
}

/// A notice that clears itself after a few seconds.
struct NoticeBanner: View {
    let notice: Notice
    let dismiss: (Notice.ID) -> Void

    var body: some View {
        Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((notice.isError ? Color.red : Color.black).opacity(0.7), in: Capsule())
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(notice.isError ? 5 : 3))
                if !Task.isCancelled { dismiss(notice.id) }
            }
    }
}
