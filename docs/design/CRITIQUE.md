# CRITIQUE — archived pre-migration evidence

> **Image note (2026-08-05):** the screenshots this document referenced lived in
> `mac/dist/shots/`, `docs/img/` or `artifacts/visual/` and have been removed. The
> first was offscreen `MorbShots` output, which `docs/design/DECISIONS.md` §6 retired
> as *not* visual evidence — it cannot composite the toolbar, inspector or glass. The
> others were dated captures of superseded builds. The findings stand as written; the
> images are recoverable from git history if a specific one is ever needed.


> **Historical record — not a current visual specification.** These findings were made
> against synthetic inner-content renders at base commit `a0602c5`, before the native
> macOS migration. They remain useful evidence of the failure modes to avoid, but their
> screenshot measurements and proposed remedies cannot approve the current app. Use the
> [native macOS playbook](NATIVE-MACOS-PLAYBOOK.md),
> [HIG coverage audit](HIG-COVERAGE-AUDIT.md), and a real-window Computer Use review
> instead.

Written against `dist/shots/*@2x.png` at base commit `a0602c5`. Every claim below is
something you can point at in a render. Nothing here is a matter of taste dressed up as
a principle; where it is taste, it says so.

The product owner's summary — "looks vibe coded, not native enough, no visual identity,
doesn't punch up to OrbStack" — is correct, and it decomposes into six root causes. The
per-screen notes after them are the evidence.

---

## The six root causes

### 1. There is no window toolbar. Anywhere.

This is the single biggest "not a Mac app" tell and it is invisible until you name it.

Look at `hero-containers-dark`. The strip across the top — **Containers / 8 running · 11
total**, the search field, the All/Running segmented control, the **Prune stopped 3**
button — is not a toolbar. It is an `HStack` inside the detail pane's content area. The
consequences are all visible in the render:

- The window has no titlebar region, so **there is nothing to drag the window by** except
  the sidebar's empty space.
- Content scrolls *behind nothing*. macOS 26 gives you a scroll-edge effect for free when
  the toolbar is real; here the first list row simply butts against a hairline.
- The title (`Containers`) and subtitle (`8 running · 11 total`) are hand-drawn `Text`
  when `.navigationTitle` + `.navigationSubtitle` exist and put them in the correct
  optical position with the correct dynamic type behaviour.
- No toolbar means no `ToolbarSpacer`, no `.toolbar(id:)` customisation, no automatic
  Liquid Glass grouping, and no `sharedBackgroundVisibility`. Every macOS 26 affordance
  that makes an app look current is gated behind the toolbar the app doesn't have.

Seven of the ten screens repeat this. `hero-logs-dark` has a fake toolbar (Follow /
Times / Filter lines / 412 lines / trash / copy / share). `images-light` has one (Filter
images / Prune Dangling) *plus* a second half-toolbar below it (the ⤓ `nginx:alpine`
[Pull] row) wedged between the header and the table. `hero-disk-light` has one (Refresh).

### 2. There is no Liquid Glass, and the one material in the app is in the wrong place.

`grep -rn "glassEffect" mac/Sources` returns nothing. The entire app contains **one**
material: `.ultraThinMaterial` behind the command palette, plus `.thinMaterial` behind
the engine pill.

Meanwhile the menu-bar popover (`menubar-popover-dark`) — the one surface on macOS where
glass is not optional — is an **opaque dark rounded rectangle**. You can see it in the
render: it is pasted onto the wallpaper with a visible hard edge and zero transmission of
the purple gradient behind it. Every first-party menu extra on macOS 26 is glass. This
one looks like a screenshot of a web app.

### 3. Every structural control is hand-rolled, and each one is hand-rolled differently.

| What it should be | What it is |
| --- | --- |
| `Table` | Ports and Mounts in Inspect are `Grid`s with a hand-drawn all-caps header row. Stacks service rows are an `HStack` with hard-coded column x-positions. Only `images-light` uses a real table. |
| `Form(.grouped)` / `LabeledContent` | Configuration in Overview is a hand-built label/value grid. Settings is a bespoke card stack. |
| `ContentUnavailableView` | `engine-stopped-light` reimplements it: a 110 pt lavender disc, an H2, two lines of body, a capsule button. |
| `.inspector` | The third column is a plain `HStack` sibling with a `Divider`. Not collapsible, not resizable, not remembered. |
| `.searchable` | Both search fields are `TextField`s with a magnifying-glass `Image` prefix. |
| `Picker(.segmented)` | Overview/Logs/Stats/Inspect is a custom pill row; All/Running is a *different* custom pill row; Settings' General/Resources/Advanced is a *third*. |

