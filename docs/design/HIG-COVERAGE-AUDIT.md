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

Each row must reach **implemented + explicitly scoped live-window verification** before
the native migration is complete. “System component present” alone is not enough; the
system component must be performing the behavior described by the HIG. “Native source
implementation” means the route's source was inspected for the system semantic pattern;
it is explicitly **not** visual acceptance, typecheck evidence, or proof that a real
daemon workflow works.

The dark-mode Computer Use record below is completed evidence only for its listed,
normal-width safe interactions. It does not establish route-wide acceptance, light
appearance, minimum-width behavior, keyboard/focus or VoiceOver traversal, Increase
Contrast/Reduce Transparency behavior, XCUITest coverage, or a real Engine mutation.
Those lanes are pending per route and must be serialized safely; builds and UI automation
are not categorically prohibited.

### Current real-window evidence ledger

The following observations are intentionally narrow. They establish that a real,
normal-width dark-mode application window displayed the named native system pattern
against local data; they do not approve unexercised actions or substitute for light,
narrow-width, keyboard, VoiceOver, contrast/transparency, motion, XCUITest, or mutation
evidence.

### 2026-08-03 WindowServer review: visual acceptance remains rejected

Computer Use inspected the actual running dark-mode main window and Images route. The
system-owned frame, `NavigationSplitView` sidebar, native toolbar/search field, table
selection, and trailing inspector all appeared in the accessibility tree and behaved
as macOS controls. Those are foundations to retain, not an acceptance result.

The rendered content still had a visibly repetitive, dashboard-like quality: the
Containers window showed rounded dark bands extending through unused table space, and
the Images route paired a dense inventory table with a visually heavy inspector/action
area. Regardless of whether a particular band originates in the current OS table
style, an old bundle, or a remaining view modifier, the route fails the product's
visual bar until the currently built source is inspected and the content reads as a
purposeful data browser rather than skeleton/dashboard residue. The earlier Settings
capture likewise must be re-run from a current bundle before its `Form`/`LabeledContent`
source can be accepted.

