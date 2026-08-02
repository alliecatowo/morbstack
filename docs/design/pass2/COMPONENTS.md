# COMPONENTS.md — shared chrome, and the per-screen plan

## 0. Read this first: the layer already exists

**A prior design pass has already landed in the working tree, uncommitted.** I found it while
auditing, not before. Concretely, present on disk right now:

| Path | Lines | State |
|---|---|---|
| `mac/Sources/MorbstackAppCore/Design/` — 11 files | 2 038 | **built** |
| `mac/Sources/MorbstackAppCore/Theme.swift` | 470 | **rewritten** |
| `mac/AppResources/make-icon.swift` | — | **rewritten** to the orb-and-stack mark |
| `docs/design/{CRITIQUE,SDK-LIQUID-GLASS,IDENTITY,COMPONENTS,REWRITE-PLAN}.md` | 2 468 | **written** |

And the adoption gap, measured:

```
grep -rl "MorbCard|MorbChip|MorbStatusDot|morbGlass|morbScreen|MorbRichRow|MorbEmptyState"
  → mac/Sources/MorbstackAppCore/Views/Containers/ContainerListRow.swift
  (one file)
```

**One view file out of thirty-six uses the design system.** ~12 800 lines of view code across
Containers, Images, Volumes, Networks, Disk, Stacks, MenuBar, Palette, Settings and `App.swift`
still render the screens in the screenshots. Every finding in `CRITIQUE.md` is still on screen
because the components were built and never wired up.

So this document is **not** a request to build components. It is the **application plan**, plus the
short list of deltas the component layer still needs.

> My `CRITIQUE.md`, `SDK-LIQUID-GLASS.md` and `IDENTITY.md` in this directory were written before I
> found `docs/design/`. They are an independent second pass. Where they agree with the existing
> docs — which is most places — that is corroboration. Where they differ, see §4.

---

## 1. The critical build constraint

```swift
// mac/Package.swift
platforms: [ .macOS(.v15) ]
```

**The deployment target is macOS 15. Every Liquid Glass API is macOS 26.0.** A bare `.glassEffect`
in a feature file does not compile, and an `@available(macOS 26, *)` on a view poisons every call
site above it.

`Design/MorbGlass.swift` already solves this correctly: the availability branch is taken **once**,
in `MorbGlassModifier.body`, with a `Material` fallback below 26 — and, notably, also whenever
`colorSchemeContrast == .increased`, because glass has no increased-contrast variant.

**Rule for all three implementation agents: never write `glassEffect`, `GlassEffectContainer`,
`glassEffectID`, `glassEffectUnion`, `.buttonStyle(.glass)` or `ToolbarSpacer` in a feature file.
Call the wrapper. If the wrapper doesn't cover your case, file it against the integrator — do not
add an `@available` to a screen.**

---

## 2. The component inventory, as built

Signatures read from the source on disk. All are internal to `MorbstackAppCore` (no `public`).

### 2.1 `Design/MorbToolbar.swift` — screen chrome

```swift
enum MorbToolbarGroup {
    static let navigation: ToolbarItemPlacement = .navigation
    static let actions:    ToolbarItemPlacement = .primaryAction
    static let overflow:   ToolbarItemPlacement = .secondaryAction
    static let status:     ToolbarItemPlacement = .status
}

struct MorbToolbarGap: ToolbarContent          // wraps ToolbarSpacer (macOS 26) / no-op below
struct MorbToolbarStatus<Content: View>: ToolbarContent {
    init(id: String, @ViewBuilder content: () -> Content)
}
struct MorbIconButton: View {
    init(_ systemImage: String, help: String, role: ButtonRole? = nil,
         action: @escaping () -> Void)
}
extension View {
    func morbScreen(title: String, subtitle: String? = nil,
                    edge: MorbScrollEdge = .hard) -> some View
}
```

`.morbScreen(title:subtitle:)` is **the single most important call in the rewrite.** It is what
replaces the painted in-content header on every screen with a real toolbar. Every root view gets
exactly one.

