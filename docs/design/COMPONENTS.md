# COMPONENTS — archived shared chrome proposal

> **Archived — do not implement or restore.** This is the historical inventory of the
> custom `Theme.swift` / `Design/**` / `Morb*` visual system proposed before the native
> macOS pivot. Those source files are being removed, not made authoritative. Preserve
> this record to explain past screenshots and migrations, but follow the binding
> [native macOS playbook](NATIVE-MACOS-PLAYBOOK.md) and
> [HIG coverage audit](HIG-COVERAGE-AUDIT.md) for all new work.
>
> The current replacements are direct system patterns: `NavigationSplitView` and a
> sidebar `List` for frame/navigation; `ToolbarItem`/`Menu`/Commands for actions;
> `Table`/`List` for records; `.inspector` with `Form` + `LabeledContent` for metadata;
> `ContentUnavailableView` for empty states; native focus/selection/status text for
> state. No compatibility wrapper, token scale, Morb card/chip/pill, custom glass, or
> custom hover/selection treatment is sanctioned.

Historical content follows. It describes a deleted component layer and is retained only
for migration archaeology; it is not an API catalogue for product code.

**These files belong to the design system. No implementation agent edits them.** If a
component is missing something you need, say so in your handoff and it gets added here
once, not forked three times. That rule is the entire point of this directory — the
current build has three segmented controls, three chip styles, five section-header
treatments and seven row heights precisely because everyone was allowed to invent locally.

The reference implementation compiles and the 617-test suite is green against it.

---

## The files

| File | Contains |
| --- | --- |
| `MorbGlass.swift` | `MorbGlassRole`, `.morbGlass`, `.morbGlassPanel`, `MorbGlassCluster`, `.morbGlassUnion`, `.morbGlassID`, `MorbButtonEmphasis`, `.morbButton`, `MorbScrollEdge`, `.morbScrollEdge`, `.morbBottomBar` |
| `MorbMotion.swift` | `MorbMotion`, `Theme.animation(_:reduceMotion:)`, `.morbAnimation`, `MorbPulse`, `.morbPulse` |
| `MorbStatus.swift` | `MorbStatusDot`, `MorbStatusBadge` |
| `MorbGroupState.swift` | `MorbGroupState`, `MorbGroupHeader` |
| `MorbChip.swift` | `MorbChipRank`, `MorbChip`, `MorbPortChip`, `MorbCountBadge` |
| `MorbCard.swift` | `MorbSectionHeader`, `MorbCard`, `MorbKeyValue` |
| `MorbMetric.swift` | `MorbMetric`, `MorbNumber`, `MorbMeter` |
| `MorbEmptyState.swift` | `MorbEmptyState`, `MorbNoMatches`, `MorbLoading`, `MorbBrandSymbol` |
| `MorbToolbar.swift` | `MorbToolbarGroup`, `MorbToolbarGap`, `MorbToolbarStatus`, `MorbIconButton`, `.morbScreen` |
| `MorbRow.swift` | `MorbRowClass`, `.morbRow`, `MorbRichRow`, `MorbOverflowChip`, `MorbRowDivider` |
| `MorbBrand.swift` | `MorbMarkGeometry`, `MorbStackShape`, `MorbOrbShape`, `MorbMark`, `MorbSidebarHeader` |

Eleven files. `Theme.swift` sits alongside them and is equally read-only.

---

## 1. Glass — `MorbGlass.swift`

### `.morbGlass(_:radius:tint:interactive:)`

```swift
func morbGlass(_ role: MorbGlassRole,
               radius: CGFloat,
               tint: Color? = nil,
               interactive: Bool = false) -> some View
```

**Replaces:** every ad-hoc `.background(.ultraThinMaterial, in:)` — there is exactly one
today, in `CommandPalette.swift:113` — and the `.background(.thinMaterial)` on the engine
pill in `App.swift`.

The **only** sanctioned way to get glass. `mac/Package.swift` targets `.macOS(.v15)` and
every Liquid Glass API is macOS 26.0, so a bare `.glassEffect(…)` in a feature file does
not compile. This takes the `#available` branch once, and also degrades to a `Material`
whenever Increase Contrast is on — glass has no increased-contrast variant we can rely on.

```swift
paletteBody
    .morbGlassPanel()                  // .panel, Theme.radiusPanel
    .presentationBackground(.clear)    // Glass is not a ShapeStyle — see SDK doc §2.13
```

### `MorbGlassCluster` + `.morbGlassUnion(id:namespace:)`

**Replaces:** the container detail header's four ungrouped buttons.

```swift
@Namespace private var ops

MorbGlassCluster(spacing: Theme.space3) {
    HStack(spacing: Theme.space3) {
        Button("Stop")    { … }.morbGlassButton().morbGlassUnion(id: "ops", namespace: ops)
        Button("Restart") { … }.morbGlassButton().morbGlassUnion(id: "ops", namespace: ops)
    }
}
```

