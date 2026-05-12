import AVFoundation
import CoreGraphics

/// Centralized permission tracker for Microphone and Screen Recording.
@Observable
@MainActor
final class SystemPermissionStatus {
    static let shared = SystemPermissionStatus()

    private(set) var micAuthorized = false
    private(set) var micNotDetermined = false
    private(set) var screenRecordingAuthorized = false

    var allGranted: Bool { micAuthorized && screenRecordingAuthorized }

    private var pollTask: Task<Void, Never>?

    private init() {
        refresh()
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

    /// Polls permission state every 2 seconds for up to 30 seconds.
    /// Auto-stops when `allGranted` becomes true.
    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
                if self?.allGranted == true { return }
            }
        }
    }

    /// Cancels any active permission poll.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
