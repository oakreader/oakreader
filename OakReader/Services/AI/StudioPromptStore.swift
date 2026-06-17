import AppKit
import Foundation
import OakAgent

/// Optional user override for an AI Studio generator's *persona*, keyed by ``StudioArtifactKind``.
///
/// A Studio prompt splits in two: the **persona** — what makes a good artifact (taste,
/// pedagogy, voice) — and the **format contract** — the JSON / outline schema the
/// downstream parser depends on. The default persona is the corresponding constant in
/// ``StudioGenerator`` (the source of truth); the format contract is also hardcoded there so a
/// user edit can never break parsing. This store only lets a power user *override* the persona
/// by dropping a Markdown file on disk — nothing is bundled.
///
/// This is the Studio counterpart to OakAgent's skills, but deliberately far lighter — no
/// `skill.json` manifest, no requirements, no context mode, no install/enable lifecycle.
/// Overrides are a *closed* set (one file per built-in kind), not an open catalog: dropping
/// a new file here does **not** add a Studio artifact, since each kind is bound to a renderer
/// in code. They live at `~/OakReader/prompts/`, sibling to `~/OakReader/skills/`.
///
/// Resolution for ``persona(for:)``:
///   1. User override at `~/OakReader(-Dev)/prompts/<kind>.md`
///   2. `nil` — the caller falls back to its built-in persona constant, so generation never fails.
enum StudioPromptStore {

    /// User-editable prompt overrides directory, sibling to `SkillManager.installedDir`.
    static let userDir: URL = {
        #if DEBUG
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader-Dev/prompts", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/prompts", isDirectory: true)
        #endif
    }()

    /// The user's persona override for `kind`, or `nil` if none — in which case the generator
    /// uses its built-in constant. Cheap, uncached file read — Studio generation is infrequent.
    static func persona(for kind: StudioArtifactKind) -> String? {
        body(at: userFile(for: kind))
    }

    /// Whether the user has an override file on disk for `kind`.
    static func hasUserOverride(for kind: StudioArtifactKind) -> Bool {
        FileManager.default.fileExists(atPath: userFile(for: kind).path)
    }

    /// Delete the user override for `kind`, restoring the built-in default.
    static func resetToDefault(for kind: StudioArtifactKind) {
        try? FileManager.default.removeItem(at: userFile(for: kind))
    }

    /// Reveal the user prompts directory in Finder, creating it if needed.
    @MainActor
    static func openUserDir() {
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(userDir)
    }

    // MARK: - Loading

    private static func userFile(for kind: StudioArtifactKind) -> URL {
        userDir.appendingPathComponent("\(kind.rawValue).md")
    }

    /// Read a persona file's body. A file may be plain Markdown or carry optional YAML
    /// frontmatter (like `SKILL.md`); strip the frontmatter when present. Returns `nil`
    /// for a missing or empty file.
    private static func body(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if let parsed = FrontmatterParser.parse(raw), !parsed.body.isEmpty {
            return parsed.body
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
