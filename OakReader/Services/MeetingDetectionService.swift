import Cocoa
import CoreAudio
import UserNotifications

/// Detects active meeting apps while the system microphone is in use.
/// Uses CoreAudio property listener (no mic permission needed) + NSWorkspace running apps.
@Observable
final class MeetingDetectionService {

    struct DetectedMeeting {
        let appName: String
        let bundleID: String
    }

    struct MeetingSession {
        let appName: String
        let bundleID: String
        let startedAt: Date
        let endedAt: Date

        var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    }

    private(set) var detectedMeeting: DetectedMeeting?
    private(set) var isMicActive: Bool = false
    private(set) var lastEndedSession: MeetingSession?

    /// Callback invoked on main thread when a new meeting is detected.
    var onMeetingDetected: ((DetectedMeeting) -> Void)?

    /// Callback invoked on main thread when a meeting ends (after debounce).
    var onMeetingEnded: ((MeetingSession) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var appObserver: NSObjectProtocol?
    private var meetingStartedAt: Date?
    private var activeMeetingInfo: DetectedMeeting?
    private var endDebounceTimer: Timer?

    // MARK: - Known Meeting Apps

    private static let meetingBundleIDs: [String: String] = [
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tencent.meeting": "Tencent Meeting",
        "us.zoom.xos": "Zoom",
    ]

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
    ]

    init() {
        installMicListener()
        observeAppLaunches()
        requestNotificationPermission()
    }

    deinit {
        removeMicListener()
        endDebounceTimer?.invalidate()
        if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - CoreAudio Mic Listener

    /// Listen for `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device.
    /// This fires when ANY process starts/stops using the mic — no microphone permission required.
    private func installMicListener() {
        guard let deviceID = Self.defaultInputDeviceID() else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.checkMicState()
            }
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)

        // Check initial state
        checkMicState()
    }

    private func removeMicListener() {
        guard let block = listenerBlock,
              let deviceID = Self.defaultInputDeviceID() else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        listenerBlock = nil
    }

    private func checkMicState() {
        guard let deviceID = Self.defaultInputDeviceID() else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)

        let active = (status == noErr && isRunning != 0)
        let wasActive = isMicActive
        isMicActive = active

        if active && !wasActive {
            endDebounceTimer?.invalidate()
            endDebounceTimer = nil
            evaluateMeetingApps()
        } else if !active && wasActive {
            handleMicDeactivated()
        }
    }

    /// Start a debounce timer when mic goes inactive to avoid false triggers from brief interruptions.
    private func handleMicDeactivated() {
        guard let meeting = activeMeetingInfo, let startedAt = meetingStartedAt else {
            detectedMeeting = nil
            return
        }

        endDebounceTimer?.invalidate()
        endDebounceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            let session = MeetingSession(
                appName: meeting.appName,
                bundleID: meeting.bundleID,
                startedAt: startedAt,
                endedAt: Date()
            )
            self.lastEndedSession = session
            self.detectedMeeting = nil
            self.activeMeetingInfo = nil
            self.meetingStartedAt = nil
            self.onMeetingEnded?(session)
        }
    }

    // MARK: - App Detection

    private func observeAppLaunches() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if self?.isMicActive == true {
                self?.evaluateMeetingApps()
            }
        }
    }

    private func evaluateMeetingApps() {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))

        // Check dedicated meeting apps first
        for (bundleID, appName) in Self.meetingBundleIDs {
            if runningBundleIDs.contains(bundleID) {
                let meeting = DetectedMeeting(appName: appName, bundleID: bundleID)
                if detectedMeeting?.bundleID != bundleID {
                    detectedMeeting = meeting
                    trackMeetingStart(meeting)
                    postMeetingNotification(meeting)
                    onMeetingDetected?(meeting)
                }
                return
            }
        }

        // Check browser-based meetings (mic active + browser running = possible Google Meet)
        for browserID in Self.browserBundleIDs {
            if runningBundleIDs.contains(browserID) {
                let browserName = runningApps.first(where: { $0.bundleIdentifier == browserID })?.localizedName ?? "Browser"
                let meeting = DetectedMeeting(appName: "Meeting (\(browserName))", bundleID: browserID)
                if detectedMeeting?.bundleID != browserID {
                    detectedMeeting = meeting
                    trackMeetingStart(meeting)
                    postMeetingNotification(meeting)
                    onMeetingDetected?(meeting)
                }
                return
            }
        }

        detectedMeeting = nil
    }

    private func trackMeetingStart(_ meeting: DetectedMeeting) {
        if meetingStartedAt == nil {
            meetingStartedAt = Date()
        }
        activeMeetingInfo = meeting
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postMeetingNotification(_ meeting: DetectedMeeting) {
        let content = UNMutableNotificationContent()
        content.title = "\(meeting.appName) detected"
        content.body = "A meeting is in progress. Tap to open OakReader and start recording."
        content.sound = .default
        content.categoryIdentifier = "MEETING_DETECTED"

        let request = UNNotificationRequest(
            identifier: "meeting-\(meeting.bundleID)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helpers

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }
}
