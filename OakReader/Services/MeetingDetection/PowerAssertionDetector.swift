import Cocoa
import IOKit.pwr_mgt

/// Detects meeting apps that hold power assertions (PreventUserIdleDisplaySleep / PreventUserIdleSystemSleep),
/// which are characteristic of active video/audio calls. No extra permissions needed.
struct PowerAssertionDetector: MeetingDetector {

    func detect() async -> [MeetingSignal] {
        // IOPMCopyAssertionsByProcess returns a dict keyed by PID (NSNumber),
        // each value is an array of assertion dicts.
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard status == kIOReturnSuccess,
              let cfDict = assertionsByProcess?.takeRetainedValue(),
              let dict = cfDict as? [NSNumber: [[String: Any]]] else {
            return []
        }

        // Build PID → bundleID map from running applications
        let runningApps = NSWorkspace.shared.runningApplications
        var pidToBundleID: [pid_t: String] = [:]
        var pidToName: [pid_t: String] = [:]
        for app in runningApps {
            guard let bid = app.bundleIdentifier else { continue }
            pidToBundleID[app.processIdentifier] = bid
            pidToName[app.processIdentifier] = app.localizedName ?? bid
        }

        let relevantTypes: Set<String> = [
            "PreventUserIdleDisplaySleep",
            "PreventUserIdleSystemSleep",
        ]

        var signals: [MeetingSignal] = []
        var seenBundleIDs: Set<String> = []

        for (pidNumber, assertions) in dict {
            let pid = pid_t(pidNumber.intValue)
            guard let bundleID = pidToBundleID[pid],
                  MeetingAppRegistry.nativeBundleIDs.contains(bundleID),
                  !seenBundleIDs.contains(bundleID) else { continue }

            let hasRelevantAssertion = assertions.contains { assertion in
                guard let assertType = assertion["AssertType"] as? String else { return false }
                return relevantTypes.contains(assertType)
            }

            if hasRelevantAssertion {
                seenBundleIDs.insert(bundleID)
                let displayName = MeetingAppRegistry.nativeApp(for: bundleID)?.displayName
                    ?? pidToName[pid] ?? bundleID

                let appID = MeetingAppIdentifier(
                    bundleID: bundleID,
                    displayName: displayName
                )
                signals.append(MeetingSignal(
                    source: .powerAssertion,
                    appIdentifier: appID,
                    confidence: 0.7,
                    detail: "Power assertion held by \(displayName)"
                ))
            }
        }

        return signals
    }
}