**Replaces:** every hand-built header `HStack` in `ContainersChrome.swift`,
`Views/Images/TrackCChrome.swift`, `StacksRootView`, `DiskRootView`, `VolumesRootView`,
`NetworksRootView`.

### 2.2 `Design/MorbGlass.swift` — the only glass door

```swift
enum MorbGlassRole { case panel, bar, control }   // .fallbackMaterial for < macOS 26

extension View {
    func morbGlass(_ role: MorbGlassRole, radius: CGFloat,
                   tint: Color? = nil, interactive: Bool = false) -> some View
    func morbGlassPanel(radius: CGFloat = Theme.radiusPanel) -> some View
    func morbGlassUnion(id: some Hashable & Sendable, namespace: Namespace.ID) -> some View
    func morbGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View
    func morbButton(_ emphasis: MorbButtonEmphasis) -> some View
    func morbGlassButton() -> some View                    // == morbButton(.floating)
    func morbScrollEdge(_ style: MorbScrollEdge, for edges: Edge.Set = .top) -> some View
    func morbBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View
}

struct MorbGlassCluster<Content: View>: View   // wraps GlassEffectContainer(spacing:)
enum MorbButtonEmphasis { … }
enum MorbScrollEdge { … }
```

### 2.3 `Design/MorbStatus.swift` + `Theme.StatusTone`

```swift
enum StatusTone { case running, idle, busy, paused, bad }   // in Theme.swift
    var color: Color; var symbol: String; var label: String; var isTransitional: Bool
    static func forContainer(state: String, unhealthy: Bool = false) -> StatusTone
    static func forEngine(_ status: EngineStatus) -> StatusTone

struct MorbStatusDot: View   // init(tone:size:pulsing:)
struct MorbStatusBadge: View
```

**Replaces:** `StatusDot` (already a thin forward in `Theme.swift`), and every ad-hoc
`Circle().fill(.green)` in the views.

### 2.4 `Design/MorbChip.swift`

```swift
enum MorbChipRank { case quiet, … }             // rank, not colour, is the API
struct MorbChip: View {
    init(_ text: String, symbol: String? = nil,
         rank: MorbChipRank = .quiet, monospaced: Bool = false)
    init(_ text: String, symbol: String? = nil, tone: Color)     // legacy colour form
}
struct MorbPortChip: View
struct MorbCountBadge: View
```

`MorbChipRank` is the fix for CRITIQUE §2 (seven pill treatments). **Use the `rank:` initialiser.
The `tone: Color` overload exists only so the legacy `Chip` forward compiles — treat it as
deprecated and do not introduce new call sites.**

### 2.5 `Design/MorbRow.swift`

```swift
enum MorbRowClass { … }                        // maps to Theme.rowCompact/Standard/Rich
extension View { func morbRow(_ rowClass: MorbRowClass, …) -> some View }
struct MorbRichRow<Leading: View, Trailing: View>: View { init(title:subtitle:…) }
struct MorbOverflowChip: View                  // the "+N" chip
struct MorbRowDivider: View                    // content-inset hairline
```

`MorbOverflowChip` is what lets the container row drop from ~66pt to `Theme.rowRich` (44) — ports
collapse to `+N` and move to the inspector.

### 2.6 `Design/MorbCard.swift`

```swift
struct MorbSectionHeader: View { init(_ title: String, symbol: String? = nil, count: Int? = nil) }
struct MorbCard<Content: View>: View {
    init(_ title: String? = nil, symbol: String? = nil, count: Int? = nil,
         padding: CGFloat = Theme.space4, @ViewBuilder content: () -> Content)
}
struct MorbKeyValue<Value: View>: View {
    init(_ label: String, monospaced: Bool = false, @ViewBuilder value: () -> Value)
}
extension MorbKeyValue where Value == Text {
    init(_ label: String, _ text: String, monospaced: Bool = false)
}
```