Three custom segmented controls in one app, none of which match AppKit's, is the
definition of "vibe coded".

### 4. Density is unmanaged. Row height is different on every screen.

Measured off the 2× renders, halved to points:

| Surface | Row height |
| --- | --- |
| Images table | 47 pt |
| Stacks service row | 63 pt |
| Disk legend row | 60 pt |
| Containers list row | **70–100 pt**, varying with port count |
| Command-palette result | 62 pt |
| Menu-bar container row | 80 pt |
| Menu-bar port row | 54 pt |

The containers list is the worst of it: a row with three port pills is 43% taller than a
row with none, so the list has a ragged rhythm and you cannot estimate "how many
containers are there" by eye. The menu-bar popover at 80 pt per container is
extraordinary — eight containers and six ports produce a **775 pt** popover, most of a
laptop's screen height, to show fourteen facts.

There is no spacing scale. `Theme` has `pagePadding: 20`, `rowPadding: 7`, and nothing
else; every other gap in the app is a literal.

### 5. The colour system inverts importance.

Open `hero-containers-dark` and squint. The loudest things on screen are the **port
pills** — indigo text on a 13%-indigo fill, up to three per row, 33 of them visible at
once. Ports are the *least* urgent fact in the list. The most urgent fact — that
`registry-mirror` is unhealthy and restarting — is an 8 pt dot and a small red chip at the
very bottom edge.

The rest of the palette does nothing. The sidebar selection is neutral grey
(`containers-list-light` makes this unmissable). Group headers use orange, green and grey
counts inconsistently. `Theme.brandSecondary` is defined and used **zero** times;
`Theme.cardBackground`, `Theme.hairline`, `Theme.rowHover`, `Theme.rowPadding` and
`Theme.springSnappy` are all used **zero** times — the design system is five dead symbols
and one over-used accent.

A greyscale print of any of these screens is indistinguishable from a greyscale print of
a SwiftUI tutorial. That is what "no visual identity" means concretely.

### 6. The mark does not survive its own smallest size, and it says the wrong word.

`make-icon.swift` draws a white **ring** (stroke width = 30% of the orb radius) with
**three slats** inside it. Inside a 16 pt icon the plate is ~13 pt across and the orb is
~6.7 pt across; that is five alternating white/indigo bands across roughly seven pixels.
It will mush into a grey disc at 1×.

Conceptually it reads as a beach ball or a loading indicator. The product is "More Orb,
open **Stack**" — the layered half is doing no work. Three equal horizontal bars inside a
circle is not a stack; a stack has perspective, offset, or depth.

---

## Screen by screen

### `hero-containers-dark` / `containers-list-light`

- **Sidebar** is a `List(.sidebar)` of eight flat peers with stock SF Symbols and no
  grouping. Two of the eight (Builds, Kubernetes) are placeholders that lead to a "coming
  soon" screen; they sit at the same rank as Containers. Selection is the system's grey
  rounded rect — no tint, no brand, no left rail. There is no header, no app mark, no
  section title. It is the Xcode template.
- **Three columns, one split view.** Sidebar↔content is a `NavigationSplitView`;
  content↔detail is an `HStack` with a `Divider()`. So the detail pane cannot be
  collapsed, cannot be dragged, and does not persist its width.
- **Rows carry three tiers of information at two tiers of weight.** Line 1: name (bold) +
  a grey service chip. Line 2: image · CPU% · memory, all `.secondary`, all the same size,
  separated by middots and tiny inline glyphs. Line 3: port pills. The eye has no route
  through it.
- **The age (`6h`, `3d`, `12d`) floats at the top-right of each row**, unlabelled, in
  tertiary grey, aligned to nothing. Nobody will guess it is uptime rather than image age.
- **Group headers use three different treatments** for the same construct: `analytics`
  gets an orange layers glyph and an orange `3/4`; `shopfront` gets a green glyph and a
  green `5/5`; `Standalone` gets a dashed-square glyph and a grey `0/2`. The colour is
  carrying status, but the header has no status dot, so the encoding is invented and
  inconsistent.
- **CPU and memory are not monospaced-digit.** `57.2%` → `4.4%` → `21.9%` reflow the row
  every refresh. On a live engine this list visibly jitters.
