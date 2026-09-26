import Foundation

/// The static half of the system prompt, fetched from the core.
///
/// The text lives in `prompts/` as Markdown — `base.md` plus named mixins —
/// so changing what the assistant is told is an edit to a file, not a Swift
/// rebuild followed by a notarized release. Dia ships its prompts the same
/// way, beside the binary rather than inside it.
///
/// What this does NOT cover is the other half: the open document, the active
/// collection, the tab list. That is assembled in `LLMContextProvider`,
/// because nothing but the shell knows it.
enum PromptCatalog {
    /// Mixins every chat turn includes, in order.
    ///
    /// A list rather than "everything in the directory" so that adding a file
    /// is inert until something asks for it — the same reason Dia's agents
    /// name their mixins instead of globbing.
    static let chatMixins = ["math-formatting"]

    /// Compose `base.md` plus the named mixins.
    ///
    /// Returns empty when the core has no prompt files, which is survivable:
    /// the caller appends context regardless, and an empty policy section is
    /// better than refusing to answer.
    static func compose(mixins: [String]) async -> String {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.promptsCompose,
                params: RPC.PromptsComposeParams(mixins: mixins),
                as: RPC.PromptsComposeResult.self)
            return result.text ?? ""
        } catch {
            Log.error(Log.store, "prompts/compose failed: \(error.localizedDescription)")
            return ""
        }
    }
}
