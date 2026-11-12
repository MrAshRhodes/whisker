# Changelog

All notable changes to Whisker are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Smooth sideways scrolling for Scroll Left and Scroll Right mappings: an opt-in mode that runs the action once per swipe from an exactly identified mouse, after an activation distance in pixels, while vertical scrolling carries on. Momentum, trackpads and unidentified input pass through, and it has not yet been verified on hardware, including thumb wheels ([#17]).
- Scroll faster or slower while holding modifier keys: choose the keys, a speed from ×0.25 to ×8 and the directions for each profile. It applies to wheel notches only, not trackpads or smooth scrolling, and has not yet been verified on hardware ([#16]).
- Native wheel speed and acceleration: an opt-in, per-mouse setting that changes the mouse's own wheel values, offered only when Whisker can read and restore them. It suspends Whisker's lines per notch and acceleration for that mouse, puts the original values back when switched off, on quit, in bypass and after a crash, and has not yet been verified on hardware ([#26]).
- Hold to Scroll (experimental): hold a button and roll the trackball to scroll instead of moving the pointer, with axes, speed and direction settings. It needs Input Monitoring, falls back to normal pointer movement when the mouse can't be identified, and has not yet been verified on hardware ([#31]).
- Application bypass: while an app on your list is in front (a game, say), Whisker stands aside, with no button remapping, wheel actions, scroll changes or per-mouse pointer speed and acceleration. Anything held is released as the app comes forward, your latest settings return when you switch away, and profiles and the Enabled switch are left as they are. The menu shows "Bypassed for …", and a mouse that won't take its pointer settings back is reported and retried, including at the next launch. ([#12])
- Triple Click action: one press of a mouse button, or one burst of wheel turning, sends three left clicks at the pointer, with optional modifier keys like Double Click. It is a mouse gesture rather than a "select paragraph" command, because what three clicks do is up to the app, and a gesture that is cut short can reach an app as fewer than three clicks. It has not yet been verified in TextEdit, Safari or any other app ([#20]).
- Device details: every device under Settings › Devices has a read-only Details disclosure with its name, connection, vendor and product ids, whether it reports a serial number (shown only when you choose Show), the buttons and wheels it reports to macOS, and why Whisker leaves a device alone or treats several as one. Input Monitoring status is kept separate from how sure Whisker is which mouse a click came from. Nothing new is saved, and reported buttons and wheels are read only once Input Monitoring is allowed and have not yet been verified on hardware ([#10]).

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
[#10]: https://github.com/MrAshRhodes/whisker/issues/10
[#12]: https://github.com/MrAshRhodes/whisker/issues/12
[#16]: https://github.com/MrAshRhodes/whisker/issues/16
[#17]: https://github.com/MrAshRhodes/whisker/issues/17
[#20]: https://github.com/MrAshRhodes/whisker/issues/20
[#26]: https://github.com/MrAshRhodes/whisker/issues/26
[#31]: https://github.com/MrAshRhodes/whisker/issues/31
