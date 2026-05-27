import SwiftUI
import UniformTypeIdentifiers
import OakAgent

struct AIChatView: View {
    let chatVM: ChatViewModel
    var voiceVM: VoiceViewModel?
    var onSaveQuizCard: ((QuizContent) -> Bool)?

    @Environment(\.isTabActive) private var isTabActive
    @State private var playingTurnId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Content: either history drawer or chat
            Group {
                if chatVM.showHistory {
                    ChatHistoryDrawer(chatVM: chatVM)
                        .transition(.move(edge: .leading))
                } else {
                    chatContent
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()
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
        .onChange(of: voiceVM?.isSpeaking) { _, speaking in
            if speaking == false { playingTurnId = nil }
        }
        .onChange(of: isTabActive) { _, active in
            if !active { inputFocusRef.dismissCompletion() }
        }
    }

    /// True while the agent is working but no per-turn animation (thinking
    /// stroke, tool-call shimmer, or streaming text cursor) is already on screen.
    /// Drives the universal footer spinner so the user always sees activity.
    private var showWorkingIndicator: Bool {
        guard chatVM.isStreaming else { return false }
        guard let last = chatVM.turns.last else { return true }
        // Agent just received the user message and hasn't produced anything yet.
        if last.role != .assistant { return true }
        let hasExecutingTool = last.toolUses.contains { $0.status == .executing }
        let isStreamingText = last.isStreaming && !last.content.isEmpty
        let isThinking = last.isStreaming && last.content.isEmpty && (last.thinking?.isEmpty == false)
        return !(hasExecutingTool || isStreamingText || isThinking)
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
                LazyVStack(spacing: 12) {
                    ForEach(chatVM.turns) { turn in
                        ChatBubbleView(
                            turn: turn,
                            onPlayAudio: voiceVM != nil ? { t in playAudio(t) } : nil,
                            isPlayingAudio: playingTurnId == turn.id && (voiceVM?.isSpeaking ?? false),
                            onStopAudio: { stopAudio() },
                            onOpenCitation: { citeKey, anchor in
                                chatVM.openCitation(citeKey: citeKey, anchor: anchor)
                            },
                            onSaveQuizCard: onSaveQuizCard
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
                    // Universal "agent is working" indicator — the same 3×3 grid
                    // animation used for streaming. Covers the phases where no
                    // per-turn animation is visible: the wait for the next LLM
                    // response between tool iterations, and the gap before the
                    // first chunk arrives.
                    if showWorkingIndicator {
                        StreamingCursor()
                            .padding(.leading, 4)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    // Research subagent live status (search / read / synthesize).
                    if let activity = chatVM.researchActivity {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(activity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }

                    // Invisible anchor at the very bottom — more reliable
                    // than scrolling to the last turn whose height is still growing.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(OakStyle.Spacing.sm)
                .animation(.easeInOut(duration: 0.2), value: showWorkingIndicator)
                .animation(.easeInOut(duration: 0.2), value: chatVM.researchActivity)
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
                    let maxTravel = max(viewH - thumbH, 0)
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
                    // Instant follow during streaming. An *animated* scrollTo
                    // restarts every tick as the content grows, so overlapping
                    // 0.15s animations never settle and the scroll visibly
                    // stutters — worse now that content commits in larger 15fps
                    // steps. Height grows in small frequent steps, so instant
                    // tracking reads as smooth continuous scroll.
                    if chatVM.isStreaming {
                        proxy.scrollTo("bottom")
                    } else {
                        withAnimation(.smooth(duration: 0.15)) {
                            proxy.scrollTo("bottom")
                        }
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
                    Button(action: { uploadFile() }) {
                        Label("Upload File", systemImage: "arrow.up.doc")
                    }
                    if chatVM.parent != nil {
                        Button(action: { chatVM.addDocumentPageSnapshot() }) {
                            Label("Attach Page", systemImage: "doc.viewfinder")
                        }
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

    // MARK: - Audio Playback

    private func playAudio(_ turn: Turn) {
        guard let voiceVM else { return }
        let text = Self.preprocessForTTS(turn.content)
        guard !text.isEmpty else { return }
        playingTurnId = turn.id
        voiceVM.speakText(text)
    }

    private func stopAudio() {
        voiceVM?.stopSpeaking()
        playingTurnId = nil
    }

    // MARK: - TTS Text Preprocessing

    /// Strips markup that should not be read aloud: citations, quiz XML,
    /// code blocks, markdown formatting, and reference blocks.
    static func preprocessForTTS(_ text: String) -> String {
        var s = text

        // 1. Remove <referenced-documents>...</referenced-documents> blocks
        s = s.replacingOccurrences(
            of: #"<referenced-documents>[\s\S]*?</referenced-documents>"#,
            with: "",
            options: .regularExpression
        )

        // 2. Remove <quiz ...>...</quiz> blocks
        s = s.replacingOccurrences(
            of: #"<quiz\s[\s\S]*?</quiz>"#,
            with: "",
            options: .regularExpression
        )

        // 3. Remove fenced code blocks (```...```)
        s = s.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: "",
            options: .regularExpression
        )

        // 4. Remove inline code (`...`)
        s = s.replacingOccurrences(
            of: #"`[^`]+`"#,
            with: "",
            options: .regularExpression
        )

        // 5. Convert markdown links [text](url) → text (keep the label, drop the URL)
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )

        // 6. Strip bold/italic markers
        s = s.replacingOccurrences(of: "***", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")

        // 7. Strip heading markers (e.g. "### ")
        s = s.replacingOccurrences(
            of: #"(?m)^#{1,6}\s+"#,
            with: "",
            options: .regularExpression
        )

        // 8. Strip horizontal rules
        s = s.replacingOccurrences(
            of: #"(?m)^[-*_]{3,}\s*$"#,
            with: "",
            options: .regularExpression
        )

        // 9. Collapse multiple blank lines
        s = s.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File Upload

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .gif, .webP, .tiff]
        panel.message = "Select an image to attach"

        guard panel.runModal() == .OK, let url = panel.url,
              let imageData = try? Data(contentsOf: url) else { return }
        chatVM.addUploadedFile(imageData, filename: url.lastPathComponent)
    }

    // MARK: - Config Menu

    private var currentModelName: String {
        let store = ConfiguredProviderStore.shared
        let pair = store.availableLLMModels.first { $0.model.id == settingsModel }
        return pair?.model.name ?? settingsModel
    }

    @State private var settingsModel: String = {
        let prefs = Preferences.shared
        if !prefs.aiModel.isEmpty { return prefs.aiModel }
        let pid = prefs.aiProviderId
        return ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
    }()
    @State private var settingsEffort: String = Preferences.shared.thinkingEffort
    @State private var settingsPermission: AgentPermissionLevel = Preferences.shared.agentPermissionLevel

    private var settingsMenu: some View {
        let prefs = Preferences.shared
        let store = ConfiguredProviderStore.shared
        let configuredProviders = store.configuredLLMProviders
        let currentModel = settingsModel
        let currentModelInfo = store.availableLLMModels.first { $0.model.id == currentModel }?.model
        let modelSelection = Binding<String>(
            get: { currentModel },
            set: { newValue in
                prefs.aiModel = newValue
                settingsModel = newValue
                // Auto-switch provider when selecting a model from a different provider
                if let pair = store.availableLLMModels.first(where: { $0.model.id == newValue }) {
                    prefs.aiProviderId = pair.provider.id
                }
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
                let disabled = Preferences.shared.disabledModelIds
                ForEach(configuredProviders) { provider in
                    let models = provider.models.filter { !disabled.contains($0.id) }
                    if !models.isEmpty {
                        Section(provider.displayName) {
                            ForEach(models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                }
            } label: {
                Label("Model", systemImage: "cpu")
            }

            // Thinking effort submenu — only for reasoning models
            if currentModelInfo?.reasoning == true {
                Picker(selection: effortSelection) {
                    Text("Off").tag("off")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Max").tag("max")
                } label: {
                    Label("Thinking", systemImage: "brain")
                }
            }

            Picker(selection: permissionSelection) {
                ForEach(AgentPermissionLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            } label: {
                Label("Permission", systemImage: "wrench")
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
