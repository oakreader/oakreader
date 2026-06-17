import SwiftUI

struct ChatHistoryDrawer: View {
    let chatVM: ChatViewModel
    /// Called after a session is loaded (e.g. so a sidebar host can open the chat panel).
    var onSelect: ((UUID) -> Void)?

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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No conversations yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start a new chat to see it here.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(chatVM.sessionList) { session in
                    sessionRow(session)
                }
            }
            .padding(.horizontal, OakStyle.Spacing.xs)
            .padding(.vertical, OakStyle.Spacing.xs)
        }
    }

    // MARK: - Session Row

    @State private var hoveredSessionId: UUID?

    private func sessionRow(_ session: ConversationMeta) -> some View {
        Button {
            chatVM.loadSession(session.id)
            onSelect?(session.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title.isEmpty ? "New Chat" : session.title)
                        .font(OakStyle.Font.styledBody)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(relativeDate(session.lastMessageAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        if session.messageCount > 0 {
                            Text("\(session.messageCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.primary.opacity(0.06))
                                )
                        }
                    }
                }

                Spacer()

                if hoveredSessionId == session.id {
                    Menu {
                        sessionMenuItems(session)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                    .fill(
                        session.id == chatVM.sessionId
                            ? OakStyle.Colors.selectedBackground
                            : (hoveredSessionId == session.id
                                ? OakStyle.Colors.hoverBackground
                                : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredSessionId = isHovered ? session.id : nil
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
            Label("Copy File Path", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            chatVM.deleteSessionFromList(session.id)
        } label: {
            Label("Delete Conversation", systemImage: "trash")
        }
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
