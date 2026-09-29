---
name: macos-release-setup
description: Set up or audit version management and the release/auto-update pipeline for a macOS app — SemVer marketing version, git-derived monotonic build number, GitHub Actions release workflow (codesign + notarize + DMG), and Sparkle EdDSA-signed appcast hosting. Use when the user wants to configure versioning, add auto-updates, wire a release workflow, set up Sparkle, or ship a signed/notarized macOS app. The agent does the code/config work; credential and hosting steps are handed to the human to perform and verify.
---

# macOS release & version-management setup

Configure a macOS app's versioning and release pipeline to the production pattern: a
hand-edited SemVer marketing version as the release trigger, a git-derived monotonic
build number, and a GitHub Actions workflow that signs, notarizes, packages, and
publishes a Sparkle auto-update feed.

This is a **collaborative** skill. The agent owns everything that is code and config in
the repo. Anything requiring secrets, Apple/Developer credentials, key material, or
external hosting is the **human's** job — the agent prepares it, hands off clear
instructions, and then *waits for the human to confirm* before continuing. Never fake,
guess, or hardcode a secret; never claim a credential step is done that only the human
can do.

## Reference implementation

Use the open-source **boring.notch** app (TheBoredTeam) as the public, inspectable
reference for this pattern — a polished, actively-maintained macOS app with a complete
GitHub-native release pipeline. **Read its workflow first** and adapt it — don't reinvent:
- `https://github.com/TheBoredTeam/boring.notch/blob/main/.github/workflows/release.yml`
  — the full pipeline (sign → notarize → DMG → Sparkle `generate_appcast` → publish)
- Fetch it with: `gh api repos/TheBoredTeam/boring.notch/contents/.github/workflows/release.yml --jq .content | base64 -d`

What it demonstrates (each maps to a step below):
- **Tag-dedup guard:** `git rev-parse refs/tags/v${VERSION}` — skip if already released.
- **Monotonic build number:** `BUILD_NUMBER="${GITHUB_RUN_NUMBER}"` (CI run number). A
  valid alternative is `git rev-list --count HEAD`; either works as long as it never
  repeats or decreases.
- **Sparkle from source:** builds `generate_appcast` pinned via `Package.resolved`, then
  EdDSA-signs the appcast with a private key held in a GitHub secret.
- **GitHub-native hosting:** DMG published via `gh release create`; `appcast.xml`
  committed back into the repo — no external S3/R2 bucket required.
- **Deliberate trigger:** an admin comments `/release vX.Y.Z` on a PR. (Simpler projects
  may prefer push-to-`main` with the version read from the project file — pick one.)

## The mental model (explain this, then apply it)

A macOS app carries two version numbers in `Info.plist`:

