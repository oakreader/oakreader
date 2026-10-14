import SwiftUI
import UniformTypeIdentifiers
import OakMarkdownUI

/// How the chat surface presents itself.
enum ChatPresentation {
    /// Narrow inspector/right-panel column (the default everywhere it has lived).
    case panel
    /// Full-page, centered Dia-style agent canvas (the library agent workspace).
    case canvas
}

struct AIChatView: View {
    let chatVM: ChatViewModel

    /// Layout mode. `.panel` (default) preserves the existing right-panel behavior;
    /// `.canvas` centers content into a comfortable reading column for the agent page.
    var presentation: ChatPresentation = .panel
    /// Name of the collection the agent is scoped to (nil = whole library). Canvas only.
    var workspaceName: String? = nil
    /// When non-nil, a "clear" affordance on the workspace chip resets scope to the whole library.
    var onClearWorkspace: (() -> Void)? = nil

    /// Width of the centered content column in `.canvas` mode.
    private let canvasContentWidth: CGFloat = 760

    @Environment(\.isTabActive) private var isTabActive
    @State private var showUserMemory = false

    /// Body text size of the surrounding messages, so the composer and its token
    /// chips match the rendered body ("正文") size — the shared 14pt prose token
    /// (`oak()`'s default), used by chat and notes alike.
    private var bodyFontSize: CGFloat {
        MarkdownTheme.oak().bodyFont.pointSize
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Content: either history drawer or chat.
            // Cross-fade rather than slide: a horizontal `.move` pushes content
            // (including the AppKit NSTextView input bar) past the panel's edge,
            // where it escapes `.clipped()` and paints over the document. A fade
            // keeps every subview in place, so nothing can bleed out of the panel.
            Group {
                if chatVM.showHistory {
                    ChatHistoryDrawer(chatVM: chatVM)
                        .transition(.opacity)
                } else {
                    chatContent
                        .transition(.opacity)
                }
            }
            .clipped()
        }
        .animation(OakStyle.Motion.fade, value: chatVM.showHistory)
        .onAppear {
            chatVM.refreshAtMentionItems()
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
        .onChange(of: isTabActive) { _, active in
            if !active { inputFocusRef.dismissCompletion() }
        }
        .sheet(isPresented: $showUserMemory) {
            MemoryManagerView()
        }
    }

    /// True while the agent is working but no per-turn animation (thinking
    /// stroke, tool-call shimmer, or streaming text cursor) is already on screen.
    /// Drives the universal footer spinner so the user always sees activity.
    /// Only the wait for the first token. After that the live step group's
    /// shimmering label, or the streaming text, shows the agent is working.
    private var showWorkingIndicator: Bool {
        guard chatVM.isStreaming else { return false }
        guard let last = chatVM.turns.last else { return true }
        return last.role != .assistant
    }

