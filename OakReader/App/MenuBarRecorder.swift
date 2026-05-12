import AVFoundation
import Cocoa
import OakVoiceAI
import SwiftUI
import UserNotifications

/// Persistent menu bar item with book icon. Shows a context menu for one-click recording.
final class MenuBarRecorder: NSObject {
    private var statusItem: NSStatusItem?
    private var selectedDeviceUID: String?
    private var updateTimer: Timer?
    private var postMeetingPanel: NSPanel?
    private let islandController = RecordingIslandController()

    let recordingService = AudioRecordingService()
    let meetingDetection = MeetingDetectionService()
    let importService: ImportService
    let dialogCoordinator = PostMeetingDialogCoordinator()

    /// Holds the last imported item when recording stopped during a meeting.
    private var lastRecordedItem: LibraryItem?
    /// Whether recording was active when the meeting was detected.
    private var wasRecordingDuringMeeting = false

    init(importService: ImportService) {
        self.importService = importService
        super.init()
        setupStatusItem()
        startUpdateTimer()
        setupIsland()

        meetingDetection.onMeetingDetected = { [weak self] _ in
            self?.updateStatusItemAppearance()
            if self?.recordingService.state == .recording {
                self?.wasRecordingDuringMeeting = true
            }
        }

        meetingDetection.onMeetingEnded = { [weak self] session in
            guard let self else { return }
            guard Preferences.shared.showPostMeetingDialog else { return }

            if self.wasRecordingDuringMeeting && self.recordingService.state == .recording {
                // Auto-stop the recording and pass the saved item to the dialog
                self.islandController.hide()
                Task { @MainActor in
                    let duration = Int(self.recordingService.elapsedSeconds)
                    guard let url = await self.recordingService.stopRecording() else { return }
                    let item = self.importService.importAudioRecording(from: url, duration: duration)
                    self.lastRecordedItem = item
                    self.wasRecordingDuringMeeting = false
                    self.dialogCoordinator.show(session: session, recordedItem: item)
                    self.showPostMeetingPanel()
                }
            } else {
                self.wasRecordingDuringMeeting = false
                self.dialogCoordinator.show(session: session, recordedItem: nil)
                self.showPostMeetingPanel()
            }
        }
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Recording Island

    private func setupIsland() {
        islandController.onStopRequested = { [weak self] in
            self?.stopRecording()
        }
    }

    // MARK: - Status Item

    private static let idleIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: "OakReader")
        img?.isTemplate = true
        return img
    }()

    private static let recordingIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
        img?.size = NSSize(width: 16, height: 16)
        return img
    }()

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = Self.idleIcon

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private var micPermission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private var screenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func buildMenu(into menu: NSMenu) {
        let currentState = recordingService.state
        let isRecording = currentState == .recording
        let isStarting = currentState == .starting
        let isStopping = currentState == .stopping
        let micAuthorized = micPermission == .authorized
        let currentMode = AudioRecordingService.RecordingMode(rawValue: Preferences.shared.recordingMode) ?? .micOnly

        // Permission warnings
        if !micAuthorized {
            let permItem = NSMenuItem(title: "Microphone Access Required", action: #selector(openMicPermission), keyEquivalent: "")
            permItem.target = self
            permItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(permItem)
            menu.addItem(.separator())
        } else if currentMode == .micAndSystem && !screenRecordingPermission {
            let permItem = NSMenuItem(title: "Screen Recording Access Required", action: #selector(openScreenRecordingPermission), keyEquivalent: "")
            permItem.target = self
            permItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(permItem)
            menu.addItem(.separator())
        }

        // Last error message
        if let error = recordingService.lastError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        // Meeting detection banner
        if let meeting = meetingDetection.detectedMeeting, !isRecording {
            let meetingItem = NSMenuItem(title: "\(meeting.appName) detected", action: nil, keyEquivalent: "")
            meetingItem.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            menu.addItem(meetingItem)
            menu.addItem(.separator())
        }

        // Record / Stop
        if isRecording {
            let timeItem = NSMenuItem(title: recordingService.formattedElapsedTime, action: nil, keyEquivalent: "")
            timeItem.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
            menu.addItem(timeItem)

            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingAction), keyEquivalent: "")
            stopItem.target = self
            stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            menu.addItem(stopItem)
        } else if isStarting {
            let startingItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
            startingItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            menu.addItem(startingItem)
        } else if isStopping {
            let savingItem = NSMenuItem(title: "Saving…", action: nil, keyEquivalent: "")
            menu.addItem(savingItem)
        } else {
            let recordItem = NSMenuItem(title: "Start Recording", action: #selector(startRecordingAction), keyEquivalent: "r")
            recordItem.target = self
            recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            recordItem.isEnabled = micAuthorized && (currentMode != .micAndSystem || screenRecordingPermission)
            menu.addItem(recordItem)
        }

        menu.addItem(.separator())

        // Recording mode submenu
        let modeMenu = NSMenu()

        let micOnlyItem = NSMenuItem(title: "Mic Only", action: #selector(selectMicOnly), keyEquivalent: "")
        micOnlyItem.target = self
        micOnlyItem.state = currentMode == .micOnly ? .on : .off
        modeMenu.addItem(micOnlyItem)

        let micSystemItem = NSMenuItem(title: "Mic + System Audio", action: #selector(selectMicAndSystem), keyEquivalent: "")
        micSystemItem.target = self
        micSystemItem.state = currentMode == .micAndSystem ? .on : .off
        modeMenu.addItem(micSystemItem)

        let modeItem = NSMenuItem(title: "Recording Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        modeItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        menu.addItem(modeItem)

        // Input device submenu
        let deviceMenu = NSMenu()
        let devices = AudioDeviceManager.shared.inputDevices

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectDevice(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.tag = -1
        defaultItem.state = selectedDeviceUID == nil ? .on : .off
        deviceMenu.addItem(defaultItem)

        if !devices.isEmpty {
            deviceMenu.addItem(.separator())
        }
        for (i, device) in devices.enumerated() {
            let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = selectedDeviceUID == device.uniqueID ? .on : .off
            deviceMenu.addItem(item)
        }

        let deviceItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        deviceItem.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        menu.addItem(deviceItem)

        // Disable mode/device changes while recording
        if isRecording || isStarting || isStopping {
            modeItem.isEnabled = false
            deviceItem.isEnabled = false
        }

    }

    // MARK: - Permission Actions

    @objc private func openMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!)
        }
    }

    @objc private func openScreenRecordingPermission() {
        // Triggers the system permission prompt; on newer macOS opens Settings if already decided.
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Menu Actions

    @objc private func startRecordingAction() {
        startRecording(deviceUID: selectedDeviceUID)
    }

    @objc private func stopRecordingAction() {
        stopRecording()
    }

    @objc private func selectMicOnly() {
        Preferences.shared.recordingMode = AudioRecordingService.RecordingMode.micOnly.rawValue
    }

    @objc private func selectMicAndSystem() {
        Preferences.shared.recordingMode = AudioRecordingService.RecordingMode.micAndSystem.rawValue
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        if sender.tag == -1 {
            selectedDeviceUID = nil
        } else {
            let devices = AudioDeviceManager.shared.inputDevices
            if sender.tag < devices.count {
                selectedDeviceUID = devices[sender.tag].uniqueID
            }
        }
    }

    // MARK: - Update Timer

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateStatusItemAppearance()
        }
    }

    private var lastDisplayedState: AudioRecordingService.State?

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let state = recordingService.state
        switch state {
        case .starting:
            if lastDisplayedState != .starting {
                button.title = " Starting…"
            }
        case .recording:
            let time = recordingService.formattedElapsedTime
            if lastDisplayedState != .recording {
                button.image = Self.recordingIcon
                button.contentTintColor = .systemRed
                // Show island now that recording is confirmed running
                let mode = AudioRecordingService.RecordingMode(rawValue: Preferences.shared.recordingMode) ?? .micOnly
                islandController.model.recordingMode = mode.rawValue
                islandController.model.inputDeviceName = resolveDeviceName(uid: selectedDeviceUID)
                islandController.show()
            }
            button.title = " \(time)"
            islandController.model.elapsedTime = time
        case .stopping:
            if lastDisplayedState != .stopping {
                button.title = " Saving…"
            }
        case .idle:
            if lastDisplayedState != .idle {
                button.image = Self.idleIcon
                button.contentTintColor = meetingDetection.detectedMeeting != nil ? .systemOrange : nil
                button.title = ""
                // Hide island if recording ended unexpectedly (error/stream end)
                if lastDisplayedState == .recording || lastDisplayedState == .starting {
                    islandController.hide()
                }
            }
        }
        lastDisplayedState = state
    }

    // MARK: - Actions

    func startRecording(deviceUID: String?) {
        let mode = AudioRecordingService.RecordingMode(rawValue: Preferences.shared.recordingMode) ?? .micOnly
        recordingService.startRecording(deviceUID: deviceUID, mode: mode)
    }

    private func resolveDeviceName(uid: String?) -> String {
        guard let uid else { return "System Default" }
        return AudioDeviceManager.shared.inputDevices
            .first(where: { $0.uniqueID == uid })?.name ?? "System Default"
    }

    func stopRecording() {
        islandController.hide()

        Task { @MainActor in
            let duration = Int(recordingService.elapsedSeconds)
            guard let url = await recordingService.stopRecording() else { return }
            let item = importService.importAudioRecording(from: url, duration: duration)
            lastRecordedItem = item

            // Auto-transcribe if preference enabled
            if Preferences.shared.autoTranscribeAfterMeeting, let item {
                startTranscription(for: item)
            }
        }
    }

    // MARK: - Post-Meeting Dialog

    private func showPostMeetingPanel() {
        if let existing = postMeetingPanel {
            existing.orderFront(nil)
            return
        }

        let coordinator = dialogCoordinator
        guard case .meetingEnded(let session, let recordedItem) = coordinator.dialogState else { return }

        let dialogView = PostMeetingDialogView(
            session: session,
            recordedItem: recordedItem,
            onSaveAndTranscribe: { [weak self] in
                if let item = recordedItem {
                    self?.startTranscription(for: item)
                }
                self?.dismissPostMeetingPanel()
            },
            onSaveOnly: { [weak self] in
                self?.dismissPostMeetingPanel()
            },
            onDismiss: { [weak self] in
                self?.dismissPostMeetingPanel()
            }
        )

        let hostingController = NSHostingController(rootView: dialogView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.title = "Meeting Ended"
        panel.center()
        panel.orderFront(nil)
        postMeetingPanel = panel
    }

    private func dismissPostMeetingPanel() {
        postMeetingPanel?.close()
        postMeetingPanel = nil
        dialogCoordinator.dismiss()
    }

    // MARK: - Transcription

    func startTranscription(for item: LibraryItem) {
        let sttModel = Preferences.shared.voiceSTTModel
        guard !sttModel.isEmpty,
              let attachment = item.primaryAttachment else { return }

        let fileURL = item.fileURL
        Task {
            let service = RecordingTranscriptionService()
            do {
                let transcript = try await service.transcribe(audioURL: fileURL, sttModel: sttModel)

                let transcriptURL = CatalogDatabase.attachmentTranscriptURL(
                    itemStorageKey: item.storageKey,
                    attachmentStorageKey: attachment.storageKey
                )
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

                // Post notification
                let content = UNMutableNotificationContent()
                content.title = "Transcription Complete"
                content.body = "Recording \"\(item.title)\" has been transcribed."
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "transcription-\(item.id)",
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.error(Log.audio, "Transcription failed: \(error)")
            }
        }
    }
}

// MARK: - NSMenuDelegate

extension MenuBarRecorder: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(into: menu)
    }
}
