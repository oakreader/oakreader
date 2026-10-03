import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey, registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon is still the only supported way to claim a key combination that fires
/// while another application is frontmost. `NSEvent.addGlobalMonitorForEvents`
/// observes but cannot consume, so the keystroke would also reach the app the
/// user is typing in.
///
/// Option-only combinations are reliable here, unlike `NSMenuItem` key
/// equivalents — which is why Cida uses ⌥A/⌥S/⌥D and why QuickChatSkill's global key can
/// be ⌥A even where its in-app menu item uses ⌃⌘A.
final class QuickChatGlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Called on the main thread when the combination fires.
    var onFire: (() -> Void)?

    /// 'OAKA' — the signature Carbon uses to tell registrations apart.
    private static let signature: OSType = 0x4F_41_4B_41
    private static let hotKeyID: UInt32 = 1

    deinit {
        // `unregister()` touches only Carbon handles, which are not actor-bound.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Claims the combination, replacing any previous one. Returns false when
    /// another application already holds it — Carbon refuses the registration
    /// rather than stealing it, so the caller can tell the user.
    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var firedID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &firedID
                )
                guard firedID.signature == QuickChatGlobalHotKey.signature else { return noErr }
                let hotKey = Unmanaged<QuickChatGlobalHotKey>.fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { hotKey.onFire?() }
                return noErr
            },
            1, &spec, context, &eventHandler
        )
        guard installStatus == noErr else { return false }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let registerStatus = RegisterEventHotKey(
            keyCode, carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        if registerStatus != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Carbon wants its own modifier bits, not `NSEvent.ModifierFlags`.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Virtual key codes for the keys QuickChatSkill offers globally. Carbon wants the
    /// hardware code, which is layout-independent — so ⌥A is the same physical
    /// key on QWERTY and Dvorak.
    static func keyCode(for key: String) -> UInt32? {
        let codes: [String: Int] = [
            "space": kVK_Space,
            "a": kVK_ANSI_A, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "g": kVK_ANSI_G, "j": kVK_ANSI_J, "l": kVK_ANSI_L, "m": kVK_ANSI_M,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S,
            "t": kVK_ANSI_T, "y": kVK_ANSI_Y,
        ]
        guard let code = codes[key.lowercased()] else { return nil }
        return UInt32(code)
    }
}
