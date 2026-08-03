# IDENTITY — brand-asset record and archived UI proposal

> **Scope split.** The mark geometry and asset-production guidance in §1 remain the
> source for `brand/` assets that cite this document. They do **not** authorize an
> in-app `MorbMark`, sidebar header treatment, or custom control. The in-app Theme,
> palette, spacing/radius, status-chip, card, toolbar, motion, row, and selection rules
> in §2 onward are archived historical material from the retired custom visual system.
> Product UI must follow the [native macOS playbook](NATIVE-MACOS-PLAYBOOK.md) and
> [HIG coverage audit](HIG-COVERAGE-AUDIT.md): system accent and semantic colors,
> standard controls, system surfaces, and no bespoke dashboard chrome.
>
> Brand colors may remain in exported artwork and marketing assets. They must not be
> repurposed to tint normal macOS chrome, selection, tables, toolbar actions, status
> chips, or content backgrounds.

Morbstack is **More Orb, open Stack**. The mark is an **orb** — a lens, a sphere, the one
machine that holds everything — **intersecting a stack** of layers. The character is a
systems tool: precise, dense, confident. Not playful. Nothing bounces. Nothing is cute.

Everything in this document is a number an implementer can type. Where a value is a
judgement call it says so.

---

## 1. THE MARK

### 1.1 Concept

A solid white **orb** resting on a **stack** of full-width slabs, with the topmost slab
passing *behind* it — so the slab is interrupted by a hard gradient-coloured gap and
resumes on the other side. The gap is what makes it read as two objects in depth rather
than one blob, and it is the single most important detail in the drawing.

Both halves of the name are load-bearing:

- The **orb** is a filled disc with a faint lens gradient — a sphere, not a ring. A ring
  at 16 pt is five alternating bands across seven pixels, which is why the current mark
  fails (see `CRITIQUE.md` §6).
- The **stack** is repetition plus a horizon: identical slabs, evenly pitched, running the
  full width of the plate. Full width matters — slabs of *ragged* length read as lines of
  text with an avatar above them, which is the trap the first draft of this fell into.
  Slabs of *narrowing* length read as a trophy. Equal and full-bleed reads as plates.

The composition is symmetric about the vertical centreline. Symmetry is what separates a
logo from a UI glyph.

### 1.1b Compositions that were tried and rejected

Rendered, looked at, and thrown away — recorded so nobody re-derives them:

| Composition | Why it failed |
| --- | --- |
| Orb upper-left, slabs staggered right with ragged ends | Reads as an avatar above three lines of text. Unmistakably a contact card. |
| Slabs narrowing as they rise, orb crowning them | Reads as a trophy, or an urn. |
| Orb centred with 2–3 slabs crossing it at intervals | A striped ball — exactly the failure of the current mark. |
| A slab crossing the orb's equator | A planet with a belt. Distinctive, but the two crescents left above and below vanish below 32 px. |
| Sheared stack (each slab shifted right as it rises) | The shear reads as a rendering skew, not as perspective, at anything under 128 px. |

### 1.2 Coordinate system

All geometry is a fraction of the **plate**, not the canvas. Origin bottom-left,
y increasing upward (CoreGraphics convention).

```
canvasSize                                        // pixels, square
inset       = canvasSize * 0.088                  // unchanged from the current file
plate       = CGRect(canvas).insetBy(dx: inset, dy: inset)
plateW      = plate.width                         // == plate.height
plateRadius = plateW * 0.235                      // squircle corner, unchanged
px(_ u:)    = plate.minX + u * plateW             // unit-x  → device x
py(_ v:)    = plate.minY + v * plateW             // unit-y  → device y
u(_ f:)     = f * plateW                          // unit length → device length
```

### 1.3 Plate

