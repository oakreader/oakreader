import AVFoundation
import CoreGraphics
import AppKit

/// Centralized permission tracker for Microphone and Screen Recording.
/// Refreshes automatically when the app becomes active (e.g. user returns from System Settings).
@Observable
@MainActor
final class SystemPermissionStatus {
    static let shared = SystemPermissionStatus()

    private(set) var micAuthorized = false
    private(set) var micNotDetermined = false
    private(set) var screenRecordingAuthorized = false

    var allGranted: Bool { micAuthorized && screenRecordingAuthorized }
    var allRecordingGranted: Bool { micAuthorized }
    var allSystemAudioGranted: Bool { micAuthorized && screenRecordingAuthorized }

    private var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    private init() {
        refresh()
        // Auto-refresh when user returns from System Settings
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Re-reads all permission state from the OS (cheap, synchronous calls).
    func refresh() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = micStatus == .authorized
        micNotDetermined = micStatus == .notDetermined
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    }

    /// Requests microphone access when status is `.notDetermined`.
    func requestMicAccess() {
        guard micNotDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Triggers the system screen recording permission prompt.
    func requestScreenRecordingAccess() {
        CGRequestScreenCaptureAccess()
        // Poll for a while since the user may grant it from the system dialog
        startPolling()
    }

    /// Polls permission state every 2 seconds for up to 30 seconds.
    /// Auto-stops when all needed permissions are granted.
    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
                if self?.allSystemAudioGranted == true { return }
            }
        }
    }

    /// Cancels any active permission poll.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
