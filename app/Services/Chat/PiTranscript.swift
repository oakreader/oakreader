import Foundation

// MARK: - Reading a pi Message

/// A pi `Message`, held as raw JSON.
///
/// The shell reads only the fields it draws, and builds only user messages
/// itself. Everything else in a message is pi's and passes through untouched.
enum PiMessage {
    static func role(_ m: JSONValue) -> String? { m["role"]?.stringValue }

    /// The text blocks, joined. A user message may carry a bare string.
    static func text(_ m: JSONValue) -> String {
        if let s = m["content"]?.stringValue { return s }
        return blocks(m, "text").compactMap { $0["text"]?.stringValue }.joined()
    }

    /// The thinking blocks, joined; nil when there is no readable thinking.
    static func thinking(_ m: JSONValue) -> String? {
        let text = blocks(m, "thinking").compactMap { $0["thinking"]?.stringValue }.joined()
        return text.isEmpty ? nil : text
    }

    static func toolCalls(_ m: JSONValue) -> [ToolCall] {
        blocks(m, "toolCall").compactMap { block in
            guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
            var input: ToolInput = [:]
            if case .object(let args) = block["arguments"] { input.values = args }
            return ToolCall(id: id, name: name, input: input)
        }
    }

    /// The decoded image blocks, in order.
    static func images(_ m: JSONValue) -> [Data] {
        blocks(m, "image").compactMap { $0["data"]?.stringValue }.compactMap { Data(base64Encoded: $0) }
    }

