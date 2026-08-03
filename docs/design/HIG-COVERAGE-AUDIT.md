# HIG coverage audit

**Status:** active migration and review gate. Every visible route must be audited against
the semantic guidance below before visual implementation is accepted.

This is not a component shopping list. Apple's Human Interface Guidelines describe the
purpose, hierarchy, interaction, platform behavior, accessibility, and personalization
requirements of each pattern. The implementation rule is therefore:

> Name the user task and UI semantic first. Read the linked Apple guidance. Use the
> system pattern/API it calls for. A custom view requires a written, tested reason that
> neither SwiftUI nor a narrow AppKit bridge can satisfy the requirement.

The app is a long-running, data-dense desktop operations tool. Its default is a
resizable native window, keyboard-first commands, data selection, a contextual
inspector, and accessible tables—not an iOS-style card page or a browser dashboard.
That follows [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
and Apple's [design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles).

## Required decision matrix

| Semantic need | Apple guidance to read | Default native implementation | Explicitly reject |
| --- | --- | --- | --- |
| Window frame, resizing, active/inactive state | [Windows](https://developer.apple.com/design/human-interface-guidelines/windows) | `WindowGroup`, unified toolbar, system window background | Painted titlebars, content pretending to be chrome |
| Top-level navigation | [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) | `NavigationSplitView` + `List(.sidebar)` | Custom left rail, custom selection, sidebar overlay button |
| Dense operational records | [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Table](https://developer.apple.com/documentation/swiftui/table) | Sortable/selectable `Table`, native columns/context menu | ScrollView of cards, hard-positioned `HStack` rows, fake table header |
| Actual hierarchy | [Outline views](https://developer.apple.com/design/human-interface-guidelines/outline-views) | `Table(children:)`/`OutlineGroup`; narrow `NSOutlineView` bridge only if required | Nested cards or custom disclosure layout |
| Selected-record metadata | [Inspectors WWDC23](https://developer.apple.com/videos/play/wwdc2023/10161/) and [Form](https://developer.apple.com/documentation/swiftui/form) | `.inspector(isPresented:)` containing `Form` + `LabeledContent` | Permanent hand-built right column, card grid of properties |
| Main commands and overflow | [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) | Symbol toolbar buttons, one primary action, `.secondaryAction`, matching menu/shortcut | In-content fake toolbar, colored/pill buttons, hand-managed overflow |
| Record-specific or infrequent action | [Menus](https://developer.apple.com/design/human-interface-guidelines/menus) | Context menu or `Menu`, selected-record toolbar action | Tiny hover-only icons or action columns with no label |
| Search/filtering a collection | [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), [Searching](https://developer.apple.com/design/human-interface-guidelines/searching) | `.searchable` with a truthful scope prompt; immediate filtering; `ContentUnavailableView.search(text:)` | In-content fake search bar, static scope pills not tied to search |
| Short choice, input, preference | [Pickers](https://developer.apple.com/design/human-interface-guidelines/pickers), [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles), [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | `Picker`, `Toggle`, `Slider`, `TextField` in an appropriate `Form` | Giant lifecycle switch, custom segmented control, settings card/dashboard |
| Destructive or irreversible work | [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | Concise confirmation dialog/alert or a scoped review sheet with Cancel + destructive role | Magic-wand action, destructive operation without scoped review, alert for non-actionable information |
| Small, transient related task | [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) | System popover with a few related controls | Mini workflow/dashboard in a popover |
| Empty, loading, unavailable, failed content | [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview) | Direct system unavailable/search state with one honest next action | Branded illustration, speculative AI copy, blank table |
| Progress | [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) | `ProgressView` only for real in-flight/determinate work | Decorative spinner/bar or a progress bar used as a dashboard hero |
| Data over time/comparison | [Charts](https://developer.apple.com/design/human-interface-guidelines/charts), [Charting data](https://developer.apple.com/design/human-interface-guidelines/charting-data), [Swift Charts](https://developer.apple.com/documentation/charts) | Swift Charts marks/scales/axes/summary/accessibility, with a textual or tabular equivalent | Colored storage bar, hand-drawn sparkline, chart with no question or accessible summary |
| Palette, material, color, motion | [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Color](https://developer.apple.com/design/human-interface-guidelines/color) | System surfaces/colors; glass only in system navigation/control layer | Content material, hand-tinted dark surface, status chips/tiles, nested glass |
| Keyboard, focus, VoiceOver, contrast, motion | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection), [VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover) | Native control/accessibility tree, system focus and selection, labels/help, reduced motion | Custom hover/focus/selection rendering, color-only state, inaccessible icon action |

`Progress indicators` is retained as a HIG link even if a screen does not need one;
the reviewer must decide “not applicable” rather than introduce a bespoke loading state.

## Whole-codebase route audit

Each row must reach **implemented + live-window verified** before the native migration
is complete. “System component present” alone is not enough; the system component must
be performing the behavior described by the HIG. “Native rewrite staged” means source is
being migrated in the worktree; it is explicitly **not** visual acceptance, typecheck
evidence, or proof that a real daemon workflow works.

| Route/source | Semantics that must be reviewed | State | Current direction |
| --- | --- | --- | --- |
| `App.swift`: window, sidebar, global errors, engine-off, diagnostics recovery | Windows, sidebar, toolbar, alerts, unavailable states, menu commands, focus/accessibility | Native source implementation — serialized real-window verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel). Preserve the system sidebar collapse/selection; no manual error chrome or unnecessary custom footer. An engine-error `ContentUnavailableView` exposes the existing offline `MorbDiagnostics` collector as a recovery action: an explicit parent-folder Open panel is cancellable before any write, then a small indeterminate `ProgressView` represents the collector’s unknown duration. The service never contacts or starts the daemon/Docker, creates only a new redacted reviewable directory, and has no cancellation contract, so the UI provides no false in-flight Cancel action. A native success/failure alert reports the actual result; success offers Show in Finder and never uploads or shares. Swift syntax parsing and `git diff --check` completed; fixture/XCUITest/Computer Use acceptance remains blocked by the active work order forbidding builds and UI automation. |
| `FirstRunCLISetup.swift` | Onboarding, sheets, forms, picker, toggles, progress, status/feedback, privacy/consent, accessibility | Native rewrite staged — live-window verification pending | HIG/API read: [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Pickers](https://developer.apple.com/design/human-interface-guidelines/pickers), [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Form](https://developer.apple.com/documentation/swiftui/form), [Picker](https://developer.apple.com/documentation/swiftui/picker), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). Use a normal `Form` review sheet; the default-off per-user-service toggle explains registration, does not register during status/launch, and applies only from explicit confirmation. A visible radio picker distinguishes host-only setup from the selected one-time Morbstack start; the confirmation title changes to match. The real in-flight work uses `ProgressView`; after the explicit start, a bounded read-only readiness check and `/_ping` either prove Docker healthy or expose a repair action that repeats only that confirmed start/check phase. Completion uses `LabeledContent`, not custom status cards. |
| `Settings/**` | Settings, forms, text fields, pickers, toggles, sliders, toolbar panes, keyboard | Native rewrite staged — live-window verification pending | Use stable settings panes/toolbar and real preferences; audit every control and disabled state |
| `MenuBar/**` | Menus, menu-bar extras, popovers, commands, accessibility | Native rewrite staged — live-window verification pending | Compact information and actual actions in a system-owned presentation |
| `Palette/**` | Search, menus/commands, sheets or panel modality, keyboard focus, accessibility | Native rewrite staged — live-window verification pending | A standard sheet is acceptable when a global command has no stable popover anchor; avoid a decorative Raycast clone. A destructive result never executes from a single Return: it must pass through a system confirmation dialog. |
| `Views/Containers/**` | Tables, inspector, forms, logs/text, context menus, toolbar/search, Charts, progress, unavailable states, destructive actions | Native rewrite staged — live-window verification pending | Main list/detail is table + inspector. Statistics is read-only: CPU/memory history and network throughput use real `/containers/{id}/stats` values, with `LabeledContent`, Swift Charts, Audio Graphs, and exact sample tables. Network throughput is derived only from complete monotonic counters; stopped, priming, missing, and reset data use system unavailable/progress states rather than placeholder values or a start action. |
| `Views/Images/**` | Tables, inspector, search, pull popover, image archive export, destructive image actions | Native source implementation — serialized real-window verification pending | HIG/API read: [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Panels](https://developer.apple.com/design/human-interface-guidelines/panels), [Form](https://developer.apple.com/documentation/swiftui/form), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), [FocusedValueKey](https://developer.apple.com/documentation/swiftui/focusedvaluekey), and [NSSavePanel](https://developer.apple.com/documentation/appkit/nssavepanel). The native `Table`/inspector path keeps selection context authoritative. Image archive export is a symbol-only secondary toolbar command with matching Image-menu, contextual, and inspector actions. `NSSavePanel` selects an explicit destination and owns replacement confirmation; the document-modal `Form` shows actual bytes, a determinate `ProgressView` only when Docker supplies total bytes, and a standard Cancel action. No custom destination, progress percentage, or archive-success claim is fabricated. Swift syntax parsing and `git diff --check` completed; real-engine, accessibility, and light/dark/narrow fixture/XCUITest/Computer Use evidence remain blocked by the active work order forbidding builds, UI automation, and live Docker operation. |
| `Views/Builds/**` | Cache-record selection, local-build command/confirmation, indeterminate progress/cancel/recovery, inspector, search, global cache prune, unavailable/history state | Native source implementation — serialized real-window verification pending | HIG/API read: [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), [Form](https://developer.apple.com/documentation/swiftui/form), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview). BuildKit cache is a flat operational collection, so use one sortable `Table`, native search, selection, context menu, and a system inspector/form. A local folder is a deliberate build command: a system sheet + `Form` selects it; the confirmation states that Dockerfile instructions execute in the VM and that the app will not push. The bundled Docker/Buildx client preserves Docker’s actual context/.dockerignore semantics and streams raw JSON, so the sheet uses only an indeterminate `ProgressView` plus observed output, a standard Cancel action, and retry after an actual failure. No count-only percent or fake completion is shown. `/system/df` is cache, not durable history, and Docker exposes only a broad `POST /build/prune`; the app labels that boundary and does not offer per-record delete or synthesize history. Build result/empty/cache, confirmation, progress/cancel, failure/retry, keyboard/focus, accessibility names/help, and light/dark/narrow sheet/table/inspector behavior require the pending serialized fixture/XCUITest/Computer Use pass. See [`docs/builds.md`](../builds.md). |
| `Views/Volumes/**`, `Views/Networks/**` | Tables, inspectors, context menu, search, destructive confirmation | Native rewrite staged — live-window verification pending | Retain native record behavior without visual wrappers. Multi-volume and multi-network removal reviews enumerate the exact captured names or IDs and execute only those individual Docker deletes; a count-only confirmation is not sufficient. |
| `Views/Stacks/**` | Tables or actual outline hierarchy, selected detail, contextual lifecycle actions, destructive confirmation | Native rewrite staged — live-window verification pending | Do not simulate project/service hierarchy with cards; prove the selected hierarchy matches actual data |
| `Views/Kubernetes/**` | Tables/outline decision, selected-record inspector, search scopes, read-only description/progress/retry, lifecycle actions, menus, confirmation | Native rewrite staged — live-window verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Table](https://developer.apple.com/documentation/swiftui/table), [Panels](https://developer.apple.com/design/human-interface-guidelines/panels), [Form](https://developer.apple.com/documentation/swiftui/form), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), [Inspectors](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview). Pods and nodes are flat operational collections, so use a sortable `Table`, native selection/search, and the system inspector. A selected record retains summary metadata and adds a bounded, daemon-owned `k8s-describe` GET in its inspector `Form`; a native `ProgressView`/retry state makes that independent read truthful without hiding table data, logs, or events. The daemon accepts only a selected DNS-style Pod or Node reference, checks Ready/forward/kubeconfig prerequisites without creating them, then reads Morbstack's credential-pinned loopback API. It returns bounded metadata, facts, conditions, labels, and annotations—not arbitrary paths, objects, Secret data, watches, logs, exec, port forward, or a workload mutation. `morb k8s describe` consumes the same typed payload, while app and CLI report update-skew through the additive-command restart requirement. The app's direct log/event reads remain separate and read-only. No Docker log cross-link exists until a canonical pod/container identity exists. The route uses native `Table`, system inspector, `Form`, `LabeledContent`, `ProgressView`, and toolbar/menu behavior only; no cards/materials/custom glass. Source/typecheck, real-engine, accessibility, and real-window light/dark/narrow Computer Use evidence remain pending because the active work order forbids builds, UI automation, and live cluster operation. |
| `Views/Disk/**` | Table, inspector/form, capacity progress, prune review, Charts decision | Native rewrite staged — live-window verification pending | One storage table; a factual `ProgressView` only; no hero consumption bar. Image/container/volume cleanup uses a scoped review sheet. Build cache has no per-record Docker delete, so Disk routes to Builds for review and does not expose Docker’s broad global cache prune. |
| `Views/Migration/**` | Source readiness, operational-record selection, scoped import review, progress, report/retry, unavailable state | Native rewrite staged — live-window verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Table](https://developer.apple.com/documentation/swiftui/table), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Form](https://developer.apple.com/documentation/swiftui/form), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview). Runtime inspection stays read-only in a selectable `Table` with a system inspector `Form`. The selected-runtime inspector presents the independent, GET-only named-volume eligibility comparison in a native `Table`: eligibility is limited to absent local-driver names, while existing destinations and unsupported drivers retain their explicit reasons. It never inspects contents, free space, emptiness, overwrite safety, or merge behavior, and it exposes no volume-transfer command. An explicit `Select Images to Import…` command opens a document-modal `Table` with an **empty** selection, then re-prepares the exact selected references and presents a second scoped review sheet before `ImageMigrationTransaction.execute` can write to Morbstack. This is a sheet, not an alert, because the user must inspect records, endpoint, excluded scopes, and cancellation behavior; an alert remains reserved for a failure that has an actionable dismissal. Real per-image work uses the typed service’s determinate `ProgressView` and safe `Stop Remaining Images` action; no dashboard progress treatment. The report table retains verification/detail evidence. Retry reopens a fresh selection/review only for failed or cancelled items; `requires_review` is never auto-retried. The route uses system tables/forms/sheets/toolbars only—no custom glass, cards, content materials, or inferred `--all` action. The source stays GET-only; containers, Docker configuration, credentials/helpers, and registry access remain excluded. Source/typecheck, real-engine, accessibility, and real-window light/dark evidence remain pending because the active work order forbids builds, UI automation, and live Docker mutation. |
| `Design/**`, `Theme.swift` | Materials, color, controls, focus/selection, accessibility | Removal staged — source verification pending | Keep only nonvisual domain semantics temporarily; eliminate routine rendering policy |
| `Shots/**`, `LiveCapture.swift`, `mise.toml`, `mac/UITests/**` | Windows, accessibility/UI testing, visual validation | Synthetic renderer retired; real-window evidence harness in place | Foundation-only fixture invariants plus a text-only real-window route probe; the standard XCUITest host launches the assembled shipping bundle for WindowServer screenshots and accessibility evidence, followed by Computer Use |

## Charts audit: current concrete rule

`ContainerStatsTab` currently contains the only real time-series visualization. It is
allowed to use Swift Charts because CPU and memory history answer a temporal question;
network throughput is likewise derived from consecutive Docker interface counters, not
invented samples. It still requires a separate HIG pass before acceptance:

1. State the user question in its title/subtitle (for example, current CPU with recent
   history), not just “CPU.”
2. Use marks, a comprehensible scale, restrained grid/axis labeling, and an honest
   domain; don’t hide every axis if that makes readings unknowable.
3. Supply chart title, descriptive summary, and mark context so VoiceOver/Audio Graphs
   can communicate the trend and values.
4. Avoid a decorative colored area fill or arbitrary brand color. Color must distinguish
   meaningful series, not make the chart look branded.
5. Keep the latest precise values/limits in `LabeledContent` and never require chart
   interaction to reveal critical state. Network counters must remain explicitly
   unavailable when an Engine response omits an interface value, and an interval that
   resets a cumulative counter must be omitted rather than rendered as negative or zero
   traffic.

Disk storage has no time-series model today, so it does **not** earn a chart. A native
table plus the one capacity `ProgressView` answers its actual task more truthfully.

## Implementation and review protocol

Before changing a route:

1. List each visible interaction and map it to a row in the decision matrix.
2. Read the corresponding Apple HIG page and the SwiftUI/AppKit API documentation.
3. Record any nondefault decision (for example, `Table` versus outline; popover versus
   sheet; Charts versus table) in the route’s handoff or this audit.
4. Implement with direct system APIs. A visual wrapper must be deleted or have a written
   exception with owner and removal condition.
5. Validate keyboard, selection, destructive confirmation, accessible naming, dark/light,
   Increase Contrast, Reduce Transparency, and narrow-window toolbar overflow.
6. Launch fixture data in a real app window and review it with Computer Use. An offscreen
   image cannot pass a window/material/sidebar/toolbar check.
7. If a route represents a runtime fact (for example a mount, published port, or engine
   lifecycle state), verify the Engine-facing contract separately. Native visual
   hierarchy must never make an unverified service capability look usable.

For each route, record a compact review card before calling it complete:

| Field | Required record |
| --- | --- |
| User task | The concrete job the person is trying to do, not the view name |
| HIG/API read | Direct Apple links consulted for every visible semantic |
| Native choice | The system container/control selected and the behavior it inherits |
| Rejected alternative | Why cards, a custom control, a fake toolbar, or a generic dashboard is wrong here |
| Exception | AppKit/custom code only: the missing system behavior, owner, accessibility behavior, and removal condition |
| Evidence | Build/typecheck, real-window dimensions/appearance, keyboard/accessibility checks, and safe interaction result |

## Required evidence at handoff

- exact HIG/API pages consulted;
- a list of semantics covered and any documented exceptions;
- for an Engine-facing claim, the bounded protocol/daemon admission contract and its
  focused tests, including any intentionally unsupported request shapes;
- `git diff --check` and source parse/typecheck result;
- one serialized app build after the concurrent source work has settled; and
- the full-window acceptance result, including safe sidebar/table/inspector/search and
  accessibility interactions.

No future native UI change is accepted merely because it “looks better.” It must make
the app more correct according to the platform pattern the user is actually invoking.

## Native-window validation hierarchy

The validation policy follows Apple's guidance for [windows](https://developer.apple.com/design/human-interface-guidelines/windows),
[accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[XCTest UI tests](https://developer.apple.com/documentation/xctest/user_interface_tests), and
[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).

1. `MorbShots` checks deterministic fixture relationships only. It is Foundation-only
   and writes no images.
2. `--tour-capture` opens the actual fixture-backed app and records text-only route
   liveness. It has no visual, accessibility, interaction, or layout assertion.
3. Computer Use is the present full-window acceptance surface. Review the WindowServer-
   composited frame and accessibility tree in light/dark and normal/narrow dimensions,
   using only safe navigation, selection, search, inspector, and non-destructive menus.
4. The macOS XCUITest harness launches `--tour-fixtures` from the assembled shipping
   bundle, drives controls through their semantic accessibility representation, asserts
   keyboard/focus behavior, and attaches `XCUIElement` screenshots from the real app
   process for review. It is repeatable evidence, while Computer Use remains the final
   human judgment of full-window UX.

ScreenCaptureKit is a screen/window capture API, not an excuse to restore a private
offscreen renderer or to make compositor images the only assertion. It may support a
separately approved capture workflow later, but it does not replace XCUITest's semantic
accessibility assertions or Computer Use's human review. No self-cached image can pass a
titlebar, toolbar, sidebar, material, inspector, focus, or Liquid Glass acceptance gate.
