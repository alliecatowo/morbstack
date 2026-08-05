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

## Taste review is a loop, not a report

A defect register answers "is this broken". Nothing in this repo answered "is this any good", and
the two questions need different reviewers — a bug hunter grades against a spec, and taste has no
spec to grade against.

`.claude/agents/taste-reviewer.md` is that reviewer. Three things about it are deliberate:

**It judges from real screenshots, never from source.** Reading SwiftUI tells you what is drawn, not
what it feels like. Every prior UI misjudgement in this project came from reasoning about code
instead of looking at the window.

**Its scope is constrained by this document, and that is what makes it useful.** It may not
recommend custom chrome, tokens, gradients or materials on navigation — that road was taken once and
the verdict was "vibecoded as fuck". So within a system-native vocabulary, taste is **density,
hierarchy, restraint, information architecture, presentation and cross-route rhythm** — what we
choose to show and how we arrange it, never how we paint it. That constraint is a feature: it rules
out the entire class of "make it pop" advice.

**It runs twice, and the second pass is the point.** Pass 1 files `TASTE-` tickets. Pass 2 re-captures
the same screens after they land and asks whether each change actually improved the screen or merely
satisfied the letter of the ticket. **It is explicitly allowed to say a fix made things worse.** A
one-shot review is a wish list; a loop is a standard.

Every finding is marked `LAW` (follows from this document or the HIG, not negotiable) or `TASTE`
(opinion, argue with it). Conflating the two is how a preference gets enforced as a rule.
