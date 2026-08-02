# REWRITE-PLAN — who owns what, and what the merge must prove

Three implementation agents, strictly disjoint file lists, one shared design system that
none of them may edit.

Read `CRITIQUE.md` for what is wrong, `IDENTITY.md` for the values, `COMPONENTS.md` for the
API, and `SDK-LIQUID-GLASS.md` before you type any macOS 26 symbol. Then read only your own
section below.

---

## 0. The rules that bind all three agents

1. **`Theme.swift` and `Design/**` are read-only.** They belong to the design system. If a
   component is missing something, put it in your handoff — do not fork it, do not
   subclass it, do not add a local variant next to it. A second `MorbChip` is exactly how
   the current build got three chip styles.
2. **No bare macOS 26 API.** `mac/Package.swift` targets `.macOS(.v15)`. Every glass call
   goes through `Design/MorbGlass.swift`. A `.glassEffect(…)` in a feature file does not
   compile, and an `@available(macOS 26.0, *)` on a view poisons every call site above it.
3. **No literal spacing, no literal row height, no literal radius, no literal colour.**
   Everything comes from `Theme`. A grep for `padding(.*\d\d)` in your diff should return
   nothing that is not a `Theme.space*`.
4. **`.monospacedDigit()` on every number that polls or is right-aligned.** Use
   `MorbNumber` and you get it for free.
5. **Do not modify any file under `mac/Tests/`.** 617 tests are green at the base commit
   and must be green at every merge point.
6. **Do not touch `Shots/**`.** The screenshot harness is the merge owner's. If your view's
   initialiser signature changes, say so in your handoff — do not "just fix" the caller.
7. **Do not touch the model layer**: `AppModel.swift`, `DockerClient.swift`,
   `DaemonClient.swift`, `Models.swift`, `Formatters.swift`, `AppLaunchRescue.swift`. If a
   screen needs a value the model does not expose, put it in your handoff. Adding a
   computed property to `AppModel` from three agents at once is a guaranteed conflict.
8. **`swift build` and `swift test` must be green in your own working tree before you hand
   off**, not "green after the merge".

---

## 1. Agent UI-1 — Containers, Logs, Stats, Inspect

The densest surface in the app and the one users live in.

### Files owned (exclusive)

```
mac/Sources/MorbstackAppCore/Views/Containers/AnsiSGR.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerDetailView.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerInspectDetails.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerInspectTab.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerListRow.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerLogStore.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerLogsTab.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerMountModel.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerMountRow.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerOverviewTab.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerStatsHub.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainerStatsTab.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainersChrome.swift
mac/Sources/MorbstackAppCore/Views/Containers/ContainersRootView.swift
mac/Sources/MorbstackAppCore/Views/Containers/LogPipeline.swift
```

15 files. Nothing outside `Views/Containers/`.

### Must do

