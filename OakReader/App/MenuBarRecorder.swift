import Cocoa
import SwiftUI
import UserNotifications

/// Persistent menu bar item with mic icon. Toggles a popover for one-click recording.
final class MenuBarRecorder: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var updateTimer: Timer?
    private var postMeetingPanel: NSPanel?

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
        setupPopover()
        startUpdateTimer()

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

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recorder")
        button.image?.size = NSSize(width: 16, height: 16)
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func setupPopover() {
        let contentView = MenuBarRecorderPopover(recorder: self)
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.contentSize = NSSize(width: 280, height: 200)
        popover.behavior = .transient
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Update Timer

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateStatusItemAppearance()
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        switch recordingService.state {
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.image?.size = NSSize(width: 16, height: 16)
            button.contentTintColor = .systemRed
            button.title = " \(recordingService.formattedElapsedTime)"
        case .stopping:
            button.title = " Saving…"
        case .idle:
            if meetingDetection.detectedMeeting != nil {
                button.image = NSImage(systemSymbolName: "mic.badge.plus", accessibilityDescription: "Meeting detected")
                button.image?.size = NSSize(width: 16, height: 16)
                button.contentTintColor = .systemOrange
            } else {
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recorder")
                button.image?.size = NSSize(width: 16, height: 16)
                button.contentTintColor = nil
            }
            button.title = ""
        }
    }

    // MARK: - Actions

    func startRecording(deviceUID: String?) {
        let mode = AudioRecordingService.RecordingMode(rawValue: Preferences.shared.recordingMode) ?? .micOnly
        recordingService.startRecording(deviceUID: deviceUID, mode: mode)
    }

    func stopRecording() {
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
              let attachment = item.primaryAttachment,
              let fileURL = item.fileURL else { return }

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
