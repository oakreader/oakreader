# Plugin & Skill UX Redesign

## Problem

OakReader has two disconnected skill surfaces and a plugin system with no visual identity. Comparing with Codex's architecture reveals specific gaps.

### Current state

**Two separate skill systems that don't talk to each other:**

1. **Built-in skills** (SkillManager) — 8 hardcoded document-analysis skills (Summarize, Explain, Translate, etc.) with icons, system prompts, context modes. Surfaced in `SkillPickerBar` as chips.

2. **File-based Agent Skills** (SkillLoader) — `SKILL.md` files loaded from `~/.oakreader/skills/` and plugin skill directories. Injected into the system prompt as XML. **Not visible in any UI** — users can't see, select, or manage them.

**Plugins have no visual identity:**

OakReader's `PluginManifest` has: `name`, `version`, `description`, `tools`, `skills`, `credentials`, `commands`. No icon, no category, no brand color, no screenshots, no capabilities declaration.

**Plugin skill directories are declared but empty:**

All 4 non-AI bundled plugins declare `skills: ["./skills/"]` but these directories don't exist in the bundle — no actual SKILL.md files ship with the plugins.

### What Codex does differently

Codex's `plugin.json` has a rich `interface` block:

```json
{
  "interface": {
    "displayName": "LaTeX (Tectonic)",
    "shortDescription": "Compile LaTeX documents",
    "longDescription": "...",
    "category": "Research",
    "capabilities": ["Read", "Write"],
    "brandColor": "#3B82F6",
    "composerIcon": "./assets/icon.png",
    "logo": "./assets/logo.png",
    "screenshots": [],
    "defaultPrompt": ["Compile my paper.tex to PDF"]
  }
}
```

Each skill has `agents/openai.yaml` for UI metadata (display name, icon, brand color, tool dependencies), separate from the SKILL.md content.

Codex's skill system is **progressively disclosed**: frontmatter metadata is always loaded into the system prompt (~100 words), the full SKILL.md body is loaded only when the LLM decides to use `read` to fetch it, and scripts/references load on demand. OakReader's SkillLoader already does this — but then doesn't surface the skills in the UI.

## Design

### Principle: One unified skill surface

Merge built-in skills and file-based skills into a single list. A "skill" is a skill, regardless of whether it came from SkillManager or a SKILL.md file.

```
┌─────────────────────────────────────────────────────┐
│  SkillPickerBar (unified)                           │
│                                                     │
│  [📄 Summarize] [🔍 Explain] [🌐 Translate] ...    │  ← built-in (SkillManager)
│  [🌿 LaTeX] [🔬 Academic Search] [📊 Data Extract] │  ← from plugins/SKILL.md
│  [📋 Linear] [🎨 Custom Skill]                     │  ← from ~/.oakreader/skills/
│                                                     │
└─────────────────────────────────────────────────────┘
```

All skills appear as chips with icon + name. Selecting one sets the context for the next message. The distinction between built-in and file-based is an implementation detail, not a UX concept.

### Unified skill protocol

```swift
/// Single protocol that both SkillManager skills and AgentSkills conform to.
protocol SkillPresentable: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var icon: String { get }           // SF Symbol name or custom icon path
    var brandColor: String? { get }    // Hex color for chip tinting
    var source: SkillSource { get }    // .builtin, .plugin("name"), .user
}

enum SkillSource {
    case builtin
    case plugin(String)  // plugin name
    case user            // ~/.oakreader/skills/
}
```

Built-in skills already have `icon` and `systemPrompt`. File-based skills need a small frontmatter extension:

```yaml
---
name: latex-compile
description: "Compile LaTeX documents to PDF using tectonic"
icon: function             # SF Symbol name
brand-color: "#3B82F6"     # optional, for chip tinting
---
```

### Plugin manifest `interface` block

Add visual identity to `PluginManifest`:

