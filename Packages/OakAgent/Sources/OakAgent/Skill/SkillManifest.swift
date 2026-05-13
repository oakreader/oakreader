import Foundation

// MARK: - Skill Manifest

/// Root type for the `skill.json` sidecar format.
/// Provides structured metadata (icon, author, binary requirements) alongside `SKILL.md`.
public struct SkillManifest: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let icon: SkillIcon?
    public let author: SkillAuthor?
    public let contextMode: String?
    public let disableModelInvocation: Bool?
    public let requires: SkillRequirements?

    public init(
        name: String? = nil,
        description: String? = nil,
        icon: SkillIcon? = nil,
        author: SkillAuthor? = nil,
        contextMode: String? = nil,
        disableModelInvocation: Bool? = nil,
        requires: SkillRequirements? = nil
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.author = author
        self.contextMode = contextMode
        self.disableModelInvocation = disableModelInvocation
        self.requires = requires
    }
}

// MARK: - Skill Icon

/// Icon for a skill, supporting SF Symbols, URLs, or local file references.
public enum SkillIcon: Sendable, Equatable {
    case symbol(String)
    case url(String)
    case file(String)
}

extension SkillIcon: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        switch type {
        case "symbol": self = .symbol(value)
        case "url":    self = .url(value)
        case "file":   self = .file(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown icon type '\(type)'. Expected symbol, url, or file."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let value):
            try container.encode("symbol", forKey: .type)
            try container.encode(value, forKey: .value)
        case .url(let value):
            try container.encode("url", forKey: .type)
            try container.encode(value, forKey: .value)
        case .file(let value):
            try container.encode("file", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - Author

public struct SkillAuthor: Codable, Sendable {
    public let name: String
    public let bio: String?
    public let links: SkillAuthorLinks?

    public init(name: String, bio: String? = nil, links: SkillAuthorLinks? = nil) {
        self.name = name
        self.bio = bio
        self.links = links
    }
}

public struct SkillAuthorLinks: Codable, Sendable {
    public let x: String?
    public let github: String?
    public let linkedin: String?
    public let reddit: String?
    public let youtube: String?

    public init(
        x: String? = nil, github: String? = nil,
        linkedin: String? = nil, reddit: String? = nil, youtube: String? = nil
    ) {
        self.x = x
        self.github = github
        self.linkedin = linkedin
        self.reddit = reddit
        self.youtube = youtube
    }
}

// MARK: - Requirements

public struct SkillRequirements: Codable, Sendable {
    public let env: [EnvRequirement]?
    public let bins: [BinRequirement]?

    public init(env: [EnvRequirement]? = nil, bins: [BinRequirement]? = nil) {
        self.env = env
        self.bins = bins
    }
}

public struct EnvRequirement: Codable, Sendable {
    public let name: String
    public let description: String?
    public let required: Bool?

    public init(name: String, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.description = description
        self.required = required
    }

    /// Whether this env var is required (defaults to `true` if not specified).
    public var isRequired: Bool { required ?? true }
}

public struct BinRequirement: Codable, Sendable {
    public let name: String
    public let description: String?
    public let searchPaths: [String]?
    public let install: InstallMethod?
    public let versionArgs: [String]?

    public init(
        name: String,
        description: String? = nil,
        searchPaths: [String]? = nil,
        install: InstallMethod? = nil,
        versionArgs: [String]? = nil
    ) {
        self.name = name
        self.description = description
        self.searchPaths = searchPaths
        self.install = install
        self.versionArgs = versionArgs
    }
}

public struct InstallMethod: Codable, Sendable {
    public let brew: String?
    public let npm: String?
    public let pip: String?
    public let url: String?

    public init(brew: String? = nil, npm: String? = nil, pip: String? = nil, url: String? = nil) {
        self.brew = brew
        self.npm = npm
        self.pip = pip
        self.url = url
    }
}