This finding changes the next review from “replace every route with a table” to
“choose the native content form that matches the task.” Tables remain appropriate for
flat, sortable operational records; source editors, outlines, forms, inspectors,
monospaced text views, charts with a real data question, and unavailable states are
equally first-class native choices. See the binding [task-shaped content guidance]
(NATIVE-MACOS-PLAYBOOK.md#choose-the-content-form-not-a-house-style). A clean,
serialized bundle build and the full light/dark/narrow review are still required
before any route receives visual acceptance.

| Route | Safe real-window observation | Still required before acceptance |
| --- | --- | --- |
| App frame | System sidebar collapse/reveal and engine-off recovery presentation | All appearance, keyboard/accessibility, diagnostics and recovery workflows |
| Containers | Selected stopped container in table and Overview inspector | Statistics/logs, lifecycle/menus/destructive workflows and broader checks |
| Images | Local image table/inspector; Pull sheet opened then dismissed | Search, export, pull, destructive workflows and broader checks |
| Builds | Empty cache state; Build sheet opened then dismissed | Cache selection, review/progress/cancel/retry and broader checks |
| Volumes | Local volume table selection and inspector wording | Archive/removal workflows and broader checks |
| Networks | Built-in network selection and managed inspector state | Search, context/destructive workflows and broader checks |
| Stacks | Actual project/service outline selection | Lifecycle/destructive workflows and broader checks |
| Kubernetes | Off-state diagnosis; Enable confirmation opened then cancelled | Enabled-cluster table/inspector/log/event workflows and broader checks |
| Disk | Storage table and review affordance | Confirmation/mutation and broader checks |
| Migration | Docker Desktop inventory table and inspector, read only | Reprepare/review/transfer flows and broader checks |

### Source-reconciliation note

Several table cells below retain the earlier phrase **“Native rewrite staged.”** That is
a historical progress label, not an assertion that a different visual system remains in
the worktree. Source review has since confirmed the principal routes use direct system
patterns (`NavigationSplitView`, sidebar `List`, `Table`/outline, `.inspector`, `Form`,
`LabeledContent`, `.searchable`, and `ContentUnavailableView`). Their acceptance state
remains pending until the evidence named in each row exists. The former `Theme.swift`
and `Design/**` visual system was removed in `c6f7825`; source discovery finds no
replacement Theme, Design, Style, or Appearance rendering module.

| Route/source | Semantics that must be reviewed | State | Current direction |
| --- | --- | --- | --- |
| `App.swift`: window, sidebar, global errors, engine-off, diagnostics recovery | Windows, sidebar, toolbar, alerts, unavailable states, menu commands, focus/accessibility | Native source implementation — partial dark real-window evidence recorded; broader verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel). Preserve the system sidebar collapse/selection; no manual error chrome or unnecessary custom footer. An engine-error `ContentUnavailableView` exposes the existing offline `MorbDiagnostics` collector as a recovery action: an explicit parent-folder Open panel is cancellable before any write, then a small indeterminate `ProgressView` represents the collector’s unknown duration. The service never contacts or starts the daemon/Docker, creates only a new redacted reviewable directory, and has no cancellation contract, so the UI provides no false in-flight Cancel action. A native success/failure alert reports the actual result; success offers Show in Finder and never uploads or shares. The recorded dark Computer Use pass covers sidebar collapse/reveal and engine-off recovery only. Light/narrow, keyboard/accessibility, XCUITest, diagnostics collection, and real daemon recovery evidence remain pending. |
| `FirstRunCLISetup.swift` | Onboarding, sheets, forms, picker, toggles, progress, status/feedback, privacy/consent, accessibility | Native rewrite staged — live-window verification pending | HIG/API read: [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Pickers](https://developer.apple.com/design/human-interface-guidelines/pickers), [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Form](https://developer.apple.com/documentation/swiftui/form), [Picker](https://developer.apple.com/documentation/swiftui/picker), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). Use a normal `Form` review sheet; the default-off per-user-service toggle explains registration, does not register during status/launch, and applies only from explicit confirmation. A visible radio picker distinguishes host-only setup from the selected one-time Morbstack start; the confirmation title changes to match. The real in-flight work uses `ProgressView`; after the explicit start, a bounded read-only readiness check and `/_ping` either prove Docker healthy or expose a repair action that repeats only that confirmed start/check phase. Completion uses `LabeledContent`, not custom status cards. |
| `Settings/**` | Settings, forms, text fields, pickers, toggles, sliders, toolbar panes, keyboard | Native source implementation — live-window verification pending | **User task:** inspect or change a durable application preference, not scan a dashboard. **HIG/API read:** [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [Form](https://developer.apple.com/documentation/swiftui/form), [FormStyle](https://developer.apple.com/documentation/swiftui/formstyle), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles), and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). The system `Settings` scene and `TabView` own stable pane navigation. The views use `Form`, `Section`, `LabeledContent`, standard controls, and explicit review/apply semantics; forced `.formStyle(.grouped)` was removed because it produced the rounded in-content row clusters observed in the real dark window. `.automatic` restores the platform-selected macOS form treatment instead of replacing one custom visual system with another. General, Resources, Sharing, and Advanced still need current-bundle light/dark/narrow, keyboard, VoiceOver, contrast/transparency/motion, control-state, and mutation-confirmation review before acceptance. |
| `MenuBar/**` | Menus, menu-bar extras, popovers, commands, accessibility | Native rewrite staged — live-window verification pending | Compact information and actual actions in a system-owned presentation |
| `Palette/**` | Search, menus/commands, sheets or panel modality, keyboard focus, accessibility | Native rewrite staged — live-window verification pending | A standard sheet is acceptable when a global command has no stable popover anchor; avoid a decorative Raycast clone. A destructive result never executes from a single Return: it must pass through a system confirmation dialog. |
| `Views/Containers/**` | Tables, inspector, forms, logs/text, context menus, toolbar/search, Charts, progress, unavailable states, destructive actions | Native rewrite staged — partial dark real-window evidence recorded; broader verification pending | Main list/detail is table + inspector. Statistics is read-only: CPU/memory history and network throughput use real `/containers/{id}/stats` values, with `LabeledContent`, Swift Charts, Audio Graphs, and exact sample tables. Network throughput is derived only from complete monotonic counters; stopped, priming, missing, and reset data use system unavailable/progress states rather than placeholder values or a start action. The recorded dark Computer Use pass covers selecting one stopped container and its Overview inspector; it does not verify statistics, logs, lifecycle changes, menus, or destructive actions. Light/narrow, keyboard/accessibility, XCUITest, and those real-engine workflows remain pending. |
| `Views/Images/**` | Tables, inspector, local filtering, public repository discovery, pull sheet, image archive export, bounded local-image run, destructive image actions | Native source implementation — partial dark real-window evidence recorded; broader verification pending | **User task:** inspect the local Docker image inventory; separately discover a public repository without initiating a pull; or create and start one container from an explicitly selected already-local image. **HIG/API read:** [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), [Form](https://developer.apple.com/documentation/swiftui/form), [DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup), [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), and [NSSavePanel](https://developer.apple.com/documentation/appkit/nsopenpanel). The local path is a sortable selected-record `Table` plus the system inspector at `340/400/460`; the bordered table style remains a narrow system-only visual hypothesis pending current-bundle Computer Use review. The inspector is an automatic `Form`: architecture is a scalar `LabeledContent`, a consequential mismatch receives one concise Compatibility section, and secondary Repo Tags use a count-labelled `DisclosureGroup` collapsed on selection. It has no duplicate command buttons, cards, custom materials, or manual layout. Pull Image is the first, truthful local-empty-state action; Refresh is secondary. Selected-record archive, run, copy, and removal commands live in the Image menu, contextual menu, and selection-aware toolbar; removal retains explicit confirmation. `.searchable` filters only local images. Public discovery stays a separate explicit system sheet, with no typed remote search, automatic pull, custom registry, credential, custom glass, card, or material behavior. The recorded dark Computer Use pass covers local-image table/selection/inspector and an opened then dismissed Pull sheet; it does **not** cover public discovery or local-image run. Light/dark/narrow, keyboard/focus/VoiceOver, contrast/transparency/motion, toolbar overflow, XCUITest, archive/run/remove/pull workflows, and real Docker evidence remain pending. |
| `Views/Builds/**` | Cache-record selection, local-build command/confirmation, indeterminate progress/cancel/recovery, inspector, search, global cache prune, unavailable/history state | Native source implementation — partial dark real-window evidence recorded; broader verification pending | HIG/API read: [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Pickers](https://developer.apple.com/design/human-interface-guidelines/pickers), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), [Form](https://developer.apple.com/documentation/swiftui/form), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview). The native Cache/History picker makes two separate Buildx collections explicit: BuildKit cache is a flat operational collection, while Buildx history contains only completed-build records returned by the active builder. Each uses a sortable `Table`, native search, selection/context menu, and a system inspector. Switching to History and its refresh control invoke only the read-only `refreshBuildHistory()` path; it is never requested on app launch and cache rows are never inferred as history. Selecting a history row performs no inspection: the inspector begins as a direct `ContentUnavailableView`, then the explicit **Load Details** action runs a bounded `buildx history inspect --format=json` for that selected reported ID only. Its loading state is a cancellable system `ProgressView`; the resulting `Form`/`LabeledContent` renders only JSON fields Buildx returned, never cache-derived values, attachments, export/import/open/remove controls, or a fabricated completion measure. Only after that inspected record loads does **Load Logs** run a separate bounded `buildx history logs --progress rawjson` read for the same selected ID. It has its own cancellable `ProgressView`/error state and presents only actual stdout in a selectable native scroll view; a retained 4 MB prefix is explicitly marked rather than presented as a complete transcript. A local folder is a deliberate build command: a system sheet + `Form` selects it; the confirmation states that Dockerfile instructions execute in the VM and that the app will not push. The bundled Docker/Buildx client preserves Docker’s actual context/.dockerignore semantics and streams raw JSON, so the sheet uses only an indeterminate `ProgressView` plus observed output, a standard Cancel action, and retry after an actual failure. No count-only percent or fake completion is shown. Docker exposes only a broad `POST /build/prune`; the app labels that boundary and does not offer per-record delete. The history route uses a direct `ContentUnavailableView` with a real Retry for only its loading, empty, and unavailable states. The recorded dark Computer Use pass covers only the empty-cache state and an opened then dismissed Build sheet. History records, detail/log loading, confirmation, progress/cancel, failure/retry, keyboard/focus, accessibility names/help, light/narrow sheet/table/inspector behavior, and XCUITest evidence remain pending. See [`docs/builds.md`](../builds.md). |
| `Views/Volumes/**`, `Views/Networks/**` | Tables, inspectors, context menu, search, destructive confirmation | Native rewrite staged — partial dark volume evidence recorded; broader verification pending | HIG/API read for volume archive export: [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), [Panels](https://developer.apple.com/design/human-interface-guidelines/panels), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Form](https://developer.apple.com/documentation/swiftui/form), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and [NSSavePanel](https://developer.apple.com/documentation/appkit/nssavepanel). Volumes retain a sortable native table with inspector/context-menu selection. Archive export is a selected-record symbol-only secondary toolbar action with matching context/inspector action; no selection or non-local driver opens a panel or reaches the Engine. `NSSavePanel` owns destination and replacement confirmation. The typed service validates the selected local driver anew, uses only an already-local image for a temporary stopped `/data:ro` helper, streams the archive to an atomic private sibling file, removes its owned helper before publication, and never pulls, modifies, or mounts the selected volume in Finder. Its native Form sheet shows a determinate `ProgressView` only for actual Content-Length, otherwise indeterminate work plus real written bytes; cancellation returns `false` to the stream so staging/helper cleanup happens and no archive is published. Success offers Show in Finder only for the completed published destination; unsupported/missing-helper/Engine/output/cancel states retain exact error/result messaging. Multi-volume and multi-network removal reviews enumerate the exact captured names or IDs and execute only those individual Docker deletes; a count-only confirmation is not sufficient. The recorded dark Computer Use pass covers one local-volume selection and its Guest Mount Point wording; it covers no Networks interaction. Light/narrow, keyboard/accessibility, XCUITest, destructive/archive flows, and real-engine evidence remain pending for both routes. |
| `Views/Stacks/**` | Actual Compose hierarchy, selected-record inspector, contextual lifecycle actions, selected source editing, dirty/save/discard, destructive confirmation | Native source implementation — live-window verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [File management](https://developer.apple.com/design/human-interface-guidelines/file-management), [Modality](https://developer.apple.com/design/human-interface-guidelines/modality), [TextEditor](https://developer.apple.com/documentation/swiftui/texteditor), [Text input and output](https://developer.apple.com/documentation/swiftui/text-input-and-output), [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator), [Form](https://developer.apple.com/documentation/swiftui/form), [DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup), [Inspectors](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), Docker’s [environment interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/), [environment precedence](https://docs.docker.com/compose/how-tos/environment-variables/envvars-precedence/), and [Compose secrets](https://docs.docker.com/reference/compose-file/secrets/). Following the binding [task-shaped content guidance](NATIVE-MACOS-PLAYBOOK.md#choose-the-content-form-not-a-house-style), Compose project → service remains a native `Table(children:)` outline with an inspector `Form`, while a person-selected source document opens in a `TextEditor`; neither is a dashboard/card hierarchy. **Edit Compose File…** selects exactly one regular, non-symlink `.yaml`/`.yml` file. **Edit Project Environment File…** separately selects exactly one regular, non-symlink literal `.env` file; it never infers or opens a sibling from a project label or Compose path. The document-modal editor uses a native `Form` for source facts and provenance, count-labelled standard `DisclosureGroup`s for bounded source declarations, a plain `TextEditor` for opaque UTF-8 source, and system toolbar/menu commands. The `.env` summary shows only declaration names, source-line provenance, and empty/set/redacted state; sensitive-looking values are redacted and no summary value is displayed. A Compose YAML summary recognizes only names from a conventional top-level block-style `secrets:` map; it does not parse complex YAML or inspect secret contents. A selected `.env` opens with values withheld in a `ContentUnavailableView`; only the explicit reveal command exposes editable source for that sheet session. Save opens a standard review, then performs the existing explicit coordinated/atomic write: it retains a UTF-8 BOM and previous POSIX mode where supported and compares live bytes with the open snapshot so external source edits reject rather than get overwritten. This is source fidelity, not a Compose-environment result: the route neither evaluates source, performs interpolation, determines Docker’s precedence, accesses Keychain/Docker/registry credentials, creates a clipboard/log record, auto-saves, executes Compose, deploys/recreates/reloads services, nor alters Docker/VM/Kubernetes state. The standard `.bordered` `Table` style is a narrow native hypothesis for the automatic Tahoe style’s repeated rounded empty-row bands; it adds no custom row/selection treatment and still requires latest-bundle Computer Use review. **Validate Compose Source…** is a separate saved-YAML-only command: a second document-modal automatic `Form` names Compose’s trust boundary before it invokes the bundled Compose executable directly with bounded `config --quiet --no-interpolate --no-env-resolution --no-path-resolution` diagnostics. It starts only after confirmation, has a 15-second deadline, distinguishes error/cancellation/timeout/truncation, and calls cancellation **requested** rather than claiming externally created helpers are stopped. It never reads an inferred `.env`, inherited Docker/user credentials/configuration, Keychain, Git/SSH/proxy environment, or performs lifecycle/build/pull/deploy/digest work. See [`docs/compose-source-validation.md`](../compose-source-validation.md). Existing live-window evidence covers only the project/service outline; YAML/.env selection, redaction/reveal, editing, external-change rejection, validation, bordered-table behavior, light/narrow, keyboard/accessibility, XCUITest, and safe real-file acceptance remain pending. |
| `Views/Kubernetes/**` | Tables/outline decision, selected-record inspector, search scopes, read-only description/progress/retry, lifecycle actions, menus, confirmation | Native rewrite staged — partial dark real-window evidence recorded; broader verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Table](https://developer.apple.com/documentation/swiftui/table), [Panels](https://developer.apple.com/design/human-interface-guidelines/panels), [Form](https://developer.apple.com/documentation/swiftui/form), [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent), [Inspectors](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview). Pods and nodes are flat operational collections, so use a sortable `Table`, native selection/search, and the system inspector. A selected record retains summary metadata and adds a bounded, daemon-owned `k8s-describe` GET in its inspector `Form`; a native `ProgressView`/retry state makes that independent read truthful without hiding table data, logs, or events. The daemon accepts only a selected DNS-style Pod or Node reference, checks Ready/forward/kubeconfig prerequisites without creating them, then reads Morbstack's credential-pinned loopback API. It returns bounded metadata, facts, conditions, labels, and annotations—not arbitrary paths, objects, Secret data, watches, logs, exec, port forward, or a workload mutation. `morb k8s describe` consumes the same typed payload, while app and CLI report update-skew through the additive-command restart requirement. The app's direct log/event reads remain separate and read-only. No Docker log cross-link exists until a canonical pod/container identity exists. The route uses native `Table`, system inspector, `Form`, `LabeledContent`, `ProgressView`, and toolbar/menu behavior only; no cards/materials/custom glass. The recorded dark Computer Use pass covers daemon diagnosis and an opened then cancelled Enable confirmation while Kubernetes was Off; it does not validate pods, nodes, describe, logs, events, or enabled-cluster behavior. Light/narrow, keyboard/accessibility, XCUITest, and real-cluster evidence remain pending. |
| `Views/Disk/**` | Table, inspector/form, capacity progress, prune review, Charts decision | Native rewrite staged — live-window verification pending | One storage table; a factual `ProgressView` only; no hero consumption bar. Image/container/volume cleanup uses a scoped review sheet. Build cache has no per-record Docker delete, so Disk routes to Builds for review and does not expose Docker’s broad global cache prune. |
| `Views/Migration/**` | Source readiness, operational-record selection, scoped import review, progress, report/retry, unavailable state | Native rewrite staged — live-window verification pending | HIG/API read: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Table](https://developer.apple.com/documentation/swiftui/table), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Form](https://developer.apple.com/documentation/swiftui/form), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview). Runtime inspection stays read-only in a selectable `Table` with a system inspector `Form`. The selected-runtime inspector presents the independent, GET-only named-volume eligibility comparison in a native `Table`: eligibility is limited to absent local-driver names, while existing destinations and unsupported drivers retain their explicit reasons. `Select Volumes to Transfer…` opens a document-modal `Table` with an **empty** selection containing only the current eligible records. Fresh preparation must rederive that selected set before a second review sheet can transfer it. That review explicitly states the stopped source helper with read-only mount, new destination creation and archive population, and the no-overwrite/no-automatic-rollback boundary. Only if the prepared transaction reports a missing helper image does the review expose a separate default-off `alpine:3.20` network-consent control. Actual transaction progress reports completed volume count plus indeterminate phase/current archive bytes; it never represents a byte percentage, cancellation, or content verification that Docker does not provide. The structured report distinguishes archive upload, destination state, and review-required outcomes. The separately labeled image import workflow remains selected-images-only: it re-prepares the exact selected references and presents a scoped review sheet before `ImageMigrationTransaction.execute` can write to Morbstack. The route uses system tables/forms/sheets/toolbars only—no custom glass, cards, content materials, or inferred `--all` action. Discovery and preparation remain GET-only; only the confirmed selected-volume transaction can create helper containers, pull the disclosed helper image, create a selected missing destination volume, and populate it. It never starts a runtime, touches unselected/existing volumes, writes Docker configuration, invokes credentials/helpers, or contacts a registry except for the separately consented helper-image pull. No Computer Use evidence is recorded for this route. Light/narrow, keyboard/accessibility, XCUITest, and real migration-engine evidence remain pending. |
| `Design/**`, `Theme.swift` | Materials, color, controls, focus/selection, accessibility | Removal staged — source verification pending | Keep only nonvisual domain semantics temporarily; eliminate routine rendering policy |
| `Shots/**`, `LiveCapture.swift`, `mise.toml`, `mac/UITests/**` | Windows, accessibility/UI testing, visual validation | Synthetic renderer retired; real-window evidence harness in place | Foundation-only fixture invariants plus a text-only real-window route probe; the standard XCUITest host launches the assembled shipping bundle for WindowServer screenshots and accessibility evidence, followed by Computer Use |

### 2026-08-03 Stacks hierarchy correction

This decision supersedes the earlier `Views/Stacks/**` table-row reference to
`Table(children:)` and its `.bordered` style hypothesis. The current task is to traverse
real Compose project → service membership, select one record, and then inspect its rich
metadata or invoke a contextually safe action; it is not a multi-column comparison task.
The actual macOS screenshot showed `Table(children:)` extending its unused body as
repeated horizontal bands, so that native container was not communicating the hierarchy
well enough at the observed density.

Consulted: Apple’s [outline views](https://developer.apple.com/design/human-interface-guidelines/outline-views),
[lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
SwiftUI [`List`](https://developer.apple.com/documentation/swiftui/list),
[`OutlineGroup`](https://developer.apple.com/documentation/swiftui/outlinegroup),
[`View.inspector`](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)),
and [`Form`](https://developer.apple.com/documentation/swiftui/form).

`StacksRootView` therefore uses direct `List(selection:)` + `OutlineGroup` with one
system `Label` for each actual project or service. The list retains native disclosure,
keyboard selection, the selection-aware context menu and primary service action,
filter-driven selection reconciliation, the existing inspector `Form`, and the current
action and destructive-confirmation safety boundaries. It adds no material, cards,
custom row treatment, or substitute visual system. Current-bundle light/dark,
narrow-width, keyboard/VoiceOver, context-menu, inspector, and source-editing
acceptance remain required; no build, test, Docker/VM action, or live-app interaction
was performed for this source change.

### 2026-08-03 Containers list override

This decision supersedes the `Views/Containers/**` row’s earlier default-`Table`
choice and the corresponding Table Semantics Audit inventory entry for this primary
inventory only. The current Computer Use review showed four real containers followed by
repeated dark unused-table stripes. At that density, the native table body was
communicating an Activity Monitor/dashboard surface more strongly than the operational
records, so changing its style again would not address the observed hierarchy problem.

Consulted: Apple’s [lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
SwiftUI [`List`](https://developer.apple.com/documentation/swiftui/list), and
[`View.inspector`](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)).

`ContainersRootView` therefore uses direct `List(selection:)` for the flat local
inventory. Each standard system row exposes only the container name and compact current
state; selecting it reveals the existing native inspector, and the preserved double-click
primary gesture explicitly selects and reveals that same record. The inspector remains
the detailed record surface for returned image, state, ports, and Compose metadata.
Existing filter behavior, contextual lifecycle/copy/remove commands, Delete-key removal
review, toolbar lifecycle actions, and destructive confirmation boundaries remain
unchanged. The route adds no custom list style, cards, material, row background, or
per-row command controls. Current-bundle light/dark,
narrow-width, keyboard/VoiceOver, context-menu, inspector, and lifecycle acceptance
remain required; this source change performs no build, test, Docker/VM, or live-app
action.

### 2026-08-03 Inspector density rule

An inspector is a selected-record surface, not a compressed dashboard column. Computer
Use showed that a roughly 300-point inspector made real monospaced Docker facts clip
and caused otherwise-standard `Form` content to read as a hand-compressed web panel.
For Containers, Stacks, and Images, the system `.inspectorColumnWidth` minimum is now
340 points with a 400-point ideal width. This is a native width constraint, not a
custom background, card, font, or field layout. Rich values still truncate/select
according to their own content semantics; the acceptance pass must verify normal and
narrow windows before this dimension is considered final.

### 2026-08-03 Container inspector hierarchy correction

The expanded real-container Overview inspector confirmed that width was not the remaining
problem: rendering every environment variable and label as equal-weight form content
created a centered wall of facts. The user task is to inspect State, Configuration, and
published Ports first; environment variables, mounts, and labels are secondary metadata
that a person requests when diagnosing a specific detail.

Consulted: Apple’s [inspectors](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)),
[forms](https://developer.apple.com/documentation/swiftui/form), and SwiftUI
[`DisclosureGroup`](https://developer.apple.com/documentation/swiftui/disclosuregroup).

`ContainerOverviewTab` therefore retains the system inspector and uses its route-specific
`FormStyle.columns` presentation: the captured automatic form centered its intrinsic-size
fact cluster in the tab, while the standard column form uses the inspector's full
top-leading canvas for legible label/value relationships at the supported 340-point
minimum. State, Configuration, and Ports remain visible, and Environment, Mounts, and
Labels are standard count-labelled `DisclosureGroup`s that are collapsed on first
presentation. Environment expansion retains the existing filter, per-variable masked
default, explicit reveal, copy action, icon help, and text-selection behavior; collapsing
the group does not expose its values. Mount actions/context menu and label text selection
remain inside their disclosed form content. This is an information-hierarchy correction,
not a custom accordion, card, list row, width increase, or typography change.
Current-bundle light/dark, minimum/ideal/expanded inspector width, disclosure keyboard
and VoiceOver behavior, long-name truncation/copy, secret reveal/copy, mount actions,
and lifecycle acceptance remain required; no build, test, Docker/VM action, or live-app
interaction was performed for this source change.

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

### Live evidence — 2026-08-03

The signed `dist/Morbstack.app` was rebuilt serially and inspected in a real dark-mode
window using Computer Use after the native-content migration.  This is deliberately
separate from fixture/source evidence: it records only what was actually observed in
the WindowServer-composited bundle.

| Surface | Observed safe interaction | Result |
| --- | --- | --- |
| Shell/sidebar | Hide then show sidebar | System `NavigationSplitView` owned collapse/reveal; no custom toggle or overlay appeared. |
| Engine-off content | Relaunched without accepting setup, then explicitly started Morbstack | Native `ContentUnavailableView` supplied the one appropriate Start action. The user-visible setup review was dismissed without changing shell/context settings. |
| Container selection/inspector | Selected an actual stopped container and inspected Overview | The detail uses native `TabView` tabs and a system Form; scalar facts and variable rows remain semantic controls, while Start is the only primary lifecycle command for that stopped record. |
| Images | Real local images, selection/inspector, Pull sheet opened then escaped | Direct sortable `Table`; no redundant first table section; Pull uses a system document-modal `Form` and no image was pulled. |
| Volumes | Real local named volume selection | Inspector labels the Docker path as a **Guest Mount Point** and offers no impossible Finder reveal. |
| Builds | Empty cache state; Build sheet opened then dismissed | `ContentUnavailableView` offers Build/Refresh; Build is a system document-modal review sheet and no build ran. |
| Disk | Real `/system/df` data and selection | Native list sections separate non-additive aggregate categories from largest individual resources; the VM capacity indicator remains factual. |
| Stacks | Real Compose project outline expanded; stopped service selected | The native `List` + `OutlineGroup` disclosure exposes the actual project→service hierarchy without unused table rows, the inspector uses `Form` facts/actions, and the selected stopped service has exactly one symbol-only Start primary action. No lifecycle command was invoked. |
| Migration | Real Docker Desktop and Morbstack inventory selected | The native runtime `Table` and inspector compared real local inventories in read-only mode. No image or volume workflow was opened, so transfer/recheck/progress acceptance remains pending. |
| Kubernetes | Rebuilt daemon diagnosis and Enable review | The stale-daemon compatibility error disappeared after a clean daemon restart. Kubernetes accurately reported Off, then showed a standard enable confirmation naming the first-download consequence; it was cancelled, so k3s was not enabled. |

The app uses the current system dark appearance without a global tint/appearance
override. The purple screen-capture pill visible in some Computer Use captures is an
OS privacy indicator, not a Morbstack view. The running-app audit did **not** execute
destructive actions, pull an image, build, enable k3s, export/remove data, or restart
any container. A clean daemon restart stopped existing running containers; they were
not restarted automatically or manually.

Still required before calling the migration fully accepted: real-window light
appearance, minimum-width/toolbar-overflow review, increased-contrast/reduced-
transparency review, and the separately approved XCUITest evidence pass.

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
