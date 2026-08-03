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

- `App.swift` uses a real `WindowGroup`, `.windowToolbarStyle(.unified)`, a two-column
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

- Use `WindowGroup` plus `.windowToolbarStyle(.unified)`.
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
  symbol-only `Button`s with a label for accessibility; place one primary action at the
  trailing edge and low-frequency actions in `.secondaryAction` so macOS owns overflow.
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
