# Design decisions — current native macOS rulings

**Status:** binding where it resolves an ambiguity in the
[native macOS playbook](NATIVE-MACOS-PLAYBOOK.md) or the
[HIG coverage audit](HIG-COVERAGE-AUDIT.md). Both documents remain the broader
implementation standard.

## 1. System-native structure is the product visual language

Morbstack is a dense desktop operations tool, not a branded dashboard. Use the semantic
macOS structure the task calls for: `WindowGroup` and the unified toolbar for the frame,
`NavigationSplitView` plus a sidebar `List` for primary navigation, `Table` for
multi-column records, `.inspector` for selected-record metadata, `Form`/
`LabeledContent` for settings/details, standard menus and commands for actions, and
`ContentUnavailableView` for unavailable content. See Apple's [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/),
[Windows](https://developer.apple.com/design/human-interface-guidelines/windows),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and
[Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables).

This is a behavioral decision, not a cosmetic one: system controls provide keyboard
navigation, focus, selection, toolbar overflow/customization, appearance adaptation, and
accessibility semantics that a manually drawn equivalent cannot reliably recreate.

## 2. The custom visual system is retired

`Theme.swift` and `Design/**` may supply only narrowly-scoped, nonvisual domain helpers
while they are being removed (for example, an operational-state label or format helper).
They may not set colors, spacing, radii, typography, animation, content backgrounds,
selection, hover behavior, cards, chips, status badges, toolbar composition, or glass.
No replacement token library or compatibility wrapper is allowed.

In ordinary app content, respect the user's system accent and semantic system colors.
Express exceptional operational state with words and an SF Symbol; color is supplemental
and is never a status tile or filled chip. The asset brand palette remains for exported
brand/marketing art only, not native application chrome.

## 3. Liquid Glass is provided navigation/control chrome, never content texture

Let macOS supply the unified titlebar, toolbar, sidebar, inspector, sheets, menus, and
ordinary control treatment. Do not add a material, gradient, or glass background behind
tables, forms, logs, charts, or dense content. Do not stack custom glass on top of
system glass. A custom effect requires the documented exception process in the playbook
and must be a real missing system behavior, not a way to make an ordinary control look
different. See [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
and [Materials](https://developer.apple.com/design/human-interface-guidelines/materials).

## 4. Records, hierarchy, and charts follow the data—not decoration

- Multi-column operational records use sortable/selectable native tables.
- A real parent/child data model uses an outline treatment; groups are not simulated with
  stacked cards.
- Selecting a record reveals detail in a native inspector rather than inflating each
  table row into a dashboard.
- `ProgressView` represents actual in-flight or factual capacity progress only.
- Swift Charts are allowed only when the data answers a time-series or comparison
  question. They need an honest scale, accessible title/summary/Audio Graph treatment,
  and an exact textual/tabular alternative; a storage bar is not a chart.

The route-specific decision and its evidence belong in the HIG audit before review.

## 5. Commands are discoverable and safe

Use symbol-only toolbar actions where the toolbar is the right home, with an accessible
label and help text. Keep one contextual primary action; place infrequent actions in a
native `Menu`, context menu, or `.secondaryAction` so the system manages overflow. Every
important toolbar command has an equivalent menu-bar command/shortcut. A destructive
action has a scoped, truthful confirmation and destructive role. An engine lifecycle
operation is an action, not a giant decorative Toggle.

## 6. Visual evidence must be a real macOS window

The former offscreen `ShotRenderer`/`ShotWindow` path is retired. An AppKit/SwiftUI cache
or `ImageRenderer` cannot validate WindowServer-owned traffic lights, the unified toolbar,
sidebar/inspector material, focus, or Liquid Glass. `MorbShots` may validate deterministic
fixture invariants, but it produces no visual acceptance evidence.

Current signoff is Computer Use on the fixture-backed app in light/dark appearance and
normal/narrow dimensions, exercising safe navigation, selection, sorting, search,
inspector behavior, menus, and empty states without invoking destructive work. The durable
automated follow-up is a macOS XCUITest host with accessibility identifiers and
`XCUIElement.screenshot()` attachments from the real app process.

## 7. Historical decisions retained for context

The prior decisions about a Theme-authoritative color palette, custom `MorbGlass`
availability wrapper, status chips/dots, fixed density/radius scales, custom toolbar
groups, and synthetic screenshot acceptance are superseded—not silently deleted. Their
original rationale remains in the archived documents named by
[the design documentation index](README.md). They cannot override this document or
current Apple guidance.

The deployment target remains a release-engineering decision in `mac/Package.swift`.
Before introducing an availability-gated API, check that target and the actual SDK; do
not create a visual wrapper simply to centralize an API gate.

## 8. Inspectors are presented exactly when they describe something (Tahoe chrome ruling)

**Context.** After the macOS 26 deployment-target bump, the main window was reported as
"three detached slabs" — sidebar, content and inspector each apparently carrying its own
toolbar strip, with the traffic lights reading as a detached box and the window title
apparently painted into the content layer. Before changing anything, the boundary between
system behaviour and our defect was established empirically on this exact OS (macOS 26.4,
dark, 1440×900) against Finder, Font Book (Apple's own SwiftUI
`NavigationSplitView` app), and a from-scratch stock SwiftUI probe
(`NavigationSplitView` + `.inspector` + `.searchable(placement: .toolbar)` + the same
toolbar placements, zero Morbstack code).

**System behaviour — adopt, do not fight:**

- The **leading title + subtitle block above the content column** is Tahoe's titlebar
  treatment, not a title painted into content. Font Book draws "All Fonts / 362
  typefaces" in exactly the position and style our "Containers / 3 running · 16 total"
  appears. `.navigationTitle`/`.navigationSubtitle` on the detail column remain correct.
- The **traffic lights float over the sidebar's full-height glass pane**, which is inset
  with rounded corners at the window edges. Finder, Font Book, and the stock probe are
  pixel-equivalent to our window here. Nothing of ours detaches them.
- **When an `.inspector` is presented, Tahoe splits the toolbar glass at the inspector
  boundary** and hosts the trailing items (search, inspector toggle) above the inspector.
  The stock probe reproduces this with no Morbstack code. It is the same treatment
  Xcode's inspector area receives. It cannot be "fixed" without abandoning `.inspector`.
- `.windowToolbarStyle(.unified)` and `.automatic` render **identically** on Tahoe
  (probe-verified); the earlier `.unified` → `.automatic` change was not the regression.
- A single `.secondaryAction` item renders as a **small centred glass island**; the
  centre region is also where Finder and Font Book put their mid-toolbar controls.

**Ours, and wrong:** resting a route with an **open inspector and nothing selected**.
Nine routes launched with `showsInspector = true`; on routes with no selection at rest
(Containers, Stacks, Kubernetes) that produced a full-height empty glass slab, moved
search above a vacant pane, and fragmented the toolbar into three sections around
"No X Selected" — the entire reported regression. Finder rests as sidebar + one
continuous strip because nothing is inspecting anything.

**Ruling.** An inspector is presented exactly when there is a selection to describe, or
when the person explicitly opens it (toolbar toggle, View ▸ Show Inspector). Routes that
follow the Mail convention of auto-selecting their first record (Images, Volumes,
Networks, Builds, Disk, Migration) already satisfy this — their inspector rests
populated and stays as it was. Routes without an at-rest selection start with the
inspector closed and auto-present it on selection. Do not "fix" Tahoe's toolbar split
while an inspector with real content is open; that is the system drawing its chrome.

Sources: HIG Toolbars/Sidebars/Split views via `docs/design/tahoe/HIG-FINDINGS.md`
(inspectors use edge-to-edge glass beside the content; sidebars float above content;
avoid custom window UI), WWDC25 session 310. Evidence: real-window `screencapture -l`
composites of Morbstack (before/after), Finder, Font Book, and the stock probe app in
light and dark, 2026-08-05; `--tour-capture` real-window frames showing selection
auto-presenting a populated inspector; UI-049 in `docs/audit/UI-AUDIT.md`.
