# IDENTITY — archived second-pass visual identity proposal

> **Archived — nonbinding.** The in-app palette, chip, status, material, radius, density,
> and motion prescriptions below belong to the retired custom visual system. They are
> retained only to preserve the historical design discussion; neither `Theme` nor a
> successor token/component library may reintroduce them. For current product UI, use
> the [native macOS playbook](../NATIVE-MACOS-PLAYBOOK.md) and
> [HIG coverage audit](../HIG-COVERAGE-AUDIT.md).

**Morbstack = "More Orb, open Stack."** The mark is a glass **orb** intersecting a **stack** of
slats, and the orb is a *lens*: where it crosses the stack, the layers are magnified apart. That is
the whole idea — an open tool that magnifies what OrbStack proved. It is also, literally, liquid
glass, which means the icon and the UI are made of the same material.

Tone: **precise, dense, confident.** A systems instrument. Never playful, never friendly, never
"delightful". No mascots, no rounded display type, no gradient-on-gradient, no illustration.

---

## 1. The mark

### 1.0 Canvas and body

Drawn programmatically for `.icns`. All numbers below are for a **1024 × 1024** canvas.

| | value |
|---|---|
| Canvas | 1024 × 1024 |
| Body (the rounded square) | **824 × 824**, origin (100, 100) — 100pt margin on all sides |
| Body corner radius | **185.4** (= 0.225 × 824), **continuous curvature** (superellipse), not a circular arc |
| Body drop shadow | offset y **+10**, blur **20**, `black @ 0.28`. Drawn by us for `.icns`. |

All geometry below is in **body-local** coordinates: origin at the body's top-left, `B = 824`,
body centre `(412, 412)`. Fractions of `B` are given so the drawing is resolution-independent.

> **Continuous corners matter.** A circular-arc rounded rect next to real macOS icons in the Dock
> reads as visibly wrong. Build the path from the Apple squircle: four cubic segments per corner,
> or use `NSBezierPath(roundedRect:xRadius:yRadius:)`'s continuous variant if hosting AppKit. Do
> not use `CGPath(roundedRect:cornerWidth:cornerHeight:)` — that is the circular one.

### 1.1 The stack — three slats

Three stadium (fully-rounded) rectangles, horizontally centred on `x = 412`.

| | absolute | fraction of B |
|---|---|---|
| Width | **560** | 0.6796 |
| Height | **96** | 0.1165 |
| Corner radius | **48** (= height / 2 → stadium) | 0.0583 |
| Vertical centres | **300, 412, 524** | 0.3641, 0.5, 0.6359 |
| Pitch | **112** | 0.1359 |
| Gap between slats | **16** | 0.0194 |
| x extent | 132 → 692 | |

Fill, top to bottom — a tonal ramp so the stack reads as lit from above:

| Slat | fill |
|---|---|
| Top | `#B3A6FF` |
| Middle | `#7C67F5` |
| Bottom | `#4A35D6` ← this is `brand.primary`, exactly |

