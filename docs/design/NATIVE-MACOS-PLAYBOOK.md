# Native macOS playbook

**Status:** binding implementation standard for the native-content migration.

This document exists because "uses SwiftUI" is not the same thing as "feels like a
Mac app". Morbstack is a desktop operations tool. Its visual language must come from
macOS's window, toolbar, sidebar, table, inspector, form, menu, and empty-state
components. Product code supplies domain data and actions; it must not redraw the
operating system around them.

This supersedes the *visual* premises in the older design documents where they conflict
with this one. In particular, `Theme.swift` and `Design/**` are not a visual API to
preserve. They may retain nonvisual semantics (status classification, formatting, safe
actions), but they are not a reason to keep a custom card, chip, toolbar, button,
selection, or surface.

## The bar

At a glance, a full Morbstack window should look like a restrained, data-dense native
macOS app: Finder/Xcode/Activity Monitor in the frame, with Docker-specific data in the
content. It should **not** look like a web dashboard rendered inside a window.

The most valuable test is subtraction: if the view still communicates its hierarchy,
selection, actions, loading state, and empty state after removing custom fills, pills,
shadows, rounded rectangles, bespoke spacings, and static tints, it is probably using
the right native structure.

## Evidence and current audit

The current source already gets the shell mostly right:

- `App.swift` uses a real `WindowGroup`, `.windowToolbarStyle(.automatic)`, a two-column
  `NavigationSplitView`, and `List(selection:)` with `.sidebar`.
- The sidebar's default selection and its system-managed collapse interaction are
  intentionally retained. They are the successful reference behavior for the rest of
  the app.

The content layer is the problem. The following files create an app-specific visual
system that competes with macOS rather than extending it:

| Custom visual layer | Why it reads as web UI | Native replacement |
| --- | --- | --- |
| `Theme.swift` palette, fixed spacing/radius scales, hand-painted surfaces | Creates a second light/dark material and mismatched contrast inside a native window | Dynamic system colors and the default surfaces; use only semantic text styles and system accent behavior |
| `Design/MorbGlass.swift` button, material, cluster, and bottom-bar wrappers | Places authored glass and shaped controls in content instead of letting system chrome compose it | System toolbar/navigation/sidebar; ordinary `Button`, `Menu`, `ControlGroup`, sheet, or popover as appropriate |
| `MorbCard`, `MorbChip`, `MorbMetric`, `MorbNumber` | Cards, pills, and dashboard metrics add an iOS/web presentation layer to desktop data | `Table`, `List`, `GroupBox` only when there is a real independent group, `LabeledContent`, `Text.monospacedDigit()` |
| `MorbStatusBadge` and `MorbStatusDot` | Repeated colored capsules make metadata louder than data and selection | Short status text or `Label` with an SF Symbol; reserve system semantic color for exceptional state, never as a tile fill |
| `MorbEmptyState`, `MorbNoMatches` | Wrapper encourages branded/hand-styled empty screens | Direct `ContentUnavailableView` and `ContentUnavailableView.search(text:)` |
| `MorbToolbar*`, `MorbIconButton` | Custom hover backgrounds, arbitrary placements, and manually sized hit areas break toolbar grouping/overflow | Direct `ToolbarItem` with standard placements, `Button` and SF Symbol label; let the system provide size, grouping, and overflow |

The high-risk visible routes, in order, are Containers (dense custom list/detail/log
chrome), Disk (dashboard bar/cards), Stacks, Volumes/Networks, Kubernetes, the global
error banner, menu-bar content, command palette, and settings. Images and Builds have
native-table rewrites in the worktree but still need a real-window review before they
are accepted.

## Architecture rules

### 1. Keep the native frame native

- Use `WindowGroup` plus `.windowToolbarStyle(.automatic)` so Tahoe selects the current
  titlebar and toolbar metrics.
- Keep `NavigationSplitView` for primary navigation and default `.sidebar` `List` for
  the navigation column. Never override its selection color or animate a replacement.
- Use `.inspector(isPresented:)` for a selected record's optional trailing details.
  Do not simulate an inspector with `HStack`, a divider, and a custom panel.
- Put a screen title/subtitle, search, and commands in the navigation title and real
  window toolbar. Never draw a header bar inside scrolling content.
- Do not put important operations in a bottom bar. A small status-only footer is the
  exception, not a second toolbar.

### 2. Match the data shape to the system container

