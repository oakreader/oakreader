import SwiftUI

// MARK: - Pill Tab Button

/// The app's shared "expanding pill" tab. A row of these renders the right-hand
/// title-bar panel tabs (AI Chat / Metadata / Translation / Quiz Cards), the
/// library detail tabs, and the library list/card view-mode toggle. The *active*
/// button expands into a capsule that reveals its text label; inactive ones stay
/// icon-only.
///
/// Why the label is **always** in the view tree (never `if isActive { Text }`):
/// conditionally inserting/removing the label drives SwiftUI's `.transition`
/// machinery, which gave us two bugs that no amount of duration-tuning fixed —
///  1. **double-image / "ghost"**: switching A→B cross-fades A's *removal* with
///     B's *insertion*, so two labels are briefly on screen at once.
///  2. **flash**: gating the incoming label with a delayed `.transition`
///     animation makes SwiftUI pop it to its final state for one frame (a known
///     insertion-transition quirk — see forums.swift.org/t/.../42211).
///
/// Instead the label is permanent and we animate its *width* and *opacity* as
/// continuous properties. The incoming label's animation is delayed by ~= the
/// outgoing label's collapse time, so the old one is fully gone before the new
/// one starts (no overlap) — and because the delay sits on a property animation
/// rather than a `.transition`, it does NOT trigger the insertion pop. The
/// label's natural width is measured once via a preference so the frame can
/// animate 0 ↔ width without an identity change.
struct PillTabButton: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var labelWidth: CGFloat = 0

    private var fillOpacity: Double {
        if isActive { return 0.12 }
        if isHovering { return 0.07 }
        return 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()
                    .padding(.leading, 5)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TabLabelWidthKey.self, value: proxy.size.width)
                        }
                    )
                    .frame(width: isActive ? labelWidth : 0, alignment: .leading)
                    .opacity(isActive ? 1 : 0)
                    .clipped()
            }
            .frame(height: 26)
            .padding(.leading, 9)
            .padding(.trailing, isActive ? 10 : 9)
            .frame(minWidth: 34, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .onHover { isHovering = $0 }
        .onPreferenceChange(TabLabelWidthKey.self) { labelWidth = $0 }
        // Asymmetric, bounce-0: fast collapse (0.12), and an expand that is
        // *delayed* by ~= the collapse time so the outgoing label clears first.
        // The delay is safe here only because it sits on property animations
        // (width/opacity), not on a `.transition` — see the type doc above.
        .animation(isActive ? .smooth(duration: 0.3).delay(0.13) : .smooth(duration: 0.12), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help(label)
    }
}

/// Measures a pill tab's natural (expanded) label width so it can animate
/// between 0 and that width without inserting/removing the label.
struct TabLabelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