| Property | Value |
| --- | --- |
| Shape | rounded rect, corner radius `plateW * 0.235` |
| Gradient | linear, `#2A1F9E` at plate top-left → `#7A3BE8` at plate bottom-right |
| Sheen | radial white, `0.20 → 0.00` alpha, centre `(0.28, 0.82)`, radius `0.72` — **only when `canvasSize ≥ 64`** |
| Inner rim | stroke the plate path, `rgba(255,255,255,0.16)`, width `max(0.75, plateW * 0.006)` — **only when `canvasSize ≥ 32`** |
| Drop shadow | offset `(0, -canvasSize * 0.012)`, blur `canvasSize * 0.035`, `rgba(0,0,0,0.30)` — **only when `canvasSize ≥ 64`** |

The gradient endpoints are `Theme.brandDeep` (light) and a violet one stop past
`Theme.brandSecondary`. White on `#2A1F9E` is **11.74 : 1**; white on `#7A3BE8` is
**5.80 : 1**. The glyph is legible against every point of the gradient.

### 1.4 The stack

All slabs are **centred at `u = 0.500`** and **`0.860` wide** — `u ∈ [0.070, 0.930]`,
running nearly the full plate.

| Detail level | Condition | Slabs `n` | Height `h` | Pitch | Centres `v` |
| --- | --- | --- | --- | --- | --- |
| **full** | `canvasSize ≥ 64` | 3 | `0.105` | `0.170` | `0.155`, `0.325`, `0.495` |
| **compact** | `canvasSize < 64` | 2 | `0.150` | `0.285` | `0.185`, `0.470` |

Both occupy the band `v ≈ [0.10, 0.55]`, so the silhouette does not jump when the detail
level changes.

```
cornerR = min(h/2, 0.030) * plateW    // slabs, not pills — a pill reads as a button
fill    = pure white, alpha 1.0
```

**Why 3 → 2 and not 3 → 1.** At `canvasSize = 32` (which is `16@2x` and `32@1x`) the plate
is 26.4 px; a compact slab is `0.150 × 26.4 = 4.0 px` tall with a `3.6 px` gap. Two slabs
survive that. Three at full-detail proportions would be `2.8 px` slabs with `1.7 px` gaps
and would grey out. One slab stops reading as a stack at all.

At `canvasSize = 16` the plate is 13.2 px, slabs are `2.0 px` with a `1.8 px` gap, and the
orb is `6.2 px` across. That is the floor of what any mark can do at 16×16 @1×, and it is
the reason the `1 device pixel` gap floor in §1.6 exists.

### 1.5 The orb

| Property | Value |
| --- | --- |
| Centre | `(0.500, 0.650)` |
| Radius `R` | `0.235` |
| Fill | linear gradient, white `#FFFFFF` at the disc's top-left → `#EBEBEB` (92 % white) at its bottom-right |

The lens gradient is 8 % of range. At 1024 px it reads as volume; at 16 px it is
imperceptible and harmless. `#EBEBEB` against the violet end of the plate is **4.87 : 1**,
so even the darkest part of the orb clears body-text contrast against the brightest part of
the plate.

Bounds: `u ∈ [0.265, 0.735]`, `v ∈ [0.415, 0.885]`.

**The intersection, checked.** The orb overlaps **only the top slab**:

- Top slab spans `v ∈ [0.4425, 0.5475]`; the orb's underside reaches `v = 0.415`, so it
  covers the slab's full thickness at the centreline.
- At the slab's mid-height `v = 0.495`, the orb's half-chord is
  `√(0.235² − 0.155²) = 0.177`, and the halo's (see §1.6) is
  `√(0.263² − 0.155²) = 0.212`. So the gap in the slab spans `u ∈ [0.288, 0.712]`,
  leaving a **`0.218`-wide stub of slab visible on each side**. Those two stubs are what
  make the slab read as continuing *behind* the orb.
- The middle slab's top edge is `v = 0.3775`; the halo's underside is `v = 0.387`. Clear
  by `0.0095`, so the halo does not dimple it. This clearance is why `R` is `0.235` and
  not `0.240` — at `0.240` the halo cut a 91 px-wide, 5 px-deep notch into the middle
  slab at 1024, which reads as a rendering fault.