| Domain shape | Component | Morbstack examples |
| --- | --- | --- |
| Flat, sortable records with multiple facts | `Table` with native selection/sort/context menu | Images, volumes, networks, build cache, Kubernetes resources |
| Hierarchical records | `OutlineGroup`/outline-style presentation or an AppKit `NSOutlineView` only if SwiftUI cannot supply needed desktop behavior | Compose project → service; Kubernetes hierarchy |
| One selected record's metadata and controls | `Form` and `LabeledContent` in an inspector | Image/build/container details, VM disk facts |
| A few editable preferences | `Form`, `Section`, `Toggle`, `Picker`, `Slider` | Engine resources and sharing settings |
| No records, unavailable engine, failed query | `ContentUnavailableView`, `ContentUnavailableView.search(text:)` | Every empty or filtered resource route |
| Destructive or infrequent actions | Toolbar overflow, contextual menu, confirmation dialog | Prune, remove, inspect/copy commands |
| Logs/code-like content | Native scrolling text plus a restrained monospaced viewport | Logs and JSON inspection; no glass/card behind it |

`Table` is the default for Images, Builds, Volumes, Networks, Pods, and other
multicolumn operations data. It gives the user native column headers, sorting,
selection, context menu behavior, scrolling, and column resizing. Do not reproduce any
of these with a `ScrollView` full of `HStack`s. Use a `List` only when rows have a
single primary label and variable narrative content; use a collection only when images
are the actual content rather than decoration.

### 3. Treat Liquid Glass as supplied navigation chrome, not a texture

- Do not put glass, material, gradients, or hand-drawn translucent cards behind a
  table, form, log, chart, or other dense scrolling content.
- Do not add a second background on top of `NavigationSplitView` detail content. Let the
  window and its semantic system surfaces resolve light/dark/key/inactive appearance.
- Do not tint normal toolbar controls or construct pill-shaped toolbar buttons. Use
  symbol-only `Button`s with a label for accessibility, and let the system group them.
- **On a route with an inspector, put every trailing item in `.primaryAction`.**
  Measured on Volumes at 1600×1000 (UI-051): a `.secondaryAction` item is centred in
  the *content* region, so it drifts by half the inspector's width on every toggle
  (135 pt) and lands nowhere in particular, while `.primaryAction`/`.automatic` items
  right-align against the search field and do not move at all. Mixing the two is what
  produced the "three detached islands" the user reported. Narrow windows still behave:
  at 900 pt the search field collapses to its glyph and six primary items all survive.
  Use `ToolbarSpacer(.fixed)` — not a different placement — to break the glass between
  a bare destructive button and a constructive one.
- If a floating presentation is genuinely needed (for example a command palette), use
  a system sheet/panel/popover and a single, availability-gated Liquid Glass treatment
  only at that navigation layer. Nothing nested inside gets another glass or material.

### 4. Color, typography, and density

- Honor the user's macOS accent color in navigation and ordinary controls. Do not force
  brand purple into selection, buttons, table rows, or icons.
- Use color sparingly and semantically: normal data is primary/secondary/tertiary text;
  exceptional state can use a system semantic color plus an SF Symbol and words. Never
  use status color as a filled chip, dashboard tile, or the only signal.
- Use the system's default fonts, row height, control size, focus rings, disabled state,
  and dynamic colors. Use `.monospacedDigit()` for live numeric values and a monospaced
  font for identifiers, paths, ports, and log payloads.
- Prefer concise row text. Let selecting a row reveal rich detail in an inspector rather
  than making every list row a mini dashboard.
- A custom `GroupBox` is permissible only for a genuinely separate, compact group; it
  is not a default page layout. No card grid on window background for operations data.

### 5. Controls and actions

- Use `Button`, `Toggle`, `Picker`, `Menu`, `ControlGroup`, confirmation dialogs,
  `SettingsLink`, and context menus before considering a custom control.
- A Toggle describes a durable binary preference or service state. It must not be used
  as an oversized screen-level call-to-action; start/stop lifecycle controls belong in
  a normal toolbar/menu action with confirmation where warranted.
- Use SF Symbols at their default toolbar rendering. Every symbol-only action needs an
  accessibility label and a help string, but no authored hover capsule/background.
- A visible content region gets at most one obvious primary action. Secondary commands
  belong in the toolbar overflow/contextual menu; destructive commands use
  `Button(role: .destructive)` and a confirmation dialog.

## SwiftUI/AppKit boundary and dependencies

The default stack is **dependency-free**:

- SwiftUI for the scene graph, split view, tables, forms, inspectors, commands, search,
  settings, menus, and unavailable states.
