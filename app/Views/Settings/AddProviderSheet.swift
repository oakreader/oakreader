import SwiftUI
import AppKit

/// Pick a provider to set up.
///
/// Shaped like Mail's "choose an account provider" sheet, which is the same
/// job: one sentence, a single-selection list, and the buttons at the bottom
/// trailing edge with the default one last. The list is filtered rather than
/// long, because twenty providers is past what anyone scans.
///
/// The parts AppKit already owns are left to AppKit. The search box is a real
/// `NSSearchField`, and the rows carry no gesture of their own: a row with a
/// double-click recognizer makes every single click wait out the double-click
/// interval before the selection moves, which reads as lag.
struct AddProviderSheet: View {
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var catalog = AIProviderCatalog.shared
    @State private var selection: String?
    @State private var query = ""

    private var matches: [BackendProviderSummary] {
        let all = catalog.unconfiguredProviders
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var cloud: [BackendProviderSummary] { matches.filter { !$0.isLocal } }
    private var local: [BackendProviderSummary] { matches.filter(\.isLocal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if matches.isEmpty {
                emptyState
            } else {
                // No header over the services: the sheet's own title already
                // says what the list is. The local servers keep one, because
                // "runs on this Mac" is the thing that sets them apart.
                List(selection: $selection) {
                    ForEach(cloud) { row($0) }
                    if !local.isEmpty {
                        Section("On This Mac") {
                            ForEach(local) { row($0) }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            buttons
        }
        .frame(width: 420, height: 460)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Provider")
                .font(.headline)
            Text("Choose a service to connect. You can change its endpoint and models afterwards.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SearchField(text: $query, onSubmit: confirm)
                .frame(height: 28)
        }
        .padding(16)
    }

    /// A row is content only. Selection, keyboard navigation and the highlight
    /// all belong to the list.
    @ViewBuilder
    private func row(_ provider: BackendProviderSummary) -> some View {
        HStack(spacing: 10) {
            ProviderIconView(
                assetName: "provider-\(provider.id)",
                fallbackSymbol: provider.isLocal ? "desktopcomputer" : "cpu",
                size: 26
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                Text(setupHint(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .tag(provider.id)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack {
            Spacer()
            Text(catalog.unconfiguredProviders.isEmpty
                 ? "Every provider is already set up."
                 : "No provider matches “\(query)”.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Continue") { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
        }
        .padding(16)
    }

    // MARK: - Actions

    /// What setting this provider up will ask for. Shown on the row so the
    /// choice is not blind: an API key and a browser sign-in are different
    /// amounts of work, and a local server needs neither.
    private func setupHint(_ provider: BackendProviderSummary) -> String {
        if provider.isLocal { return "Local server, no key" }
        if provider.auth.kind == "oauth" { return "Sign in" }
        if provider.auth.oauthAvailable { return "API key or sign-in" }
        return "API key"
    }

    private func confirm() {
        guard let selection else { return }
        onSelect(selection)
    }
}

// MARK: - Search Field

/// `NSSearchField`, unwrapped.
///
/// The system draws the magnifier, the clear button, the focus ring and the
/// capsule, clears on Escape, and keeps whatever shape the current macOS gives
/// a search field. A hand-built field has to re-implement each of those, and
/// gets the shape wrong on the next release.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.placeholderString = String(localized: "Search")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        // Return submits; every keystroke arrives through the delegate.
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() { parent.onSubmit() }
    }
}
