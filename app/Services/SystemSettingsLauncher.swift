import AppKit

/// Maps permission types to System Settings deep-link URLs and opens them.
enum SystemSettingsLauncher {
    case microphone
    /// Language & Region → per-app language list. macOS resolves OakReader's UI
    /// language from here (and the system language), so this is the canonical
    /// place to override it — we deep-link rather than reimplement a switcher.
    case language

    private var url: URL {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!
        case .language:
            URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
        }
    }

    func open() {
        NSWorkspace.shared.open(url)
        // Bring System Settings to front
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first?.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
