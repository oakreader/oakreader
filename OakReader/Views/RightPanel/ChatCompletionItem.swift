import Foundation
import OakAgent

/// Unified data model for `/` slash commands and `@` context mentions
/// shown in the chat completion panel.
struct ChatCompletionItem: Identifiable, Equatable {

    enum Kind {
        case installedSkill(Skill)
        case contextMention(ContextMention)
        case characterAgent(CharacterAgent)
    }

    enum ContextMention: String, Equatable, CaseIterable {
        case document
        case page
        case selection
        case notes
    }

    let id: String
    let icon: String
    var imagePath: String?
    let label: String
    let description: String
    let kind: Kind

    /// The trigger character that produced this item (`/` or `@`).
    let trigger: String

    // MARK: - Equatable

    static func == (lhs: ChatCompletionItem, rhs: ChatCompletionItem) -> Bool {
        lhs.id == rhs.id && lhs.trigger == rhs.trigger
    }

    // MARK: - Factory - Slash Items

    static func slashItems(installed: [Skill]) -> [ChatCompletionItem] {
        installed.map { skill in
            ChatCompletionItem(
                id: "skill:\(skill.id)",
                icon: skill.icon,
                label: skill.name,
                description: skill.description,
                kind: .installedSkill(skill),
                trigger: "/"
            )
        }
    }

    // MARK: - Factory - Mention Items

    static func mentionItems(
        hasDocument: Bool,
        characterAgents: [CharacterAgent] = []
    ) -> [ChatCompletionItem] {
        var items: [ChatCompletionItem] = []
        if hasDocument {
            items.append(ChatCompletionItem(
                id: "ctx:document",
                icon: "doc.text",
                label: "Document",
                description: "Full document context",
                kind: .contextMention(.document),
                trigger: "@"
            ))
            items.append(ChatCompletionItem(
                id: "ctx:page",
                icon: "doc",
                label: "Current Page",
                description: "Current page only",
                kind: .contextMention(.page),
                trigger: "@"
            ))
            items.append(ChatCompletionItem(
                id: "ctx:selection",
                icon: "text.cursor",
                label: "Selection",
                description: "Selected text",
                kind: .contextMention(.selection),
                trigger: "@"
            ))
            items.append(ChatCompletionItem(
                id: "ctx:notes",
                icon: "note.text",
                label: "Notes",
                description: "Document notes",
                kind: .contextMention(.notes),
                trigger: "@"
            ))
        }

        items.append(contentsOf: characterAgents.map { agent in
            ChatCompletionItem(
                id: "agent:\(agent.id)",
                icon: agent.icon,
                imagePath: agent.imagePath,
                label: agent.handle,
                description: "\(agent.domain) · \(agent.description)",
                kind: .characterAgent(agent),
                trigger: "@"
            )
        })

        return items
    }

    // MARK: - Helpers

    /// Returns the `ContextMode` implied by this item, if it's a context mention.
    var contextMode: ContextMode? {
        guard case .contextMention(let mention) = kind else { return nil }
        switch mention {
        case .document: return .fullDocument
        case .page:     return .currentPage
        case .selection: return .selectedText
        case .notes:    return .fullDocument
        }
    }

    /// Returns the display string shown in the text field (e.g. `/Summarize` or `@Document`).
    var displayText: String {
        "\(trigger)\(displayLabel)"
    }

    /// Returns the label shown inside the popup row without the trigger glyph.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(trigger) else { return trimmed }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Section label used by the completion popup.
    var sectionTitle: String {
        switch kind {
        case .installedSkill:
            return "Skills"
        case .contextMention:
            return "Context"
        case .characterAgent:
            return "Agents"
        }
    }

    /// Matches a filter query against label and description (case-insensitive).
    func matches(query: String) -> Bool {
        let q = query.lowercased()
        return displayText.lowercased().contains(q)
            || displayLabel.lowercased().contains(q)
            || label.lowercased().contains(q)
            || description.lowercased().contains(q)
    }
}

// MARK: - CharacterAgent

