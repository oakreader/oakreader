# Slash Commands and @Mentions in Chat Input

## Summary

Type `/` in the chat input to trigger skill selection. Type `@` to mention context entities (documents, collections, pages) and plugin tool contexts. Both show an inline autocomplete popup above the input field.

## Motivation

Currently skill selection requires the `SkillPickerBar` — a horizontal scroll of 8 hardcoded chips above the chat. This has three problems:

1. **Not discoverable** — users don't know skills exist unless they notice the chip bar
2. **Not extensible** — file-based AgentSkills from plugins/`~/.oakreader/skills/` don't appear
3. **No context scoping** — users can't tell the agent "use this document" or "search this collection" from within the message

Slash commands and @mentions are established patterns (Slack, ChatGPT, Cursor, Discord, Notion) that users already understand.

## Design

### Mental model

```
/  = what to do    (skills, actions, workflows)
@  = what to use   (context entities, plugin tool contexts)
```

### `/` Slash commands — Skills

Typing `/` at the start of input (or after a newline) shows a filtered skill list:

```
┌───────────────────────────────────────────┐
│  /sum▏                                    │
├───────────────────────────────────────────┤
│  📄  /summarize                           │
│      Summarize the full document          │
│                                           │
│  🔍  /suggest-annotations          ← ↑↓  │
│      Suggest key highlights               │
└───────────────────────────────────────────┘
```

**Sources** (unified, in order):
1. Built-in skills from `SkillManager` (Summarize, Explain, Translate, etc.)
2. File-based AgentSkills from `~/.oakreader/skills/`
3. Plugin-sourced skills from plugin skill directories

**Behavior:**
- `/` triggers popup showing all available skills
- Typing more characters filters the list (fuzzy match on name + description)
- `↑`/`↓` to navigate, `Tab` or `Enter` to select, `Escape` to dismiss
- Selecting a skill:
  - Sets `chatVM.selectedSkill` (same as tapping a chip today)
  - Shows a skill badge token in the input: `[📄 Summarize] your message here`
  - The `/command` text is replaced by the token
- User can then type their message after the token
- Pressing backspace on the token removes it (deselects skill)

**Special commands** (not skills, but system actions):
- `/clear` — clear conversation
- `/new` — new chat session
- `/history` — toggle history drawer

### `@` Mentions — Context entities

Typing `@` shows a filtered entity list:

```
┌───────────────────────────────────────────┐
│  @doc▏                                    │
├───────────────────────────────────────────┤
│  Context                                  │
│  📖  @document                            │
│      Include current document text        │
│  📄  @page:5                              │
│      Include specific page(s)             │
│  ✂️   @selection                           │
│      Include current text selection       │
│  📝  @notes                               │
│      Include attached notes               │
│                                           │
│  Library                                  │
│  📚  @library                             │
│      Search across entire library         │
│  📁  @collection:ML Papers               │
│      Scope to a specific collection       │
│                                           │
│  Plugins                                  │
│  📐  @latex                               │
│      Enable LaTeX compilation tools       │
│  🌐  @web-import                          │
│      Enable web import tools              │
│  🎙  @transcription                       │
│      Enable transcription tools           │
└───────────────────────────────────────────┘
```

**Three sections:**

**Context** — scopes what the agent sees:
- `@document` — inject full document text into context (overrides default page-range extraction)
- `@page:N` or `@page:N-M` — inject specific page range
- `@selection` — inject current text selection
- `@notes` — inject attached markdown notes

**Library** — expands the agent's search scope:
- `@library` — enable library-wide search tools
- `@collection:Name` — show a sub-menu of user's collections, scope search to selected one

**Plugins** — activate plugin tool contexts for this conversation:
- `@latex` — make tectonic compilation available to agent
- `@web-import` — make monolith/pandoc available to agent
- `@transcription` — make whisper-cpp available to agent
- Only shows plugins that are enabled AND have their tools installed

**Behavior:**
- `@` triggers popup anywhere in the input (not just at start)
- Multiple `@` mentions allowed in one message: `@document @latex compile this to PDF`
- Selected mentions appear as inline tokens: `[@document] [@latex] compile this to PDF`
- Each mention modifies the `ChatViewModel.send()` behavior:
  - Context mentions → override context snapshot parameters
  - Library mentions → enable/scope search tools
  - Plugin mentions → add plugin tools to the agent's tool list for this message

### Autocomplete popup component

A reusable `CompletionPopupView` that works for both `/` and `@`:

```swift
struct CompletionPopupView: View {
    let items: [CompletionItem]
    let selectedIndex: Int
    let onSelect: (CompletionItem) -> Void

    struct CompletionItem: Identifiable {
        let id: String
        let icon: String           // SF Symbol
        let label: String          // e.g. "/summarize" or "@document"
        let description: String
        let section: String?       // e.g. "Context", "Library", "Plugins"
        let brandColor: String?    // optional tint
    }
}
```

Positioned using `GeometryReader` to float above the input bar, anchored to the cursor position. Max height: 280pt, max 8 visible items, scrollable.

