# Credential rotation runbook

How to replace the secrets behind OakReader's Developer ID + Sparkle release pipeline.
Repo: `oakreader/oakreader`. The full pipeline is documented in
[`docs/release-setup.md`](../release-setup.md); this file is only about rotating the
credentials it depends on.

## When to rotate

Rotate a credential whenever it might have been seen by someone who shouldn't have it:

- it got committed to git, pasted into a chat / LLM, printed in a log, or shared
- someone with access left
- it's old and you rotate on a schedule

> **Open action item:** the **R2 token** and the **ASC API key (`ZD8CURS9CU`)** were once
> pasted into a setup-chat transcript. Both are 🟢 safe-to-rotate-anytime — rotate them
> (sections below) when convenient. They were never committed to the repo, so no git
> history scrub is needed.

## The five beats (every rotation)

1. **Reissue** the credential at its source (Apple / Cloudflare) — *you, in a dashboard*.
2. **Update** the matching GitHub secret — `gh secret set` (you, or the agent).
3. **Prove** it: run a release (or dry run) and watch sign/notarize/upload pass.
4. **Revoke** the old credential — only **after** step 3 is green.
5. **Clean up** key files left on disk.

> Run `gh secret set NAME` **without a pipe** — it prompts for the value, so the secret
> never lands in your shell history. In Claude Code, prefix with `!` so you type the value,
> not the assistant.

## Secrets at a glance

| Credential (secret names) | Purpose | Risk to rotate |
|---|---|---|
| R2 token (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) | Upload DMG + appcast | 🟢 Safe anytime |
| App Store Connect key (`ASC_API_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`) | Notarize | 🟢 Safe anytime |
| Developer ID cert (`DEVELOPER_ID_CERT_P12`, `..._PASSWORD`) | Sign the app | 🟡 Regen profile too |
| Provisioning profile (`PROVISIONING_PROFILE`) | Restricted entitlements | 🟡 Regen after cert change |
| **Sparkle EdDSA key (`SPARKLE_ED_KEY`)** | Sign auto-updates | 🔴 **Do not, normally** |

Non-secret, leave alone: `R2_ENDPOINT` (account address), `ASC_ISSUER_ID`
(`5242c966-78e9-46ac-96f4-c90f9117c419`), Cloudflare zone `4c5dc9f18f814b359a79b7124d0fe681`.

## Proving a rotation (shared step 3)

`MARKETING_VERSION` in `project.yml` is the release trigger, and the workflow skips if tag
`v<version>` already exists. So the way to prove new credentials is a **bump-and-ship**:
edit `MARKETING_VERSION` to the next SemVer, merge to `main`, and watch the run reach the
relevant step (upload for R2, notarization for ASC). Then revoke the old credential.

```bash
gh run watch --repo oakreader/oakreader   # tail the release run
```

---

## 🟢 R2 / S3 storage token

Lets CI upload the DMG + `appcast.xml` to the `oakreader-downloads` bucket. Can't touch code
or signing — safest to rotate.

1. Cloudflare → **R2 → Manage R2 API Tokens** → new token, *Object Read & Write*, scoped to
   `oakreader-downloads`. Copy the Access Key ID + Secret.
2. Update secrets (paste at the prompt):
   ```bash
   gh secret set R2_ACCESS_KEY_ID     --repo oakreader/oakreader
   gh secret set R2_SECRET_ACCESS_KEY --repo oakreader/oakreader
   ```
3. Bump-and-ship; confirm the **upload** step passes.
4. Delete the old token in the Cloudflare dashboard.

## 🟢 App Store Connect API key

Used by `notarytool` at notarization time. This is the leaked `ZD8CURS9CU` key.

1. App Store Connect → **Users and Access → Integrations → App Store Connect API** →
   generate a new key (**Admin** role). Download the new `.p8`, note its **Key ID**. Issuer
   ID is unchanged (`5242c966-78e9-46ac-96f4-c90f9117c419`).
2. Update secrets:
   ```bash
   base64 -i ~/Downloads/AuthKey_<NEWKEYID>.p8 | gh secret set ASC_API_KEY --repo oakreader/oakreader
   gh secret set ASC_KEY_ID --repo oakreader/oakreader     # the NEW key id
   # ASC_ISSUER_ID unchanged — only reset if you want completeness
   ```
3. Bump-and-ship; confirm **notarization** is accepted.
4. Revoke the old key in App Store Connect; `rm -f ~/Downloads/AuthKey_ZD8CURS9CU.p8`.

