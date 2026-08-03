# Morbstack brand assets

Everything here is original work by the Morbstack authors, licensed under the same
Apache License 2.0 as the rest of the repository. No third-party logo, icon set,
clip-art or font file is vendored, and none was used as a source. That is a
deliberate choice rather than an accident of taste: an Apache-2.0 project that
redistributes a mark it does not own has a licensing problem the moment someone
forks it.

The geometry is not invented here either. `docs/design/IDENTITY.md` §1 is the
specification — every coordinate, radius and colour below is that document's
plate-relative fraction resolved against a concrete canvas. If a file here and
`IDENTITY.md` ever disagree, `IDENTITY.md` wins.

## The mark

**More Orb, open Stack.** A solid orb resting on a stack of full-width slabs, with
the topmost slab passing *behind* the orb through a hard, gradient-coloured gap.
The gap is the single most important detail: it is what makes the drawing read as
two objects in depth rather than one blob, and it has a one-device-pixel floor so
it survives to 16×16.

## Files

### Vector sources (the source of truth — edit these)

| File | What it is |
| --- | --- |
| `mark.svg` | The mark on its plate, 1024×1024, full detail (three slabs), with the sheen, inner rim and lens gradient. The general-purpose logo. |
| `mark-compact.svg` | The compact detail level: **two** slabs, no sheen, no rim. For anything that will be seen at 32px or smaller. `IDENTITY.md` §1.4 explains why three slabs grey out down there. |
| `mark-template.svg` | Menu-bar template symbol: the glyph alone, no plate, pure black plus alpha, tight-cropped viewBox. |
| `wordmark.svg` | Mark plus the name. The type sets live in the system UI font — see "On the type" below. |
| `icon/background.svg` | Icon Composer background layer. Full-bleed gradient, unmasked, nothing baked in. |
| `icon/foreground.svg` | Icon Composer foreground layer. Flat white glyph, unmasked, transparent elsewhere. |

### Generated rasters (`out/` — do not edit, regenerate)

`out/` is checked in so that the website and the README work for someone who has not
installed a rasteriser. It is generated; treat it as build output that happens to be
tracked.

| File | Use |
| --- | --- |
| `out/mark-1024.png`, `-512`, `-256` | READMEs, slides, anywhere wanting a raster mark |
| `out/favicon-16.png`, `-32`, `-48` | Favicons (compact detail level) |
| `out/apple-touch-icon.png` | 180×180, iOS home screen |
| `out/MorbTemplate.png`, `@2x` | macOS menu-bar template image, 1× and 2× |
| `out/icon-background-1024.png`, `out/icon-foreground-1024.png` | Flat fallbacks of the Icon Composer layers |
| `out/og-image.png` | 1200×630 social card |
| `out/wordmark.png`, `out/wordmark-dark.png` | Fixed-pixel wordmark, dark ink and white ink |

### Scripts

| File | What it does |
| --- | --- |
| `render.sh` | Rasterises everything into `out/`. Run it after editing any SVG. |
| `make-raster.swift` | Draws the two assets that set type (the OG card, the wordmark PNGs). Called by `render.sh`; not usually run by hand. |

## Regenerating

```sh
brew install librsvg      # one-time; the only build-time dependency in this directory
brand/render.sh
```

`rsvg-convert` is confined to this directory on purpose. Nothing in the app, the
daemon, the guest or the website needs it, and the checked-in `out/` means nothing
downstream is blocked on installing it — you just cannot *regenerate* without it.

Two rasterisers are involved, for one reason: text.

- Pure geometry goes through `rsvg-convert`, which is exact and fast.
- Anything that **sets type** goes through `make-raster.swift`, because fontconfig on
  macOS has never heard of the system UI font. Ask `rsvg-convert` for "SF Pro Display"
  and it hands back Hiragino Sans without complaining. AppKit asks the OS properly.

## On the type

No font file is embedded or redistributed here, and the wordmark's letterforms are
not outlined. Both are licensing decisions:

- Outlining SF Pro into a redistributable Apache-2.0 asset is not clearly permitted
  by Apple's font licence.
- Vendoring a third-party open font to sidestep that would add a binary blob to a
  repository whose entire build story is "no dependencies, works offline".

So the wordmark sets **live**, in the system UI font: SF Pro on Apple platforms —
which is the correct face for a Mac-native product — and a reasonable grotesque
everywhere else. `wordmark.svg` therefore renders correctly in any browser and in
any macOS app, and renders in a substituted face under a headless rasteriser with no
system font stack. Where a fixed-pixel wordmark is needed (a GitHub README, which
renders on Linux; a slide; a conference programme), use `out/wordmark.png`, which is
produced on macOS through AppKit and therefore in the real face.

The website uses the same reasoning: a system font stack in CSS, no webfont, zero
external requests.

## The app icon, and how it differs from the mark

Three implementations of the same geometry exist, and the differences between them
are deliberate and documented rather than drift:

| Where | File | Difference from `mark.svg` |
| --- | --- | --- |
| The `.icns` | `mac/AppResources/make-icon.swift` | None. Same sheen, rim, shadow, lens gradient. |
| The in-app mark | `mac/Sources/MorbstackAppCore/Design/MorbBrand.swift` | Origin flip only: SwiftUI is top-left origin, so it stores `1 − v`. |
| The layered icon | `brand/icon/*.svg` | **No sheen, no inner rim, no drop shadow, no lens gradient, no squircle.** |

That last row is the one worth understanding. `docs/design/tahoe/HIG-FINDINGS.md`
records Apple's requirement for layered app icons: provide **unmasked** layers at
1024×1024, vectors preferred, and do **not** bake in specular highlights, drop
shadows, bevels, blurs or glows, because the system generates them. A baked
highlight double-renders against the generated one; a baked squircle fights the
mask the system applies. So the layered artwork is stripped back to two flat layers
and the system supplies the lighting.

`icon/README.md` has the import steps.

## Colour

From `docs/design/IDENTITY.md` §2.3. These are the only brand colours; there is no
third.

| Token | Light | Dark | Where |
| --- | --- | --- | --- |
| `brand` | `#4436D8` | `#8B84FF` | Identity, selection, focus, one primary action per screen |
| `brandDeep` | `#2A1F9E` | `#B3ADFF` | The plate gradient's origin; pressed states |
| `brandSecondary` | `#7A3BE8` | `#C58BF0` | The plate gradient's terminus. In the UI, **only** inside the gradient. |
| `accent` | `#4A41C7` | `#9A93FF` | Interactive content: a clickable port, a matched substring |

White on `#2A1F9E` is 11.74 : 1 and white on `#7A3BE8` is 5.80 : 1, so the white
glyph is legible against every point of the plate gradient.

## What the mark must never become

Repeated from `IDENTITY.md` §1.8 because this is where someone will come looking
before they change something:

No drop shadow inside the glyph. No outline around the orb. No gloss arc. No third
colour. No text inside the plate. No isometric perspective, no shear, no ragged
slab lengths — each of those was tried, rendered, looked at and rejected, and
`IDENTITY.md` §1.1b records why. No hierarchical SF Symbol rendition: it is a filled
two-tone shape and hierarchical rendering greys the stack.

## Verification

`IDENTITY.md` §1.7 is a six-point checklist for the mark (count two slabs at 16px;
stubs of the top slab visible on both sides at ≥64px; no dimple in the middle slab;
survives a greyscale and a 1-bit threshold; reads as a bright mass over stripes when
squinted to 4px). The SVGs here were rendered at 16, 32, 512 and 1024 and checked
against it. `docs/design/icon-reference.png` is the reference image;
whoever reimplements the mark should be able to reproduce it.