```swift
struct PluginManifest: Codable {
    // existing fields...
    let interface: PluginInterface?

    struct PluginInterface: Codable {
        let displayName: String?
        let shortDescription: String?
        let category: String?           // "Research", "Productivity", "Engineering"
        let brandColor: String?         // hex
        let icon: String?               // SF Symbol or bundled asset path
        let capabilities: [String]?     // ["documentImport", "documentExport", "agentSkill"]
        let defaultPrompts: [String]?   // suggested starter prompts
    }
}
```

This enables a future Plugin Manager view that shows plugins as cards with identity, rather than a flat enable/disable toggle list.

### Plugin Manager view

```
┌──────────────────────────────────────────────────────────────┐
│  Plugins                                                      │
│                                                                │
│  ┌────────────────────────┐  ┌────────────────────────┐       │
│  │ 🌐 Web Import    [ON] │  │ 📺 YouTube       [ON] │       │
│  │ Import web pages as    │  │ Download and manage    │       │
│  │ offline snapshots      │  │ YouTube videos        │       │
│  │                        │  │                        │       │
│  │ Tools:                 │  │ Tools:                 │       │
│  │ ✅ monolith 0.4.1     │  │ ✅ yt-dlp 2024.12    │       │
│  │ ✅ pandoc 3.6         │  │                        │       │
│  │                        │  │ ⚠️ Install yt-dlp     │       │
│  └────────────────────────┘  └────────────────────────┘       │
│                                                                │
│  ┌────────────────────────┐  ┌────────────────────────┐       │
│  │ 🎙 Transcription [ON] │  │ 📐 Typesetting   [ON] │       │
│  │ Transcribe audio and   │  │ Professional document  │       │
│  │ video files            │  │ export via Typst       │       │
│  │                        │  │                        │       │
│  │ Tools:                 │  │ Tools:                 │       │
│  │ ✅ whisper-cpp 1.7    │  │ ✅ typst 0.13        │       │
│  └────────────────────────┘  └────────────────────────┘       │
│                                                                │
│  ┌────────────────────────┐  ┌────────────────────────┐       │
│  │ 📄 LaTeX         [ON] │  │ 🤖 AI             [ON] │       │
│  │ Import and compile     │  │ AI chat and document   │       │
│  │ LaTeX documents        │  │ analysis               │       │
│  │                        │  │                        │       │
│  │ Tools:                 │  │ Credentials:           │       │
│  │ ✅ tectonic 0.15      │  │ ✅ Anthropic           │       │
│  │                        │  │ ✅ OpenAI              │       │
│  │ Skills:                │  │ ⚠️ Google (not set)   │       │
│  │ • latex-compile        │  │                        │       │
│  └────────────────────────┘  └────────────────────────┘       │
│                                                                │
│  ── User Plugins (~/.oak/plugins/) ──                         │
│  (none installed)                                              │
│                                                                │
│  [Open Plugins Directory]                                      │
└──────────────────────────────────────────────────────────────┘
```

### MCP server support in plugins

Following Codex's `.mcp.json` pattern, allow plugins to declare MCP servers:

```swift
struct PluginManifest: Codable {
    // existing fields...
    let mcpServers: [String: MCPServerConfig]?

    struct MCPServerConfig: Codable {
        let command: String           // binary path (resolved like tools)
        let args: [String]?
        let transport: MCPTransport   // .stdio, .sse, .streamableHTTP
        let env: [String: String]?
    }

    enum MCPTransport: String, Codable {
        case stdio
        case sse
        case streamableHTTP = "streamable_http"
    }
}
```

When a plugin with MCP servers is enabled, the app starts the MCP server process and registers its tools with the agent. This turns plugins from passive tool-binary registries into active tool providers.

### Skill authoring from the app

Codex has a `skill-creator` meta-skill that generates SKILL.md files. OakReader should support creating skills from within the app:

1. User selects text/content in a document or chat
2. "Save as Skill" action
3. Generates a SKILL.md in `~/.oakreader/skills/` with the content as instructions
4. Skill immediately appears in the picker

This is the simplest path to user-created skills — no marketplace, no install flow, just a file.

## Requirements

### Phase 1 — Unified skill surface

