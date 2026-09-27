import Foundation

/// Skills, read from the core.
///
/// Loading moved there with the prompt that lists them: the agent discovers a
/// skill by name and description in its system prompt and reads the body
/// itself, so the side composing the prompt is the side that should know what
/// is on disk. Before this, the same two directories were walked by the app,
/// by the core, and by the CLI — three readings that could disagree.
///
/// Whether a skill's required tools are installed is resolved there too, so
/// the row a person reads in Settings and the listing the model gets cannot
/// disagree about what this machine has.
@MainActor
@Observable
final class SkillStore {
    static let shared = SkillStore()

    /// Installed, enabled skills in picker order — what the `/` menu offers.
    private(set) var installed: [BackendSkill] = []

    /// Everything the core can see, kept so a tool lookup does not need a round
    /// trip: importers ask for `monolith` or `pdf-oxide` mid-import, and the
    /// answer has not changed since the listing was read.
    private var all: [BackendSkill] = []

    private init() {}

    func reload() async {
        let (skills, advisories) = await SkillCatalog.list()
        all = skills
        installed = skills
            .filter { !$0.isBundled && $0.enabled }
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }

        // Worth a line for the same reason the library gets one: an empty `/`
        // menu and a failed read look identical on screen.
        Log.info(Log.store, "skills loaded: \(installed.count) installed, "
            + "\(skills.count - installed.count) other, \(advisories.count) advisories")
    }

    /// Where a tool some skill declares actually is, or nil when it is missing.
    ///
    /// Resolved by the core while it loaded the manifests, so this and the
    /// Settings row showing a green tick are reading one answer.
    func binPath(named name: String) -> String? {
        for skill in all {
            if let bin = skill.bins.first(where: { $0.name == name }), let path = bin.path {
                return path
            }
        }
        return nil
    }

    func skill(matching identifier: String) -> BackendSkill? {
        installed.first {
            $0.name.caseInsensitiveCompare(identifier) == .orderedSame
                || $0.title.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }
}

enum SkillCatalog {
    static func list() async -> (skills: [BackendSkill], advisories: [BackendSkillAdvisory]) {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.skillsList, params: RPC.SkillsListParams(),
                as: RPC.SkillsListResult.self)
            return (result.skills ?? [], result.advisories ?? [])
        } catch {
            Log.error(Log.store, "skills/list failed: \(error.localizedDescription)")
            return ([], [])
        }
    }
}

extension SkillCatalog {
    /// One skill's instructions, read when it is actually used.
    ///
    /// The bodies are long prose and only the active skill's is ever needed, so
    /// listing them would put every skill's full instructions on the wire to
    /// draw a menu of names.
    static func body(of name: String) async -> String {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.skillsBody, params: RPC.SkillsBodyParams(name: name),
                as: RPC.SkillsBodyResult.self)
            return result.body ?? ""
        } catch {
            Log.error(Log.store, "skills/body failed: \(error.localizedDescription)")
            return ""
        }
    }
}

extension BackendSkill: Identifiable {
    /// A skill's name is its identity — it is what a transcript records when a
    /// skill was used, and what `[[skill:…]]` refers to. Qualifying it by
    /// source would be a different id from the one already written into every
    /// stored conversation.
    ///
    /// Two skills with the same name are an advisory from the loader rather
    /// than a silent pick; the settings list shows one row per name.
    var id: String { name }

    var isBundled: Bool { source == "bundled" }

    /// The icon as the tile wants it, or nil to fall back to a default.
    var icon: SkillTileIcon? {
        guard let iconValue else { return nil }
        switch iconType {
        case "symbol": return .symbol(iconValue)
        case "url":    return .url(iconValue)
        case "file":   return .file(iconValue)
        default:       return nil
        }
    }

    /// A tool this skill needs that this machine does not have.
    var missingBins: [BackendSkillBin] { bins.filter { $0.path == nil } }

    /// The SF Symbol for a chip or badge, falling back for the icon shapes a
    /// glyph cannot represent.
    var symbolName: String {
        iconType == "symbol" ? (iconValue ?? "sparkles") : "sparkles"
    }

    /// How much of the document to attach while this skill is active.
    var documentContextMode: ContextMode {
        ContextMode(rawValue: contextMode) ?? .fullDocument
    }
}

/// How a skill's tile is drawn. Mirrors the three shapes `skill.json` allows:
/// an SF Symbol, a remote image, or a file beside the skill.
enum SkillTileIcon {
    case symbol(String)
    case url(String)
    case file(String)
}
