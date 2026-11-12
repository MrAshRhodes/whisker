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
- **Actions.** Click, double-click or triple-click, press a keyboard shortcut (optionally
  repeating while the button is held), go back or forward, send a media key (play/pause, track,
  volume, mute or display brightness), open Mission Control, App Windows, Show Desktop,
  Launchpad or Notification Centre, move to the Space on the left or right, switch apps, scroll,
  open an app, file (by full path or a `~/` path) or web address, or do nothing at all.
- **Triple click.** One press sends three left clicks in a row at the pointer, with optional
  modifier keys, like Double Click. It is a mouse gesture, not a "select paragraph" command: what
  three clicks do is up to the app, and Whisker does not promise that any app responds to them.
  If something cuts a triple click short, such as a real click or scroll, a change of app or
  Whisker being switched off, Whisker sends no more clicks and does not retry, but clicks already
  sent cannot be taken back, so an app may see fewer than three. Not yet verified in TextEdit,
  Safari or any other app.
- **Wheel actions.** Turning the wheel runs its action once per burst of notches, or once for
  every notch if you choose **Repeat for every notch**. For Scroll Left and Scroll Right,
  **Also act on smooth scrolling from this mouse** adds an opt-in mode for sideways movement that
  arrives as smooth scrolling (for example a thumb wheel): the action runs once per sideways
  swipe, after a distance in pixels you choose, and any vertical scrolling at the same time
  carries on. It needs a mouse Whisker can identify exactly, ignores coasting and trackpads, and
  is not yet verified on hardware.
- **Scrolling.** Reverse the vertical or horizontal wheel for each mouse without changing the
  trackpad or the system's natural-scrolling setting. Each profile can set how many lines a
  wheel notch scrolls, add scroll acceleration, choose a modifier key that scrolls sideways and
  scroll faster or slower, from ×0.25 to ×8, while modifier keys you choose are held. The speed
  change applies to wheel notches, not trackpads or smooth scrolling, and is not yet verified on
  hardware. An opt-in native wheel speed and acceleration setting, per mouse, writes to the
  mouse's own driver settings instead; it is offered only when Whisker can read and restore the
  values, replaces Whisker's lines per notch and acceleration for that mouse, and is not yet
  verified on hardware.
- **Hold to Scroll (experimental).** Hold a button and roll the ball to scroll instead of moving
  the pointer, which stays where it was and does not jump when you let go. Choose the axes,
  speed and direction. It needs Input Monitoring, is not yet verified on hardware, and falls
  back to normal pointer movement when Whisker can't tell which mouse you're using.
- **Profiles.** Give an app, a mouse, or an app on one mouse its own buttons and scrolling.
  Anything a profile does not set comes from the profile it inherits from, ending at the
  default profile, and Whisker switches profiles as you change apps.