### 1.6 The gap (the important bit)

```
gap = max(1.0, plateW * 0.028)        // device pixels; the 1.0 floor is the whole point
```

Rendered by clipping, not by stroking, so there is no double-drawn edge:

```swift
// 1. plate: gradient, sheen, rim, shadow
// 2. slabs, clipped to everything OUTSIDE a disc of radius (R + gap)
context.saveGState()
context.addPath(plateShape)                                   // outer subpath
context.addEllipse(in: haloRect)                              // inner subpath, R + gap
context.clip(using: .evenOdd)                                 // → plate minus halo
for slab in slabs { context.addPath(slab); }
context.setFillColor(.white)
context.fillPath()
context.restoreGState()
// 3. the orb itself, radius R, lens gradient
```

`gap` at 1024 px is 23.6 px; at 32 px and 16 px it is exactly 1 px. Without the floor the
gap disappears below 36 px and the mark fuses into a lollipop.

The halo radius used in the §1.5 arithmetic is `R + gap = 0.235 + 0.028 = 0.263` at large
sizes.

### 1.7 Verification checklist for whoever implements this

1. Render 16, 32, 64, 128, 256, 512, 1024 and view all seven at 100 %, side by side, on
   both a white and a black desktop.
2. At 16 px you must be able to count **two** slabs and see the orb as a separate object
   sitting on them.
3. At ≥ 64 px, the top slab must show a visible stub on **both** sides of the orb. If one
   side is missing, the orb is off-centre.
4. The middle slab's top edge must be perfectly straight — no dimple where the halo passes
   near it.
5. Convert 1024 to greyscale and to a 1-bit threshold at 50 %. The silhouette must still
   read as a disc above stacked bars.
6. Squint until the image is 4 px wide. It should be a bright mass in the upper half over
   a striped darker mass — not a centred bullseye, and not a uniform blob.

This checklist was run against the geometry above before it was written down; all six
pass. The result is checked in as `docs/design/icon-reference.png` — the mark at 16, 32,
64, 128, 256 and 512, each nearest-neighbour upscaled to 128 pt on a neutral grey field so
the pixel grid is visible. **Whoever reimplements `make-icon.swift` should be able to
reproduce that image.** If they cannot, one of the two is wrong.

### 1.8 What the mark must never become

No drop shadow **inside** the glyph. No outline around the orb. No gloss arc. No third
colour. No text. No isometric perspective, no shear, and no ragged slab lengths — each of
those was tried and each broke the reading (§1.1b). No
`.symbolRenderingMode(.hierarchical)` rendition of this mark as an SF Symbol — it is a
filled two-tone shape and hierarchical rendering will grey the stack.

### 1.9 The in-app mark

`MorbMark` in `Design/MorbBrand.swift` draws the same geometry in SwiftUI, for the sidebar
header and the About box. `MorbMarkGeometry` in that file holds the same constants as the
table above; the CoreGraphics side (`make-icon.swift`) and the SwiftUI side must agree, and
`IDENTITY.md` is the tie-breaker.

Note the origin flip: `make-icon.swift` uses CoreGraphics' bottom-left origin and the `v`
values above are as written; `MorbMarkGeometry` stores `1 − v` because SwiftUI's origin is
top-left.

`MorbMark` is the **only** place the app draws the logo; nobody re-implements it.

---

## 2. COLOUR

### 2.1 Rules

1. **Semantic first.** If the OS has a colour for it (`.primary`, `.secondary`,
   `separatorColor`, `controlAccentColor`, `selectedContentBackgroundColor`), use the OS's.
   The tokens below exist only where the OS has no opinion.
2. **Every token is a light/dark pair**, built with `Color(light:dark:)` so it re-resolves
   live on appearance change.
3. **Status is colour AND symbol.** Never colour alone. Enforced by `StatusTone`.
4. **Brand is for identity and selection, not for data.** Port numbers stop being indigo.

