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
  open an app, file (by full path or a `~/` path) or web address, switch a mouse to one of its
  pointer speed presets, or do nothing at all.
- **Triple click.** One press sends three left clicks in a row at the pointer, with optional
  modifier keys, like Double Click. It is a mouse gesture, not a "select paragraph" command: what
  three clicks do is up to the app, and Whisker does not promise that any app responds to them.
  If something cuts a triple click short, such as a real click or scroll, a change of app or
  Whisker being switched off, Whisker sends no more clicks and does not retry, but clicks already
  sent cannot be taken back, so an app may see fewer than three. Not yet verified in TextEdit,
  Safari or any other app.
- **Keyboard shortcut sequence.** One press runs two to sixteen shortcuts in order, each with
  its own delay (0 to 2,000 ms, 10 seconds in total), such as ⌘A then ⌘C. It runs once per
  press and never overlaps: pressing the same mapping again cancels it, and any other mapping is
  ignored until it ends. Choose **Cancel Sequence** in the menu to stop it. It is also cancelled
  by a change of frontmost app (including leaving and returning), changed settings, Whisker being
  switched off, bypassed, asleep or quit, a lost Accessibility permission, or a tap reset. No key
  is left held down. Delivery is best-effort: Whisker checks the frontmost app before each step
  but an app can still change in the instant between the check and the keystroke, and a change of
  window within the same app is not detected. A step is refused, and the sequence stopped with a
  beep, if you are holding modifier keys the step does not include, or the step's own key. Not yet
  verified in any real app. Because settings now use schema 2, Whisker 0.1.0 will refuse files
  saved by this version.
- **Wheel actions.** Turning the wheel runs its action once per burst of notches, or once for
  every notch if you choose **Repeat for every notch**. For Scroll Left and Scroll Right,
  **Also act on smooth scrolling from this mouse** adds an opt-in mode for sideways movement that
  arrives as smooth scrolling (for example a thumb wheel): the action runs once per sideways
  swipe, after a distance in pixels you choose, and any vertical scrolling at the same time
  carries on. It needs a mouse Whisker can identify exactly, ignores coasting and trackpads, and
  is not yet verified on hardware.