- AppKit only for a capability SwiftUI cannot provide reliably (window lifecycle and
  capture plumbing, AppKit-native table/outline behavior, focus/first-responder details,
  or an `NSPanel`-class command surface if a sheet proves wrong after real-window review).
- Observation for models, `OSLog` for diagnostics, `ServiceManagement` when the signed
  app legitimately enables its login item, and `Charts` only for real time-series data
  that cannot be read better in a table.

Do **not** add a third-party design system, custom component kit, CSS-like token library,
glass library, or screenshot renderer to solve native feel. Those add a second visual
language and are the problem we are removing. A narrowly-scoped AppKit bridge is better
than a UI library when a production-critical interaction truly exceeds SwiftUI.

Before adding such a bridge, write down: (1) the missing system behavior, (2) why a
native SwiftUI component cannot perform it, (3) the smallest AppKit API that does, and
(4) the accessibility/keyboard/selection behavior it inherits. No bridge exists merely
to repaint a component.

### Practical experience and known traps

These are implementation cautions from experienced macOS developers, not substitutes
for Apple HIG:

- SwiftUI toolbars are composed from the view tree and their final arrangement can be
  less obvious than source placement. Keep a route's toolbar small, use semantic
  placements (`.primaryAction`, `.secondaryAction`, `.navigation`), and judge the real
  narrow window rather than trying to position a custom toolbar manually.
- A custom `HSplitView` may appear to solve a right-inspector problem, but it loses the
  native inspector's collapse, restoration, toolbar relationship, and surface. Start
  with `.inspector`; use `NSSplitViewController` only if a documented editor-class
  requirement survives real-window evaluation.
- `SwiftUI.Table` is the first choice, not a compromise. Escalate to `NSTableView` or
  `NSOutlineView` only for a measured large-data/performance issue or a required feature
  such as Finder-grade outline behavior, drag/reorder semantics, advanced inline
  editing, or column behavior that the system `Table` cannot provide.