## 🟡 Developer ID Application certificate

Signs the app. Rotate only if the private key leaks. Already-notarized DMGs keep working —
only future builds use the new cert. **Team must stay `5Y27G7B6D8`** (NOT the personal
`59X959HPTF`).

1. **(Account Holder only)** Xcode → **Settings → Accounts → Manage Certificates → +
   Developer ID Application**. Creates a fresh cert + private key in the login keychain.
2. Export + update secrets (throwaway password becomes the secret):
   ```bash
   PW=$(openssl rand -base64 18)
   security export -k ~/Library/Keychains/login.keychain-db -t identities \
     -f pkcs12 -P "$PW" -o devid.p12
   base64 -i devid.p12 | gh secret set DEVELOPER_ID_CERT_P12 --repo oakreader/oakreader
   printf '%s' "$PW"   | gh secret set DEVELOPER_ID_CERT_PASSWORD --repo oakreader/oakreader
   ```
3. **Regenerate the provisioning profile** (next section) so it points at the new cert.
4. Bump-and-ship; confirm signing + notarization, then revoke the old cert in the portal.
5. `rm -f devid.p12`.

## 🟡 Provisioning profile

The embedded profile that lets the restricted `keychain-access-groups` entitlement run under
Developer ID (without it the app **SIGKILLs at launch** — notarization still passes, so you
only find out when it won't open). Regenerate on expiry or after a cert rotation.

1. Recreate it in the Developer portal, tied to the **current** Developer ID cert:
   - App ID: **`com.oakreader.OakReader`**
   - Keychain Sharing capability for group **`5Y27G7B6D8.com.oakreader.keys`**
   - Named **EXACTLY `OakReader Developer ID`** — the workflow asserts this matches
     `project.yml`'s `PROVISIONING_PROFILE_SPECIFIER` and fails fast otherwise.
2. Verify it still authorizes the keychain group before trusting it:
   ```bash
   security cms -D -i new.provisionprofile   # keychain-access-groups must include 5Y27G7B6D8.com.oakreader.keys (or 5Y27G7B6D8.*)
   ```
3. Update the secret:
   ```bash
   base64 -i new.provisionprofile | gh secret set PROVISIONING_PROFILE --repo oakreader/oakreader
   ```
4. Bump-and-ship; confirm the app both **notarizes AND launches** (restricted entitlements
   bite at launch, not during signing). `rm -f new.provisionprofile`.

## 🔴 Sparkle EdDSA key — read before touching

The matching **public** key (`zm3UpFrDf8tFcctK2vkEhrms6oFTp50AUb824lP9BAw=`) is compiled into
every installed copy of OakReader. Those apps only accept updates signed with the
**original** private key. Generate a new key and start signing with it → **everyone already
installed silently stops getting updates.**

Treat the private key as long-lived. Do **not** rotate on a schedule. Our notes confirm only
R2 + ASC were exposed — the Sparkle key was **not**.

**If it is genuinely compromised**, migrate, don't swap:

1. Keep signing with the **old** key; ship one update whose `Info.plist` carries the **new**
   `SUPublicEDKey`. Let users adopt that build.
2. Only after adoption, switch to signing with the new private key.
3. Anyone who skipped the migration build must reinstall by hand.

If you ever discover the Sparkle **private** key was exposed, raise it loudly — it's the most
consequential leak in this list.

---

## Cleanup (after any rotation)

```bash
rm -f *.p12 *.p8 *.pem *_priv* devid.p12 new.provisionprofile
```

- Deleting a file does **not** remove a secret from git history. None of these were ever
  committed to this repo (they're GitHub secrets), so no scrub is needed. If one ever is
  committed, rotate it *and* scrub history with `git filter-repo` / BFG, then force-push.
- Always prove the new credential works **before** revoking the old one, so you can fall back.

## Secret inventory (verify with `gh secret list --repo oakreader/oakreader`)

`ASC_API_KEY` · `ASC_KEY_ID` · `ASC_ISSUER_ID` · `APPLE_TEAM_ID` · `DEVELOPER_ID_CERT_P12` ·
`DEVELOPER_ID_CERT_PASSWORD` · `PROVISIONING_PROFILE` · `SPARKLE_ED_KEY` ·
`R2_ACCESS_KEY_ID` · `R2_SECRET_ACCESS_KEY` · `R2_ENDPOINT` · `CLOUDFLARE_API_TOKEN`
