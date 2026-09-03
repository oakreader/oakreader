import SwiftUI
import OakAgent

/// Compact sticky bar shown between messages and input when a tool call
/// is awaiting user confirmation. Replaces inline Approve/Deny buttons
/// in ``ToolCallCardView``.
struct ToolConfirmationBar: View {
    let confirmation: PendingConfirmation
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: categoryIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(categoryColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(toolDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let path = confirmation.toolCall.input["path"] {
                    Text(abbreviatedPath(path))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                onDeny()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Color.red.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Deny")

            Button {
                onApprove()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Color.green.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Approve")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(categoryColor.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, OakStyle.Spacing.sm)
    }

    // MARK: - Helpers

    private var categoryIcon: String {
        switch confirmation.category {
        case .readOnly: return "eye"
        case .write: return "square.and.pencil"
        case .dangerous: return "exclamationmark.triangle"
        }
    }

    private var categoryColor: Color {
        switch confirmation.category {
        case .readOnly: return .blue
        case .write: return .orange
        case .dangerous: return .red
        }
    }

    private var toolDisplayName: String {
        switch confirmation.toolCall.name {
        case "read": return "Read File"
        case "write": return "Write File"
        case "edit": return "Edit File"
        case "bash": return "Run Command"
        case "read_document": return "Read Document"
        case "search_document": return "Search Document"
        default: return confirmation.toolCall.name
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return path
        }
        return ".../" + components.suffix(2).joined(separator: "/")
    }
}