    /// pi timestamps are Unix milliseconds.
    static func date(_ m: JSONValue) -> Date? {
        guard let ms = m["timestamp"]?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// The failure text of an assistant reply that ended in an error.
    static func failure(_ m: JSONValue) -> String? {
        guard m["stopReason"]?.stringValue == "error" else { return nil }
        return m["errorMessage"]?.stringValue ?? "provider error"
    }

    private static func blocks(_ m: JSONValue, _ type: String) -> [JSONValue] {
        guard case .array(let content) = m["content"] else { return [] }
        return content.filter { $0["type"]?.stringValue == type }
    }

    // MARK: Building

    enum Part {
        case text(String)
        case image(data: String, mimeType: String)

        var json: JSONValue {
            switch self {
            case .text(let text):
                return .object(["type": .string("text"), "text": .string(text)])
            case .image(let data, let mimeType):
                return .object(["type": .string("image"), "data": .string(data), "mimeType": .string(mimeType)])
            }
        }
    }

    static func user(_ parts: [Part], at date: Date = Date()) -> JSONValue {
        .object([
            "role": .string("user"),
            "content": .array(parts.map(\.json)),
            "timestamp": .int(milliseconds(date)),
        ])
    }

    /// pi timestamps are Unix milliseconds.
    static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Attachments (text selections + captured images) followed by the typed text.
    /// `turn` must be hydrated: images are read from `imageData`.
    static func userParts(for turn: Turn) -> [Part] {
        var parts: [Part] = []
        for attachment in turn.attachments {
            switch attachment.type {
            case .textSelection:
                if let text = attachment.textContent {
                    parts.append(.text("[\(attachment.label)]\n> \(text)\n"))
                }
            case .imageCapture:
                if let imageData = attachment.imageData {
                    // A region of a PDF page carries its page label and the text
                    // under it. Only that path sets `textContent`, empty for a
                    // figure with no text. Other images send pixels only.
                    if let text = attachment.textContent {
                        var context = "[\(attachment.label)]"
                        if !text.isEmpty { context += "\nText inside the region:\n> \(text)" }
                        parts.append(.text(context + "\n"))
                    }
                    parts.append(.image(data: imageData.base64EncodedString(), mimeType: "image/png"))
                }
            }
        }
        parts.append(.text(modelText(from: turn.content)))
        return parts
    }

    /// UI-only skill marker (`[[skill:id]]`) must not leak to providers; when the
    /// user only selected a skill and typed nothing, send the skill id instead of
    /// an empty message.
    static func modelText(from content: String) -> String {
        var remaining = content
        var skillIds: [String] = []

        while true {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[[skill:") else { break }
            guard let closeRange = trimmed.range(of: "]]") else { break }
            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: "[[skill:".count)
            let rawSkill = String(trimmed[valueStart..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawSkill.isEmpty { skillIds.append(rawSkill) }
            remaining = String(trimmed[closeRange.upperBound...])
        }

        let text = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if skillIds.isEmpty { return text.isEmpty ? "Go" : text }
        return (text.isEmpty || text == "/") ? (skillIds.first ?? "Go") : text
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
}

// MARK: - The session file

/// A chat transcript: one pi session file, `chats/{sessionId}.jsonl`.
///
/// The core writes it in pi's session format (version 3) and sends each line
/// it appends on `chat/entry`; the shell only reads it. Each line is the
/// `session` header or an entry chained by `parentId`. A `message` entry holds
/// a pi Message. A `custom` entry of type `oakreader.display` holds what the
/// shell draws that pi has no field for, and names its message in `targetId`.
enum PiSession {
    static let displayType = "oakreader.display"

    /// The data of an `oakreader.display` entry.
    struct Display: Codable {
        var targetId: String?
        /// The text as the user typed it, skill markers included.
        var content: String?
        var metadata: [String: String]?
        /// Labels and page numbers. The pixels are the message's image blocks, in order.
        var attachments: [TurnAttachment]?
        var thinkingSeconds: Double?
    }

    /// The display data the core stores with a user message.
    static func display(for turn: Turn) -> AnyJSONObject? {
        let attachments = turn.attachments.map { a in
            TurnAttachment(id: a.id, type: a.type, label: a.label, textContent: a.textContent, pageIndex: a.pageIndex)
        }
        let display = Display(
            content: turn.content,
            metadata: turn.metadata.isEmpty ? nil : turn.metadata,
            attachments: attachments.isEmpty ? nil : attachments
        )
        guard let data = try? JSONEncoder().encode(display),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return AnyJSONObject(object)
    }

    /// Every line of the file, the header included; empty when there is no file.
    static func read(_ url: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// The turns to draw. A tool result folds into the assistant turn that called it.
    static func turns(from entries: [JSONValue]) -> [Turn] {
        var displays: [String: Display] = [:]
        for entry in entries where entry["type"]?.stringValue == "custom"
            && entry["customType"]?.stringValue == displayType {
            guard let data = entry["data"].flatMap({ try? JSONEncoder().encode($0) }),
                  let display = try? JSONDecoder().decode(Display.self, from: data),
                  let target = display.targetId else { continue }
            displays[target, default: Display()].merge(display)
        }

        var turns: [Turn] = []
        for entry in entries where entry["type"]?.stringValue == "message" {
            guard let id = entry["id"]?.stringValue, let m = entry["message"] else { continue }
            let display = displays[id]
            let timestamp = PiMessage.date(m) ?? Date()
            switch PiMessage.role(m) {
            case "user":
                turns.append(Turn(
                    id: turnId(id), role: .user, content: display?.content ?? PiMessage.text(m),
                    timestamp: timestamp, metadata: display?.metadata ?? [:],
                    attachments: attachments(display?.attachments ?? [], images: PiMessage.images(m))
                ))
            case "assistant":
                let records = PiMessage.toolCalls(m).map { call -> ToolUseRecord in
                    var record = ToolUseRecord(from: call)
                    // Settled: a call with no stored result was cut off, not running.
                    record.status = .completed
                    return record
                }
                var turn = Turn(
                    id: turnId(id), role: .assistant, content: PiMessage.text(m),
                    timestamp: timestamp, error: PiMessage.failure(m),
                    toolUses: records, thinking: PiMessage.thinking(m)
                )
                turn.thinkingSeconds = display?.thinkingSeconds
                turns.append(turn)
            case "toolResult":
                guard let callId = m["toolCallId"]?.stringValue,
                      let t = turns.lastIndex(where: { $0.toolUses.contains { $0.id == callId } }),
                      let r = turns[t].toolUses.firstIndex(where: { $0.id == callId })
                else { continue }
                turns[t].toolUses[r].result = PiMessage.text(m)
                turns[t].toolUses[r].isError = m["isError"]?.boolValue ?? false
                let denied = m["details"]?["denied"]?.boolValue ?? false
                turns[t].toolUses[r].status = denied ? .denied : .completed
            default:
                // System messages hold the prompt and tools; nothing to draw.
                continue
            }
        }
        return turns
    }

    /// A stable turn id from an entry id: pi's 8 hex characters, or a full UUID.
    static func turnId(_ entryId: String) -> UUID {
        UUID(uuidString: entryId)
            ?? UUID(uuidString: "\(entryId)-0000-4000-8000-000000000000")
            ?? UUID()
    }

    /// The stored attachments with their pixels back, from the message's image blocks.
    private static func attachments(_ stored: [TurnAttachment], images: [Data]) -> [TurnAttachment] {
        var images = images[...]
        var result = stored.map { a -> TurnAttachment in
            guard a.type == .imageCapture, let data = images.popFirst() else { return a }
            return TurnAttachment(
                id: a.id, type: a.type, label: a.label, textContent: a.textContent,
                imageData: data, pageIndex: a.pageIndex
            )
        }
        // Images the display entry does not describe still show.
        result += images.map { TurnAttachment(type: .imageCapture, label: "Image", imageData: $0) }
        return result
    }
}

private extension PiSession.Display {
    mutating func merge(_ other: PiSession.Display) {
        content = other.content ?? content
        metadata = other.metadata ?? metadata
        attachments = other.attachments ?? attachments
        thinkingSeconds = other.thinkingSeconds ?? thinkingSeconds
    }
}
