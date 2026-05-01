---
name: swift-rebuild
description: "Kill the running OakReader app, rebuild it via xcodebuild, and relaunch it. Invoke when user says 'rebuild', 'rebuild app', 'restart app', or 'relaunch'."
---

# Rebuild App

Kill the running OakReader.app process, rebuild the project, and relaunch.

## Instructions

When invoked, execute these steps sequentially:

1. **Kill the running app**:
   ```bash
   pkill -x OakReader || true
   ```

2. **Rebuild**:
   ```bash
   xcodebuild -scheme OakReader -configuration Debug build \
     CODE_SIGN_IDENTITY="-" \
     CODE_SIGNING_REQUIRED=NO \
     CODE_SIGNING_ALLOWED=NO \
     DEVELOPMENT_TEAM="" \
     2>&1 | tail -5
   ```
   - If the build fails, show the error output and stop. Do NOT relaunch.

3. **Find and launch the built app**:
   ```bash
   open "$(xcodebuild -scheme OakReader -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')/OakReader.app"
   ```

4. **Report** the result: whether the build succeeded and the app was launched, or what went wrong.

## Notes

- Always use `CODE_SIGN_IDENTITY="-"` and disable code signing to avoid provisioning profile errors.
- Use Debug configuration by default. If the user asks for a release build, use `-configuration Release` instead.
- Do NOT modify any project files (pbxproj, entitlements, etc.).
