# Changelog

All notable changes to Whisker are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Identify tilt-wheel controls in Buttons: a guided, cancellable flow that previews whether a tilt (and the wheel press) arrives as a numbered button or as horizontal scrolling, and saves only what you confirm. Scrolling is never turned into a guessed button, a horizontal scroll mapping is explained as matching other horizontal scrolling from the same mouse, and optional per-mouse control labels are saved only for an exactly identified mouse and never change what a trigger matches. Not yet verified on hardware ([#23]).
- Best-effort wireless mouse battery status in Settings › Devices: a read-only percentage from the mouse's own standard HID battery element (0 to 100 only, with charging shown only when the mouse reports it explicitly), with Not supported, Waiting for a reading, Unavailable, Stale and Disconnected states. It is read once Input Monitoring is allowed, never from the Mac's battery or a UPS, never shown for an ambiguous device such as identical mice without serial numbers or a receiver, kept in memory only, and no mouse or receiver model has been verified yet ([#28]).
- Opt-in duplicate-click filter for one mouse and chosen buttons (Settings › Devices › Duplicate clicks): a press within 20 to 100 ms of the previous click's release that is let go just as quickly is dropped together with its release, while the first click is never delayed and a drag, long hold or other input lets a held press through in order. The wheel and other mice are never filtered, a bare left click stays exempt unless primary-button remapping is allowed, turning it on starts a 60-second trial that reverts unless kept, and a fast deliberate double-click can be ignored too. It has not yet been verified on faulty hardware or across apps ([#9]).
- Documented decision: Magic Mouse and other touch mice stay left alone, with no opt-in for their buttons, because clicks cannot yet be told apart from gestures or other mice and no model has been verified on hardware. Native gestures and scrolling are untouched, and a tested eligibility policy records what any future opt-in would need ([#29]).
- Smooth notched scrolling: an opt-in setting for each profile that spreads the distance a wheel notch already scrolls over 40 to 400 milliseconds. It adds no distance and no coasting, covers only notches from an exactly identified mouse, leaves trackpads, smooth-scrolling and touch mice alone, switches off while Reduce Motion is on, and drops anything pending when Whisker is switched off, the Mac sleeps, an app comes to the front or Hold to Scroll starts. It has not yet been verified in real applications ([#27]).
- Smooth sideways scrolling for Scroll Left and Scroll Right mappings: an opt-in mode that runs the action once per swipe from an exactly identified mouse, after an activation distance in pixels, while vertical scrolling carries on. Momentum, trackpads and unidentified input pass through, and it has not yet been verified on hardware, including thumb wheels ([#17]).
- Scroll faster or slower while holding modifier keys: choose the keys, a speed from ×0.25 to ×8 and the directions for each profile. It applies to wheel notches only, not trackpads or smooth scrolling, and has not yet been verified on hardware ([#16]).
- Native wheel speed and acceleration: an opt-in, per-mouse setting that changes the mouse's own wheel values, offered only when Whisker can read and restore them. It suspends Whisker's lines per notch and acceleration for that mouse, puts the original values back when switched off, on quit, in bypass and after a crash, and has not yet been verified on hardware ([#26]).
- Hold to Scroll (experimental): hold a button and roll the trackball to scroll instead of moving the pointer, with axes, speed and direction settings. It needs Input Monitoring, falls back to normal pointer movement when the mouse can't be identified, and has not yet been verified on hardware ([#31]).
- Automatic Axis Lock for Hold to Scroll: an opt-in choice next to the fixed and both-direction modes. Each hold starts undecided, picks vertical or horizontal from its first movement (a balanced diagonal counts as vertical), keeps the first movement on that axis once, drops sideways drift, and starts fresh at the next press. The threshold is provisional, not an ergonomic measurement, and neither it nor thumb versus finger trackballs has been verified on hardware ([#30]).
- Application bypass: while an app on your list is in front (a game, say), Whisker stands aside, with no button remapping, wheel actions, scroll changes or per-mouse pointer speed and acceleration. Anything held is released as the app comes forward, your latest settings return when you switch away, and profiles and the Enabled switch are left as they are. The menu shows "Bypassed for …", and a mouse that won't take its pointer settings back is reported and retried, including at the next launch. ([#12])
- Triple Click action: one press of a mouse button, or one burst of wheel turning, sends three left clicks at the pointer, with optional modifier keys like Double Click. It is a mouse gesture rather than a "select paragraph" command, because what three clicks do is up to the app, and a gesture that is cut short can reach an app as fewer than three clicks. It has not yet been verified in TextEdit, Safari or any other app ([#20]).
- Device details: every device under Settings › Devices has a read-only Details disclosure with its name, connection, vendor and product ids, whether it reports a serial number (shown only when you choose Show), the buttons and wheels it reports to macOS, and why Whisker leaves a device alone or treats several as one. Input Monitoring status is kept separate from how sure Whisker is which mouse a click came from. Nothing new is saved, and reported buttons and wheels are read only once Input Monitoring is allowed and have not yet been verified on hardware ([#10]).

- Keyboard Shortcut Sequence action: one press runs two to sixteen shortcuts in order, each with a delay of up to 2,000 ms (10 seconds in total). It never overlaps, the same mapping cancels it, and it is also cancelled from the menu, by a change of frontmost app, changed settings, Whisker being switched off, bypassed, asleep or quit, or lost permission. A step is refused if conflicting modifier keys are held. Delivery is best-effort, with a small race between the focus check and each keystroke, and it has not yet been verified in any real app. Settings move to schema 2, which Whisker 0.1.0 refuses to open ([#22]).

## [0.1.0] - 2026-11-12

### Added

- Menu bar app for configuring mouse buttons, scrolling and pointer speed.
- Remap any mouse button or wheel direction, with optional modifier keys, to clicks, keyboard shortcuts, Back/Forward, media keys, Mission Control, Spaces, app switching, scrolling or opening an app, file or website.
- Profiles per app and per mouse that inherit mappings from a parent profile.
- Scrolling controls: lines per notch, acceleration, per-mouse reversed direction and a modifier for horizontal scrolling.
- Per-mouse pointer speed and acceleration, restored when Whisker is turned off or quits, with a confirmation step after big changes.
- Button recorder, first-run Accessibility guide, open at login, and settings import, export and reset.
- Settings stored as versioned JSON that is checked and repaired on load (an unreadable file is left untouched and not overwritten); the primary button can't be remapped without a modifier unless allowed.
- Release workflow for signed and notarized builds with opt-in Sparkle in-app updates and a Homebrew cask.

[Unreleased]: https://github.com/MrAshRhodes/whisker/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MrAshRhodes/whisker/releases/tag/v0.1.0
[#9]: https://github.com/MrAshRhodes/whisker/issues/9
[#10]: https://github.com/MrAshRhodes/whisker/issues/10
[#12]: https://github.com/MrAshRhodes/whisker/issues/12
[#16]: https://github.com/MrAshRhodes/whisker/issues/16
[#17]: https://github.com/MrAshRhodes/whisker/issues/17
[#20]: https://github.com/MrAshRhodes/whisker/issues/20
[#22]: https://github.com/MrAshRhodes/whisker/issues/22
[#23]: https://github.com/MrAshRhodes/whisker/issues/23
[#26]: https://github.com/MrAshRhodes/whisker/issues/26
[#27]: https://github.com/MrAshRhodes/whisker/issues/27
[#28]: https://github.com/MrAshRhodes/whisker/issues/28
[#29]: https://github.com/MrAshRhodes/whisker/issues/29
[#30]: https://github.com/MrAshRhodes/whisker/issues/30
[#31]: https://github.com/MrAshRhodes/whisker/issues/31
