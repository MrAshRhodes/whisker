# Security

## Supported versions

Security fixes target the latest release. Please update and check whether the problem still
occurs before reporting. Reports about older versions are welcome, but the fix may require
upgrading.

## Report a vulnerability

Report suspected vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/MrAshRhodes/whisker/security/advisories/new).
Do not open a public issue or pull request with vulnerability details or a working exploit.

Please include:

- The Whisker version, macOS version, Mac model and installation method (download or Homebrew).
- The mouse or trackball involved, if relevant.
- What happened, what you expected and the possible security impact.
- Steps to reproduce, and a settings file that shows the problem with any personal paths or
  web addresses removed.

## What Whisker can access

Whisker needs the macOS **Accessibility** permission. It uses it to:

- observe mouse button, drag and scroll-wheel events, together with the modifier keys held at
  the time, so it can decide whether a mapping applies;
- replace those events with the action you assigned, which may mean posting a different click,
  a keyboard shortcut, a media key or a scroll event;
- read the name of the frontmost app, to choose the matching profile.

Whisker reads the list of connected pointing devices and, where supported, changes their pointer
speed and acceleration through public IOKit interfaces. It restores the original values when it
quits, and at the next launch if it did not quit cleanly.

Whisker does not record keystrokes, take screenshots, read window contents or send any of this
information anywhere. Settings are stored locally in
`~/Library/Application Support/Whisker/settings.json`, and Whisker reads your keyboard shortcut
preferences only to perform system actions such as Mission Control.

Relevant reports include:

- events being remapped, swallowed or posted when they should not be, or modifier keys or mouse
  buttons left held down;
- a crafted settings file causing Whisker to run something other than the actions it lists, or
  to open files or addresses without the user having configured them;
- pointer or scroll settings that are not restored;
- ways to bypass release signing, notarization or update verification.

## Update integrity and credentials

Releases are signed with an Apple Developer ID certificate, use the hardened runtime and are
notarized by Apple. Gatekeeper stays enabled, and the Homebrew cask does not remove quarantine.
Each release publishes a SHA-256 checksum for its ZIP and DMG.

Direct downloads update with Sparkle 2. The update feed is fetched over HTTPS from
`https://mrashrhodes.github.io/whisker/appcast.xml` and must carry a valid EdDSA signature, as
must the downloaded archive before it is extracted. Sparkle also checks that the new app has a
valid code signature before installing it. The update key is separate from the Developer ID
certificate.

Automatic checks are off by default. Whisker makes no update request until you check manually or
choose a schedule, and sends no system profile. Downloading and installing both need your
confirmation. Homebrew copies are never replaced by Sparkle, and source builds without the
release public key cannot update themselves.

Signing and notarization credentials and the Sparkle private key are kept in the protected GitHub
**release** environment and secure local storage, never in the repository, app bundle or logs.
Only the Sparkle public key is embedded in the app. Report suspected key exposure privately using
the channel above.

## Response and disclosure

Whisker is maintained on a reasonable-effort basis. Reports will be investigated and fixes and
disclosure coordinated where possible, but there is no guaranteed response time.