### Interaction with existing SkillPickerBar

Two options:

**Option A: Keep both** — `SkillPickerBar` remains as a quick visual picker, `/` commands add keyboard-driven access. Both set the same `selectedSkill` binding.

**Option B: Replace SkillPickerBar** — `/` commands fully replace the chip bar, freeing vertical space. Empty state shows hint text: "Type / for skills, @ for context".

Recommendation: **Option A for now** (additive, less risk), **Option B later** once `/` commands are proven and the unified skill surface (from the plugin-skill-ux-redesign issue) is built.

### Token display in input

Tokens are styled inline in the NSTextView using `NSAttributedString`:

```
[📄 Summarize] [@document] what are the key findings?
 ^^^^^^^^^^^^   ^^^^^^^^^^
 rounded bg     rounded bg
 accent color   blue tint
 not editable   not editable
```

Implementation: use NSTextAttachment or custom NSAttributedString attributes with a custom `NSLayoutManager` drawing pass. Tokens are:
- Not editable (cursor skips over them)
- Deletable with backspace (whole token removed)
- Stored as metadata on the message, not as text content

### What gets sent to the agent

The tokens are **not** included in the message text. They modify the `send()` call parameters:

```swift
// User types: [/summarize] [@document] [@latex] what are the key findings?
// ChatViewModel receives:
chatVM.send(
    text: "what are the key findings?",        // clean text only
    skill: .summarize,                          // from /summarize token
    contextOverrides: [.fullDocument],          // from @document token
    enabledPluginTools: ["latex"]               // from @latex token
)
```

## Requirements

### Phase 1 — `/` slash commands

- [ ] Detect `/` at input start in `ChatNSTextView.textDidChange`
- [ ] Build `CompletionPopupView` with filtered skill list
- [ ] Keyboard navigation: ↑↓ to navigate, Tab/Enter to select, Esc to dismiss
- [ ] On select: replace `/text` with skill token, set `selectedSkill`
- [ ] Render skill token as styled `NSAttributedString` with accent color background
- [ ] Backspace on token removes it and clears `selectedSkill`
- [ ] Include all skill sources: SkillManager + SkillLoader (unified)
- [ ] Add system commands: `/clear`, `/new`, `/history`

### Phase 2 — `@` mentions

- [ ] Detect `@` anywhere in input text
- [ ] Build sectioned completion popup (Context / Library / Plugins)
- [ ] Allow multiple `@` mentions per message
- [ ] Render mention tokens inline with blue tint background
- [ ] `@document` and `@page:N` override context snapshot in `LLMContextProvider`
- [ ] `@selection` captures current text selection at send time
- [ ] `@notes` injects attached note content
- [ ] `@library` enables library search tools
- [ ] `@collection:Name` shows sub-list of collections, scopes search
- [ ] `@plugin-name` adds plugin tools to agent tool list for this message

### Phase 3 — Polish

- [ ] Fuzzy matching for completion filtering (not just prefix)
- [ ] Show recently used skills/mentions first
- [ ] Keyboard shortcut hints in popup (e.g. "Tab to select")
- [ ] Evaluate replacing SkillPickerBar with inline-only interaction
- [ ] Persist last-used mentions per document (e.g. always use `@document` for this PDF)
- [ ] Empty-state hint text: "Type / for skills, @ for context"

## Affected areas

| Area | File | Change |
|------|------|--------|
| Text input | `ChatInputTextView.swift` | Detect `/` and `@`, show popup, insert tokens |
| Text view | `ChatNSTextView` | Token rendering, keyboard routing for popup navigation |
| New view | `CompletionPopupView.swift` | Autocomplete popup component |
| Chat view | `AIChatView.swift` | Host popup overlay, coordinate positioning |
| Chat VM | `ChatViewModel.swift` | Accept context overrides, plugin tool activation in `send()` |
| Context | `LLMContextProvider.swift` | Support context override parameters |
| Skill picker | `SkillPickerBar.swift` | Sync with `/`-selected skill (Phase 1: keep, Phase 3: evaluate removal) |
| Skill loader | `SkillLoader.swift` | No change (already loads from all sources) |
| Plugin service | `PluginService.swift` | Query installed plugin tools for `@` completion |

## Precedent in other apps

| App | `/` does | `@` does |
|-----|----------|----------|
| ChatGPT | Not used | `@gpt-name` switches active GPT/plugin |
| Cursor | `/` commands (edit, explain, test) | `@file`, `@codebase`, `@docs`, `@web` |
| Slack | `/commands` (giphy, remind, etc.) | `@user`, `@channel` |
| Notion | `/` block types (heading, table, etc.) | `@page`, `@person`, `@date` |
| Discord | `/commands` per bot | `@user`, `@role` |
| Codex | Implicit (LLM reads skill desc) or `/skill:name` | Not used |
| **OakReader** | **Skills + system commands** | **Context + library + plugins** |

OakReader's `/` maps closest to Cursor's slash commands. OakReader's `@` maps closest to Cursor's `@file`/`@codebase`/`@docs` — scoping context — with the addition of plugin tool activation.
