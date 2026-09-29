---
name: gatheros-source-analysis
description: "Analyze / reverse-engineer the locally installed GatherOS mac app (gatheros.co; internal name 'moodmark'; bundle id com.gatheros.app; author 'BrettfromDJ'). A local-first visual-inspiration / moodboard app (save images → masonry grid + freeform boards, palette extraction, X-bookmark + browser-extension capture). Unlike Dia (native Swift) and Fabric (CDN-served Next.js in Electron), GatherOS is a SELF-CONTAINED Electron app whose ENTIRE main process ships UNMINIFIED inside app.asar and whose React/Vite renderer is bundled in dist/ — the most recoverable of the three. Map its SQLite schema, IPC surface, capture pipeline (localhost server + Chrome native-messaging host), AI proxy, and licensing. Invoke when the user wants to study how GatherOS's capture / board canvas / palette / local-first storage works, or compare it against OakReader's clip-capture and library."
---

# Analyze GatherOS (gatheros.co) source

GatherOS (`/Applications/GatherOS.app`, ~269 MB) is a **local-first visual-inspiration
app** — "save, browse, and organize visual inspiration." Think Pinterest/Cosmos as a native
mac app: clip an image (from the web, X bookmarks, drag-drop, or a screenshot hotkey), it's
stored locally, its color **palette** is extracted, and it lands in a **masonry grid** you can
organize into **collections**, **tags**, and freeform **boards** (a moodboard canvas). We use
it as a reference for **clip-capture UX, local-first storage, and a browser-extension capture
pipeline** — all of which OakReader also has (SnapshotServer + extension), so the parallels are
unusually direct.

**The crucial structural fact:** GatherOS is a **self-contained Electron app**, and its
**entire main process ships UNMINIFIED** inside `app.asar` (clear filenames, real comments,
~9 k lines). The React renderer is a bundled **Vite** build in `dist/renderer/` (minified but
readable). Nothing is fetched from a CDN at runtime. This makes it the **most recoverable** of
our three reference apps — recovery is just "extract the asar," no source maps
([[dia-source-analysis]]) and no cache/CDN spelunking ([[fabric-source-analysis]]).

## Golden rules

- **Read-only, on the user's own machine, for research.** Proprietary code shipped to the
  user (a paid app — see Licensing). Use it to *understand and learn*, never to
  copy/redistribute verbatim or ship lifted code. State this caveat when sharing recovered
  source.
- **The main process is the gold mine, and it's already plaintext.** Don't waste effort
  "deobfuscating" — `src/main/*.js` reads like the original repo (comments and all). Read it
  directly.
- **`app.asar` is the whole app.** No network recovery step. The renderer (`dist/renderer/`)
  and main process (`src/`) are both inside it. The only thing NOT in the bundle is the user's
  live data (their saved images + SQLite DB), which lives under Application Support.
- **Verify before trusting old findings.** Facts below are version-stamped. GatherOS
  auto-updates via **electron-updater** from **GitHub releases** (`owner: BrettfromDJ,
  repo: gatheros`). Re-read the version (step 0) first; treat mismatches as "re-derive."

## Established facts (as of GatherOS 0.3.9 — RE-VERIFY)

`CFBundleShortVersionString` 0.3.9, bundle id `com.gatheros.app`, productName **GatherOS**,
internal/package name **`moodmark`** (the original codename — it's everywhere: `moodmark.db`,
the `window.moodmark` bridge, `moodmark-file:` scheme, `moodmark-updater` cache dir). Electron
shell with Squirrel (`Squirrel.framework`) + electron-updater. Native deps: **better-sqlite3**
(local DB), **sharp** (thumbnails), **node-vibrant** (palette), **yauzl** (zip import). Fonts:
Geist / Geist Mono (`@fontsource-variable/geist`).

