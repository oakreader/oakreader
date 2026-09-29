# Rotating release credentials

A plain-English runbook for replacing the secrets behind a macOS Developer ID + Sparkle
release pipeline.

## When should you rotate?

Rotate a credential whenever it might have been seen by someone who shouldn't have it:

- it got committed to git, pasted into a chat / LLM, or printed in a log
- you shared it, or someone with access left the team
- it's simply old and you rotate on a schedule

## How rotation works (the same five beats every time)

1. **Reissue** the credential at its source (Apple, Cloudflare, etc.).
2. **Update** the matching GitHub secret.
3. **Run** a release (or a dry run) and watch it sign/notarize successfully.
4. **Revoke** the old credential — but only *after* step 3 proves the new one works.
5. **Clean up** any key files left on disk.

Who does what: reissuing and revoking happen in a web dashboard (that's you, the human).
The agent can run the `gh secret set` step and confirm the next pipeline run is green.

> **Tip:** run `gh secret set NAME` *without* a pipe — it prompts for the value, so the
> secret never lands in your shell history. Replace `OWNER/REPO` with your repository.

## At a glance

| Credential (secret names) | What it does | Risk to rotate | Notes |
|---|---|---|---|
| R2 / S3 token (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) | Uploads the DMG + appcast | 🟢 Safe anytime | — |
| App Store Connect key (`ASC_API_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`) | Notarizes the app | 🟢 Safe anytime | — |
| Developer ID cert (`DEVELOPER_ID_CERT_P12`, `..._PASSWORD`) | Signs the app | 🟡 Safe, but regen the profile too | Old DMGs keep working |
| Provisioning profile (`PROVISIONING_PROFILE`) | Allows restricted entitlements | 🟡 Regen after a cert change | Verify it still covers your keychain group |
| **Sparkle EdDSA key (`SPARKLE_ED_KEY`)** | Signs auto-updates | 🔴 **Don't, normally** | Rotating breaks updates for installed users |

---

## 🟢 R2 / S3 storage token

**What it is:** the key that lets CI upload the DMG and `appcast.xml`. It can't touch your
code or signing, so it's the safest one to rotate.

1. Cloudflare dashboard → **R2 → Manage R2 API Tokens** → create a new token (Object Read &
   Write, scoped to the bucket). Copy the new Access Key ID and Secret.
2. Update the secrets:
   ```bash
   gh secret set R2_ACCESS_KEY_ID     --repo OWNER/REPO
   gh secret set R2_SECRET_ACCESS_KEY --repo OWNER/REPO
   ```
3. Re-run the release and confirm the upload step passes.
4. Delete the old token in the dashboard.

`R2_ENDPOINT` is just your account's address, not a secret — leave it alone.

## 🟢 App Store Connect API key

**What it is:** the key `notarytool` uses to notarize. Used only at notarization time.

1. App Store Connect → **Users and Access → Integrations → App Store Connect API** →
   generate a new key (Admin role). Download the new `.p8` and note its **Key ID**. (Your
   **Issuer ID** doesn't change.)
2. Update the secrets:
   ```bash
   base64 -i AuthKey_NEWKEYID.p8 | gh secret set ASC_API_KEY --repo OWNER/REPO
   gh secret set ASC_KEY_ID    --repo OWNER/REPO   # the new Key ID
   gh secret set ASC_ISSUER_ID --repo OWNER/REPO   # unchanged, but reset for completeness
   ```
3. Re-run and confirm notarization is accepted.
4. Revoke the old key in App Store Connect, and delete the local `.p8`.

## 🟡 Developer ID Application certificate

**What it is:** the certificate that signs your app. Rotate it if the private key leaks.
Good news: apps you already notarized keep working — only future builds use the new cert.

1. **(Account Holder only)** Xcode → **Settings → Accounts → Manage Certificates → +
   Developer ID Application**. This creates a fresh certificate and private key in your
   login keychain.
2. Export it and update the secrets (a throwaway password becomes the secret):
   ```bash
   PW=$(openssl rand -base64 18)
   security export -k ~/Library/Keychains/login.keychain-db -t identities \
     -f pkcs12 -P "$PW" -o devid.p12
   base64 -i devid.p12 | gh secret set DEVELOPER_ID_CERT_P12 --repo OWNER/REPO
   printf '%s' "$PW"   | gh secret set DEVELOPER_ID_CERT_PASSWORD --repo OWNER/REPO
   ```
3. If you use a provisioning profile, regenerate it now (next section) so it points at the
   new cert.
4. Re-run and confirm signing + notarization, then revoke the old cert in the Developer
   portal.

## 🟡 Provisioning profile

**What it is:** the embedded profile that lets restricted entitlements (like
`keychain-access-groups`) run under Developer ID. Regenerate it when it expires or after
you rotate the cert above.

1. Recreate the Developer ID provisioning profile, tied to the current Developer ID cert
   (Developer portal → Profiles, or via the ASC API / fastlane / Spaceship). For OakReader
   it must be: App ID **`com.oakreader.OakReader`**, Keychain Sharing capability for group
   **`5Y27G7B6D8.com.oakreader.keys`**, and named **EXACTLY `OakReader Developer ID`** (the
   workflow asserts the name matches the Release `PROVISIONING_PROFILE_SPECIFIER` set in
   `xcconfig/OakReader-release.xcconfig` and fails fast otherwise).
2. **Double-check it still authorizes your keychain group** before trusting it:
   ```bash
   security cms -D -i new.provisionprofile   # keychain-access-groups must include 5Y27G7B6D8.com.oakreader.keys (or 5Y27G7B6D8.*)
   ```
3. Update the secret and re-run:
   ```bash
   base64 -i new.provisionprofile | gh secret set PROVISIONING_PROFILE --repo OWNER/REPO
   ```
4. Confirm the app both notarizes *and launches* (restricted entitlements only bite at
   launch, not during signing).

## 🔴 Sparkle EdDSA key — please read before touching

**Why this one is different:** the matching **public** key is compiled into every copy of
your app that's already installed. Those apps will only accept updates signed with the
*original* private key. If you generate a new key and start signing with it, **everyone who
already installed your app silently stops getting updates.**

So: treat the Sparkle private key as long-lived. Protect it; don't rotate it on a schedule.

**If it's genuinely compromised** and you must rotate, migrate carefully:

1. Keep signing with the **old** key, and ship one update whose `Info.plist` carries the
   **new** `SUPublicEDKey`. Let users adopt that build.
2. Only after they've updated do you switch to signing with the new private key.
3. Anyone who skipped the migration build has to reinstall by hand.

If you ever discover the Sparkle **private** key was exposed, raise it loudly — it's the
most consequential leak in this list.

---

## Cleanup (after any rotation)

- Remove key material from disk: `rm -f *.p12 *.p8 *.pem *_priv* asc_key.json` and any
  temp working dirs.
- Deleting a file does **not** remove a secret from git history. If a secret was ever
  committed, rotate it (above) and, only if truly necessary, scrub history with
  `git filter-repo` / BFG and force-push.
- Always prove the new credential works (a real release or a `workflow_dispatch` dry run)
  *before* revoking the old one, so you can fall back if something's wrong.
