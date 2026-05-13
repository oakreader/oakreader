import AVFoundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

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
        refreshMicStatus()
        // Kick off the async screen-recording check immediately.
        Task { await refreshScreenRecordingStatus() }
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

    /// Re-reads all permission state from the OS.
    func refresh() {
        refreshMicStatus()
        Task { await refreshScreenRecordingStatus() }
    }

    private func refreshMicStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = status == .authorized
        micNotDetermined = status == .notDetermined
    }

    /// Uses SCShareableContent to check the real permission state.
    /// CGPreflightScreenCaptureAccess() is unreliable on macOS 15 — it caches
    /// the value from launch and doesn't reflect runtime changes.
    private func refreshScreenRecordingStatus() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            screenRecordingAuthorized = !content.windows.isEmpty
        } catch {
            screenRecordingAuthorized = false
        }
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

    /// Triggers the system screen recording permission prompt.
    func requestScreenRecordingAccess() {
        CGRequestScreenCaptureAccess()
        startPolling()
    }

    // MARK: - Polling

    /// Polls permission state every 2 seconds for up to 30 seconds.
    /// Auto-stops when all needed permissions are granted.
    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refreshMicStatus()
                await self?.refreshScreenRecordingStatus()
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