| # | Change | Fixes |
| --- | --- | --- |
| 1.1 | Delete the fake header in `ContainersChrome`. Title/subtitle → `.morbScreen(title:subtitle:edge: .hard)`. Search → `.searchable(text:placement: .toolbar, prompt: "Name, image, project")`. All/Running → `Picker(…).pickerStyle(.segmented)` in `MorbToolbarGroup.navigation`. Prune → `MorbToolbarGroup.actions`. | Critique §1 |
| 1.2 | Replace the `HStack` + `Divider()` third column in `ContainersRootView` with `.inspector(isPresented:)` + `.inspectorColumnWidth(min: Theme.inspectorMinWidth, ideal: Theme.inspectorWidth, max: Theme.inspectorMaxWidth)`. | Critique, containers §2 |
| 1.3 | Rebuild `ContainerListRow` on `MorbRichRow`. **Fixed `Theme.rowRich` = 44 pt.** First port as a `MorbPortChip`, the rest as `MorbOverflowChip(hidden:detail:)`. CPU/memory as `MorbNumber` in a fixed-width trailing column. Uptime gets a header or a tooltip — an unlabelled `12d` floating at the top-right is not information. | Critique §4, containers §3–5 |
| 1.4 | Group headers → `MorbGroupHeader(_:state:running:total:symbol:)` with `MorbGroupState.from(running:total:)`. Three treatments become one. | Critique, containers §5 |
| 1.5 | Detail header: name + `MorbStatusBadge` + `MorbChip(project, rank: .brand)`. Actions move to `.toolbar(id: "container")` with `MorbToolbarGap` between the lifecycle cluster and the destructive one, all via `.morbButton(.floating)` / `MorbIconButton(role: .destructive)`. **Zero `.primary` buttons on this screen.** | Critique, containers §7–8 |
| 1.6 | Overview/Logs/Stats/Inspect → `Picker(…).pickerStyle(.segmented)`, or a real `.toolbar` `.principal` item. Not a hand-rolled pill row. | Critique §3 |
| 1.7 | `ContainerOverviewTab`'s Configuration grid → `Form { … }.formStyle(.grouped)` of `MorbKeyValue`, monospaced where the value is an ID, digest, path or command. | Critique, containers §10 |
| 1.8 | Ports and Mounts → real `Table` with `.tableStyle(.inset)` + `.alternatingRowBackgrounds()`. Sortable. `Theme.rowStandard`. | Critique, containers §12 |
| 1.9 | Environment: **one** reveal mechanism, not two. Keep the per-row eye, drop the global "Values hidden" chip (or the inverse — pick one and say which). Default to *showing* names with masked values is fine; seven identical rows of `••••••••` across 240 pt is not. | Critique, containers §11 |
| 1.10 | Log gutter: `logGutter` role (10 pt mono, `.tertiary`), fixed 78 pt column, **suppressed on continuation lines**. Log body stays at 11.5 pt mono with 2 pt line spacing on a **flat** background. | Critique, logs §1; Identity §3.3 |
| 1.11 | Error regions: 3 pt `Theme.statusBad` left rule + a very faint tint, replacing the full-bleed red wash. Add a "next error" affordance — the app already knows where they are. | Critique, logs §2, §4 |
| 1.12 | Logs toolbar → real `.toolbar`. Follow / Times as `Toggle`s. Line count as `MorbToolbarStatus`. Trash/copy/share as `MorbIconButton`. `.morbScrollEdge(.hard, for: .top)`. | Critique §1 |
| 1.13 | Stats: every number through `MorbNumber` or `MorbMetric`. Chart bars in `Theme.series` order. No animation on poll refresh beyond `.fade`. | Identity §3.2, §6.3 |
| 1.14 | `.contextMenu(forSelectionType: Container.ID.self)` on the list, with `primaryAction:` = open in inspector. | SDK doc §2.7 |
| 1.15 | Filtering to zero results shows `MorbNoMatches(query:)`. | Critique §3 |

### Must not

- Put glass behind the log viewport. **At any size, for any reason.** This is the one
  hard prohibition in the whole plan.
- Change `LogPipeline`'s or `ContainerLogStore`'s public behaviour — `TrackBLogPipelineTests`
  and `TrackBMountModelTests` cover them.
- Restyle the ANSI SGR palette. It is the terminal's contract with the program that wrote
  the bytes.

---

## 2. Agent UI-2 — Images, Volumes, Networks, Disk, Stacks

The resource screens. Four of the five should be tables, and three of them currently are
not.

### Files owned (exclusive)

```
mac/Sources/MorbstackAppCore/Views/Images/ImagesRootView.swift
mac/Sources/MorbstackAppCore/Views/Images/TrackCChrome.swift
mac/Sources/MorbstackAppCore/Views/Images/TrackCImageArchitecture.swift
mac/Sources/MorbstackAppCore/Views/Images/TrackCImageList.swift
mac/Sources/MorbstackAppCore/Views/Volumes/VolumesRootView.swift
mac/Sources/MorbstackAppCore/Views/Networks/NetworksRootView.swift
mac/Sources/MorbstackAppCore/Views/Disk/DiskRootView.swift
mac/Sources/MorbstackAppCore/Views/Disk/TrackCConfirmSheet.swift
mac/Sources/MorbstackAppCore/Views/Disk/TrackCDiskMath.swift
mac/Sources/MorbstackAppCore/Views/Stacks/StacksRootView.swift
```