- **Tilt-wheel controls.** **Identify tilt-wheel controls…** in Buttons asks you to tilt left,
  tilt right and press the wheel, previews what macOS actually reported and saves only what you
  confirm. A numbered button stays an ordinary button mapping with a normal press and release.
  A horizontal scroll report stays Scroll Left or Scroll Right, which also matches any other
  horizontal scrolling from the same mouse and runs once per tilt, never held. No event, smooth
  or coasting scrolling, fractions of a notch and mixed-axis input only get an explanation, never
  a guessed button number. The flow shows the mouse it believes you used and how sure it is, and
  attaches optional labels (such as "Wheel tilt left") only when that is exact; labels never
  change what a trigger matches. Not yet verified on hardware: see the checklist in the
  [guide](https://mrashrhodes.github.io/whisker/guide.html#tilt-wheel).
- **Scrolling.** Reverse the vertical or horizontal wheel for each mouse without changing the
  trackpad or the system's natural-scrolling setting. Each profile can set how many lines a
  wheel notch scrolls, add scroll acceleration, choose a modifier key that scrolls sideways and
  scroll faster or slower, from ×0.25 to ×8, while modifier keys you choose are held. The speed
  change applies to wheel notches, not trackpads or smooth scrolling, and is not yet verified on
  hardware. An opt-in native wheel speed and acceleration setting, per mouse, writes to the
  mouse's own driver settings instead; it is offered only when Whisker can read and restore the
  values, replaces Whisker's lines per notch and acceleration for that mouse, and is not yet
  verified on hardware.
- **Smooth notched scrolling (opt-in).** Spreads the distance a wheel notch already scrolls over
  a short time you choose, from 40 to 400 milliseconds, per profile. It adds no distance and no
  coasting, applies only to notches from a mouse Whisker can identify exactly, leaves trackpads,
  smooth-scrolling and touch mice alone, and switches itself off while Reduce Motion is on.
  It has not yet been verified in real applications, native or browser, and apps may treat the
  pixel scrolling it sends differently.
- **Hold to Scroll (experimental).** Hold a button and roll the ball to scroll instead of moving
  the pointer, which stays where it was and does not jump when you let go. Choose the axes
  (including Automatic Axis Lock, which picks vertical or horizontal from each hold's first
  movement, drops sideways drift and treats a diagonal as vertical; its threshold is
  provisional and not yet verified on thumb or finger trackballs), speed and direction. It needs Input Monitoring, is not yet verified on hardware, and falls
  back to normal pointer movement when Whisker can't tell which mouse you're using.
- **Button gestures (opt-in).** Turn on **Gestures** for a button in Buttons and give it up to
  five actions: one each for holding the button while you move the mouse up, down, left or
  right, and an optional **Tap** for letting go without having moved. The first movement that
  adds up to the distance you choose (60 units to start, from 20 to 400, counted in the movement
  macOS reports for the mouse) and runs mostly one way, at least twice as far along one axis as
  across it, picks the direction; a diagonal, or jitter that goes nowhere, picks nothing.
  Letting go runs the action once. The pointer keeps moving, but the app sees no click or drag
  from that button, and other buttons, other mappings and an unmodified primary click carry on
  as usual (a gesture on the primary button follows the same safeguard as any other mapping of
  it). Only actions that happen once can be chosen, so not Click, Hold to Scroll, Auto-scroll,
  Slow pointer while held, a shortcut sequence, a repeating shortcut or a pointer speed preset.
  It needs Input Monitoring and a mouse Whisker can identify exactly: only the mouse you pressed
  counts, and the button keeps its normal behaviour when Whisker can't tell which mouse that
  was. Changing app (even if you come straight back), losing the mouse, changing settings, and
  switching Whisker off, bypassing it, sleep or quitting all call a gesture off, and nothing
  runs. It works with buttons macOS reports as ordinary presses and releases. Whether a
  particular gesture button does, such as the one on the Logitech MX Master 3S, is not yet
  verified, no mouse is listed as supported, and a button macOS does not report is out of reach
  (support for those is [#25](https://github.com/MrAshRhodes/whisker/issues/25)). The distances
  and rules are provisional and not yet verified on hardware. See the
  [guide](https://mrashrhodes.github.io/whisker/guide.html#button-gestures).
- **Auto-scroll (experimental).** Press a button you choose to anchor the pointer, then let go:
  the window under that spot keeps scrolling, faster the further you move the pointer from it,
  down when the pointer is below the anchor and up when it is above (and sideways too, if you
  choose Both Directions). You set the dead zone and the top speed. Pressing the same button
  again, pressing any other mouse button (the click still goes through), turning the wheel or
  swiping a trackpad, or a change of app, profile, Space, display or connected mice stops it, and
  it never starts again by itself. There is no marker on screen: the menu bar icon changes and
  its tooltip says auto-scroll is on, even if you have hidden the icon. It needs no Input
  Monitoring of its own. The speeds are provisional, and it has not yet been verified on
  hardware, including in TextEdit, in nested scrolling in Safari (which pane receives the
  scrolling), across several displays or with mixed pointing devices. See the
  [guide](https://mrashrhodes.github.io/whisker/guide.html#auto-scroll).
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
- **Pointer speed presets.** Save a mouse's custom speed under a name, such as "Fast — ×1.5", and
  switch between that mouse's presets from Settings, the menu bar menu or a mouse button. A
  preset is a software speed, not the mouse's DPI, and is not yet verified on hardware. A switch
  to a much faster speed goes through the same keep-or-revert check as any other speed change.
  See [Pointer speed presets](#pointer-speed-presets).
- **Devices.** Lists connected mice and trackballs, including ones you plug in or pair while
  Whisker is running. With several mice connected, allow Input Monitoring so Whisker can tell
  which one each click came from and apply that mouse's settings. Trackpads and touch mice such
  as Magic Mouse are listed but left alone. Open **Details** under any of them to see how Whisker
  identifies it, the buttons and wheels it reports and how sure Whisker is which clicks are its.
  See [Device details](#device-details).
- **Duplicate clicks (advanced, off by default).** For one mouse and the buttons you choose,
  Whisker can ignore a press that follows the previous click within a very short time (20 to
  100 ms, 50 ms to start) and is let go just as quickly, dropping the press and its release
  together. The first click is never delayed; a press that might be a repeat is held for at most
  that interval, and a drag, a longer hold or other input lets it through in order. It needs a
  mouse Whisker can identify exactly, leaves the wheel and other mice alone, and a bare left
  click is only filtered while remapping the primary button is allowed. **Timing can't tell
  chatter from a deliberate fast double-click**, so one quicker than the interval is ignored
  too. This is different from the double-click speed in System Settings, which only changes how
  fast two clicks must be to count as a double-click. Turning it on starts a 60-second trial that
  switches it off unless you press **Keep**. It has not yet been verified on real faulty
  hardware or across apps (for example Finder double-clicks and text selection), and it does not
  diagnose or repair a mouse.
- **Swap primary and secondary buttons (per mouse, off by default).** For one mouse, under
  **Devices** or in that mouse's own profile in **Buttons**, the primary and secondary buttons
  trade places, always as a pair, for example for a left-handed set-up. Only plain presses swap:
  a click with ⌘, ⌥, ⌃ or ⇧ held, the other buttons, the wheel and other mice and trackpads are
  left alone, and a press keeps the button it began as until you let go. It needs **Allow
  remapping the primary button**, which Whisker never turns on for you, and Input Monitoring, so
  Whisker knows which mouse you pressed. A profile that maps the plain Primary Button or
  Secondary Button itself wins over the swap, and Whisker says when that happens. Turning it on
  starts a 60-second trial that switches it off unless you press **Keep** (or Return; Escape
  switches it off at once). The duplicate-click filter still looks at the button you pressed.
  How it combines with the secondary-click setting in System Settings has not yet been verified,
  apps that read the mouse directly may ignore the swap, and none of it, including the trial's
  keyboard and VoiceOver use, has been verified on hardware.
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
  system. Pointer speed presets cannot be switched while the app is in front. When you switch to
  another app your latest settings apply again; anything you edit in the meantime waits until then.
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

## Pointer speed presets

Name the speeds you use and switch between them without dragging a slider. Under
**Settings › Pointer**, turn on **Custom pointer speed** for a mouse, set the speed and choose
**Save Current Speed as Preset…**. Each mouse keeps its own list of up to 12 presets, shown as
"Fast — ×1.5", which you can rename or delete from the same pane. A custom speed that matches
none of them reads **Custom**.

- **Switching.** Pick a preset in **Settings › Pointer**, from that mouse's **Pointer Speed**
  submenu in the menu bar menu, or give a button the **Pointer Speed Preset** action under
  **Buttons** and choose the mouse and the preset. A preset sets the speed only: the mouse's
  acceleration and **Linear** setting stay as they are. Deleting a preset also removes the button
  mappings that switch to it, after asking.
- **Software speed, not DPI.** A preset is a multiplier on the movement the mouse reports. It does
  not change the mouse's own DPI, which only its maker's software can do.
- **Keep or revert.** A switch that makes the pointer more than twice as fast waits for you to
  keep it, like any big speed increase. In Settings press Return to **Keep** or Esc to
  **Revert**; in the menu choose **Keep Pointer Speed** or **Revert Pointer Speed**. With no
  answer it goes back by itself after 5 seconds. While one change is waiting, no other switch
  is accepted, for any mouse.
- **Recovery.** **Use System Settings**, in the Pointer pane, the menu and the waiting prompt,
  hands that mouse's speed straight back to the system. If macOS refuses a switch or takes only
  part of it, Whisker puts the previous speed back and tells you. If it cannot even do that, it
  keeps the original values and tries again, as it does for any other pointer change.
- **When it does nothing.** Presets are dormant while Whisker or the mouse is switched off, while
  **Custom pointer speed** is off for the mouse, while it is not connected (or is one of several
  identical mice Whisker cannot tell apart), and while the app in front is on the bypass list. The
  Pointer pane or menu says which. When a mouse reconnects, Whisker applies the last speed you
  kept, never one that was still waiting to be kept.
- **Not yet verified on hardware.** Presets have only been tested against a stand-in for the
  system's pointer settings, not against real mice. If Whisker is force-quit or crashes within
  the 5 seconds, the speed it was waiting on stays saved and applies at the next launch; use
  **Use System Settings** to drop it.

## Slow pointer while held

In **Settings › Buttons**, map a spare button to **Slow pointer while held** and choose a factor
from ×0.1 to ×0.9 (×0.5 initially). It slows only the mouse you press, not every mouse. It needs
Input Monitoring, exact device identification, a supported pointer service and an enabled
**Custom pointer speed** baseline for that mouse. Otherwise the button passes through normally.
Trackpads, touch mice and indistinguishable mice are not eligible. The primary-button safeguard
still applies.

The factor is a temporary overlay: acceleration and saved settings are unchanged. Overlapping
holds use the slowest factor, not their product; speed stays within the normal pointer bounds.
**Settings › Pointer** shows the temporary speed and baseline, explains unavailable states and
provides a keyboard-accessible **Cancel pointer slowdown** button. Release restores the latest
applicable baseline without asking you to confirm it again. After cancellation, let go before
pressing again.

A profile/settings or frontmost-app change, bypass, disconnection, paused event tap, sleep,
session switch, disabling Whisker or quitting cancels the hold. A reconnected mouse gets its
baseline, never a stale hold. If macOS refuses restoration, Whisker reports it and retains the
original values for recovery and retry.

This changes macOS pointer response, **not sensor DPI**. Repeated restoration on real hardware,
games and raw-input paths are **not yet verified**; no game or anti-cheat compatibility is claimed.
The action is additive without another schema change. Existing top-level unknown settings keys
are preserved; the codec still does not preserve unknown keys inside nested objects.

## Pointer orientation — foundation only

**Not available as a pointer setting.** The maintainer decision on rewriting pointer coordinates
is **pending** ([#32](https://github.com/MrAshRhodes/whisker/issues/32)). This work adds tested
rotation maths, fractional-count handling and confidence calculations for deliberately recorded
forward strokes, not a calibration wizard or usable global rotation. Confidence measures how
closely stroke directions agree; its thresholds are provisional, not verified on hardware.

The per-device JSON key `rotationDegrees` defaults to zero, rejects non-finite numbers and
normalises equivalent angles to −180° inclusive through 180° exclusive. It is dormant: editing
it does not rotate movement or drags, enable custom pointer speed, change a speed preset, reverse
a wheel or alter button identities. The primary-button guard is unchanged. Unknown top-level
settings still survive a round trip, but unknown nested keys do not; that part of #32 remains unmet.

Before any global control can be offered, a public-API prototype must demonstrate exact motion
attribution (never inferred from one listed mouse), coherent pointer and drag coordinates across
mixed-scale displays and edges, and keyboard cancellation, timeout, disable and interruption
recovery without jumps or drift. These checks and raw-input compatibility are **unverified**.
No hardware compatibility is claimed; repositioning the trackball remains the available workaround.

## Device details

Open **Details** under a mouse in **Settings › Devices** to see what Whisker knows about it. It is
read-only: opening it changes no setting, does not ask for Input Monitoring and never writes to
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
- **Battery (best effort).** Details has a **Battery** row, and a percentage also appears beside
  the mouse's name when there is one. Whisker only reads what the mouse itself declares through
  macOS's public HID interface, and only once Input Monitoring is allowed. It tries two sources:
  the standard Generic Device Controls *Battery Strength* element and the Battery System
  *Absolute State of Charge* element, and shows a percentage only when the element's range is
  exactly 0 to 100. Charging is shown only when the mouse declares an explicit charging flag,
  never guessed from USB or a rising level. Whisker never uses the Mac's own battery or a UPS,
  never writes to the mouse and never asks for a permission for this.
  - **Not supported**: the mouse declares no battery element.
  - **Waiting for a reading**: the mouse has one, and Whisker hasn't received a value yet.
  - **Unavailable — …**: Input Monitoring is off, macOS didn't describe the device, a read
    failed, the value was out of range, the battery is in a format Whisker doesn't recognise, or
    Whisker can't tell which device the battery belongs to (identical mice without serial numbers,
    a wireless receiver, or several battery elements). It never shows another mouse's reading.
  - **Stale — 80%, last read 10:42**: the last good reading is older than 15 minutes or a later
    read failed.
  - **Disconnected**: the mouse is not connected.
  - A percentage, optionally with "charging" or "not charging".

  Readings are refreshed when the mouse reports a new value, when you open Details and at most
  every ten minutes for a couple of hours after it connects. They stay in memory and are never
  saved. If the row says anything but a percentage, check the battery in the Bluetooth menu or
  Control Centre instead. **No mouse or receiver model has been verified yet**, including Magic
  Mouse (which Whisker leaves alone and whose battery macOS shows in its own menus), so do not
  expect a reading from any particular model.

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
- **Swapping the buttons does nothing.** The note under the switch says why. It is usually
  **Allow remapping the primary button** being off in General, Input Monitoring not being allowed,
  or a profile that maps the plain Primary Button or Secondary Button itself, which wins over the
  swap. Clicks with a modifier key held are never swapped.
- **Auto-scroll does not start, or scrolls the wrong thing.** Press its button once and let go.
  It does not start while Whisker is off, while the app in front is on the bypass list or during
  Hold to Scroll, and the profile in front must map the button to **Auto-scroll**. The scrolling
  goes to the window under the spot where you pressed, not under the pointer as it moves, so
  stop it and start again with the pointer over the pane you want. If it keeps stopping, a
  button press, the wheel or a mouse connecting or disconnecting is ending it, and it never
  starts again by itself. It has not yet been verified on hardware. See the
  [guide](https://mrashrhodes.github.io/whisker/guide.html#auto-scroll).
- **A mouse's own settings are not used when another mouse is connected.** Click
  **Allow Input Monitoring…** under Devices so Whisker can tell the mice apart, then open the
  mouse's **Details** to see how sure Whisker is which clicks are its.
- **Two mice share one set of settings.** They report the same vendor and product ids and no
  serial number, so Whisker cannot tell them apart. Their **Details** say so.
- **The pointer is suddenly too fast.** Wait a few seconds without confirming and Whisker reverts
  the change, or press Esc in Settings or choose **Revert Pointer Speed** in the menu. **Use
  System Settings** hands that mouse back to the system at once, and quitting Whisker also
  restores the original speed.
- **A pointer speed preset will not switch.** The preset is greyed out in the menu, or **Use** is
  greyed out in Settings › Pointer, and pointing at it says why: another speed change is waiting
  to be kept, Whisker or the mouse is switched off, **Custom pointer speed** is off for the
  mouse, the mouse is not connected, or the app in front is on the bypass list. If macOS refuses
  a switch, Whisker puts the previous speed back and says so in the Pointer pane. See
  [Pointer speed presets](#pointer-speed-presets).
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
  the speed of them. Decision: this stays the default, and there is no opt-in for Magic Mouse
  buttons. Whisker cannot yet tell a Magic Mouse's clicks from its touch gestures or from other
  mice, no model or macOS version has been verified, and its scrolling and gestures (swipe,
  smart zoom, Mission Control) must stay exactly as macOS has them. Evidence that would reverse
  it: hardware tests showing clicks reach Whisker as separate, exactly attributed events with
  gestures and scroll momentum unchanged. Use Apple's own Mouse settings for secondary click
  and gestures.

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
- Support for extra buttons that macOS does not report, using publicly documented protocols.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and report security problems privately as described in [SECURITY.md](SECURITY.md).

## Licence

Whisker is released under the [MIT Licence](LICENSE).
