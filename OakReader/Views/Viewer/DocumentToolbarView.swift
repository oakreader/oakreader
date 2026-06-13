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
        // PDF has no per-document toolbar: zoom → ⌘=/⌘-/⌘0 (+ Command Palette),
        // highlight/underline → text-selection popup & ⌃⌘H/⌃⌘U, area capture →
        // View ▸ Capture Area (⇧⌘A). The empty full-width bar wasn't earning
        // its keep, so it's gone.
        // PDF has no per-document toolbar. Zoom → ⌘=/⌘-/⌘0 (+ Command Palette),
        // highlight/underline + color → text-selection popup & ⌃⌘H/⌃⌘U, area
        // capture → View ▸ Capture Area (⇧⌘A). HTML snapshots get a read-only
        // archive bar (badge + non-editable URL + "Open original"); live web
        // gets the editable address-bar chrome. Same WKWebView underneath —
        // only the chrome differs.
        case .pdf:      EmptyView()
        case .html:     SnapshotToolbarContent(viewModel: viewModel)
        case .link:     linkToolbar
        case .markdown: EmptyView()  // nothing toolbar-worthy yet — tab-bar anchors suffice
        case .audio:    EmptyView()
        }
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
        ToolbarPill {
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
        }
    }

    private var savePill: some View {
        ToolbarPill { saveButton }
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

// MARK: - Snapshot toolbar (read-only archive bar)

/// Read-only counterpart to `LiveWebToolbarContent`. A snapshot is the page
/// frozen at clip time — there's nowhere to navigate, so the address bar is
/// replaced by an archive badge (with capture date) + a non-editable URL. The
/// one action is "Open original", which loads the live page in a fresh tab.
private struct SnapshotToolbarContent: View {
    let viewModel: DocumentViewModel

    private var state: DocumentState { viewModel.state }

    /// Prefer the original source URL over the local `file://` snapshot path.
    private var displayURL: URL? { viewModel.html?.sourceURL ?? state.currentURL }

    private var canOpenOriginal: Bool {
        displayURL?.scheme?.lowercased().hasPrefix("http") == true
    }

    /// Warm sepia/amber — the "archived / offline" accent, kept distinct from
    /// the neutral chrome of live browsing and away from security green/red.
    private static let archiveTint = Color(red: 0.60, green: 0.43, blue: 0.18)

    var body: some View {
        HStack(spacing: 8) {
            archiveBadge

            URLLabel(url: displayURL)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canOpenOriginal {
                ToolbarPill {
                    OakToolButton(
                        systemImage: "arrow.up.right",
                        tooltip: "Open original page"
                    ) {
                        openOriginal()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var archiveBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 11))
            Text("Snapshot")
                .font(.system(size: 12, weight: .medium))
            if let date = viewModel.captureDate {
                Text("· Saved \(date.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 12))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(Self.archiveTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Self.archiveTint.opacity(0.12))
        )
    }

    private func openOriginal() {
        guard let url = displayURL, canOpenOriginal else { return }
        viewModel.appState?.openWebTab(url: url)
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
