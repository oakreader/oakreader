import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Delegate

protocol QuickChatPanelDelegate: AnyObject {
    func quickChatPanel(_ panel: QuickChatPanel, run skill: QuickChatSkill)
    func quickChatPanel(
        _ panel: QuickChatPanel, deliver destination: QuickChatDestination, text: String
    )
    func quickChatPanel(_ panel: QuickChatPanel, refine instruction: String)
    func quickChatPanelStopRequested(_ panel: QuickChatPanel)
    func quickChatPanelDidDismiss(_ panel: QuickChatPanel)
}

// MARK: - Panel

/// A thin `NSPanel` host for `QuickChatPanelView`, the same pattern as
/// `CommandPalettePanel`: the panel floats above the main window so it covers
/// `NSViewRepresentable`-hosted content (PDFView / WKWebView) that a SwiftUI
/// `.overlay` cannot reliably cover, while all of the UI is SwiftUI.
///
/// `.nonactivatingPanel` + `canBecomeMain = false` means taking key focus for
/// the filter field does not deactivate the main window.
final class QuickChatPanel: NSPanel {

    weak var quickChatDelegate: QuickChatPanelDelegate?

    let model = QuickChatModel()
    private var isDismissing = false
    /// Standalone = summoned by the global hotkey over another app: the window
    /// is the card itself, not a full-size transparent backdrop, so clicks
    /// outside it still reach whatever is underneath.
    private(set) var isStandalone = false

    private var contentHeight: CGFloat = 220

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

        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onRun = { [weak self] skill in
            guard let self else { return }
            self.quickChatDelegate?.quickChatPanel(self, run: skill)
        }
        model.onRefine = { [weak self] instruction in
            guard let self else { return }
            self.quickChatDelegate?.quickChatPanel(self, refine: instruction)
        }
        model.onStop = { [weak self] in
            guard let self else { return }
            self.quickChatDelegate?.quickChatPanelStopRequested(self)
        }
        model.onDeliver = { [weak self] destination, text in
            guard let self else { return }
            self.quickChatDelegate?.quickChatPanel(self, deliver: destination, text: text)
        }

        model.onCardHeight = { [weak self] height in
            self?.resizeStandalone(toCardHeight: height)
        }

        let host = NSHostingView(rootView: QuickChatPanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    // MARK: - Present / Dismiss

    func present(relativeTo parentWindow: NSWindow, capture: QuickChatCapture) {
        isDismissing = false
        isStandalone = false
        model.isStandalonePresentation = false
        resetState(capture: capture)

        setFrame(parentWindow.frame, display: false)
        parentWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.requestFocus?()
            self.model.isVisible = true
        }
    }

    /// Summoned over another application. The panel takes key focus without
    /// activating OakReader, so the app the user came from stays frontmost and
    /// gets focus straight back when this hides.
    func presentStandalone(capture: QuickChatCapture) {
        isDismissing = false
        isStandalone = true
        model.isStandalonePresentation = true
        resetState(capture: capture)

        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let width = QuickChatPanelView.standaloneWidth
        let height = max(160, contentHeight)
        // Top edge at 18% of the visible height, centred — Spotlight's position,
        // and the one Cida settled on.
        let top = visible.maxY - visible.height * 0.18
        setFrame(
            NSRect(x: floor(visible.midX - width / 2), y: top - height, width: width, height: height),
            display: false
        )
        orderFrontRegardless()
        makeKey()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.requestFocus?()
            self.model.isVisible = true
        }
    }

    /// Keeps the top edge fixed and grows downward, so the source line never
    /// moves under the pointer while a result streams in.
    private func resizeStandalone(toCardHeight height: CGFloat) {
        contentHeight = height
        guard isStandalone, isVisible, height > 0 else { return }
        let current = frame
        let top = current.maxY
        let clamped = min(height, (screen ?? NSScreen.main)?.visibleFrame.height ?? height)
        guard abs(clamped - current.height) > 0.5 else { return }
        setFrame(
            NSRect(x: current.minX, y: top - clamped, width: current.width, height: clamped),
            display: true,
            animate: false
        )
    }

    private func resetState(capture: QuickChatCapture) {
        model.capture = capture
        model.query = ""
        model.selectedIndex = 0
        model.phase = .choosing
        model.resetTurns()
        model.confirmation = nil
        model.isVisible = false
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        model.isVisible = false

        let delay = reduceMotion ? 0 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isStandalone = false
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.quickChatDelegate?.quickChatPanelDidDismiss(self)
        }
    }

    // MARK: - Key handling

    /// Panel-level keys that must work while the composer holds focus. ⌘C and
    /// ⌘R only fire when there is a result to deliver, so they keep their system
    /// meaning while you are still typing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags == .command, key == "[" {
            model.backToList()
            return true
        }
        // ⌘1–⌘9 runs the nth action, as in Raycast's Actions panel.
        if flags == .command, let n = Int(key), n >= 1, n <= 9 {
            if model.phase == .choosing {
                let rows = model.rankedSkills
                guard n <= rows.count else { return true }
                model.run(rows[n - 1].skill)
            } else {
                let destinations = model.availableDestinations
                guard n <= destinations.count else { return true }
                quickChatDelegate?.quickChatPanel(self, deliver: destinations[n - 1], text: model.result)
            }
            return true
        }
        if model.phase.hasResult {
            if flags == .command, key == "r", model.capture.isWritable {
                quickChatDelegate?.quickChatPanel(self, deliver: .replace, text: model.result)
                return true
            }
            if flags == .command, key == "c" {
                quickChatDelegate?.quickChatPanel(self, deliver: .copy, text: model.result)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Arrow keys never reach `doCommandBy`: a single-line `NSTextField`'s field
    /// editor maps ↑/↓ to beginning/end-of-line instead of `moveUp:`/`moveDown:`.
    /// Taking them here, before the field editor sees them, is the only reliable
    /// place while a text field holds focus.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, model.phase == .choosing {
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                model.moveSelection(down: true)
                return
            case kVK_UpArrow:
                model.moveSelection(down: false)
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        // Clicking another window or app dismisses, as the palette does.
        if isVisible && !isDismissing { dismiss() }
    }
}
