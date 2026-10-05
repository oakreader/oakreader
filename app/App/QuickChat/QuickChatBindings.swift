import AppKit
import Foundation

/// How Quick Chat is summoned. One trigger, nothing else.
///
/// There were three layers before: an in-app menu key equivalent, a separate
/// system-wide combination, and an optional key per skill. That is a shortcut
/// table to memorise standing in front of a panel whose whole job is that you
/// do not have to memorise anything — you summon it and pick. The panel is the
/// index; it only needs one door.
enum QuickChatBindings {

    private static let triggerKey = "quickSkillTrigger"
    private static let enabledKey = "acornGlobalEnabled"   // storage key kept: renaming it would reset the user's setting

    static var trigger: QuickChatTrigger.Kind {
        get {
            let raw = UserDefaults.standard.string(forKey: triggerKey) ?? ""
            return QuickChatTrigger.Kind(rawValue: raw) ?? .optionA
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: triggerKey)
            NotificationCenter.default.post(name: .quickChatTriggerChanged, object: nil)
        }
    }

    /// Off until the user turns it on: claiming a trigger system-wide and asking
    /// for Accessibility are both things to agree to, not to discover.
    static var isGlobalEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .quickChatTriggerChanged, object: nil)
        }
    }

    // MARK: - Screenshot trigger

    private static let shotKey = "quickChatScreenshotTrigger"

    /// Its own gesture, because it is a different act: you are not selecting
    /// text first, you are framing a region. Nil turns it off.
    static var screenshotTrigger: QuickChatTrigger.Kind? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: shotKey) else { return .optionS }
            return raw.isEmpty ? nil : QuickChatTrigger.Kind(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: shotKey)
            NotificationCenter.default.post(name: .quickChatTriggerChanged, object: nil)
        }
    }

    // MARK: - Visible skills

    /// Skills kept out of Quick Chat, by name.
    ///
    /// Stored as the hidden set rather than the shown one, so a skill installed
    /// later shows up instead of being invisible until someone finds this
    /// screen.
    private static let hiddenKey = "quickChatHiddenSkills"

    static var hiddenSkills: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey)
            NotificationCenter.default.post(name: .quickChatSkillsChanged, object: nil)
        }
    }

    static func isVisible(_ name: String) -> Bool {
        !hiddenSkills.contains(name)
    }

    static func setVisible(_ visible: Bool, for name: String) {
        var hidden = hiddenSkills
        if visible { hidden.remove(name) } else { hidden.insert(name) }
        hiddenSkills = hidden
    }

    static var display: String {
        isGlobalEnabled ? trigger.display : "off"
    }
}

extension Notification.Name {
    /// Posted when the trigger or its on/off state changes, so the monitors are
    /// torn down and set up again.
    static let quickChatTriggerChanged = Notification.Name("OakReaderQuickChatTriggerChanged")
    /// Posted with a trigger's display string when another app already holds it.
    static let quickChatTriggerRejected = Notification.Name("OakReaderQuickChatTriggerRejected")
    /// Posted when a skill is shown or hidden, so open views re-read the list.
    static let quickChatSkillsChanged = Notification.Name("OakReaderQuickChatSkillsChanged")
}
