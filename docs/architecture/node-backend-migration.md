# Node Backend Migration

Status: **Phases 0–3 done** (this branch; build-green, protocol-tested).
`Packages/OakAI` is deleted; the Node sidecar (protocol v2) owns providers,
credentials, OAuth, endpoint overrides, and the agentic chat loop. Swift owns
UI, sessions (JSONL via OakAgent's `SessionStore`), and tool execution
(`tool_exec` → `tool_result` round-trips). Phase 4 (Windows / shared React
surfaces) remains.

What moved where:
- `web/backend` (pi-ai): provider catalog (pi's builtin providers, OakReader ids
  preserved — `kimi`↔`moonshotai` mapped), credentials in a 0600 `auth.json`
  (`<dataDir>/backend/`), OAuth login flows (incl. NEW Anthropic-subscription
  sign-in), base-URL overrides + Ollama/LM Studio in `config.json`, the
  chat loop (`streamSimple` + client-tool round-trips), stateless `complete`.
- Swift `BackendChatEngine` replaces OakAgent's `AgentSession` 1:1 (same
  `send(...)` surface + `SessionEvent` semantics) so `ChatViewModel`'s event
  loop is unchanged; `AIProviderCatalog` replaces `ProviderRegistry` +
  `ConfiguredProviderStore` + `LocalProviderStore` + `ProviderEndpointStore`.
- `Packages/OakAgent` is now LLM-free: tools/skills/sessions/Turn types plus the
  tool-call types and `KeychainService` (still used for skill env secrets and
  web-search keys) moved in from OakAI.
- One-time `BackendCredentialMigrator`: Keychain API keys + UserDefaults
  endpoint/local-provider config → backend. OAuth sign-ins are NOT migrated
  (users re-connect once); thinking *budget* is retired (pi thinking levels).

Verification level: `web/backend/test/protocol.test.mjs` covers ping, the 0600
credential store, catalog serving, id mapping, `get_api_key`, local-provider
discovery, the full chat loop with a tool_exec/tool_result round-trip against a
mock OpenAI-compatible SSE server, and override persistence. The embedded
bundle answers protocol-2 ping + list_providers when spawned exactly as the app
spawns it. **Not yet live-verified:** in-app runtime against real providers
(chat, translation, OAuth UI, voice key sharing).

**Node.js ≥ 22 is now required** for all AI features (no in-process fallback
remains). Bundling a Node runtime into the app is the next follow-up.

## Goal