10 files. Nothing outside `Views/Images/`, `Views/Volumes/`, `Views/Networks/`,
`Views/Disk/`, `Views/Stacks/`.

### Must do

| # | Change | Fixes |
| --- | --- | --- |
| 2.1 | All five screens: `.morbScreen(title:subtitle:edge:)` + real `.toolbar(id:)`. Filter fields → `.searchable(placement: .toolbar)`. `edge: .hard` for Images/Volumes/Networks/Stacks, `.soft` for Disk. | Critique §1 |
| 2.2 | Images: move the Pull row out of the content area. It becomes a `.toolbar` item (a `TextField` + `Button` in one `ToolbarItem`, or a popover from a `+` button) — not a third bar wedged between the header and the table. | Critique, images §2 |
| 2.3 | Images `In use` column: one grammar. `MorbCountBadge(count:)` when > 0, an em-dash when 0. Not "a green capsule or a bare grey zero". | Critique, images §3 |
| 2.4 | Trailing icon columns → `MorbIconButton`, `Theme.minHitTarget`. Trash is `.secondary` at rest and `statusBad` on hover **only**. Add a `TableColumn` header, or move both into `.contextMenu(forSelectionType:)` and drop the columns. | Critique, images §4 |
| 2.5 | Dangling images become a real second `Section` of the same table, so their rows sit inside the same column geometry. | Critique, images §6 |
| 2.6 | Volumes and Networks → real `Table` + `.tableStyle(.inset)` + `.alternatingRowBackgrounds()`, `Theme.rowStandard`, sortable, with `@AppStorage`-backed `TableColumnCustomization`. | Critique §3 |
| 2.7 | Stacks: the two "cards" become one `Table`-per-project inside a `MorbCard`, or a `List` with `MorbGroupHeader` + `MorbRichRow`. **Delete the hard-coded port column x-position.** | Critique, stacks §2 |
| 2.8 | Stacks per-service actions → `MorbIconButton` at `Theme.minHitTarget`, moved next to the service name or into `.contextMenu`. Not 11 pt glyphs 1 600 pt away pinned to the window edge. | Critique, stacks §3 |
| 2.9 | Stacks project header → `MorbGroupHeader` + `MorbGroupState.from(running:total:)`. `Up`/`Restart`/`Down` in a `MorbGlassCluster` with `.morbButton(.floating)`; disabled state uses `.disabled(_:)`, not an opacity change on the label. | Critique, stacks §1, §4 |
| 2.10 | Disk stacked bar: **delete the diagonal hatching.** Reclaimable is the same hue at `Theme.seriesDimAlpha`. Five categories max, drawn in `Theme.series` order. | Critique, disk §1; Identity §2.5 |
| 2.11 | Disk legend rows → `Theme.rowStandard` with `MorbNumber` for the size and `MorbIconButton`/`Button(role: .destructive)` for Prune. Prune must not have the same visual weight as the row label. | Critique, disk §2 |
| 2.12 | "Largest images" and "Largest volumes" → `MorbMeter` with a **shared `total`** across both cards, so a 3.22 GB volume draws longer than a 1.49 GB image. | Critique, disk §3 |
| 2.13 | `VM DISK IMAGE` → three `MorbMetric`s, exactly one with `emphasis: .leading`. | Critique, disk §4 |
| 2.14 | Disk body copy: render inline code as `monoSmall` on a `.quaternary` chip. **Backtick characters must not appear on screen.** Raise the disk-image path off `.tertiary`-at-25 % to at least `.secondary`. | Critique, disk §5–6 |
| 2.15 | Every list gets `MorbNoMatches(query:)` when the filter empties it, and a `MorbEmptyState` when there is genuinely nothing (no volumes yet, no images pulled). | Critique §3 |
| 2.16 | Disk page fills its window or explains itself. 350 pt of content in a 900 pt window with cards floating on a grey field is the iOS grouped-form idiom. | Critique, disk §7 |

