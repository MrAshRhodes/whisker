# Contributing to Whisker

Thank you for helping. Whisker aims to stay small, predictable and native to macOS: it follows
Apple's Human Interface Guidelines, uses system fonts, colours and SF Symbols, and keeps
behaviour that can be tested out of the app shell.

Please report vulnerabilities privately using the [security policy](SECURITY.md), not in a
public issue.

## Requirements

- macOS 14 or later.
- Swift 5.9 or later, from either the Xcode Command Line Tools (`xcode-select --install`) or Xcode.
- Node.js 20 or later, only for the release tooling tests in `.github/scripts`.

## Build, run, test

```sh
make app      # assemble dist/Whisker.app for this Mac (CONFIG=debug for a debug build)
make run      # build and open it
make test     # run the Swift Testing suites, one test at a time
make install  # copy dist/Whisker.app to /Applications (INSTALL_DIR=... to change)
make help     # list every target
```

SwiftPM always runs through `Scripts/swiftw.sh`, which picks the right options for the installed
toolchain. You can call it directly, for example `Scripts/swiftw.sh build`.

### Command Line Tools only

Whisker builds without Xcode, with two differences that `Scripts/swiftw.sh` handles for you:

- SwiftPM's default build engine needs Xcode, so the wrapper passes `--build-system native`. The
  resulting deprecation warning can be ignored.
- Swift Testing ships with the Command Line Tools but is not on the default search paths, so the
  wrapper adds the framework and runtime search paths for `swift test`.

There is no XCTest, `xcodebuild` or asset catalog compiler. Tests use Swift Testing, the interface
is written in code, and the app icon is drawn by `Scripts/make_icon.swift` (`make icon`).

The wrapper reads `SWIFTW_MODE` (`auto`, `xcode` or `clt`, to override toolchain detection),
`SWIFTW_BUILD_SYSTEM` (always pass `--build-system <value>`) and `SWIFTW_VERBOSE=1` (print the
final command).

### Accessibility permission during development

macOS ties the Accessibility grant to the app's code signature. Local builds are signed ad-hoc,
so every rebuild looks like a new app and the old grant stops applying, even though Whisker may
still appear switched on in System Settings. Either remove and re-add it, or run:

```sh
tccutil reset Accessibility io.github.mrashrhodes.whisker
```

To keep the grant across rebuilds, set `WHISKER_SIGN_IDENTITY` to a code-signing identity of your
own. `make signing-cert` creates a self-signed **test** identity for this; never use it for
releases. Switching between your build and an installed release still needs a new grant.

## Project layout

```
Package.swift            WhiskerCore, Whisker and their test targets
Sources/WhiskerCore      Pure logic: settings model and validation, profile resolution,
                         trigger and action types, scroll and pointer maths, update policy
Sources/Whisker          App shell: event tap, device monitoring, menu bar item,
                         SwiftUI settings window, onboarding, login item, Sparkle updates
Tests/WhiskerCoreTests   Swift Testing suites for WhiskerCore
Tests/WhiskerAppTests    Swift Testing suites for the app shell
Resources/               Info.plist, entitlements and the generated app icon
Scripts/                 Build, packaging, signing and release scripts
packaging/               Signing policy and guide, Homebrew cask template
.github/                 CI, release and Pages workflows, their Node.js helpers and tests
site/                    Product site and user guide, published to GitHub Pages
docs/assets/             Images used by the README
```

`WhiskerCore` must not import AppKit, SwiftUI, IOKit or Sparkle. Anything that decides *what*
should happen (which profile applies, whether a mapping is valid, how many lines a notch scrolls)
belongs there with tests. `Whisker` only connects that logic to macOS: it reads events and
devices, posts events, and draws the interface.

## Tests

- `make test` runs every Swift suite. Add or update tests for any change in behaviour, mostly in
  `Tests/WhiskerCoreTests`.
- `node --test .github/scripts/*.test.cjs` runs the release tooling tests: changelog, issue-link
  policy, notarization gates and the update feed generator.
- Settings changes must keep older settings files loading. Unknown top-level keys are preserved,
  but unknown keys inside nested objects are not, so add new keys rather than renaming existing
  ones, and bump `schemaVersion` only with a migration and a test for it.
- Event-tap and device code cannot be fully tested in CI. Describe how you checked it by hand,
  including which mouse you used, in the pull request.

## Product site

`site/` is plain HTML and CSS with no build step, external fonts, scripts or trackers. Open
`site/index.html` in a browser to preview it. Pushing changes under `site/` to `main` publishes it
with `.github/workflows/pages.yml`, which also copies the latest stable release's `appcast.xml`
into the site root. Do not add an `appcast.xml` to `site/`, and keep the `guide.html#updates`,
`#permissions` and `#switching-installs` anchors: the app and release notes link to them.

## Changelog

Record notable user-visible changes under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md),
grouped under `### Added`, `### Changed`, `### Deprecated`, `### Removed`, `### Fixed` or
`### Security`. These entries become the release notes. Call out breaking changes and anything
users need to do.

