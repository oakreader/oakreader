import SwiftUI
import OakAgent

struct AIChatView: View {
    let chatVM: ChatViewModel
    var onSaveAssistantResponse: ((Turn) -> Bool)?

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                inputFocusRef.focus()
            }
        }
        .onChange(of: chatVM.pendingLibraryRef?.id) { _, newId in
            guard newId != nil, let item = chatVM.pendingLibraryRef else { return }
            chatVM.pendingLibraryRef = nil
            let token = ChatCompletionItem.libraryReference(from: item)
            inputFocusRef.insertDroppedToken(token)
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

            // Sticky tool confirmation bar
            if let pending = chatVM.pendingToolConfirmation {
                ToolConfirmationBar(
                    confirmation: pending,
                    onApprove: { chatVM.approveToolCall() },
                    onDeny: { chatVM.denyToolCall() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3, bounce: 0.15), value: chatVM.pendingToolConfirmation != nil)
                .padding(.bottom, 4)
            }

            inputBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if chatVM.showHistory {
                Text("History")
                    .font(OakStyle.ChatFont.headerTitle)
            } else {
                Text("AI Chat")
                    .font(OakStyle.ChatFont.headerTitle)
            }

            Spacer()

            OakToolButton(systemImage: "bubble.left", tooltip: "New Chat") {
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

    @State private var emptyStateAppeared = false

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
                .scaleEffect(emptyStateAppeared ? 1.0 : 0.8)
                .opacity(emptyStateAppeared ? 1.0 : 0)
            Text(chatVM.parent != nil ? "Ask about this Document" : "Ask anything")
                .font(OakStyle.ChatFont.headerTitle)
                .foregroundStyle(.secondary)
                .offset(y: emptyStateAppeared ? 0 : 6)
                .opacity(emptyStateAppeared ? 1.0 : 0)
            Text(chatVM.parent != nil
                 ? "Ask questions, get summaries, or find information in your document."
                 : "Ask questions or chat with AI — no document needed.")
                .font(OakStyle.Font.styled(size: 14))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OakStyle.Spacing.lg)
                .offset(y: emptyStateAppeared ? 0 : 6)
                .opacity(emptyStateAppeared ? 1.0 : 0)

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
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(0.1)) {
                emptyStateAppeared = true
            }
        }
        .onDisappear {
            emptyStateAppeared = false
        }
    }

    // MARK: - Message List

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0
    @State private var scrollBarOpacity: Double = 0
    @State private var fadeTask: Task<Void, Never>?

    @State private var isNearBottom = true
    @State private var scrollTask: Task<Void, Never>?

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chatVM.turns) { turn in
                        ChatBubbleView(
                            turn: turn,
                            onSaveToNote: onSaveAssistantResponse,
                            onOpenCitation: { citeKey, anchor in
                                chatVM.openCitation(citeKey: citeKey, anchor: anchor)
                            }
                        )
                            .id(turn.id)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom)
                                        .combined(with: .opacity)
                                        .combined(with: .scale(scale: 0.98, anchor: turn.role == .user ? .trailing : .leading)),
                                    removal: .opacity
                                )
                            )
                    }
                    // Invisible anchor at the very bottom — more reliable
                    // than scrolling to the last turn whose height is still growing.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(OakStyle.Spacing.sm)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: chatVM.turns.count)
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
            .defaultScrollAnchor(.bottom)
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

                // Track whether user is near the bottom (within 20px)
                let scrollable = metrics.contentHeight - scrollViewHeight
                isNearBottom = scrollable <= 0 || (scrollable - metrics.offset) < 20
            }
            .onChange(of: chatVM.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom")
                }
                isNearBottom = true
            }
            .onChange(of: scrollContentHeight) { old, new in
                guard new - old > 1 else { return }
                // During streaming: always follow. Otherwise: respect user scroll.
                guard chatVM.isStreaming || isNearBottom else { return }
                // Debounce: coalesce rapid height changes into one smooth scroll.
                // Without this, 60fps height updates cause 60 discrete jumps.
                scrollTask?.cancel()
                scrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(32))
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.15)) {
                        proxy.scrollTo("bottom")
                    }
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

    @State private var inputContentHeight: CGFloat = ChatInputTextView.minContentHeight
    private let inputFocusRef = ChatInputTextView.FocusRef()

    private var inputHasText: Bool {
        !chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chatVM.activeTokens.isEmpty
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
                slashItems: chatVM.chatSlashItems,
                onActiveTokensChanged: { tokens in chatVM.activeTokens = tokens },
                resetToken: chatVM.inputResetToken,
                focusRef: inputFocusRef
            )
            .frame(height: inputContentHeight)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

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
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Add attachment")

                settingsMenu

                Spacer()

                if chatVM.isStreaming {
                    Button(action: { chatVM.stopStreaming() }) {
                        ZStack {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 28, height: 28)
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button(action: { chatVM.send() }) {
                        ZStack {
                            Circle()
                                .fill(inputHasText ? Color.primary : Color.gray.opacity(0.3))
                                .frame(width: 28, height: 28)
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
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.20), lineWidth: 1)
        )
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Config Menu

    private var currentModelName: String {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        let provider = ProviderRegistry.shared.provider(for: pid)
        let modelId = settingsModel.isEmpty ? (provider?.defaultModelId ?? "") : settingsModel
        return provider?.models.first { $0.id == modelId }?.name ?? modelId
    }

    @State private var settingsModel: String = Preferences.shared.aiModel
    @State private var settingsEffort: String = Preferences.shared.thinkingEffort
    @State private var settingsPermission: AgentPermissionLevel = Preferences.shared.agentPermissionLevel

    private var settingsMenu: some View {
        let prefs = Preferences.shared
        let providerInfo = ProviderRegistry.shared.provider(for: prefs.aiProviderId)
        let models = providerInfo?.models ?? []
        let currentModel = settingsModel.isEmpty ? (providerInfo?.defaultModelId ?? "") : settingsModel
        let currentModelInfo = providerInfo?.models.first { $0.id == currentModel }
        let modelSelection = Binding<String>(
            get: { currentModel },
            set: { newValue in
                prefs.aiModel = newValue
                settingsModel = newValue
            }
        )
        let effortSelection = Binding<String>(
            get: { settingsEffort },
            set: { newValue in
                prefs.thinkingEffort = newValue
                settingsEffort = newValue
            }
        )
        let permissionSelection = Binding<AgentPermissionLevel>(
            get: { settingsPermission },
            set: { newValue in
                prefs.agentPermissionLevel = newValue
                settingsPermission = newValue
            }
        )

        return Menu {
            Picker(selection: modelSelection) {
                ForEach(models) { model in
                    Text(model.name).tag(model.id)
                }
            } label: {
                Label("Model", systemImage: "cpu")
            }

            // Thinking effort submenu — only for reasoning models
            if currentModelInfo?.reasoning == true {
                Picker(selection: effortSelection) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                } label: {
                    Label("Thinking", systemImage: "brain")
                }
            }

            Picker(selection: permissionSelection) {
                ForEach(AgentPermissionLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            } label: {
                Label("Tools", systemImage: "wrench")
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentModelName)
                    .font(OakStyle.ChatFont.modelLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Model & settings")
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.body)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { chatVM.errorMessage = nil }
                .font(.callout)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, OakStyle.Spacing.sm)
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
