import SwiftUI
import OakAgent

/// Collapses multiple tool calls into a single summary line with optional expansion.
/// Mirrors the disclosure style of `ThinkingDisclosureView`.
struct ToolCallGroupView: View {
    let records: [ToolUseRecord]

    @State private var isExpanded = false
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — collapsed summary
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    if !isExecuting {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    }

                    if isExecuting {
                        shimmerLabel
                    } else {
                        Text(summaryText)
                            .font(OakStyle.ChatFont.messageBody)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            // Expanded detail list
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(records) { record in
                        HStack(spacing: 4) {
                            recordStatusIcon(record)
                            Text(recordLabel(record))
                                .font(OakStyle.ChatFont.messageBody)
                                .foregroundStyle(.secondary.opacity(0.75))
                                .lineLimit(1)
                        }
                        .padding(.leading, 8)
                    }
                }
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
            if isExecuting { startShimmer() }
        }
        .onChange(of: isExecuting) { _, executing in
            if executing { startShimmer() }
        }
    }

    // MARK: - State

    private var isExecuting: Bool {
        records.contains { $0.status == .executing }
    }

    // MARK: - Summary Text

    private var summaryText: String {
        let grouped = Dictionary(grouping: records, by: { toolCategory($0.name) })
        let parts: [String] = grouped.keys.sorted().compactMap { category in
            guard let items = grouped[category] else { return nil }
            return completedDescription(category: category, count: items.count)
        }
        return parts.joined(separator: ", ")
    }

    private var executingText: String {
        // Show the executing tool's action, or a generic message
        if let executing = records.last(where: { $0.status == .executing }) {
            return executingDescription(toolName: executing.name)
        }
        return "Working..."
    }

    // MARK: - Tool Category Mapping

    private enum ToolCategory: String, Comparable {
        case searchDocument
        case readDocument
        case searchFiles
        case readFiles
        case writeFiles
        case editFiles
        case bash
        case oak
        case other

        static func < (lhs: ToolCategory, rhs: ToolCategory) -> Bool {
            lhs.sortOrder < rhs.sortOrder
        }

        var sortOrder: Int {
            switch self {
            case .searchDocument: return 0
            case .readDocument: return 1
            case .searchFiles: return 2
            case .readFiles: return 3
            case .writeFiles: return 4
            case .editFiles: return 5
            case .bash: return 6
            case .oak: return 7
            case .other: return 8
            }
        }
    }

    private func toolCategory(_ name: String) -> ToolCategory {
        switch name {
        case "search_document": return .searchDocument
        case "read_document": return .readDocument
        case "search_files": return .searchFiles
        case "read", "read_file": return .readFiles
        case "write", "write_file": return .writeFiles
        case "edit": return .editFiles
        case "bash": return .bash
        case "oak": return .oak
        default: return .other
        }
    }

    private func completedDescription(category: ToolCategory, count: Int) -> String {
        switch category {
        case .searchDocument:
            return count == 1 ? "Searched 1 page" : "Searched \(count) pages"
        case .readDocument:
            return count == 1 ? "Read 1 page" : "Read \(count) pages"
        case .searchFiles:
            return "Searched files"
        case .readFiles:
            return count == 1 ? "Read 1 file" : "Read \(count) files"
        case .writeFiles:
            return count == 1 ? "Wrote 1 file" : "Wrote \(count) files"
        case .editFiles:
            return count == 1 ? "Edited 1 file" : "Edited \(count) files"
        case .bash:
            return count == 1 ? "Ran 1 command" : "Ran \(count) commands"
        case .oak:
            return "Queried library"
        case .other:
            return count == 1 ? "Used 1 tool" : "Used \(count) tools"
        }
    }

    private func executingDescription(toolName: String) -> String {
        switch toolName {
        case "search_document": return "Searching documents..."
        case "read_document": return "Reading document..."
        case "search_files": return "Searching files..."
        case "read", "read_file": return "Reading files..."
        case "write", "write_file": return "Writing..."
        case "edit": return "Editing..."
        case "bash": return "Running command..."
        case "oak": return "Querying library..."
        default: return "Working..."
        }
    }

    // MARK: - Record Detail

    @ViewBuilder
    private func recordStatusIcon(_ record: ToolUseRecord) -> some View {
        switch record.status {
        case .executing:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)
        case .completed:
            Image(systemName: record.isError ? "xmark" : "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(record.isError ? .red : .green)
                .frame(width: 10, height: 10)
        case .denied:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 8))
                .foregroundStyle(.red)
                .frame(width: 10, height: 10)
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .frame(width: 10, height: 10)
        }
    }

    private func recordLabel(_ record: ToolUseRecord) -> String {
        let displayName: String
        switch record.name {
        case "search_document": displayName = "Search"
        case "read_document": displayName = "Read"
        case "search_files": displayName = "Search files"
        case "read", "read_file": displayName = "Read"
        case "write", "write_file": displayName = "Write"
        case "edit": displayName = "Edit"
        case "bash": displayName = "Bash"
        case "oak": displayName = "Oak"
        default: displayName = record.name
        }

        if let path = record.filePath {
            let abbreviated = abbreviatedPath(path)
            return "\(displayName) \(abbreviated)"
        }
        if let query = record.input["query"] ?? record.input["command"] {
            let truncated = query.count > 40 ? String(query.prefix(40)) + "..." : query
            return "\(displayName) \"\(truncated)\""
        }
        return displayName
    }

    private func abbreviatedPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return ".../" + components.suffix(2).joined(separator: "/")
    }

    // MARK: - Shimmer

    private var shimmerLabel: some View {
        HStack(spacing: 6) {
            // The same animated 3×3 "agent is working" indicator the chat uses
            // elsewhere — replaces the static gear, which read as a Settings icon.
            StreamingCursor()
            Text(executingText)
                .font(OakStyle.ChatFont.messageBody)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .overlay {
                    shimmerGradient
                        .mask {
                            Text(executingText)
                                .font(OakStyle.ChatFont.messageBody)
                                .fontWeight(.medium)
                        }
                }
        }
    }

    private var shimmerGradient: some View {
        LinearGradient(
            colors: [.clear, Color.primary.opacity(0.6), .clear],
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
}
