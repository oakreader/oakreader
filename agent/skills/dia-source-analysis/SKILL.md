---
name: dia-source-analysis
description: "Analyze / reverse-engineer the locally installed Dia Browser mac app (The Browser Company; bundle id company.thebrowser.dia; shares ArcCore with Arc). Inspect its app bundle, read its system-prompt text and fine-tuned model ids straight out of the binary, recover native-Swift structure via reflection metadata, and map its AI-chat rendering, citation/grounding, on-device-ML and sandbox architecture. (Its Bun/TypeScript agent-server was recoverable from source maps up to 1.32.x; those no longer ship.) Invoke when the user wants to study how Dia works internally, see how Dia prompts a model or renders/anchors citations, or compare Dia's approach against OakReader. (User sometimes voice-types the name as 'DotBrowser' — same app.)"
---

# Analyze Dia Browser source

Dia (`/Applications/Dia.app`, The Browser Company, `company.thebrowser.dia`) is a
WebKit-based browser (~1.3 GB) that shares `ArcCore.framework` with Arc. We use it as a
reference for AI-chat UX. This skill captures how to dig into it and what's already known,
so analysis doesn't start from scratch each time.

## Golden rules

- **Read-only, on the user's own machine, for research.** This is proprietary code shipped
  to the user. Use it to *understand and learn*, never to copy/redistribute verbatim or
  ship lifted code. State this caveat when sharing recovered source.
- **Verify before trusting old findings.** The "Established facts" below are version-stamped.
  Dia auto-updates (Sparkle); bundle layout, file hashes, runtime versions, and even whether
  source maps ship can all change. Always re-read `info.json` + `CFBundleShortVersionString`
  first and treat mismatches as "re-derive from scratch."
- **Two recoverability tiers:** the Bun/TS agent backend is near-fully recoverable (source
  maps); the native Swift app is symbols/structure only (no real source).

## Established facts (as of Dia 1.49.1 — RE-VERIFY)

Agent-server `info.json` (1.49.1): version 1.0.0, buildDate 2026-09-18, commit `6dd0e8a6318`,
`claudeCodeVersion 2.1.250`. (1.34.2 was commit `47de9fbe6c4` / `claudeCodeVersion 2.1.131`.)
Bundled `claude` CLI reports **Bun v1.4.1**. Everything in this section was re-verified against
1.49.1 on 2026-09-26; the chat-render and on-device-ML findings below were unchanged from 1.35.2.

- **⚠️ Source maps NO LONGER SHIP as of 1.34.2.** `extract-sourcemaps.py` returns "No .map
  files found" — the Bun/TS agent-server backend is no longer recoverable as near-original TS
  (only logic compiled into the Mach-O remains). The native-Swift tier is unchanged: symbols +
  embedded source paths only. So "the big win" in §1 below is gone on current builds; keep the
  procedure for older installs / in case they return.
- **The AI-chat INPUT is the native AppKit module `BoostCommandBar`** (`Frameworks/BoostBrowser/
  Sources/BoostCommandBar/*`): `CommandBarRootViewController` → `InputController`/`TextContainerView`
  (a token/pill `TokenTextView` w/ `TokenAttachment`+`SkillPillTokenViewProvider`), `ToolbarController`
  (plus/send/`DictationController`), `SuggestionsController`, `SkillsV3PanelController`,
  `AttachmentsController`. Skills = `SkillsV3` (first-party `PreinsalledSkillIDs` + `CustomSkillV3`
  store + `SkillBuilder`); `@`-mentions (`AtMentionKeywords`: @Search/@Slack/@Gmail/@Notion) insert
  context/tool pills. On-device `cmd_t_router`(3-label intent) + `skills` classifier rank proactive
  suggestions (`matchScore`). Streaming-state UI uses **shimmer skeletons** (`ShimmeringTextView`/
  `ShimmerSkeletonView`/`StreamingPlaceholder*`) and respects Reduce Motion
  (`AnimationRespectingReduceMotionModifier`). See OakReader memory `dia-chat-parity-streaming`.

- **AI chat ("AssistantPanel") renders NATIVELY, not in a webview.** Markdown parsed by
  `cmark` (swift-markdown), code highlighted by **Highlightr** (`CodeAttributedString` →
  NSAttributedString), math by **SwiftMath** (`MTMathListDisplay`, CoreText). UI is AppKit
  `NSViewController`s: `AssistantPanelResponseViewController`, `…ContentViewController`,
  `…HeaderView`, `…ResponseViewModel` (source paths `Frameworks/BoostBrowser/Sources/AssistantPanel/*.swift`).
- **WKWebView (~45 refs) is for web pages + HTML "artifacts"** (reports/slides/morning-brief
  via `report-kit`/`slide-kit`, injected through `merge-template.ts` into `index.html`), NOT
  for chat bubbles.
