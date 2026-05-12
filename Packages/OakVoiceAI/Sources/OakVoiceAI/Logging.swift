import os

/// Centralized logging for OakVoiceAI with an injectable sink for file logging.
///
/// The host app can set ``sink`` at startup to forward log messages to its own
/// file writer (e.g. `LogFileWriter`). Without a sink, messages still go to
/// `os.Logger` (visible in Console.app / Xcode).
public enum VoiceAgentLog {
    /// Optional sink for forwarding log messages to the host app's file writer.
    ///
    /// Set at app startup:
    /// ```swift
    /// VoiceAgentLog.sink = { level, category, message in
    ///     LogFileWriter.shared.write(level: level, category: category, message: message)
    /// }
    /// ```
    public static var sink: ((_ level: String, _ category: String, _ message: String) -> Void)?

    // MARK: - Loggers

    private static let sttLogger = Logger(subsystem: "OakVoiceAI", category: "stt")
    private static let ttsLogger = Logger(subsystem: "OakVoiceAI", category: "tts")

    // MARK: - STT

    public static func sttInfo(_ message: String) {
        sttLogger.info("\(message)")
        sink?("info", "stt", message)
    }

    public static func sttWarning(_ message: String) {
        sttLogger.warning("\(message)")
        sink?("warning", "stt", message)
    }

    public static func sttError(_ message: String) {
        sttLogger.error("\(message)")
        sink?("error", "stt", message)
    }

    // MARK: - TTS

    public static func ttsInfo(_ message: String) {
        ttsLogger.info("\(message)")
        sink?("info", "tts", message)
    }

    public static func ttsWarning(_ message: String) {
        ttsLogger.warning("\(message)")
        sink?("warning", "tts", message)
    }

    public static func ttsError(_ message: String) {
        ttsLogger.error("\(message)")
        sink?("error", "tts", message)
    }
}