### Renderer (the UI)
- **React + Vite**, single bundle `dist/renderer/assets/main-<hash>.js` (~388 KB minified)
  + a shared `variables-<hash>.js` vendor chunk. Entry `dist/renderer/index.html` → `#root`.
- Grid is a **masonry** layout (fingerprint `masonry` in the bundle). The board surface is a
  **hand-rolled freeform canvas** — NOT konva / fabric / tldraw / dnd-kit (none present);
  items are absolutely positioned from `board_items` (x/y/width/height/rotation/z_index).
- Talks to the main process ONLY through the preload bridge **`window.moodmark.*`**, namespaces:
  `app, saves, collections, boards, tags, db, capture, image, window, shell, share, library,
  backup, libraries, drag, settings, onboarding, ai, updater, licensing, entitlement`.
- CSP (`index.html`) is `script-src 'self'`, single-origin, custom file scheme `moodmark-file:`
  for serving local images, and `connect-src` allows `http://localhost:5173` (the Vite dev
  server) + `ws:`.

### Data model (better-sqlite3, WAL) — `src/main/db.js`
Core noun is a **`save`** (one saved image). Tables:
- `saves` — `file_path`, `thumb_path`, `title`, `source_url`, `width/height`, `file_size`,
  `palette` (extracted colors, JSON), `created_at`.
- `collections` + `collection_items` (m:n; collections are foldering, support a parent →
  hierarchy via the `collections:set-parent` IPC).
- `tags` + `save_tags` (m:n).
- `boards` + `board_items` — the moodboard canvas. A `board_item` has `type`, `x`, `y`,
  `width`, `height`, `rotation`, `z_index`, and a freeform `data` JSON blob.
- `dismissed_tweets` — tombstones (keyed by tweet id) so the **X-bookmark watcher** doesn't
  silently re-capture a bookmark the user deleted from Gather.
- **Multi-library**: `library-registry.js` keeps `userData/libraries.json` + a folder per
  library `userData/libraries/<id>/` each with its own `moodmark.db` + `images/` + `thumbs/`.
  Legacy single-DB installs are migrated into a default library on first run.

### Capture pipeline (the part most relevant to OakReader)
Four ingest paths, all funneling into `saves` via `capture.js` (palette via node-vibrant,
thumbs via sharp):
1. **Drag-drop / file / zip** — `saves:drop-file`, `saves:drop-zip`, `zipImport.js`.
2. **URL capture** — `saves:capture-url` / `urlCapture.js` (fetch a remote image by URL).
3. **Screenshot hotkey** — `capture.js` registers a global accelerator
   (default `Cmd/Ctrl+Shift+S`) → `desktopCapturer` area/screen grab.
4. **Browser extension** — two pieces:
   - `extension-server.js`: a **localhost HTTP server on `127.0.0.1:53247`**, one endpoint
     `POST /save` (body `{imageUrl?, videoUrl?, posterUrl?, pageUrl?, pageTitle?, notes?,
     tweetMeta?, tags?}`) gated on header `X-GatherOS-Token` (a 32-byte token the user copies
     from Settings → Capture into the extension), plus an unauthenticated `GET /ping` for the
     "Test connection" button. **Directly analogous to OakReader's `SnapshotServer` on :23119.**
   - `native-host.js` + `native-host-installer.js`: a **Chrome native-messaging host** (length-
     prefixed JSON over stdin/stdout) installed into `~/Library/Application Support/GatherOS/
     native-host`. It relays extension messages to the localhost server, launching the app first
     if it isn't running. Deliberately does **not** `require('electron')` (so Chrome spawning it
     doesn't flash a Dock icon). `tweetCardCapture.js` renders X/tweet cards.