`MorbKeyValue` replaces the hand-aligned Configuration list in `ContainerOverviewTab`.
`MorbSectionHeader` replaces every all-caps `Text(...).font(.caption)` header — **and it takes
sentence case; do not pass `"CONFIGURATION"`.**

### 2.7 `Design/MorbGroupState.swift`

```swift
enum MorbGroupState { … ; static func from(running: Int, total: Int, transitioning: Int = 0) }
struct MorbGroupHeader<Trailing: View>: View {
    init(_ title: String, state: MorbGroupState, running: Int, total: Int,
         symbol: String? = nil, @ViewBuilder trailing: () -> Trailing)
}
```

This is where `degraded` lives. `StatusTone` deliberately has **no** `degraded` case because
"up, but not all of it" is a property of a *group*, and adding a sixth case would break the
exhaustive switch in `MenuBar/TrackDChrome.swift`. See §5.

### 2.8 `Design/MorbMetric.swift`, `MorbEmptyState.swift`, `MorbMotion.swift`, `MorbBrand.swift`

```swift
struct MorbMetric: View
struct MorbNumber: View { init(_ text: String, tone: Color? = nil,
                               width: CGFloat? = nil, font: Font = .subheadline) }
struct MorbMeter: View

struct MorbEmptyState<Actions: View>: View {
    init(_ title: String, systemImage: String, description: String? = nil,
         footnote: String? = nil, @ViewBuilder actions: () -> Actions)
}
extension MorbEmptyState where Actions == EmptyView  { init(_:systemImage:description:footnote:) }
extension MorbEmptyState where Actions == Button<Text> {
    init(_ title: String, systemImage: String, description: String? = nil,
         footnote: String? = nil, actionTitle: String, action: @escaping () -> Void)
}
struct MorbBrandSymbol: View ; struct MorbNoMatches: View ; struct MorbLoading: View

enum MorbMotion { … }
extension Theme { static func animation(_ motion: MorbMotion, reduceMotion: Bool) -> Animation? }
extension View {
    func morbAnimation<V: Equatable>(_ motion: MorbMotion, value: V) -> some View
    func morbPulse(_ isActive: Bool, minimumOpacity: Double = 0.35) -> some View
}

enum MorbMarkGeometry { … }
struct MorbStackShape: Shape ; struct MorbOrbShape: Shape
struct MorbMark: View ; struct MorbSidebarHeader: View
```

`MorbNumber` is the monospaced-digit, fixed-width numeric — **every** figure in a scannable column
goes through it. `MorbMotion` + `Theme.animation(_:reduceMotion:)` is the single reduce-motion
path; no feature file reads `accessibilityReduceMotion` directly.

### 2.9 What `Theme.swift` still forwards (delete when the last call site is gone)

| Legacy | Forwards to | Call sites |
|---|---|---|
| `StatusDot` | `MorbStatusDot` | ~23 across the views |
| `Chip` | `MorbChip(_:symbol:tone:)` | many |
| `SectionLabel` | `MorbSectionHeader` | many |
| `Theme.cornerRadius` | `Theme.radiusCard` | — |
| `Theme.chipRadius` | `Theme.radiusChip` | — |
| `Theme.rowPadding` | superseded by row heights | — |

**Migrating a screen means retiring its forwards.** The forwards are deleted by the integrator in
the merge step, only once `grep -rn "StatusDot\|struct Chip\|SectionLabel"` returns nothing outside
`Theme.swift`.

---

## 3. Deltas the component layer still needs

Small, and all owned by the **integrator**, not by the three screen agents. Do these before the
parallel phase starts so nobody is blocked.

