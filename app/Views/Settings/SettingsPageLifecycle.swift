import SwiftUI

/// Whether the settings page this view sits in is the one on screen.
///
/// Settings keeps every page it has built alive and only hides the ones not
/// selected, so a page keeps its scroll position and half-typed fields when you
/// look at another one and come back. The cost is that hiding a page no longer
/// fires `onDisappear`, which is where several pages save. Pages read this
/// value through `settingsPageLifecycle(onShow:onHide:)` instead.
extension EnvironmentValues {
    @Entry var settingsPageIsShown: Bool = true
}

private struct SettingsPageLifecycle: ViewModifier {
    @Environment(\.settingsPageIsShown) private var isShown
    let onShow: (() -> Void)?
    let onHide: (() -> Void)?

    func body(content: Content) -> some View {
        content
            // Built while selected: the first show.
            .onAppear { if isShown { onShow?() } }
            // Torn down while selected: the window closed on this page. A page
            // torn down while hidden already ran `onHide` when it was hidden.
            .onDisappear { if isShown { onHide?() } }
            .onChange(of: isShown) { _, shown in
                if shown { onShow?() } else { onHide?() }
            }
    }
}

extension View {
    /// `onAppear` / `onDisappear` for a settings page: runs when the page is
    /// selected or left, and when the window opens or closes on it.
    func settingsPageLifecycle(
        onShow: (() -> Void)? = nil,
        onHide: (() -> Void)? = nil
    ) -> some View {
        modifier(SettingsPageLifecycle(onShow: onShow, onHide: onHide))
    }
}
