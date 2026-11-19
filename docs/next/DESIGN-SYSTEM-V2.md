<!--
SP Drive — Next Generation
File: docs/next/DESIGN-SYSTEM-V2.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# SP Drive design system v2

One token set for the three clients. This file is the contract; the macOS implementation is
`Components/Theme.swift` (`SPDTheme`). Web mirrors the names as CSS custom properties (`--spd-…`), iOS as the same
`SPDTheme` members. **Token names are the same everywhere; only the rendering technology changes.**

Status 2026-11-19: tokens implemented and used on macOS (phase 1). Not yet mirrored on web or iOS.

## 1. Principles

1. **Calm surfaces.** White canvas, one raised surface, one sunken well. No gradient backgrounds, no giant cards.
2. **Editorial type.** A serif (New York — `design: .serif`; web: `ui-serif, "New York", Georgia, serif`) for titles that
   name a place or a moment: empty states, sheet titles, sign-in. The system sans for everything you operate.
3. **One accent.** Violet `brand` is the only colour of controls, selection and progress. Indigo `brandIndigo` appears
   in the app mark only (the indigo → violet kinship with the web app, as a two-stop tile — nowhere else).
4. **Restrained translucency.** Material only where content really passes underneath: the command palette, the path
   and status bars (system `.bar`), the Desktop Drop Zone, badge capsules over thumbnails. Never as decoration.
5. **Meaning is never colour alone.** Every status colour ships with a symbol or a word (`SPDPill`).
6. **Motion explains, then gets out of the way.** Every animation is a named motion with a Reduce Motion form.

## 2. Colour roles

sRGB hex; `@n %` is the alpha. HC = *Increase contrast* (macOS `accessibilityHighContrast…`, web `prefers-contrast: more`).
For translucent roles the HC alpha is ×1.6 (capped at 100 %).

| Token (Swift `SPDTheme.…` / CSS `--spd-color-…`) | Light | Dark | HC light | HC dark | Usage |
|---|---|---|---|---|---|
| `brand` / `brand` | `#6D3DF2` | `#9882FF` | `#4F22C9` | `#B7A8FF` | Accent of controls, links, selection pill, progress, active symbols |
| `brandIndigo` / `brand-indigo` | `#4A55E0` | `#8E97FF` | `#2F39B8` | `#AEB5FF` | First stop of the app mark only |
| `brandWash` / `brand-wash` | `#6D3DF2 @10 %` | `#9882FF @18 %` | `#4F22C9 @16 %` | `#B7A8FF @29 %` | Valid drop targets, empty-state halo, quiet banners |
| `selection` / `selection` | `#6D3DF2 @16 %` | `#9882FF @30 %` | `#4F22C9 @26 %` | `#B7A8FF @48 %` | Background of a selected grid cell |
| `canvas` / `canvas` | `#FFFFFF` | `#1B1B1F` | `#FFFFFF` | `#000000` | Browser background |
| `surface` / `surface` | `#F6F6F9` | `#232328` | `#F2F2F6` | `#101013` | Inspector, sheets, hover of a row |
| `surfaceRaised` / `surface-raised` | `#FFFFFF` | `#2B2B31` | `#FFFFFF` | `#1A1A1E` | Cards (`spdCard`) |
| `sunken` / `sunken` | `#EEEEF3` | `#161619` | `#E6E6EC` | `#000000` | Wells behind previews |
| `hairline` / `hairline` | `#000000 @10 %` | `#FFFFFF @12 %` | `#000000 @16 %` | `#FFFFFF @19 %` | 1-px separators and card borders |
| `textPrimary` / `text-primary` | `#16161A` | `#F2F2F5` | `#000000` | `#FFFFFF` | Names, titles, values |
| `textSecondary` / `text-secondary` | `#5C5C66` | `#A6A6B0` | `#33333A` | `#D4D4DC` | Labels, descriptions |
| `textTertiary` / `text-tertiary` | `#8A8A94` | `#7C7C86` | `#55555E` | `#B0B0BA` | Captions, eyebrows, hints |
| `onBrand` / `on-brand` | `#FFFFFF` | `#14102B` | `#FFFFFF` | `#000000` | Text and symbols on a `brand` fill |
| `positive` / `positive` | `#1E8E5A` | `#4CC38A` | `#116B41` | `#7BE0AE` | Verified, up to date, connected |
| `warning` / `warning` | `#B76E00` | `#F0B454` | `#8A5200` | `#FFD084` | Conflict, offline, low battery, storage above 90 % |
| `critical` / `critical` | `#C8322B` | `#FF6B63` | `#9E1C16` | `#FF9A94` | Failed transfer, blocked by antivirus, session closed |

Not computed yet: WCAG contrast ratios of each pair (to be measured and added before delivery).

## 3. Type scale

macOS point sizes (fixed: macOS has no Dynamic Type). iOS maps each token to the text style in the last column and
lets Dynamic Type scale it; web uses `rem` with 13 px = 0.8125 rem as body.

