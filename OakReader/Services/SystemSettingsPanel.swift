import AppKit

/// Maps permission types to System Settings deep-link URLs.
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
    }
}
