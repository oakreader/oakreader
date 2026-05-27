# OakReader Release Setup

How versioning and the signed/notarized auto-update pipeline work, and the one-time
setup the **human** must complete before the workflow can produce a release.

> **OakReader has its own Apple Developer account / Team — distinct from any other
> project (e.g. sarea).** Every credential below (Team ID, Developer ID certificate,
> App Store Connect API key, provisioning profile) must come from **OakReader's own
> team**. Do not reuse another project's certs, keys, or Team ID — notarization and
> launch will fail if the signing identity and the embedded profile disagree.

## Version model

Two numbers in `Info.plist`, both driven by build settings in `project.yml`:

| Key | Build setting | Audience | Rule |
|-----|--------------|----------|------|
| `CFBundleShortVersionString` | `MARKETING_VERSION` | Humans (About box) | SemVer `X.Y.Z`; may repeat |
| `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | Sparkle / system | Must strictly increase per shipped build |

- **`MARKETING_VERSION` (in `project.yml`) is the source of truth and the release
  trigger.** Bump it, merge to `main`, and the workflow ships.
- **`CURRENT_PROJECT_VERSION` is derived in CI** as `git rev-list --count HEAD` and
  injected via an `xcodebuild` override at archive time. The `"1"` in `project.yml` is
  only a placeholder for local builds. This commit-count value is what Sparkle compares;
  if it ever repeats, `generate_appcast` collapses releases and clients miss updates.
- **Dedup guard:** the workflow skips if tag `v<MARKETING_VERSION>` already exists, so
  re-pushing `main` without bumping does nothing.

## Hosting

DMGs and the appcast live on **Cloudflare R2** behind `downloads.oakreader.com`:

- DMG: `https://downloads.oakreader.com/oakreader/v<version>/OakReader.dmg`
- Appcast: `https://downloads.oakreader.com/oakreader/appcast.xml` (matches `SUFeedURL`)

The workflow downloads the existing `appcast.xml` before running `generate_appcast` so
release history is **merged, not replaced**.

---

## One-time setup (human)

### 1. Developer ID certificate (OakReader's team)
1. Apple Developer Portal → Certificates → create a **Developer ID Application**
   certificate, install it, then export as `.p12` from Keychain Access.
2. Base64-encode and store:
   ```bash
   base64 -i certificate.p12 | pbcopy
   gh secret set DEVELOPER_ID_CERT_P12      # paste the base64
   gh secret set DEVELOPER_ID_CERT_PASSWORD # the .p12 export password
   ```

### 2. Apple Team ID
Find it at developer.apple.com/account (Membership), then:
```bash
gh secret set APPLE_TEAM_ID
```

### 3. App Store Connect API key (for notarization)
1. App Store Connect → Integrations → App Store Connect API → Generate API Key
   (Developer access). Download the `.p8` (one-time) and note Key ID + Issuer ID.
2. ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   gh secret set ASC_API_KEY    # base64 of the .p8
   gh secret set ASC_KEY_ID     # the Key ID
   gh secret set ASC_ISSUER_ID  # the Issuer ID
   ```

### 4. Provisioning profile (required — restricted entitlement)
OakReader's entitlements include `keychain-access-groups`, which is **restricted**:
under Developer ID it requires an embedded provisioning profile, or macOS SIGKILLs the
app at launch ("No matching profile found"). The keychain code uses the data-protection
keychain (`kSecUseDataProtectionKeychain`), which itself requires this entitlement — so
the profile is mandatory, not optional.

1. Apple Developer Portal → Profiles → create a **Developer ID** provisioning profile
   for app ID `com.oakreader.OakReader`, tied to the Developer ID Application certificate
   from step 1. Download the `.provisionprofile`.
2. ```bash
   base64 -i OakReader.provisionprofile | pbcopy
   gh secret set PROVISIONING_PROFILE   # base64 of the .provisionprofile
   ```
   The workflow installs it, reads its name, archives with
   `PROVISIONING_PROFILE_SPECIFIER`, and embeds it so the entitlement validates.

### 5. Sparkle EdDSA keypair
1. Build the app once locally so Sparkle is fetched, then generate the keypair:
   ```bash
   find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin/generate_keys" -exec {} \;
   ```
   This prints the **public** key and stores the private key in your login keychain.
2. Paste the **public** key into `project.yml` → `targets.OakReader.settings.base`:
   ```yaml
   SPARKLE_PUBLIC_ED_KEY: "<public key printed above>"
   ```
   (Public keys are not secret; committing it is correct. It's baked into `SUPublicEDKey`.)
3. Export the **private** key and store it as a secret:
   ```bash
   find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin/generate_keys" -exec {} -x \;
   gh secret set SPARKLE_ED_KEY   # paste the private key
   ```

### 6. Cloudflare R2
1. Create an R2 bucket named **`oakreader-downloads`**.
2. Add a custom domain **`downloads.oakreader.com`** pointing at the bucket (public read).
3. Create an R2 API token with Object Read & Write, then:
   ```bash
   gh secret set R2_ACCESS_KEY_ID
   gh secret set R2_SECRET_ACCESS_KEY
   gh secret set R2_ENDPOINT        # https://<account_id>.r2.cloudflarestorage.com
   ```

### Secrets summary

| Secret | Source |
|--------|--------|
| `DEVELOPER_ID_CERT_P12` | Exported Developer ID cert (base64) |
| `DEVELOPER_ID_CERT_PASSWORD` | `.p12` export password |
| `APPLE_TEAM_ID` | Developer account membership page |
| `ASC_API_KEY` | App Store Connect API `.p8` (base64) |
| `ASC_KEY_ID` | App Store Connect API key page |
| `ASC_ISSUER_ID` | App Store Connect API key page |
| `PROVISIONING_PROFILE` | Developer ID provisioning profile (base64) |
| `SPARKLE_ED_KEY` | Sparkle `generate_keys -x` output (private) |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 API token |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 API token |
| `R2_ENDPOINT` | Cloudflare R2 account endpoint |

`SPARKLE_PUBLIC_ED_KEY` is **not** a secret — it lives in `project.yml`.

---

## Releasing

1. Bump `MARKETING_VERSION` in `project.yml` (SemVer `X.Y.Z`).
2. Open a PR, merge to `main`.
3. The Release workflow runs automatically: archive → sign → notarize → DMG → appcast
   merge → upload to R2 → tag `v<version>` → draft GitHub Release.
4. Review the draft release and publish when ready.
5. Verify the DMG at `https://downloads.oakreader.com/oakreader/v<version>/OakReader.dmg`
   and the appcast at `https://downloads.oakreader.com/oakreader/appcast.xml`.
6. Confirm an installed older build sees the update via "Check for Updates…".

> Until the secrets above are configured, every push to `main` triggers a Release run
> that fails fast at the signing step. That's expected — it's a no-op that produces no
> tag or release.
