import SwiftUI
import OakAgent

struct ToolCallCardView: View {
    let record: ToolUseRecord

    @State private var isExpanded = false
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — disclosure style matching ThinkingDisclosureView
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    // Expand chevron — only shown when there's a result to disclose
                    if record.status == .completed || record.status == .denied {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    }

                    if record.isExecuting {
                        // Shimmer text while executing
                        shimmerLabel
                    } else {
                        // Static label when not executing
                        staticLabel
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            // Expanded result
            if isExpanded, let result = record.result {
                Text(truncatedResult(result))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(record.isError ? .red : .secondary.opacity(0.75))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            if record.isExecuting {
                startShimmer()
            }
        }
        .onChange(of: record.isExecuting) { _, executing in
            if executing {
                startShimmer()
            }
        }
    }

    // MARK: - Shimmer Label (executing state)

    private var shimmerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: toolIcon)
                .font(.system(size: 11, weight: .medium))
            Text(executingLabel)
                .font(OakStyle.ChatFont.messageBody)
                .fontWeight(.medium)
        }
        .foregroundStyle(.secondary)
        .overlay {
            shimmerGradient
                .mask {
                    HStack(spacing: 6) {
                        Image(systemName: toolIcon)
                            .font(.system(size: 11, weight: .medium))
                        Text(executingLabel)
                            .font(OakStyle.ChatFont.messageBody)
                            .fontWeight(.medium)
                    }
                }
        }
    }

    private var shimmerGradient: some View {
        LinearGradient(
            colors: [
                .clear,
                Color.primary.opacity(0.6),
                .clear,
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 60)
        .offset(x: shimmerPhase * 120)
        .animation(
            .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
            value: shimmerPhase
        )
    }

    private func startShimmer() {
        shimmerPhase = -1
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }
    }

    // MARK: - Static Label (completed / pending / denied)

    private var staticLabel: some View {
        HStack(spacing: 6) {
            statusIcon

            Text(completedLabel)
                .font(OakStyle.ChatFont.messageBody)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .pending:
            Image(systemName: toolIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
        case .executing:
            // Handled by shimmerLabel
            EmptyView()
        case .completed:
            Image(systemName: record.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(record.isError ? .red : .green)
        case .denied:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Display Helpers

    private var toolIcon: String {
        switch record.name {
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "bash": return "terminal"
        default: return "wrench"
        }
    }

    private var displayName: String {
        switch record.name {
        case "read_file": return "Read"
        case "write_file": return "Write"
        case "bash": return "Bash"
        default: return record.name
        }
    }

    /// Label shown while the tool is executing (e.g. "Running oak...")
    private var executingLabel: String {
        if let path = record.filePath {
            return "\(displayName) \(abbreviatedPath(path))..."
        }
        return "Running \(displayName)..."
    }

    /// Label shown after execution completes or for other states.
    private var completedLabel: String {
        switch record.status {
        case .pending:
            return "\(displayName) — awaiting approval"
        case .denied:
            return "\(displayName) — denied"
        case .completed, .executing:
            if let path = record.filePath {
                return "\(displayName) \(abbreviatedPath(path))"
            }
            return displayName
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