- **Streaming smoothness** comes from (a) native rendering happening efficiently + (b)
  `session/update-batcher.ts`: deltas are coalesced and flushed only on **≥256 B** OR
  **250 ms idle** OR completion — so the UI updates a few times/sec, not per token. The Bun
  agent-server is backend orchestration and does NOT touch UI perf.
- **Agent backend = Bun-compiled standalone Mach-O** (`agent-server`, `handler`) + **the real
  Claude Code CLI** (`claude`, 206 MB, itself a Bun binary). No separate Node/Bun runtime is
  installed — each binary embeds Bun. They run as **child processes under Seatbelt sandbox**
  (`sandbox-exec -f agent.sb` / `agent-claude-code.sb`, params via `-D DATA_DIR=…`), talking
  to the native UI over SSE/IPC (`transport/sse.ts`, `ipc-gateway.ts`). Per-context workspace
  at `data/contexts/{contextId}` with resumable disk buffers (`session/buffer.ts`, JSONL).
- **Citations** are a first-class subsystem, and the design is the interesting part: **nothing
  the model writes carries a payload.**
  - *Inline source citations.* Every URL in context is numbered by
    `SupertabEngine.SourcesController` (fields `scrapedURLMapState: MapModel`,
    `sourceIDMapChannel: SourceIDMap`, `sourceIDMapNeedsPersistence`), and the model emits
    `[label](url://3)`. Prompt rule, verbatim: `URLs MUST start with "url://". Never use this
    function with URLs that do not contain this prefix.` / `- url:// shortlinks from page
    content (e.g. url://3)`. So a citation destination is ~8 characters — it cannot flash a
    long raw URL mid-stream, and the model cannot invent or misspell a source.
  - *Rendering.* A citation is **not styled text** — it is
    `SupertabFrontend.InlineLinkAttachment : NSTextAttachment` → `InlineLinkAttachmentCell` →
    `InlineLinkAttachmentView : NSControl` (favicon fetch, title label, `isHovered`,
    `InlineSourceTooltipView`). It occupies one glyph slot, so resolving it never reflows the
    paragraph. Same pattern for every rich element: `inlineLinkAttachmentProvider`,
    `inlineSourceAttachmentProvider`, `codeBlockAttachmentProvider`, `tableAttachmentProvider`,
    `latexAttachmentProvider`, `blockQuoteSourceAttachmentProvider`,
    `headerQuoteButtonAttachmentProvider`.
  - *Quote anchors are recovered, not encoded.* To deep-link a quote on a page the model emits
    an ordinary markdown **blockquote** (prompt: "Make sure the block quote matches an excerpt
    of the content precisely"), and the app sources it afterwards — `BlockQuoteSourcingKey` /
    `BlockQuoteSourcingResult` / `BlockQuoteSourcingState`, `blockQuoteSource`,
    `currentBlockQuoteIndex` — driven by `SupertabFrontend.SupertabFindInPageProvider` over
    WebKit's `_performFindInPage`, then attaches a scroll-to button (`assistantHeaderQuoteButton`,
    string "Tooltip for scroll to quote button"). The model never encodes a location.
  - *Timestamps* get their own tiny scheme: `dia://timestamp?…`, plus
    `youtubeDeepLinkTimestampSeconds(youtubeVideoUrl:)`.
  - *They fine-tuned for it* rather than prompting harder: `inlineCitationFineTuned_gpt4_o` =
    `ft:gpt-4o-2024-08-06:the-browser-company:inline-citations:BANvQLvl`, behind a
    `CitationsFormattingMixin`. The prompt itself is only three placement rules — "Attach an
    inline citation at the END of a sentence using descriptive link text, never a bare URL" /
    "There should never be more than one citation per sentence" / "Do NOT make the entire
    sentence a link."
  - Other fine-tunes in the binary: `ft:gpt-4o-mini-…:memory-query-parsing:AoFc6r2Z`,
    `ft:gpt-3.5-turbo-1106:…` (askArc, tabGroup), `ft:gpt-4.1-2025-04-14:…:BNPXuXlk`.

- **On-device ML** (`OnDeviceLoRAadaptors` bundle, 152 M): one shared **DistilBERT-base** encoder
  (126 M, split part1/part2, fp16) + three LoRA adapters + classification heads sharing it —
  `cmd_t_router` (Cmd+T input intent, 3 labels), `skills` (which skill to fire),
  `sensitive_content` (privacy gate for what may go to cloud). Run via MLX (`mlx-swift`) /
  swift-transformers; Swift side `AIDistilBertClassifier` / `LocalClassificationClient.swift`.
  `*_overrides` variants = remotely hot-patchable head/adapter.

## Bundle map

