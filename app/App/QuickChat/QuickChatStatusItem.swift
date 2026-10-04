import AppKit

/// QuickChatSkill's menu bar presence.
///
/// The global hotkey has to work when OakReader has no window open — otherwise
/// "select text in Chrome and press ⌥A" only works while the reader happens to
/// be up. A status item is what makes that legible: it shows the app is
/// listening, and gives a way in that is not a keystroke.
///
/// This is Cida's arrangement too, with one difference: Cida has no Dock icon
/// at all, whereas OakReader stays a document app that also lives in the menu
/// bar.
final class QuickChatStatusItem: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private weak var controller: QuickChatController?

    init(controller: QuickChatController) {
        self.controller = controller
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "Quick Chat"
        )
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Quick Chat — run a skill over the selected text"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    var isInstalled: Bool { statusItem != nil }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(
            title: "Run Over Selection",
            action: #selector(openPanel),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        // Says what the hotkey is without pretending the status menu owns it:
        // the real binding is the global hotkey, not this item.
        let claimed = controller?.isGlobalShortcutClaimed ?? true
        let hint = NSMenuItem(
            title: claimed
                ? "Trigger: \(QuickChatBindings.display)"
                : "\(QuickChatBindings.display) is taken by another app",
            action: claimed ? nil : #selector(openSettings),
            keyEquivalent: ""
        )
        hint.isEnabled = !claimed
        if !claimed {
            hint.target = self
            hint.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: nil
            )
        }
        menu.addItem(hint)

        if !QuickChatAccessibility.isTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(
                title: "Needs Accessibility permission",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warn.target = self
            warn.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: nil
            )
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Quick Chat Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let activate = NSMenuItem(
            title: "Open OakReader",
            action: #selector(activateApp),
            keyEquivalent: ""
        )
        activate.target = self
        menu.addItem(activate)
    }

    // MARK: - Actions

    @MainActor
    @objc private func openPanel() {
        controller?.showFromGlobalHotKey()
    }

    @MainActor
    @objc private func openAccessibilitySettings() {
        QuickChatAccessibility.openSettings()
    }

    @MainActor
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .settingsNavigateToTab, object: "extensionQuickChatSkills"
        )
        (NSApp.delegate as? AppDelegate)?.showSettingsWindow(nil)
    }

    @MainActor
    @objc private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = (NSApp.delegate as? AppDelegate)?.appState.window {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