- `TableStyle` is a system choice, not a branded styling hook. Start automatic, then
  inspect the actual WindowServer-composited route. If automatic produces the Tahoe
  inset/rounded empty-row treatment that makes a dense operational grid read as
  skeleton/dashboard UI, prefer the system `.bordered` style before considering any
  custom drawing; it retains native column, selection, resize, and accessibility
  behavior while avoiding inset-style rows. The choice must be recorded and rechecked
  in light/dark and narrow windows. [TableStyle](https://developer.apple.com/documentation/swiftui/tablestyle)
- Do not use `SwiftUI-Introspect` for appearance. Its own documentation notes that its
  view-hierarchy search can stop finding a component as SwiftUI evolves. A direct,
  small AppKit bridge is more explicit and removable if the system API has a real gap.
- Test snapshots of a hosted/offscreen view are useful for data/layout regressions only.
  The test strategy for window chrome is a macOS XCUITest host that launches fixtures,
  navigates by accessibility identifier, and attaches
  `app.windows.firstMatch.screenshot()`; Computer Use remains the human visual signoff.

This makes the tooling hierarchy clear: component snapshots < fixture-driven UI tests <
an actual WindowServer-composited human review. No automated layer is allowed to hide a
bad native frame behind a plausible inner-content PNG.

## Screen-by-screen target state

1. **App shell and sidebar** — preserve current `NavigationSplitView`/sidebar behavior;
   remove manual overlay/bottom-chrome decoration if it fights the system material.
2. **Containers** — a default `Table` for containers; selected container in a native
   inspector or detail split; overview/inspect as `Form` + `LabeledContent`; logs as a
   sober text viewport. Delete fake headers, port/status pills, metric cards, and custom
   segmented controls.
3. **Images, Volumes, Networks, Builds** — one native `Table` each, standard search,
   toolbar pull/refresh plus overflow prune, and an inspector form. Empty states have
   a real action, not motivational product copy.
4. **Disk** — a compact facts form/table, not a colored storage dashboard. If a usage
   chart is still justified, use `Charts` with a declared common scale and accessible
   table equivalent; never use decorative progress bars as page furniture.
5. **Kubernetes** — native tables and inspector forms. Replace the giant switch with a
   normal lifecycle action; resource rows must use real selection and context menus.
6. **Stacks** — hierarchy/table semantics, not grouped cards. Compose and service
   actions are contextual and safely confirmed.
7. **Settings, command palette, menu bar** — use the standard Settings scene/tab
   behavior, a native floating presentation only when required, and concise menu-bar
   rows. These are part of the app frame and get a separate real-window review.

## Choose the content form, not a house style

Native macOS is not a mandate to put every route in a table. The application should
feel like a coherent workstation, not an Activity Monitor clone. Start from the
person's immediate task and the shape of the information, then choose the smallest
system presentation that lets them complete it.

| User task and data shape | Native presentation | Morbstack examples | Avoid |
| --- | --- | --- | --- |
| Scan and compare many peer records across stable attributes | Sortable, resizable `Table` | Containers, local images, volumes, networks, build-cache entries | Cards, arbitrary row fills, or a table whose columns do not answer a comparison question |
| Work through an actual parent → child structure | Outline/table with disclosure or a purpose-built detail split | Compose project → service → container; Kubernetes hierarchy | Flattening relationships into repeated tables or nested cards |
| Create or revise a focused configuration | `Form` in a sheet/window; standard controls and clear apply/revert semantics | Resources, file sharing, CLI setup, future run/configuration flow | Dashboard controls, giant toggles, or an always-visible configuration column |
| Edit source text that must retain user fidelity | Document-oriented `TextEditor`/AppKit text view with Save, Revert, dirty state, and a plain source preview | Compose YAML and `.env` workflows | Lossy “visual YAML” builders, autosave-to-deployment, cards pretending to be an editor |
| Review one selected operational object | System trailing `.inspector` with `Form` and `LabeledContent` | Image facts, container overview, volume/network properties | A permanent hand-painted right panel or a metric-card grid |
| Read an evolving command/result stream | Monospaced scrolling text viewport with selection, search, copy, and clear lifecycle state | Container logs, build progress, inspect JSON | Decorative terminal chrome, tinted panels, fake streaming or a chart without a question |
| Understand a real trend, comparison, or capacity question over time | Swift Charts plus an accessible textual/table equivalent | Container statistics, build-duration trend, measured storage history | A colored “health” dashboard or progress bar used as decoration |
| Begin with nothing, a failed query, or unavailable capability | `ContentUnavailableView` with one honest, safe next action | No local images, no Compose document selected, unavailable registry query | Blank panes, motivational copy, fabricated counts, or disabled fake buttons |

The main window can mix these presentations. A Compose route, for example, should
combine an outline for project hierarchy, a source editor for selected YAML, and an
inspector only for metadata; forcing all three into a table loses the user's mental
model. Conversely, Containers is a natural table because the default task is comparing
many peer processes by name, image, state, ports, and age. Apple's table guidance
supports tables for sortable multi-attribute productivity data and recommends a
collection when items vary widely in size or imagery; that distinction is binding for
future routes. [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)

Real-window review must reject a route when it has become visually repetitive: a field
of uniform rows, rectangular bands, or empty stripes is not justified merely because
it uses `Table`. Confirm that row count and background follow the system's table
behavior at the current OS release, that empty space reads as a content surface rather
than skeleton UI, and that the route could not be explained more clearly by an outline,
form, editor, inspector, or unavailable state.

## Migration sequence

1. **Freeze custom visual expansion.** No new `Morb*` visual component, custom fill,
   card, chip, hover background, or hard-coded design token may be introduced.
2. **Remove source of the second design system.** Separate nonvisual semantics from
   `Theme.swift`/`Design/**`; mark visual wrappers deprecated and remove their use route
   by route. Do not delete shared files until call sites are gone and a serialized build
   passes.
3. **Rebuild the primary workflows first.** Containers, Images/Builds, Disk, Kubernetes,
   Stacks, then Volumes/Networks. Each route is rebuilt as system container + data
   adapter, not cosmetically restyled.
4. **Finish frame surfaces.** Error presentation, first-run, settings, command palette,
   menu bar. Apply real functionality before polish; eliminate "soon," fake, or
   speculative AI-style copy.
5. **Accessibility and keyboard pass.** Keyboard selection, focus rings, menus,
   destructive confirmations, tooltips/accessibility labels, dynamic type, Increase
   Contrast, and light/dark/inactive windows.
6. **Delete the obsolete visual API and stale design directives.** Update old design
   documents to point here; do not leave contradictory rules that invite regression.

The reconciliation set is known: `docs/design/REWRITE-PLAN.md` currently protects the
custom visual system, and `docs/design/DECISIONS.md` still asks an offscreen harness to
decide titlebar/toolbar correctness. `docs/design/pass2/**`, `docs/build.md`, `mise.toml`
(`shots-live`), capture-related `LaunchOptions` comments, and container compatibility
comments must be rewritten or archived as part of step 6. Do this only after the new
real-window acceptance flow is exercised; do not preserve bad design to satisfy an
invalid bitmap test.

## Acceptance gate: judge the real window, not synthetic inner images

An `NSView.cacheDisplay` or `ImageRenderer` bitmap is not an acceptable visual test for
Tahoe material, unified titlebars, traffic lights, sidebars, inspectors, or Liquid
Glass. The capture tool must label that output diagnostic-only and fail instead of
writing a deceptively credible screenshot.

For each changed route, launch the actual app in both system appearances and inspect the
full window using Computer Use. At 1440×900 and at the minimum supported size, verify:

- traffic lights/title/subtitle/toolbar render as one native frame;
- the sidebar retains default selection and its good collapse/reveal interaction;
- a real table/list has native row selection, sort, column resize, keyboard movement,
  contextual actions, and no hand-drawn row treatment;
- opening/closing an inspector is native, resizable, and leaves the toolbar to overflow
  controls itself;
- content uses the native dark/light window surfaces with no flat custom contrast seam;
- empty/search/error states use a system hierarchy and offer the next safe action;
- no control is an unexplained colored pill, custom card, decorative progress bar, or
  fake toolbar; and
- no destructive path is activated during visual validation.

Only then run one serialized `swift build`; do not compete with an existing `xctest` or
launch multiple expensive builds. Automated screenshot regression work may resume only
after it can capture the window-server-composited frame or is explicitly scoped to
layout/accessibility rather than visual-material approval.

## Source basis

First-party guidance, consulted 2026-08-02:

- Apple HIG: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Windows](https://developer.apple.com/design/human-interface-guidelines/windows), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), and [Color](https://developer.apple.com/design/human-interface-guidelines/color).
- SwiftUI: [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [Table](https://developer.apple.com/documentation/swiftui/table), [Form](https://developer.apple.com/documentation/swiftui/form), [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview), and [ContentUnavailableView.search(text:)](https://developer.apple.com/documentation/swiftui/contentunavailableview/search%28text%3A%29).
- Tahoe: [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), [NSTableView](https://developer.apple.com/documentation/appkit/nstableview), [NSOutlineView](https://developer.apple.com/documentation/appkit/nsoutlineview), [XCUIScreenshot](https://developer.apple.com/documentation/xcuiautomation/xcuiscreenshot), and [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).

Experience-based sources, reviewed 2026-08-02 and deliberately nonbinding:

- [AppKit vs. SwiftUI on macOS](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/) and [Making a Mac app in SwiftUI? Reach for AppKit.](https://tagavari.me/blog/swiftui-vs-appkit/) reinforce the hybrid escalation rule; neither justifies replacing working SwiftUI indiscriminately.
- [Three-column SwiftUI on macOS](https://msena.com/posts/three-column-swiftui-macos/) documents the custom-split/inspector tradeoff.
- [SwiftUI Introspect](https://swiftpackageindex.com/siteline/swiftui-introspect) documents the narrow workaround class that we are explicitly declining for visual styling.
- [Point-Free SnapshotTesting](https://github.com/pointfreeco/swift-snapshot-testing) is an optional future **test-only** component-regression tool; it is not a WindowServer screenshot solution.

---

## Toolbar grammar: a window toolbar with a trailing inspector

Written 2026-08-06 as the fifth pass at UI-051, and written the way the previous four
were not: **every claim below is either a measurement off a real window or a citation.**
Where a note in this file or in a source comment used to say the opposite, the old text
is quoted and marked wrong, because acting on those notes is part of how this took five
attempts. Nothing here may be edited from memory.

Method: `./scripts/capture-window.sh <out.png> <AppName>` (WindowServer's own composited
buffer for one named window — see `CLAUDE.md` §1.6), then per-pixel column and row scans.
Stock-SwiftUI control captures come from `docs/design/probes/ToolProbe.swift`, which
imports nothing from Morbstack.

### 1. Is the toolbar overlapping the inspector a defect? No. It is the composition.

The question every previous attempt assumed away. Measured, dark, 1600×1000 windows:

| | Xcode 26.4 | stock SwiftUI probe | Morbstack (Volumes) |
| --- | --- | --- | --- |
| toolbar spans the full window width | yes | yes | yes |
| inspector column begins at | x 1340 | x 1200 | x 1200 |
| inspector toggle sits at | x 1562–1591 | x 1560–1589 | x 1560–1589 |
| …i.e. above the inspector column | **yes** | **yes** | **yes** |
| divider colour *inside* the toolbar band (y 5–60) | `455052` | `444f51` | `424f53` |
| divider colour *below* it (y 70–400) | `455052` | `444f51` | `424f53` |
| divider runs the full window height | **yes, one constant tone** | **yes** | **yes** |
| toolbar background, sidebar side | `23292a` | `23292a` | `22292c` |
| toolbar background, content side | `2a3235` | `2b3235` | `2a3236` |
| toolbar background, inspector side | `23292a` | `23292a` | `23292c` |
| inspector background below the toolbar | `23292a` — identical | `23292a` — identical | `23292c` — identical |
| centred toolbar item, inspector open → closed | 1041–1249 → 911–1119 (**moves 130 = ½ the inspector**) | `.secondaryAction` moves ½ the inspector | n/a |
| trailing item, inspector open → closed | 1562–1591 → 1562–1591 (**0**) | 0 | 0 |

Read that table as three findings.

1. **Xcode's inspector toggle is above its inspector column, and nothing else is.** The
   toolbar is one full-width bar; the inspector's leading divider runs up through it to
   the top of the window; the toggle is the last item at the window's trailing edge.
   Our arrangement is the same arrangement.
2. **The toolbar's material differs per region in Xcode too**, and by about the same
   amount. Sidebar and inspector regions share a tone, the content region is lighter.
   That is not us; it is what a translucent bar over three different backdrops looks
   like. "The material changes at the divider" is not a defect to chase.
3. **The inspector's own background is continuous from the top of the window to the
   bottom, behind the toolbar, in all three.** The inspector does not begin below the
   toolbar; it begins at the top of the window and the toolbar floats on it *by design*.

So: **an item pinned to the window's trailing edge sits above the inspector column, and
that is the platform's intended composition, not our bug.** Do not open a sixth ticket
to move it. Verified against Apple's own IDE and against stock SwiftUI on the same
machine, same OS build (macOS 26.4, 25E246), same day.

Two supporting observations from other Apple apps, same capture method:

- **Finder** (`Finder.app`, list window): full-width toolbar, sidebar divider running to
  y 0, sidebar region holding only the traffic lights, and **search rendered as a glyph
  in its own capsule at the trailing edge**. Four capsules across a wide content region:
  back/forward · view-mode segmented · arrange menu · share/tag/more · search.
- **Font Book**: the *sidebar* toggle sits inside the sidebar's own toolbar region, hard
  against the divider — the mirror of Xcode putting the *inspector* toggle above the
  inspector. Each pane's toggle hugs that pane's divider from that pane's side.
- **Preview** does not have a trailing inspector at all; its Inspector (⌘I) is a floating
  utility panel. Absence of evidence, recorded so nobody goes looking again.

Not measured, and still open: Pages / Numbers / Keynote are **not installed on this
machine**, so the "Format inspector" case in the ticket text could not be captured. If
they are ever installed, the one thing worth measuring is whether Pages puts more than
one item above the inspector column, because Xcode puts exactly one and we put four.

### 2. Where each placement actually lands

Probe `placementMap`, one numbered button per macOS `ToolbarItemPlacement`, captured
with the inspector open (divider x 1200, inspector 400pt) and closed:

| placement | open | closed | Δ | region |
| --- | --- | --- | --- | --- |
| `.navigation` | 236–271 | 236–271 | 0 | content region, leading edge |
| `.secondaryAction` | 697–732 | 897–932 | +200 | **centred in the content region** |
| `.destructiveAction` | 1014–1040 | 1114–1140 | +100 | floating, unanchored |
| `.principal` | 1060–1076 | 1160–1176 | +100 | floating, unanchored |
| `.status` | 1095–1120 | 1195–1220 | +100 | floating, unanchored |
| `.cancellationAction` | 1405–1431 | 1405–1431 | 0 | trailing run, sorted to its head |
| `.automatic` | 1451–1467 | 1451–1467 | 0 | trailing run |
| `.primaryAction` | 1488–1504 | 1488–1504 | 0 | trailing run |
| `.confirmationAction` | 1525–1541 | 1525–1541 | 0 | trailing run |
| `.accessoryBar(id:)` | — | — | — | second row under the bar, content-leading |

**There is no placement that pins an item to the *trailing edge of the content region*,
i.e. immediately left of the inspector divider.** Every placement that does not move
when the inspector toggles is in the one trailing run, and that run is over the
inspector. This is why "put the commands beside the inspector instead of over it" has
failed four times: it is not expressible. The choice is *over the inspector and still*,
or *left of it and drifting*. Still wins.

### 3. What orders the trailing run

Probe `runOrder`: five numbered items interleaving the two placements across the two
toolbar modifiers the routes actually use.

```
root toolbar:       1 .primaryAction   2 .automatic
inspector toolbar:  3 .automatic       4 .primaryAction   5 .primaryAction
```

Rendered: `1 2 3 4 5`, one capsule.

- Items declared on the **root's** toolbar render before items declared on the
  **inspector content's** toolbar.
- Within that, order is **declaration order**.
- `.automatic` and `.primaryAction` **do not sort against each other.**
- `.cancellationAction` is the one exception: it sorts to the head of the run
  (`placementMap`, where item 8 rendered first).

> **Wrong, now corrected in `VolumesRootView`:** *"`.automatic` lands in the same run but
> sorts before `.primaryAction`, so leaving the toggle on `.automatic` would silently put
> it left of search."* It does not. Use one placement for the whole run anyway — when
> order is only declaration order, a single placement is the only spelling in which the
> source reads in the same order as the bar.

### 4. What shares one glass capsule — and what makes a lone pill in the middle

Probes `spacerNone`, `spacerFixedDefault`, `spacerFixedPrimary`, `spacerFlexPrimary`,
`spacerSharedHidden`, `groupPair`, `groupPairSpacer`, `menuInRun`. Capsule fills read off
the capture at y 9:

| declaration | capsules |
| --- | --- |
| four adjacent `ToolbarItem`s + toggle | **one** (fill 1420–1574) |
| `ToolbarSpacer(.fixed)` between them, default placement | **one** — byte-identical trailing run |
| `ToolbarSpacer(.fixed, placement: .primaryAction)` | **one** — byte-identical |
| `ToolbarSpacer(.flexible, placement: .primaryAction)` | **one** — byte-identical |
| two `ToolbarItemGroup`s | **one** |
| two `ToolbarItemGroup`s + `ToolbarSpacer(.fixed)` | **one** |
| `sharedBackgroundVisibility(.hidden)` on an item | that item loses its glass entirely |
| a `Menu` mid-run (`A`, `Menu`, `B`, toggle) | **three**: `[A] [Menu] [B toggle]` |

> **Wrong, and it was in this repo's comments and in TASKS.md:** *"`ToolbarSpacer(.fixed)`
> … renders — verified, two adjacent capsules — and is the API Apple names for this."*
> It does not split a placement run on macOS 26.4. Five variants, byte-identical trailing
> runs. `VolumesRootView` already carries the correction.

**The rule that follows, and it is the whole of the "single pill in the middle"
complaint:** a placement run is one capsule, and *only a `Menu` splits it* — a `Menu` is
always its own capsule, with everything before it in one capsule and everything after it
in another. Therefore:

> **A route's `Menu` is declared first in the trailing run.** Then the run is always
> `[menu] [commands · search · inspector toggle]` — two capsules — and a capsule stranded
> between two others is structurally impossible rather than fixed once.

A second reason to put it first: on a route whose record commands appear only when a row
is selected, a mid-run menu makes the **capsule count change with the selection** (two
capsules with nothing selected, three with something selected). Menu-first keeps it at
two either way, so the bar stops re-fragmenting as you click down a list.

### 5. Slot order inside the run

Leading → trailing, narrowing scope, view controls last:

1. **collection menu** — infrequent, administrative, multi-choice (scope, refresh, prune).
   Its own capsule, by the platform.
2. **record actions** — act on the selection (start/stop, open terminal, export).
3. **collection actions** — act on the whole list; destructive before create, so a prune
   is never adjacent to a `+`. (Ordering is the only separation the platform gives —
   see §4; the spacer does nothing.)
4. **search** — a `magnifyingglass` glyph, `RouteSearchToolbarItem`. Settled and shipped;
   see `RouteToolbarSearch.swift` for why the field cannot be a system glyph on macOS.
5. **inspector toggle** — always last, hard against the window's trailing edge, mirroring
   Xcode.

`.principal` is for *what the window is showing*, not for a command: Builds' cache/history
picker and Kubernetes' resource picker. It is unanchored (§2) and drifts when the
inspector toggles; that is acceptable for a scope picker and not acceptable for a command.

### 6. Per-route inventory

Measured off real 1600×1000 dark windows on 2026-08-06 (`before-*` captures). "Pills" is
the capsule count in the trailing run.

| route | `.principal` | trailing run, in render order | pills | grammar |
| --- | --- | --- | --- | --- |
| Containers | — | `options`(Menu) · `primaryLifecycle` · `openTerminal` · `runCommand` · `search` · `inspector` | 2 | **fixed this pass** — menu moved to the head; was 3 with a row selected, 2 without |
| Stacks | — | `primaryLifecycle` · `actions`(Menu) *or* `project-actions`(Menu) · `options`(Menu) · `search` · `inspector` | 2 empty / up to 4 selected | **queued** — two menus, one of them a record action; needs a decision, not a reorder |
| Images | — | `runLocal` · `pruneDangling` · `explorePublic` · `pull` · `archive`(Menu) · `search` · `inspector` | 3 | **queued** — `archive` is a record menu; moving it to the head changes its meaning |
| Volumes | — | `export` · `removeUnused` · `create` · `search` · `inspector` | 1 | conforms |
| Networks | — | `removeUnused` · `create` · `search` · `inspector` | 1 | conforms |
| Builds | `scope` picker | `options`(Menu) · `start` · `inspector` | 2 | conforms; toggle moved `.automatic` → `.primaryAction` this pass |
| Kubernetes | `resources` picker | `refresh` · `actions`(Menu) · `inspector` | 2 | menu is last, so two capsules; route is separately broken (see UI-051 notes) |
| Disk | — | `recalculate` · `inspector` | 1 | conforms; no search — Disk has nothing to filter |
| Migration | — | `refresh` · `inspector` | 1 | conforms; no search and **no inspector column** |

Routes genuinely differ and the grammar does not pretend otherwise:

- **No search** is honest on Disk and Migration: neither presents a filterable collection.
  Do not add a glyph that filters nothing.
- **No inspector** on Migration means its toggle has no column to sit above; the trailing
  run is then simply at the window's edge, which is the same rule with the inspector
  width at zero.
- **`.principal` pickers** on Builds and Kubernetes are the route's subject, not a
  command, and are the one thing that legitimately lives in the centre region.

### 7. What yields as the window narrows

Measured at 1600 → 1100 → 900 on the worst case (Images, six trailing items) in the
2026-08-05 pass and unchanged by this one: every control is present at 1100. At 900 the
system collapses the search *field* to a glyph and keeps all six items; nothing clips and
no control is lost. With `RouteSearchToolbarItem` search is already a glyph at rest, so
the narrow case now starts from a smaller run than the one that was measured.

### 8. `TabView` must not be the inspector's content container

Found this pass, reproduced in stock SwiftUI, **not yet fixed** — see the queued ticket.

`TabView` draws a bordered content box. Inside `.inspector` that border lands exactly on
chrome the window already draws: its leading edge overdraws the inspector divider, its
trailing edge overdraws the window border. Column scan at the divider, x 1200, 1600×1000
dark:

| inspector content | y 1–63 | y 66–995 |
| --- | --- | --- |
| `Form` (probe `inspectorForm`) | `444f51` | `444f51` — constant |
| `TabView` (probe `inspectorTabView`) | `444f51` | **`61686b`** |
| `TabView` + `.tabViewStyle(.grouped)` | `444f51` | **`61686b`** — no help |
| `TabView` + `.tabViewStyle(.sidebarAdaptable)` | `434d50` | `434d50` — but it renders a whole sidebar inside the 400pt inspector |
| segmented `Picker` + switch (probe `inspectorPickerPanes`) | `444f51` | `444f51` — constant |
| Morbstack Containers, a container selected | `435054` | **`646a6c`** |
| Morbstack Volumes | `424f53` | `424f53` — constant |
| Xcode | `455052` | `455052` — constant |

The consequence is the one thing in this app that genuinely reads as "a panel that starts
below the toolbar": the inspector's leading edge is ~30 levels brighter from the toolbar's
lower edge down, and its content sits in a rounded card with a visible top-left corner.
Only Containers and Builds do this, and only when a record is selected.

There is no API to remove a `TabView`'s border — the macOS 26.4 SDK exposes
`.automatic`, `.grouped`, `.sidebarAdaptable`, `.tabBarOnly`, `.page`, `.verticalPage`,
`.carousel` and nothing that suppresses the box. **Apple's own inspectors do not use a
tab container**: Xcode's inspector is a segmented control at the top of the column with
the pane below it, which is what `inspectorPickerPanes` reproduces cleanly.

Do not convert `ContainerDetailView`/Builds to a `Picker` casually: `Tab` carries the
`containers.detail.tab.*` accessibility identifiers that
`MorbstackFixtureUITests` queries by, and a segmented `Picker`'s options do not carry
per-segment identifiers reliably. That is the work the queued ticket is for.