| Path | Size (1.49.1) | What |
|---|---|---|
| `Contents/Frameworks/ArcCore.framework` | ~327 M | browser engine core (WebKit + Arc) |
| `Contents/Resources/agent-server-resources/dist` | ~372 M | Bun agent backend + bundled `claude` CLI (197 M) |
| `Contents/Resources/OnDeviceLoRAadaptors_…bundle` | ~152 M | DistilBERT base + 3 LoRA classifiers |
| `Contents/MacOS/Dia` | ~124 M | native Swift app binary (AssistantPanel etc.) |
| `Contents/Frameworks/libAIInfra.dylib` | ~17 M | on-device classification (`LocalClassification`) |
| `Contents/Resources/*.bundle` | — | Highlightr, SwiftMath, SwiftProtobuf, mlx-swift, swift-transformers, ARC/BoostBrowser feature bundles |
| `dist/*.sb` | — | Seatbelt sandbox profiles |

## Procedure

### 0. Identify version (always first)
```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Dia.app/Contents/Info.plist
cat "/Applications/Dia.app/Contents/Resources/agent-server-resources/dist/info.json"
```

### 1. Recover the agent-server source (HISTORICAL — no maps since 1.34.2)
Try this first anyway; it costs one command and would be the richest source if maps ever return.
Up to 1.32.x, `entrypoint.js.map` and `handler-entrypoint.js.map` shipped with `sourcesContent`
populated → near-original TS. Confirmed absent again at 1.49.1, so on current builds go to §3/§6,
where the prompt text and Swift structure still are.
```bash
python3 agent/skills/dia-source-analysis/scripts/extract-sourcemaps.py --out /tmp/dia-src
```
Yields ~40 "own" TS files (non-node_modules): `agent/harness/claude-sdk/*` (how it drives the
Claude SDK — `prompt-template.ts`, `proxy-tools.ts`, `claude-sdk-in-process.ts`, `sandbox.ts`),
`session/*`, `transport/*`, `handler/*`, `runtime.ts`, `watchdog.ts`, `main.ts`. Also readable
without extraction: `dist/agents/*/spec.yaml`, `dist/agents/*/.claude/`, `dist/resources/tool-schemas/*.json`.

### 2. Fingerprint the runtime
```bash
D=/Applications/Dia.app/Contents/Resources/agent-server-resources/dist
for f in agent-server handler claude; do echo "== $f"; \
  strings -a "$D/$f" | grep -iE "Bun v[0-9]|Bun/[0-9]|node\.js v[0-9]"|sort -u|head; done
```

### 3. Native Swift binary — structure recoverable via `ipsw class-dump --swift` (no bodies)
The symbol table is **stripped** (`nm` ≈ 8.5k symbols, no Swift method-body symbols; debugger
attach is blocked by hardened runtime `flags=0x10000(runtime)` + no `get-task-allow`). But the
Swift **reflection metadata** survives and gives field-level structure — the closest thing to source:
```bash
brew install ipsw   # one-time
BIN=/Applications/Dia.app/Contents/MacOS/Dia
strings -a "$BIN" | grep -iE "AssistantPanel|Highlightr|SwiftMath|cmark|MarkdownText" | sort -u | head
strings -a "$BIN" | grep -c "WKWebView"
# NOTE: the chat code lives in the MAIN Dia binary, NOT ArcCore (which is the web engine).
ipsw class-dump "$BIN" --class 'AssistantPanel'                    # response/content view controllers
ipsw class-dump "$BIN" --class 'Supertab.*(Stream|Markdown|Text)'  # the actual answer renderer
ipsw macho info  "$BIN" --swift-all | grep -i <Type>              # generics (e.g. TextFadeAnimator<…>)
```
This yields class/struct **instance-variable layouts, superclasses, protocol conformances, and
method signatures** — NOT bodies, and NOT the numeric values of fields (e.g. `fadeInDuration`
exists as a field; its `~0.2` value is a code literal, unrecoverable without disassembly). `strings`
still gives demangled type names + embedded source *paths* (`/Users/admin/actions-runner/_work/arc/arc/…`).
Generic classes don't surface as ObjC `@interface`; find them via `--swift-all` / `strings`. For deeper
work use Hopper/Ghidra, but Swift ABI makes UI/animation bodies near-unreadable.