### 2.2 Reference backgrounds used for every ratio below

| Surface | Light | Dark |
| --- | --- | --- |
| Content (`NSColor.textBackgroundColor`) | `#FFFFFF` | `#1E1E1E` |
| Sidebar material (measured, over a neutral desktop) | `#ECECEE` | `#232326` |
| Chip fill | token at **12 % alpha** over the surface | same |

12 % is not arbitrary: it is the highest alpha at which *every* token still clears 4.5 : 1
against its own chip in dark mode (`brand` is the binding constraint at 4.58 : 1).

### 2.3 Brand

| Token | Light | Dark | Light : white | Dark : `#1E1E1E` |
| --- | --- | --- | --- | --- |
| `Theme.brand` | `#4436D8` | `#8B84FF` | **7.59** | **5.43** |
| `Theme.brandDeep` | `#2A1F9E` | `#B3ADFF` | **11.74** | **8.21** |
| `Theme.brandSecondary` | `#7A3BE8` | `#C58BF0` | **5.80** | **6.61** |
| `Theme.accent` | `#4A41C7` | `#9A93FF` | **7.31** | **6.34** |

`brand` is identity: the mark, the sidebar selection rail, the focus ring, one primary
action per screen. `brandDeep` is the icon's gradient origin and the pressed state.
`brandSecondary` is the icon's gradient terminus and the second half of `brandGradient`;
it appears in the UI **only** inside the gradient. `accent` is interactive *content* —
a clickable port, a matched substring, a copy affordance — deliberately not
`Color.accentColor`, for the reasons already written into `Theme.swift`.

Where brand fills a shape and carries text: **white on `#4436D8` is 7.59 : 1**;
**black on `#8B84FF` is 6.84 : 1**.

Selection fill is `brand` at **16 %**: `#E1DFF9` light, `#2F2E42` dark. Primary label on
those is 15.6 : 1 and 12.8 : 1 respectively.

### 2.4 Status

Four hues. `busy` and `degraded` are deliberately adjacent — they are the same message
("attention, not broken") and are separated by symbol and motion, not by 25° of hue that
nobody can resolve in an 8 pt dot.

| Token | Light | Dark | L : white | L : sidebar | D : `#1E1E1E` | D : own chip | Symbol |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `statusRunning` | `#17703C` | `#3FD37E` | 6.14 | 5.21 | 8.60 | 6.80 | `circle.fill` |
| `statusBusy` | `#9A5200` | `#FF9F45` | 5.86 | 4.97 | 8.17 | 6.54 | `arrow.triangle.2.circlepath` |
| `statusDegraded` | `#7E6100` | `#EFC63F` | 5.84 | 4.95 | 10.18 | 7.81 | `exclamationmark.triangle.fill` |
| `statusPaused` | `#37568F` | `#87A9F5` | 7.27 | 6.16 | 7.16 | 5.76 | `pause.circle.fill` |
| `statusBad` | `#B3261E` | `#FF6B60` | 6.54 | 5.54 | 5.97 | 5.04 | `exclamationmark.octagon.fill` |
| `idle` | `.secondary` | `.secondary` | system | system | system | system | `circle` |

Every value clears **4.5 : 1** on every surface it is used on, at every text size, in both
appearances. The tightest is `statusDegraded` light on the sidebar material at 4.95 : 1.

Status dots are 8 pt — non-text UI, needs 3 : 1; all of the above clear it by ≥ 65 %.

### 2.5 Categorical series (charts only)

Five hues, hue-spaced and lightness-matched so a stacked bar reads as one chart rather
than five stickers. Order is the drawing order; adjacent pairs never share a hue family.

| Token | Light | Dark | L : white | D : `#1E1E1E` |
| --- | --- | --- | --- | --- |
| `seriesIndigo` | `#4B41C9` | `#8C85F2` | 7.24 | 5.36 |
| `seriesTeal` | `#0A6E75` | `#3FC7CE` | 6.00 | 8.15 |
| `seriesViolet` | `#8B3FBF` | `#C58BF0` | 5.90 | 6.61 |
| `seriesAmber` | `#9A6207` | `#F0AC42` | 5.09 | 8.48 |
| `seriesRose` | `#A62F63` | `#EE7EAC` | 6.55 | 6.52 |

