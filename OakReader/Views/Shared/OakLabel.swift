import SwiftUI

/// A `Label` whose accessibility label is pinned to its title, so SwiftUI never resolves
/// the SF Symbol's *default* accessibility description.
///
/// Resolving a symbol's accessibility description (`AXSwiftUIDescriptionForSymbolName`)
/// walks CFBundle localization-variant tables. On a non-base system locale (e.g. en-GB)
/// that lookup is expensive, and inside a `Menu`/`Picker` that re-renders repeatedly it
/// can pile up and peg a CPU core (observed as a beachball with RSS ballooning). Pinning
/// the accessibility label to the already-visible title short-circuits that path — and is
/// also the accessibility behaviour Apple recommends for SF Symbols (an explicit label
/// instead of the symbol's generic description).
///
/// Use this anywhere an icon+text `Label` lives in a menu, picker, or toolbar.
/// See the `sfsymbol-a11y-locale-hang` note for the original diagnosis.
func OakLabel(_ titleKey: LocalizedStringKey, systemImage: String) -> some View {
    Label(titleKey, systemImage: systemImage)
        .accessibilityLabel(Text(titleKey))
}

/// Verbatim-title overload, for runtime strings (collection names, languages, tags …).
func OakLabel(verbatim title: String, systemImage: String) -> some View {
    Label {
        Text(title)
    } icon: {
        Image(systemName: systemImage)
    }
    .accessibilityLabel(Text(title))
}
