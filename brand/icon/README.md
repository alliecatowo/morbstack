# The layered app icon

Two SVG layers, ready for Apple's Icon Composer pipeline.

    background.svg    the plate gradient, full-bleed, unmasked
    foreground.svg    the white orb-and-stack glyph, transparent elsewhere

Both are 1024×1024, which is the canvas Apple specifies, and both are vectors,
which Apple prefers.

## Why these are flatter than `brand/mark.svg`

`docs/design/tahoe/HIG-FINDINGS.md` §"App icon" records the requirement: layered
icons must be **unmasked**, with clearly defined edges, and must **not** bake in
specular highlights, drop shadows, bevels, blurs or glows — the system generates
those, per variant, and a baked one double-renders.

So relative to `brand/mark.svg`, these layers drop:

- the radial sheen (`IDENTITY.md` §1.3),
- the inner white rim (§1.3),
- the drop shadow (§1.3),
- the orb's lens gradient (§1.5) — an 8%-of-range form gradient is a second light
  source competing with the one the system will generate,
- the squircle itself. The background is a plain full-bleed rectangle; Icon
  Composer applies the mask.

Because the mask is applied for us, the 8.8% plate inset that
`mac/AppResources/make-icon.swift` draws by hand is also gone: the glyph geometry
in `foreground.svg` is `IDENTITY.md` §1 resolved against the **full canvas** rather
than against an inset plate.

Only the full-detail (three-slab) level exists here. Icon Composer renders every
size down from one 1024 source, so the two-slab compact level has no home in this
pipeline; `brand/mark-compact.svg` carries it for the favicon, which is the one
place something else picks the size.

## Importing

Icon Composer ships inside Xcode:
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`.

1. Open Icon Composer and create a new icon.
2. Drag `background.svg` in as the bottom layer, `foreground.svg` above it.
3. Leave the appearance variants (default, dark, clear light/dark, tinted
   light/dark) to be generated. The white-on-gradient mark survives all of them:
   white on `#2A1F9E` is 11.74 : 1 and white on `#7A3BE8` is 5.80 : 1.
4. Export the `.icon` next to this file.

`out/icon-background-1024.png` and `out/icon-foreground-1024.png` (produced by
`brand/render.sh`) are flat PNG equivalents for any tool that will not accept SVG.

## The `.icon` bundle is not checked in

Deliberately. Icon Composer's `.icon` format is authored by that app, and
hand-writing its internal JSON from guesswork would produce a file that looks
tracked and reviewable but is neither — it would drift from the SVGs with nothing
to catch it. The vectors above are the durable, diffable source; the `.icon` is a
five-minute export from them.

TODO(human): run the import above once and commit the exported `.icon`, if and when
the app bundle moves from the `iconutil`-based `.icns` pipeline
(`mise run app-icon`, `mac/AppResources/make-icon.swift`) to a layered icon. Until
then the `.icns` pipeline is what ships and these layers are staged work.