Replace the in-process Swift AI stack (`Packages/OakAI` + `Packages/OakAgent`) with a
long-lived **Node.js sidecar** built on [pi.dev](https://pi.dev)
(`@earendil-works/pi-ai` for provider transport, `@earendil-works/pi-agent-core` for the
agent loop), following the Raycast v2 architecture: thin native shells per platform, one
shared Node backend, so a future Windows client reuses all AI/business logic.

```
┌────────────────────────────┐  ┌──────────────────────────┐
│ macOS shell (SwiftUI)      │  │ Windows shell (later)    │
│ PDFKit viewer, tabs,       │  │                          │
│ Keychain, WebViews         │  │                          │
└─────────┬──────────────────┘  └───────────┬──────────────┘
          │  JSONL over stdio (typed protocol, defined in web/backend/src/protocol.ts)
┌─────────┴──────────────────────────────────┴─────────────┐
│ oak-backend — bundled Node process (pnpm: web/backend)   │
│ pi-ai (providers/streaming)  ·  pi-agent-core (loop)     │
└──────────────────────────────────────────────────────────┘
```

### Locked-in decisions

- **Transport: JSONL over stdio** (LF-delimited, one JSON object per line — same framing
  as pi's own RPC mode). No localhost port: no conflicts, no firewall prompts, identical
  on Windows. The shell spawns and supervises the process.
- **Bidirectional protocol.** 8 of 11 chat tools execute against local app state
  (GRDB/FTS, live WebView DOM, open PDF, filesystem). The agent loop (Phase 2) calls
  *back* into the shell ("client tools"), incl. the tool-confirmation round-trip.
- **Credentials leave the Keychain eventually** (Phase 3): pi-ai's `CredentialStore`
  interface backed by a `0600` JSON file (pi `auth.json` format). Kills the
  `keychain-access-groups` entitlement / provisioning-profile / dev-entitlements saga.
  Until Phase 3, Swift resolves credentials (Keychain → env → OAuth) and passes them
  per-request to the sidecar.
- **Fallback:** while both stacks coexist, completion traffic prefers the sidecar and
  falls back to in-process OakAI if the sidecar is unavailable (no Node, spawn failure).

## Phases

### Phase 0 — Swift-side prep (no Node) ✅ this branch

1. Delete `@_exported import OakAI` from `OakAgent/Exports.swift`; every app file that
   uses OakAI symbols imports it explicitly. (Before: 44 files silently depended on the
   transport layer through `import OakAgent`.)
2. Remove dead `import OakAgent` from `ImportService+PDF.swift` / `+URL.swift`.
3. New **`CompletionClient` facade** (`OakReader/Services/Backend/`): the single
   completion contract for *stateless* AI calls — translation, word define, chat titles,
   Settings "Test Connection". Two implementations:
   - `LocalCompletionClient` — wraps `ProviderRouter`/`StreamChunk` (existing path).
   - `NodeCompletionClient` — Phase 1, speaks the sidecar protocol.
4. `TranslationViewModel`, `ChatTitleService` (drops its throwaway temp-dir
   `AgentSession`), and Test Connection all consume the facade. After this, **raw
   `StreamChunk` no longer leaks into app code** — only `ChatViewModel`'s
   `SessionEvent` contract remains (Phase 2).

### Phase 1 — Node sidecar, completion path ✅ this branch

- `web/backend/` (pnpm workspace member): TypeScript, dep `@earendil-works/pi-ai`.
  - `src/protocol.ts` — the typed protocol (zod schemas). Swift mirrors these in
    `OakReader/Services/Backend/BackendProtocol.swift`. **Keep the two in sync.**
  - `src/main.ts` — JSONL loop: `ping` / `complete` / `abort` commands →
    `delta` / `done` / `error` events, keyed by request id.
  - Uses pi-ai **direct API implementations** (`@earendil-works/pi-ai/api/<api-id>`),
    constructing an ephemeral `Model` from the request (`api`, `baseUrl`, `modelId`,
    `headers`) with an explicit `apiKey` — no provider catalog / credential store in the
    sidecar yet (that's Phase 3).
  - `pnpm build` bundles to `dist/main.cjs` (esbuild, single file, committed — same
    convention as the Preview.bundle cite-anchor artifact) which project.yml embeds as an
    app resource.
- API-format mapping (Swift `APIFormat` → pi-ai api id):
  `anthropicMessages → anthropic-messages`, `openaiCompletions → openai-completions`,
  `openaiResponses → openai-responses`, `googleGenerativeAI → google-generative-ai`.
  OakAI's `ProviderInfo.baseURL` stores the *full endpoint* URL; the protocol carries the
  *API base* (endpoint minus the format suffix) because pi-ai appends paths itself.
- Swift side (`OakReader/Services/Backend/`):
  - `NodeBackendProcess` — locate node (bundled later; system node for now), spawn
    `main.cjs`, supervise, restart on crash, kill on quit.
  - `NodeBackendClient` — actor: JSONL framing (split on `\n` only), id correlation,
    per-request `AsyncThrowingStream`.
  - `NodeCompletionClient` — facade impl; resolves credential + API base in Swift.
  - `AIBackend` — picks Node when the handshake succeeds, else local. Kill switch:
    `Preferences.nodeBackendEnabled`.

### Phase 1.5 — bundle Node (follow-up)

Ship a Node runtime inside the app (Raycast bundles it too) instead of requiring system
node. Adds ~50 MB; do it once Phase 1 proves out.

### Phase 2 — agent loop moves to Node (pi-agent-core)

- Protocol v2: `session/*` commands, `SessionEvent`-shaped event stream (delta /
  thinkingDelta / toolUseStarted / Pending / Completed / finished(Turn) / error) so
  `ChatViewModel`'s coalescing, lazy-turn creation, and session-switch guard survive
  unchanged.
- **Client-tool RPC**: backend → shell `tool_call` request, shell replies with result;
  same for the confirmation round-trip (`ToolCategory`-gated `async -> Bool`).
  Local-state tools stay in Swift: `read_document`, `search_document`,
  `read_current_page`, `search_content`, `research`(† child-agent moves server-side,
  its `search` tool becomes a client tool), `oak`, `manage_memory`, read/write/bash.
- Server-side tools move into Node: `search_web`, `fetch_web`, `search_academic`.
- Content-addressed image upload (`attachment/put` once, reference by hash) — replaces
  re-base64ing every screenshot into every history turn.
- Chat history: sessions owned by pi-agent-core session persistence; one-time JSONL
  import of `SessionStore` data.

### Phase 3 — ownership moves, packages deleted

- Provider catalog + model registry served by the backend (`ProviderEndpointStore`
  base-URL overrides become backend config, still keyed by providerId).
- Credentials: file-backed pi `CredentialStore`; one-time Swift-side Keychain export
  hands existing keys to the backend. OAuth (OpenAI PKCE, Copilot device-code) runs in
  Node (pi-ai provider-owned login flows); shell just opens the browser.
- Delete `Packages/OakAI` + `Packages/OakAgent`. `oak` CLI becomes a client of the same
  sidecar. `OakVoice` gets keys via the backend instead of importing OakAI.

### Phase 4 — Windows + shared React surfaces

Thin Windows shell speaking the same protocol. Chat/notes/settings panels become shared
React-in-system-WebView surfaces (extension of the existing `web/webviews` →
Preview.bundle pattern). React extensions ride the same Node runtime.

**Consciously out of scope:** the GRDB catalog / FTS / importers stay Swift for now.
A Windows build ultimately needs the library in Node too (schema is plain SQLite, so
portable) — that is a second project of comparable size; decide after Phase 3.

## Protocol v1 reference

Client → server (stdin), one JSON per line:

```jsonc
{"id":"1","type":"ping"}
{"id":"2","type":"complete",
 "model":{"api":"openai-completions","baseUrl":"https://api.deepseek.com/v1",
           "id":"deepseek-chat","headers":{}},
 "auth":{"apiKey":"sk-…"},
 "system":"…","messages":[{"role":"user","content":"…"}],
 "maxTokens":4096}
{"type":"abort","id":"2"}
```

Server → client (stdout):

```jsonc
{"id":"1","type":"response","command":"ping","success":true,"protocol":1,"backend":"oak-backend x.y.z"}
{"id":"2","type":"delta","text":"…"}
{"id":"2","type":"done","stopReason":"stop"}
{"id":"2","type":"error","message":"…"}
```

Rules: LF framing only (never split on U+2028/9); every event carries the originating
request `id`; `done`/`error` are terminal per id; unknown ids in `abort` are a no-op;
stderr is free-form logging, never protocol.
