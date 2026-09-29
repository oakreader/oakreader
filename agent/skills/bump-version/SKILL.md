---
name: bump-version
description: "Cut a new OakReader release: gate on whether app code actually changed, verify it builds, bump MARKETING_VERSION, commit + push to main (which triggers the signed/notarized release workflow), then watch the run, publish the draft GitHub Release, and verify the DMG + appcast are live. Invoke when the user says 'bump', 'bump a version', 'bump new version', 'release new version', 'ship a release', 'cut a release', or 'again' right after a prior bump."
---

# Bump Version (cut a release)

Run OakReader's already-configured release pipeline: bump the marketing version and
push to `main`, which fires the `Release` GitHub Actions workflow (build → codesign →
notarize → DMG → Sparkle appcast → R2 upload). This skill is the *routine* — for
first-time pipeline setup/credentials use `macos-release-setup` instead.

Background facts live in the `release-pipeline` memory and `docs/release-setup.md`.
The essentials this skill depends on:

- **Version source of truth:** `MARKETING_VERSION` in `project.yml` (~line 108). Bumping
  it and pushing to `main` is the entire trigger.
- **Build number:** CI sets it to `git rev-list --count HEAD` — monotonic, do not touch.
- **Dedup guard:** the workflow skips if tag `v<version>` already exists, so the version
  MUST be new (a website-only push reuses the current version and the run no-ops in ~15s).
- **Artifacts:** immutable `https://downloads.oakreader.com/oakreader/v<ver>/OakReader.dmg`
  + stable `…/oakreader/OakReader.dmg` + appcast at `…/oakreader/appcast.xml`.
- **GitHub Release is created as a DRAFT** — it must be published explicitly.

## Step 0 — Should we even bump? (gate)

Run `git status --short` and `git diff --stat`. Decide whether a macOS release is
warranted:

- **Bump** when there are unreleased changes under `OakReader/`, `Packages/`, or app
  build settings in `project.yml`.
- **Do NOT bump** for `website`-only or docs-only changes — the website deploys
  separately via Vercel, and a bump would push a no-op Sparkle update plus burn a ~7–8 min
  notarization run and permanent R2 storage. Say so and stop.
- If the working tree is **clean** and the last commit is already a `chore(release): …`,
  there is nothing to ship — say so and stop (do not bump to ship identical code).

Mixed trees are common: commit only the app-relevant files for this release and leave
unrelated WIP (e.g. a `website` refactor) uncommitted unless the user asked otherwise.

## Step 1 — Commit pending app changes

If there are uncommitted app changes that belong in this release, commit them first using
the **`conventional-commit`** skill's rules (proper `type(scope): …`, imperative mood, NO
co-author/AI tags). Split unrelated concerns into separate commits.

## Step 2 — Verify it builds

A failed CI build wastes ~8 minutes, so verify locally first:

```bash
xcodebuild -project OakReader.xcodeproj -scheme OakReader -configuration Debug build 2>&1 \
  | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head
```

If it doesn't print `** BUILD SUCCEEDED **`, fix the errors and stop — do not bump.

## Step 3 — Pick the new version

Read the current `MARKETING_VERSION` from `project.yml`. Default to a **patch** bump
(`0.7.6` → `0.7.7`) — that is what routine fixes/features in this 0.x line have used.
Choose `minor` only if the user says so or the change is clearly a notable feature, and
`major` only on explicit request. If genuinely ambiguous, ask; otherwise pick patch and
state which you chose.

Confirm the chosen `v<version>` tag does not already exist (`git tag | grep v<version>`).

## Step 4 — Bump, commit, push

Edit `project.yml` to the new `MARKETING_VERSION`, then:

```bash
git add project.yml
git commit -q -m "chore(release): <version>"
git push origin main
```

(The release commit is a plain `chore(release): X.Y.Z` — no co-author/AI tags, matching
every prior release commit.)

## Step 5 — Watch, publish, verify

Confirm the run started, watch to completion, publish the draft, and verify artifacts:

```bash
sleep 8
RUN_ID=$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1
gh run view "$RUN_ID" 2>&1 | grep -E "release in|conclusion"

gh release edit v<version> --draft=false
curl -sI https://downloads.oakreader.com/oakreader/v<version>/OakReader.dmg | grep -iE "^HTTP"
curl -s  https://downloads.oakreader.com/oakreader/appcast.xml | grep -iE "shortVersionString" | head -1
```

A healthy release shows: `✓ release in ~7–8m`, DMG `HTTP/2 200`, and the appcast's top
`<sparkle:shortVersionString>` equal to the new version. The run takes ~7–8 minutes —
consider running the watch step in the background.

## Step 6 — Report

State the version shipped, what it contains (one line), and the published release URL
(`https://github.com/oakreader/oakreader/releases/tag/v<version>`). Note that existing
users get the update automatically via Sparkle, and call out anything deliberately left
uncommitted.

## Failure modes

- **Run no-ops in ~15s** → the version wasn't new (tag already existed). Bump again.
- **Notarization `Invalid` / timeout** → see `release-pipeline` memory; do not chase a
  phantom signing error. Pull the notary log with the `notarytool log` command recorded
  there.
- **DMG/appcast stale after success** → the Cloudflare cache purge step handles this; if
  it lags, re-check after a moment rather than re-releasing.
- **`gh` not authenticated** → surface it; the user must `gh auth login` (a human step).