Each slat gets a contact shadow: offset y **+3**, blur **9**, `black @ 0.28`. Contact shadows are
clipped OUT of the orb region (a lens does not cast the stack's shadow).

### 1.2 The orb — a lens, not a sticker

Circle, centre **(412, 412)**, radius **176** (0.2136 × B). Diameter 352.

- Vertical span 236 → 588. The stack's outer span is 252 → 572, so **the orb overhangs the stack
  by 16pt top and bottom.** That overhang is "more orb" and it is load-bearing: without it the orb
  looks contained by the stack instead of passing through it.
- Horizontal span 236 → 588, inset 104 from each slat end, so the slats clearly continue past it.

**Render order and the lens rule:**

1. Draw body + gradient.
2. Draw the three slats with their contact shadows.
3. `CGContextSaveGState`; clip to the orb circle.
4. **Redraw the same three slats, scaled vertically by 1.22 about y = 412.** Vertical-only, not
   radial — the point is "the layers spread apart", and a radial magnification muddies it.
   Resulting geometry inside the lens: height 117.1; centres at **275.4, 412, 548.6**. The top and
   bottom slats now overflow the circle and are clipped by it, which is correct lens behaviour.
   Fills, lightened ~12% L: top `#C7BEFF`, middle `#9787FF`, bottom `#6A57E8`.
5. Still clipped: bottom inner shade. Radial gradient centred **(412, 372)**, radius 176,
   `clear` at 0.55r → `#0E0B24 @ 0.34` at 1.0r.
6. `RestoreGState`.
7. **Rim.** Stroke the circle at **8pt**, with a linear gradient along the vertical:
   `white @ 0.90` at the top (y = 236) → `white @ 0.06` at the bottom (y = 588).
   Then a second inner rim — stroke at **3pt**, inset 5, `white @ 0.25`, only across the bottom
   140° arc. That is the caustic bounce and it is what makes the sphere read as glass rather than
   as a circle with a highlight.
8. **Speculars.**
   - Primary: ellipse centred **(360, 326)**, rx **92**, ry **50**, rotated **−20°**,
     `white @ 0.32`, Gaussian blur σ **16**.
   - Secondary: circle centred **(470, 500)**, r **20**, `white @ 0.14`, σ **10**.

### 1.3 Body gradient

Linear, top → bottom: `#2E2463` → `#12102B`.

Deep indigo-black. Not pure black (dead in the Dock), not saturated purple (toy). The brand indigo
lives in the *slats*, against a near-black field — that is the systems-tool register.

### 1.4 Size variants — these are different drawings, not scales

The three-slat lens does not survive downscaling. Each break below is drawn from scratch.

| Target | Slats | Orb r | Slat h | Slat w | Effects kept |
|---|---|---|---|---|---|
| **1024, 512, 256** | 3 | 0.2136·B | 0.1165·B | 0.6796·B | everything in §1.2 |
| **128** | 3 | 0.2136·B | 0.1165·B | 0.6796·B | lens, rim, primary specular. **Drop:** contact shadows, secondary specular, inner shade |
| **64** | **2** (y = 300, 524) | **0.24**·B | **0.13**·B | 0.6796·B | rim (2-stop, no gradient interpolation), lens magnification ×1.18, one hard-edged crescent specular. **No blur at all** |
| **32** | **2** | **0.28**·B | **0.15**·B | **0.72**·B | flat fills; rim = 1 stop `white @ 0.55` on the top arc only; specular = solid circle at (0.40B, 0.36B) r 0.05B `white @ 0.50` |
| **16** | **1** (y = 412) | **0.34**·B | **0.17**·B | **0.80**·B | body collapses to solid `#1A1638`; slat solid `#8B7BFF`; orb fill `#C7BEFF`; one 1px `white @ 0.7` arc top-left. No lens (invisible) — instead draw the slat **1.3× thicker inside the orb**, which at 16pt is one pixel and reads as the bulge |

Read test at 16pt: a light circle with a bar through it, on a dark rounded square. Distinct from a
box (Docker), a whale, a hexagon, and a gear at that size. That is the bar to clear.

### 1.5 Menu-bar icon — a separate asset

Do **not** downscale the app icon into the menu bar. The menu bar wants a template image.

- 18 × 18 @1x, 36 × 36 @2x, `NSImage.isTemplate = true`.
- Pure outline: circle, centre (9, 9), r **6**, stroke **1.5**. One horizontal bar through it,
  y = 9, from x = 1 to x = 17, stroke **1.5**, round caps. Bar is drawn, then a 2pt-wide gap is
  knocked out on each side where it meets the circle — so the circle reads as in front.
- Black at 100%. The system inverts and tints it. Never colour a template image.
- Engine state is **not** encoded in the icon shape. If state must show in the menu bar, use the
  system's own badge affordance or change nothing — a flickering menu-bar glyph is user-hostile.

### 1.6 Icon Composer — the alternative path

`Icon Composer.app` **is present** on this machine at
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app` (verified). That is the macOS 26
authoring tool for layered `.icon` documents, and it gives you the system's own material, shadow,
specular, and the dark / clear / tinted appearance variants for free — which is a better result
than hand-rolling §1.2, and a *much* better result at the small sizes.

**But:** the `.icon` document schema was not inspected and must not be hand-generated. Adopting it
is a build-system change (an asset catalogue and an Xcode-driven step), not a CoreGraphics change,
and it is out of scope for the three implementation agents. Ship the programmatic `.icns` per
§1.0–1.5 now; log Icon Composer as a follow-up.

---

## 2. Colour

Every value below was contrast-checked with `_contrast.py` in this directory. Ratios cited are
**measured**, against three real surfaces per mode. **No token in the semantic or series set falls
below 4.5:1 on any surface it is allowed on.**

Reference surfaces used:
- Light: content `#FFFFFF`, window `#ECECEC`, grouped `#F2F2F4`
- Dark: content `#1E1E1E`, window `#2A2A2C`, grouped `#262628`

### 2.1 Brand

| Token | Light | Dark | min ratio (L / D) |
|---|---|---|---|
| `brand.primary` | `#4A35D6` | `#9B8CFF` | 6.41 / 5.18 |
| `brand.chipFill` | `#EDEAFB` | `#2C2740` | — (fill) |
| `brand.onChip` | `#4A35D6` on `#EDEAFB` = **6.41** | `#9B8CFF` on `#2C2740` = **5.16** | |

`brand.primary` is the *only* legitimate use of indigo. Specifically it is **not** the link colour,
**not** the port-chip colour, and **not** chart series 1's semantic meaning (see §2.5 — series 1
shares the hex, but it is a different token and may be reassigned).