    @ViewBuilder
    private func displayRow(_ item: ChatDisplayItem) -> some View {
        switch item {
        case .turn(let turn):
            ChatBubbleView(
                turn: turn,
                resolveCitation: { chatVM.resolveCitation($0) },
                onOpenCitation: { itemId, anchor in
                    chatVM.openCitation(itemId: itemId, anchor: anchor)
                },
                markdownTheme: presentation == .canvas ? .dia : nil
            )
                .equatable()
        case .steps(_, let steps, let isLive):
            AgentStepsView(steps: steps, isLive: isLive,
                           theme: presentation == .canvas ? .dia : .oak())
        }
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
            if chatVM.turns.isEmpty {
                // Canvas is a full-page surface that earns a welcome screen; the
                // right panel doesn't — its composer placeholder already says the
                // same thing, so leave the space clean above the input bar.
                if presentation == .canvas {
                    canvasConstrained { emptyState }
                } else {
                    Spacer()
                }
            } else {
                // messageList spans the full pane so its custom scrollbar sits at
                // the pane's right edge; the message column is centered internally.
                messageList
            }

            // Error banner
            if let error = chatVM.errorMessage {
                canvasConstrained { errorBanner(error) }
            }

            // Sticky tool confirmation bar
            if let pending = chatVM.pendingToolConfirmation {
                canvasConstrained {
                    ToolConfirmationBar(
                        confirmation: pending,
                        onApprove: { chatVM.approveToolCall() },
                        onDeny: { chatVM.denyToolCall() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(OakStyle.Motion.slow, value: chatVM.pendingToolConfirmation != nil)
                    .padding(.bottom, 4)
                }
            }

            // Transient "memory updated / saved" notice — surfaces the agent's
            // explicit `remember` saves, tappable to inspect.
            if let notice = chatVM.memoryNotice {
                canvasConstrained { memoryNoticeBar(notice) }
            }

            canvasConstrained { inputBar }
        }
        .animation(OakStyle.Motion.slow, value: chatVM.memoryNotice)
    }

    /// Dia-style pill announcing a memory write; tap to open the manager.
    private func memoryNoticeBar(_ text: String) -> some View {
        Button {
            showUserMemory = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                Text("· View")
                    .font(.system(size: 11))
                    .foregroundStyle(OakStyle.Colors.textTertiary)
            }
            .foregroundStyle(OakStyle.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(OakStyle.Colors.diaSurface))
            .overlay(Capsule().stroke(OakStyle.Colors.diaHairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Centers content into the Dia reading column in `.canvas` mode; no-op in `.panel`.
    @ViewBuilder
    private func canvasConstrained<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if presentation == .canvas {
            content()
                .frame(maxWidth: canvasContentWidth)
                .frame(maxWidth: .infinity)
        } else {
            content()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            OakToolButton(
                systemImage: chatVM.showHistory ? "xmark" : "list.bullet",
                prominent: true,
                tooltip: chatVM.showHistory ? "Close History" : "Chat History"
            ) {
                if chatVM.showHistory {
                    chatVM.showHistory = false
                } else {
                    Task { await chatVM.loadSessionList() }
                    chatVM.showHistory = true
                }
            }

            if chatVM.showHistory {
                Text("History")
                    .font(OakStyle.ChatFont.headerTitle)
            } else {
                if presentation == .canvas || workspaceName != nil {
                    // The panel earns the chip only when the chat is scoped to
                    // something — a collection. Document chat passes no scope and
                    // keeps its bare header.
                    workspaceChip
                }
                // The chat's own name, once it has a message — Gemini's side
                // panel shows the same.
                if let title = chatVM.sessionTitle, !title.isEmpty {
                    SessionTitleView(title: title) { chatVM.renameSession(chatVM.sessionId, to: $0) }
                }
            }

            Spacer(minLength: 0)

            OakToolButton(systemImage: "plus", prominent: true, tooltip: "New Chat") {
                chatVM.newSession()
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        // Match the live-web address-bar toolbar's vertical padding (6) so this
        // header's icons sit on the SAME line as the back/forward/reload row in
        // the content column — both columns start at the same Y below the tab
        // bar, so equal padding lines up the icon centers. Spacing.sm (10) here
        // pushed these icons 4px lower than the toolbar.
        .padding(.vertical, 6)
    }

    /// Pill in the header naming what the agent is scoped to (the selected
    /// collection), with a clear affordance back to the whole library.
    private var workspaceChip: some View {
        HStack(spacing: 6) {
            Image(systemName: workspaceName == nil ? "books.vertical" : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(workspaceName ?? "All Library")
                .font(OakStyle.ChatFont.headerTitle)
                .lineLimit(1)
            if let onClearWorkspace, workspaceName != nil {
                Button(action: onClearWorkspace) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear workspace — chat across the whole library")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, workspaceName != nil && onClearWorkspace != nil ? 6 : 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.primary.opacity(workspaceName == nil ? 0 : 0.06))
        )
    }

    // MARK: - Empty State

    @State private var emptyStateAppeared = false

    private var emptyStateTitle: String {
        if let workspaceName { return "Ask anything about \(workspaceName)" }
        if presentation == .canvas { return "Ask anything" }
        return chatVM.parent != nil ? "Ask about this Document" : "Ask anything"
    }

    private var emptyStateSubtitle: String {
        if workspaceName != nil {
            return "Ask across these sources, or have a paper found and filed here."
        }
        if presentation == .canvas {
            return "Ask questions, search your library, or chat with AI."
        }
        return chatVM.parent != nil
            ? "Ask questions, get summaries, or find information in your document."
            : "Ask questions, search your library, or file something new in it."
    }

    @ViewBuilder
    private var emptyStateIcon: some View {
        if presentation == .canvas {
            OakAppIcon(size: 44)
        } else {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: presentation == .canvas ? 14 : 12) {
            Spacer()
            emptyStateIcon
                .scaleEffect(emptyStateAppeared ? 1.0 : 0.8)
                .opacity(emptyStateAppeared ? 1.0 : 0)
            Text(emptyStateTitle)
                .font(presentation == .canvas
                      ? OakStyle.Font.styled(size: 24, weight: .semibold)
                      : OakStyle.ChatFont.headerTitle)
                .foregroundStyle(presentation == .canvas ? .primary : .secondary)
                .offset(y: emptyStateAppeared ? 0 : 6)
                .opacity(emptyStateAppeared ? 1.0 : 0)
            Text(emptyStateSubtitle)
                .font(OakStyle.Font.styled(size: presentation == .canvas ? 15 : 14))
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

    // Scroll position lives in an @Observable object, not @State on this view.
    // Only the extracted ChatScrollbar reads `offset`/`barOpacity`, so a scroll
    // (which fires the metrics preference every frame) re-renders the thin
    // scrollbar capsule alone — never the eager message list. This mirrors how
    // AppKit's NSScrollView scrolls content without re-running any view tree.
    @State private var scrollState = ChatScrollState()

    /// Feather the scroll edges, the way Dia wraps its thread in
    /// `ARCUI.FeatheredContainerView` (`featherSize`, `featherInset`).
    ///
    /// This replaces a gradient of `windowBackgroundColor` painted over the top and
    /// bottom. Painting the background only works while the background really is
    /// that colour; a mask takes the text's own alpha down, so it is right over any
    /// surface, in either appearance.
    ///
    /// An edge only feathers when there is content past it. Dia's feather is
    /// constant, which leaves the first line of a short answer looking dimmed for no
    /// reason; the flags come from the scroll metrics that are already being
    /// measured, so this costs nothing and invalidates the list only when an edge
    /// actually changes state.
    private func featherMask(top: Bool, bottom: Bool) -> some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(top ? 0 : 1), .black],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.featherHeight)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .black.opacity(bottom ? 0 : 1)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.featherHeight)
        }
    }

    private static let featherHeight: CGFloat = 28

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager layout (not LazyVStack): each bubble's prose is an AppKit NSTextView,
                // and LazyVStack dehydrates off-screen rows while a reply streams (content
                // height changes every frame + scroll-to-bottom). Rehydrating an NSTextView
                // means re-running makeNSView + TextKit layout + math/code image rendering,
                // which blanks the whole history for ~1s at generation start/end. Keeping
                // rows realized avoids the teardown/rebuild churn.
                //
                // The thread pads its last exchange to the viewport height, so a sent
                // message can scroll to the top and the reply grows into the space
                // below it — nothing above the reply moves while it streams. See
                // `ChatThreadLayout`.
                ChatThreadLayout(
                    spacing: 12,
                    viewportHeight: max(scrollState.viewHeight - 2 * OakStyle.Spacing.sm, 0)
                ) {
                    ForEach(ChatDisplayItem.build(from: chatVM.turns, isStreaming: chatVM.isStreaming)) { item in
                        displayRow(item)
                            .id(item.id)
                            .layoutValue(key: StartsThreadTail.self, value: item.id == lastUserTurnID?.uuidString)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 8)),
                                    removal: .opacity
                                )
                            )
                    }
                    // "Agent is working" indicator — the three-dot typing wave.
                    // Covers the first-token wait and the gaps between tool
                    // iterations where no per-turn animation is on screen.
                    if showWorkingIndicator {
                        StreamingCursor()
                            .padding(.leading, 4)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    // Invisible anchor at the very bottom — more reliable
                    // than scrolling to the last turn whose height is still growing.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(OakStyle.Spacing.sm)
                .animation(OakStyle.Motion.fade, value: showWorkingIndicator)
                .animation(OakStyle.Motion.fade, value: chatVM.turns.count)
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
                // Center the message column inside the full-width scroll view so the
                // trailing scrollbar overlay stays at the pane's right edge (canvas mode).
                .frame(maxWidth: presentation == .canvas ? canvasContentWidth : .infinity)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .coordinateSpace(name: "chatScroll")
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            // Initial position only. Size changes must not re-anchor: the thread
            // holds still while a reply streams, and following is decided below.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Mask before the scrollbar overlay, so the bar itself never fades.
            .mask {
                featherMask(top: !scrollState.isAtTop, bottom: !scrollState.isAtBottomEdge)
                    .animation(OakStyle.Motion.fade, value: scrollState.isAtTop)
                    .animation(OakStyle.Motion.fade, value: scrollState.isAtBottomEdge)
            }
            .overlay(alignment: .trailing) {
                ChatScrollbar(state: scrollState)
            }
            .onPreferenceChange(ScrollMetricsKey.self) { metrics in
                // Guard redundant writes: during a pure scroll only `offset`
                // changes, so only the scrollbar (which reads it) is invalidated.
                let heightChanged = scrollState.contentHeight != metrics.contentHeight
                if scrollState.offset != metrics.offset { scrollState.offset = metrics.offset }
                if heightChanged { scrollState.contentHeight = metrics.contentHeight }
                scrollState.registerActivity()

                // Read the position only on a pure scroll (height stable). While content
                // grows, the offset lags the new height by a frame, so reading it then
                // would see "not at the bottom" for one frame: the follow would let go
                // and the bottom feather would blink on every streamed chunk.
                guard !heightChanged else { return }
                let scrollable = metrics.contentHeight - scrollState.viewHeight
                let fromBottom = scrollable - metrics.offset
                scrollState.isNearBottom = scrollable <= 0 || fromBottom < 20
                let atTop = metrics.offset <= 2
                let atBottom = scrollable <= 0 || fromBottom <= 2
                if scrollState.isAtTop != atTop { scrollState.isAtTop = atTop }
                if scrollState.isAtBottomEdge != atBottom { scrollState.isAtBottomEdge = atBottom }
            }
            // A new message: bring it to the top, once. The reply then streams into
            // the padded space below it. Opening a past conversation lands on the
            // same spot, without the animation.
            .onChange(of: lastUserTurnID) { _, id in
                guard let id else { return }
                scrollState.isNearBottom = true
                withAnimation(chatVM.isStreaming ? OakStyle.Motion.slow : nil) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            // The one follow. The thread's height is constant until the reply
            // outgrows the viewport, so this fires only after that, and only while
            // the reader is still at the bottom.
            .onChange(of: scrollState.contentHeight) { old, new in
                guard new > old, chatVM.isStreaming, scrollState.isNearBottom else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var lastUserTurnID: Turn.ID? {
        chatVM.turns.last { $0.role == .user }?.id
    }

    // MARK: - Input Bar

    @State private var inputContentHeight: CGFloat = ChatInputTextView.minContentHeight
    @State private var inputFocusRef = ChatInputTextView.FocusRef()

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
                atItems: chatVM.atMentionItems,
                onActiveTokensChanged: { tokens in chatVM.activeTokens = tokens },
                resetToken: chatVM.inputResetToken,
                fontSize: bodyFontSize,
                focusRef: inputFocusRef
            )
            .frame(height: inputContentHeight)
            .padding(.horizontal, 14)
            // Match the note composer's 8pt top breathing room (NoteComposerBox) so the
            // two right-panel input boxes feel consistent.
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Bottom row: attachment + send
            HStack(spacing: 6) {
                // Single attachment entry point — mirrors Dia's command bar,
                // where every attach type funnels through one borderless "+".
                Button {
                    inputFocusRef.textView?.toggleAttachmentMenu(items: attachmentMenuItems)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .accessibilityLabel(Text("Add attachment"))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Add attachment")

                Spacer()

                settingsMenu

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
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: ChatComposerStyle.cornerRadius, style: .continuous)
                .fill(OakStyle.Colors.diaSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatComposerStyle.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(ChatComposerStyle.borderOpacity), lineWidth: ChatComposerStyle.borderWidth)
        )
        .background {
            ChatComposerAnchor(focusRef: inputFocusRef)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 3)
        .padding(.horizontal, presentation == .canvas ? 0 : OakStyle.Spacing.sm)
        .padding(.bottom, presentation == .canvas ? OakStyle.Spacing.md : OakStyle.Spacing.xs)
        .padding(.top, OakStyle.Spacing.xs)
    }

    private var attachmentMenuItems: [CardMenuItem] {
        var items = [CardMenuItem(title: String(localized: "Upload File"), icon: "arrow.up.doc", action: uploadFile)]
        if chatVM.parent != nil {
            items.append(CardMenuItem(title: String(localized: "Attach Page"), icon: "doc.viewfinder") {
                chatVM.addDocumentPageSnapshot()
            })
            items.append(CardMenuItem(title: String(localized: "Capture Region"), icon: "viewfinder") {
                chatVM.parent?.beginAreaCaptureForChat()
            })
        }
        return items
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
        let pair = AIProviderCatalog.shared.availableModels.first { $0.model.id == settingsModel }
        return pair?.model.name ?? settingsModel
    }

    @State private var settingsModel: String = {
        let prefs = Preferences.shared
        let catalog = AIProviderCatalog.shared
        // Honor the stored model only when it's actually available (configured provider,
        // not toggled off); otherwise fall back to the resolved provider's default so the
        // picker never shows a model from a vendor the user hasn't set up.
        if !prefs.aiModel.isEmpty,
           catalog.availableModels.contains(where: { $0.model.id == prefs.aiModel }) {
            return prefs.aiModel
        }
        let pid = catalog.resolvedProviderId(preferred: prefs.aiProviderId)
        return catalog.provider(for: pid)?.defaultModel ?? ""
    }()
    @State private var settingsEffort: String = Preferences.shared.thinkingEffort
    @State private var settingsPermission: AgentPermissionLevel = Preferences.shared.agentPermissionLevel

    private var settingsMenu: some View {
        let prefs = Preferences.shared
        let catalog = AIProviderCatalog.shared
        let configuredProviders = catalog.configuredProviders
        let currentModel = settingsModel
        let currentModelInfo = catalog.availableModels.first { $0.model.id == currentModel }?.model
        let modelSelection = Binding<String>(
            get: { currentModel },
            set: { newValue in
                prefs.aiModel = newValue
                settingsModel = newValue
                // Auto-switch provider when selecting a model from a different provider
                if let pair = AIProviderCatalog.shared.availableModels.first(where: { $0.model.id == newValue }) {
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
                        Section(provider.name) {
                            ForEach(models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                }
            } label: {
                OakLabel("Model", systemImage: "cpu")
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
                    OakLabel("Thinking", systemImage: "brain")
                }
            }

            Picker(selection: permissionSelection) {
                ForEach(AgentPermissionLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            } label: {
                OakLabel("Permission", systemImage: "wrench")
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentModelName)
                    .font(OakStyle.ChatFont.modelLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // One chevron, pointing the way the menu opens. The up/down pair says
                // "cycle through values", which is a stepper's promise — this opens a
                // menu, and every value in it is visible at once.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // The padding outlives the capsule it used to sit inside: it is the click
            // target now, and a borderless label with none would be a smaller thing to
            // hit than the bordered one was. `contentShape` makes the whole inset area
            // clickable rather than just the glyphs.
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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

// MARK: - Thread layout

/// Marks the first view of the thread's last exchange: the newest user message.
private struct StartsThreadTail: LayoutValueKey {
    static let defaultValue = false
}

/// A vertical stack whose last exchange is at least one viewport tall.
///
/// The padding goes after the last view, so scrolling the newest user message
/// to the top always has room, and the reply below it grows into that padding
/// instead of growing the content. The content height stays constant until the
/// reply is taller than the viewport, which is what lets the thread hold still
/// while it streams.
///
/// A layout, not two stacks for "history" and "tail": moving a turn from one
/// stack to the other on each send would rebuild its NSTextView.
private struct ChatThreadLayout: Layout {
    var spacing: CGFloat
    var viewportHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let heights = rowHeights(width: width, subviews: subviews)
        let content = stackHeight(heights[...])
        let tailStart = subviews.firstIndex { $0[StartsThreadTail.self] }
        let tail = tailStart.map { stackHeight(heights[$0...]) } ?? 0
        let padding = tailStart == nil ? 0 : max(viewportHeight - tail, 0)
        return CGSize(width: width, height: content + padding)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height + spacing
        }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    private func stackHeight(_ heights: ArraySlice<CGFloat>) -> CGFloat {
        heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
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

// MARK: - Chat scroll state / scrollbar

/// Holds live scroll position outside the chat view's `body`. Only `ChatScrollbar`
/// reads `offset`/`barOpacity`, so a scroll (which fires the metrics preference
/// every frame) re-renders just the scrollbar capsule — the eager message list is
/// never invalidated by scrolling. `isNearBottom` is observation-ignored because it
/// is only read inside event closures, never in a `body`.
@MainActor
@Observable
final class ChatScrollState {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewHeight: CGFloat = 0
    var barOpacity: Double = 0
    /// Scroll-edge state for the feather mask. Observed (unlike `offset`) because it
    /// changes a handful of times per scroll, not every frame, so reading it in the
    /// message list does not re-render the list on each frame.
    var isAtTop = true
    var isAtBottomEdge = true
    @ObservationIgnored var isNearBottom = true

    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = Date()

    /// Show the scrollbar and (re)arm a single fade-out. Cheap to call every scroll
    /// frame: it bumps a timestamp and reuses one task, instead of allocating and
    /// cancelling a Task per frame as the old per-frame `showScrollBar()` did.
    func registerActivity() {
        lastActivity = .now
        if barOpacity != 1 { barOpacity = 1 }
        guard fadeTask == nil else { return }
        fadeTask = Task { @MainActor [weak self] in
            while true {
                let idle: Double
                if let self { idle = Date.now.timeIntervalSince(self.lastActivity) } else { return }
                if idle >= 1.2 { break }
                try? await Task.sleep(for: .milliseconds(Int((1.2 - idle) * 1000) + 16))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.6)) { self.barOpacity = 0 }
            self.fadeTask = nil
        }
    }
}

/// The custom trailing scrollbar. Reads scroll position from `ChatScrollState`, so
/// it is the only view invalidated while scrolling.
private struct ChatScrollbar: View {
    let state: ChatScrollState

    var body: some View {
        GeometryReader { geo in
            let viewH = geo.size.height
            let ratio = state.contentHeight > viewH ? viewH / state.contentHeight : 1
            let thumbH = max(ratio * viewH, 28)
            let maxTravel = max(viewH - thumbH, 0)
            let scrollable = state.contentHeight - viewH
            let progress = scrollable > 0 ? min(max(state.offset / scrollable, 0), 1) : 0
            let thumbY = progress * maxTravel

            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 3, height: thumbH)
                .offset(y: thumbY)
                .padding(.trailing, 1.5)
                .opacity(ratio < 1 ? state.barOpacity : 0)
                .animation(.easeOut(duration: 0.15), value: state.barOpacity)
                .onAppear { state.viewHeight = viewH }
                .onChange(of: geo.size.height) { _, h in state.viewHeight = h }
        }
    }
}

/// Measures the composer's outer border for both input menus.
private struct ChatComposerAnchor: NSViewRepresentable {
    let focusRef: ChatInputTextView.FocusRef

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        focusRef.composerView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        focusRef.composerView = nsView
    }
}

/// The open chat's title in the panel header.
///
/// - A long title fades out at the right edge instead of ending in an
///   ellipsis, as in Gemini's side panel: the words that fit stay whole.
/// - A new title cross-fades in over 0.3 s (Cursor's title transition).
/// - Double-click, or "Rename Chat" in the context menu, edits it in place,
///   as in Cursor: Return or clicking away saves, Escape cancels, and an
///   empty name is ignored.
private struct SessionTitleView: View {
    let title: String
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Chat name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(OakStyle.ChatFont.headerTitle)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused && isEditing { commit() }
                    }
                    .onAppear { fieldFocused = true }
            } else {
                Text(title)
                    .font(OakStyle.ChatFont.headerTitle)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEditing)
                    .contextMenu {
                        Button("Rename Chat", action: beginEditing)
                    }
                    .help(title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginEditing() {
        draft = title
        isEditing = true
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        if !name.isEmpty, name != title { onRename(name) }
    }
}

