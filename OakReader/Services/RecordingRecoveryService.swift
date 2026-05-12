import Foundation
import AVFoundation
import UserNotifications

/// Recovers recordings from crashed sessions on app launch.
/// Checks for a checkpoint file, validates the audio, and imports it.
enum RecordingRecoveryService {
    /// Minimum duration (seconds) for a recording to be worth recovering.
    private static let minimumDuration: TimeInterval = 5.0

    /// Maximum age (seconds) for stale recording files before cleanup.
    private static let staleFileAge: TimeInterval = 7 * 24 * 3600 // 7 days

    /// Check for and recover any recordings from a previous crashed session.
    static func checkAndRecover(importService: ImportService) {
        guard let checkpoint = RecordingCheckpointManager.load() else {
            cleanupStaleFiles()
            return
        }

        let audioURL = URL(fileURLWithPath: checkpoint.audioFilePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            Log.info(Log.audio, "Checkpoint found but audio file missing, clearing")
            RecordingCheckpointManager.clear()
            return
        }

        // Check duration
        let asset = AVAsset(url: audioURL)
        Task {
            let duration: TimeInterval
            do {
                let cmDuration = try await asset.load(.duration)
                duration = cmDuration.seconds
            } catch {
                Log.error(Log.audio, "Failed to load recovered audio duration: \(error)")
                RecordingCheckpointManager.clear()
                return
            }

            guard duration.isFinite && duration >= minimumDuration else {
                Log.info(Log.audio, "Recovered recording too short (\(duration)s), discarding")
                RecordingCheckpointManager.clear()
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Import the recovered recording
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let title = "Recovered Recording \(formatter.string(from: checkpoint.startedAt))"

            let item = importService.importAudioRecording(
                from: audioURL,
                duration: Int(duration),
                title: title
            )

            RecordingCheckpointManager.clear()

            if item != nil {
                Log.info(Log.audio, "Successfully recovered recording from \(checkpoint.startedAt)")
                postRecoveryNotification(startedAt: checkpoint.startedAt)
            }

            cleanupStaleFiles()
        }
    }

    private static func postRecoveryNotification(startedAt: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let content = UNMutableNotificationContent()
        content.title = "Recording Recovered"
        content.body = "A recording from \(formatter.string(from: startedAt)) was recovered after an unexpected quit."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "recording-recovery-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Remove stale recording files older than 7 days that weren't imported.
    private static func cleanupStaleFiles() {
        let recordingsDir = AudioRecordingService.recordingsDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff = Date().addingTimeInterval(-staleFileAge)

        for file in files {
            guard let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = attrs.creationDate,
                  creationDate < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
            Log.info(Log.audio, "Cleaned up stale recording: \(file.lastPathComponent)")
        }
    }
}
