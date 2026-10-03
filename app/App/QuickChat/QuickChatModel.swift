import AppKit
import Foundation

// MARK: - Phase

/// The panel is one window with two faces: the skill list, then the result in
/// its place (§1). `⌘[` goes back.
enum QuickChatPhase: Equatable {
    case choosing
    case streaming
    case done
    case stopped
    case failed(String)

    var hasResult: Bool {
        switch self {
        case .done, .stopped: return true
        case .choosing, .streaming, .failed: return false
        }
    }
}

// MARK: - Destination

enum QuickChatDestination: String, CaseIterable, Identifiable {
    case replace
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: return "Replace selection"
        case .copy: return "Copy result"
        }
    }

    var icon: String {
        switch self {
        case .replace: return "arrow.left.arrow.right.square"
        case .copy: return "doc.on.doc"
        }
    }

    var shortcut: String {
        switch self {
        case .replace: return "⌘R"
        case .copy: return "⌘C"
        }
    }
}

// MARK: - Turn

/// One exchange in the panel. The instruction you gave, then the answer.
struct QuickChatTurn: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }

    let id: Int
    let role: Role
    var text: String
}

// MARK: - Model

/// State shared between the hosting `QuickChatPanel` (AppKit) and `QuickChatPanelView`
/// (SwiftUI), mirroring `CommandPaletteModel`.
@Observable
final class QuickChatModel {

    // Capture
    var capture = QuickChatCapture(
        text: "", isWritable: false, sourceKind: .unknown, isMyLanguage: false
    )

    // Skill list
    var query: String = ""
    var selectedIndex: Int = 0

    // Result
    var phase: QuickChatPhase = .choosing
    var result: String = ""
    /// The exchange so far. The newest assistant turn is the one `result`
    /// streams into; everything before it is settled.
    private(set) var turns: [QuickChatTurn] = []
    private var nextTurnID = 0
    /// The skill that produced `result`, so the result header can name it.
    var ranSkill: QuickChatSkill?

    /// Drives the pop-in / fade-out transition.
    var isVisible: Bool = false
    /// 800 ms "✓ Copied" / "✓ Added" feedback on the action bar.
    var confirmation: String?

    // Wired by the panel / controller.
    var onDismiss: (() -> Void)?
    var onRun: ((QuickChatSkill) -> Void)?
    var onDeliver: ((QuickChatDestination, String) -> Void)?
    var onStop: (() -> Void)?
    /// A typed instruction applied to the result already on screen.
    var onRefine: ((String) -> Void)?
    var requestFocus: (() -> Void)?
    /// The card's measured height, so a standalone panel can size to it.
    var onCardHeight: ((CGFloat) -> Void)?
    /// True while the panel is floating over another application.
    var isStandalonePresentation = false

    private var allSkills: [QuickChatSkill] = []
    private var confirmationTask: Task<Void, Never>?

    /// Written after the verb on the Translate row, read as "Translate → 中文".
    /// Cida's inline target rather than a language dropdown (§7).
    private(set) var targetLanguageLabel: String = ""

    // MARK: Skills

    /// Skills come from the core's loader — the same set the chat and the CLI
    /// see — minus the ones that need a whole document behind them.
    @MainActor
    func loadSkills(targetLabel: String) {
        allSkills = QuickChatSkill.available
        targetLanguageLabel = targetLabel
    }

    func skill(id: String) -> QuickChatSkill? {
        allSkills.first { $0.id == id }
    }

    /// Applicable skills first, demoted ones after, each group ordered by
    /// frecency so the skill you actually use rises to the top (§5).
    /// True while the field is in skill-picking mode. The list is a `/` mode,
    /// exactly as it is at the start of the chat input — otherwise this is an
    /// ordinary composer and what you type is what runs.
    var isPickingSkill: Bool { query.hasPrefix("/") }

