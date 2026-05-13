import AVFoundation
import AppKit

/// Centralized permission tracker for Microphone.
/// Refreshes automatically when the app becomes active (e.g. user returns from System Settings).
@Observable
@MainActor
final class SystemPermissionStatus {
    static let shared = SystemPermissionStatus()

    private(set) var micAuthorized = false
    private(set) var micNotDetermined = false

    private var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    private init() {
        refreshMicStatus()
        // Auto-refresh when user returns from System Settings.
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

    // MARK: - Refresh

    /// Re-reads permission state from the OS.
    func refresh() {
        refreshMicStatus()
    }

    private func refreshMicStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = status == .authorized
        micNotDetermined = status == .notDetermined
    }

    // MARK: - Request

    /// Requests microphone access when status is `.notDetermined`.
    func requestMicAccess() {
        guard micNotDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMicStatus()
            }
        }
    }

    // MARK: - Polling

    /// Polls permission state every 2 seconds for up to 30 seconds.
    /// Auto-stops when mic permission is granted.
    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refreshMicStatus()
                if self?.micAuthorized == true { return }
            }
        }
    }

    /// Cancels any active permission poll.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
