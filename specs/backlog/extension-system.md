# Extension System Design

**Status:** Backlog
**Created:** 2026-04-26

## Goal

Enable users and third-party developers to extend OakReader's functionality — starting with custom AI skills and potentially growing to full plugin support.

## Research

Studied three reference architectures:

| Project | Approach | Runtime | Sandboxing | Maturity |
|---------|----------|---------|------------|----------|
| **Raycast** | React/TS → native AppKit | V8 isolates in Node.js | None (open-source review) | Production |
| **CodeEditApp** | Apple ExtensionKit | Sandboxed .appex processes | OS-level (XPC) | Beta/WIP |
| **Chime** | ExtensionKit via ChimeKit | Sandboxed .appex processes | OS-level (XPC) | Production |

### Key Takeaways

- ExtensionKit ecosystem is immature — only Chime ships a production implementation
- Raycast's model (JS runtime + native rendering) offers best DX but high engineering cost
- JSON-based config extensions are the lowest-cost, highest-value starting point
- JavaScriptCore (built into macOS) is a viable middle ground before ExtensionKit

## Phased Implementation Plan

### Phase 1: User-Defined AI Skills (Recommended Start)

**Effort:** Days
**Value:** High — custom AI prompts/workflows without code changes

Users drop JSON files defining custom AI skills:

```
~/.oakreader/skills/
├── legal-reviewer.json
├── citation-extractor.json
└── my-custom-skill.json
```

**Skill JSON schema:**

```json
{
  "id": "legal-reviewer",
  "name": "Legal Review",
  "description": "Review document for legal issues and flag concerns",
  "icon": "scale.3d",
  "systemPrompt": "You are a legal document reviewer. Analyze the provided PDF content and...",
  "contextMode": "fullDocument"
}
```

**contextMode options:** `fullDocument`, `currentPage`, `selectedText`, `none`

**Implementation:**
1. Add directory scanning to `SkillManager` (watch `~/.oakreader/skills/`)
2. Parse and validate JSON skill files on launch + file system events
3. Merge user skills with built-in 8 skills
4. Show user skills in skill picker UI (with a "User" badge)
5. Add "Open Skills Folder" and "Create Skill" helpers in Settings

**Existing extension points:**
- `SkillManager.builtInSkills` — already returns `[Skill]` array
- `Skill` struct — already has id, name, description, systemPrompt, icon, contextMode
- `ChatViewModel.selectedSkill` — already wired to UI

### Phase 2: JavaScriptCore Plugin Runtime

**Effort:** Weeks to months
**Value:** Programmable extensions — automation, custom processing, integrations

- Embed JavaScriptCore (built into macOS, no dependency) as plugin runtime
- Define `oakreader` JS API:
  - `oakreader.document` — page count, metadata, text extraction
  - `oakreader.annotations` — read/create/modify annotations
  - `oakreader.selection` — current selection text and page
  - `oakreader.ui` — show toasts, open panels, add sidebar items
  - `oakreader.clipboard` — read/write clipboard
  - `oakreader.storage` — per-plugin persistent key-value store
- Plugin manifest: `manifest.json` with name, version, permissions, entry point
- Sandboxing: JSC runs in-process but has no file/network access unless explicitly bridged
- Hot reload in dev mode

**Plugin structure:**

```
~/.oakreader/plugins/
└── my-plugin/
    ├── manifest.json
    ├── index.js
    └── icon.png
```

### Phase 3: ExtensionKit (Full Native)

**Effort:** Months
**Value:** Full UI extensions, deep integration, process isolation

Only pursue if building a platform with third-party developer ecosystem.

- Apple ExtensionKit framework (macOS 13+)
- `.appex` bundles with XPC communication
- Shared `OakReaderKit` dynamic framework (like Chime's ChimeKit)
- Extension types: sidebar panels, toolbar items, document processors, themes
- Distribution: in-app extension browser

**Reference implementations:**
- [ChimeKit](https://github.com/ChimeHQ/ChimeKit) — best production example
- [Extendable](https://github.com/ChimeHQ/Extendable) — SwiftUI utilities for ExtensionKit
- [TextTransformer](https://github.com/insidegui/TextTransformer) — sample app by Guilherme Rambo

## Current Extension Points in Codebase

| Component | File | Extensibility |
|-----------|------|---------------|
| AI Skills | `SkillManager.swift` | `Skill` struct, `builtInSkills` array — ready for Phase 1 |
| LLM Providers | `LLMProviderService.swift` | Protocol + `ProviderRouter` — add new providers |
| Services | `Services/` (24 files) | Stateless, could abstract to protocols |
| PDF Processing | Various services | Pre/post hooks for custom processing |

## Decision

Start with **Phase 1** when user demand exists. The AI skill system is already structured for this — it's primarily a file-loading and UI task.