    var rankedSkills: [QuickChatRow] {
        let isSlashScoped = query.hasPrefix("/")
        let needle = isSlashScoped ? String(query.dropFirst()) : query

        let filtered = allSkills.filter { skill in
            needle.isEmpty || Self.matches(skill.name, query: needle)
        }
        let applicable = filtered.filter { $0.applies(to: capture) }
        let demoted = filtered.filter { !$0.applies(to: capture) }

        var rows = (applicable.sorted { score($0) > score($1) }).map {
            QuickChatRow(skill: $0, isDemoted: false)
        }
        rows += (demoted.sorted { score($0) > score($1) }).map {
            QuickChatRow(skill: $0, isDemoted: true)
        }

        // Nothing matched what was typed: offer it as a one-off instruction.
        // Not under `/`, which means "a skill, specifically".
        if rows.isEmpty, !isSlashScoped,
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows = [QuickChatRow(
                skill: QuickChatPromptBuilder.adHocSkill(
                    instruction: query, isWritable: capture.isWritable
                ),
                isDemoted: false,
                isAdHoc: true
            )]
        }
        return rows
    }

    /// Subsequence match, so "pol" finds "Make it polite" and "mic" does not.
    private static func matches(_ name: String, query: String) -> Bool {
        let haystack = name.lowercased()
        let needle = query.lowercased()
        if haystack.contains(needle) { return true }
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    // MARK: Selection

    func moveSelection(down: Bool) {
        let count = rankedSkills.count
        guard count > 0 else { return }
        selectedIndex = down
            ? min(selectedIndex + 1, count - 1)
            : max(selectedIndex - 1, 0)
    }

    func activateSelection() {
        switch phase {
        case .choosing:
            if isPickingSkill {
                let rows = rankedSkills
                guard selectedIndex >= 0, selectedIndex < rows.count else { return }
                run(rows[selectedIndex].skill)
                return
            }
            let instruction = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            run(QuickChatPromptBuilder.adHocSkill(
                instruction: instruction, isWritable: capture.isWritable
            ))
        case .done, .stopped:
            // With something typed, ⏎ refines the answer on screen; empty, it is
            // the action bar's primary action. One field, and what it does is
            // whatever is in it.
            let instruction = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if instruction.isEmpty {
                onDeliver?(primaryDestination, result)
            } else {
                onRefine?(instruction)
            }
        case .streaming:
            break
        case .failed:
            if let ranSkill { run(ranSkill) }
        }
    }

    func run(_ skill: QuickChatSkill) {
        query = ""
        if !skill.isRefinement {
            turns.removeAll()
        }
        append(.user, skill.name)
        append(.assistant, "")
        noteUse(skill)
        ranSkill = skill
        result = ""
        phase = .streaming
        onRun?(skill)
    }

    /// Clears the exchange. Every summon starts a new one — the panel is about
    /// the text selected right now, and showing the previous conversation over a
    /// different selection is simply wrong content.
    func resetTurns() {
        turns.removeAll()
        result = ""
        ranSkill = nil
    }

    private func append(_ role: QuickChatTurn.Role, _ text: String) {
        turns.append(QuickChatTurn(id: nextTurnID, role: role, text: text))
        nextTurnID += 1
    }

    /// Mirrors the streaming buffer into the open assistant turn, so the
    /// transcript and the delivered result are never two different strings.
    func streamDelta(_ delta: String) {
        result += delta
        if let last = turns.indices.last, turns[last].role == .assistant {
            turns[last].text = result
        }
    }

    /// Back to the skill list, keeping the capture. The result is discarded —
    /// re-running is one keystroke and stale results are worse than none.
    func backToList() {
        guard phase != .choosing else { return }
        phase = .choosing
        result = ""
        turns.removeAll()
        ranSkill = nil
        requestFocus?()
    }

    // MARK: Destinations

    /// Replace is the primary action only where the result can actually be
    /// written back; everywhere else Copy is, and Replace does not appear at
    /// all (§6). Phase 1 captures from the viewer, so this is Copy today.
    var primaryDestination: QuickChatDestination {
        guard let ranSkill else { return .copy }
        if ranSkill.disposition == .replace && capture.isWritable { return .replace }
        return .copy
    }

    /// The actions offered under an answer, primary first. Replace never
    /// appears where it cannot work.
    var availableDestinations: [QuickChatDestination] {
        var list = [primaryDestination]
        for destination in QuickChatDestination.allCases where destination != primaryDestination {
            if destination == .replace && !capture.isWritable { continue }
            list.append(destination)
        }
        return list
    }

    /// Tab completes the highlighted skill into the filter field, as Raycast's
    /// Tab completes the selected item into its search bar.
    func completeSelection() {
        let rows = rankedSkills
        guard selectedIndex >= 0, selectedIndex < rows.count, !rows[selectedIndex].isAdHoc else { return }
        query = rows[selectedIndex].skill.name
        selectedIndex = 0
    }

    /// Esc steps back from the result to the list before it closes, the way Esc
    /// walks back one level in Raycast.
    func escape() {
        if phase == .choosing {
            onDismiss?()
        } else {
            backToList()
        }
    }

    func confirm(_ message: String) {
        confirmationTask?.cancel()
        confirmation = message
        confirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            confirmation = nil
        }
    }

    // MARK: Frecency

    private static let frecencyKey = "acornSkillFrecency"

    private func score(_ skill: QuickChatSkill) -> Int {
        let store = UserDefaults.standard.dictionary(forKey: Self.frecencyKey) as? [String: Int]
        return store?[skill.id] ?? 0
    }

    private func noteUse(_ skill: QuickChatSkill) {
        guard !skill.id.isEmpty, skill.id != "ad-hoc" else { return }
        var store = UserDefaults.standard.dictionary(forKey: Self.frecencyKey) as? [String: Int] ?? [:]
        store[skill.id, default: 0] += 1
        UserDefaults.standard.set(store, forKey: Self.frecencyKey)
    }
}

// MARK: - Row

struct QuickChatRow: Identifiable {
    let skill: QuickChatSkill
    let isDemoted: Bool
    var isAdHoc: Bool = false

    var id: String { skill.id }
}
