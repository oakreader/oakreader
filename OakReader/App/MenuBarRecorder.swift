import Cocoa
import SwiftUI

/// Persistent menu bar item with mic icon. Toggles a popover for one-click recording.
final class MenuBarRecorder: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var updateTimer: Timer?

    let recordingService = AudioRecordingService()
    let meetingDetection = MeetingDetectionService()
    let importService: ImportService

    init(importService: ImportService) {
        self.importService = importService
        super.init()
        setupStatusItem()
        setupPopover()
        startUpdateTimer()

        meetingDetection.onMeetingDetected = { [weak self] _ in
            self?.updateStatusItemAppearance()
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
        recordingService.startRecording(deviceUID: deviceUID)
    }

    func stopRecording() {
        Task { @MainActor in
            let duration = Int(recordingService.elapsedSeconds)
            guard let url = await recordingService.stopRecording() else { return }
            importService.importAudioRecording(from: url, duration: duration)
        }
    }
}
