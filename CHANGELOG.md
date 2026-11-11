# Changelog

All notable changes to Whisker are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