### Must not

- Put glass behind a table or a chart.
- Change the arithmetic in `TrackCDiskMath.swift` or `TrackCImageArchitecture.swift`.
  `TrackCDiskMathTests`, `TrackCImageArchTests` and `TrackCResourceListTests` cover them.
  Restyle their *presenters*, not their maths.
- Introduce a sixth series colour.

---

## 3. Agent UI-3 — App shell, sidebar, menu bar, palette, settings, placeholders, icon

The frame everything else sits in, plus the two surfaces where Liquid Glass is not
optional.

### Files owned (exclusive)

```
mac/Sources/MorbstackAppCore/App.swift
mac/Sources/MorbstackAppCore/MenuBar/MorbMenuBar.swift
mac/Sources/MorbstackAppCore/MenuBar/TrackDAppBridge.swift
mac/Sources/MorbstackAppCore/MenuBar/TrackDChrome.swift
mac/Sources/MorbstackAppCore/Palette/CommandPalette.swift
mac/Sources/MorbstackAppCore/Palette/FuzzyMatcher.swift
mac/Sources/MorbstackAppCore/Palette/PaletteCommands.swift
mac/Sources/MorbstackAppCore/Settings/MorbSettingsView.swift
mac/Sources/MorbstackAppCore/Settings/TrackDConfigEditor.swift
mac/Sources/MorbstackAppCore/Settings/TrackDSharingSettings.swift
mac/Sources/MorbstackAppCore/Sharing/FileSharingStatus.swift
mac/Sources/MorbstackAppCore/Views/Placeholders/PlaceholderView.swift
mac/AppResources/make-icon.swift
```

13 files.

`App.swift` carries the app shell, `Sidebar`, `NavRow`, `EnginePill`, `DetailHost`,
`EngineStoppedView`, `LoadingView` and `MorbCommands` — the engine-stopped state and the
sidebar are here, not in a `Views/` subdirectory, which is why they are UI-3's.

### Must do

