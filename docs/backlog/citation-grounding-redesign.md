# Citation & Grounding Redesign — Chunk-ID Citations

**Status:** Phase 0–2 implemented (build-green, not yet runtime-verified); Phase 3–4 designed, not started
**Created:** 2026-06-14
**Related:** `docs/issues/2026-05-14-ai-citation-links.md`, memory `grounded-chat-collection-scoped`, `html-citation-anchoring`

## Problem

The product owner's complaint: **AI chat citations often don't point to the
load-bearing claim.** The model cites an incidental phrase that merely *contains
the answer's keywords* instead of the sentence that carries the thesis or the
evidence. Citations also sometimes fail to highlight at all (the anchor doesn't
match the source text).

This document explains *why* the current design produces that, and proposes a
single mechanism that fixes both the **selection** problem (cite the key claim)
and the **faithfulness** problem (the anchor always resolves), in a way that is
**provider-agnostic** (we do not run Anthropic models in chat).

## Root Causes (current design)

Audited in `LLMContextProvider.swift`, `FTSSearchTool.swift`, `ResearchTool.swift`,
`ChatBubbleView.swift`. Ranked by impact:

1. **Format-only guidance + "cite every statement" → citation spam.** The system
   prompt (`LLMContextProvider.swift:193-198`) tells the model to cite *whenever a
   statement comes from a source*, with no criteria for *which* claim deserves a
   citation and no "when NOT to cite." The load-bearing cite is diluted among
   incidental ones.
2. **"4–8 word verbatim phrase" biases toward catchy fragments**
   (`LLMContextProvider.swift:458`). A short quotable noun-phrase is easy to copy
   exactly; a claim sentence ("X causes Y because Z") is not. The model optimizes
   for *findable*, not *load-bearing*. This also contradicts the verbatim-anchor
   block one section up (`:413-415`), which says "prefer a complete clause."
3. **The model copies the anchor text itself** (`?text=verbatim`,
   `LLMContextProvider.swift:406-419`). Reproducing exact text is error-prone →
   the anchor fails to highlight; and the safest text to reproduce is a short,
   distinctive fragment → reinforces (2).
4. **Retrieval is pure lexical (BM25).** `search_content`
   (`FTSSearchTool.swift:128`) ranks by keyword overlap and returns 200-char
   excerpts (`:227`). It surfaces passages that *contain the query terms* — exactly
   "the phrase with the keywords," not "the phrase that supports the claim."
5. **Context truncated to 4000 chars** in every branch of `buildDocumentContext`
   (`LLMContextProvider.swift:84,99,104,115`) and again at render (`:307`). For
   anything past ~1 page the model can only cite whatever happened to be in a
   retrieved snippet. **This is the actual bug behind "summarize this 20-page PDF"
   — the model only ever sees page 1.**
6. **Quote-as-label convention** (`LLMContextProvider.swift:467-470`,
   `ChatBubbleView.swift:379-386`) rewards picking a phrase short enough to double
   as the visible link text.

## Core Principle

> **The model decides *what* to cite (a semantic judgment it is good at). Code
> decides *where* it is and *what the exact text is* (a lookup it should never
> trust the model to reproduce).**

