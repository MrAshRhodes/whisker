<p align="center"><img src="docs/assets/icon-1024.png" width="128" height="128" alt="Whisker app icon"></p>

# Whisker

Whisker is a free, open-source menu bar app for macOS that customises mice and trackballs. It
remaps extra buttons, changes how the scroll wheel behaves, adjusts pointer speed and switches
settings automatically for the app you are using.

Product site and user guide: <https://mrashrhodes.github.io/whisker/>

## Features

- **Button remapping.** Assign an action to any mouse button or wheel direction, optionally only
  while ⌘, ⌥, ⌃ or ⇧ is held, so one button can do several things. Record a button by pressing
  it, or pick one from a list. The primary button is not remapped unless you hold a modifier key
  or turn on **Allow remapping the primary button**, so you cannot lock yourself out of clicking.
- **Actions.** Click or double-click, press a keyboard shortcut (optionally repeating while the
  button is held), go back or forward, send a media key (play/pause, track, volume, mute or
  display brightness), open Mission Control, App Windows, Show Desktop, Launchpad or
  Notification Centre, move to the Space on the left or right, switch apps, scroll, open an
  app, file or web address, or do nothing at all.
- **Wheel actions.** Turning the wheel runs its action once per burst of notches, or once for
  every notch if you choose **Repeat for every notch**.
- **Scrolling.** Reverse the vertical or horizontal wheel for each mouse without changing the
  trackpad or the system's natural-scrolling setting. Each profile can set how many lines a
  wheel notch scrolls, add scroll acceleration and choose a modifier key that scrolls sideways.
- **Profiles.** Give an app, a mouse, or an app on one mouse its own buttons and scrolling.
  Anything a profile does not set comes from the profile it inherits from, ending at the
  default profile, and Whisker switches profiles as you change apps.
- **Pointer speed and acceleration**, per mouse, where supported. If a change makes the pointer
  more than twice as fast, Whisker asks you to keep it and changes it back after a few seconds
  if you do not. The system's values come back when you turn a mouse's custom speed off, when
  Whisker quits, or at the next launch if it did not quit cleanly.
- **Devices.** Lists connected mice and trackballs, including ones you plug in or pair while
  Whisker is running. With several mice connected, allow Input Monitoring so Whisker can tell
  which one each click came from and apply that mouse's settings. Trackpads and Magic Mouse are
  left alone.
- **Menu bar item** to turn Whisker on or off, see the active profile and open its settings. The
  icon can be hidden, and Whisker can open at login.
- **Settings file.** Everything is kept in one readable JSON file that you can export, import or
  reset. Whisker checks it when it starts and tells you about anything it had to fix.
- **Updates** through Sparkle for direct downloads, or through Homebrew.

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel.
- The **Accessibility** permission. Whisker watches mouse button and scroll-wheel events so it
  can replace them with the actions you choose, and macOS only allows that for apps you have
  approved under Accessibility. Whisker does not read what you type.
- Optionally, **Input Monitoring**, only if you want different settings for several mice that
  are connected at the same time. With one mouse, Whisker does not need it.

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

1. Open Whisker. Its icon appears in the menu bar and a **Welcome to Whisker** window explains
   why it needs Accessibility access.
2. Click **Open Accessibility Settings** and turn Whisker on in
   **System Settings › Privacy & Security › Accessibility**. While the welcome window is open,
   Whisker notices the change within a second or so, with no need to relaunch.
3. Choose whether Whisker opens at login, click **Done**, then open **Settings…** from the menu
   bar menu and start assigning buttons.

If you choose **Continue Without Access**, Whisker stays in the menu bar with a dimmed icon.
Choose **Grant Accessibility Access…** from its menu when you are ready.

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
  under **System Settings › Privacy & Security › Accessibility**. If the menu bar icon is
  dimmed, Whisker is either turned off or missing access; choose **Grant Accessibility Access…**
  from its menu if it appears.
- **Whisker is listed under Accessibility but still does not work.** This usually follows a
  rebuild or reinstall from a differently signed copy. Remove the entry, or run
  `tccutil reset Accessibility io.github.mrashrhodes.whisker`, then open Whisker and allow it
  again.
- **A system action such as App Windows or a Space switch does nothing.** Whisker performs
  these with your keyboard shortcuts from **System Settings › Keyboard › Keyboard Shortcuts**.
  Turn the matching shortcut on there; Whisker shows a warning with an
  **Open Keyboard Shortcuts** button next to any action whose shortcut is off. Mission Control
  and Launchpad still open without their shortcut.
- **Back and forward do nothing in an app.** These send ⌘[ and ⌘]. Map the button to a different
  shortcut in a profile for that app.
- **A mouse's own settings are not used when another mouse is connected.** Click
  **Allow Input Monitoring…** under Devices so Whisker can tell the mice apart.
- **The pointer is suddenly too fast.** Wait a few seconds without confirming and Whisker reverts
  the change. Quitting Whisker also restores the original speed.
- **Trackpads and Magic Mouse** are left alone entirely: Whisker does not remap, reverse or change
  the speed of them.

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
- Auto-scroll, click lock and triple-click actions.
- Keyboard shortcut sequences and quick-switch pointer speed presets.
- Native per-device wheel speed and acceleration, and smooth scrolling for notched wheels.
- Support for extra buttons that macOS does not report, using publicly documented protocols.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and report security problems privately as described in [SECURITY.md](SECURITY.md).

## Licence

Whisker is released under the [MIT Licence](LICENSE).
