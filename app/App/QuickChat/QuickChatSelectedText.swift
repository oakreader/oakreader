import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the selection out of whatever application is frontmost.
///
/// This is the spec's §3 pipeline, and almost every step exists because
/// something broke without it. The structure follows Cida's
/// `Sources/Cida/SelectedText.swift`, which is the reference implementation for
/// this problem on macOS.
enum QuickChatSelectedText {

    /// What the frontmost application said.
    enum Answer {
        case selection(String)
        /// The focused element has nothing selected. The selection may still be
        /// elsewhere — Telegram keeps focus in the composer while text in a
        /// message is selected — so `elementText` carries what the element
        /// holds, for the whole-line check.
        case nothingSelected(elementText: String?)
        /// No focused element, or it does not offer `kAXSelectedText`.
        case unreadable
        /// Nothing may be read: a password field, OakReader itself, secure
        /// input, or no Accessibility permission.
        case withheld
    }

    /// What a capture can write back through.
    struct Target {
        let element: AXUIElement
        /// False when the element reported it cannot be edited.
        let isWritable: Bool
        /// The owning application, so focus can be handed back before pasting.
        let pid: pid_t
    }

    struct Result {
        let text: String
        let target: Target?
        let appName: String?
        let appBundleID: String?
        /// The AX role of the focused element, e.g. `AXTextArea`. Tier 1 context.
        let role: String?
    }

    /// Accessibility reads get this long; a slower app would not copy in time
    /// either, so it is not asked to.
    private static let readDeadline: TimeInterval = 0.15
    /// How long to wait for the synthetic ⌘C to land.
    private static let copyDeadline: TimeInterval = 0.05
    private static let messagingTimeout: Float = 0.1

    // MARK: - Entry point

    /// Reads the frontmost app's selection, falling back to a synthetic ⌘C when
    /// the focused element cannot answer. Must be called on the main thread,
    /// before the panel takes key focus.
    static func read() -> Result? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        // Electron apps only build their accessibility tree for clients that
        // ask; the first read after this may still come back empty.
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )

        let focused = focusedElement(of: application)
        let answer = selection(of: focused)
        let role = focused.flatMap { stringAttribute($0, kAXRoleAttribute) }

        func result(_ text: String, writable: Bool) -> Result {
            Result(
                text: text,
                target: focused.map { Target(element: $0, isWritable: writable, pid: app.processIdentifier) },
                appName: app.localizedName,
                appBundleID: app.bundleIdentifier,
                role: role
            )
        }

        switch answer {
        case .withheld:
            return nil
        case .selection(let text):
            return result(text, writable: isWritable(focused))
        case .unreadable:
            guard let copied = copySelection(excluding: nil) else { return nil }
            return result(copied, writable: false)
        case .nothingSelected(let elementText):
            // Still worth copying: the selection may live outside the focused
            // element. But a bare ⌘C in VS Code copies the cursor's whole line,
            // and that line is inside the element's own text — exclude it.
            guard let copied = copySelection(excluding: elementText) else { return nil }
            return result(copied, writable: false)
        }
    }

    // MARK: - Accessibility read

    private static func focusedElement(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func selection(of element: AXUIElement?) -> Answer {
        guard let element else { return .unreadable }

        // Never read a password field.
        if let subrole = stringAttribute(element, kAXSubroleAttribute),
           subrole == kAXSecureTextFieldSubrole {
            return .withheld
        }
        // Secure input (a password prompt anywhere) also blocks the ⌘C path.
        if IsSecureEventInputEnabled() {
            return .withheld
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        )
        switch status {
        case .success:
            guard let text = value as? String else { return .unreadable }
            if let normalized = normalized(text) { return .selection(normalized) }
            return .nothingSelected(elementText: stringAttribute(element, kAXValueAttribute))
        case .noValue:
            return .nothingSelected(elementText: stringAttribute(element, kAXValueAttribute))
        default:
            return .unreadable
        }
    }

    private static func isWritable(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        return status == .success && settable.boolValue
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Copy fallback

    /// Sends ⌘C, reads the pasteboard, then puts it back exactly as it was.
    /// Returns nil when the app copied nothing, copied files or an image, or
    /// copied the cursor's whole line.
    private static func copySelection(excluding elementText: String?) -> String? {
        guard !IsSecureEventInputEnabled() else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(of: pasteboard)
        let changeCount = pasteboard.changeCount

        sendCommandC()

        // Poll until the app writes, or the deadline passes. An app that does
        // not copy (the common case with no selection) costs the full wait.
        let deadline = Date().addingTimeInterval(copyDeadline)
        while pasteboard.changeCount == changeCount, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
        }
        guard pasteboard.changeCount != changeCount else { return nil }

        let copied = plainText(on: pasteboard)
        snapshot.restore(to: pasteboard)

        guard let copied else { return nil }
        // VS Code and friends copy the whole line when nothing is selected; that
        // line is contained in the element's own text, a real selection is not.
        if let elementText, elementText.contains(copied) { return nil }
        return copied
    }

    /// Only ⌘ — the user is still holding ⌥ from the hotkey, and ⌥⌘C is
    /// "Copy Path" in Finder. The C key code is layout-independent, so Dvorak
    /// still produces ⌘C.
    private static func sendCommandC() {
        postCommandKey(CGKeyCode(kVK_ANSI_C))
    }

    /// Files (Finder copied a selection) or an image alone are not text.
    private static func plainText(on pasteboard: NSPasteboard) -> String? {
        let hasFiles = pasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
        guard !hasFiles else { return nil }
        return normalized(pasteboard.string(forType: .string))
    }

    // MARK: - Write-back

    /// Writes `text` over the selection in `target` through Accessibility.
    ///
    /// Works in native text views. Web content usually refuses: Chrome and
    /// Safari report `kAXSelectedText` as settable and then decline the write,
    /// so a false here is ordinary rather than exceptional — the caller pastes
    /// instead.
    @discardableResult
    static func write(_ text: String, to target: Target) -> Bool {
        guard target.isWritable else { return false }
        let status = AXUIElementSetAttributeValue(
            target.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        return status == .success
    }

    /// Replaces the selection by pasting, for the apps Accessibility cannot
    /// write to.
    ///
    /// Order matters and each step has a reason: the panel has key focus, so it
    /// is hidden first; the source application is brought back, because ⌘V goes
    /// wherever focus is and a paste into the wrong window is unrecoverable;
    /// only then is the text put on the pasteboard and the keystroke sent. The
    /// user's clipboard is restored afterwards, late enough that the paste has
    /// certainly read it.
    static func paste(_ text: String, into pid: pid_t, afterHiding hide: @escaping () -> Void) {
        guard !IsSecureEventInputEnabled() else {
            NSSound.beep()
            return
        }
        hide()

        let app = NSRunningApplication(processIdentifier: pid)
        app?.activate()

        // Long enough for focus to land before the keystroke is posted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(of: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            sendCommandV()

            // The paste reads the pasteboard asynchronously; putting the user's
            // clipboard back too early would paste their old contents instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private static func sendCommandV() {
        postCommandKey(CGKeyCode(kVK_ANSI_V))
    }

    private static func postCommandKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

}

// MARK: - Pasteboard snapshot

/// Every item on the pasteboard with the data for each of its types, so the
/// copy fallback can leave the clipboard exactly as it found it.
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    private let wasEmpty: Bool

    init(of pasteboard: NSPasteboard) {
        wasEmpty = (pasteboard.pasteboardItems ?? []).isEmpty
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !wasEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            // nspasteboard.org's convention: clipboard managers skip transient
            // contents, so putting the user's clipboard back does not log it
            // a second time.
            item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
