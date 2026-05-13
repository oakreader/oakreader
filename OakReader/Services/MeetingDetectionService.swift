import Cocoa
import CoreAudio
import IOKit.pwr_mgt
import ScreenCaptureKit
import UserNotifications

/// Detects active meeting apps while the system microphone is in use.
/// Uses a multi-signal architecture: power assertions, window titles, and browser tab titles
/// are fused via noisy-OR confidence scoring to reduce false positives.
@Observable
final class MeetingDetectionService {

    struct DetectedMeeting {
        let appName: String
        let bundleID: String
        let confidence: Double

        init(appName: String, bundleID: String, confidence: Double = 1.0) {
            self.appName = appName
            self.bundleID = bundleID
            self.confidence = confidence
        }
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

    /// Callback invoked on main thread when a meeting ends (after grace period).
    var onMeetingEnded: ((MeetingSession) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var appObserver: NSObjectProtocol?
    private var meetingStartedAt: Date?
    private var activeMeetingInfo: DetectedMeeting?

    // MARK: - Signal Aggregation

    private let aggregator: MeetingSignalAggregator

    // MARK: - Polling & Confirmation State Machine

    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval = 5.0

    /// Consecutive polls where a meeting was detected above threshold.
    private var consecutivePositive: Int = 0

    /// Consecutive polls where no meeting was detected.
    private var consecutiveNegative: Int = 0

    /// Number of consecutive positive polls required before declaring a meeting.
    private var confirmationThreshold: Int { aggregator.confirmationCount }

    /// Number of consecutive negative polls required before ending a meeting.
    private var endGraceThreshold: Int { aggregator.endGraceCount }

    init() {
        self.aggregator = MeetingSignalAggregator(detectors: [
            PowerAssertionDetector(),
            NativeAppWindowTitleDetector(),
            BrowserWindowTitleDetector(),
        ])
        installMicListener()
        observeAppLaunches()
        requestNotificationPermission()
    }

    deinit {
        removeMicListener()
        pollingTask?.cancel()
        if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - CoreAudio Mic Listener

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
            Log.info(Log.meeting, "Mic activated, starting meeting detection polling")
            consecutivePositive = 0
            consecutiveNegative = 0
            startPolling()
        } else if !active && wasActive {
            Log.info(Log.meeting, "Mic deactivated, stopping meeting detection polling")
            stopPolling()
            handleMicDeactivated()
        }
    }

    // MARK: - Polling Loop

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            // Run an immediate poll, then continue at the interval
            await self.pollOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.pollingInterval))
                if Task.isCancelled { break }
                await self.pollOnce()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    private func pollOnce() async {
        let assessment = await aggregator.bestAssessment()

        if let assessment {
            consecutivePositive += 1
            consecutiveNegative = 0

            Log.debug(Log.meeting,
                "Poll positive: \(assessment.candidate.displayName) confidence=\(String(format: "%.2f", assessment.confidence)) " +
                "consecutive=\(consecutivePositive)/\(confirmationThreshold)")

            if consecutivePositive >= confirmationThreshold && detectedMeeting == nil {
                let meeting = DetectedMeeting(
                    appName: assessment.candidate.displayName,
                    bundleID: assessment.candidate.bundleID,
                    confidence: assessment.confidence
                )
                detectedMeeting = meeting
                trackMeetingStart(meeting)
                postMeetingNotification(meeting)
                onMeetingDetected?(meeting)
                Log.info(Log.meeting,
                    "Meeting confirmed: \(meeting.appName) (confidence=\(String(format: "%.2f", meeting.confidence)))")
            } else if detectedMeeting != nil {
                // Update confidence on ongoing meeting
                detectedMeeting = DetectedMeeting(
                    appName: assessment.candidate.displayName,
                    bundleID: assessment.candidate.bundleID,
                    confidence: assessment.confidence
                )
            }
        } else {
            consecutiveNegative += 1
            consecutivePositive = 0

            Log.debug(Log.meeting,
                "Poll negative: consecutive=\(consecutiveNegative)/\(endGraceThreshold)")

            if consecutiveNegative >= endGraceThreshold && detectedMeeting != nil {
                endMeeting()
            }
        }
    }

    // MARK: - Meeting Lifecycle

    private func handleMicDeactivated() {
        guard detectedMeeting != nil else {
            detectedMeeting = nil
            return
        }
        // When mic goes inactive, end the meeting after grace period.
        // Since polling has stopped, trigger the end directly.
        endMeeting()
    }

    private func endMeeting() {
        guard let meeting = activeMeetingInfo, let startedAt = meetingStartedAt else {
            detectedMeeting = nil
            return
        }

        let session = MeetingSession(
            appName: meeting.appName,
            bundleID: meeting.bundleID,
            startedAt: startedAt,
            endedAt: Date()
        )
        lastEndedSession = session
        detectedMeeting = nil
        activeMeetingInfo = nil
        meetingStartedAt = nil
        consecutivePositive = 0
        consecutiveNegative = 0
        onMeetingEnded?(session)

        Log.info(Log.meeting,
            "Meeting ended: \(session.appName) duration=\(String(format: "%.0f", session.duration))s")
    }

    private func trackMeetingStart(_ meeting: DetectedMeeting) {
        if meetingStartedAt == nil {
            meetingStartedAt = Date()
        }
        activeMeetingInfo = meeting
    }

    // MARK: - App Launch Observer

    private func observeAppLaunches() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isMicActive else { return }
            // If a meeting app just launched while mic is active, do an immediate poll
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bid = app.bundleIdentifier,
               MeetingAppRegistry.nativeBundleIDs.contains(bid) || MeetingAppRegistry.browserBundleIDs.contains(bid) {
                Task { await self.pollOnce() }
            }
        }
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
