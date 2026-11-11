# Whisker website design

This identity applies to `site/`, not to the native macOS application.
Product and release facts belong to `PRODUCT.md` and the user guide.

## A working exhibition

The website is a full-colour exhibition poster that visitors can operate.
Candidate 7, contemporary exhibition identity; `diagonal-stage`;
concept seed `33b8bf2f`.

The first scene connects a compact brand, a short purpose, a build action,
a large physical mouse and the result of an actual profile selection.
There is no second, duplicate mouse diagram. It is an original illustration,
not a screenshot or a promise of hardware. Subsequent scenes change density:
an orchid scrolling installation, a quiet pointer playground, readable feature
links, a dark privacy passage and a green source-build finish.

## Visual language

- Spring green `#c1f17b` and orchid `#d7b8f3` occupy whole regions. Near-black
  `#20271e` anchors their type. Cool white `#fafbf7` gives reading room.
- Brand fields stay colourful in both system colour schemes. Reading surfaces
  adapt to dark mode; the guide remains quiet and legible.
- Anybody is the wide, heavy display voice; Atkinson Hyperlegible Next carries
  body copy and controls. Monospace appears only in actual commands/code.
- The original solid mouse uses broad coloured regions, dimensional edges and
  an offset result slip. Selected buttons are visibly filled, with equivalent
  native buttons for keyboard and touch.
- No drafting-paper grids, dimensions, fine-line diagrams, numbered sections,
  kicker headings, faux native windows or repeated feature cards.
- One visible mouse entrance; pointer replay is user-triggered. Motion never
  hides content, alters the system cursor or blocks a control. Reduced motion
  presents the same result without travel.

## Evidence behind the direction

Borrowed principles, not code, assets or compositions:

- Tangible oversized object, committed colour and direct feature demonstration:
  <https://play.date/>.
- Let visitors operate the product-world rather than inspect decoration:
  <https://poolsuite.net/>.
- Clear utility purpose, generous scale and one honest primary action:
  <https://handmirror.app/>.
- Filled physical form and readable feature isolation, not technical captions:
  <https://teenage.engineering/products/op-1>.
- Purposeful objects and varied information density:
  <https://op.al/>.

## Assets and licences

`site/fonts/anybody.woff2` is the Latin variable subset of Anybody by Tyler
Finck, weight 400–900 and width 100–150%. It is self-hosted under SIL OFL 1.1;
copyright and full licence are in `site/fonts/OFL-Anybody.txt`.

Source: <https://github.com/google/fonts/tree/main/ofl/anybody>.
The downloaded WOFF2 is
<https://fonts.gstatic.com/s/anybody/v13/VuJxdNvK2Ib2ppdWSKHdOQ.woff2>.
Atkinson's existing normal/italic WOFF2 files and OFL remain unchanged.
There are no runtime requests to a font service.

The site mouse, social image and website icon are original project artwork.
The website icon is not a claim that the native app icon has changed.
Regenerate the PNGs with Pillow and an original Anybody variable TTF:

```sh
python3 .github/scripts/render-site-artwork.py --font path/to/Anybody.ttf
```

The original TTF is available in the same licensed source directory above;
it is not needed or loaded by the website.

## Contracts and validation

Build from source remains primary until a signed release exists. Planned
features remain explicitly unshipped. Keep all guide anchors, relative Pages
URLs and nested-404 root-relative URLs. Keep strict self-only CSP, local
assets, font licences, no runtime network JS and the 250 KiB index/CSS/JS/font
budget. No update feed is checked into `site/`.

All controls remain native and labelled. Hidden controls stay hidden without
JavaScript. The guide has a skip link, landmarks, deep links and a scroll-aware
contents list. Single-column mobile layouts keep the controls and results in
reading order. Both system colour schemes, reduced motion and forced colours
have explicit styles.

```sh
node --check site/site.js
node --test .github/scripts/site.test.cjs
```

Browser verification additionally covers profile inheritance, button selection,
scroll reversal, pointer linear mode and Keep/Revert/timeout, no-JS, focus,
mobile overflow and the nested 404.
