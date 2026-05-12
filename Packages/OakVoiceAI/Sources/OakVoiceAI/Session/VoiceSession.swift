import Foundation

/// A single turn in a voice conversation (one user utterance + one assistant response).
public struct VoiceTurn: Identifiable, Sendable {
    public let id: UUID
    public let userText: String
    public let assistantText: String
    public let startedAt: Date
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        userText: String,
        assistantText: String,
        startedAt: Date,
        completedAt: Date
    ) {
        self.id = id
        self.userText = userText
        self.assistantText = assistantText
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Tracks conversation state across voice turns.
public final class VoiceSession: Sendable {
    private let _turns: LockedState<[VoiceTurn]>
    private let _messages: LockedState<[VoiceMessage]>

    public var turns: [VoiceTurn] { _turns.value }
    public var messages: [VoiceMessage] { _messages.value }

    public init() {
        _turns = LockedState([])
        _messages = LockedState([])
    }

    public func addTurn(_ turn: VoiceTurn) {
        _turns.withLock { $0.append(turn) }
    }

    public func addMessage(_ message: VoiceMessage) {
        _messages.withLock { $0.append(message) }
    }

    public func reset() {
        _turns.withLock { $0.removeAll() }
        _messages.withLock { $0.removeAll() }
    }
}

// MARK: - Thread-safe wrapper

/// A simple lock-based wrapper for thread-safe access to a value.
final class LockedState<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    init(_ value: Value) {
        self._value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }
}