`seriesAmber` light against the *sidebar* material is 4.32 : 1 — below the text floor.
Series colours are never drawn on the sidebar, so this is in-bounds; do not move them there.

**Reclaimable space is not a second texture.** Diagonal hatching is banned (see
`CRITIQUE.md` on `hero-disk-light`). Reclaimable is the same hue at **45 % opacity**,
which is a lightness step the eye reads instantly and which survives greyscale.

### 2.6 Surfaces and lines

| Token | Value |
| --- | --- |
| `Theme.contentBackground` | `Color(nsColor: .textBackgroundColor)` |
| `Theme.cardBackground` | `Color(nsColor: .controlBackgroundColor)` |
| `Theme.hairline` | `Color(nsColor: .separatorColor)` |
| `Theme.rowHover` | `Color.primary.opacity(0.055)` |
| `Theme.selectionFill` | `Theme.brand.opacity(0.16)` |
| `Theme.selectionRail` | `Theme.brand` — 3 pt, leading edge, `.capsule` |

### 2.7 What loses its colour

- **Port chips lose their indigo.** They become `.secondary` text on a `.quaternary` fill.
  Only a *published* port that opens a browser keeps `Theme.accent`, and only on its
  arrow-and-host half.
- **Sidebar selection gains the brand.** `Theme.selectionFill` + `Theme.selectionRail`.
- **The trash affordance stops being red-when-enabled.** It is `.secondary`, and turns
  `statusBad` only on hover or in a destructive confirmation.

---

## 3. TYPE

One family (SF Pro / SF Mono), seven roles, and a hard rule about digits.

### 3.1 The scale

| Role | SwiftUI | pt / weight | Where |
| --- | --- | --- | --- |
| `screenTitle` | `.largeTitle.weight(.bold)` — **but see below** | 26 / bold | *Deleted.* Screen titles move to `.navigationTitle`; the OS sizes them. |
| `sectionTitle` | `.title3.weight(.semibold)` | 15 / semibold | Card and stack headers |
| `rowTitle` | `.body.weight(.medium)` | 13 / medium | Container name, image repo, volume name |
| `rowDetail` | `.subheadline` | 11 / regular | The image:tag line under a row title |
| `label` | `.callout` | 12 / regular | Form labels, `LabeledContent` leading side |
| `caption` | `.caption` | 10 / regular | Column headers, footnotes |
| `overline` | `.caption2.weight(.semibold)` + `kerning(0.6)`, uppercased | 9 / semibold | `MorbSectionHeader` |
| `metricValue` | `.system(size: 22, weight: .semibold, design: .rounded)` | 22 / semibold | The one big number on a `MorbMetric` |
| `metricUnit` | `.caption.weight(.medium)` | 10 / medium | The `GB` after it |
| `mono` | `.system(.body, design: .monospaced)` | 13 | IDs, digests, paths, ports |
| `monoSmall` | `.system(.caption, design: .monospaced)` | 10 | Chips containing a number |
| `log` | `.system(size: 11.5, weight: .regular, design: .monospaced)` | 11.5 | The log viewport only |
| `logGutter` | `.system(size: 10, weight: .regular, design: .monospaced)` | 10 | Timestamps in the log gutter |

Seven ranks is already one more than most screens need. **If a screen uses more than five
of these, it is over-designed.**

### 3.2 Monospaced digits are mandatory, not optional

`.monospacedDigit()` **must** be applied to every number that can change without the user
asking. Non-exhaustively:

- CPU % and memory in the containers list and the menu-bar popover
- every value in Stats
- sizes and counts in Images, Volumes, Disk
- the line count in the logs toolbar
- badge counts in the sidebar
- uptime / age columns

