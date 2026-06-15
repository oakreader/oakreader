import SwiftUI
import AppKit

// MARK: - Model

/// Observable state shared between the hosting `CommandPalettePanel` (AppKit) and
/// the `CommandPaletteView` (SwiftUI). The panel wires the `on…` callbacks to its
/// delegate; the view reads/writes the published state.
@Observable
final class CommandPaletteModel {
    var query: String = ""
    var sections: [PaletteSection] = []
    var emptyMessage: String?
    var selectedIndex: Int = 0
    /// Drives the pop-in / fade-out transition.
    var isVisible: Bool = false

    // Wired by the panel.
    var onSearch: ((String) -> Void)?
    var onActivate: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    /// Set by the search field so the panel can focus it after presenting.
    var requestFocus: (() -> Void)?

    var flatCommands: [PaletteCommand] { sections.flatMap(\.commands) }

    /// Bumped only on keyboard navigation, so the view scrolls the selection
    /// into view for ↑/↓ but NOT when the mouse merely hovers a row.
    private(set) var keyboardNavTick: Int = 0

    func moveSelection(down: Bool) {
        let count = flatCommands.count
        guard count > 0 else { return }
        selectedIndex = down
            ? min(selectedIndex + 1, count - 1)
            : max(selectedIndex - 1, 0)
        keyboardNavTick += 1
    }

    func activateSelection() {
        let commands = flatCommands
        guard selectedIndex >= 0, selectedIndex < commands.count else { return }
        onActivate?(commands[selectedIndex].id)
    }
}

// MARK: - Palette View

/// The command palette UI, hosted inside a borderless `NSPanel`. Mirrors the
/// GatherOS QuickSwitcher: a top-anchored frosted-white card over an undimmed
/// click-to-dismiss backdrop.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel

    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private static let cardWidth: CGFloat = 540
    private static let searchHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 26
    private static let emptyHeight: CGFloat = 72
    private static let maxListHeight: CGFloat = 384
    private static let cornerRadius: CGFloat = 14
    private static let topFraction: CGFloat = 0.14
    /// GatherOS `--ease-pop`.
    private static let easePop = SwiftUI.Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Undimmed click target — tapping outside the card dismisses.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.onDismiss?() }

                card
                    .frame(width: Self.cardWidth)
                    .padding(.top, geo.size.height * Self.topFraction)
                    .scaleEffect(model.isVisible ? 1 : 0.985, anchor: .top)
                    .offset(y: model.isVisible ? 0 : -6)
                    .opacity(model.isVisible ? 1 : 0)
                    .animation(reduceMotion ? nil : Self.easePop, value: model.isVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            searchRow
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
            resultsArea
        }
        .background(frostedBackground)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        // Swallow clicks inside the card so they don't reach the backdrop.
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// `.regularMaterial` blur whitened with a vertical near-white gradient —
    /// GatherOS's `linear-gradient(180deg, --glass-from, --glass-to)`. Adaptive:
    /// clean white in light mode, an elevated dark panel in dark mode.
    private var frostedBackground: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay(
                LinearGradient(
                    colors: [
                        Color(nsColor: tint(light: 0.86, dark: 0.20, alphaLight: 0.86, alphaDark: 0.80)),
                        Color(nsColor: tint(light: 1.0, dark: 0.14, alphaLight: 0.74, alphaDark: 0.80)),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func tint(light: CGFloat, dark: CGFloat, alphaLight: CGFloat, alphaDark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: dark, alpha: alphaDark)
                : NSColor(white: light, alpha: alphaLight)
        }
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            PaletteSearchField(text: $model.query, model: model)
            KbdHint(text: "esc")
        }
        .padding(.horizontal, 16)
        .frame(height: Self.searchHeight)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        if model.sections.isEmpty {
            Text(model.emptyMessage ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.emptyHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // A single flattened list (headers + rows) with stable IDs.
                    // Nested ForEach keyed separately scrambles header/row pairing
                    // when the filtered sections change.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayItems) { item in
                            switch item {
                            case let .header(title, showsHairline):
                                sectionHeader(title, showsTopHairline: showsHairline)
                            case let .command(command, index):
                                rowView(command, isSelected: index == model.selectedIndex)
                                    .onHover { hovering in
                                        if hovering { model.selectedIndex = index }
                                    }
                                    .onTapGesture { model.onActivate?(command.id) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                // Scroll into view only on keyboard nav — never on mouse hover.
                .onChange(of: model.keyboardNavTick) { _, _ in
                    let commands = model.flatCommands
                    let index = model.selectedIndex
                    guard index >= 0, index < commands.count else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("cmd:\(commands[index].id)", anchor: .center)
                    }
                }
            }
            .frame(height: listHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: listHeight)
        }
    }

    /// Sections flattened into a single identified list so SwiftUI keeps each
    /// header glued to its rows across filtering.
    private enum DisplayItem: Identifiable {
        case header(title: String, showsHairline: Bool)
        case command(PaletteCommand, index: Int)

        var id: String {
            switch self {
            case let .header(title, _): return "header:\(title)"
            case let .command(command, _): return "cmd:\(command.id)"
            }
        }
    }

    private var displayItems: [DisplayItem] {
        var items: [DisplayItem] = []
        var index = 0
        for (sectionIndex, section) in model.sections.enumerated() {
            items.append(.header(title: section.title, showsHairline: sectionIndex > 0))
            for command in section.commands {
                items.append(.command(command, index: index))
                index += 1
            }
        }
        return items
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(model.flatCommands.count) * Self.rowHeight
        let headers = CGFloat(model.sections.count) * Self.headerHeight
        return min(rows + headers + 12, Self.maxListHeight)
    }

    private func sectionHeader(_ title: String, showsTopHairline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTopHairline {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 16)
                .padding(.bottom, 4)
        }
        .frame(height: Self.headerHeight, alignment: .bottomLeading)
    }

    private func rowView(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 10)
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - "esc" keyboard hint pill

private struct KbdHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Search field (AppKit-backed for reliable key handling + autofocus)

/// An `NSTextField` bridged into SwiftUI. AppKit handles the editing intents
/// (↑/↓/Enter/Esc) via `doCommandBy` — far more reliable than `.onKeyPress`
/// while a text field holds focus — and lets the panel focus the field after
/// presenting.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let model: CommandPaletteModel

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = "Type a command\u{2026}"
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator

        // Let the panel focus this field once it's in a window.
        model.requestFocus = { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.model.onSearch?(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.model.moveSelection(down: true); return true
            case #selector(NSResponder.moveUp(_:)):
                parent.model.moveSelection(down: false); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.model.activateSelection(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.model.onDismiss?(); return true
            default:
                return false
            }
        }
    }
}
