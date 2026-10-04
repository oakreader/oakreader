import AppKit
import ApplicationServices

/// The Accessibility permission that system-wide capture needs.
///
/// Reading another application's selection and writing back to it both go
/// through the same permission, so there is one switch, not two. macOS grants
/// it per code signature, which is why the dev build asks separately from the
/// release build.
enum QuickChatAccessibility {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show its permission prompt. Returns the status as it
    /// stands right now — the user granting it happens later, out of process,
    /// so callers should re-check rather than trust the return value.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens System Settings directly on the Accessibility list. The system
    /// prompt only appears once per signature, so this is the way back for
    /// anyone who dismissed it.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Polls until the permission is granted, so the UI can update without the
    /// user having to restart the app. macOS does not notify on change.
    /// Stops on its own after `timeout`.
    static func waitForGrant(
        timeout: TimeInterval = 120,
        onChange: @escaping (Bool) -> Void
    ) {
        guard !isTrusted else {
            onChange(true)
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if isTrusted {
                    onChange(true)
                } else if Date() < deadline {
                    poll()
                }
            }
        }
        poll()
    }
}
