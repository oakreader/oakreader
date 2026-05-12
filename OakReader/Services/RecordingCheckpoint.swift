import Foundation

/// Checkpoint written when a recording starts, cleared on successful stop.
/// Used for crash recovery — if the app crashes mid-recording, the checkpoint
/// tells the recovery service where to find the partial audio file.
struct RecordingCheckpoint: Codable {
    let id: UUID
    let audioFilePath: String
    let startedAt: Date
    let deviceUID: String?
    let mode: String
}

enum RecordingCheckpointManager {
    static let checkpointURL = CatalogDatabase.dataDirectory.appendingPathComponent("recording-checkpoint.json")

    static func save(_ checkpoint: RecordingCheckpoint) {
        do {
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: checkpointURL, options: .atomic)
        } catch {
            Log.error(Log.audio, "Failed to save recording checkpoint: \(error)")
        }
    }

    static func load() -> RecordingCheckpoint? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: checkpointURL)
            return try JSONDecoder().decode(RecordingCheckpoint.self, from: data)
        } catch {
            Log.error(Log.audio, "Failed to load recording checkpoint: \(error)")
            return nil
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: checkpointURL)
    }
}