**Rule: purple means "Morbstack itself".** App icon, the prominent CTA, the sidebar selection tint,
the palette's selected row. Nothing else.

### 2.2 Semantic status — colour *and* shape

Six states. **Every one is distinguished by shape as well as colour**, so the set survives
deuteranopia, protanopia, and a monochrome screenshot. This is non-negotiable: `degraded` and
`error` are both warm reds and are *only* separable by shape.

| State | Light | Dark | Ratio (L / D) | **Shape** (7pt box) |
|---|---|---|---|---|
| `running` | `#17703A` | `#4CD46A` | 5.20 / 7.46 | ● filled disc, r 3.5 |
| `paused` | `#8A5A00` | `#F0B840` | 5.02 / 7.94 | ▮▮ two vertical bars, 2 × 6, gap 2 |
| `degraded` (unhealthy, restarting) | `#B03A0E` | `#FF8A5B` | 5.14 / 6.17 | ◎ **ring** — 1.75pt stroke, hollow centre |
| `error` (failed, exited non-zero) | `#B3261E` | `#FF7A72` | 5.53 / 5.65 | ✕ filled disc with a 1.5pt white diagonal knocked out |
| `stopped` (exited 0) | `#66666B` | `#98989F` | 4.83 / 5.00 | ○ hollow, 1.25pt stroke |
| `unknown` / `creating` | `#66666B` | `#98989F` | 4.83 / 5.00 | ◌ dashed ring, 1.25pt, 4 dashes |

Tinted chip fills for each (background / measured foreground-on-background):

| State | Light fill | ratio | Dark fill | ratio |
|---|---|---|---|---|
| running | `#E4F3E9` | 5.36 | `#17321F` | 7.23 |
| paused | `#F7EEDC` | 5.14 | `#332715` | 8.07 |
| degraded | `#FCEBE4` | 5.25 | `#3A2318` | 6.31 |
| error | `#FBE9E7` | 5.58 | `#3A2020` | 5.88 |
| stopped | `#EDEDEF` | 4.88 | `#2C2C2E` | 4.86 |

### 2.3 Text