| Key | Build setting | Audience | Rule |
|-----|--------------|----------|------|
| `CFBundleShortVersionString` | `MARKETING_VERSION` | Humans (About box, site) | SemVer `X.Y.Z`; may repeat |
| `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | System / Sparkle / App Store | Must **strictly increase** every shipped build |

Core decisions of this pattern:
1. **Marketing version is the source of truth.** Hand-edit it; a new value drives a
   release (via push-to-`main` or an explicit `/release vX.Y.Z` trigger — pick one).
2. **Build number is derived, never hand-edited:** use a monotonic source — either
   `git rev-list --count HEAD` or the CI run number (`GITHUB_RUN_NUMBER`, as boring.notch
   does). This is what Sparkle compares — if it ever repeats or decreases, the appcast
   collapses releases and clients miss updates.
3. **Dedup guard:** the workflow skips if tag `v<MARKETING_VERSION>` already exists, so a
   re-run without bumping the version does nothing.

## Workflow

Work top to bottom. Steps are tagged **[AGENT]** (do it) or **[HUMAN]** (hand off and
wait for confirmation). Confirm with the human before any push, secret, or release.

### 1. [AGENT] Detect the project shape
- Is the project XcodeGen (`project.yml`) or a raw `.xcodeproj`? Version settings live in
  `project.yml` `settings:` for the former, `project.pbxproj` build configs for the latter.
- Does it already use Sparkle (SPM dependency)? Is there an existing release workflow,
  appcast URL (`SUFeedURL`), or signing setup?
- **Check the things that break the first CI run (see "Failure modes to preempt"):** the
  developer's local toolchain (`xcodebuild -version`, `swift --version`); how many SPM
  package + command-line-tool targets exist; whether `Package.resolved` is gitignored;
  whether the app declares `keychain-access-groups` / uses the data-protection keychain;
  and whether committed `HEAD` actually compiles from a clean checkout.
- Report findings and the specific gaps before changing anything.

### 2. [AGENT] Set explicit version settings
- Set `MARKETING_VERSION` (SemVer; start `0.1.0` or current) and a placeholder
  `CURRENT_PROJECT_VERSION = 1` in the repo. For XcodeGen:
  ```yaml
  settings:
    base:
      MARKETING_VERSION: "0.1.0"
      CURRENT_PROJECT_VERSION: "1"
  ```
  For raw pbxproj, set it in every build config. The real build number is injected by CI
  at archive time via `xcodebuild` overrides — the repo value is just a placeholder.

### 3. [HUMAN] Apple Developer credentials
Hand the human this checklist and **wait** — the agent cannot create these:
- A **Developer ID Application** certificate, exported as `.p12` (base64 it for the secret).
  This cert can **only be created by the Account Holder** — the ASC API key / fastlane is
  rejected ("This operation can only be performed by the Account Holder"). Fastest path:
  Xcode → Settings → Accounts → Manage Certificates → **+ Developer ID Application**; the
  agent can then `security export` the `.p12` and set the secrets.
- An **App Store Connect API key** (or Apple ID + app-specific password) for `notarytool`.
  Unlike the cert, profiles and notarization *can* be automated with this key.
- The **Team ID** — read it from the issued Developer ID cert
  (`security find-identity -v -p codesigning` → `… (TEAMID)`), not assumed. Developers
  often have multiple teams (free personal + paid org); the signing team is the cert's
  team, and the ASC key, cert, and profile must all be the same team.
Ask the human to confirm they have each before wiring the workflow. Offer to walk them
through `security`/`notarytool` commands they run themselves via `!`-prefixed input.

### 4. [HUMAN] Sparkle EdDSA keypair
- After the project builds Sparkle once, the human runs Sparkle's `generate_keys` to
  produce the EdDSA keypair. The **public** key goes into `Info.plist` as `SUPublicEDKey`;
  the **private** key becomes a GitHub secret (e.g. `SPARKLE_ED_KEY`).
- The agent can prepare the exact commands and the Info.plist edit, but the human must
  generate and store the key. **Wait for confirmation** the public key is in Info.plist.

### 5. [HUMAN] Hosting for the appcast + DMG
- Decide where the appcast XML and DMGs are served. Simplest is **GitHub-native** (as
  boring.notch does): DMG on GitHub Releases, `appcast.xml` committed to the repo and
  served via raw/GitHub Pages — no extra credentials. Larger projects may prefer S3 /
  Cloudflare R2 behind a `downloads.<domain>` host.
- The human confirms the public base URL (and creates the bucket/credentials if not using
  the GitHub-native route). The agent needs that URL to set `SUFeedURL`.

### 6. [AGENT] Wire Sparkle into the app (if not already)
- Add the Sparkle SPM dependency, the updater controller, and Info.plist keys:
  `SUFeedURL` (from step 5), `SUPublicEDKey` (from step 4), `SUEnableInstallerLauncherService`
  as needed. Add a "Check for Updates…" menu item.

### 7. [AGENT] Write the release workflow
Adapt boring.notch's `release.yml` (fetch it as shown above). It must:
- Have a single, deliberate trigger (push to `main`, or `/release` comment) with
  `concurrency` so only one release runs at a time.
- Resolve the version (from the project file or the trigger) and a monotonic
  `BUILD_NUMBER` (`git rev-list --count HEAD` or `${GITHUB_RUN_NUMBER}`).
- Skip if tag `v<version>` exists.
- Import the signing cert into a temp keychain, archive with **only**
  `MARKETING_VERSION=… CURRENT_PROJECT_VERSION=…` as CLI overrides. Put Developer ID
  signing (identity, style, team, profile) in the **app target's Release config**, not on
  the `xcodebuild` command line — see failure mode 1. Match `runs-on`/Xcode to the
  project's toolchain (failure mode 2) and pin deps with `-onlyUsePackageVersionsFromResolvedFile`
  (failure mode 3).
- Package a DMG (`create-dmg`/`hdiutil`), notarize (`xcrun notarytool`), staple.
- Run Sparkle's `generate_appcast` (EdDSA key from secret) to **merge** (not replace)
  history into the existing appcast, then publish DMG + appcast to the chosen hosting
  (GitHub Releases + committed `appcast.xml`, or S3/R2).
- Create a GitHub Release tagged `v<version>`.
Reference the secret names but never inline secret values.

### 8. [HUMAN] Add GitHub secrets
List every secret the workflow references (`DEVELOPER_ID_CERT_P12`,
`DEVELOPER_ID_CERT_PASSWORD`, `SPARKLE_ED_KEY`, notarization creds, R2/S3 keys, etc.) and
ask the human to add them in repo Settings → Secrets. **Wait for confirmation.** Offer the
`gh secret set` commands for them to run via `!`.

### 9. [AGENT] Document it
Write a `docs/release-setup.md` listing every secret, the key-gen steps, and the release
ritual (e.g. "bump `MARKETING_VERSION` → merge to `main`", or "comment `/release vX.Y.Z`").

### 10. [HUMAN] First release verification
The agent can dry-run/validate workflow YAML, but the real signed/notarized release must
be triggered and observed by the human. Ask them to bump the version, merge, and confirm:
the workflow ran, the DMG notarized, the appcast updated, and an installed older build
sees the update. Report back together.

## Failure modes to preempt (hard-won)

These are the blockers that actually break a first CI release — especially on apps with
many SPM dependencies, native (C++/Metal) deps, embedded helper/CLI targets, or restricted
entitlements. Check them *while wiring the workflow*, not after a red run.

1. **Scope signing to the app target — never as global `xcodebuild` overrides.** Passing
   `PROVISIONING_PROFILE_SPECIFIER` / `CODE_SIGN_IDENTITY` / `CODE_SIGN_STYLE` on the
   `xcodebuild` command line applies them to *every* target; SPM package targets and
   command-line-tool targets then fail with "`X` does not support provisioning profiles."
   Put Developer ID signing in the **app target's Release config** — an xcconfig wired via
   XcodeGen `targets.<App>.configFiles.Release` (OakReader uses
   `xcconfig/OakReader-release.xcconfig`), or `targets.<App>.configs.Release`, or the app
   target's pbxproj Release config. The CLI archive should inject only `MARKETING_VERSION`
   / `CURRENT_PROJECT_VERSION`.

2. **Match the CI runner's toolchain to the project's actual Swift version.** Don't trust
   `project.yml`'s `xcodeVersion` or `macos-latest`. Check the developer's local
   `xcodebuild -version` / `swift --version`. A transitive dep pinned to a newer Swift
   tools-version fails resolution on an older runner ("package … is using Swift tools
   version 6.2.0 but the installed version is 6.0.0"). Pick the `runs-on` image
   (`macos-15` vs `macos-26`, …) and Xcode that provide that toolchain.

3. **Pin SPM dependencies for reproducible CI.** `Package.resolved` is often gitignored,
   so CI resolves *newer* versions than the developer has locally and the build breaks on
   a changed API (real example: usearch dropped an enum member between minor versions).
   Commit the Xcode project's resolved file
   (`<App>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) and
   resolve/archive with `-onlyUsePackageVersionsFromResolvedFile`.

