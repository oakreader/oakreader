import SwiftUI
import OakReaderAI

struct ToolCallCardView: View {
    let record: ToolUseRecord
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    // Tool icon
                    Image(systemName: toolIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(toolColor)
                        .frame(width: 16, height: 16)

                    // Tool name
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    // File path
                    if let path = record.filePath {
                        Text(abbreviatedPath(path))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    // Status indicator
                    statusView

                    // Expand chevron (hidden when awaiting confirmation)
                    if record.status != .pending {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Confirmation buttons
            if record.status == .pending {
                Divider()
                    .padding(.horizontal, 8)

                HStack(spacing: 8) {
                    Button {
                        onApprove?()
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    Button {
                        onDeny?()
                    } label: {
                        Label("Deny", systemImage: "xmark.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            // Expanded result
            if isExpanded, let result = record.result {
                Divider()
                    .padding(.horizontal, 8)

                ScrollView {
                    Text(truncatedResult(result))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(record.isError ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        switch record.status {
        case .pending:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .executing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .completed:
            Image(systemName: record.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(record.isError ? .red : .green)
        case .denied:
            HStack(spacing: 3) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                Text("Denied")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Display Helpers

    private var toolIcon: String {
        switch record.name {
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        default: return "wrench"
        }
    }

    private var toolColor: Color {
        switch record.name {
        case "read_file": return .blue
        case "write_file": return .orange
        default: return .secondary
        }
    }

    private var displayName: String {
        switch record.name {
        case "read_file": return "Read"
        case "write_file": return "Write"
        default: return record.name
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return path
        }
        return ".../" + components.suffix(2).joined(separator: "/")
    }

    private func truncatedResult(_ text: String) -> String {
        if text.count > 2000 {
            return String(text.prefix(2000)) + "\n[Truncated]"
        }
        return text
    }
}