- **Detail header**: name, a violet `shopfront` chip, `Up 12 days (healthy)`, a 12-hex
  container ID at 40% opacity, then port pills again, then the fake segmented control.
  Five ranks of type in 90 pt of height.
- **Four buttons, four treatments**: `⏹ Stop` (bordered, labelled), `↻ Restart` (bordered,
  labelled), `⏸` (bordered, icon), `⊖` (borderless-looking, icon). No grouping, no
  `ToolbarSpacer`, and the destructive one is the least emphasised.
- **Section headers** (`STATE`, `CONFIGURATION`, `PORTS 1`, `ENVIRONMENT 7`, `MOUNTS 1`,
  `LABELS 6`) each pair an all-caps caption with an SF Symbol, but the six symbols are
  drawn at different optical weights and none of them are related — a clock, a gear, an
  unidentifiable port glyph, a card, a drive, a tag.
- **ENVIRONMENT is seven identical rows of `••••••••`** with a per-row eye button *and* a
  global "Values hidden" toggle. Two mechanisms, one job, and the default state shows the
  user nothing at all across 240 pt of screen.
- **PORTS and MOUNTS are fake tables**: grey all-caps header row, hand-positioned columns,
  no sorting, no resizing, no selection.

### `hero-logs-dark`

The best screen in the app, and still wrong in four ways.

- **The gutter does not read as a gutter.** Timestamps are the same size as the log text
  and only slightly dimmer, so the eye cannot lock onto the left rail. They also repeat on
  blank continuation lines inside a stack trace (`08:44:05.032` on an empty line), where
  they are meaningless.
- **The error region is a full-bleed red wash** across the entire viewport width, with the
  band's edges as its only anchor. A 3 pt left rule in `statusBad` plus a very faint tint
  would say the same thing with a tenth of the ink and would survive being scrolled
  half-off-screen.
- **`412 lines` sits next to a green dot** in the fake toolbar — the dot means "following"
  but is 200 pt from the Follow button.
- **No line numbers, no wrap indicator, no jump-to-next-error.** The app knows exactly
  where the `[FATAL]` is; there is no way to get to it.

### `hero-disk-light`

- **The stacked bar encodes eight states in 30 pt**: four hues × solid/diagonal-hatched.
  The hatching reads as a moiré artifact, not as "reclaimable". At the sizes rendered, the
  amber segment's hatch is four stripes wide.
- **Legend rows are a five-column hand-rolled `HStack`** ending in a `Prune` button. The
  destructive action has the same visual weight as the row's label.
- **The two "LARGEST …" cards use independent scales.** `jenkins/jenkins 1.49 GB` fills its
  bar; `shopfront_uploads 3.22 GB` fills its bar. Side by side, at a glance, the 1.49 GB
  image looks bigger than the 3.22 GB volume. That is a chart that lies.
- **`VM DISK IMAGE` gives three metrics three different weights** — 68.72 GB regular,
  19.38 GB bold, 28.2% regular — with no stated reason.
- **Backticks are leaking into the UI.** The body copy renders `` `ls -l` `` and
  `` `st_blocks × 512` `` with literal backtick characters.
- **The path `/Users/ada/.morbstack/data/disk.img` is at roughly 25% opacity**, below the
  contrast floor for any text size, let alone monospaced caption.
- **The page is 350 pt of content in a 900 pt window**, cards floating on a grey field.
  Grouped cards on a tinted field is the iOS Settings idiom, not the macOS one.

### `images-light`

- **The most native screen** — it is a real `Table` with a real header. It also shows what
  the rest of the app is missing.
- **The Pull row is a third kind of bar**: a download glyph, a monospaced `nginx:alpine`
  as a borderless text field, and a lavender `Pull` button, sandwiched between the fake
  toolbar and the table header.
- **`In use` renders two ways in one column**: a green capsule with a box glyph and a
  count, or a bare grey `0`. Same column, two grammars.
- **Two unheaded trailing icon columns** (ⓘ, 🗑). The trash is **red when the image is
  unused and grey when it is in use** — colour is encoding *enablement*, which reads as
  "danger", so the safe-to-delete rows look like the dangerous ones.
- **The sort indicator is a chevron before the column title**; AppKit puts a triangle
  after it.
- **The `Dangling 2 1.9 GB` header floats below the table** rather than being a table
  section, so its two rows are outside the header's column geometry contract.