This is exactly how Anthropic's [Citations API](https://platform.claude.com/docs/en/docs/build-with-claude/citations)
works internally: source text is pre-chunked into sentences, the model references
a chunk, and the system extracts the verbatim `cited_text` and its location. We
reimplement this **at the application layer** so it works with any provider. The
["Anthropic-Style Citations with Any LLM"](https://medium.com/data-science-collective/anthropic-style-citations-with-any-llm-2c061671ddd5)
write-up is the minimal version of the same idea (two-level chunk/sentence IDs;
`<CIT chunk_id sentences>` where *"the text inside is your final answer's snippet,
not the chunk text itself"*; regex-resolve back to offsets).

## The Mechanism: Chunk-ID Citations

Instead of the model copying a verbatim quote, the host gives every citable unit
a **stable ID** before the model sees it; the model cites the ID; the host
resolves the ID back to `{page/charRange/time, exact text}`.

```
What the model sees (host-injected):
<source cite-key="vaswani2017">
[c12] (p.2) We propose a new simple network architecture, the Transformer,
            based solely on attention mechanisms.
[c27] (p.3) Scaled Dot-Product Attention computes the dot products of the
            query with all keys.
</source>

What the model emits (label = its own words, anchor = an ID):
The Transformer replaces recurrence entirely with attention
([architecture](oak://cite/vaswani2017?c=c12)).

What the host does at parse time:
?c=c12  →  look up chunk c12  →  page 2 + verbatim text  →  fill CitationAnchor
```

OakReader's existing markdown-link form is **a better fit than the article's
`<CIT>` tag** because the visible `[label]` is already separated from the anchor
(the URL) — no need to instruct "don't put source text in the label."

### Why this fixes the root causes

| Root cause | Fixed? |
| --- | --- |
| #2 short-fragment bias | ✅ removed — IDs have no length preference |
| #3 model copies anchor text (highlight fails) | ✅ removed structurally |
| #6 quote-as-label incentive | ✅ removed — label must be the model's words |
| #1 citation spam | ⚠️ still needs prompt rule ("one cite per claim, when NOT to cite") |
| #4 / #5 retrieval & context window | ⚠️ still needs retrieval + truncation fixes |

### The FTS index *is* the chunk table

Critical implementation shortcut: `FTSIndexService` **already chunks every
document at import** with page / chunk-type / offset (`FTSSearchTool.swift:128,
219-230`). So we do not need a new chunker or a per-turn map for indexed docs:

- "current page's citable chunks" = query the index `WHERE page == currentPage`;
- "retrieved chunks" = retrieval already returns these blocks;
- resolving `?c=N` = look N up in the index → page + exact text.

No whole-document-in-memory, no per-turn state, survives re-render. A long book
does not need to fit in context — the model only ever cites chunks it was given
IDs for, and **cannot cite a chunk it has not seen** (which is correct).

### How chunking actually works (chunk ≠ sentence)

A common misread: "chunking = split the article sentence by sentence." It does
not. The sentence is the *cut boundary*, not the *unit*. From
`ContentChunker.swift`:

- **`chunkPlainText` accumulates whole sentences up to ~500 tokens, then closes
  the chunk** (`:25-37`). A chunk is therefore a paragraph or two — *many*
  sentences — and is never cut mid-sentence. PDF chunks are per-page (`type:
  "page"`, `pageStart=pageEnd=pageIndex`); markdown is heading-aware (each h1–h3
  section, long ones sub-split by sentence, heading prepended).

Three granularities, three jobs:

| Level | What it is | Role |
| --- | --- | --- |
| Sentence | the atom / cut boundary | the span the model picks for `?text=` highlight |
| **Chunk (~500 tok)** | a paragraph or two | the **retrieved + citable** unit (`?c=<id>`) |
| Page / section | grouping | navigation, summary-level anchors |

Why not one-sentence chunks? Retrieval (BM25) needs paragraph-level context to
rank — a lone sentence has too few keywords. But a whole paragraph is too coarse
to *highlight*. Hence the **two-level** design that the whole pilot rests on:
**retrieve & cite at chunk granularity (`?c=<id>`), highlight at sentence
granularity** (the model picks the claim sentence; the host validates it appears
in that chunk). (The "Sentence-level chunk ID" entries in the table below mean
exactly this: a chunk-ID citation whose `?text=` resolves to one sentence.)

**Known gap — CJK sentence splitting.** `splitSentences` (`ContentChunker.swift:
185-197`) only breaks on `.` `?` `!` — *not* on `。！？；`. So Chinese/Japanese
text never sentence-splits: a CJK chunk is one long run bounded only by the
~500-token cap, and sentence-level highlighting degrades to "a big blob" for CJK
documents. Fix is small (add CJK terminators to the split set) and is folded into
Phase 2.

## Task-Aware Context Strategy

"Long" ≠ "doesn't fit." Route on (a) whether the chunked+ID'd content fits the
*active model's* context window, and (b) whether the task is local or global.

```
Does the chunked+ID'd content fit the current model's window?
├─ Yes ───────────────────────────→ load it ALL, model cites chunk IDs
└─ No
   ├─ Local question ("what does X say about Y") → retrieve top-k, cite IDs
   └─ Global task (summarize / outline / "main arguments")
                                     → hierarchical map-reduce over structure,
                                       propagate citations upward
```

| Task | Fits? | Strategy | Citation granularity |
| --- | --- | --- | --- |
| Local Q&A | Yes | Full load | Sentence-level chunk ID |
| Local Q&A | No | Retrieve top-k | Sentence-level chunk ID |
| Summarize / outline | Yes (e.g. 20-page PDF) | Full load | Section/paragraph; one cite per section |
| Summarize / outline | No (whole book) | Map-reduce by chapter/heading | Section-level, propagated up |

Notes:
- **Retrieval is for needle-in-haystack, never for summarization** — top-k misses
  coverage. Summaries must see the whole doc (full load) or map-reduce.
- **The current page is always injected** regardless of retrieval — most reading-
  time questions are about what's on screen.
- **Synthesis statements get no single-sentence anchor.** A summary point that
  compresses a section cites the *section* (`?heading=` or a chunk range
  `?c=c12-c18`), or nothing. Don't force a single-sentence cite onto a synthesis.

## ResearchTool: the ideal pilot

`ResearchTool.swift` already embodies half of this principle and is the cleanest
place to prove the mechanism:

- **Already right:** `sourcesSection` (`:173-203`) builds the Sources list
  *deterministically from what was actually retrieved* via `RetrievalLog`
  (`:71-77, 99-101`) — "generated by the tool (not the model), so it can't list a
  source that was never retrieved." Provenance is reconstructed by code, not
  trusted to the model. **This is exactly our principle, already shipped.**
- **The gap:** inline citations are page-only and model-emitted. The child prompt
  (`:65-66`) says `oak://cite/{citeKey}?page=N` — no `?text=` anchor, and the page
  number is re-typed by the model from memory even though the passage is sitting in
  `RetrievalLog` with its exact page + snippet. **The ground-truth chunk table is
  already materialized and then thrown away at the inline-citation level.**
- **Cross-context is a non-issue here:** the subagent runs in isolated context, so
  resolve all `?c=` → final anchors (with verbatim text from the log) *before
  returning the string to the parent*. The parent then sees ordinary, guaranteed-
  correct `oak://cite` links.
- **UI cleanup:** ResearchTool returns its own markdown `### Sources` section
  (`:194-201`), but `ChatBubbleView.parseCitedSources` *also* renders a Sources
  chip strip from inline links → duplicate sources surfaced to the reader. Drop the
  tool's markdown list; let the shared chip footer be the single source UI.

## Work Breakdown

### Phase 0 — Stop the bleeding (cheap, high impact)

- [x] **Remove/raise the 4000-char truncation.** _(done 2026-06-14)_ Replaced the
  fixed cap in `buildDocumentContext` and the render-time duplicate with
  `LLMContextProvider.documentCharBudget(contextWindow:)` — ~40% of the active
  model's window at ~3 chars/token, floored at 2 000 tokens. Threaded from
  `ChatViewModel.send` via `config.modelInfo?.contextWindow`. A 20-page PDF now
  loads in full on any modern window. _This alone fixes "summarize this PDF only
  saw page 1."_ Build-green.
- [x] **Add explicit selection criteria + "when NOT to cite"** to the system
  prompt. _(done 2026-06-14)_ Replaced the "cite every statement" wording with a
  "What to cite — and what NOT to" block: cite thesis / specific claims-findings-
  causal statements / named stats-dates-quotations; don't cite transitions,
  background, re-paraphrase, restatements, or own synthesis; "one load-bearing cite
  beats several incidental." Build-green.
- [x] **Change anchor granularity wording** from "SHORT phrase (4–8 words)" to "the
  clause/sentence that states the claim." _(done 2026-06-14)_ Updated all three
  blocks — verbatim-anchor rule ("anchor on the CLAIM, not a catchy fragment… core
  assertion = subject+verb+object"), PDF format, and textual format (incl. a new
  example whose label names the idea and whose anchor is the claim sentence).
  Resolved the prior contradiction between the blocks. Build-green.

### Phase 1 — Chunk-ID pilot in ResearchTool

**Anchor-granularity decision (2026-06-14):** chunk ID **+ host-validated
sentence**. The model emits `?c=<id>&text=<claim sentence>`; the host resolves the
page from the chunk (always correct) and keeps the `?text=` quote only if it
actually appears in that chunk's text, else drops to page-only. Precise highlight,
verified quote, model still picks *which* sentence. (Two-level sentence IDs deferred
as a later refinement.)

- [x] Surface a stable chunk ID. _(done 2026-06-14)_ Added `chunkId: Int64?` to
  `FTSIndexService.SearchResult` (the `chunks` table rowid) and to
  `FTSSearchTool.CitedPassage`; added `FTSIndexService.chunks(byIds:)` for
  resolution.
- [x] Print the ID in `FTSSearchTool.formatResults`. _(done 2026-06-14)_ Each
  passage now shows `Cite this passage as: ?c=<id>`; bumped the excerpt window
  200→400 chars so the model sees enough to pick the claim sentence.
- [x] Change `ResearchTool.systemPrompt` from `?page=N` to `?c=<id>&text=<claim
  sentence>`, label in the model's own words, one cite per load-bearing claim.
  _(done 2026-06-14)_
- [x] Resolve `?c=` before returning. _(done 2026-06-14)_ `resolveChunkCitations`
  rewrites every `?c=<id>&text=…` to `?page=&text=` (page from chunk, 1-based;
  quote kept only if it appears in the chunk via case-insensitive,
  whitespace-collapsed containment), so the parent + UI only ever see ordinary,
  verified `oak://` links. Build-green.
- [ ] **Deferred:** drop the markdown `### Sources` section. Kept for now — research
  output is *tool context for the parent model*, not shown to the user directly, so
  it doesn't actually double with the `ChatBubbleView` chip footer; the
  deterministic list is still useful provenance for the parent. Revisit if/when the
  parent surfaces research output verbatim.

Note: `FTSSearchTool.formatResults` is shared with main chat, which now also sees
the `?c=` handle but is not yet told to use it (its prompt still uses `?text=`).
Harmless until Phase 2 wires the main-chat prompt + parse path.

### Phase 2 — Chunk-ID in main chat

- [x] Make `search_content` results carry chunk IDs. _(done — Phase 1, shared)_
- [x] Resolve `?c=<id>` in the main chat. _(done 2026-06-14)_ Extracted the
  ResearchTool resolver into a shared `ChunkCitationResolver` (new file); the main
  chat resolves an assistant turn's `?c=` → validated `?page=&text=` when the turn
  **settles** (`ChatViewModel` `.finished` case → `resolveChunkCitations`). Chosen
  over teaching `CitationAnchor.parse` to hit the DB: parse is a pure static func
  with no service access, and resolve-on-settle persists durable anchors (rowids rot
  on re-index). `CitationAnchor.parse` / `ChatBubbleView` untouched.
- [x] Rewrite the citation-format prompt blocks. _(done 2026-06-14)_ Added a
  "PREFERRED — cite retrieved passages by their `?c=<id>` handle" block to both the
  document-open cross-reference path and the no-document (library-scoped) path.
- [x] **Fix CJK sentence splitting.** _(done 2026-06-14)_ `ContentChunker` now breaks
  on `。！？；…．` as well as `.?!`. Existing CJK docs need a re-index to benefit.
- [x] **Chunk-page-scoped highlight (disambiguation).** _(already present, now
  exercised)_ `PDFDocument.searchQuote(preferredPage:)` already searches the cited
  page first (`PDFDocument+Extensions.swift:62-92`), and `?c=` now resolves to that
  page — so a recurring phrase highlights on the right page automatically. No new
  code needed for PDF; HTML uses `dom-anchor-text-quote` (no pages).
- [x] **Current-page chunk injection.** _(done 2026-06-14)_ The open PDF's current
  page is now injected as numbered `[c<id>]` passages (`FTSDatabase.fetchChunks(forItemId:page:)`
  → `FTSIndexService.currentPageChunks` → `ChatViewModel.currentPageChunks`), and
  `buildSystemPrompt` renders them with a `?c=` cite instruction. The prompt build
  moved **inside the stream task** so the async chunk fetch can be awaited. When the
  page isn't indexed (or non-PDF), it falls back to the raw `<current-page>` text +
  `?text=` path. This unifies the open-document citation onto the same validated
  `?c=` mechanism as retrieved passages — the most-used citation path now gets
  chunk-validated anchors. Build-green. (HTML/markdown stay on `?text=`: they have no
  page index, so per-page chunk injection doesn't map.)
### Phase 3 — Selection quality: agentic loop first, embeddings later (optional)

**Design decision (2026-06-14): strengthen the agentic recursive loop; do NOT lead
with embeddings.** Recall vs. precision is the crux:

- Embeddings improve **recall** — surface passages that are *semantically* near the
  query but share no keywords.
- An agentic read-and-judge loop improves **precision** — the LLM reads candidate
  passages and cites the one that actually *supports the claim*.

The owner's complaint ("cites incidental phrases that merely contain the keywords")
is a **precision/selection failure**, not a recall failure. BM25 returns
keyword-matching junk; citing the top hit blindly cites junk. Embeddings would only
return *semantically* closer candidates — the model could still grab a fragment.
**The loop fixes the actual complaint; embeddings don't, directly.** And the loop
needs zero new infrastructure: `ResearchTool` already is a deep-research loop
(decompose → `search_content` → read → synthesize, `maxIterations: 8`), the LLM
recovers most semantic recall by reformulating queries in natural language, and it
composes directly with the chunk-ID citation stack we just built (read chunk → get
`chunkId`+page → cite `?c=`). Embeddings would be net-new (provider + vector store +
re-index the whole library) and don't target the precision problem.

- [ ] **Explicit relevance judging in the loop.** After retrieving, have the agent
  rate each chunk's support for the question and discard keyword-only matches before
  citing — kill the "incidental phrase" at the source. (This is "re-rank by the
  drafted claim," done by the LLM reading candidates, not by a vector op.)
- [ ] **Gap reflection / loop-until-covered.** "What's still unanswered?" →
  reformulate → search again, until coverage is satisfied (deep-research's reflect
  step). Strengthen `ResearchTool`'s loop and let the main chat lean on it for
  non-trivial questions instead of single-shot `search_content`.
- [ ] **Map-reduce summarization flow** for docs that exceed the window: iterate
  chapters/headings (PDF outline), summarize each section carrying its chunk IDs,
  synthesize with propagated citations. Reuse the `ResearchTool` subagent pattern.
- [ ] **Embeddings as an OPTIONAL later first-stage recall** — only where the loop is
  genuinely weak: **cross-lingual** (English query over a Chinese doc — BM25 fails,
  LLM term-translation is unreliable; multilingual embeddings handle it natively),
  latency-sensitive single-shot answers, and huge corpora where BM25's first page is
  noise. Slot in *behind the same chunk-ID interface* so the loop and citations don't
  change. Not a prerequisite; do this only if the agentic loop proves insufficient.

### Phase 4 — Model annotations (future direction)

An annotation is just a **persisted citation anchor + a note**. The hard part —
robustly anchoring a model-chosen span to a location in the document — is the same
problem this whole redesign solves, so once citations work, annotation is mostly an
extension. Industry LLM-annotation features (Hypothesis, NotebookLM source
highlights, Adobe AI) converge on the **W3C Web Annotation model's
`TextQuoteSelector`** (`{prefix, exact, suffix}`) rather than fragile offsets.

What OakReader already has:

- PDF persisted highlights — DB-backed overlay (`OverlayPDFPage` /
  `PDFMarkupOverlayController`).
- HTML text-quote anchoring — `window.oakHighlightCitation` + `dom-anchor-text-quote`
  + diff-match-patch (memory `html-citation-anchoring`).

The one real delta vs. a transient citation: **an annotation must outlive
re-indexing, so it cannot store the raw `?c=<chunkId>`** (rowids change). At
save-time, resolve the chunk-ID citation into a durable selector and store *that*.

- [ ] Model side: an `annotate` tool (or `oak://annotate/{citeKey}?c=<id>&text=…&note=…`)
  — model selects the claim sentence + writes a margin note.
- [ ] Resolve side: reuse Phase 1 validation, but additionally **slice
  `{prefix, exact, suffix}` straight out of the chunk text** (a few words on each
  side of the quote) → persist as a stable `TextQuoteSelector` + page + note (not a
  chunkId). We get prefix/suffix for free because the chunk text is in hand — no
  re-prompting the model for disambiguation context the way AnchoredAI must
  (word→sentence→paragraph re-prompt). The selector both **disambiguates** repeated
  phrases and **survives re-indexing/edits** (re-anchor by fuzzy quote, not rowid).
- [ ] Anchor-robustness ladder (shared with citations): exact quote (page-scoped) →
  page/heading → open document. Always yield a navigable anchor; never a broken
  highlight. Hallucinated spans (quote not in chunk) are dropped, per AnchoredAI.
- [ ] Render side: reuse the existing PDF overlay / HTML `oakHighlightCitation`;
  show the note as the annotation's comment.
- [ ] Use case: "AI annotates this paper" — highlight every load-bearing claim with
  a one-line label ("claim" / "evidence" / "gap"), NotebookLM/Hypothesis-style.

This is a separate effort, not part of the citation refactor — listed so the
direction is on record.

## Open Decisions

- **URL scheme:** `?c=<id>` resolved at parse time into the existing
  `CitationAnchor` fields (keeps highlight/hover/footer untouched) — vs. a new
  anchor variant. _Leaning: resolve into existing fields._
- **Chunk ID stability across re-index:** FTS rowids may change on re-index. For
  persisted chat history, store the resolved `page+text` anchor (not the raw `?c=`)
  so old messages still navigate. _Resolve-on-write, persist the anchor._
- **Window-budget fraction:** what share of the model window to spend on document
  context vs. history/tools. Start ~50%, make it a constant.
- **Range citations** (`?c=a-b`) for section-level summary anchors — needed for
  Phase 3, optional earlier.

## Out of Scope

- Switching chat to Anthropic's Citations API (provider-locked; we run multiple
  providers).
- Changing the highlight/anchoring machinery (`dom-anchor-text-quote` for web, PDF
  search) — it already accepts a text quote; we only feed it a *correct* one.
- The Sources-footer visual design (`ChatBubbleView` chips) — unchanged.

## Reference

- Anthropic Citations API — sentence chunking, parsed `cited_text`, "significantly
  more likely to cite the most relevant quotes":
  <https://platform.claude.com/docs/en/docs/build-with-claude/citations>
- Anthropic-Style Citations with Any LLM (minimal app-layer reimplementation):
  <https://medium.com/data-science-collective/anthropic-style-citations-with-any-llm-2c061671ddd5>
- Perplexity leaked prompt (per-claim, "most pertinent", no trailing Sources list):
  <https://github.com/jujumilk3/leaked-system-prompts/blob/main/perplexity.ai_20250112.md>
- NotebookLM: grounded Q&A with expandable per-sentence source passages (selection
  done by retrieval+grounding, not by the model choosing a quotable substring).
- W3C Web Annotation Data Model — `TextQuoteSelector` (`prefix`/`exact`/`suffix`),
  the durable anchoring standard for annotations (Phase 4):
  <https://www.w3.org/TR/annotation-model/>
- AnchoredAI (arXiv 2509.16128) — LLM emits {exact span, disambiguation context,
  comment}; host validates by normalized string match, expands context
  word→sentence→paragraph to disambiguate, filters hallucinated anchors:
  <https://arxiv.org/html/2509.16128v1>
- Text Fragments — browser-native deep linking `#:~:text=prefix-,exact,-suffix`,
  the web standard for "link to an exact spot in text":
  <https://tidbits.com/2025/04/23/text-fragments-enable-deep-linking-on-web-pages/>
- Hypothesis — fuzzy text-quote re-anchoring (`dom-anchor-text-quote`, the same
  family OakReader's HTML citations already use).