### `.morbButton(_:)`

```swift
enum MorbButtonEmphasis { case primary, floating, standard }
```

**Replaces:** the four different button treatments in the container detail header, the
lavender `Pull` button in Images, and the indigo capsule in `EngineStoppedView`.

`.primary` → `.glassProminent` on 26, `.borderedProminent` below. **A screen gets at most
one `.primary`.** `.floating` → `.glass` / `.bordered`. `.standard` → `.bordered`.

### `.morbScrollEdge(_:for:)` and `.morbBottomBar`

`.hard` above tables and the log viewport, `.soft` above prose. `.morbBottomBar` is
`safeAreaBar` on 26 and `safeAreaInset` below — the engine pill's home.

---

## 2. Motion — `MorbMotion.swift`

### `MorbMotion` + `.morbAnimation(_:value:)`

**Replaces:** direct use of `Theme.springSubtle` / `springSnappy` / `fade` at the 11 call
sites that have them today, none of which honour Reduce Motion.

```swift
.morbAnimation(.subtle, value: rows)       // instead of .animation(Theme.springSubtle, value: rows)
```

Five tokens: `.snappy` (a click), `.subtle` (layout), `.fade` (something changed without
being asked), `.glassMorph`, `.pulse`. Under Reduce Motion the three springs collapse to
the 180 ms cross-fade and the two ornamental ones become `nil`.

**No feature file reads `\.accessibilityReduceMotion`.** If you find yourself wanting to,
the component you need is missing — say so.

### `.morbPulse(_:)`

**Replaces:** `StatusDot`'s inline `@State private var pulsing` + `repeatForever`, which
runs regardless of Reduce Motion.

---

## 3. Status — `MorbStatus.swift`, `MorbGroupState.swift`

### `MorbStatusDot`

```swift
MorbStatusDot(tone: .running, size: Theme.dotSize, pulsing: false, showsSymbol: false)
```

**Replaces:** `StatusDot` in `Theme.swift` (now a one-line forward to this) — 13 call
sites. New: Reduce Motion, and `showsSymbol` for the surfaces that want the glyph instead
of the disc.

### `MorbStatusBadge`

```swift
MorbStatusBadge(tone: .running, detail: "up 12d")
MorbStatusBadge(tone: .running, title: "3 of 4 services running", filled: false)
```

**Replaces:** three independently-grown `HStack { Circle(); Text(…) }` blocks — the
container header's `running · healthy · up 12d`, the stacks card header, and the engine
pill's headline — which had already drifted to three dot sizes and two fonts.

### `MorbGroupState` + `MorbGroupHeader`

```swift
let state = MorbGroupState.from(running: 3, total: 4)   // → .degraded
MorbGroupHeader("analytics", state: state, running: 3, total: 4, symbol: "square.3.layers.3d")
```

**Replaces:** the three *different* group-header treatments in `ContainersRootView`
(orange glyph + orange `3/4`, green glyph + green `5/5`, dashed square + grey `0/2`) and
the card headers in `StacksRootView`.

This is a separate type from `StatusTone` on purpose: `StatusTone` is switched over
exhaustively in `MenuBar/TrackDChrome.swift`, so adding a `degraded` case would break a
file outside this change's blast radius. See `REWRITE-PLAN.md` §Deferred.

---

## 4. Chips — `MorbChip.swift`

### `MorbChip`

```swift
MorbChip("postgres")                                    // .quiet — the default
MorbChip("arm64", rank: .actionable)
MorbChip("unhealthy", symbol: "exclamationmark.octagon.fill", rank: .status(.bad))
```

**Replaces:** `Chip` in `Theme.swift` (now a forward) — 9 call sites.

The rank system is the API. `.quiet` is `.secondary` on `.quaternary` and **most chips
should be this**; you cannot make a quiet fact loud without typing `.actionable` or
`.status`. That constraint is the fix for the thirty-three indigo port pills that are
currently the loudest thing on the containers screen.

### `MorbPortChip`

```swift
MorbPortChip(host: "8080", container: "80/tcp", isOpenable: true)
```

**Replaces:** the hand-built port pill in `ContainerListRow`, `ContainersChrome` and
`StacksRootView` — three copies at two different fonts. Only the host half gets
`Theme.accent`, and only when it opens in a browser.

### `MorbCountBadge`

```swift
MorbCountBadge(count: 8)
MorbCountBadge(count: 3, of: 4, tone: .busy)
```

**Replaces:** `NavRow`'s inline badge in `App.swift`, the group headers' `3/4`, and the
section headers' trailing count.

---

