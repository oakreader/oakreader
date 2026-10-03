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
            return QuickChatTrigger.Kind(rawValue: raw) ?? .holdRightOption
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

    static var display: String {
        isGlobalEnabled ? trigger.display : "off"
    }
}

extension Notification.Name {
    /// Posted when the trigger or its on/off state changes, so the monitors are
    /// torn down and set up again.
    static let quickChatTriggerChanged = Notification.Name("OakReaderQuickChatSkillsTriggerChanged")
    /// Posted with a trigger's display string when another app already holds it.
    static let quickChatTriggerRejected = Notification.Name("OakReaderQuickChatSkillsTriggerRejected")
}
