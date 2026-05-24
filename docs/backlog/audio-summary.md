# Audio Summary

**Status:** Backlog
**Created:** 2026-05-15

## Goal

Let users turn any library item — PDF, web snapshot, markdown note — into a listenable audio summary. The core loop:

```text
Read/save → generate script → synthesize speech → listen in-app or in Apple Podcasts
```

OakReader already has the building blocks: OakVoiceAI (TTS with MLX local + ElevenLabs cloud), AI chat with deep document context, the Character system with 26 voice personas, and an attachment model that supports `ContentType.audio`. This feature connects them into a single workflow.

## Why This Matters

NotebookLM's Audio Overviews proved the demand: 100M+ plays, 2M+ users, fastest-adopted feature in the product's history. The appeal is straightforward — people save articles they never read. Audio turns a guilt-ridden "read later" list into a passive listening queue for commutes, walks, and chores.

OakReader's advantage over NotebookLM:

| | NotebookLM | OakReader |
|--|-----------|-----------|
| Source types | Upload-only (PDF, Docs, URL) | Local library with sync (PDF, web, markdown, YouTube) |
| Voice | Fixed dual-host style | Character system — pick Alan Kay, Feynman, or custom voice |
| AI provider | Gemini only | Claude / OpenAI / Gemini, user's choice |
| Offline | No | MLX on-device TTS possible |
| Distribution | Web-only playback | In-app player + Podcast RSS feed |
| Integration | Standalone product | Tied to reading/annotation/citation workflow |

## Key Design Decisions

### Script Style

Support multiple styles from the start, matching NotebookLM's approach but leveraging our Character system:

| Style | Description | Typical Length |
|-------|-------------|---------------|
| **Brief** | Key takeaways in 2–3 minutes | 400–600 words |
| **Deep Dive** | Section-by-section walkthrough | 1500–3000 words |
| **Conversation** | Two-character dialogue (the NotebookLM style) | 2000–4000 words |
| **Critique** | One character analyzes strengths and weaknesses | 800–1500 words |

The Conversation style requires two Characters; the other three use a single narrator.

### Voice Selection

Reuse the existing Character system rather than introducing a separate voice picker:

- Each Character already has a `ttsVoice` config (ElevenLabs voice ID or MLX model).
- User picks one Character for single-narrator styles, two for Conversation style.
- Default: a built-in "OakReader Narrator" character optimized for article narration.

### TTS Provider Strategy

| Provider | Latency | Quality | Cost | Offline |
|----------|---------|---------|------|---------|
| ElevenLabs | ~2–5s per chunk | Highest | ~$0.30/1000 chars | No |
| MLX on-device | ~10–20s per chunk | Good | Free | Yes |

Recommend ElevenLabs as default for quality, MLX as offline fallback. Long-form audio should use chunked synthesis (paragraph-level) with streaming concatenation.

### Storage Model

Audio summaries are stored as Attachments on the parent LibraryItem:

```
~/OakReader/storage/{itemStorageKey}/attachments/{attachmentStorageKey}/
  summary-brief.mp3          # audio file
  summary-brief.json          # script metadata (style, characters, timestamps)
```

- `ContentType.audio`, `LinkMode.importedFile`
- `isPrimary = false` (the original document remains primary)
- One item can have multiple summaries (different styles or characters)

### Podcast RSS Feed

Expose a local HTTP server (or Cloudflare Worker in the sharing phase) that serves a per-user podcast RSS feed:

```
http://localhost:{port}/feed/podcast.xml     → local feed
podcast://localhost:{port}/feed/podcast.xml  → opens Apple Podcasts (local)

https://oakreader.site/p/{userId}.xml       → cloud feed (Phase 3)
podcast://oakreader.site/p/{userId}.xml     → opens Apple Podcasts (cloud)
```

The feed aggregates all audio summaries across the user's library. New summaries appear as new episodes automatically.

---

## Phase 1 — Single-Narrator Audio Summary

Generate a script from document content and synthesize it to audio with one voice.

### Requirements

- [ ] Add "Generate Audio Summary" action to the library item context menu and viewer toolbar.
- [ ] Script generation via AI chat (reuse `LLMContextProvider` for document context).
  - System prompt instructs the model to produce a narration script.
  - User selects style: Brief, Deep Dive, or Critique.
  - User selects Character (defaults to built-in narrator).
  - Script is stored as JSON alongside the audio file.
- [ ] Chunked TTS synthesis.
  - Split script into paragraphs.
  - Synthesize each chunk via `OakVoiceAI` TTS provider (ElevenLabs or MLX).
  - Concatenate chunks into a single MP3/AAC file.
  - Show progress bar during generation.
