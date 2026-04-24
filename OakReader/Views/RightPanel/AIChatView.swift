import SwiftUI
// import OakReaderAI // TODO: re-enable when module is available

struct AIChatView: View {
    let chatVM: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

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
        .onAppear {
            // Auto-focus the chat input when the AI chat panel opens.
            // Delayed so the NSTextView is attached to its NSWindow before
            // we call makeFirstResponder (otherwise textView.window is nil
            // and the call silently no-ops, leaving keystrokes to hit the
            // toolbar responder chain — e.g. triggering the search field).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                inputFocusRef.focus()
            }
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

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0
    @State private var scrollBarOpacity: Double = 0
    @State private var fadeTask: Task<Void, Never>?

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
                .background(
                    GeometryReader { inner in
                        Color.clear
                            .preference(
                                key: ScrollMetricsKey.self,
                                value: ScrollMetrics(
                                    offset: -inner.frame(in: .named("chatScroll")).minY,
                                    contentHeight: inner.size.height
                                )
                            )
                    }
                )
            }
            .coordinateSpace(name: "chatScroll")
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .trailing) {
                GeometryReader { geo in
                    let viewH = geo.size.height
                    let ratio = scrollContentHeight > viewH
                        ? viewH / scrollContentHeight : 1
                    let thumbH = max(ratio * viewH, 28)
                    let maxTravel = viewH - thumbH
                    let scrollable = scrollContentHeight - viewH
                    let progress = scrollable > 0
                        ? min(max(scrollOffset / scrollable, 0), 1) : 0
                    let thumbY = progress * maxTravel

                    Capsule()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 3, height: thumbH)
                        .offset(y: thumbY)
                        .padding(.trailing, 1.5)
                        .opacity(ratio < 1 ? scrollBarOpacity : 0)
                        .animation(.easeOut(duration: 0.15), value: scrollBarOpacity)
                        .onAppear { scrollViewHeight = viewH }
                        .onChange(of: geo.size.height) { _, h in scrollViewHeight = h }
                }
            }
            .onPreferenceChange(ScrollMetricsKey.self) { metrics in
                scrollOffset = metrics.offset
                scrollContentHeight = metrics.contentHeight
                showScrollBar()
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

    private func showScrollBar() {
        scrollBarOpacity = 1
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { scrollBarOpacity = 0 }
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
                onPasteImage: { data in chatVM.addClipboardImage(data) },
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
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
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
                                .frame(width: 30, height: 30)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 12, height: 12)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button(action: { chatVM.send() }) {
                        ZStack {
                            Circle()
                                .fill(inputHasText ? Color.primary : Color.gray.opacity(0.3))
                                .frame(width: 30, height: 30)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        }
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

// MARK: - Scroll metrics preference key

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct ScrollMetricsKey: PreferenceKey {
    static let defaultValue = ScrollMetrics()
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
        value = nextValue()
    }
}
