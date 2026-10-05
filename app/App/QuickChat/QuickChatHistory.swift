import Foundation

/// What you asked Quick Chat, kept so you can look it up later.
///
/// JSONL, append-only, one exchange per line, at
/// `~/OakReader/agent/quickchat.jsonl`. A log is the one shape where appending
/// a line is the whole write: no migration, no schema to version, and the `oak`
/// CLI reads it with the same path helpers the app uses rather than a second
/// copy of a query.
///
/// The captured text is someone else's — a Slack message, a page you were
/// reading — so this is local, visible, and switchable off in Settings.
enum QuickChatHistory {

    struct Entry: Codable {
        let at: String
        /// `selection` or `screenshot`.
        let source: String
        /// The app the text came from, when it came from another one.
        let app: String?
        let appId: String?
        /// Skill name for a list pick, the typed words for an instruction.
        let skill: String
        /// True when the words are the user's own rather than a skill's name.
        let typed: Bool
        let text: String
        let reply: String

        private enum CodingKeys: String, CodingKey {
            case at, source, app, appId, skill, typed, text, reply
        }
    }

    private static let enabledKey = "quickChatKeepsHistory"

    /// On unless turned off. A history you have to discover and enable is a
    /// history that is empty on the day you need it.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var fileURL: URL {
        CatalogDatabase.agentDirectory.appendingPathComponent("quickchat.jsonl")
    }

    /// Longest source text and reply kept. A log is for remembering what you
    /// asked, not for archiving whole documents.
    private static let maxField = 4000

    static func record(
        capture: QuickChatCapture,
        skill: QuickChatSkill,
        reply: String
    ) {
        guard isEnabled else { return }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = Entry(
            at: ISO8601DateFormatter().string(from: Date()),
            source: capture.imageData != nil ? "screenshot" : "selection",
            app: capture.externalAppName,
            appId: capture.externalBundleID,
            skill: skill.name,
            typed: skill.inlinePolicy != nil,
            // The image itself is not stored: a screenshot is megabytes and the
            // line is meant to stay greppable.
            text: String(capture.text.prefix(maxField)),
            reply: String(trimmed.prefix(maxField))
        )

        Task.detached(priority: .utility) {
            append(entry)
        }
    }

    private static func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        let url = fileURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
            // Readable only by its owner: it holds text lifted out of other
            // people's windows.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