- [ ] Store result as an `Attachment` with `ContentType.audio`.
- [ ] In-app audio player.
  - Appears in the viewer area when an audio attachment is selected.
  - Play/pause, seek bar, playback speed (0.5×–2×), skip ±15s.
  - Show synchronized script text with current paragraph highlighted.
- [ ] Audio summary list in the right panel.
  - Shows all generated summaries for the current item.
  - Delete, regenerate, or play actions.

### Script Generation Prompt Structure

```text
System: You are a podcast narrator. Given the following document content,
write a {style} narration script. Speak directly to the listener.
Do not include stage directions or speaker labels.
Write in {language} matching the source document.

Keep the script between {min_words}–{max_words} words.
Structure: opening hook → main content → takeaway.

User: [document content from LLMContextProvider]
```

### Affected Areas

- `OakReader/Views/Viewer/MediaViewerView.swift` (extend for audio playback)
- `OakReader/Views/RightPanel/` (new AudioSummaryListView)
- `OakReader/ViewModels/` (new AudioSummaryViewModel)
- `OakReader/Services/` (new AudioSummaryService)
- `OakReader/Services/ImportService+Audio.swift` (store generated audio)
- `OakReader/Services/AI/LLMContextProvider.swift` (reuse for context)
- `Packages/OakVoiceAI/` (expose batch TTS API)

---

## Phase 2 — Conversation Style (Dual Host)

Add the NotebookLM-style two-host dialogue.

### Requirements

- [ ] Conversation script generation.
  - User picks two Characters (Host A and Host B).
  - AI generates a dialogue script with speaker labels.
  - Script format: `[{"speaker": "A", "text": "..."}, {"speaker": "B", "text": "..."}]`
- [ ] Per-speaker TTS.
  - Synthesize Host A lines with Character A's voice.
  - Synthesize Host B lines with Character B's voice.
  - Interleave audio segments with natural crossfade (50–150ms overlap).
- [ ] Conversation player UI.
  - Show speaker avatars (from Character config) alongside transcript.
  - Highlight active speaker during playback.
- [ ] Allow user to provide a focus prompt.
  - "Focus on the methodology section"
  - "Explain this like I'm new to the field"
  - Appended to the system prompt as user guidance.

### Script Generation Prompt Structure

```text
System: You are writing a podcast conversation between two hosts
discussing the following document.

Host A ({characterA.name}): {characterA.systemPrompt excerpt}
Host B ({characterB.name}): {characterB.systemPrompt excerpt}

Write a natural, engaging dialogue. Include:
- Brief introductions
- Key insights from the document
- One host asking clarifying questions
- A summary at the end

Output as JSON array: [{"speaker": "A", "text": "..."}, ...]
Write in {language}. Target {min_words}–{max_words} words total.

User: [document content]
Optional focus: [user's focus prompt]
```

### Affected Areas

- `OakReader/Services/AudioSummaryService.swift` (conversation mode)
- `OakReader/Views/Viewer/AudioPlayerView.swift` (dual-speaker UI)
- `Packages/OakVoiceAI/` (multi-voice synthesis, crossfade)

---

## Phase 3 — Podcast Feed & External Listening

Expose audio summaries as a Podcast RSS feed so users can listen in Apple Podcasts, Overcast, or any podcast app.

### Requirements

- [ ] Local HTTP server serving Podcast RSS XML.
  - Embed a lightweight HTTP server (e.g., Swifter or NIO).
  - Serve `GET /feed/podcast.xml` — RSS 2.0 with `<itunes:*>` tags.
  - Serve `GET /audio/{attachmentStorageKey}.mp3` — audio files.
  - Server starts on demand, stops when app quits.
- [ ] RSS feed structure.
  - Channel title: "OakReader — {username}'s Library"
  - Channel artwork: OakReader icon or user avatar.
  - Each audio summary = one `<item>` with `<enclosure>`.
  - Episode title: "{item title} — {style}" (e.g., "Attention Is All You Need — Deep Dive").
  - Episode description: first 500 chars of the script.
  - `<pubDate>` from generation timestamp.
- [ ] "Listen in Podcasts" button in the app.
  - Copies `podcast://localhost:{port}/feed/podcast.xml` to clipboard.
  - Or opens the URL directly via `NSWorkspace.shared.open()`.
