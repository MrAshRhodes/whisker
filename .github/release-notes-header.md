## Install

```sh
brew install --cask mrashrhodes/tap/whisker
```

Or download `Whisker-@VERSION@.zip` and its matching `Whisker-@VERSION@.zip.sha256` below. For a DMG instead, download `Whisker-@VERSION@.dmg` and `Whisker-@VERSION@.dmg.sha256`. Keep the pair from this release in the same folder without renaming either file.

Before extracting the ZIP or opening the DMG, open Terminal and change to that folder (for example, `cd ~/Downloads`). Run **only the command for your chosen format**:

**ZIP:**

```sh
shasum -a 256 -c "Whisker-@VERSION@.zip.sha256"
```

**DMG (instead of ZIP):**

```sh
shasum -a 256 -c "Whisker-@VERSION@.dmg.sha256"
```

Continue only if the command succeeds and reports `Whisker-@VERSION@.zip: OK` (or `Whisker-@VERSION@.dmg: OK`). **If verification fails for any reason, including a mismatch or a missing archive or checksum, stop. Do not install the app or clear quarantine.** Download the matching pair again from this official release and verify again.

After successful verification, extract the ZIP or open the DMG and move **Whisker.app** to your Applications folder. A matching checksum confirms agreement with the published checksum; it is not notarization or proof that the app is safe.

This release is signed with Apple Developer ID and notarized, with tickets stapled to the app and DMG. Gatekeeper checks stay enabled, including for Homebrew installations. If macOS rejects the app, stop and investigate; do not clear quarantine or bypass a warning.

Whisker asks for **Accessibility** permission on first launch so it can read and remap mouse input. Allow it in System Settings > Privacy & Security > Accessibility (and Input Monitoring if macOS asks), then relaunch Whisker. Developer ID updates use the same signing requirement to preserve the permission.

## Update an existing installation

Direct downloads include **Sparkle in-app updates**. Choose **Check for Updates…** from Whisker's menu bar menu, or **Check Now** in Whisker's settings under Updates. Whisker verifies signed feeds and archives, asks before downloading, then asks again before installing and relaunching.

**Automatic checks are off by default.** Choose Daily, Weekly or Monthly in Whisker's settings to opt in, or Never to turn them off. Scheduled checks still ask before downloading or installing anything. Only stable releases are offered.

**Homebrew:** Whisker leaves updates to Homebrew and shows its command with a Copy Command button. Quit Whisker, run `brew update && brew upgrade --cask whisker`, then reopen it. `brew update` alone does not upgrade the app. The new version becomes available once the Homebrew tap has been updated after this release.

[Changelog](https://github.com/MrAshRhodes/whisker/blob/v@VERSION@/CHANGELOG.md) · [Product site](https://mrashrhodes.github.io/whisker/) · [User and update guide](https://mrashrhodes.github.io/whisker/guide.html#updates)