## 5. Cards — `MorbCard.swift`

### `MorbSectionHeader`

```swift
MorbSectionHeader("Ports", symbol: "point.3.connected.trianglepath.dotted", count: 1)
MorbSectionHeader("Environment", count: 7) { Toggle("Show values", isOn: $reveal) }
```

**Replaces:** `SectionLabel` in `Theme.swift` (now a forward) **and** the six bespoke
`HStack { Image; Text.uppercased(); Text(count) }` blocks in the container inspect tabs.
The symbol is drawn at a fixed 10 pt semibold regardless of glyph — SF Symbols do not
share an optical weight across families, which is why the current six look like six
different sizes.

### `MorbCard`

```swift
MorbCard("Largest images", symbol: "shippingbox", padding: 0) {
    VStack(spacing: 0) { ForEach(images) { row($0) } }
}
```

**Replaces:** the ad-hoc `RoundedRectangle` backgrounds in `DiskRootView`,
`StacksRootView` and `MorbSettingsView` — three radii, two fills.

Opaque, hairline-bordered, **never glass, never a shadow**. A card is content.

### `MorbKeyValue`

```swift
MorbKeyValue("Image", "postgres:16.4-alpine")
MorbKeyValue("Image ID", "sha256:9879af2c…", monospaced: true)
```

**Replaces:** the hand-built label/value `Grid` in `ContainerOverviewTab`, which
right-aligns its labels at a width computed by eye. This is `LabeledContent`, which is
macOS 13 and gets the column width and the baseline right for free.

---

## 6. Numbers — `MorbMetric.swift`

### `MorbMetric`

```swift
MorbMetric(value: "25.15", unit: "GB", caption: "used by Docker", emphasis: .leading)
```

**Replaces:** the three metrics in the Disk screen's `VM DISK IMAGE` card, which are given
three different weights for no stated reason, and the stat tiles in `ContainerStatsTab`.

Exactly one sibling may be `.leading`.

### `MorbNumber`

```swift
MorbNumber("57.2%", width: 52)
```

**Replaces:** every `Text("\(pct)%")` in the app. All of them are missing
`.monospacedDigit()`, which is why the containers list, the menu-bar popover and the disk
legend visibly twitch on a live engine.

Always monospaced-digit, always `.contentTransition(.numericText())`.

### `MorbMeter`

```swift
MorbMeter(value: 1.49e9, total: largestOfEitherCard, tone: Theme.seriesIndigo,
          reclaimable: 0.4e9)
```

**Replaces:** the naked `RoundedRectangle` bars in the Disk screen's two "LARGEST …"
cards. Two fixes the call site cannot make: the track is always drawn (an empty bar still
reads as a bar with a scale), and `total` is explicit so **two meters side by side can be
given the same denominator**. The current cards use independent scales, which makes a
1.49 GB image look larger than a 3.22 GB volume.

Reclaimable is the same hue at `Theme.seriesDimAlpha` (45 %). **Diagonal hatching is
banned.**

---

## 7. Empty states — `MorbEmptyState.swift`

```swift
MorbEmptyState("The engine isn’t running",
               systemImage: "shippingbox",
               description: "Start it to see your containers, images and volumes.",
               footnote: "Morbstack runs Docker in a lightweight virtual machine.",
               actionTitle: "Start Engine") { Task { await model.engineAction(.start) } }
```

**Replaces:** `EngineStoppedView` in `App.swift` and `PlaceholderView.swift` — two
hand-built empty states at two sets of metrics, neither matching the system's.

Built on `ContentUnavailableView` (macOS 14, no gate). The footnote lives *inside* the
stack rather than bottom-anchored to the window 450 pt away from anything.

`MorbNoMatches(query:)` is `ContentUnavailableView.search(text:)` — every filterable list
in the app needs one and none has one; filtering to zero currently shows an empty table.

`MorbBrandSymbol(systemImage:)` is the empty state's glyph: `Theme.brand`, rendered as a
gradient on macOS 26 via `symbolColorRenderingMode(.gradient)`. The tint goes on the
**icon**, never on the whole `ContentUnavailableView` — a `foregroundStyle` on the
container turns the headline indigo and flattens the type hierarchy.

---

## 8. Toolbar — `MorbToolbar.swift`

### `.morbScreen(title:subtitle:edge:)`

```swift
ImagesTable(model: model)
    .morbScreen(title: "Images", subtitle: "18 images · 6.93 GB · 2 dangling", edge: .hard)
    .toolbar(id: "images") { … }
```

**Replaces:** the hand-drawn `Text` title + subtitle at the top of every content pane —
`ContainersChrome`, `TrackCChrome`, `DiskRootView`, `StacksRootView`, `VolumesRootView`,
`NetworksRootView`. This is the single change that fixes "no window to drag", "no
scroll-edge effect" and "no Liquid Glass" on seven screens at once.