CI runs `node .github/scripts/changelog.cjs check`, which fails if the first section is not
Unreleased, a release date is invalid, versions are out of order, or a reference such as `[#12]`
has no link definition at the bottom of the file.

## Pull requests

Every change to `main` needs an issue and a pull request, including documentation and workflow
changes.

1. Create or choose an issue in `MrAshRhodes/whisker` describing the change.
2. Branch from `main`, for example `feat/12-short-description`.
3. Open a pull request with `Fixes #12` (or `Closes`/`Resolves`) in its description, outside
   comments and code blocks. The **Issue link** check requires a real issue in this repository.
4. Run `make test` and `make app`, and the Node.js tests if you changed `.github/scripts`.
5. Update the changelog, resolve review conversations and wait for the **Build and test** and
   **Issue link** checks before merging.

Keep pull requests focused. Write code comments only where the reason is not obvious, and keep
user-facing text in plain British English that matches the rest of the app.

## Repository protections

Repository rulesets and the **release** environment enforce the workflow above. Nobody, including
administrators, can turn off the rules marked "no bypass".

- **`main` (no bypass):** changes arrive only through pull requests. Force pushes and deleting
  the branch are blocked. Review conversations must be resolved, and the **Build and test** and
  **Issue link** checks must pass on a branch that is up to date with `main`.
- **`main` review:** a pull request needs one approval. A new push dismisses earlier approvals,
  and the latest push must be approved by someone other than its author. Only the repository
  owner can merge, and the owner may merge their own pull request without an approval once the
  checks pass, for example with `gh pr merge --squash --admin`.
- **Release tags (no bypass):** `v*` tags cannot be moved or deleted once pushed, so a tag
  always names the commit its release was built from.
- **Release tag creation:** only the repository owner can create `v*` tags.
- **release environment:** only `v*` tags can deploy to it, and every run waits for the owner
  to approve the deployment. Administrators cannot skip the approval. Its signing credentials are
  environment secrets, so pull-request workflows never see them.

## Cutting a release

Releases are built, signed, notarized and published only by `.github/workflows/release.yml`.
Credentials live in the protected GitHub **release** environment; see the
[signing and notarization guide](packaging/signing/README.md). If a credential is missing, the
workflow stops rather than publish an un-notarized build.

1. On a branch from `main`, run `make prepare-release VERSION=X.Y.Z`. It moves the Unreleased
   changelog entries into a new `## [X.Y.Z] - YYYY-MM-DD` section dated today, updates the
   comparison links and writes `VERSION`. It refuses an empty Unreleased section, an existing
   version or a version older than the latest release. Review the result, open the usual
   issue-linked pull request, merge it and wait for CI.
2. Tag the merged commit and push the tag:

   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

   Do not create the GitHub release by hand. Only the repository owner can push `v*` tags.
   Approve the waiting **release** deployment in the workflow run on the Actions tab; nothing is
   built or signed until you do.
3. The release workflow checks that `CHANGELOG.md` at the tag has a section for the version and
   stops before building if not. To recover, fix the changelog and cut a new version: pushed tags
   are never moved or deleted.
   It also checks the Sparkle public key and requires a build number higher than the previous
   release's, so installed copies are offered the update.
4. It builds a universal app, signs it with Apple Developer ID and the hardened runtime,
   notarizes and staples the app and DMG, and verifies the app extracted from the ZIP. Missing
   credentials or a failed notarization stop the release; there is no unsigned fallback.
5. For stable releases it signs the final ZIP with the Sparkle EdDSA key and generates
   `appcast.xml`. It then publishes the GitHub release with the changelog section and
   `.github/release-notes-header.md` as notes, and attaches the ZIP, DMG, their `.sha256` files
   and, for stable releases, `appcast.xml`. It then runs the Pages workflow, which copies that
   `appcast.xml` to <https://mrashrhodes.github.io/whisker/appcast.xml>, the feed installed copies
   read.
6. If `TAP_GITHUB_TOKEN` is set in the release environment, the workflow updates the cask in
   `MrAshRhodes/homebrew-tap`. Otherwise run
   `Scripts/update_tap.sh --version X.Y.Z --from-release` once the release is published.
   `--dry-run` previews the change. The script never replaces a newer cask with an older one (for
   example when an old release's workflow run is repeated) unless you pass `--allow-downgrade`.

Tags containing `-` (for example `v0.2.0-beta.1`) are prereleases: they publish no update feed
and no tap update, and are never offered in-app. Preview release notes with
`node .github/scripts/changelog.cjs notes X.Y.Z`.

Published releases are immutable. The cask pins the ZIP's checksum and every build differs, so
the workflow never replaces assets of an existing release. To replace a broken release, cut a new
version.

`make zip` and `make dmg` build local packages in `dist/` for testing. They are not notarized and
must not be published.

## Licence

By contributing you agree that your contributions are licensed under the [MIT Licence](LICENSE).
