# Slack's composer ("texty"), as recovered from its cached bundles

Read on 2026-10-15/16 from Slack desktop's Service Worker cache,
`~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Service Worker/CacheStorage/4c237d5e…/506b9f7a…/`.
Read-only research on a locally installed app; no Slack code was run, and none is
copied here. Offsets are byte offsets into the cache entries below.

| entry | content |
|---|---|
| `53647c3f99aa5678_0` | chunk `gantry-v2-shared-boot-async`; texty is module `9b2R` (@23771890–24058357), plus English UI strings |
| `3f6e0ee99889e5f5_0` | vendor chunk: Quill `1.3.7-slack8` (@1068528), keyboard bindings (@~1122950–1131700) |
| `d42e0e7c908fedab_0` | module `SM/6`: the inline markdown regexes (@4827051) |
| `10a7f5e956a1d210_0` | composer CSS |

**What this method gives.** Minified JS keeps string literals, Quill binding names and
Slack's own function names, so behaviour and its conditions are readable. It does not
show anything running: every claim below is read, not seen.

---

## 1. Data model

- The document is a **Quill Delta** (Quill 1.3.7 fork with a 2.x-style code-block
  container). Lists, quotes and code blocks are **line formats**; a `border:1` line
  format marks a list or code line nested in a quote.
- **Lists are flat**: `{list: bullet|ordered, indent: n}` per line, no tree. Serialization
  (`convertDeltaToBlocks`, module `8J14`) starts a new `rich_text_list` when style or
  indent changes and keeps a counter per indent level as `offset`.
- **A mention is formatted text, not an embed**: `{insert:"@Alice", attributes:{slackmention:{id,label}}}`.
  It stays a mention only while its text equals `label`; extra text on either side
  loses the format, any other edit removes it (`buildUnformatBrokenMentionsChanges`).
- Ordered-list numbers come from CSS counters, so they renumber by construction.

## 2. Change pipeline (`getTextChangeQueueModule` @23929407)

One text change → about 11 rules (sanitize, link, mention, emoji, markdown, smart
quotes, cleanups), each returning a delta, composed in order, applied **once** in
`setTimeout(0)` with a re-entry flag. **During IME composition no rule runs**; changes
are composed and processed once on `compositionend`. Markdown runs only when the
inserted text is exactly one delimiter character.

## 3. Undo

Quill history defaults (delay 1000 ms, maxStack 100). Slack sets the delay to **0
around each markdown conversion**, so ⌘Z after `*x*` → **x** brings back `*x*`;
substitutions (`--` → `—`) rewrite the stack so ⌘Z restores the typed characters.

## 4. Keyboard

| binding | behaviour |
|---|---|
| `"outdent backspace"` | Backspace at offset 0 of a list line: outdent, then remove the list |
| `"list empty enter"` | Enter on an empty list item leaves the list |
| `on_enter_onEnter` | in a **code block or quote, Enter on the second blank line** leaves it and drops the blank; inline marks carry to the new line |
| `"backspace non-empty single line blockquote"` | Backspace at offset 0 of a quote removes the quote, keeps text |
| formatting | ⌘B, ⌘I, ⌘⇧X strike, ⌘⇧C code, ⌘⇧7 / ⌘⇧8 lists, ⌘⇧9 quote, ⌘⌥⇧C code block, ⌘⇧U link (`getFormattingBindings` @23868822) |
| send | ⌘Enter always sends; ⇧Enter / ⌥Enter newline; Enter per preference (`shouldInsertNewline`) |
| Tab / ⇧Tab | change a list line's indent by one |

## 5. Markdown shortcuts

Single delimiters (`*` bold, `_` italic, `~` strike, `` ` `` code); an opener must follow
line start, whitespace, punctuation, `+ | =`; no whitespace just inside; one line only;
never in code (`SM/6` regex). ` ``` ` makes a code block, `>` at line start a quote,
`1.`/`-`/`*` + Space a list. Backspace right after a conversion restores the literal.

## 6. Clipboard (`getPlainClipboardModule` @23830528)

Paste order: markdown check (asks via toast), table, `slack/block-kit`, **`slack/texty`
(Slack's own lossless copy)**, Slack HTML, **external HTML cut to a whitelist** of
12 formats (bold, italic, strike, code, link, underline, code-block, list, blockquote,
mention, slug, indent ≤ 4), plain text (trailing spaces trimmed). **Code blocks take
plain text only.** `javascript:` and malformed links become plain text.

## 7. Toolbar and completion

- Buttons: bold, italic, underline, strike | link | ordered, bullet | quote | code,
  code block. **Disabled inside a code block** (except block buttons) and **bold
  disabled in a heading** (`shouldDisableButton`).
- Completion (`@` `#` `:` `/`): a valid character must precede the trigger; emoji need
  3 query characters; results are **tiered** (frecency, prefix/fuzzy); Enter/Tab picks
  the first item when none is highlighted; a trailing space is inserted.

## 8. Composer tokens (CSS)

15 px text, line-height 1.46668 (22 px); padding 8/12; height from
`--min-lines`/`--max-lines` × 22 px + 16; list indent step 28 px; quote: 4 px bar,
16 px indent; code block: 1 px `#ddd` sides, `#f8f8f8`, 8 px padding, 12 px Monaco.

---

## What OakReader's note editor took (2026-10-16)

| Slack design | OakReader | where |
|---|---|---|
| IME holds back all formatting | already: `handleTextChange` skips math, `keyDown` passes every key to the IME | `NoteEditorTextView` |
| conversion is its own undo step | `beginShortcutUndoStep()` closes the typing group first | `NoteEditorTextView` |
| Backspace at a block start removes the block | `removeBlockAtCaretIfAtStart()` (lists, quote, heading, code) | `NoteEditorTextView` |
| Enter on second blank line leaves code / quote | `removePrecedingBlankLine(in:)` | `NoteEditorTextView` |
| numbers renumber | `renumberOrderedLists()` (markers are text here, not CSS counters) | `NoteEditorTextView` |
| paste whitelist, lossless private type, plain text in code | `NoteEditorTextView+Paste.swift` (`com.oakreader.note-markdown`) | new file |
| formatting shortcuts | `performKeyEquivalent` | `NoteEditorTextView` |
| bold disabled in a heading | toolbar | `NoteComposerBox` |
| tiered completion | `matchRank`: prefix, word start, substring, description | `ChatCompletionItem` |

**Deliberately different.**
- `*x*` is italic, not bold: notes are stored as standard markdown.
- Markdown in a plain-text paste is converted without asking (Slack shows a toast);
  ⌘⇧V pastes it literally.
- Backspace also removes quote, heading and code blocks at their start; Slack's
  binding covers lists and single-line quotes.

**Not taken yet.** Tab / ⇧Tab list nesting (needs an indent level in the model and
codec), mentions that unformat when edited, emoji completion, draft autosave.

**Tests.** `tools/note-editor-harness` drives the real editor files offscreen:
`swift run --package-path tools/note-editor-harness` (63 checks).
