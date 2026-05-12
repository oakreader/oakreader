import SwiftUI

/// Slack-like "meeting ended" dialog shown after a detected meeting concludes.
struct PostMeetingDialogView: View {
    let session: MeetingDetectionService.MeetingSession
    let recordedItem: LibraryItem?
    let onSaveAndTranscribe: () -> Void
    let onSaveOnly: () -> Void
    let onDismiss: () -> Void

    @State private var autoTranscribe = Preferences.shared.autoTranscribeAfterMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text("Meeting Ended")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Meeting info
            VStack(alignment: .leading, spacing: 6) {
                Text(session.appName)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 12) {
                    Label(formatTimeRange(), systemImage: "clock")
                    Label(formatDuration(), systemImage: "timer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if recordedItem != nil {
                // Recording was captured
                Toggle("Auto-transcribe after meetings", isOn: $autoTranscribe)
                    .font(.caption)
                    .onChange(of: autoTranscribe) { _, newValue in
                        Preferences.shared.autoTranscribeAfterMeeting = newValue
                    }

                HStack(spacing: 8) {
                    Button("Save & Transcribe", action: onSaveAndTranscribe)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                    Button("Save Only", action: onSaveOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            } else {
                // Meeting detected but not recorded
                Text("This meeting was not recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func formatTimeRange() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: session.startedAt)) – \(formatter.string(from: session.endedAt))"
    }

    private func formatDuration() -> String {
        let total = Int(session.duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }
}