| # | Change | Fixes |
| --- | --- | --- |
| 3.1 | `WindowGroup` gets `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`. This is the change that makes seven other screens' toolbars look right. | Critique §1 |
| 3.2 | Sidebar gets `MorbSidebarHeader(version:)` at the top and **two sections**: *Workloads* (Containers, Stacks, Kubernetes) and *Resources* (Images, Volumes, Networks, Builds, Disk). Eight flat peers where two are placeholders is the Xcode template. | Critique, containers §1 |
| 3.3 | `NavRow` selection → `Theme.selectionFill` + `Theme.selectionRail` via `.morbRow(.standard, isSelected:)`, and badges → `MorbCountBadge`. The system's neutral grey selection is the single most visible reason the app has no colour identity. | Critique §5 |
| 3.4 | Sidebar rows for the two placeholder destinations (Builds, Kubernetes) get a "soon" affordance or move below a divider. A dead end at the same rank as Containers is a lie about the product. | Critique, containers §1 |
| 3.5 | `EnginePill` → `.morbBottomBar { … }` on the sidebar, with `MorbStatusBadge`. Numbers through `MorbNumber`. | Identity §5.1 |
| 3.6 | `EngineStoppedView` → `MorbEmptyState(…, actionTitle: "Start Engine")` with `.morbButton(.primary)`. Delete the 110 pt lavender disc and the capsule button. Move the bottom-anchored footnote into the empty state's `footnote:`. | Critique, engine-stopped |
| 3.7 | Disable, or contextually explain, the sidebar destinations while the engine is stopped. Clicking `Images` with the engine down currently shows an empty table with no explanation. | Critique, engine-stopped §2 |
| 3.8 | **Menu-bar popover gets glass**: `.morbGlassPanel()` on its root, clipped to `Theme.radiusPanel`. It is currently an opaque rectangle pasted onto the wallpaper, and it is the one surface on macOS where that is objectively wrong. | Critique §2 |
| 3.9 | Menu-bar popover rows → `Theme.rowCompact` (24 pt). Target ≤ 450 pt total at eight containers and six ports, down from 775 pt. Five row heights become two. CPU through `MorbNumber`. | Critique, menubar §2–3, §6 |
| 3.10 | `+3 more in the main window` becomes a `Button`. Drop the ⌘-shortcut hints from the footer, or move the footer to a real `Menu` — a `.window`-style popover does not fire them. | Critique, menubar §4–5 |
| 3.11 | Command palette: `.presentationBackground(.clear)` + `.morbGlassPanel()` over a `Color.black.opacity(0.18)` scrim. `Glass` is **not** a `ShapeStyle` — see `SDK-LIQUID-GLASS.md` §2.13. Anchor at ~22 % from the top and centre it. | Critique, palette §1 |
| 3.12 | Palette results: rows at `Theme.rowCompact`, the repeated right-aligned `Container` label becomes a section header, and the icon column carries the *command kind*, not container status. Fix the two-indigos-fighting problem: selected row uses `Theme.selectionFill` and the match highlight uses `.primary` bold, not a brighter indigo. | Critique, palette §2–4 |
| 3.13 | Palette footer legend from `.caption2`/`.tertiary` to `.caption`/`.secondary`. It is currently invisible. | Critique, palette §5 |
| 3.14 | Settings: `Form { … }.formStyle(.grouped)` inside the standard `Settings` scene, with the tabs as a real window toolbar. **Delete the Revert/Save footer** — Mac settings apply on change. Sliders get their value adjacent to the track, not 450 pt away. Explanatory prose drops to `.caption`/`.secondary`. | Critique, settings |
| 3.15 | `PlaceholderView` → `MorbEmptyState`. | Critique §3 |
| 3.16 | **Redraw the icon** in `make-icon.swift` to the geometry in `IDENTITY.md` §1 — orb resting on full-width slabs, the top slab passing behind it, one-device-pixel gap floor, three slabs at ≥ 64 px and two below. **Your output must reproduce `docs/design/icon-reference.png`.** Then run the six checks in `IDENTITY.md` §1.7. `MorbMarkGeometry` in `Design/MorbBrand.swift` holds the same constants; they must agree. Note the origin flip — CoreGraphics is bottom-left, `MorbMarkGeometry` stores `1 − v`. | Critique §6 |

### Must not

- Change `FuzzyMatcher`'s scoring — `TrackDFuzzyMatcherTests` covers it. Restyle the
  results, not the ranking.
- Change `FileSharingStatus`'s classification — `TrackEShareStatusTests` covers it.
- Change the `TrackDPreferences` keys or the `menuBarInserted` binding's idempotence guard
  in `App.swift`. That guard prevents an infinite scene-rebuild loop and the comment
  explaining it must survive.
- Change `MorbWindowOpener` / `AppLaunchRescue` behaviour — `TrackALaunchRescueTests`
  covers it.
- Add a case to `StatusTone`. See §Deferred.

---

## 4. Owned by the merge, not by any agent

```
mac/Sources/MorbstackAppCore/Theme.swift          ← design system
mac/Sources/MorbstackAppCore/Design/**            ← design system
mac/Sources/MorbstackAppCore/Shots/ShotChrome.swift
mac/Sources/MorbstackAppCore/Shots/ShotClients.swift
mac/Sources/MorbstackAppCore/Shots/ShotFixtures.swift
mac/Sources/MorbstackAppCore/Shots/ShotLogs.swift
mac/Sources/MorbstackAppCore/Shots/ShotRenderer.swift
mac/Sources/MorbstackAppCore/Shots/ShotScenes.swift
mac/Sources/MorbstackAppCore/Shots/ShotsCLI.swift
dist/shots/**
```