**Recovered chat architecture (Dia 1.35.2, via the above):** answer surface = `SupertabFrontend`
(`AssistantPanel` just hosts a `SupertabController`). Streaming bytes → `SupertabEngine.ResponseStreamParser`
(incremental Node/Element/TextNode tree) → `ThreadMarkdownDataController` → `MarkdownItemView`(NSTextView)
→ `SupertabFrontend.SupertabTextView : NSTextView` whose reveal is a **glyph fade-in**:
`fadeAnimator: AssistantUI.TextFadeAnimator<TextKit1Layout>` (field `fadeInDuration`) +
`trailingLineRevealMaxDelay` — it lays out the full text and fades NEW glyph ranges 0→1 (NOT a
typewriter). Edges masked by `ARCUI.FeatheredContainerView` (CAGradientLayer). Waiting state =
`ShimmeringTextView`(`gradientAnimationDuration`) + `StreamingPlaceholder*` staggered fade. Body font =
system (`-apple-system`); code = `ABCFavoritMono`/SFMono; spacing via `NSLayoutManagerDelegate`
(`lineSpacingAfterGlyphAtIndex`/`paragraphSpacingBeforeGlyphAtIndex`). OakReader replicated the glyph
fade-in natively in `OakMarkdownUI` (see memory `chat-image-and-coalescing-fix`).

### 4. On-device models
```bash
B=/Applications/Dia.app/Contents/Resources/OnDeviceLoRAadaptors_OnDeviceLoRAadaptors.bundle/Contents/Resources
cat "$B/config.json"; ls -lhS "$B"/*.safetensors
strings -a /Applications/Dia.app/Contents/Frameworks/libAIInfra.dylib | grep -iE "cmd_t|router|sensitive|skills_|distilbert|lora" | sort -u | head
```

### 5. Sandbox profiles
```bash
cat /Applications/Dia.app/Contents/Resources/agent-server-resources/dist/agent.sb
cat /Applications/Dia.app/Contents/Resources/agent-server-resources/dist/agent-claude-code.sb
```
These are Seatbelt (`sandbox-exec`) profiles — read them to see exactly what the agent / Claude
Code subprocess may touch (worth borrowing if hardening OakReader's BashTool/file tools).

### 6. Citations / grounding
The prompt text ships as plain strings in the main binary, so the rules are readable directly —
this is the fastest way to see how Dia instructs a model, for citations or anything else:
```bash
BIN=/Applications/Dia.app/Contents/MacOS/Dia
strings -a "$BIN" | grep -iE "citation|inline link|url://|footnote" | sort -u | head -60
strings -a "$BIN" | grep -iE "^\s*-\s.*(link|url|quote|cite)" | sort -u   # the prompt's bullet rules
strings -a "$BIN" | grep -oE "ft:gpt[^\"]*"                                # fine-tuned model ids
ipsw class-dump "$BIN" --class 'InlineLinkAttachment'                       # the citation chip
ipsw class-dump "$BIN" --class 'SourcesController'                          # the url:// id map
strings -a "$BIN" | grep -iE "BlockQuoteSourc|FindInPageProvider|scroll to quote"
```
Note the shape of what you find: Dia's *renderer* names (`…AttachmentProvider`) tell you which
markdown constructs are widgets rather than text, and its *prompt* bullets tell you which rules
it could not get from a fine-tune. Both are more informative than the class list alone.

## Relevance to OakReader

OakReader builds a **native Swift agent** (`packages/OakAgent`: tools, Claude-Code-style skills,
`PathSandbox`) instead of shelling to Claude Code, and renders chat natively via `OakMarkdownUI`
(a WKWebView chat was tried and reverted — see memory `oakagentui-web-chat-migration`). When
comparing:
- Dia's smoothness ≠ its Bun server. It's native-render + delta coalescing. Both halves are now
  matched in OakReader: output memoized via block-splitting, input coalesced in `ChatViewModel`,
  glyph fade-in in `MarkdownTextView`.
- **Citations: adopted 2026-09-26** (`refactor(citation)!`, commit `640b4a94`). OakReader took
  Dia's core move — get the payload out of the link — and replaced
  `oak://cite/{citeKey}?page=&text=<verbatim quote>` with `oak:N` numbered passage handles
  resolved through `CitationSourceRegistry`, the analogue of `SourcesController`. Two deliberate
  divergences, both because OakReader cites *local documents* rather than *web pages*:
  - Handles resolve to a **stable item id**, not a cite key (cite keys are user-editable; keying
    on one forced a rewrite of every stored transcript on rename).
  - Handles name a **passage**, not a whole page, and the registry stores the verbatim text —
    so the highlight is exact by construction. Dia can afford page-level handles plus post-hoc
    `BlockQuoteSourcing` find-in-page because a live WKWebView is searchable; a PDF page is
    the more natural unit here.
  Not adopted: the `NSTextAttachment` citation chip. OakReader draws the chip as a tinted
  capsule behind a real text run (the existing `.inlineCodePill` hook) so the label stays
  selectable and copyable — Dia needs an attachment because its chip carries a favicon image.
- Borrow specifically: the `update-batcher` coalescing pattern, and the Seatbelt sandbox profiles
  for dangerous tools. Do NOT replicate the whole Bun agent-server (wrong tradeoff: +200 M, IPC,
  throws away the native OakAgent).
