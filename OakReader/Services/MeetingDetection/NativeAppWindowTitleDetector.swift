import Cocoa
import ScreenCaptureKit

/// Detects native meeting apps by checking window titles for active-call vs idle patterns.
struct NativeAppWindowTitleDetector: MeetingDetector {

    func detect() async -> [MeetingSignal] {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningMeetingApps = runningApps.filter {
            guard let bid = $0.bundleIdentifier else { return false }
            return MeetingAppRegistry.nativeBundleIDs.contains(bid)
        }

        guard !runningMeetingApps.isEmpty else { return [] }

        let windows: [SCWindow]
        do {
            // Use onScreenWindowsOnly: false to catch minimized meeting windows
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            windows = content.windows
        } catch {
            Log.debug(Log.meeting, "NativeAppWindowTitleDetector: SCShareableContent error: \(error)")
            return []
        }

        var signals: [MeetingSignal] = []

        for app in runningMeetingApps {
            guard let bundleID = app.bundleIdentifier,
                  let appDef = MeetingAppRegistry.nativeApp(for: bundleID) else { continue }

            let appWindows = windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }

            // No title patterns defined (e.g. Tencent Meeting) — low confidence based on running
            guard !appDef.activePatterns.isEmpty || !appDef.idlePatterns.isEmpty else {
                if !appWindows.isEmpty {
                    let appID = MeetingAppIdentifier(
                        bundleID: bundleID,
                        displayName: appDef.displayName
                    )
                    signals.append(MeetingSignal(
                        source: .windowTitle,
                        appIdentifier: appID,
                        confidence: 0.3,
                        detail: "App running, no title patterns available"
                    ))
                }
                continue
            }

            let titles = appWindows.compactMap { $0.title?.lowercased() }
            var foundActive = false
            var foundIdle = false

            for title in titles {
                for pattern in appDef.activePatterns {
                    if title.contains(pattern) {
                        foundActive = true
                        break
                    }
                }
                for pattern in appDef.idlePatterns {
                    if title.contains(pattern) {
                        foundIdle = true
                        break
                    }
                }
            }

            let appID = MeetingAppIdentifier(
                bundleID: bundleID,
                displayName: appDef.displayName
            )

            if foundActive && !foundIdle {
                signals.append(MeetingSignal(
                    source: .windowTitle,
                    appIdentifier: appID,
                    confidence: 0.8,
                    detail: "Active call title matched, no idle titles"
                ))
            } else if foundActive && foundIdle {
                // Both patterns found (multiple windows) — less certain
                signals.append(MeetingSignal(
                    source: .windowTitle,
                    appIdentifier: appID,
                    confidence: 0.5,
                    detail: "Both active and idle titles found"
                ))
            }
            // If only idle patterns found or no patterns found → no signal emitted
        }

        return signals
    }
}