| # | Component | Change | Why |
|---|---|---|---|
| D1 | `MorbToolbar` | Add `MorbSearchField` or confirm `.morbScreen` wires `.searchable(text:placement:.toolbar)`. Currently no component owns search. | Every screen hand-rolls a search field (CRITIQUE §0). Six screens need it; none can build it independently without colliding. |
| D2 | `MorbRow` | Add `.morbSelection(isSelected:isFocused:)` distinguishing focused from unfocused selection. | CRITIQUE §1: one selection state means you cannot tell which pane has the keyboard. `Theme.selectionFill` exists; the *unfocused* variant does not. |
| D3 | `MorbCard` | Add a `MorbTableSection` or document that `Table` + `.tableStyle(.inset)` is the answer and `MorbCard` is not for tabular data. | Three agents will otherwise each invent a table wrapper. |
| D4 | `MorbGlass` | Add `func morbScrim() -> some View` for the palette backdrop. | CRITIQUE §8: no scrim. Belongs with the glass wrapper, not in `CommandPalette.swift`. |
| D5 | `Theme` | Add `text.tertiary` as a named token. Currently views reach for `.secondary` / `.tertiary` system colours ad hoc. | IDENTITY §2.3: three text levels, all ≥4.5:1. The near-invisible fourth level in Disk and engine-stopped comes from having no token. |
| D6 | `MorbMetric` | `MorbNumber`'s default `font: .subheadline` is a text style, not the 11pt monospaced-digit numeric of IDENTITY §3. Reconcile. | Otherwise columns still won't align. |

---

## 4. Where my independent pass differs from `docs/design/`

Flagging these so someone decides, rather than letting two specs drift. **I am not asserting the
existing values are wrong** — several are defensible and some are better than mine.

| Topic | `docs/design/` (as built in `Theme.swift`) | This pass (IDENTITY.md) | Recommendation |
|---|---|---|---|
| **`statusPaused`** | **Blue** `rgb(0.216, 0.337, 0.561)` | Amber `#8A5A00` | **Investigate.** Blue for "paused" is unusual, and the screenshots show paused rendered *amber*, so the shipped code and the new Theme already disagree. Pick one and make the screenshots match. |
| **`statusBusy` / `statusDegraded`** | busy = orange, degraded = yellow | degraded = orange-red, error = red | Existing split (busy vs degraded) is **better** than mine — it distinguishes "mid-transition" from "partially up". Keep the existing. |
| **Series palette** | indigo, teal, **violet**, amber, rose | indigo, teal, amber, **magenta**, slate, olive | **Take my change on violet.** Indigo and violet are ~40° apart and merge under deuteranopia. The existing doc mitigates by never placing them adjacent, which helps the bar but not the legend. Rose is close to my magenta — probably just adopt rose in violet's slot. |
| **Reclaimable rendering** | same hue at `seriesDimAlpha = 0.45` | vector diagonal hatching | **Take the existing.** "Hatching reads as a rendering artefact" is correct, and alpha survives greyscale. My hatching note is wrong. |
| **Radii** | 5 / 8 / 12 / 16 (concentric) | 6 / 8 / 12 / 20 | **Take the existing.** The concentric derivation (`radiusCard − space3`) is a better argument than my round numbers. |
| **Row heights** | 24 / 28 / 32 / 44 | 24 / 28 / 44 | **Take the existing** — it has a distinct table row (32) and group header (28). |
| **Spacing** | 6 values: 2/4/8/12/16/24 | 9 values | **Take the existing.** Six is more disciplined. |
| **Section header case** | — | sentence case, no leading glyph | **Take mine.** `MorbSectionHeader` accepts `symbol:`; the all-caps + glyph treatment is a top-5 critique finding. Default `symbol` to `nil` at every call site. |
| **Digest truncation** | not specified | 12 chars + copy | **Take mine.** `REPORT.md` known-gap #5. |

---

## 5. Per-screen application plan

Each entry: the concrete change, the component that does it, and the critique finding it closes.

### 5.1 App shell — `App.swift` (604 lines; contains `Sidebar` at :210, `DetailHost` at :391)