| Token | Light | Dark | min ratio |
|---|---|---|---|
| `text.primary` | `#1D1D1F` | `#F2F2F4` | 14.25 / 12.81 |
| `text.secondary` | `#5B5B60` | `#A8A8AE` | 5.72 / 6.06 |
| `text.tertiary` | `#67676D` | `#9A9AA0` | 4.76 / 5.12 |

**There is no `text.quaternary`.** Three levels. The current app's near-invisible fourth level (the
VM disk path, the engine-stopped footer) is deleted, not dimmed further. If content does not
deserve 4.5:1 it does not deserve to be on screen.

The log gutter is the single exception and it earns it structurally, not chromatically: gutter
timestamps use `text.tertiary` at the same size but are separated by an 8pt rule and a background
step, not by being faint.

### 2.4 Structural

| Token | Light | Dark |
|---|---|---|
| `surface.window` | `NSColor.windowBackgroundColor` | same |
| `surface.content` | `#FFFFFF` | `#1E1E1E` |
| `surface.grouped` | `#F2F2F4` | `#262628` |
| `surface.log` | `#FFFFFF` | `#141416` (darker than content — the log is its own place) |
| `separator` | `NSColor.separatorColor` | same |
| `selection.focused` | `brand.primary @ 0.16` | `brand.primary @ 0.22` |
| `selection.unfocused` | `#00000 @ 0.06` | `#FFFFFF @ 0.07` |
| `link` | **use `brand.primary`** | **use `brand.primary`** |

**The blue `Open` links in the Ports table are deleted.** One accent. A link is identified by being
a `Button(role: .none)` with `.buttonStyle(.link)` behaviour and an `arrow.up.forward.square`
glyph, not by being a second brand colour.

### 2.5 Categorical series — charts, the Disk bar

Six hues at near-equal perceived lightness, chosen for maximum separation on the
deuteranope-safe axis. **Every one clears 4.5:1 on every surface**, so a series colour may carry a
label, not just a swatch.

| # | Name | Light | Dark | min ratio (L / D) |
|---|---|---|---|---|
| 1 | Indigo | `#4A35D6` | `#9B8CFF` | 6.41 / 5.18 |
| 2 | Teal | `#00706B` | `#35C8BF` | 5.04 / 6.93 |
| 3 | Amber | `#8A5A00` | `#E5A72E` | 5.02 / 6.75 |
| 4 | Magenta | `#A0247C` | `#F07BC8` | 5.85 / 5.71 |
| 5 | Slate blue | `#2E5FA3` | `#6FA8F0` | 5.42 / 5.82 |
| 6 | Olive | `#56630F` | `#B4C44A` | 5.58 / 7.46 |

**Violet is removed from the series.** `REPORT.md` records the current set as
indigo / teal / violet / amber. Indigo and violet are ~40° apart and collapse into one colour for a
deuteranope — the Disk bar currently has two segments a colourblind user cannot separate. Magenta
replaces violet.

**Disk stacked-bar assignment** (Images / Containers / Volumes / Build cache):
**1 Indigo → 3 Amber → 2 Teal → 4 Magenta.** No two adjacent segments share a hue family.

The hatched "reclaimable" overlay stays, but as **vector** diagonal strokes at 45°, 2pt wide, 6pt
pitch, in `white @ 0.30` (dark) / `black @ 0.22` (light) — not a raster pattern. The current one
will alias at fractional scales.

### 2.6 What the colour system forbids

- `Color.accentColor` / `NSColor.controlAccentColor` for **content**. It is the user's system
  accent and belongs to AppKit's own controls (checkboxes, focus rings, default buttons) and to
  nothing we draw. `REPORT.md` already found this the hard way; the rule is now written down.
- Any hex literal outside this file. If a screen needs a colour that isn't here, the answer is
  that the screen is wrong, or this file gets an addition — reviewed.
- Red as decoration. `error` is for states, and for exactly one destructive control at a time.
  Eighteen red trash cans in a table column (CRITIQUE §10) is the anti-pattern.
