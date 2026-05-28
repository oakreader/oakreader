import SwiftUI

/// Browser chrome for live web pages: back / forward / reload / stop and an
/// editable address bar. Reads navigation state from `DocumentState` (kept in
/// sync by `WebViewCoordinator` via KVO) and issues commands as tab-scoped
/// notifications consumed by that coordinator.
struct BrowserChromeView: View {
    let viewModel: DocumentViewModel

    @State private var addressText: String = ""
    @FocusState private var addressFocused: Bool
    @State private var saveState: SaveState = .idle

    private enum SaveState { case idle, saving, saved, failed }

    private var state: DocumentState { viewModel.state }
    private var isLoading: Bool { state.webLoadProgress > 0 && state.webLoadProgress < 1 }

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            if let pending = state.pendingPasswordSave {
                savePasswordBanner(pending)
            }
        }
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        // Keep the address bar in sync with the page unless the user is editing it.
        .onChange(of: state.currentURL) { _, newURL in
            if !addressFocused { addressText = newURL?.absoluteString ?? "" }
            saveState = .idle   // new page → reset the save affordance
        }
        .onAppear {
            addressText = state.currentURL?.absoluteString ?? ""
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 6) {
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// Clip the current page into the library's Reading List — the in-app
    /// equivalent of the browser-extension capture.
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
        do {
            let item = try await importService.importURL(url)
            guard item != nil else { saveState = .failed; return }
            saveState = .saved
            viewModel.appState?.importNotification = "Saved to Reading List"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if saveState == .saved { saveState = .idle }
        } catch {
            saveState = .failed
            viewModel.appState?.importNotification = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    private func savePasswordBanner(_ pending: PendingPasswordSave) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
            Text("Save password for **\(pending.host)**?")
                .font(.system(size: 12))
            Spacer()
            Button("Not Now") { state.pendingPasswordSave = nil }
                .controlSize(.small)
            Button("Save") {
                PasswordStore.save(
                    host: pending.host,
                    username: pending.username,
                    password: pending.password
                )
                state.pendingPasswordSave = nil
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OakStyle.Colors.hoverBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $addressText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($addressFocused)
            .onSubmit(navigate)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .fill(OakStyle.Colors.hoverBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .stroke(addressFocused ? Color.accentColor : .clear, lineWidth: 1)
            )
            .onExitCommand {
                // Esc reverts edits back to the live URL.
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