### `MorbToolbarGroup`

Named placements so every screen puts the same *kind* of control in the same place:
`.navigation` (view mode), `.actions` (primary), `.overflow` (⋯), `.status`.

### `MorbToolbarGap`

```swift
.toolbar(id: "container") {
    ToolbarItem(id: "stop", placement: .primaryAction) { Button("Stop") { … } }
    MorbToolbarGap(placement: .primaryAction)
    ToolbarItem(id: "remove", placement: .primaryAction) { MorbIconButton("trash", help: "Remove", role: .destructive) { … } }
}
```

`ToolbarSpacer` on macOS 26, no-op below. Without it every item in a placement merges into
one glass blob.

### `MorbToolbarStatus`

A read-only indicator with `sharedBackgroundVisibility(.hidden)` so it does not read as a
button. The logs screen's `● 412 lines` is the one user.

### `MorbIconButton`

```swift
MorbIconButton("trash", help: "Remove image", role: .destructive) { … }
```

**Replaces:** every bare `Button { } label: { Image(systemName:) }` in the app.

Gives a `Theme.minHitTarget` (24 × 24) frame, a `contentShape`, a hover wash and a tooltip.
Destructive affordances are `.secondary` at rest and only turn `statusBad` on hover — the
Images table currently paints its trash red whenever deleting is *safe*, so the safe rows
look like the dangerous ones.

---

## 9. Rows — `MorbRow.swift`

### `MorbRowClass` + `.morbRow(_:isSelected:showsHover:)`

```swift
enum MorbRowClass { case compact, standard, rich }   // 24 / 32 / 44 pt
```

**Replaces:** `Theme.rowPadding`-based sizing everywhere. The app currently ships **seven**
row heights; this is four, and each list picks exactly one.

`.morbRow` also supplies the selection treatment: `Theme.selectionFill` plus a 3 pt
`Theme.selectionRail` capsule on the leading edge. That rail is the half of the selection
that survives greyscale, and it is why a screenshot of the new build will have a colour
identity when the current one does not.

### `MorbRichRow`

```swift
MorbRichRow(title: container.name, subtitle: container.image, isSelected: isSelected) {
    MorbStatusDot(tone: tone)
} trailing: {
    MorbNumber(cpu, width: 52)
    MorbPortChip(host: "8080", container: "80/tcp")
    if extraPorts > 0 { MorbOverflowChip(hidden: extraPorts, detail: allPorts) }
}
```

**Replaces:** `ContainerListRow`'s three-tier layout. The type enforces the rule: the
trailing content is one column, it truncates there, and **nothing in it can make the row
taller**. The current row swells from 70 pt to 100 pt when a container publishes three
ports.

### `MorbOverflowChip`, `MorbRowDivider`

`+2` for what a fixed row cannot show, with the full list in the tooltip. Dividers inset
to the row's content rather than to the window edge.

---

## 10. Brand — `MorbBrand.swift`

### `MorbMark`

```swift
MorbMark(size: 20)                 // glyph only, brand gradient — sidebar header
MorbMark(size: 96, plated: true)   // full icon — About box
```

Draws the same geometry as `mac/AppResources/make-icon.swift`, specified once in
`IDENTITY.md` §1. **The only place in the app that draws the logo.** `MorbMarkGeometry`
exposes the constants so the CoreGraphics side and the SwiftUI side cannot drift.

### `MorbSidebarHeader`

```swift
MorbSidebarHeader(version: model.engine.version.map { "v\($0)" })
```

**Replaces:** nothing — the sidebar currently opens straight into a list of eight peers
with no header, no mark and no grouping.

---

## What is deliberately NOT here

| Not a component | Use instead |
| --- | --- |
| A custom segmented control | `Picker(…).pickerStyle(.segmented)`. The app has three hand-rolled ones and none matches AppKit's. |
| A custom table | `Table` + `.tableStyle(.inset)` + `.alternatingRowBackgrounds()`. |
| A custom search field | `.searchable(text:placement: .toolbar, prompt:)`. |
| A custom settings panel | `Form` + `.formStyle(.grouped)` in the `Settings` scene. |
| A custom third column | `.inspector(isPresented:)` + `.inspectorColumnWidth(min:ideal:max:)`. |
| A custom disclosure / outline | `DisclosureGroup`, `OutlineGroup`. |
| A "card shadow" modifier | There are no shadows on content. |
| A gradient text style | There is one gradient in the app and it is the mark. |

All of the above are available at `.macOS(.v15)` with **no availability gate** — see
`SDK-LIQUID-GLASS.md` §2. Most of the "native Mac" win is not glass; it is using the
structural controls the SDK already ships.
