import SwiftUI

/// The settings sidebar.
///
/// Modeled on Obry's settings, read from its binary: one raised selection
/// capsule (`SettingsSelectionCapsuleView` — fill, light along the top edge,
/// shadow), filled black glyphs, and muted labels that turn full ink when
/// selected. Selection is instant: a capsule sliding between rows
/// was motion for its own sake in a list you click once and leave.
struct SettingsSidebar: View {
    struct Group: Identifiable {
        let title: String?
        let tabs: [SettingsView.Tab]
        var id: String { title ?? tabs.first?.rawValue ?? "" }
    }

    let groups: [Group]
    @Binding var selection: SettingsView.Tab

    @State private var hovered: SettingsView.Tab?
    @FocusState private var isFocused: Bool

    private var orderedTabs: [SettingsView.Tab] { groups.flatMap(\.tabs) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }
                    ForEach(group.tabs) { tab in
                        row(tab)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        // Arrow keys move the selection, as they did in the `List` this replaced.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onAppear { isFocused = true }
    }

    private func row(_ tab: SettingsView.Tab) -> some View {
        let isSelected = tab == selection
        // A tap gesture, not a `Button`. Rows as buttons inside the focusable
        // sidebar had SwiftUI fire a row's action on its own after an arrow
        // key moved the selection, so ↓ bounced back or skipped rows.
        return HStack(spacing: 9) {
            icon(tab)
                .frame(width: 20, height: 20)
            Text(tab.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Self.ink : Self.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            if isSelected {
                SelectionCapsule()
            } else if hovered == tab {
                Capsule(style: .continuous)
                    .fill(OakStyle.Colors.hoverBackground)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { selection = tab }
        .onHover { inside in
            if inside { hovered = tab } else if hovered == tab { hovered = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = tab }
    }

    /// Label ink: a slate, muted when not selected. Icons are plain black
    /// (white in dark mode), filled, monochrome — the slate on the glyphs
    /// read as grey, and hierarchical mode washed some of them out entirely.
    static let ink = Color(nsColor: NSColor(name: "OakSettingsInk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xD4 / 255.0, green: 0xD8 / 255.0, blue: 0xE3 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x3E / 255.0, green: 0x46 / 255.0, blue: 0x5C / 255.0, alpha: 1)
    })
    static let inkMuted = ink.opacity(0.72)

    @ViewBuilder
    private func icon(_ tab: SettingsView.Tab) -> some View {
        if let asset = tab.iconAsset {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: tab.sidebarSymbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
        }
    }


    private func step(_ delta: Int) -> KeyPress.Result {
        let tabs = orderedTabs
        guard let index = tabs.firstIndex(of: selection) else { return .ignored }
        let next = index + delta
        guard tabs.indices.contains(next) else { return .handled }
        selection = tabs[next]
        return .handled
    }
}

/// The selection shape: an object lying on the sidebar, not a tint printed on it.
private struct SelectionCapsule: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = Capsule(style: .continuous)
        shape
            .fill(OakStyle.Surface.card)
            // Light along the top edge only: the capsule is lit from above.
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.12 : 0.9), .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 0.5
                )
            }
            .overlay { shape.strokeBorder(OakStyle.Colors.borderSubtle, lineWidth: 0.5) }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 2, y: 1)
    }
}
