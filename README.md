<p align="center"><img src="docs/assets/icon-1024.png" width="128" height="128" alt="Whisker app icon"></p>

# Whisker

Whisker is a free, open-source menu bar app for macOS that customises mice and trackballs. It
remaps extra buttons, changes how the scroll wheel behaves, adjusts pointer speed and switches
settings automatically for the app you are using.

Product site and user guide: <https://mrashrhodes.github.io/whisker/>

## Features

- **Button remapping.** Assign an action to any button from the middle button upwards, optionally
  combined with ⌘, ⌥, ⌃, ⇧ or fn, so one button can do several things. The primary button is
  never remapped on its own, so you cannot lock yourself out of clicking.
- **Actions.** Click another button, press a keyboard shortcut (optionally repeating while the
  button is held), go back or forward, control media playback and volume, open Mission Control,
  move between Spaces, switch to the next or previous app, open a file or web address, or do
  nothing at all.
- **Scrolling.** Reverse the vertical or horizontal wheel for each mouse without changing the
  trackpad or the system's natural-scrolling setting, choose how many lines each wheel notch
  scrolls, and run an action when you turn the wheel while holding a modifier key.
- **Per-app profiles.** Give an app its own buttons and scrolling. Anything a profile does not
  set falls back to the default profile, and Whisker switches profiles as you change apps.
- **Pointer speed and acceleration**, per device, where supported. If a change makes the
  pointer much faster, Whisker asks you to confirm it and reverts automatically after a few
  seconds if you cannot. Original values are restored when Whisker quits.
- **Devices.** Lists connected mice and trackballs, including ones you plug in or pair while
  Whisker is running.
- **Menu bar item** to turn Whisker on or off and open its settings, plus an optional login item.
- **Settings file.** Everything is kept in one readable JSON file that you can export and import.
- **Updates** through Sparkle for direct downloads, or through Homebrew.

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel.
- The **Accessibility** permission. Whisker watches mouse button and scroll-wheel events so it
  can replace them with the actions you choose, and macOS only allows that for apps you have
  approved under Accessibility. Whisker does not read what you type.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask mrashrhodes/tap/whisker
```

Or download `Whisker-<version>.dmg` or `Whisker-<version>.zip` from the
[latest release](https://github.com/MrAshRhodes/whisker/releases/latest), check it against the
matching `.sha256` file as described in the release notes, and move **Whisker.app** to your
Applications folder.

Releases are signed with Apple Developer ID and notarized by Apple. Gatekeeper stays enabled; if
macOS refuses to open the app, stop and report it rather than bypassing the warning.

## First run

1. Open Whisker. Its icon appears in the menu bar and the settings window explains why it needs
   Accessibility access.
2. Click **Open Accessibility Settings**, turn Whisker on in
   **System Settings › Privacy & Security › Accessibility**, then return to Whisker. It notices
   the change within a second or so.
3. Choose whether Whisker opens at login, then pick a device and start assigning buttons.

See the [user guide](https://mrashrhodes.github.io/whisker/guide.html) for each settings pane.

## Privacy

Whisker works entirely on your Mac. It has no accounts, analytics or telemetry, and it makes no
network requests except update checks, which are off until you turn them on or choose
**Check for Updates…**. Your settings stay in
`~/Library/Application Support/Whisker/settings.json`.

## Updates

Direct downloads update in place with [Sparkle](https://sparkle-project.org). Choose
**Check for Updates…** from the menu bar menu, or pick a schedule under Updates in the settings
window. Automatic checks are off by default. Whisker asks before downloading and again before
installing, and every update must carry a valid Whisker update signature and Apple Developer ID
signature.

Homebrew copies are updated by Homebrew. Quit Whisker, then run:

```sh
brew update && brew upgrade --cask whisker
```

## Troubleshooting

- **Buttons or scrolling do nothing.** Check that Whisker is switched on in the menu bar menu and
  under **System Settings › Privacy & Security › Accessibility**. If the menu bar icon is crossed
  through, choose **Grant Accessibility Access…** from its menu.
- **Whisker is listed under Accessibility but still does not work.** This usually follows a
  rebuild or reinstall from a differently signed copy. Remove the entry, or run
  `tccutil reset Accessibility io.github.mrashrhodes.whisker`, then open Whisker and allow it
  again.
- **A system action such as Mission Control or a Space switch does nothing.** Whisker performs
  these with your keyboard shortcuts from **System Settings › Keyboard › Keyboard Shortcuts**.
  Turn the matching shortcut on there; Whisker shows a warning next to any action whose shortcut
  is missing.
- **Back and forward do nothing in an app.** These send ⌘[ and ⌘]. Map the button to a different
  shortcut in a profile for that app.
- **The pointer is suddenly too fast.** Wait a few seconds without confirming and Whisker reverts
  the change. Quitting Whisker also restores the original speed.
- **Trackpads and Magic Mouse** are left alone for button remapping because they rely on gestures.

## Build from source

Requires the Xcode Command Line Tools (or Xcode) with Swift 5.9 or later.

```sh
git clone https://github.com/MrAshRhodes/whisker.git
cd whisker
make app     # builds dist/Whisker.app
make run     # builds and opens it
make test    # runs the test suite
```

Local builds are signed ad-hoc, so macOS asks for Accessibility again after each rebuild. Source
builds cannot update themselves. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Roadmap

Planned after 0.1, in no particular order:

- Tilt-wheel buttons and two-button chords.
- Auto-scroll, click lock, and double or triple click actions.
- Keyboard shortcut sequences and quick-switch pointer speed presets.
- Native per-device wheel speed and acceleration, and smooth scrolling for notched wheels.
- Support for extra buttons that macOS does not report, using publicly documented protocols.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and report security problems privately as described in [SECURITY.md](SECURITY.md).

## Licence

Whisker is released under the [MIT Licence](LICENSE).
