import SwiftUI
// import OakReaderAI // TODO: re-enable when module is available

struct AIChatView: View {
    let chatVM: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if chatVM.turns.isEmpty {
                emptyState
            } else {
                messageList
            }

            // Error banner
            if let error = chatVM.errorMessage {
                errorBanner(error)
            }

            inputBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("AI Chat")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            SessionPickerMenu(chatVM: chatVM)

            Button(action: { chatVM.newSession() }) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("New Chat")
        }
        .padding(.horizontal, ZoteroStyle.Spacing.sm)
        .padding(.vertical, ZoteroStyle.Spacing.sm)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Ask about this PDF")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Ask questions, get summaries, or find information in your document.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ZoteroStyle.Spacing.lg)

            if chatVM.selectedSkill != nil {
                Text("Skill: \(chatVM.selectedSkill!.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.1)))
            }

            Spacer()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chatVM.turns) { turn in
                        ChatBubbleView(turn: turn)
                            .id(turn.id)
                    }
                }
                .padding(ZoteroStyle.Spacing.sm)
            }
            .onChange(of: chatVM.turns.count) { _, _ in
                if let last = chatVM.turns.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatVM.turns.last?.content) { _, _ in
                if let last = chatVM.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input Bar

    @State private var inputContentHeight: CGFloat = 36
    private let inputFocusRef = ChatInputTextView.FocusRef()

    private var inputHasText: Bool {
        !chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Attachment chips
            if !chatVM.pendingAttachments.isEmpty {
                AttachmentPreviewStrip(
                    attachments: chatVM.pendingAttachments,
                    onRemove: { chatVM.removePendingAttachment($0) }
                )
                .padding(.top, 6)
                .padding(.horizontal, 10)
            }

            // Text input — sized exactly to content
            ChatInputTextView(
                text: Binding(
                    get: { chatVM.inputText },
                    set: { chatVM.inputText = $0 }
                ),
                placeholder: "Ask about this PDF...",
                onSend: { if inputHasText { chatVM.send() } },
                contentHeight: $inputContentHeight,
                focusRef: inputFocusRef
            )
            .frame(height: inputContentHeight)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Bottom row: attachment + send
            HStack(spacing: 6) {
                Menu {
                    Button(action: {}) {
                        Label("Attach Page Snapshot", systemImage: "doc.viewfinder")
                    }
                    Button(action: {}) {
                        Label("Attach Selection", systemImage: "text.quote")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Add attachment")

                Spacer()

                if chatVM.isStreaming {
                    Button(action: { chatVM.stopStreaming() }) {
                        ZStack {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 24, height: 24)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button(action: { chatVM.send() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(inputHasText ? Color.accentColor : Color.gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!inputHasText)
                    .help("Send message (↩)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            inputFocusRef.focus()
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.horizontal, ZoteroStyle.Spacing.sm)
        .padding(.vertical, ZoteroStyle.Spacing.xs)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { chatVM.errorMessage = nil }
                .font(.caption)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, ZoteroStyle.Spacing.sm)
        .padding(.vertical, ZoteroStyle.Spacing.xxs)
        .background(Color.yellow.opacity(0.1))
    }
}
