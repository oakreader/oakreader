import SwiftUI

struct ChatHistoryDrawer: View {
    let chatVM: ChatViewModel
    /// Called after a session is loaded (e.g. so a sidebar host can open the chat panel).
    var onSelect: ((UUID) -> Void)?

    @State private var hoveredSessionId: UUID?
    @State private var pendingDelete: ConversationMeta?

    var body: some View {
        VStack(spacing: 0) {
            if chatVM.sessionList.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .onAppear {
            chatVM.loadSessionList()
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { session in
            Button("Delete", role: .destructive) {
                chatVM.deleteSessionFromList(session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("“\(session.title.isEmpty ? "New Chat" : session.title)” will be permanently deleted.")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(OakStyle.Colors.textTertiary)
            Text("No conversations yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OakStyle.Colors.textSecondary)
            Text("Start a new chat to see it here.")
                .font(.system(size: 12))
                .foregroundStyle(OakStyle.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Session List (date-grouped, Dia "Recents" style)

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(groupedSessions, id: \.title) { group in
                    Section {
                        ForEach(group.sessions, id: \.id) { session in
                            sessionRow(session)
                        }
                    } header: {
                        sectionHeader(group.title)
                    }
                }
            }
            .padding(.horizontal, OakStyle.Spacing.xs)
            .padding(.bottom, OakStyle.Spacing.sm)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(OakStyle.Colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Session Row

    private func sessionRow(_ session: ConversationMeta) -> some View {
        let isSelected = session.id == chatVM.sessionId
        let isHovered = hoveredSessionId == session.id
        // A two-line cell mirrors Dia's ChatCellView (title + subtitle teaser).
        // Fall back to the relative time when there's no message to preview.
        let subtitle = session.snippet.isEmpty ? relativeDate(session.lastMessageAt) : session.snippet

        return Button {
            chatVM.loadSession(session.id)
            onSelect?(session.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "New Chat" : session.title)
                        // Regular by default so the list stays light/quiet; only the
                        // currently-open conversation gets medium, so weight itself
                        // marks "this is the one you're viewing".
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(OakStyle.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(OakStyle.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                if isHovered {
                    Menu {
                        sessionMenuItems(session)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OakStyle.Colors.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
            }
            .padding(.horizontal, 10)
            // No per-row hairline: modern macOS sidebars (Notes, Reminders) separate
            // rows with whitespace + the rounded selection/hover highlight instead of
            // a divider. A touch more vertical room replaces the line's structuring job.
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard, style: .continuous)
                    .fill(
                        isSelected
                            ? OakStyle.Colors.selectedBackground
                            : (isHovered ? OakStyle.Colors.hoverBackground : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSessionId = hovering ? session.id : nil
        }
        .contextMenu {
            sessionMenuItems(session)
        }
    }

    // MARK: - Session Menu

    @ViewBuilder
    private func sessionMenuItems(_ session: ConversationMeta) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([CatalogDatabase.chatFileURL(sessionId: session.id)])
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }

        Button {
            let path = CatalogDatabase.chatFileURL(sessionId: session.id).path
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        } label: {
            Label("Copy File Path", systemImage: "square.on.square")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = session
        } label: {
            Label("Delete Conversation", systemImage: "trash")
        }
    }

    // MARK: - Date Grouping

    private struct SessionGroup {
        let title: String
        let sessions: [ConversationMeta]
    }

    /// Buckets sessions into recency sections (Today / Yesterday / Previous 7 Days /
    /// Previous 30 Days / month-year), mirroring Dia's "Recents" data source.
    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Stable order keyed by bucket rank, so newer buckets sort first.
        var buckets: [(rank: Int, title: String, sessions: [ConversationMeta])] = []

        func appendSession(_ session: ConversationMeta, rank: Int, title: String) {
            if let idx = buckets.firstIndex(where: { $0.rank == rank }) {
                buckets[idx].sessions.append(session)
            } else {
                buckets.append((rank, title, [session]))
            }
        }

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"

        // sessionList already arrives newest-first from the store.
        for session in chatVM.sessionList {
            let date = session.lastMessageAt
            let dayStart = calendar.startOfDay(for: date)
            let daysAgo = calendar.dateComponents([.day], from: dayStart, to: startOfToday).day ?? 0

            if daysAgo <= 0 {
                appendSession(session, rank: 0, title: "Today")
            } else if daysAgo == 1 {
                appendSession(session, rank: 1, title: "Yesterday")
            } else if daysAgo <= 7 {
                appendSession(session, rank: 2, title: "Previous 7 Days")
            } else if daysAgo <= 30 {
                appendSession(session, rank: 3, title: "Previous 30 Days")
            } else {
                // Month-year buckets; rank keeps them after the fixed sections and
                // ordered most-recent-first.
                let monthRank = 1000 + (calendar.dateComponents([.day], from: dayStart, to: startOfToday).day ?? 0)
                appendSession(session, rank: monthRank, title: monthFormatter.string(from: date))
            }
        }

        return buckets
            .sorted { $0.rank < $1.rank }
            .map { SessionGroup(title: $0.title, sessions: $0.sessions) }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
