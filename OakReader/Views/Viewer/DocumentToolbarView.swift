import SwiftUI
import AppKit

/// One-row, per-document toolbar. Mounted inside `ContentView`'s main content
/// **column** (not at window width), so the left sidebar and right panel both
/// extend from below the tab bar all the way down — Xcode/Mail/Notes pattern.
/// Holds only content-specific controls (page nav, zoom, annotation tools,
/// address bar).
///
/// **Why no sidebar / right-panel toggles here.** OakReader's tab bar already
/// hosts those window-level anchors (sidebar toggle on the left, right-panel
/// mode tabs on the right — see `TabBarView`). Duplicating them in the toolbar
/// would be the literal Zotero/Preview pattern, but it competes with the
/// existing chrome instead of complementing it. So this toolbar deliberately
/// owns *only* the per-document affordances; the title bar owns the panels.
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
        case .markdown: EmptyView()  // nothing toolbar-worthy yet — tab-bar anchors suffice
        case .audio:    EmptyView()
        }
    }
}

// MARK: - PDF toolbar

private extension DocumentToolbarView {
    /// `[⊖ % ⊕ ↔]   [🖍 ▾] [□]`
    /// Each bracket is a capsule pill (Apple Preview / Tahoe pattern). No page
    /// field — scrolling handles motion and the page indicator lives in the
    /// status overlay. No find button — the left sidebar's search mode owns
    /// that affordance; duplicating it here violates "same vocabulary, single
    /// authoritative entry" (Kurtenbach-Buxton).
    var pdfToolbar: some View {
        HStack(spacing: 8) {
            zoomPill

            Spacer(minLength: 12)

            MarkupPill(viewModel: viewModel)
            ToolPill { areaSelectionButton }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var zoomPill: some View {
        let viewer = viewModel.viewer
        return ToolPill {
            HStack(spacing: 2) {
                OakToolButton(systemImage: "minus.magnifyingglass", tooltip: "Zoom Out") {
                    viewer.zoomOut()
                }
                Text(viewer.zoomPercentage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36)
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
}

// MARK: - HTML snapshot toolbar

private extension DocumentToolbarView {
    /// HTML snapshots get just the annotation cluster — page nav and zoom
    /// don't apply, and the title-bar anchors handle sidebar / panels.
    var htmlSnapshotToolbar: some View {
        HStack(spacing: 8) {
            Spacer()
            MarkupPill(viewModel: viewModel)
            ToolPill { areaSelectionButton }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Link toolbar (live web pages and embed cards)

private extension DocumentToolbarView {
    /// Live web pages get the full browser chrome (back / forward / reload +
    /// editable address bar + save-to-Reading-List). Embed cards (no `liveURL`)
    /// have nothing toolbar-worthy — the tab bar already supplies the panels.
    @ViewBuilder
    var linkToolbar: some View {
        if viewModel.liveURL != nil || viewModel.state.currentURL != nil {
            LiveWebToolbarContent(viewModel: viewModel)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Shared groups

private extension DocumentToolbarView {
    /// Area selection (snapshot crop). OakReader-specific — Apple Preview has
    /// no equivalent; it uses the Shapes tool's filled rectangle for a
    /// visually-similar "area highlight," which is a different concept (a
    /// persistent annotation vs. a one-shot crop). Lives in its own pill.
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
}

// MARK: - Capsule pill container

/// Thin wrapper that puts arbitrary toolbar content inside a soft capsule
/// background — Apple Preview / Tahoe pattern. Use it once per "tool concept":
/// either a single button (e.g. find, area) or a tight group of related
/// controls (e.g. zoom +/–/fit).
private struct ToolPill<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(OakStyle.Colors.hoverBackground)
            )
    }
}

// MARK: - Markup pill (highlighter + chevron + popover)

/// Apple Preview / Tahoe pattern: one pill combining the active markup tool's
/// button with a chevron that opens a popover containing color choices and
/// markup-type variants (Underline). Replaces the separate highlight /
/// underline / color-swatch buttons — they were three pills' worth of chrome
/// for what is really one "what kind of mark do I want to make" decision.
private struct MarkupPill: View {
    @Bindable var viewModel: DocumentViewModel
    @State private var showMenu = false

    private var currentTool: AnnotationTool { viewModel.annotation.currentTool }
    private var isAnnotating: Bool {
        viewModel.state.editorMode == .annotate && currentTool != .none
    }

    /// The pill's icon reflects the last-used markup tool, so the user sees
    /// which markup type they're about to apply at a glance.
    private var icon: String {
        switch currentTool {
        case .underline: return "underline"
        default:         return "highlighter"
        }
    }

    private var tooltip: String {
        switch currentTool {
        case .underline: return isAnnotating ? "Stop Underline" : "Underline"
        default:         return isAnnotating ? "Stop Highlight" : "Highlight"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            OakToolButton(
                systemImage: icon,
                isSelected: isAnnotating,
                tooltip: tooltip
            ) {
                toggleMarkup()
            }

            ChevronButton {
                showMenu = true
            }
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                MarkupMenu(viewModel: viewModel) { showMenu = false }
            }
            .foregroundStyle(activeAccentForeground)
        }
        .padding(.horizontal, 2)
        .background(
            Capsule(style: .continuous)
                .fill(OakStyle.Colors.hoverBackground)
        )
    }

    private var activeAccentForeground: Color {
        isAnnotating ? Color.accentColor : Color(nsColor: .labelColor)
    }

    private func toggleMarkup() {
        if isAnnotating {
            viewModel.annotation.currentTool = .none
            viewModel.setEditorMode(.viewer)
        } else {
            // Re-activate the last-used tool, defaulting to highlight first time.
            let tool: AnnotationTool = (currentTool == .none) ? .highlight : currentTool
            viewModel.annotation.currentTool = tool
            viewModel.setEditorMode(.annotate)
        }
    }
}

private struct ChevronButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? OakStyle.Colors.activeBackground : .clear)
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel("Markup Options")
        .background(TooltipTrigger(tooltip: "Markup Options"))
    }
}

private struct MarkupMenu: View {
    @Bindable var viewModel: DocumentViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(OakStyle.AnnotationColors.allColors, id: \.name) { entry in
                colorRow(name: entry.name, color: entry.color, nsColor: entry.nsColor)
            }

            Divider().padding(.vertical, 4)

            toolRow(.underline, label: "Underline", systemImage: "underline")
        }
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private func colorRow(name: String, color: Color, nsColor: NSColor) -> some View {
        let isSelected = colorsAreClose(viewModel.annotation.strokeColor, nsColor)
        return Button {
            // Picking a color implicitly switches into markup mode with the
            // highlight tool if we weren't already annotating — matches Preview.
            viewModel.annotation.strokeColor = nsColor
            if viewModel.state.editorMode != .annotate || viewModel.annotation.currentTool == .none {
                viewModel.annotation.currentTool = .highlight
                viewModel.setEditorMode(.annotate)
            }
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
                Text(name)
                    .font(.system(size: 13))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolRow(_ tool: AnnotationTool, label: String, systemImage: String) -> some View {
        let isActive = viewModel.state.editorMode == .annotate
            && viewModel.annotation.currentTool == tool
        return Button {
            viewModel.annotation.currentTool = tool
            viewModel.setEditorMode(.annotate)
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 13))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func colorsAreClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let aRGB = a.usingColorSpace(.deviceRGB),
              let bRGB = b.usingColorSpace(.deviceRGB) else { return false }
        let dr = abs(aRGB.redComponent - bRGB.redComponent)
        let dg = abs(aRGB.greenComponent - bRGB.greenComponent)
        let db = abs(aRGB.blueComponent - bRGB.blueComponent)
        return dr < 0.02 && dg < 0.02 && db < 0.02
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
        HStack(spacing: 8) {
            navPill
            addressField
            savePill
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: state.currentURL) { _, newURL in
            if !addressFocused { addressText = newURL?.absoluteString ?? "" }
            saveState = .idle
        }
        .onAppear {
            addressText = state.currentURL?.absoluteString ?? ""
        }
    }

    private var navPill: some View {
        HStack(spacing: 2) {
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
        }
        .padding(.horizontal, 2)
        .background(
            Capsule(style: .continuous)
                .fill(OakStyle.Colors.hoverBackground)
        )
    }

    private var savePill: some View {
        saveButton
            .padding(.horizontal, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(OakStyle.Colors.hoverBackground)
            )
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
