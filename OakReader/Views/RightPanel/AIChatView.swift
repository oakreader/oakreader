import SwiftUI
import OakAI

struct AIChatView: View {
    let chatVM: ChatViewModel
    var onSaveAssistantResponse: ((ChatTurn) -> Bool)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Content: either history drawer or chat
            if chatVM.showHistory {
                ChatHistoryDrawer(chatVM: chatVM)
                    .transition(.move(edge: .leading))
            } else {
                chatContent
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chatVM.showHistory)
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

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
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
            if chatVM.showHistory {
                Text("History")
                    .font(.system(size: 16, weight: .semibold))
            } else {
                Text("AI Chat")
                    .font(.system(size: 16, weight: .semibold))
            }

            Spacer()

            OakToolButton(systemImage: "plus.bubble", tooltip: "New Chat") {
                chatVM.newSession()
            }

            OakToolButton(
                systemImage: chatVM.showHistory ? "xmark" : "list.bullet",
                isSelected: chatVM.showHistory,
                tooltip: chatVM.showHistory ? "Close History" : "Chat History"
            ) {
                if chatVM.showHistory {
                    chatVM.showHistory = false
                } else {
                    chatVM.loadSessionList()
                    chatVM.showHistory = true
                }
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.sm)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(chatVM.parent != nil ? "Ask about this Document" : "Ask anything")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(chatVM.parent != nil
                 ? "Ask questions, get summaries, or find information in your document."
                 : "Ask questions or chat with AI — no document needed.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OakStyle.Spacing.lg)

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
                        ChatBubbleView(
                            turn: turn,
                            onSaveToNote: onSaveAssistantResponse,
                            onApproveToolCall: { chatVM.approveToolCall() },
                            onDenyToolCall: { chatVM.denyToolCall() }
                        )
                            .id(turn.id)
                    }
                }
                .padding(OakStyle.Spacing.sm)
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

    @State private var inputContentHeight: CGFloat = 48
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
                placeholder: chatVM.parent != nil ? "Ask about this Document..." : "Ask a question...",
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
                        .font(.system(size: OakStyle.Font.icon, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Add attachment")

                modelSwitcher

                Spacer()

                if chatVM.isStreaming {
                    Button(action: { chatVM.stopStreaming() }) {
                        ZStack {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
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
                                .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                            Image(systemName: "arrow.up")
                                .font(.system(size: OakStyle.Font.icon, weight: .bold))
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Model Switcher

    private var currentModelName: String {
        let config = chatVM.config
        return config.modelInfo?.name ?? config.model
    }

    private var modelSwitcher: some View {
        let prefs = Preferences.shared
        let providerInfo = ProviderRegistry.shared.provider(for: prefs.aiProviderId)
        let models = providerInfo?.models ?? []
        let currentModel = chatVM.config.model

        return Menu {
            ForEach(models) { model in
                Button(action: {
                    prefs.aiModel = model.id
                }) {
                    HStack {
                        Text(model.name)
                        if model.id == currentModel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentModelName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Switch model")
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
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xxs)
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
