import SwiftUI
import AppKit

/// One-row, per-document toolbar mounted just below the tab bar. Replaces the
/// `BrowserChromeView` shell: live web pages still get back/forward/reload +
/// address bar, but PDFs, HTML snapshots, and markdown notes now share the
/// same surface, with buttons gated by `contentType`.
///
/// Layout follows the Zotero pattern — three clusters separated by dividers:
/// `[nav]  │  [tools + shared color]  │  [actions]`. Each content type picks
/// which clusters it wants; the tools cluster is only shown when the viewer
/// supports text-markup annotations (PDF, HTML snapshot).
struct DocumentToolbarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            if viewModel.contentType == .link,
               let pending = viewModel.state.pendingPasswordSave {
                savePasswordBanner(pending)
            }
        }
        .background(OakStyle.Colors.activeTabBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var toolbarRow: some View {
        switch viewModel.contentType {
        case .pdf:      pdfToolbar
        case .html:     htmlSnapshotToolbar
        case .link:     linkToolbar
        case .markdown: markdownToolbar
        case .audio:    EmptyView()
        }
    }
}

// MARK: - PDF toolbar

private extension DocumentToolbarView {
    var pdfToolbar: some View {
        HStack(spacing: 6) {
            sidebarToggle
            Divider().frame(height: 18)
            pageNavGroup

            Spacer(minLength: 8)

            zoomGroup

            Spacer(minLength: 8)

            Divider().frame(height: 18)
            annotationToolsGroup
            colorSwatch
            Divider().frame(height: 18)

            findButton
            rightPanelToggle
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    var pageNavGroup: some View {
        let viewer = viewModel.viewer
        return HStack(spacing: 2) {
            OakToolButton(systemImage: "chevron.left", tooltip: "Previous Page") {
                viewer.previousPage()
            }
            .disabled(!viewer.canGoToPreviousPage)
            .opacity(viewer.canGoToPreviousPage ? 1 : 0.4)

            OakToolButton(systemImage: "chevron.right", tooltip: "Next Page") {
                viewer.nextPage()
            }
            .disabled(!viewer.canGoToNextPage)
            .opacity(viewer.canGoToNextPage ? 1 : 0.4)

            PageNumberField(viewModel: viewModel)
        }
    }

    var zoomGroup: some View {
        let viewer = viewModel.viewer
        return HStack(spacing: 2) {
            OakToolButton(systemImage: "minus.magnifyingglass", tooltip: "Zoom Out") {
                viewer.zoomOut()
            }
            Text(viewer.zoomPercentage)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
            OakToolButton(systemImage: "plus.magnifyingglass", tooltip: "Zoom In") {
                viewer.zoomIn()
            }
            OakToolButton(
                systemImage: "arrow.up.left.and.arrow.down.right.magnifyingglass",
                tooltip: "Fit to Width"
            ) {
                viewer.zoomToFit()
            }
        }
    }
}

// MARK: - HTML snapshot toolbar

private extension DocumentToolbarView {
    var htmlSnapshotToolbar: some View {
        HStack(spacing: 6) {
            sidebarToggle

            Spacer(minLength: 8)

            Divider().frame(height: 18)
            annotationToolsGroup
            colorSwatch
            Divider().frame(height: 18)

            rightPanelToggle
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

// MARK: - Link toolbar (live web pages and embed cards)

private extension DocumentToolbarView {
    /// Live web pages keep the full browser chrome: back / forward / reload +
    /// editable address bar + save-to-Reading-List. Embed cards (no `liveURL`)
    /// just get the sidebar + right-panel anchors.
    @ViewBuilder
    var linkToolbar: some View {
        if viewModel.liveURL != nil || viewModel.state.currentURL != nil || viewModel.isNewTab {
            LiveWebToolbarContent(viewModel: viewModel)
        } else {
            HStack(spacing: 6) {
                sidebarToggle
                Spacer()
                rightPanelToggle
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }
}

// MARK: - Markdown toolbar

private extension DocumentToolbarView {
    var markdownToolbar: some View {
        HStack(spacing: 6) {
            sidebarToggle
            Spacer()
            rightPanelToggle
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

// MARK: - Shared anchors and groups

private extension DocumentToolbarView {
    var sidebarToggle: some View {
        OakToolButton(
            systemImage: "sidebar.left",
            isSelected: viewModel.state.isSidebarVisible,
            tooltip: viewModel.state.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        ) {
            viewModel.state.isSidebarVisible.toggle()
        }
    }

    var rightPanelToggle: some View {
        OakToolButton(
            systemImage: "sidebar.right",
            isSelected: viewModel.state.rightPanelMode != nil,
            tooltip: viewModel.state.rightPanelMode != nil ? "Hide Inspector" : "Show Inspector"
        ) {
            if viewModel.state.rightPanelMode != nil {
                viewModel.state.rightPanelMode = nil
            } else {
                viewModel.state.rightPanelMode = .aiChat
            }
        }
    }

    var findButton: some View {
        OakToolButton(
            systemImage: "magnifyingglass",
            isSelected: viewModel.state.sidebarMode == .search && viewModel.state.isSidebarVisible,
            tooltip: "Find in Document"
        ) {
            viewModel.state.sidebarMode = .search
            viewModel.state.isSidebarVisible = true
        }
    }

    /// Highlight / underline / area-selection — internally each button drives the
    /// existing `editorMode` + `currentTool` pair the PDFViewCoordinator already
    /// observes. The mode is an implementation detail; from the user's POV they
    /// just pick a tool.
    var annotationToolsGroup: some View {
        HStack(spacing: 2) {
            annotationToolButton(.highlight, systemImage: "highlighter", tooltip: "Highlight")
            annotationToolButton(.underline, systemImage: "underline", tooltip: "Underline")
            areaSelectionButton
        }
    }

    @ViewBuilder
    func annotationToolButton(
        _ tool: AnnotationTool,
        systemImage: String,
        tooltip: String
    ) -> some View {
        let isActive = viewModel.state.editorMode == .annotate
            && viewModel.annotation.currentTool == tool
        OakToolButton(systemImage: systemImage, isSelected: isActive, tooltip: tooltip) {
            toggleAnnotationTool(tool)
        }
    }

    var areaSelectionButton: some View {
        let isActive = viewModel.state.editorMode == .snapshot
        return OakToolButton(
            systemImage: "rectangle.dashed",
            isSelected: isActive,
            tooltip: "Area Selection"
        ) {
            if isActive {
                viewModel.setEditorMode(.viewer)
            } else {
                viewModel.setEditorMode(.snapshot)
            }
        }
    }

    func toggleAnnotationTool(_ tool: AnnotationTool) {
        let isActive = viewModel.state.editorMode == .annotate
            && viewModel.annotation.currentTool == tool
        if isActive {
            viewModel.annotation.currentTool = .none
            viewModel.setEditorMode(.viewer)
        } else {
            viewModel.annotation.currentTool = tool
            viewModel.setEditorMode(.annotate)
        }
    }

    /// Single swatch reflecting the active tool's stroke color (Zotero pattern,
    /// not Preview's per-attribute color triplet). Clicking pops a palette.
    var colorSwatch: some View {
        ColorSwatchButton(viewModel: viewModel)
    }
}

// MARK: - Page-number field (PDF)

private struct PageNumberField: View {
    @Bindable var viewModel: DocumentViewModel
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 36)
                .focused($focused)
                .onSubmit(commit)
                .onAppear { syncFromState() }
                .onChange(of: viewModel.state.currentPageIndex) { _, _ in
                    if !focused { syncFromState() }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { syncFromState() }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                        .fill(OakStyle.Colors.hoverBackground)
                }
            Text("/ \(viewModel.pageCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func syncFromState() {
        text = "\(viewModel.state.currentPageIndex + 1)"
    }

    private func commit() {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            syncFromState()
            return
        }
        viewModel.viewer.goToPage(value - 1)
        focused = false
    }
}

// MARK: - Color swatch

private struct ColorSwatchButton: View {
    @Bindable var viewModel: DocumentViewModel
    @State private var showPalette = false
    @State private var isHovering = false

    var body: some View {
        Button {
            showPalette = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: viewModel.annotation.strokeColor))
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                    )
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .fill(isHovering ? OakStyle.Colors.hoverBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Annotation Color")
        .background(TooltipTrigger(tooltip: "Annotation Color"))
        .popover(isPresented: $showPalette, arrowEdge: .bottom) {
            ColorPalettePopover { color in
                viewModel.annotation.strokeColor = color
                showPalette = false
            }
        }
    }
}

private struct ColorPalettePopover: View {
    let onPick: (NSColor) -> Void

    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 6)]
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(OakStyle.AnnotationColors.allColors, id: \.name) { entry in
                Button {
                    onPick(entry.nsColor)
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(entry.color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(entry.name)
            }
        }
        .padding(8)
    }
}

// MARK: - Live web toolbar (preserves prior BrowserChromeView behavior)

/// Extracted into its own view so the address-field focus state and the
/// save-to-Reading-List task state don't leak into the parent toolbar's body.
private struct LiveWebToolbarContent: View {
    let viewModel: DocumentViewModel

    @State private var addressText: String = ""
    @FocusState private var addressFocused: Bool
    @State private var saveState: SaveState = .idle

    private enum SaveState { case idle, saving, saved, failed }

    private var state: DocumentState { viewModel.state }
    private var isLoading: Bool { state.webLoadProgress > 0 && state.webLoadProgress < 1 }

    var body: some View {
        HStack(spacing: 6) {
            sidebarToggle

            OakToolButton(systemImage: "chevron.left", tooltip: "Back") {
                post(.webViewGoBack)
            }
            .disabled(!state.canGoBack)
            .opacity(state.canGoBack ? 1 : 0.4)

            OakToolButton(systemImage: "chevron.right", tooltip: "Forward") {
                post(.webViewGoForward)
            }
            .disabled(!state.canGoForward)
            .opacity(state.canGoForward ? 1 : 0.4)

            OakToolButton(
                systemImage: isLoading ? "xmark" : "arrow.clockwise",
                tooltip: isLoading ? "Stop" : "Reload"
            ) {
                post(isLoading ? .webViewStop : .webViewReload)
            }

            addressField
            saveButton
            rightPanelToggle
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .onChange(of: state.currentURL) { _, newURL in
            if !addressFocused { addressText = newURL?.absoluteString ?? "" }
            saveState = .idle
        }
        .onAppear {
            addressText = state.currentURL?.absoluteString ?? ""
        }
    }

    private var sidebarToggle: some View {
        OakToolButton(
            systemImage: "sidebar.left",
            isSelected: state.isSidebarVisible,
            tooltip: state.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        ) {
            state.isSidebarVisible.toggle()
        }
    }

    private var rightPanelToggle: some View {
        OakToolButton(
            systemImage: "sidebar.right",
            isSelected: state.rightPanelMode != nil,
            tooltip: state.rightPanelMode != nil ? "Hide Inspector" : "Show Inspector"
        ) {
            if state.rightPanelMode != nil {
                state.rightPanelMode = nil
            } else {
                state.rightPanelMode = .aiChat
            }
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        switch saveState {
        case .saving:
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        default:
            OakToolButton(
                systemImage: saveState == .saved ? "bookmark.fill"
                    : (saveState == .failed ? "exclamationmark.triangle" : "bookmark"),
                isSelected: saveState == .saved,
                tooltip: saveState == .saved ? "Saved to Reading List"
                    : (saveState == .failed ? "Save failed — click to retry" : "Save to Reading List")
            ) {
                Task { await saveToReadingList() }
            }
        }
    }

    @MainActor
    private func saveToReadingList() async {
        guard let importService = viewModel.appState?.importService,
              let url = state.currentURL ?? viewModel.liveURL,
              url.scheme?.lowercased().hasPrefix("http") == true else { return }

        saveState = .saving
        let readable = await LivePageBridge.shared.extractReadable(maxChars: 1_000_000)
        let item = await importService.importBrowserLink(
            url,
            liveTitle: readable?.title,
            liveMarkdown: readable?.markdown
        )
        guard item != nil else {
            saveState = .failed
            viewModel.appState?.importNotification = "Couldn’t save to Reading List"
            return
        }
        saveState = .saved
        viewModel.appState?.importNotification = "Saved to Reading List"
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if saveState == .saved { saveState = .idle }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $addressText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($addressFocused)
            .onSubmit(navigate)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .fill(OakStyle.Colors.hoverBackground)
                    // Page-load progress fills the field from the leading edge
                    // (Safari/Arc-style) instead of a separate top bar.
                    .overlay(alignment: .leading) {
                        if isLoading {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(width: geo.size.width * state.webLoadProgress)
                                    .animation(.linear(duration: 0.15), value: state.webLoadProgress)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: OakStyle.Radius.standard))
            }
            .overlay(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .stroke(addressFocused ? Color.accentColor : .clear, lineWidth: 1)
            )
            .onExitCommand {
                addressText = state.currentURL?.absoluteString ?? ""
                addressFocused = false
            }
    }

    private func navigate() {
        guard let url = BrowserSession.resolveInput(addressText) else { return }
        addressFocused = false
        NotificationCenter.default.post(
            name: .webViewLoadURL, object: viewModel, userInfo: ["url": url]
        )
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: viewModel)
    }
}

// MARK: - Save-password banner

private extension DocumentToolbarView {
    func savePasswordBanner(_ pending: PendingPasswordSave) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
            Text("Save password for **\(pending.host)**?")
                .font(.system(size: 12))
            Spacer()
            Button("Not Now") { viewModel.state.pendingPasswordSave = nil }
                .controlSize(.small)
            Button("Save") {
                PasswordStore.save(
                    host: pending.host,
                    username: pending.username,
                    password: pending.password
                )
                viewModel.state.pendingPasswordSave = nil
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OakStyle.Colors.hoverBackground)
        .overlay(alignment: .top) { Divider() }
    }
}