/// A delegated reasoning source selected from the chat input with `@`.
/// CharacterAgents provide user-role material for the main assistant; they are
/// inspired by intellectual methods and must not impersonate historical people.
struct CharacterAgent: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let handle: String
    let name: String
    let domain: String
    let icon: String
    var imagePath: String?
    let description: String
    let prompt: String

    static func installed(from characters: [Character]) -> [CharacterAgent] {
        characters.compactMap { character in
            let prompt = character.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }

            let templateId = character.config.sourceTemplateId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata = templateId.flatMap(metadata(for:)) ?? metadata(for: character.name)
            let resolvedTemplateId = metadata?.id ?? templateId
            let imagePath = installedImagePath(for: character, metadata: metadata)

            return CharacterAgent(
                id: resolvedTemplateId?.isEmpty == false ? resolvedTemplateId! : character.id.uuidString,
                handle: metadata?.handle ?? handle(for: character.name),
                name: character.name,
                domain: metadata?.domain ?? "Character",
                icon: character.avatar.icon ?? metadata?.icon ?? "person.crop.circle",
                imagePath: imagePath,
                description: metadata?.description ?? fallbackDescription(from: prompt),
                prompt: prompt
            )
        }
    }

    static func find(idOrHandle: String, in agents: [CharacterAgent]) -> CharacterAgent? {
        agents.first {
            $0.matches(idOrHandle: idOrHandle)
        }
    }

    private static func metadata(for value: String) -> CharacterAgentTemplate? {
        let normalized = normalize(value)
        if let template = loadTemplate(named: normalized) {
            return template
        }
        return loadAllTemplates().first {
            $0.matches(value)
        }
    }

    private static func loadTemplate(named name: String) -> CharacterAgentTemplate? {
        for root in templateRootURLs() {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if let template = loadTemplate(in: directory) {
                return template
            }
        }
        return nil
    }

    private static func loadAllTemplates() -> [CharacterAgentTemplate] {
        var templates: [CharacterAgentTemplate] = []
        for root in templateRootURLs() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            templates.append(contentsOf: entries.compactMap { entry in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    return nil
                }
                return loadTemplate(in: entry)
            })
        }
        return templates
    }

    private static func loadTemplate(in directory: URL) -> CharacterAgentTemplate? {
        let manifestURL = directory.appendingPathComponent("character.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CharacterAgentManifest.self, from: data) else {
            return nil
        }

        let id = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let displayName = manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName?.isEmpty == false ? displayName! : Self.displayName(for: id)
        let prompt = manifest.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avatar = manifest.avatar
        let imagePath = resolvedImagePath(avatar: avatar, sourceDir: directory)

        return CharacterAgentTemplate(
            id: id,
            handle: handle(for: name),
            name: name,
            domain: manifest.category?.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: avatar?.icon,
            imagePath: imagePath,
            description: manifest.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt
        )
    }

    private static func templateRootURLs() -> [URL] {
        var roots: [URL] = []

        if let bundled = Bundle.main.url(forResource: "character", withExtension: nil) {
            roots.append(bundled)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("character", isDirectory: true) {
            roots.append(bundled)
        }

        roots.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("character", isDirectory: true)
        )
        roots.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("OakReader/agent/characters", isDirectory: true)
        )

        var seen = Set<String>()
        return roots.filter { root in
            var isDirectory: ObjCBool = false
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            return true
        }
    }

    private static func resolvedImagePath(avatar: CharacterAvatar?, sourceDir: URL) -> String? {
        guard avatar?.type == .image,
              let imagePath = avatar?.imagePath,
              !imagePath.isEmpty else {
            return nil
        }

        if (imagePath as NSString).isAbsolutePath {
            return imagePath
        }

        let resolved = sourceDir.appendingPathComponent(imagePath).path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    private static func installedImagePath(
        for character: Character,
        metadata: CharacterAgentTemplate?
    ) -> String? {
        if character.avatar.type == .image,
           let imagePath = character.avatar.imagePath,
           !imagePath.isEmpty,
           FileManager.default.fileExists(atPath: imagePath) {
            return imagePath
        }

        return metadata?.imagePath
    }

    private static func handle(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let last = words.last else { return name }
        return String(last)
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private static func fallbackDescription(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Use this installed character's reading method." }
        let sentenceEnd = trimmed.firstIndex { ".!?".contains($0) }
        let firstSentence = sentenceEnd.map { String(trimmed[...$0]) } ?? trimmed
        return String(firstSentence.prefix(96))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(idOrHandle value: String) -> Bool {
        let target = Self.normalize(value)
        if id.lowercased() == target || handle.lowercased() == target || name.lowercased() == target {
            return true
        }

        let idParts = id.split(separator: "-").map { $0.lowercased() }
        let nameParts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
        return idParts.contains(target) || nameParts.contains(target)
    }
}

private struct CharacterAgentManifest: Decodable {
    let name: String
    let displayName: String?
    let description: String?
    let category: String?
    let avatar: CharacterAvatar?
    let systemPrompt: String?
}

private struct CharacterAgentTemplate {
    let id: String
    let handle: String
    let name: String
    let domain: String?
    let icon: String?
    let imagePath: String?
    let description: String?
    let prompt: String

    func matches(_ value: String) -> Bool {
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.lowercased() == target || handle.lowercased() == target || name.lowercased() == target {
            return true
        }

        let idParts = id.split(separator: "-").map { $0.lowercased() }
        let nameParts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
        return idParts.contains(target) || nameParts.contains(target)
    }
}

struct CharacterAgentThreadRef: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
    }

    let id: UUID
    let agentId: String
    let agentName: String
    let icon: String?
    let jsonlPath: String
    var status: Status
    var title: String
    var summary: String
    var latestUserFollowUp: String?
    let createdAt: Date
    var updatedAt: Date
}