Rule of thumb: **if it is right-aligned or it polls, it is monospaced-digit.** The current
build fails this on the containers list, the menu-bar popover and the disk legend, and you
can watch those rows twitch on a live engine.

Pair it with `.contentTransition(.numericText())` on anything that updates while visible
(macOS 13, no gate — see `SDK-LIQUID-GLASS.md` §2.10).

### 3.3 Log and code text

Log text is **not** body text with a different font. It is a different medium:

| Property | Log viewport | Everything else |
| --- | --- | --- |
| Font | `.system(size: 11.5, design: .monospaced)` | SF Pro |
| Line spacing | `2.0` pt, fixed | system |
| Colour | ANSI SGR palette, or `.primary` | semantic |
| Selection | full-width, text-selectable | row-based |
| Background | **flat `Theme.contentBackground`. Never a material. Never glass.** | per §5 |
| Gutter | `logGutter` at `.tertiary`, right-aligned, fixed 78 pt column, **suppressed on continuation lines** | n/a |

Inline code inside prose (settings help text, tooltips) uses `monoSmall` with a
`.quaternary` rounded-rect background at 4 pt radius — **not** literal backtick
characters, which are currently leaking into the Disk screen.

The ANSI palette is not restyled; it is the terminal's contract with the program that
wrote the bytes.

---

## 4. DENSITY

### 4.1 The spacing scale

Six values. **No literal spacing anywhere in the app that is not one of these.**

```
Theme.space1 =  2    // hairline separations inside a control
Theme.space2 =  4    // icon → its label
Theme.space3 =  8    // between related controls; chip padding.horizontal
Theme.space4 = 12    // between rows of a form; card internal padding
Theme.space5 = 16    // between cards
Theme.space6 = 24    // between major sections
Theme.pagePadding = 20   // detail-pane inset (kept — it is already the 20 everyone uses)
```

If a gap wants to be 10, it is 8. If it wants to be 14, it is 12. This is the rule that
turns "vibe coded" into "designed", and it costs nothing.

### 4.2 Row heights — the standard

| Class | Height | Used by |
| --- | --- | --- |
| `Theme.rowCompact` | **24 pt** | Menu-bar popover rows, palette results, form rows |
| `Theme.rowStandard` | **32 pt** | Every table row: Images, Volumes, Networks, Ports, Mounts, Env |
| `Theme.rowRich` | **44 pt** | Two-line list rows: Containers, Stacks services |
| `Theme.rowGroupHeader` | **28 pt** | A group header inside a list |

**`rowRich` is a fixed 44 pt regardless of content.** The containers row currently swells
to 100 pt when a container publishes three ports; ports move into a single truncating
trailing column with a `+2` overflow chip. A list you can count by eye is worth more than
a list that shows you every port without clicking.

Menu-bar popover at `rowCompact`: eight containers and six ports is
`8×24 + 6×24 + headers` ≈ **420 pt** instead of today's 775 pt.

### 4.3 Corner radii

| Token | Value | Used for |
| --- | --- | --- |
| `Theme.radiusChip` | 5 | chips, badges |
| `Theme.radiusControl` | 8 | buttons, fields, small tiles |
| `Theme.radiusCard` | 12 | `MorbCard`, inspector sections |
| `Theme.radiusPanel` | 16 | command palette, menu-bar popover |

All `.continuous`. Concentric rule: a chip inside a card is `radiusCard − padding`, which
at `12 − 8 = 4` rounds to `radiusChip = 5`. That is why the scale is what it is.

### 4.4 Other fixed metrics

| Token | Value |
| --- | --- |
| `Theme.dotSize` | 8 |
| `Theme.sidebarWidth` | 216 (min 180, max 280) |
| `Theme.inspectorWidth` | ideal 460 (min 380, max 640) |
| `Theme.hairlineWidth` | 1 / `displayScale`, floored at 0.5 |
| `Theme.minHitTarget` | 24 × 24 — every icon-only button gets `.frame(minWidth:minHeight:)` and a `.contentShape` |