| Token (`SPDTheme.Typo.…` / `--spd-type-…`) | Family | Size / weight | iOS text style | Usage |
|---|---|---|---|---|
| `display` | serif | 28 semibold | `.title` | Empty states, sign-in, lock screen |
| `title` | serif | 20 semibold | `.title3` | Sheet titles (conflict), inspector multi-selection |
| `headline` | sans | 15 semibold | `.headline` | Card titles, item name in the inspector |
| `body` | sans | 13 regular | `.body` | Rows, text |
| `bodyStrong` | sans | 13 medium | `.body` + medium | Current crumb, banner titles |
| `callout` | sans | 12 regular | `.callout` | Secondary lines, grid names |
| `caption` | sans | 11 regular | `.caption` | Sizes, dates, hints, pills |
| `eyebrow` | sans | 10 semibold, +0.6 tracking, uppercase | `.caption2` | Group labels ("SUR CE MAC") |
| `mono` | monospaced | 11 | `.caption` monospaced | SHA-256, version numbers |
| `figure` | rounded, tabular digits | 22 semibold | `.title2` rounded | Dashboard figures (speed, storage) |

## 4. Spacing, radii, sizes

| Token | Value (pt / px) | Usage |
|---|---|---|
| `Space.xxs` `xs` `sm` `md` `lg` `xl` `xxl` `xxxl` (`--spd-space-…`) | 2 · 4 · 8 · 12 · 16 · 24 · 32 · 48 | 4-pt grid; `lg` is the default padding of cards and panes |
| `Radius.xs` `sm` `md` `lg` `xl` (`--spd-radius-…`) | 4 · 6 · 10 · 14 · 20 | Continuous corners. `sm` rows and crumbs, `md` grid cells and tiles, `lg` cards and the palette, `xl` drop zone |
| `Size.gridCell` | 148 (steps 112 / 148 / 196) | Grid cell width |
| `Size.palette` | 620 | Command palette width |

## 5. Elevation

Shadow colour is black; in dark mode the opacity is ×1.7. A raised element always has a `hairline` border too.

| Token (`Elevation.…` / `--spd-elevation-…`) | Blur radius | Y offset | Opacity | Usage |
|---|---|---|---|---|
| `e0` | 0 | 0 | 0 | Flat: hairline only |
| `e1` | 3 | 1 | 7 % | Cards, thumbnails |
| `e2` | 24 | 8 | 16 % | Command palette, banners, popovers |
| `e3` | 40 | 16 | 24 % | Things in the hand: drop zone under a drag |

## 6. Motion

Durations: `instant` 0.10 s · `quick` 0.18 s · `standard` 0.28 s · `slow` 0.45 s.
Curves (cubic-bézier): `standard` (0.2, 0, 0, 1) · `enter` (0.05, 0.7, 0.1, 1) · `exit` (0.3, 0, 0.8, 0.15) ·
`springSnappy` (response 0.28, damping 0.86) · `springGentle` (response 0.45, damping 0.82).

| Motion (`SPDTheme.Motion.…` / `--spd-motion-…`) | Duration | Curve | Reduce Motion | Usage |
|---|---|---|---|---|
| `select` | instant | standard | none (state changes at once) | Selection, pressed states |
| `hover` | quick | standard | none | Hover wash, thumbnail arriving |
| `navigate` | standard | enter | 0.10 s fade | Entering / leaving a folder: the new place slides 18 pt from the side it comes from (deeper → from the right, back → from the left) |
| `reveal` | standard | springGentle | 0.10 s fade | Command palette, banners, lock screen |
| `dismiss` | quick | exit | 0.10 s fade | Closing the palette |
| `drop` | standard | springSnappy | none | A valid drop target answering a drag (scale 1.05–1.12, wash, border) |
| `progress` | 0.20 s | linear | same | Progress bars, storage meter |
| `ambient` | 1.35 s, repeats | ease-in-out | removed | Reserved for the sync mark; the system symbol pulse is also switched off |

Rules: views use `.spdMotion(_:value:)` (reads `accessibilityReduceMotion`), imperative code uses `spdAnimate(_:)`
(reads the system setting). The Quick Look zoom is the system's own; under Reduce Motion no source frame is given, so
the panel simply fades. Nothing loops except `ambient`.

## 7. Components built on the tokens (macOS)

`spdCard()` · `spdEyebrow()` · `spdElevation(_:)` · `SPDPill` (symbol + word status) · `SPDEmptyState` (halo symbol,
`display` title, message, real actions) · `QuotaBar` · `DropOverlay` · `ItemThumbnail` · `TransferSummary`.

## 8. Platform notes

- **macOS** keeps system chrome where the system does it better: sidebar list style, toolbar, `Table`, sheets.
  Tokens colour content, not chrome.
- **iOS / iPadOS** (to do by the iOS team): same names; `Typo` through text styles; `Size.gridCell` steps 104 / 128 / 168.
- **Web** (to do by the web team): `--spd-color-*` under `:root`, `[data-theme=dark]`, `@media (prefers-contrast: more)`;
  motions as `--spd-motion-<name>: <duration> <curve>` and `@media (prefers-reduced-motion: reduce)` mapping each to its
  reduced form from the table.