- Colour as the sole carrier of any status. See §2.2.

---

## 3. Typography

System font (SF Pro) throughout. **Six sizes exist. Nothing else is permitted.**

| Role | Font | Colour | Where |
|---|---|---|---|
| `metric` | `.system(size: 28, weight: .semibold).monospacedDigit()` | primary | the one hero number per screen ("25.15 GB"). Max one per screen. |
| `title` | `.system(size: 17, weight: .semibold)` | primary | **only** in `ContentUnavailableView` titles and the Settings window. Screen titles are drawn by the toolbar — we do not set them. |
| `control` | `.system(size: 13)` | — | never set explicitly; let controls size themselves |
| `rowPrimary` | `.system(size: 13, weight: .medium)` | primary | container name, image repo, service name |
| `rowSecondary` | `.system(size: 11)` | secondary | image:tag, subtitles |
| `meta` | `.system(size: 11)` | tertiary | elapsed time, counts, captions |
| `sectionHeader` | `.system(size: 11, weight: .semibold)` | secondary | section titles |
| `numeric` | `.system(size: 11).monospacedDigit()` | primary / secondary | **every** figure in a scannable column |
| `code` | `.system(size: 11, design: .monospaced)` | primary | ids, digests, paths, ports, env values |
| `log` | `.system(size: 11, design: .monospaced)`, line box **15pt** | primary | log body |
| `logGutter` | `.system(size: 10, design: .monospaced)` | tertiary | timestamps |
| `axis` | `.system(size: 10).monospacedDigit()` | tertiary | chart axis labels only |

Sizes in the scale: **28, 17, 13, 11, 10.** (`control` is 13 by system default.)

### 3.1 Section headers are sentence case

`STATE` → **State**. `CONFIGURATION` → **Configuration**. `PUBLISHED PORTS` → **Published ports**.

All-caps + letter-spacing micro-headers are the single clearest dashboard-framework tell in the
screenshots, and they appear on every screen. 11pt semibold secondary, sentence case, **no
tracking, no leading glyph.** The six decorative glyphs currently prefixing the detail-pane headers
(gear, plug, card, disc…) are deleted — their only job was to say "this is a heading", which the
heading already does.

### 3.2 Numerics

**Rule: if a number appears in a column that a user scans vertically, it is
`.monospacedDigit()` and `.trailing`-aligned. No exceptions.**

Currently violated by: menu-bar CPU percentages (`25.9%` / `6.1%` do not align), container-row CPU
and memory, table Size columns, the Disk legend percentages.

Units are `text.secondary` at the same size, separated by a hair space — `421.5` primary, `MB`
secondary. Never bold a unit.

### 3.3 Code and logs

- Monospaced at 11pt for anything the user might copy or diff: image IDs, digests, paths, ports,
  commands, env values, inspect output.
