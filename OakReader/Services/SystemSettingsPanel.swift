import AppKit

/// Maps permission types to System Settings deep-link URLs and opens them.
enum SystemSettingsPanel {
    case microphone
    case screenRecording

    private var url: URL {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
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