### AI (`src/main/openai.js`) — proxied, license-gated
GatherOS does **not** ship an OpenAI key. `openai.js` is a thin client to the **GatherOS AI
proxy Worker** at `https://api.gatheros.co` (`API_BASE_URL`, overridable via
`GATHEROS_API_BASE_URL`). The Worker holds the master key and gates every call on a valid
**licensed session token** (read on demand from `licensing.js`, sent as `Bearer`). Features
exposed via `window.moodmark.ai.*`:
- `autoTag` — `gpt-4o-mini` vision → suggested tags for a save.
- `similarSaves` / `reindexLibrary` / `unindexedCount` — **embedding-based** visual similarity
  search (embeddings stored locally, computed via the proxy).
- `generatePrompt` — turn a save into a text prompt.
- `generateVariant` — `gpt-image-1` image variant (size validated against the supported set).
- `usage` / `hasSession` — quota + auth state.

### Licensing / entitlement
`licensing.js` (346 ln) + `entitlement.js` — a **paid app**. Email magic-link auth
(`gatheros://auth/verify?token=…` custom URL scheme), session token, 7-day offline grace
(`OFFLINE_GRACE_MS`), re-verify every 6 h. Free tier is capped (`canCreateSave()` guards both
saves and the screenshot hotkey, failing **open** on error); blocked actions call
`notifyNeedsUpgrade`. AI is entirely behind a valid session.

## Bundle / on-disk map

