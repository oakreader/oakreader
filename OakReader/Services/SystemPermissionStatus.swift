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

    /// Re-reads all permission state from the OS.
    func refresh() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = micStatus == .authorized
        micNotDetermined = micStatus == .notDetermined

        // CGPreflightScreenCaptureAccess() is unreliable on macOS 15+;
        // it often returns false even after the user grants permission.
        // Use SCShareableContent as a more reliable check.
        if !CGPreflightScreenCaptureAccess() {
            Task { @MainActor in
                await self.checkScreenRecordingViaSCK()
            }
        } else {
            screenRecordingAuthorized = true
        }
    }

    /// Checks screen recording permission by attempting to enumerate windows
    /// via ScreenCaptureKit — this reflects the actual permission state.
    private func checkScreenRecordingViaSCK() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            // If we can see windows from other apps, permission is granted.
            screenRecordingAuthorized = !content.windows.isEmpty
        } catch {
            // SCShareableContent throws when permission is denied.
            screenRecordingAuthorized = false
        }
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
                // Refresh mic status synchronously
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                self?.micAuthorized = micStatus == .authorized
                self?.micNotDetermined = micStatus == .notDetermined
                // Check screen recording via the reliable async path
                await self?.checkScreenRecordingViaSCK()
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
