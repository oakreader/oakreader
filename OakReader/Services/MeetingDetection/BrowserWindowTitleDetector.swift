import Cocoa
import ScreenCaptureKit

/// Detects browser-based meetings by checking window titles for known meeting domain patterns.
struct BrowserWindowTitleDetector: MeetingDetector {

    func detect() async -> [MeetingSignal] {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningBrowsers = runningApps.filter {
            guard let bid = $0.bundleIdentifier else { return false }
            return MeetingAppRegistry.browserBundleIDs.contains(bid)
        }

        guard !runningBrowsers.isEmpty else { return [] }

        let windows: [SCWindow]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            windows = content.windows
        } catch {
            Log.debug(Log.meeting, "BrowserWindowTitleDetector: SCShareableContent error: \(error)")
            return []
        }

        var signals: [MeetingSignal] = []

        for browser in runningBrowsers {
            guard let bundleID = browser.bundleIdentifier else { continue }
            let browserName = browser.localizedName ?? "Browser"

            let browserWindows = windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }

            for window in browserWindows {
                guard let title = window.title?.lowercased() else { continue }

                for pattern in MeetingAppRegistry.browserMeetingPatterns {
                    if title.contains(pattern.urlPattern) {
                        let displayName = "\(pattern.label) (\(browserName))"
                        let appID = MeetingAppIdentifier(
                            bundleID: bundleID,
                            displayName: displayName
                        )
                        signals.append(MeetingSignal(
                            source: .browserTitle,
                            appIdentifier: appID,
                            confidence: 0.85,
                            detail: "Browser title matched: \(pattern.urlPattern)"
                        ))
                        break // one match per window is enough
                    }
                }
            }
        }

        return signals
    }
}