- [ ] Cloud feed via sharing infrastructure (depends on `sharing-short-links.md`).
  - Upload audio to R2/S3 via the existing share service.
  - Generate cloud RSS feed at `oakreader.site/p/{userId}.xml`.
  - Supports listening away from the Mac (iPhone, car, etc.).
  - Auth via per-user token in feed URL.

### RSS Feed Template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>OakReader Library</title>
    <link>https://oakreader.com</link>
    <language>en</language>
    <itunes:author>{username}</itunes:author>
    <itunes:image href="{coverURL}"/>
    <itunes:category text="Education"/>

    <item>
      <title>{itemTitle} — {style}</title>
      <description>{scriptExcerpt}</description>
      <enclosure url="{audioURL}" length="{fileSize}" type="audio/mpeg"/>
      <pubDate>{rfc2822Date}</pubDate>
      <itunes:duration>{duration}</itunes:duration>
      <itunes:episode>{episodeNumber}</itunes:episode>
    </item>
  </channel>
</rss>
```

### Affected Areas

- New: `OakReader/Services/PodcastFeedService.swift`
- New: `OakReader/Services/LocalHTTPServer.swift`
- `OakReader/Views/RightPanel/AudioSummaryListView.swift` (feed button)
- `OakReader/Services/ShareService.swift` (cloud feed upload, if sharing exists)

---

## Phase 4 — Batch & Queue

Generate summaries for multiple items without babysitting.

### Requirements

- [ ] Batch generation from collection.
  - Right-click collection → "Generate Audio for All Items".
  - Queued background processing with progress indicator.
- [ ] Auto-generate on import (opt-in preference).
  - When a new item is added to a designated collection, auto-queue audio generation.
  - Configurable default style and character.
- [ ] Generation queue management.
  - Show queue in a status popover (like the GitHub Stars sync progress).
  - Cancel, pause, reorder queued items.
  - Retry failed generations.
- [ ] Cost estimation before batch generation.
  - Estimate token count for script generation.
  - Estimate character count for TTS.
  - Show approximate cost for cloud providers.

### Affected Areas

- New: `OakReader/Services/AudioSummaryQueueService.swift`
- `OakReader/Views/StatusBar/` (queue progress indicator)
- `OakReader/Utilities/Preferences.swift` (auto-generate settings)
- `OakReader/Views/Settings/` (audio summary preferences pane)

---

## Technical Notes

### Audio Format

- Output format: MP3 (widest compatibility with podcast apps).
- Bitrate: 128 kbps mono (voice-optimized, ~1 MB/min).
- Sample rate: 44.1 kHz.
- ID3 tags: title, artist ("OakReader"), album (collection name), cover art (item thumbnail).

### Document Length Handling

| Document Size | Strategy |
|---------------|----------|
| < 4K tokens | Send full text to LLM |
| 4K–32K tokens | Send full text with larger context window |
| 32K–128K tokens | Use chapter summaries + key sections |
| > 128K tokens | Hierarchical: summarize chapters first, then synthesize |

### Script Storage Format

```json
{
  "version": 1,
  "style": "deep-dive",
  "language": "en",
  "characters": [
    {"id": "narrator-default", "role": "narrator"}
  ],
  "focusPrompt": null,
  "sourceItemId": "uuid-of-source-item",
  "generatedAt": "2026-05-15T10:00:00Z",
  "modelId": "claude-sonnet-4-5-20250514",
  "segments": [
    {
      "speaker": "narrator",
      "text": "Today we're diving into...",
      "startTime": 0.0,
      "endTime": 12.5
    }
  ],
  "totalDuration": 180.0,
  "wordCount": 1200
}
```

### Error Handling

- TTS provider failure → retry with exponential backoff, fall back to alternate provider.
- Script too long for TTS limits → chunk at paragraph boundaries.
- Document has no extractable text → show error with suggestion to run OCR first.
- Network offline + ElevenLabs selected → prompt to switch to MLX on-device.

---

## Non-Goals for Now

- Real-time streaming playback during generation (generate fully, then play).
- Background music or sound effects.
- Video overviews (NotebookLM's newer feature — may revisit later).
- Public podcast directory submission (Apple Podcasts Connect review process).
- Multi-language voice mixing within a single summary.
- Live audience interaction or Q&A mode.

## Open Questions

- Should generated audio count against a usage quota for free users?
- What is the maximum document length we support for audio generation?
- Should we cache scripts separately from audio to allow re-synthesis with a different voice without re-running the LLM?
- Should the podcast feed include items from all collections or only a user-designated "podcast" collection?
- Do we want chapter markers in the audio file (MP3 chapters / enhanced podcasts)?