- **Application bypass.** List an app, such as a game, and Whisker stands aside while it is in
  front: no button remapping, wheel actions or scroll changes, and every mouse gets its own
  pointer speed and acceleration back from the system. Anything Whisker was holding is let go
  as the app comes forward, and your latest settings apply again when you switch away. Your
  profiles and the **Enabled** switch are not changed, bypass never turns Whisker on, and the
  menu bar menu shows "Bypassed for …" separately from **Enabled**. It covers every mouse, so it
  does not need Input Monitoring. See [Application bypass](#application-bypass).
- **Pointer speed and acceleration**, per mouse, where supported. If a change makes the pointer
  more than twice as fast, Whisker asks you to keep it and changes it back after a few seconds
  if you do not. The system's values come back when you turn a mouse's custom speed off, when
  you turn Whisker off, while an app on the bypass list is in front, when Whisker quits, or at
  the next launch if it did not quit cleanly. Turning Whisker back on reapplies your settings.
  If macOS will not take a mouse's values back, Whisker says so and keeps trying.
- **Devices.** Lists connected mice and trackballs, including ones you plug in or pair while
  Whisker is running. With several mice connected, allow Input Monitoring so Whisker can tell
  which one each click came from and apply that mouse's settings. Trackpads and touch mice such
  as Magic Mouse are listed but left alone. Open **Details** under any of them to see how Whisker
  identifies it, the buttons and wheels it reports and how sure Whisker is which clicks are its.
  See [Device details](#device-details).
- **Menu bar item** to turn Whisker on or off, see the active profile (or the app it is bypassed
  for) and open its settings. The icon can be hidden, and Whisker can open at login.
- **Settings file.** Everything is kept in one readable JSON file that you can export, import or
  reset. Whisker checks it when it starts and tells you about anything it had to fix. If an
  existing file can't be read, Whisker leaves it untouched and doesn't save changes until it is
  fixed, and tells you why.
- **Updates** through Sparkle for direct downloads, or through Homebrew (see
  [Install](#install)).

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel.
- The **Accessibility** permission. Whisker watches mouse button and scroll-wheel events so it
  can replace them with the actions you choose, and macOS only allows that for apps you have
  approved under Accessibility. Whisker does not read what you type.
- Optionally, **Input Monitoring**, only if you want different settings for several mice that
  are connected at the same time. With one mouse, Whisker does not need it, and opening a
  mouse's details never asks for it.

## Install

Install with [Homebrew](https://brew.sh):

```sh
brew install --cask mrashrhodes/tap/whisker
```

or download `Whisker-<version>.dmg` or `Whisker-<version>.zip` from the
[latest release](https://github.com/MrAshRhodes/whisker/releases/latest), check it against the
matching `.sha256` file as described in the release notes, and move **Whisker.app** to your
Applications folder. Releases are signed with Apple Developer ID and notarized by Apple.
Gatekeeper stays enabled; if macOS refuses to open the app, stop and report it rather than
bypassing the warning.

You can also [build Whisker from source](#build-from-source).

## First run

1. Open Whisker. Its icon appears in the menu bar and a **Welcome to Whisker** window explains
   why it needs Accessibility access.
2. Click **Open Accessibility Settings** and turn Whisker on in
   **System Settings › Privacy & Security › Accessibility**. Whisker notices the change within a
   second or so, with no need to relaunch.
3. Choose whether Whisker opens at login, click **Done**, then open **Settings…** from the menu
   bar menu and start assigning buttons.

If you choose **Continue Without Access**, Whisker stays in the menu bar with a dimmed icon and
keeps checking every second, so it starts remapping as soon as you allow it. Choose
**Grant Accessibility Access…** from its menu to see the instructions again. If you later remove
access, Whisker stops remapping straight away, lets go of any held buttons, and starts again when
access returns.

See the [user guide](https://mrashrhodes.github.io/whisker/guide.html) for each settings pane.

## Application bypass

Add an app under **Settings › Applications › Application Bypass**, or tick **Bypass Whisker in
this application** on an app profile, and Whisker stands aside while that app is in front. It
covers every mouse, and changes to the list apply straight away.

- **What stops.** Button remapping, wheel actions and scroll changes, so the app gets the mouse
  as macOS delivers it, and each mouse's own pointer speed and acceleration come back from the
  system. When you switch to another app your latest settings apply again; anything you edit in
  the meantime waits until then.
- **What does not change.** Your profiles and the **Enabled** switch stay as they are, and bypass
  never turns Whisker on: with Whisker off, it stays off. It works with or without Input
  Monitoring and does not change which permissions Whisker needs.
- **When the app comes forward.** Anything Whisker was holding, such as a button held down for a
  drag or a shortcut that repeats, is let go once, and the real release that follows is not
  passed on to an app that never saw the press.
- **When Whisker cannot tell which app is in front.** An app without a readable identifier
  changes nothing: Whisker stays out of the way if the app before it was bypassed, and keeps
  working if it was not, until an app it can identify comes forward. Sleep, switching users and
  quitting an app do not change this either.
- **If a mouse will not take its values back.** Whisker says so in the menu and in Settings,
  keeps the record of the original values and tries again, including the next time it starts.

Application bypass is not a raw-input mode. It only stops Whisker's own changes: it does not
configure Apple's Game Mode, make a game accept synthetic clicks or keys, or promise
compatibility with anti-cheat software. Games often start from a launcher, and whether the
launcher or the game's own program is in front while you play depends on the game. That has not
been verified for particular games, so add whichever app is in front while you play. Opening a
Whisker window brings Whisker to the front, which ends the bypass until you switch back.

## Device details

Open **Details** under a mouse in **Settings › Devices** to see what Whisker knows about it. It is
read-only: opening it changes no setting, does not ask for Input Monitoring and does not touch
the device. A mouse that is not connected shows only what its saved settings record.

- **Who it is.** The product name, the connection (such as USB or Bluetooth) and the vendor and
  product ids. Anything a device does not report says "Not reported", and a device without a name
  is listed by its ids.
- **Serial number.** Whether the mouse reports one. The number stays hidden until you choose
  **Show** and is hidden again when you close the details. Whisker already uses it as part of the
  mouse's identity in your settings, and saves nothing more.
- **Permission and attribution are separate.** **Input Monitoring** says whether Whisker can
  listen for button and wheel reports: Allowed, Not allowed, or Allowed but Whisker could not
  start listening. **Attribution** says how sure Whisker is which mouse a click came from:
  **Recent matching input** (that mouse sent a button press or wheel turn in the last minute),
  **Inferred from one eligible mouse** (it is the only mouse Whisker handles, so clicks are assumed
  to be its), **Ambiguous identity** (several connected devices look the same) or **Unknown**.
  It is evidence, not a guarantee, and a mouse can be allowed yet Unknown until you use it.
- **Reported controls.** The buttons and wheels the mouse reports to macOS, each listed once. It is
  not a count of physical buttons, and "None reported" or "Unavailable" never means there are
  none. Whisker reads controls once Input Monitoring is allowed and does not ask for it just to
  show them. This is not yet verified on hardware: in one test on macOS 26.6 with Input Monitoring
  off, macOS gave Whisker no controls for any of twelve built-in, USB and Bluetooth interfaces, so
  every mouse showed Unavailable. Other versions of macOS, other connections and what you see once
  Input Monitoring is allowed have not been tried.
- **Shared settings.** Mice with the same vendor and product ids and no serial number have the
  same identity, so they share one set of settings, and the details say how many connected
  devices share it. Whisker can only notice this when each device reports where it is connected:
  two such mice that do not are listed as one. A mouse that reports a serial number is kept apart
  from the others.
- **Left alone.** Trackpads and touch mice such as Magic Mouse are listed with the reason Whisker
  leaves them alone, and are not counted as a second mouse.
- **Privacy.** Whisker keeps only when each mouse last sent a button press or wheel turn, in memory,
  and treats it as recent for 60 seconds. It does not keep what was sent or a history, never
  saves, logs or sends it anywhere, and forgets it when the mouse is unplugged or Whisker quits.
  Details add nothing to the settings file.

## Privacy

Whisker works entirely on your Mac. It has no accounts, analytics or telemetry, and it makes no
network requests except update checks, which are off until you turn them on or choose
**Check for Updates…**. Your settings stay in
`~/Library/Application Support/Whisker/settings.json`.

## Updates

Direct downloads update in place with [Sparkle](https://sparkle-project.org). Choose
**Check for Updates…** from the menu bar menu, or pick a schedule under Updates in the settings
window. Automatic checks are off by default. Whisker asks before downloading and again before
installing. The update feed and every update archive must carry a valid Whisker update signature,
which Sparkle checks before unpacking the archive, and Sparkle also checks the new app's code
signature before installing it.

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
  and Launchpad use their shortcut when it is on, and otherwise open the app instead (Launchpad,
  or Apps on newer macOS).
- **Back and forward do nothing in an app.** These send ⌘[ and ⌘]. Map the button to a different
  shortcut in a profile for that app.
- **A mouse's own settings are not used when another mouse is connected.** Click
  **Allow Input Monitoring…** under Devices so Whisker can tell the mice apart, then open the
  mouse's **Details** to see how sure Whisker is which clicks are its.
- **Two mice share one set of settings.** They report the same vendor and product ids and no
  serial number, so Whisker cannot tell them apart. Their **Details** say so.
- **The pointer is suddenly too fast.** Wait a few seconds without confirming and Whisker reverts
  the change. Quitting Whisker also restores the original speed.
- **Whisker still changes my mouse in an app I have bypassed.** Bypass follows the app that is in
  front, which in a game may be its launcher or its own program; add the one that is in front
  while you play. Opening a Whisker window ends the bypass until you switch back. See
  [Application bypass](#application-bypass).
- **The menu says "Pointer settings couldn’t be restored…".** macOS refused to take Whisker's
  pointer speed or acceleration off a mouse, so it may still be in use. Whisker keeps the
  original values and tries again each time the app in front or your settings change, and the
  next time it starts.
- **Trackpads and touch mice such as Magic Mouse** are left alone entirely (shown as
  "Touch mouse — left alone" under Devices): Whisker does not remap, reverse or change
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
- Auto-scroll and click lock.
- Keyboard shortcut sequences and quick-switch pointer speed presets.
- Smooth scrolling for notched wheels.
- Support for extra buttons that macOS does not report, using publicly documented protocols.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and report security problems privately as described in [SECURITY.md](SECURITY.md).

## Licence

Whisker is released under the [MIT Licence](LICENSE).