| Path | What |
|---|---|
| `/Applications/GatherOS.app/Contents/Resources/app.asar` (7.7 MB) | **the whole app** — `src/main/*` (unminified Node) + `src/shared/*` + `dist/renderer/*` (Vite/React build) + `package.json` |
| `…/app.asar.unpacked/node_modules/{better-sqlite3,sharp,@img}` | native modules unpacked from the asar (can't run inside it) |
| `…/Resources/app-update.yml` | electron-updater feed → GitHub `BrettfromDJ/gatheros` |
| `Contents/Frameworks/` | Electron Framework + Squirrel (updater) + 4 Helper apps + Mantle/ReactiveObjC |
| `Contents/MacOS/GatherOS` (52 KB) | tiny Electron launcher stub (no product logic) |
| `~/Library/Application Support/GatherOS/libraries/<id>/moodmark.db` | **live SQLite DB** (saves/collections/boards/tags) — outside the bundle |
| `~/Library/Application Support/GatherOS/libraries/<id>/{images,thumbs}/` | the user's saved images + generated thumbnails |
| `~/Library/Application Support/GatherOS/native-host/` | installed Chrome native-messaging launcher + manifest |

## Procedure

### 0. Identify version (always first)
```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/GatherOS.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier"        /Applications/GatherOS.app/Contents/Info.plist
cat /Applications/GatherOS.app/Contents/Resources/app-update.yml
```

### 1. Recover the source (the big win — one step)
Extract the asar and print a fingerprint (version, main-process modules, IPC bridge, schema):
```bash
agent/skills/gatheros-source-analysis/scripts/extract-asar.sh /tmp/gatheros-src
```
Then **read the main process directly** — it's plaintext with comments. Highest-value files:
`db.js` (schema + migrations), `ipc.js` (the full IPC surface), `index.js` (app wiring),
`capture.js` + `urlCapture.js` + `tweetCardCapture.js` (ingest), `extension-server.js` +
`native-host.js` (browser capture), `openai.js` (AI), `licensing.js` + `entitlement.js`
(paid gating), `library-registry.js` + `storage.js` + `backup.js` (local-first storage),
`preload.js` (the `window.moodmark` API surface).

### 2. Map the IPC surface (what the renderer can do)
```bash
S=/tmp/gatheros-src/src/main
grep -oE "ipcMain\.(handle|on)\('[a-zA-Z0-9:._-]+'" "$S/ipc.js" | sed -E "s/.*'(.*)'/\1/" | sort
# and the bridge the renderer actually calls:
grep -oE "moodmark\.[a-zA-Z]+\.[a-zA-Z]+" /tmp/gatheros-src/dist/renderer/assets/main-*.js | sort -u
```

### 3. Read the DB schema + migrations
```bash
sed -n '/const SCHEMA =/,/`;/p' /tmp/gatheros-src/src/main/db.js
grep -nE "ALTER TABLE|CREATE TABLE|migrate|version" /tmp/gatheros-src/src/main/db.js | head -40
```
To inspect a LIVE library (read-only — copy first so you never touch WAL state):
```bash
LIB=$(ls -t "$HOME/Library/Application Support/GatherOS/libraries"/*/moodmark.db | head -1)
cp "$LIB" /tmp/gatheros-live.db
sqlite3 /tmp/gatheros-live.db '.tables' ; sqlite3 /tmp/gatheros-live.db 'SELECT count(*) FROM saves;'
```

### 4. Renderer (React/Vite) — fingerprint only
The renderer is minified; read it for *what libraries/patterns* it uses, not line-by-line.
```bash
cd /tmp/gatheros-src/dist/renderer/assets
for kw in React useState useEffect masonry konva fabric tldraw dnd-kit framer-motion; do
  echo "$kw : $(grep -lE "$kw" main-*.js 2>/dev/null | wc -l)"; done
grep -oE "moodmark\.[a-zA-Z.]+" main-*.js | sort -u    # every bridge call = a renderer capability
```

### 5. Capture / extension pipeline
```bash
sed -n '1,60p'  /tmp/gatheros-src/src/main/extension-server.js   # localhost :53247 /save contract
sed -n '1,40p'  /tmp/gatheros-src/src/main/native-host.js        # Chrome native-messaging relay
grep -nE "globalShortcut|desktopCapturer|accelerator" /tmp/gatheros-src/src/main/capture.js
```

## Relevance to OakReader

GatherOS is the closest structural cousin of the three reference apps to OakReader's
**clip-capture + local library** side (OakReader: `SnapshotServer` on `localhost:23119` ←
browser extension → `ImportService` → GRDB catalog). What's worth studying vs. not:

- **Borrow / validate (direct parallels):**
  - The **localhost-server + Chrome native-messaging-host** capture pattern. GatherOS's
    `native-host.js` solves a problem OakReader's extension also faces — *launch the app if it
    isn't running, then deliver the clip* — and does it without flashing a Dock icon. The
    token-in-header auth (`X-GatherOS-Token`, copied from Settings) is a cleaner pairing UX than
    an always-open unauthenticated port.
  - **Palette extraction** (node-vibrant) + **sharp thumbnails** on ingest — OakReader could
    surface dominant colors for image clips the same way.
  - **Multi-library** as folder-per-library each with its own SQLite + assets
    (`library-registry.js`) — a clean model if OakReader ever wants separate vaults.
  - The **AI-proxy-Worker** pattern (`openai.js` → `api.gatheros.co`, license-gated, master key
    server-side). This is the *opposite* of OakReader's "user brings their own provider key"
    model — relevant only if OakReader ever offers a hosted/managed AI tier; for a BYO-key local
    tool, OakReader's direct-provider approach is the right tradeoff.
- **Reference, probably don't copy:**
  - The **freeform board canvas** (`board_items` absolute x/y/rotation/z) is a whole second
    spatial surface — only relevant if OakReader wants a moodboard mode.
  - **Paid licensing / entitlement gating** — OakReader is open-source self-use
    ([[oakreader-portfolio-vs-business]]); the whole `licensing.js`/`entitlement.js` layer is
    counter to that direction. Study it as "how a solo dev gates a paid Electron app," not as
    something to adopt.
- **Architectural contrast worth internalizing:** GatherOS ships its renderer **bundled
  locally** (Vite build in the asar) — same offline-first bet as OakReader's bundled-WKWebView
  editor, and the opposite of Fabric's CDN-served renderer ([[fabric-source-analysis]]). All
  three apps (Dia native, Fabric CDN-Electron, GatherOS bundled-Electron) are a useful spectrum
  of "where does the UI come from" tradeoffs.
