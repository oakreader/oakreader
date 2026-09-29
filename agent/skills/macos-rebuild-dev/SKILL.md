---
name: macos-rebuild-dev
description: "Kill the running OakReader app, rebuild it for local development (signed with the developer's Apple Development identity), and relaunch it. Invoke when user says 'rebuild', 'rebuild app', 'restart app', or 'relaunch'."
---

# Rebuild App (local development)

Kill the running OakReader.app process, rebuild the project with a **stable Apple
Development signing identity**, and relaunch.

## Signing model (and why a stable identity is still preferred)

Debug builds ship `app/OakReader-dev.entitlements`, which is minimal —
`com.apple.security.network.client`, `com.apple.security.network.server`,
`com.apple.security.device.audio-input`, `com.apple.security.print` — and deliberately
**omits `keychain-access-groups`** (that restricted key lives only in the Release
entitlements, `OakReader.entitlements`). Because Debug carries no restricted entitlement,
**ad-hoc signing works and `-allowProvisioningUpdates` is no longer strictly required** —
this is what lets a contributor build with their own Apple team, or with no Apple account
at all. See the `contributor-signing-xcconfig` memory and README "Build".

Without the access group, Debug stores API keys / OAuth tokens in the **file-based login
keychain** (`OakAI/KeychainConfig.swift` → `scoped(_:)` skips the access group under
`#if DEBUG`). Those items' ACLs are bound to the code signature, so they persist across
rebuilds **only while the signing identity stays constant** — which is the reason this
skill still signs the maintainer's dev build with a **stable Apple Development identity**
rather than ad-hoc. Ad-hoc (`-`) produces a different identity every build, which both
re-fires TCC permission dialogs (mic, local network — macOS keys those to the identity)
and invalidates login-keychain reads (the old "my saved API key disappeared" symptom).
Contributors who don't care can build ad-hoc and re-enter keys, or inject them via the
provider env vars (e.g. `OPENAI_API_KEY`, read by `CredentialResolver`).

Signing is configured in the **xcconfig layer**, not `project.yml`:
`xcconfig/OakReader-debug.xcconfig` → `OakReader-common.xcconfig`, which sets the
maintainer default (Apple Development, team `5Y27G7B6D8`, Automatic) and ends with an
optional `#include? "DeveloperSettings.xcconfig"` so a contributor's gitignored override
wins. On the maintainer's machine (no override) the defaults apply, so this skill's
command works unchanged.

This is for **local development only**. Distribution/release uses the separate Developer
ID flow (team `5Y27G7B6D8`, `OakReader.entitlements` with the access group) — see the
`macos-release-setup` skill. Do not use the Developer ID cert here.

## Instructions

When invoked, execute these steps sequentially:

1. **Kill the running app**. The Debug wrapper is `OakReader-Dev.app` and its
   executable is `OakReader-Dev` (`PRODUCT_NAME` is overridden per-config in
   `project.yml` so the Dock labels the dev build correctly), so `-x OakReader`
   no longer matches it. Both names are killed here because a dev build made
   before that rename is still called `OakReader`:
   ```bash
   pkill -x OakReader-Dev || true
   pkill -f 'Build/Products/Debug/OakReader.app/Contents/MacOS/OakReader' || true
   ```

2. **Rebuild** (Debug). Signing comes from the xcconfig layer
   (`xcconfig/OakReader-debug.xcconfig`) scoped to the OakReader target, so do NOT pass
   any signing flags on the command line — global `xcodebuild` signing overrides break the
   SPM package targets and the `oak` tool:
   ```bash
   xcodebuild -scheme OakReader -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -5
   ```
   - `-allowProvisioningUpdates` lets Xcode auto-create/refresh the development
     provisioning profile that Automatic signing uses. It is **harmless to keep but no
     longer required** — Debug carries no restricted entitlement, so the build also
     succeeds ad-hoc or with a contributor's own team. On the maintainer's machine it uses
     the default Apple Development identity (team `5Y27G7B6D8`), which needs that Apple ID
     signed into Xcode → Settings → Accounts. If the build fails with "No Account for Team"
     and there is **no** local `xcconfig/DeveloperSettings.xcconfig`, that login is missing
     — surface it and stop; it is a one-time human step.
   - If the build fails, show the error output and stop. Do NOT relaunch.

3. **Find and launch the built app**. Ask xcodebuild for `FULL_PRODUCT_NAME`
   rather than hardcoding a wrapper name — Debug builds `OakReader-Dev.app`,
   Release builds `OakReader.app`. Scope the lookup to the `OakReader` target:
   the scheme also builds `oak`, and a bare `grep -m1` can pick up that
   target's settings instead.
   ```bash
   open "$(xcodebuild -scheme OakReader -configuration Debug -showBuildSettings -json 2>/dev/null \
     | python3 -c 'import json,sys; s=next(t["buildSettings"] for t in json.load(sys.stdin) if t.get("target")=="OakReader"); print(s["BUILT_PRODUCTS_DIR"] + "/" + s["FULL_PRODUCT_NAME"])')"
   ```

4. **Report** the result: whether the build succeeded and the app was launched, or what went wrong.

## Notes

- Signing is defined in the **xcconfig layer**, scoped to the OakReader target
  (`xcconfig/OakReader-debug.xcconfig` → `OakReader-common.xcconfig`): default Apple
  Development identity, team `5Y27G7B6D8`, Automatic — overridable by a gitignored
  `xcconfig/DeveloperSettings.xcconfig`. A stable identity keeps login-keychain items and
  TCC permissions from being invalidated across rebuilds. Never pass
  `CODE_SIGN_*`/`DEVELOPMENT_TEAM` as global `xcodebuild` overrides — that breaks the SPM
  packages and the `oak` tool.
- Use Debug configuration by default (bundle ID `com.oakreader.OakReader.dev`, display
  name "OakReader Dev", kept separate from the release app). For a release/distribution
  build, use the `macos-release-setup` flow instead — do not produce one here.
- Do NOT modify project files during a rebuild (pbxproj, entitlements, etc.).
- For the **maintainer's** dev build, prefer the stable Apple Development identity (the
  default) over ad-hoc, so keys and TCC grants persist. If that cert is genuinely
  unavailable on the machine, report it rather than silently switching to ad-hoc; a
  contributor without it would instead add a local `DeveloperSettings.xcconfig`.