4. **Restricted entitlements need an embedded provisioning profile under Developer ID —
   OakReader declares one and the workflow is already wired for it.** The app ships
   `keychain-access-groups` (`5Y27G7B6D8.com.oakreader.keys`, hardcoded — see below) so
   credentials use the macOS *data-protection* keychain (`kSecUseDataProtectionKeychain`)
   and survive rebuilds/identity changes. That is a restricted entitlement: AMFI SIGKILLs
   the app **at launch** unless a provisioning profile is embedded — notarization still
   passes, so you discover it only when the app won't open. How it's wired:
   - `xcconfig/OakReader-release.xcconfig` (wired via `project.yml`'s
     `targets.OakReader.configFiles.Release`) sets `CODE_SIGN_STYLE = Manual` +
     `PROVISIONING_PROFILE_SPECIFIER = OakReader Developer ID` + the access-group
     entitlement, **scoped to the app target** (never as a global xcodebuild override —
     that fails the `oak` command-line tool with "does not support provisioning profiles",
     see failure mode #1's cousin at the top of this list). Note: Release re-asserts these
     after the optional `DeveloperSettings.xcconfig` include, so a contributor's local
     signing override can't weaken distribution signing. Debug uses a separate
     `OakReader-dev.entitlements` that omits the access group (see `contributor-signing-xcconfig`).
   - `release.yml` "Import provisioning profile" step decodes the `PROVISIONING_PROFILE`
     secret, asserts it grants `5Y27G7B6D8.com.oakreader.keys` (or `5Y27G7B6D8.*`) and is
     named exactly `OakReader Developer ID`, then installs it so the archive embeds it.
   - The re-seal step re-signs with the **archive's own captured entitlements**, not the
     static `OakReader.entitlements`, so the expanded `com.apple.application-identifier`
     that pairs with the profile survives (re-sealing with the static file would drop it
     and re-introduce the SIGKILL).
   - **`OakReader.entitlements` hardcodes the team prefix** (`5Y27G7B6D8.com.oakreader.keys`,
     NOT `$(AppIdentifierPrefix)…`) because the CLI `codesign` re-seal can't expand Xcode
     build variables. It must equal `OakAI/KeychainConfig.swift`'s `accessGroup`.

   [HUMAN] one-time: create the profile in the Developer portal (App ID
   `com.oakreader.OakReader`, Keychain Sharing capability for the group, name `OakReader
   Developer ID`), then `base64 -i …provisionprofile | gh secret set PROVISIONING_PROFILE`.
   Verify with `security cms -D -i x.provisionprofile`. (The legacy escape hatch — reverting
   to the file-based login keychain, no entitlement/profile — was deliberately abandoned
   because its item ACLs broke on every signing-identity change.)

5. **The release builds committed `HEAD`, not the working tree.** Developers routinely
   build with uncommitted changes, so `main` may not compile from a clean checkout. Confirm
   committed `HEAD` builds clean before (or as part of) wiring releases — otherwise the
   first run dies on plain compile errors that "work on my machine."

Minor, but each cost a cycle: `fastlane cert` maps `developer_id_application` to the
`DEVELOPER_ID_APPLICATION_G2` type, which some accounts' API reject — call Spaceship
directly with `DEVELOPER_ID_APPLICATION`. `wrangler` can create an R2 bucket and bind a
custom domain, but the S3 API token (access key + secret) must be minted in the Cloudflare
dashboard. The custom domain's `ssl_status` is briefly `initializing` after binding — wait
for `active` before relying on the appcast URL.

## Rotating credentials

When a secret is exposed (committed, pasted into a chat/LLM, shared, leaked in logs) or
someone with access leaves, rotate it. Follow **`assets/rotation-checklist.md`** — a
per-credential runbook (R2/S3 token, ASC API key, Developer ID cert, provisioning profile,
GitHub secrets). The agent can run the `gh secret set` step and verify the next run; the
human reissues/revokes at the source.

> **One exception — the Sparkle EdDSA key must NOT be casually rotated.** Its public key is
> baked into already-installed apps; replacing the private key makes every installed client
> reject updates signed with the new key, breaking auto-update for existing users. Treat it
> as long-lived; rotate only on real compromise, and only with a migration (see the
> checklist). If you ever expose the Sparkle *private* key, flag this loudly.

## Guardrails
- **Never** commit, push, or trigger a release without explicit human go-ahead.
- **Never** write a real secret, key, cert, or password into a file or the workflow.
- If a [HUMAN] step isn't confirmed done, stop and ask — don't proceed and don't pretend.
- Prefer reading and adapting boring.notch's working `release.yml` over generating a
  pipeline from memory.
- Keep the build-number monotonicity invariant intact; flag any change that could let
  `CFBundleVersion` repeat or decrease.