| Change | How | Closes |
|---|---|---|
| Sidebar becomes a real `NavigationSplitView` sidebar column with `.listStyle(.sidebar)` — remove the opaque painted background | structural; `.navigationSplitViewColumnWidth(min:196, ideal: Theme.sidebarWidth, max: 280)` | §1 opaque slab |
| Sidebar rows → `Theme.rowStandard`-driven, 28pt | `.morbRow(.standard)` | §1 44pt rows |
| Sidebar selection → `Theme.selectionFill` + `Theme.selectionRail` (3pt leading capsule) | existing tokens | §1 grey selection |
| Sidebar icons get per-item series colour + `.symbolRenderingMode(.hierarchical)` | IDENTITY §6.5 table | §1 dead icon column |
| Count badges → `MorbCountBadge` (or `.badge()`) | | §1 web pills |
| Engine footer block → `MorbSidebarHeader` / move to toolbar `.status` placement | `MorbToolbarStatus` | §1 welded footer |
| `.windowToolbarStyle(.unified)` on the `WindowGroup` | Scene modifier — **not** `.toolbarStyle` | §0 |
| Detail pane adopts `.inspector()` for the container detail | `Theme.inspectorWidth/Min/Max` already defined | §0 |

### 5.2 Containers list — `ContainersRootView` (428), `ContainersChrome` (234), `ContainerListRow` (273 ✅ already migrated)

| Change | How | Closes |
|---|---|---|
| Delete the painted header; one `.morbScreen(title: "Containers", subtitle:)` | `MorbToolbar` | §0 |
| Search → `.searchable(placement: .toolbar)` (needs D1) | | §0 |
| "All / Running" → real segmented `Picker` in `MorbToolbarGroup.navigation` | | §0 two custom controls |
| "Prune stopped" → `Button(role: .destructive)` in the overflow menu | `MorbIconButton(role:)` | §0 |
| Row height fixed at `Theme.rowRich` (44); ports collapse to `MorbOverflowChip` | `MorbRichRow` | §11 |
| Delete the 9pt CPU/memory glyphs; CPU + memory via `MorbNumber` | | §11, §3.2 |
| Group headers → `MorbGroupHeader(state:running:total:)` | | §2 fraction pill |
| Separators inset to content | `MorbRowDivider` | §11 ragged edge |
| Focused vs unfocused selection (needs D2) | | §1 |

### 5.3 Container detail — `ContainerDetailView` (272), `ContainerOverviewTab` (597), `ContainerInspectTab` (341), `ContainerInspectDetails` (401), `ContainerMountRow` (167)

| Change | How | Closes |
|---|---|---|
| Move Stop / Restart / Pause / More into the **toolbar** | `MorbToolbarGroup.actions` + `MorbToolbarGap` | §0 |
| Overview/Logs/Stats/Inspect → real `Picker(.segmented)`, matching the list's control | | §0 |
| All section headers → `MorbSectionHeader`, **sentence case, `symbol: nil`** | | §3.1 |
| Configuration list → `MorbKeyValue` | | §2, alignment |
| Image ID → 12-char digest + copy button | | §5, REPORT gap #5 |
| State chips → one `MorbStatusBadge` + `MorbChip(rank:)`; kill the third outlined-with-icon variant | | §2 |
| Ports `Open` link → `Theme.accent`, not blue | | §3 |
| Env rows → `Table` with `.contextMenu(forSelectionType:)`; one reveal control, not 7 | | §10 |

### 5.4 Logs — `ContainerLogsTab` (353), `ContainerLogStore` (286), `LogPipeline` (226), `AnsiSGR` (283)

**Do not touch the ANSI renderer.** It is the app's best asset (CRITIQUE, "what must survive").

