import AppKit
import Carbon.HIToolbox

/// How Quick Chat is summoned.
///
/// Two shapes, because they need different machinery:
///
/// - **Holding a modifier.** Watched through `flagsChanged` monitors. A monitor
///   observes without consuming, which is normally a reason not to use one —
///   but a modifier pressed alone produces no character, so there is nothing to
///   swallow. That is what makes this safe where a letter combination is not:
///   it cannot collide with typing, with another app's shortcut, or with an
///   input method.
/// - **A key combination.** Carbon's `RegisterEventHotKey`, which does consume,
///   and which refuses rather than steals when another app holds the keys.
final class QuickChatTrigger {

    enum Kind: String, CaseIterable, Identifiable {
        case optionA
        case optionS
        case optionSpace
        case controlCommandA
        case holdRightOption
        case holdLeftOption
        case holdRightCommand

        var id: String { rawValue }

        var display: String {
            switch self {
            case .holdRightOption: return "Hold right ⌥"
            case .holdLeftOption: return "Hold left ⌥"
            case .holdRightCommand: return "Hold right ⌘"
            case .optionSpace: return "⌥Space"
            case .optionA: return "⌥A"
            case .optionS: return "⌥S"
            case .controlCommandA: return "⌃⌘A"
            }
        }

        var detail: String? {
            switch self {
            case .holdRightOption, .holdLeftOption, .holdRightCommand:
                return "nothing to collide with — a modifier alone types nothing"
            case .optionSpace:
                return "ChatGPT, Codex and Raycast also default to this"
            case .optionA: return "å is no longer typable while Quick Chat is on"
            case .optionS: return "ß is no longer typable while Quick Chat is on"
            case .controlCommandA: return nil
            }
        }

        var isHold: Bool {
            switch self {
            case .holdRightOption, .holdLeftOption, .holdRightCommand: return true
            case .optionSpace, .optionA, .optionS, .controlCommandA: return false
            }
        }

        /// The physical key watched for a hold.
        var holdKeyCode: UInt16? {
            switch self {
            case .holdRightOption: return UInt16(kVK_RightOption)
            case .holdLeftOption: return UInt16(kVK_Option)
            case .holdRightCommand: return UInt16(kVK_RightCommand)
            default: return nil
            }
        }

        /// The modifier that must be the only one down during a hold.
        var holdFlag: NSEvent.ModifierFlags? {
            switch self {
            case .holdRightOption, .holdLeftOption: return .option
            case .holdRightCommand: return .command
            default: return nil
            }
        }

        var comboKey: String? {
            switch self {
            case .optionSpace: return "space"
            case .optionA, .controlCommandA: return "a"
            case .optionS: return "s"
            default: return nil
            }
        }

        var comboModifiers: NSEvent.ModifierFlags {
            switch self {
            case .optionSpace, .optionA, .optionS: return [.option]
            case .controlCommandA: return [.control, .command]
            default: return []
            }
        }
    }

    /// How long the modifier must be held. Long enough that an ordinary ⌥-click
    /// or a modifier passed through to another shortcut does not reach it,
    /// short enough not to feel like waiting.
    static let holdDuration: TimeInterval = 0.35

    var onFire: (() -> Void)?

    private let hotKey = QuickChatGlobalHotKey()
    private var monitors: [Any] = []
    private var holdTimer: Timer?
    private var kind: Kind = .optionA
    /// Set once a hold fires, so releasing the key does not fire it again.
    private var hasFired = false

    deinit {
        holdTimer?.invalidate()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        hotKey.unregister()
    }

    /// Returns false only for a key combination another app already holds;
    /// a hold can never be refused.
    @discardableResult
    func start(_ kind: Kind) -> Bool {
        stop()
        self.kind = kind

        guard kind.isHold else {
            guard let key = kind.comboKey,
                  let code = QuickChatGlobalHotKey.keyCode(for: key)
            else { return false }
            hotKey.onFire = { [weak self] in self?.onFire?() }
            return hotKey.register(
                keyCode: code,
                carbonModifiers: QuickChatGlobalHotKey.carbonModifiers(from: kind.comboModifiers)
            )
        }

        // Local as well as global: a global monitor never sees this app's own
        // events, so without the local one the trigger would die inside
        // OakReader itself.
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Any real keystroke or click means the modifier is being used as a
        // modifier, not held on its own.
        let cancelHandler: (NSEvent) -> Void = { [weak self] _ in
            self?.cancelHold()
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: flagsHandler) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: cancelHandler
        ) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: {
            flagsHandler($0)
            return $0
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: {
                cancelHandler($0)
                return $0
            }
        ) {
            monitors.append(monitor)
        }
        return true
    }

    func stop() {
        cancelHold()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        hotKey.unregister()
    }

    // MARK: - Hold

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let target = kind.holdKeyCode, let flag = kind.holdFlag else { return }

        // A different modifier moved: whatever is happening, it is not a bare
        // hold of ours.
        guard event.keyCode == target else {
            cancelHold()
            return
        }

        let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDown = active.contains(flag)
        // Exactly one modifier, or it is part of a combination.
        let isAlone = active == flag

        if isDown && isAlone {
            armHold()
        } else {
            cancelHold()
            hasFired = false
        }
    }

    private func armHold() {
        guard holdTimer == nil, !hasFired else { return }
        holdTimer = Timer.scheduledTimer(
            withTimeInterval: Self.holdDuration, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.holdTimer = nil
            self.hasFired = true
            self.onFire?()
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