- [ ] Extend `AgentSkill` frontmatter to support `icon` and `brand-color` fields
- [ ] Create `SkillPresentable` protocol that both `Skill` (built-in) and `AgentSkill` conform to
- [ ] Merge built-in and file-based skills in `SkillPickerBar` as a single flat list
- [ ] Show file-based skills with their icon/color (fallback: generic SF Symbol)
- [ ] Selecting a file-based skill sets context the same way built-in skills do
- [ ] Write actual SKILL.md files for bundled plugins (web-import, youtube, transcription, typesetting)

### Phase 2 — Plugin visual identity

- [ ] Add `PluginInterface` struct to `PluginManifest`
- [ ] Update bundled plugin definitions with displayName, icon, category
- [ ] Build `PluginManagerView` — card grid showing each plugin with tool status, credentials, skills
- [ ] Replace current flat toggle list in Settings with the new Plugin Manager
- [ ] Add "Open Plugins Directory" button
- [ ] Show plugin-sourced skills with their plugin's brand color in SkillPickerBar

### Phase 3 — MCP server integration

- [ ] Add `MCPServerConfig` to `PluginManifest`
- [ ] Build MCP client in OakAgent (stdio transport first)
- [ ] Lifecycle management: start MCP server when plugin enabled, stop when disabled
- [ ] Register MCP-provided tools alongside built-in AgentTools
- [ ] Surface MCP tool calls in the same ToolCallCardView UI

### Phase 4 — Skill authoring

- [ ] "New Skill" command that scaffolds a SKILL.md in `~/.oakreader/skills/`
- [ ] "Save as Skill" context action from chat/document
- [ ] Skill editor view (markdown editor for SKILL.md with frontmatter template)
- [ ] Hot-reload: `SkillLoader` watches `~/.oakreader/skills/` for changes

## Affected areas

| Area | File | Change |
|------|------|--------|
| Skill model | `Packages/OakAgent/.../AgentSkill.swift` | Add icon, brandColor fields |
| Skill model | `Packages/OakAgent/.../FrontmatterParser.swift` | Parse icon, brand-color |
| Skill model | `Packages/OakAgent/.../Skill.swift` | Conform to SkillPresentable |
| Skill UI | `OakReader/Views/RightPanel/SkillPickerBar.swift` | Unified list, brand colors |
| Skill loader | `Packages/OakAgent/.../SkillLoader.swift` | No change (already works) |
| Plugin model | `OakReader/Models/PluginManifest.swift` | Add interface, mcpServers |
| Plugin service | `OakReader/Services/PluginService.swift` | Update bundled defs, MCP lifecycle |
| Plugin UI | New: `OakReader/Views/Settings/PluginManagerView.swift` | Card grid |
| Plugin skills | New: bundled `skills/` dirs with SKILL.md files | Actual skill content |
| MCP client | New: `Packages/OakAgent/.../MCPClient.swift` | stdio transport |
| Chat VM | `OakReader/ViewModels/ChatViewModel.swift` | Register MCP tools |
| Settings | `OakReader/Views/Settings/AISettingsView.swift` | Link to Plugin Manager |

## Comparison: Codex vs OakReader (current → proposed)

| Aspect | Codex | OakReader (current) | OakReader (proposed) |
|--------|-------|--------------------|--------------------|
| Plugin identity | Rich: icon, color, screenshots, category | Bare: name + description | Rich: interface block |
| Skill UI | Chips in composer with icons | 8 hardcoded chips only | Unified chips for all skills |
| File-based skills in UI | Always visible | Invisible (system prompt only) | Visible in picker |
| MCP integration | `.mcp.json` per plugin | None | MCPServerConfig in manifest |
| Skill authoring | skill-creator meta-skill | None | "New Skill" / "Save as Skill" |
| Plugin management | Marketplace with install policies | Enable/disable toggles | Card grid with tool status |
| Skill metadata | openai.yaml (icon, color, deps) | Frontmatter (name, desc only) | Extended frontmatter |
| Progressive disclosure | 3-level (meta → body → refs) | Already implemented | Same (no change needed) |