| Change | How | Closes |
|---|---|---|
| Toolbar strip → `.morbScreen` + toolbar items | `MorbIconButton` for trash/copy/share | §13 |
| Follow / Times → toolbar toggles | | §13 |
| Floating "N new lines ↓" ↔ Follow pill morph | `MorbGlassCluster` + `.morbGlassID(_:in:)` | IDENTITY §5.1 |
| **Viewport stays opaque** — `Theme.contentBackground`, no glass, ever | | IDENTITY §4.2 |
| `.morbScrollEdge(.hard, for: .top)` | wraps `scrollEdgeEffectStyle(.hard,…)` | REPORT gap #2, clipped first line |
| Live-lines indicator: stop using status green | pick a neutral/`accent` tone | §13 green collision |
| stderr wash must not extend under the gutter | | §13 |
| Gutter → `logGutter` role, recedes via structure not faintness | | §13 |
| Add ⌘F find | `.keyboardShortcut` | §13 |

### 5.5 Stats — `ContainerStatsTab` (365), `ContainerStatsHub` (211)

| Change | How | Closes |
|---|---|---|
| Cards → `MorbCard` | | §14 radii |
| Axis labels → `MorbNumber` at the `axis` role | | §3.2 |
| **No glass on plot areas** | | IDENTITY §4.2 |
| Values tick with `.morbAnimation(.numeric, value:)` | | IDENTITY §5.1 |

### 5.6 Stacks — `StacksRootView` (446)

| Change | How | Closes |
|---|---|---|
| `.morbScreen(title: "Stacks", subtitle:)` | | §0 |
| Bordered cards → `MorbCard` (L2 fill, **no border, no shadow**) | | §12, IDENTITY §4.3 |
| Project header → `MorbGroupHeader` | | §12 |
| Up / Restart / **Down** — Down gets `role: .destructive`; disabled Up gets real disabled styling | `MorbIconButton(role:)` | §12 |
| Service rows → `Theme.rowStandard` (28), aligned columns | `MorbRichRow` | §6.2 |
| Fill the empty 45%: a project summary section, or accept and document | REPORT gap #1 | §12 |

### 5.7 Images — `ImagesRootView` (689), `TrackCChrome` (474), `TrackCImageList` (182), `TrackCImageArchitecture` (234)

| Change | How | Closes |
|---|---|---|
| `.morbScreen(title: "Images", subtitle:)`; delete `TrackCChrome`'s painted header | | §0 |
| **Delete the 18 trash + 18 info buttons**; move to `.contextMenu(forSelectionType:)` + toolbar | | §10 |
| Pull field → toolbar item or a sheet, not a bar wedged above the table | | §10 |
| "In use" column: one language — `MorbCountBadge` for all rows incl. zero | | §10 |
| **Remove status dots from images** — images have no run state | | §10 |
| `.tableStyle(.inset)`; `TableColumnCustomization` binding; multi-select | | §10 |
| Size / Created → `MorbNumber` | | §3.2 |

### 5.8 Volumes (438) · Networks (395)

