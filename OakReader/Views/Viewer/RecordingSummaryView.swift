import SwiftUI

/// Displays AI-generated meeting summary (highlights + action items) below the transcript.
struct RecordingSummaryView: View {
    let itemStorageKey: String
    let attachmentStorageKey: String
    let transcript: String

    @State private var summary: RecordingSummaryService.MeetingSummary?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary {
                summaryContent(summary)
            } else if isGenerating {

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating summary...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    generateSummary()
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .onAppear { loadPersistedSummary() }
    }

    private func loadPersistedSummary() {
        let url = CatalogDatabase.attachmentSummaryURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attachmentStorageKey
        )
        guard let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(RecordingSummaryService.MeetingSummary.self, from: data) else {
            return
        }
        summary = persisted
    }

    @ViewBuilder
    private func summaryContent(_ summary: RecordingSummaryService.MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Highlights
            if !summary.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Highlights", systemImage: "star")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(summary.highlights, id: \.self) { highlight in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\u{2022}")
                                .foregroundStyle(.secondary)
                            Text(highlight)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Action items
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Action Items", systemImage: "checklist")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(summary.actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "square")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    generateSummary()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    copySummary(summary)
                } label: {
                    Label("Copy", systemImage: "square.on.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    private func generateSummary() {
        isGenerating = true
        errorMessage = nil

        Task {
            let service = RecordingSummaryService()
            do {
                let result = try await service.generateSummary(transcript: transcript)

                // Persist summary
                let url = CatalogDatabase.attachmentSummaryURL(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attachmentStorageKey
                )
                let data = try JSONEncoder().encode(result)
                try data.write(to: url, options: .atomic)

                summary = result
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func copySummary(_ summary: RecordingSummaryService.MeetingSummary) {
        var text = ""
        if !summary.highlights.isEmpty {
            text += "Highlights:\n"
            for h in summary.highlights {
                text += "- \(h)\n"
            }
        }
        if !summary.actionItems.isEmpty {
            if !text.isEmpty { text += "\n" }
            text += "Action Items:\n"
            for item in summary.actionItems {
                text += "- [ ] \(item)\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