`ShotScenes.swift` constructs every screen in the app, so it touches all three agents'
initialisers. If it were owned by an agent it would conflict on every merge. Agents record
signature changes in their handoff; the merge owner applies them all at once and
regenerates `dist/shots`.

### Never touched by this redesign

`AppModel.swift`, `DockerClient.swift`, `DaemonClient.swift`, `Models.swift`,
`Formatters.swift`, `AppLaunchRescue.swift`, `mac/Sources/MorbstackKit/**`,
`mac/Sources/morb/**`, `mac/Sources/morbstackd/**`, `mac/Sources/MorbLive/**`,
`mac/Sources/MorbShots/main.swift`, `mac/Tests/**`, `guest/**`, `scripts/**`.

---

## 5. Disjointness proof

| Directory | UI-1 | UI-2 | UI-3 | Merge |
| --- | :-: | :-: | :-: | :-: |
| `Views/Containers/` (15) | ● | | | |
| `Views/Images/` (4) | | ● | | |
| `Views/Volumes/` (1) | | ● | | |
| `Views/Networks/` (1) | | ● | | |
| `Views/Disk/` (3) | | ● | | |
| `Views/Stacks/` (1) | | ● | | |
| `Views/Placeholders/` (1) | | | ● | |
| `MenuBar/` (3) | | | ● | |
| `Palette/` (3) | | | ● | |
| `Settings/` (3) | | | ● | |
| `Sharing/` (1) | | | ● | |
| `App.swift` | | | ● | |
| `AppResources/make-icon.swift` | | | ● | |
| `Theme.swift` | | | | ● |
| `Design/` (11) | | | | ● |
| `Shots/` (7) | | | | ● |

**15 + 10 + 13 = 38 owned files, no overlaps, no file unassigned.** Every `.swift` under
`MorbstackAppCore/Views/`, `MenuBar/`, `Palette/`, `Settings/`, `Sharing/` and `App.swift`
appears exactly once.

---

## 6. What the merge must verify

Run in this order. Any failure blocks the merge.

### 6.1 Mechanical

1. `cd mac && swift build` — **zero errors, and zero new warnings** relative to the base
   commit's warning set.
2. `swift test` — **617 passing, 1 skipped, 0 failures.** No test file modified:
   `git diff --stat mac/Tests/` must be empty.
3. `git diff --name-only` intersected with each agent's list must be a subset of that list.
   Any file touched by two agents is a merge failure, not a merge conflict to resolve.
4. Every macOS 26 API goes through `Design/`. Quote the `--include` glob or zsh will eat it:

   ```sh
   grep -rn --include='*.swift' -E \
     "glassEffect|GlassEffectContainer|ToolbarSpacer|glassProminent|buttonStyle\(\.glass|scrollEdgeEffect|safeAreaBar|symbolColorRenderingMode" \
     mac/Sources/MorbstackAppCore | grep -v "/Design/"
   ```

   At the design-system commit this returns exactly one line — a doc comment in
   `Theme.swift:396` mentioning `glassEffectID`. **Any code hit is a merge failure.**
5. ```sh
   grep -rn --include='*.swift' "#available" mac/Sources/MorbstackAppCore | grep -v "/Design/"
   ```
   must return **nothing**. It is clean at the design-system commit.
6. `make sign` still produces a `morbstackd` with the virtualization entitlement, and the
   app bundle still launches. (`swift build` strips it; signing must remain the last step.)

### 6.2 Design conformance

7. **Row heights.** `grep -rn "\.frame(height:" mac/Sources/MorbstackAppCore/Views mac/Sources/MorbstackAppCore/MenuBar mac/Sources/MorbstackAppCore/Palette` — every value must be a `Theme.row*` constant or come from `.morbRow`.
8. **Spacing.** No numeric literal ≥ 2 inside `padding(`, `spacing:` or `HStack(spacing:` outside `Theme`. Ten minutes with `grep -nE "(padding|spacing:)\s*[,(]?\s*[0-9]"`.
9. **Colour.**
   ```sh
   grep -rn --include='*.swift' -E "Color\(red:|Color\(white:" \
     mac/Sources/MorbstackAppCore | grep -v "/Design/\|Theme.swift\|/Shots/"
   ```
   must return **nothing**. (`Shots/ShotChrome.swift` is excluded: its literals are the
   fake desktop wallpaper behind a screenshot, not app UI.)
