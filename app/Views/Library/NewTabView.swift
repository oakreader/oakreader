import SwiftUI

/// New-tab omnibox. A centered unified field that resolves typed text to one of
/// two destinations — navigate to a URL, or run a web search with the user's
/// default search engine. As the user types, the candidate routes show as a
/// suggestion list; the submit button is relabeled to the selected action.
struct NewTabView: View {
    let viewModel: DocumentViewModel

    @State private var text: String = ""
    @State private var selectedIndex: Int = 0
    @State private var fieldFocused: Bool = false
    @Namespace private var highlight

    private let contentWidth: CGFloat = 640

    private var searchEngine: BrowserSearchEngine {
        Preferences.shared.browserSearchEngine
    }

    private var routes: [BrowserSession.Route] {
        BrowserSession.routes(for: text)
    }

    private var selectedRoute: BrowserSession.Route? {
        let r = routes
        guard !r.isEmpty else { return nil }
        return r[min(selectedIndex, r.count - 1)]
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            OakAppIcon(size: 44)

            omnibox
                .frame(maxWidth: contentWidth)

            if text.isEmpty {
                Text("Search the web or open a link.")
                    .font(OakStyle.Font.styled(size: 13))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fieldFocused = true }
        }
        .onChange(of: text) { _, _ in selectedIndex = 0 }
    }

    // MARK: - Omnibox

    private var omnibox: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.tertiary)
                OmniboxField(
                    text: $text,
                    isFocused: $fieldFocused,
                    placeholder: "Search or enter address…",
                    font: OakStyle.Font.nsFont(size: 20),
                    onMoveUp: { moveSelection(-1) },
                    onMoveDown: { moveSelection(1) },
                    onSubmit: submit
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            if !routes.isEmpty {
                Divider().overlay(OakStyle.Colors.diaHairline)

                // Suggestions
                VStack(spacing: 2) {
                    ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                        suggestionRow(route, isSelected: index == min(selectedIndex, routes.count - 1))
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                guard hovering, selectedIndex != index else { return }
                                withAnimation(.easeOut(duration: 0.13)) { selectedIndex = index }
                            }
                            .onTapGesture { submit(route: route) }
                    }
                }
                .padding(8)

                // Action row
                HStack {
                    Spacer()
                    submitButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(OakStyle.Colors.diaHairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private func suggestionRow(_ route: BrowserSession.Route, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            rowIcon(for: route)
                .frame(width: 20)
            rowLabel(for: route)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(actionLabel(for: route))
                .font(OakStyle.Font.styled(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
                    .matchedGeometryEffect(id: "omniboxSelection", in: highlight)
            }
        }
    }

    @ViewBuilder
    private func rowLabel(for route: BrowserSession.Route) -> some View {
        switch route {
        case .search:
            Text(text)
                .font(OakStyle.Font.styled(size: 14))
                .foregroundStyle(.primary)
        case .navigate(let url):
            HStack(spacing: 0) {
                Text("Go to ")
                    .foregroundStyle(.secondary)
                Text(url.host ?? url.absoluteString)
                    .foregroundStyle(.primary)
            }
            .font(OakStyle.Font.styled(size: 14))
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            HStack(spacing: 5) {
                Text(selectedRoute.map(actionLabel) ?? "Go")
                    .font(OakStyle.Font.styled(size: 13, weight: .medium))
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color(nsColor: .textBackgroundColor))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(text.isEmpty ? Color.gray.opacity(0.35) : Color.primary))
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
    }

    // MARK: - Labels & icons

    @ViewBuilder
    private func rowIcon(for route: BrowserSession.Route) -> some View {
        switch route {
        case .search:
            // The search route hands off to the user's default search engine, so
            // brand the row with that engine's mark when one ships in the asset
            // catalog; otherwise fall back to a generic magnifying glass.
            if let asset = searchEngine.iconAsset {
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .accessibilityLabel(searchEngine.displayName)
            } else {
                symbolIcon("magnifyingglass")
            }
        case .navigate:
            symbolIcon("globe")
        }
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
    }

    private func actionLabel(for route: BrowserSession.Route) -> String {
        switch route {
        case .search: return searchEngine.displayName
        case .navigate: return "Go"
        }
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) {
        let count = routes.count
        guard count > 0 else { return }
        withAnimation(.easeOut(duration: 0.13)) {
            selectedIndex = max(0, min(count - 1, selectedIndex + delta))
        }
    }

    private func submit() {
        guard let route = selectedRoute else { return }
        submit(route: route)
    }

    private func submit(route: BrowserSession.Route) {
        viewModel.appState?.routeNewTab(route, from: viewModel)
        text = ""
        selectedIndex = 0
    }
}

// MARK: - AppKit-backed omnibox field
//
// A plain SwiftUI `TextField` swallows ↑/↓ in its field editor (the keys move the
// caret to the start/end of the text), so they never reach `.onKeyPress`. We back
// the field with `NSTextField` and intercept the editor's `moveUp:`/`moveDown:`/
// `insertNewline:` selectors to drive suggestion-list navigation instead.
private struct OmniboxField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let font: NSFont
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = font

        if isFocused,
           let window = field.window,
           window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        init(_ parent: OmniboxField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            default:
                return false
            }
        }
    }
}