Same treatment, same components: `.morbScreen`, `Table` + `.tableStyle(.inset)`,
`.contextMenu(forSelectionType:)`, `MorbNumber` for sizes and counts, `MorbChip(rank:)` for the
`anonymous` / built-in badges, `MorbEmptyState` when empty. Both are ~40% empty at 900pt
(REPORT gap #1) — decide summary-section or shorter shot, and write it down.

### 5.9 Disk — `DiskRootView` (621), `TrackCDiskMath` (531), `TrackCConfirmSheet` (165)

**`TrackCDiskMath.swift` is computation, not presentation — leave it alone.**

| Change | How | Closes |
|---|---|---|
| `.morbScreen(title: "Disk", subtitle:)` | | §0 |
| Hero number → `MorbMetric` | | §14 |
| Series order per IDENTITY §2.5; resolve violet/rose (§4) | `Theme.series` — never index by hand | §2.5 |
| Legend rows 60 → `Theme.rowCompact` (24); per-row Prune → context menu | | §6.2 |
| Largest-images/volumes bars → `MorbMeter` | | |
| **Fix the rendered backticks** in the VM-image prose; cut to a footnote | | §5 ← *highest-embarrassment, lowest-effort fix in the whole plan* |
| VM disk path → `text.tertiary` (≥4.5:1), monospaced, with a copy action | needs D5 | §4 |
| **No glass on the bar** | | IDENTITY §4.2 |

### 5.10 Settings — `MorbSettingsView` (564), `TrackDConfigEditor` (261), `TrackDSharingSettings` (270)

The largest single convention win in the app.

| Change | How | Closes |
|---|---|---|
| **Delete Save and Revert.** Settings apply immediately | | §7.1 |
| Hand-built cards → `Form` + `.formStyle(.grouped)` | | §7.3 |
| Segmented strip → `TabView` with toolbar tabs, or a `NavigationSplitView` sidebar | | §7.2 |
| Slider rows → grouped `LabeledContent`; delete the 9pt endpoint ticks | | §7.3 |
| Prose paragraphs → short footnotes under the control | | §7 |
| Size the window to its content | | §7.4, REPORT caveat |
| **No glass in a Form** | | IDENTITY §4.2 |

### 5.11 MenuBar — `MorbMenuBar` (600), `TrackDChrome` (316), `TrackDAppBridge` (142)

| Change | How | Closes |
|---|---|---|
| Rows 80 → `Theme.rowStandard` (28). Popover ~1500pt → ~560pt | `.morbRow(.standard)` | §9 |
| Header may take `.morbGlass(.bar, radius:)`; body rows opaque | | IDENTITY §4.1 |
| Fix inverted hierarchy: container name is primary, the loopback address is not | | §9 |
| CPU % → `MorbNumber` (monospaced digit, fixed width) | | §9, §3.2 |
| Bottom commands → real `Divider()` + `Button` + `.keyboardShortcut` | | §9 |
| Keep the `+N more` overflow — it is good | `MorbOverflowChip` | |
| **`TrackDChrome.TrackDTone.init(_:)` switches exhaustively over `StatusTone`** — see §6 | | |

### 5.12 Command palette — `CommandPalette` (426), `PaletteCommands` (399), `FuzzyMatcher` (224)

**Do not touch `FuzzyMatcher.swift`** — it is algorithm, it has tests, and it is not a design
problem.

| Change | How | Closes |
|---|---|---|
| Add a scrim behind the panel (needs D4) | `.morbScrim()` | §8 |
| Panel → `.morbGlassPanel()` at `Theme.radiusPanel` (16) | | §8 |
| Present/dismiss → glass materialize transition, reduce-motion aware | `.morbAnimation` | IDENTITY §5.1 |
| **Differentiate the result icons** — 11 identical glyphs is the worst offender | icon per command *kind*, from `PaletteCommands` | §8 |
| Reserve the `↩` slot on every row so the trailing edge stops jittering | | §8 |
| Delete the decorative leading `⌘` glyph | | §8 |
| Footer hints → `text.tertiary` at ≥4.5:1 | needs D5 | §4 |
| Rows at `Theme.rowRich` (44) | | §6.2 |

### 5.13 Kubernetes / Builds — `PlaceholderView` (91)

There is **no** `Views/Kubernetes/` directory. Kubernetes and Builds are both sidebar items served
by `PlaceholderView`.

| Change | How | Closes |
|---|---|---|
| Placeholder → `MorbEmptyState(_:systemImage:description:footnote:)` — no lavender circle, no pill CTA | | §6 |
| Replace the off-weight Kubernetes wheel glyph with a real SF Symbol at the neighbours' weight | | §1 |

---

## 6. The one cross-track landmine

`Theme.StatusTone` has **five** cases and no `degraded`. `MenuBar/TrackDChrome.swift`
(`TrackDTone.init(_:)`) switches over it **exhaustively**.

**Therefore: `Theme.swift` and `Design/**` are frozen during the parallel phase.** If a screen agent
needs a sixth status case, it does not add one — it files against the integrator, who lands it
together with the `TrackDChrome` update in a single serialized change. This is written into
`Theme.swift`'s own doc comment already; it is repeated here because it is the one edit that can
break a track an agent cannot see.