### `settings-light`

The weakest screen.

- **A bespoke, centred segmented `Picker` inside a floating panel with no titlebar.** A
  macOS settings window has a titlebar with a toolbar of tabs.
- **A `Revert` / `Save` footer bar.** No macOS settings window has one. Mac settings apply
  on change; the footer is a Windows/web idiom and it means the user has to remember to
  press a button after moving a slider.
- **Each setting is a card containing a label, a right-aligned value, a slider under it,
  and a paragraph of body copy under that.** The slider sits at the far right of a
  full-width row with ~450 pt of dead space between the label and the track, and the
  1…8 endpoint labels are 9 pt grey text sitting *outside* the track.
- **Explanatory prose is the same size as the control label.** "A cap, not an allocation…"
  is two lines at body size — good writing at the wrong rank, so it competes with the
  thing it explains.

### `menubar-popover-dark`

- **Opaque, not glass.** See root cause 2.
- **775 pt tall** at default content. 80 pt per container row (a two-line label plus a
  right-aligned percentage), 54 pt per port row.
- **Five distinct row heights** in one panel: header 60, section header 30, container 80,
  port 54, footer 54.
- **`+3 more in the main window` is dead text**, not a button, in the middle of a list of
  clickable things.
- **The footer shows ⌘O / ⌘, / ⌘Q hints** — a `Menu` idiom — inside a `.window`-style
  popover where those shortcuts only fire if the popover holds key focus.
- **The CPU percentages are right-aligned but not monospaced-digit**, so they shimmer on
  every 2-second sample.

### `command-palette-dark`

- **Presented as a `.sheet`**, so it is bolted to the window's centre-top and dims
  nothing. A command palette is a floating panel; it should be `.presentationBackground`
  glass over a scrim, anchored at ~22% from the top.
- **Every result row has the same icon** (`text.alignleft` in a rounded square) because
  the query matched one verb eight times, and the icon's *tint* is carrying container
  status. So the icon column encodes neither the command nor its category.
- **`Container` is right-aligned on all eight rows.** That is a section header printed
  eight times.
- **Two indigos fight**: the selected row's fill is indigo at ~20%, and the fuzzy-match
  highlight inside the text is a brighter indigo — on the selected row the highlight is
  nearly invisible.
- **The keyboard legend** (`↑↓ navigate  ↵ run  esc close`) is tertiary caption2 and
  disappears against the material.

### `stacks-dark`

- **Cards that aren't cards**: the header and body share a fill and are separated only by
  a hairline, so the "card" contributes nothing but a corner radius.
- **Port pills sit at a hard-coded x (~745 pt).** A service with no ports leaves a hole
  there. This is a table pretending not to be one.
- **The per-row stop/restart buttons are ~11 pt tertiary glyphs jammed against the right
  window edge**, roughly 1 600 pt from the service name they act on, with no visible hit
  target.
- **`Up` is disabled by opacity only** on the fully-running stack — the border stays at
  full strength, so it reads as enabled-but-faded.
- **800 pt of empty window** below the second card.

### `engine-stopped-light`

- **A hand-built `ContentUnavailableView`** at non-standard metrics: a 110 pt lavender
  disc (roughly 3× the system's icon size), an H2, a two-line body, and a fully-rounded
  **capsule** primary button. macOS does not use capsule buttons for primary actions.
- **The sidebar is fully live while the engine is stopped.** Clicking `Images` gives an
  empty table with no explanation — a second, worse empty state one click away from a good
  one.
- **`Morbstack runs Docker in a lightweight virtual machine.` is bottom-centred at ~40%
  opacity, 450 pt below the button**, anchored to nothing.

---

## What "punching up to OrbStack" actually requires

Not more chrome. Three things, in order:

1. **Move every fake header bar into a real `.toolbar`,** and let macOS 26 supply the
   glass, the scroll-edge effect, the window drag and the customisation. This single
   change fixes root causes 1 and 2 on seven screens.
2. **Standardise density.** One spacing scale, one row height per class of list, monospaced
   digits everywhere a number updates. Dense and even beats airy and ragged for a systems
   tool.
3. **Spend the brand colour where it means something** — selection, focus, and the one
   primary action per screen — and take it off the port pills. Then give status the
   loudness that ports currently have.

Everything else in `IDENTITY.md` and `COMPONENTS.md` follows from those three.
