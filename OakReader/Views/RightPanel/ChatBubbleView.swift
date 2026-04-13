import SwiftUI
import OakReaderAI

struct ChatBubbleView: View {
    let turn: ChatTurn

    @State private var isHovered = false

    var body: some View {
        if turn.role == .system { return AnyView(EmptyView()) }

        return AnyView(
            HStack(alignment: .top) {
                if turn.role == .user { Spacer(minLength: 40) }

                VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 4) {
                    // Skill badge
                    if let skill = turn.skill {
                        Text(skill)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                    }

                    // Inline attachments for user messages
                    if turn.role == .user && !turn.attachments.isEmpty {
                        ForEach(turn.attachments) { attachment in
                            attachmentView(attachment)
                        }
                    }

                    // Message content
                    Group {
                        if turn.role == .assistant {
                            markdownContent
                        } else {
                            Text(turn.content)
                        }
                    }
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(bubbleColor)
                    )
                    .foregroundStyle(turn.role == .user ? .white : Color(nsColor: .labelColor))

                    // Streaming indicator
                    if turn.isStreaming {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Generating...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Error indicator
                    if let error = turn.error {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    // Hover actions
                    if isHovered && !turn.isStreaming && turn.role == .assistant {
                        HStack(spacing: 8) {
                            Button(action: copyContent) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Copy")
                        }
                        .transition(.opacity)
                    }
                }

                if turn.role == .assistant { Spacer(minLength: 40) }
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
    }

    // MARK: - Markdown content

    @ViewBuilder
    private var markdownContent: some View {
        if let attributed = try? AttributedString(markdown: turn.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(turn.content)
        }
    }

    // MARK: - Attachment view

    @ViewBuilder
    private func attachmentView(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.type == .textSelection ? "text.quote" : "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(attachment.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var bubbleColor: Color {
        switch turn.role {
        case .user:
            return Color.accentColor
        case .assistant, .system:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.content, forType: .string)
    }
}