The 24 pt hit target is a hard requirement. The Stacks screen currently ships 11 pt glyphs
with no padding.

---

## 5. MATERIALS — where Liquid Glass goes, and where it must not

Glass is a **chrome** material. It belongs on things that float over content. It does not
belong on content, and it categorically does not belong behind dense text.

### 5.1 Prescriptive table

| Surface | Treatment | Why |
| --- | --- | --- |
| **Window toolbar** | System default. `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`. Group items with `ToolbarSpacer(.fixed, placement:)`. Non-control items get `.sharedBackgroundVisibility(.hidden)`. | The OS supplies the glass. Do not draw your own. |
| **Sidebar** | System `.listStyle(.sidebar)` inside `NavigationSplitView`. **No extra material, no `glassEffect`.** | The split view already vibrancy-blurs it. Adding glass double-blurs and makes Morbstack visibly murkier than every other app on screen. |
| **Engine pill (sidebar footer)** | `.safeAreaBar(edge: .bottom)` on 26, `.safeAreaInset` below. `MorbGlass.bar()` → `.regular` glass on 26, `.thinMaterial` below. | Floating chrome over a scrolling list. |
| **Menu-bar popover** | `MorbGlass.panel(radius: 16)` → `.regular` glass on 26, `.regularMaterial` below. Container clipped to `radiusPanel`. | This is the one surface where opaque is objectively wrong. |
| **Command palette** | `.presentationBackground(.clear)` + `MorbGlass.panel(radius: 16)` on the palette's own root, over a `Color.black.opacity(0.18)` scrim. | `Glass` is not a `ShapeStyle`, so it cannot be passed to `presentationBackground` — verified. |
| **Inspector (container detail)** | System `.inspector`. No material of our own. | Same reasoning as the sidebar. |
| **Floating action clusters** (Stop / Restart / Pause / Remove) | `MorbGlass.cluster { … }` → `GlassEffectContainer(spacing: 8)` + `.buttonStyle(.glass)`, or `.bordered` below 26. | This is exactly what `GlassEffectContainer` is for. |
| **The one primary action per screen** (Start Engine, Pull) | `.buttonStyle(.glassProminent)` on 26, `.borderedProminent` below. | |
| **Cards (`MorbCard`)** | `Theme.cardBackground` + `Theme.hairline` border. **Never glass.** | A card is content, not chrome. Glass behind a data card is the "vibe coded" tell. |
| **Log viewport** | Flat `Theme.contentBackground`. **Never glass, never a material, at any size.** | 10 000 lines of monospaced text over a live-blurring backdrop is unreadable, and it re-composites the blur on every scroll tick. |
| **Tables** (Images, Volumes, Networks, Ports, Mounts, Env) | System `Table` + `.alternatingRowBackgrounds()`. **Never glass.** | Same. |
| **Charts** (Disk) | Flat fills on `contentBackground`. **Never glass.** | Translucency under a bar chart destroys the value encoding. |
| **Settings** | `Form(.formStyle(.grouped))` in the standard `Settings` scene. No custom panel, no Save/Revert footer. | |
| **Sheets and confirmations** | System. `.presentationBackground(.regularMaterial)` where a sheet floats over content. | |

### 5.2 The two rules, stated once

1. **Glass floats; content sits.** If the user scrolls it, it is content and it is opaque.
   If it hovers over the thing the user scrolls, it may be glass.
2. **Never put glass behind more than about 200 characters of text.** The menu-bar
   popover and the palette are at the limit. The log viewport is two orders of magnitude
   past it.

### 5.3 Scroll edge effects

| Surface | Style |
| --- | --- |
| Above a `Table` | `.scrollEdgeEffectStyle(.hard, for: .top)` |
| Above the log viewport | `.scrollEdgeEffectStyle(.hard, for: .top)` |
| Above prose / the Disk page | `.scrollEdgeEffectStyle(.soft, for: .top)` |
| Sidebar | system default |