- **Truncate digests to 12 characters** with the full value on hover and in the copy action. The
  64-character `sha256:` line in the Overview (`REPORT.md` known-gap #5) is replaced by
  `sha256:9879af2cbf81` + a copy button. Accuracy is preserved by the copy, not by the display.
- Log line box is **15pt** for an 11pt monospaced face (≈1.35). Do not let the log inherit a
  general line-spacing token; it is its own thing.
- **Never render markdown syntax.** The backticks in the Disk screen's VM-image prose are on
  screen as characters (CRITIQUE §5). Prose is prose; code is `code` styling. Every UI string ships
  through a review that catches this.

---

## 4. Materials and depth

### 4.1 Where Liquid Glass goes — and how

| Surface | Treatment | How |
|---|---|---|
| **Sidebar** | System sidebar material | Use a real `NavigationSplitView` sidebar column + `.listStyle(.sidebar)`. **Do NOT call `.glassEffect` on it.** On macOS 26 the sidebar column is already glass; adding our own double-blurs and costs a pass for nothing. The current opaque slab is wrong because the *structure* is wrong, not because a modifier is missing. |
| **Toolbar** | Automatic glass | Just use `.toolbar { }`. macOS 26 wraps toolbar items in glass capsules for free. Group with `ToolbarSpacer`. Never hand-roll a toolbar. |
| **Command palette** | **Explicit glass — spend it here** | `GlassEffectContainer(spacing: 12)` around field + list; `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))`; `.glassEffectTransition(.materialize)`. Over a `Color.black.opacity(0.28)` scrim. Result rows are **not** individually glassed. |
| **Menu-bar popover** | Popover chrome + one glass header | `MenuBarExtra(style: .window)`. The engine-state header may take `.glassEffect(.regular, in: .rect(cornerRadius: 10))`. Body rows: no glass. |
| **Floating log chrome** | Glass capsules | The "Follow" pill and the "N new lines ↓" pill: `.glassEffect(.regular, in: .capsule)` inside one `GlassEffectContainer`, morphing via `glassEffectID`. |
| **Prominent CTA** | `.buttonStyle(.glassProminent).tint(brand.primary)` | Start Engine, and nothing else on that screen. |
| **Secondary floating buttons** | `.buttonStyle(.glass)` | Only when floating over content. In a toolbar, use the default style and let the toolbar glass them. |
| **Inspector** | System material | `.inspector()` provides it. No manual glass. |
| **Toasts / undo bars** | `.glassEffect(.regular, in: .capsule)` in a `.safeAreaBar(edge: .bottom)` | |

### 4.2 Where Liquid Glass is FORBIDDEN

This list is more important than the one above. Each entry has a reason; the reasons are the rule.

| Surface | Why not |
|---|---|
| **The log viewport, and every log line** | 10 000+ lines behind a live backdrop sample is a per-frame blur over a huge dirty rect — it will drop frames on scroll — and blur destroys monospaced legibility, which is the entire value of that screen. `surface.log` is **opaque**. |
| **Any `Table` or `List` row background** | Rows scroll. Glass on scrolling content re-samples the backdrop every frame for zero benefit. |
| **Chart plot areas, the Disk stacked bar, sparklines** | Glass tints and blurs the exact colour values you are asking the user to compare. It corrupts the data. |
| **Env-var rows and masked secrets** | Blur plus masking dots equals unreadable. |
| **Settings form sections** | `.formStyle(.grouped)` draws the sanctioned grouped background. Glass there is a visual bug. |
| **Anything inside a `ScrollView`'s content** | Glass is for chrome that floats *over* scrolling content. Never for the content itself. |
| **Cards** | We are deleting cards (§4.3). But for the avoidance of doubt: a card is content, not chrome. |
| **Nested glass** | Never a `.glassEffect` inside another `.glassEffect`. Adjacent glass goes in one `GlassEffectContainer` with `glassEffectUnion(id:namespace:)`. |
| **The app's own background** | `.containerBackground(.regularMaterial, for: .window)` at most. Not glass. |

**Budget: at most three glass surfaces visible at once.** If a screen wants a fourth, one of them
is decoration.

### 4.3 Depth ladder

Five levels. Exactly one shadow spec in the entire app.

| Level | What | Background | Border | Shadow |
|---|---|---|---|---|
| **L0** | Window | `surface.window` | — | — |
| **L1** | Content surface (tables, lists, log viewport) | `surface.content` | 1px `separator` where it meets chrome | **none** |
| **L2** | Grouped section (`Form`, `GroupBox`, detail sections) | `surface.grouped`, radius 8 | **none** | **none** |
| **L3** | Floating chrome (palette, popover, toast) | glass | **none** | `black @ 0.28` (dark) / `@ 0.18` (light), radius **24**, y **+12** |
| **L4** | Modal sheet | system | system | system |

- **L2 has no border and no shadow.** The bordered cards on Stacks and the shadowed cards on Disk
  both collapse to L2 fills. A rounded grey fill is a section; a rounded grey fill *with a border
  and a shadow* is a web card.
- **L3 is the only shadow in the app.** If you are writing `.shadow(` and you are not building a
  floating panel, delete it.
- Nothing is ever L1-on-L1 or L2-on-L2. Two nested grey fills means the hierarchy is wrong.

### 4.4 Radius scale

**Five values. Plus `.capsule`. Nothing else.**

| Radius | Use |
|---|---|
| `.capsule` | status pills, count badges, service badges, port chips, the prominent CTA |
| **6** | inline controls, small buttons, the search field |
| **8** | grouped sections (L2), list-row selection, sidebar-row selection |
| **12** | popover rows, menu-bar popover inner grouping |
| **20** | the command palette, floating panels (L3) |
| **185.4** (=0.225·824) | the app icon body only |

The seven radii currently in the screenshots (CRITIQUE §14) map onto these. Any other value is a
bug.

---

## 5. Motion

### 5.1 What animates

| What | Animation | Duration | Trigger |
|---|---|---|---|
| Live numerics — CPU %, memory, counts, sizes | `.contentTransition(.numericText())` + `.animation(.easeInOut(duration: 0.20), value:)` | 0.20 | value change |
| Status change | `.symbolEffect(.bounce.down, options: .nonRepeating, value: state)` on the state glyph + colour cross-fade | 0.18 | **state actually changes** — never on first appear |
| In-progress work (restarting, pulling, building) | `.symbolEffect(.rotate, isActive:)`, or `ProgressView().controlSize(.small)` | indefinite | while running |
| Pull / build progress | variable-value symbol + `.symbolVariableValueMode(.draw)` | — | progress |
| Palette present / dismiss | `.glassEffectTransition(.materialize)` | 0.22 | ⌘K / esc |
| Follow-pill ↔ new-lines-pill | `glassEffectID` morph in a `GlassEffectContainer` | 0.22 | scroll detach/attach |
| Row insert / remove | default spring | 0.25 | **user-initiated only** |
| Sidebar / inspector show-hide | system default | system | |

### 5.2 What must NOT animate

- **Nothing animates on a poll.** The engine refreshes on a timer; a re-render must animate
  *nothing* except `numericText`. If the container list re-sorts because of a poll, it snaps.
- **Selection is instant.** macOS list selection does not animate. 0ms.
- **No staggered list-entrance animation.** Ever. This is the single loudest vibe-coded tell in
  existence and it must never appear in this app.
- No hover scale, no card lift, no shimmer or skeleton loaders, no gradient sweeps, no parallax.
- No `.bounce` / `.pulse` / `.wiggle` on decorative icons. Symbol effects are reserved for state.
- The Disk bar does not animate its segments. It re-renders on refresh.
- Glass does not animate on hover. `.interactive()` handles press; that is the whole budget.

### 5.3 Durations

**0.12** micro (press) · **0.18** colour and opacity · **0.20** numeric · **0.22** present/dismiss ·
**0.25** layout. **Nothing exceeds 0.30.** Curves: `.easeOut` for entering, `.easeInOut` for value
changes, default spring for layout only.

### 5.4 Reduce motion

Read `@Environment(\.accessibilityReduceMotion)` (verified: `SwiftUICore` `EnvironmentValues`).
When on:

| Normally | Reduced |
|---|---|
| `.contentTransition(.numericText())` | plain text swap, no animation |
| `.symbolEffect(_:value:)` (discrete) | omit the modifier entirely |
| `.symbolEffect(_:isActive:)` (indefinite) | pass `isActive: false` |
| `.glassEffectTransition(.materialize)` | `.identity` |
| palette present | opacity fade, 0.12 |
| row insert / remove | no animation |
| **`ProgressView` spinners** | **keep spinning** — a progress indicator conveys state, and freezing it is worse than moving it. Reduce Motion targets decorative movement. |

Implement this once, in a `MorbMotion` environment-reading helper (COMPONENTS §3.9). Do not scatter
`if reduceMotion` through the screens.

---

## 6. Density

### 6.1 Spacing scale

**Nine values. Every gap, pad and inset in the app is one of these.**

| Token | pt | Use |
|---|---|---|
| `Space.hair` | 2 | icon-to-glyph nudges |
| `Space.tight` | 4 | inside a chip |
| `Space.snug` | 6 | chip-to-chip, icon-to-label |
| `Space.base` | 8 | default gap; row internal vertical |
| `Space.roomy` | 12 | label-to-control, column gutter minimum |
| `Space.section` | 16 | between sections; pane horizontal inset |
| `Space.gutter` | 20 | between major columns |
| `Space.pane` | 24 | pane bottom inset |
| `Space.void` | 32 | around empty states only |

### 6.2 Row heights — the shared rhythm

Every list in the app picks one of three densities. They are 24 / 28 / 44, and they are multiples
of 4 so screens stack cleanly against each other.

| Density | Height | Content | Used by |
|---|---|---|---|
| `.compact` | **24** | 1 line | Images, Volumes, Networks tables; Disk legend |
| `.standard` | **28** | 1 line + trailing meta | Sidebar; menu-bar container rows; Stacks service rows |
| `.rich` | **44** | 2 lines | Containers list; palette results |

Concrete corrections against the current screens:

| Screen | Now | Becomes |
|---|---|---|
| Sidebar row | ~44 | **28** |
| Container list row | ~66 | **44** — ports move to the detail pane, replaced by a single `+N` chip |
| Images table row | ~24 | 24 ✓ (already right) |
| Stacks service row | ~32 | **28** |
| Disk legend row | ~60 | **24** — the per-row Prune buttons move to a context menu |
| Menu-bar container row | ~80 | **28** |
| Palette result row | ~47 | **44** |

The menu-bar popover goes from ~1500pt tall to ~560pt. That change alone makes it feel like a Mac
menu-bar extra.

### 6.3 Insets and rules

- Pane horizontal inset: **16**. Section vertical gap: **16**. First section top: **12**. Last
  section bottom: **24**.
- Table column gutter: minimum **12**.
- Hairline: `NSColor.separatorColor` at **1 device pixel** (`1 / displayScale`), never 1.0pt.
- Separators are **inset to the content**, not full-bleed — they start at the text's leading edge,
  which fixes the ragged left edge in the grouped container list (CRITIQUE §11).

### 6.4 Icon sizes

| Context | Symbol pt | Box |
|---|---|---|
| Sidebar | 15 | 20 × 20 |
| Row leading | 13 | 16 × 16 |
| Inline meta | 11 | 14 × 14 |
| Toolbar | system | system |
| Status dot | **7 × 7** | 7 × 7 |
| Empty state | 40 | — (`ContentUnavailableView` sizes it) |

**The 9pt inline glyphs are deleted.** The chip and memory-stick glyphs beside CPU and memory in
the container row are illegible at 1× and carry no information a column header wouldn't. Anything
below 11pt is not an icon, it is grit.

### 6.5 Sidebar icons get colour

Eight identical grey monochrome symbols is the sidebar's core failure (CRITIQUE §1). Fix:

```swift
Image(systemName: "shippingbox.fill")
    .symbolRenderingMode(.hierarchical)
    .symbolColorRenderingMode(.gradient)     // macOS 26, verified
    .foregroundStyle(Theme.series[n])
```

Assign each nav item a fixed series colour, held for the life of the product so it becomes muscle
memory: Containers → 1 Indigo · Stacks → 5 Slate blue · Images → 2 Teal · Volumes → 3 Amber ·
Networks → 4 Magenta · Builds → 6 Olive · Kubernetes → 5 Slate blue · Disk → 3 Amber.

Also: replace the off-set Kubernetes wheel with a real SF Symbol at the same weight as its
neighbours — its current stroke weight breaks the icon column's optical alignment.