10. **Monospaced digits.** Every number in the containers list, the menu-bar popover, the disk legend and the Stats tab. Verify by starting a live engine and watching for horizontal jitter over 30 s.
11. **Hit targets.** Every icon-only button is `MorbIconButton` or carries `.frame(minWidth: Theme.minHitTarget, minHeight: Theme.minHitTarget)`.
12. **One primary per screen.** `grep -rn "morbButton(.primary)"` — at most one per screen root.

### 6.3 Visual

13. Regenerate every shot: `MorbShots` for all 36 renders, both appearances.
14. **Side-by-side against `dist/shots` at the base commit.** For each screen, the diff must show: a real titlebar, a real toolbar, one row height, and the brand rail on the selected sidebar row.
15. Menu-bar popover: glass, and **≤ 450 pt tall** at the standard fixture.
16. Command palette: glass, centred, scrim visible.
17. Log viewport: **flat background.** Zoom to 400 % and confirm no blur behind the text.
18. Disk stacked bar: **no hatching**, and the two "Largest …" meters share a scale — confirm the 3.22 GB volume bar is longer than the 1.49 GB image bar.
19. Icon: render at 16 / 32 / 64 / 128 / 256 / 512 / 1024 and run `IDENTITY.md` §1.7.

### 6.4 Accessibility

20. **Reduce Motion on**: nothing springs, nothing pulses, nothing rotates. Walk all ten screens.
21. **Increase Contrast on**: glass degrades to material, hairlines darken, chip fills go to 20 %, the selection rail widens to 4 pt.
22. **Greyscale**: every status is still distinguishable, on all ten screens. This is what the symbols are for.
23. **VoiceOver**: every `MorbIconButton` announces its `help` text; every status announces its `label`; every group header announces "n of m running".
24. **Full keyboard access**: Tab reaches every control; ⌘1–⌘8 still switch destinations; ⌘K still opens the palette; ⌘R still refreshes.

### 6.5 Live

25. `scripts/live-app-check.sh` (or `MorbLive`) against a real engine — the redesign must not have broken a data path.
26. Start / suspend / stop the engine and watch the pill, the popover and the sidebar badges agree at every step.

---

## 7. Deferred — the one cross-cutting change nobody may make unilaterally

**Promoting `degraded` to a real `StatusTone` case.**

`StatusTone` is switched over exhaustively in
`MenuBar/TrackDChrome.swift:41–49` (`TrackDTone.init(_ status: StatusTone)`), which belongs
to UI-3. Adding a
case breaks that file, so the design system ships `MorbGroupState` instead —
`Design/MorbGroupState.swift` — which carries the state and the colour without touching the
shared enum.

If the merge owner wants to unify them afterwards, it is exactly three edits, in this
order, in one commit:

1. `Theme.swift` — add `case degraded` to `StatusTone`, with
   `Theme.statusDegraded` and `"exclamationmark.triangle.fill"`.
2. `MenuBar/TrackDChrome.swift` — add `case .degraded: self = .warn` to `TrackDTone.init`.
3. `Design/MorbGroupState.swift` — `approximateTone` returns `.degraded` for `.degraded`.

`ModelTests.testEveryToneHasADistinctSymbol` stays green because the new symbol is
distinct. **Do not attempt this during the three-way parallel phase.**

---

## 8. Handoff format

Each agent finishes with:

1. The exact file list they touched, verified against §5.
2. `swift build` / `swift test` output.
3. Any changed initialiser signature, so the merge owner can update `ShotScenes.swift`.
4. Anything they wanted from `Design/` and did not have — **as a request, not as a local
   workaround.**
5. Anything in `CRITIQUE.md` for their screens they consciously did *not* fix, and why.