All gated at macOS 26 via `MorbGlass.scrollEdge(_:for:)`.

---

## 6. MOTION

Restraint is the identity. A systems tool that bounces is a toy.

### 6.1 The four curves — and there are only four

| Token | Curve | Duration | For |
| --- | --- | --- | --- |
| `Theme.springSnappy` | `.spring(response: 0.22, dampingFraction: 0.86)` | ~220 ms | Direct response to a click: a disclosure, a tab change, a button's own state |
| `Theme.springSubtle` | `.spring(response: 0.32, dampingFraction: 0.90)` | ~320 ms | Layout that changes size: a row appearing, the inspector opening |
| `Theme.fade` | `.easeInOut(duration: 0.18)` | 180 ms | State that changes **without** the user asking: a poll result, a status flip |
| `Theme.glassMorph` | `.spring(response: 0.38, dampingFraction: 0.92)` | ~380 ms | `glassEffectID` / `glassEffectUnion` morphs only |

Damping went from `0.80`/`0.86` to `0.86`/`0.90`. At 0.80 a spring visibly overshoots; a
container list that overshoots when a container dies is flippant about the event.

### 6.2 What animates

| Thing | Animation |
| --- | --- |
| Sidebar selection rail | `springSnappy` on position |
| Inspector show/hide | system |
| A row entering or leaving a list | `springSubtle`, `.opacity.combined(with: .move(edge: .top))` |
| Status dot changing tone | `fade` on colour |
| A **busy** status dot | `.opacity` 1.0 ↔ 0.35, `easeInOut(0.9).repeatForever(autoreverses: true)` |
| A **busy** status *symbol* | `.symbolEffect(.rotate, isActive:)` (macOS 14, no gate) |
| A live number | `.contentTransition(.numericText())` + `fade` |
| Glass cluster merge/split | `Theme.glassMorph` + `.glassEffectTransition(.matchedGeometry)` |
| Toolbar item appearing | none — toolbars do not animate their own contents |

### 6.3 What never animates

Log lines arriving. Table row content. Chart bars on a poll refresh (only on first
appearance, and only `fade`). The window. The sidebar's width. Anything at all on a
`.task`-driven refresh that the user did not initiate — that is what `Theme.fade` at 180 ms
is for, and it is already at the threshold of "noticed".

### 6.4 Reduce Motion

Non-negotiable, and currently unimplemented anywhere in the app.

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

`Design/MorbMotion.swift` provides the single accessor everyone uses:

```swift
Theme.animation(.springSubtle, reduceMotion: reduceMotion)
```

which returns `Theme.fade` (a plain 180 ms cross-fade) for **every** spring when Reduce
Motion is on, and `nil` — no animation at all — for the repeating busy pulse and for the
glass morph. The `.symbolEffect(.rotate)` is suppressed with `.symbolEffectsRemoved()`.

**No feature file reads `accessibilityReduceMotion` and branches by hand.** Every
animation goes through `Theme.animation(_:reduceMotion:)` or through a `Design/`
component that already does.

### 6.5 Increase Contrast

`@Environment(\.colorSchemeContrast)`. When `.increased`:

- `Theme.hairline` → `Color.primary.opacity(0.35)` instead of `separatorColor`
- chip fills go from 12 % to 20 % alpha
- the selection rail widens from 3 pt to 4 pt
- `MorbGlass` degrades to `.regularMaterial` (glass has no increased-contrast variant we
  can rely on)

Handled centrally in `Design/MorbGlass.swift` and `Theme`, not per-screen.

---

## 7. THE ONE-PARAGRAPH SUMMARY

Indigo orb over violet, a real toolbar on every screen, glass only on things that float,
flat surfaces under everything you read, four status hues each with its own symbol, six
spacing values, four row heights, monospaced digits on anything that moves, and no spring
that overshoots. The identity is not decoration — it is the *consistency*. Ten screens that
share one row height and one spacing scale will look designed even before anyone notices
the colour.
