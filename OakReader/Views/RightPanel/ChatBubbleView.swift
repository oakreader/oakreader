import SwiftUI
import OakReaderAI
import Textual

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
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                    }

                    // Inline attachments for user messages
                    if turn.role == .user && !turn.attachments.isEmpty {
                        FannedAttachmentStack(attachments: turn.attachments)
                    }

                    // Message content
                    messageBubble

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

                    // Copy button — always visible after response is done
                    if !turn.isStreaming && turn.role == .assistant {
                        Button(action: copyContent) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }
                }

                if turn.role == .assistant { Spacer(minLength: 40) }
            }
            .clipped()
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
    }

    @ViewBuilder
    private var messageBubble: some View {
        let base = StructuredText(markdown: turn.content, syntaxExtensions: [.math])
            .textual.headingStyle(ChatHeadingStyle())
            .textual.textSelection(.enabled)
            .font(.system(size: 15))

        if turn.role == .assistant {
            base
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bubbleColor)
                )
                .foregroundStyle(Color(nsColor: .labelColor))
        } else {
            base
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bubbleColor)
                )
                .foregroundStyle(Color(nsColor: .labelColor))
        }
    }

    private var bubbleColor: Color {
        switch turn.role {
        case .user:
            return Color.accentColor.opacity(0.15)
        case .assistant, .system:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.content, forType: .string)
    }
}

// MARK: - Compact heading style for chat bubbles

private struct ChatHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.3, 1.15, 1.05, 1.0, 0.9, 0.85]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        let scale = Self.fontScales[level - 1]

        configuration.label
            .textual.fontScale(scale)
            .textual.lineSpacing(.fontScaled(0.1))
            .textual.blockSpacing(.fontScaled(top: 0.6, bottom: 0.3))
            .fontWeight(.semibold)
    }
}
