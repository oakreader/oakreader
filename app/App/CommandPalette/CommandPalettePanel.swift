import AppKit
import SwiftUI

// MARK: - Delegate

protocol CommandPalettePanelDelegate: AnyObject {
    func commandPaletteSearchChanged(_ panel: CommandPalettePanel, text: String)
    func commandPaletteDidActivate(_ panel: CommandPalettePanel, commandID: String)
    func commandPaletteDidDismiss(_ panel: CommandPalettePanel)
}

// MARK: - Panel

/// A command palette modeled on GatherOS's QuickSwitcher (⌘K).
///
/// This is a thin `NSPanel` host: it floats above the main window (so it sits
/// correctly over AppKit-hosted content like `WKWebView` / `PDFView`, which
/// SwiftUI `.overlay`s cannot reliably cover), while all of the UI — the
/// frosted card, results list, animations — is SwiftUI in `CommandPaletteView`.
///
/// Key choices that avoid the previous AppKit-overlay pitfalls:
///   • `.nonactivatingPanel` so taking key focus for the search field does not
///     deactivate the main window (no flicker / no spurious dismissals).
///   • SwiftUI `.shadow` / `.background(.regularMaterial)` instead of a
///     hand-rolled CALayer shadow + scrim window (no rectangular shadow leak,
///     no full-window dimming bug).
final class CommandPalettePanel: NSPanel {

    weak var paletteDelegate: CommandPalettePanelDelegate?

    private let model = CommandPaletteModel()
    private var isDismissing = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the SwiftUI card draws its own shadow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        model.onSearch = { [weak self] text in
            guard let self else { return }
            self.paletteDelegate?.commandPaletteSearchChanged(self, text: text)
        }
        model.onActivate = { [weak self] id in
            guard let self else { return }
            self.paletteDelegate?.commandPaletteDidActivate(self, commandID: id)
        }
        model.onDismiss = { [weak self] in self?.dismiss() }

        let host = NSHostingView(rootView: CommandPaletteView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    // MARK: - Present / Dismiss

    func present(relativeTo parentWindow: NSWindow) {
        isDismissing = false
        model.query = ""
        model.selectedIndex = model.sections.isEmpty ? -1 : 0
        model.isVisible = false

        setFrame(parentWindow.frame, display: false)
        parentWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)

        // Focus the search field and trigger the pop-in on the next tick, so the
        // card animates from its hidden state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.requestFocus?()
            self.model.isVisible = true
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        model.isVisible = false

        let delay = reduceMotion ? 0 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.paletteDelegate?.commandPaletteDidDismiss(self)
        }
    }

    // MARK: - Update Rows

    /// Populate the palette with grouped command sections. Pass an
    /// `emptyMessage` (and no sections) to show the empty state instead.
    func updateSections(_ sections: [PaletteSection], emptyMessage: String?) {
        model.sections = sections
        model.emptyMessage = emptyMessage
        model.selectedIndex = sections.isEmpty ? -1 : 0
    }

    // MARK: - Key handling

    override func resignKey() {
        super.resignKey()
        // Clicking another window/app dismisses the palette.
        if isVisible && !isDismissing { dismiss() }
    }
}
