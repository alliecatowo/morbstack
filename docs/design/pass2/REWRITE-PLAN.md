# REWRITE-PLAN — archived second-pass execution plan

> **Image note (2026-08-05):** the screenshots this document referenced lived in
> `mac/dist/shots/`, `docs/img/` or `artifacts/visual/` and have been removed. The
> first was offscreen `MorbShots` output, which `docs/design/DECISIONS.md` §6 retired
> as *not* visual evidence — it cannot composite the toolbar, inspector or glass. The
> others were dated captures of superseded builds. The findings stand as written; the
> images are recoverable from git history if a specific one is ever needed.


> **Archived — do not execute.** This plan assigned agents to build the custom
> Theme/`Design/**`/`Morb*` system and synthetic screenshot process that the native-macOS
> migration has retired. Its parallel-work lessons are historical only; its component,
> wrapper, screenshot, and visual-token instructions are superseded by the binding
> [native macOS playbook](../NATIVE-MACOS-PLAYBOOK.md) and
> [HIG coverage audit](../HIG-COVERAGE-AUDIT.md).

## 0. Where the work actually stands

Measured on disk, not assumed:

| Layer | State |
|---|---|
| `Theme.swift` (470 lines) | ✅ rewritten |
| `Design/` — 11 components, 2 038 lines | ✅ built |
| `AppResources/make-icon.swift` | ✅ rewritten to the orb-and-stack mark |
| `docs/design/*.md` — 2 468 lines | ✅ written |
| **Screen adoption** | ❌ **1 of 36 view files** (`ContainerListRow.swift`) |
| Worktrees / branches | ❌ none — `git worktree list` shows only `main`, `/Users/allie/Develop/worktrees/` is empty |

**The shared layer landed and the three screen tracks never ran.** ~12 800 lines of view code still
render exactly the screens in `dist/shots/`. That is the entire remaining job, and it is the job
this plan sequences.

A consequence worth stating plainly: **nothing the user can see has changed yet.** The critique
findings are all still live.

---

## 1. Phase 0 — integrator, serial, before any agent starts

Nobody forks until this is done, because all three tracks depend on it and none of them can add it
without colliding.

1. **Land component deltas D1–D6** (COMPONENTS.md §3): search field, focused/unfocused selection,
   table-section guidance, `morbScrim()`, `text.tertiary` token, `MorbNumber` font reconciliation.
2. **Resolve the spec divergences** in COMPONENTS.md §4 — in particular `statusPaused` (the built
   `Theme.swift` says blue; the screenshots render amber; they cannot both be right) and
   violet-vs-rose in the series.
3. **Freeze** `Theme.swift` and `Design/**`. From this point they are integrator-only.
4. Create the three worktrees and branches:

```
/Users/allie/Develop/worktrees/shell       →  design/shell
/Users/allie/Develop/worktrees/containers  →  design/containers
/Users/allie/Develop/worktrees/resources   →  design/resources
```

All three branch from the same commit — the one containing the frozen shared layer. If the shared
layer is still uncommitted, **commit it first**; three agents rebasing onto a moving uncommitted
tree is the failure mode that produced the current empty-worktree state.

---

## 2. File ownership — exact, disjoint, exhaustive

Every `.swift` file under `mac/Sources/MorbstackAppCore/` appears in exactly one bucket below.
**An agent may not open a file it does not own, even to read-and-copy.** If you need to change a
file you don't own, you file it with the integrator.

### Agent A — "shell" · app chrome, palette, menu bar, settings · 3 897 lines

```
mac/Sources/MorbstackAppCore/App.swift                            604   ← Sidebar :210, DetailHost :391
mac/Sources/MorbstackAppCore/Palette/CommandPalette.swift         426
mac/Sources/MorbstackAppCore/Palette/PaletteCommands.swift        399
mac/Sources/MorbstackAppCore/Palette/FuzzyMatcher.swift           224   ← OWNED BUT DO NOT EDIT
mac/Sources/MorbstackAppCore/MenuBar/MorbMenuBar.swift            600
mac/Sources/MorbstackAppCore/MenuBar/TrackDChrome.swift           316
mac/Sources/MorbstackAppCore/MenuBar/TrackDAppBridge.swift        142
mac/Sources/MorbstackAppCore/Settings/MorbSettingsView.swift      564
mac/Sources/MorbstackAppCore/Settings/TrackDConfigEditor.swift    261
mac/Sources/MorbstackAppCore/Settings/TrackDSharingSettings.swift 270
mac/Sources/MorbstackAppCore/Views/Placeholders/PlaceholderView.swift 91
mac/Tests/MorbstackAppTests/TrackDFuzzyMatcherTests.swift
mac/Tests/MorbstackAppTests/TrackDSettingsTests.swift
mac/Tests/MorbstackAppTests/TrackALaunchRescueTests.swift
mac/Tests/MorbstackAppTests/TrackEShareStatusTests.swift
```

Work: COMPONENTS §5.1 (app shell / sidebar), §5.10 (Settings), §5.11 (MenuBar), §5.12 (Palette),
§5.13 (Placeholders).

**A owns the window.** `NavigationSplitView`, the sidebar column, `.windowToolbarStyle(.unified)`,
the `Settings` scene, `MenuBarExtra`. A does **not** add toolbar items to detail screens.

### Agent B — "containers" · Containers, detail, logs, stats · 4 750 lines

```
mac/Sources/MorbstackAppCore/Views/Containers/ContainersRootView.swift      428
mac/Sources/MorbstackAppCore/Views/Containers/ContainersChrome.swift        234
mac/Sources/MorbstackAppCore/Views/Containers/ContainerListRow.swift        273  ← already migrated
mac/Sources/MorbstackAppCore/Views/Containers/ContainerDetailView.swift     272
mac/Sources/MorbstackAppCore/Views/Containers/ContainerOverviewTab.swift    597
mac/Sources/MorbstackAppCore/Views/Containers/ContainerInspectTab.swift     341
mac/Sources/MorbstackAppCore/Views/Containers/ContainerInspectDetails.swift 401
mac/Sources/MorbstackAppCore/Views/Containers/ContainerLogsTab.swift        353
mac/Sources/MorbstackAppCore/Views/Containers/ContainerLogStore.swift       286
mac/Sources/MorbstackAppCore/Views/Containers/LogPipeline.swift             226
mac/Sources/MorbstackAppCore/Views/Containers/AnsiSGR.swift                 283  ← OWNED BUT DO NOT EDIT
mac/Sources/MorbstackAppCore/Views/Containers/ContainerStatsTab.swift       365
mac/Sources/MorbstackAppCore/Views/Containers/ContainerStatsHub.swift       211
mac/Sources/MorbstackAppCore/Views/Containers/ContainerMountModel.swift     313
mac/Sources/MorbstackAppCore/Views/Containers/ContainerMountRow.swift       167
mac/Tests/MorbstackAppTests/TrackBLogPipelineTests.swift
mac/Tests/MorbstackAppTests/TrackBMountModelTests.swift
```

Work: COMPONENTS §5.2–§5.5.

**B owns the flagship.** `hero-containers` and `hero-logs` are the two images that sell the app;
both are B's. **`AnsiSGR.swift` is the best code in the repo — it is owned so nobody else touches
it, not so B can rewrite it.**

### Agent C — "resources" · Images, Volumes, Networks, Disk, Stacks · 4 175 lines

```
mac/Sources/MorbstackAppCore/Views/Images/ImagesRootView.swift            689
mac/Sources/MorbstackAppCore/Views/Images/TrackCChrome.swift              474
mac/Sources/MorbstackAppCore/Views/Images/TrackCImageList.swift           182
mac/Sources/MorbstackAppCore/Views/Images/TrackCImageArchitecture.swift   234
mac/Sources/MorbstackAppCore/Views/Volumes/VolumesRootView.swift          438
mac/Sources/MorbstackAppCore/Views/Networks/NetworksRootView.swift        395
mac/Sources/MorbstackAppCore/Views/Stacks/StacksRootView.swift            446
mac/Sources/MorbstackAppCore/Views/Disk/DiskRootView.swift                621
mac/Sources/MorbstackAppCore/Views/Disk/TrackCConfirmSheet.swift          165
mac/Sources/MorbstackAppCore/Views/Disk/TrackCDiskMath.swift              531  ← OWNED BUT DO NOT EDIT
mac/Tests/MorbstackAppTests/TrackCDiskMathTests.swift
mac/Tests/MorbstackAppTests/TrackCImageArchTests.swift
mac/Tests/MorbstackAppTests/TrackCResourceListTests.swift
```

Work: COMPONENTS §5.6–§5.9.

C carries the most screens and the most table work. C also owns the **single
highest-embarrassment-per-line fix in the project**: the rendered markdown backticks in
`DiskRootView`'s VM-image prose (CRITIQUE §5). Do that one first.

### FROZEN — integrator only. No agent may edit these.

```
mac/Package.swift                                    ← .macOS(.v15); changing it changes everything
mac/Sources/MorbstackAppCore/Theme.swift
mac/Sources/MorbstackAppCore/Design/*.swift          (all 11)
mac/Sources/MorbstackAppCore/Models.swift
mac/Sources/MorbstackAppCore/AppModel.swift
mac/Sources/MorbstackAppCore/DockerClient.swift
mac/Sources/MorbstackAppCore/DaemonClient.swift
mac/Sources/MorbstackAppCore/Formatters.swift
mac/Sources/MorbstackAppCore/AppLaunchRescue.swift
mac/Sources/MorbstackAppCore/Sharing/FileSharingStatus.swift
mac/Sources/MorbstackAppCore/Shots/*.swift           (all 7)
mac/Sources/MorbstackKit/**                          (entire target)
mac/Sources/{MorbstackApp,MorbLive,MorbShots,morb,morbstackd}/**
mac/AppResources/make-icon.swift
mac/Tests/MorbstackAppTests/{ModelTests,StdcopyTests}.swift
mac/Tests/MorbstackKitTests/**
docs/design/**
```

`Shots/` being frozen matters: it composes `Sidebar`, `DetailHost`, `ContainerDetailView`,
`MorbMenuBarContent` and `CommandPalette` — i.e. it reaches across all three tracks. If a screen's
signature changes, the agent notes it in its handoff and the **integrator** updates `Shots/`.

---

## 3. Build discipline — the hard rule

The tree and the VM are shared. A build from the wrong place kills other agents' daemons.

1. **Each agent builds only inside its own worktree.** `cd /Users/allie/Develop/worktrees/<name>
   && swift build`. Separate worktrees have separate `.build/`, so this is safe.
2. **Nobody runs the app, `MorbLive`, `morbstackd`, or `MorbShots` during the parallel phase.**
   Not once. Screenshot regeneration and live runs are the integrator's Phase 2 step, done once,
   serially.
3. **Nobody touches `Package.swift`.** If a track thinks it needs macOS 26 as the target, the
   answer is no — go through `MorbGlass` (COMPONENTS §1).
4. `swift test` in your own worktree is fine and expected.

---

## 4. Phase 1 — parallel execution

All three run concurrently. Each agent's brief:

> Read `docs/design/IDENTITY.md`, `docs/design/COMPONENTS.md` and this file's §2 for your bucket.
> You own exactly the files listed. Apply the per-screen plan in COMPONENTS §5 for your screens.
> Never write a Liquid Glass API directly — call the `morb*` wrappers. Never edit `Theme.swift` or
> `Design/`. Build only in your worktree; do not run the app. When done, write a handoff note
> listing: files changed, any component gap you had to work around, and any change to a view's
> signature that `Shots/` will need.

**Ordering hint inside each track:** do the toolbar conversion (`.morbScreen`) first on every
screen you own. It is the change that unblocks all the others, it is mechanical, and it closes the
single biggest finding.

### Cross-track boundary rules

| Boundary | Rule |
|---|---|
| Toolbars | **Exactly one `.morbScreen(title:)` per detail root**, applied by the agent that owns that root. A owns the window's toolbar style and the sidebar toggle; B and C own their own screens' items. |
| Toolbar item ids | Namespaced by screen: `"containers.*"` (B), `"images.*"`, `"disk.*"`, … (C), `"app.*"` (A). Prevents duplicate-id collisions in `.toolbar(id:)`. |
| `StatusTone` | Has five cases and **no `degraded`**; `MenuBar/TrackDChrome.swift` switches exhaustively. Nobody adds a case. Group-level degradation is `MorbGroupState` (COMPONENTS §6). |
| Legacy forwards | `StatusDot`, `Chip`, `SectionLabel` stay alive through Phase 1 so all three can compile independently. The integrator deletes them in Phase 2. |
| New shared component | Not allowed in Phase 1. If two tracks need the same thing, both hand-roll it locally and flag it; the integrator promotes it in Phase 3. |

---

## 5. Phase 2 — merge and verify

Integrator only, serial, on a merge branch.

### 5.1 Mechanical gate

```
swift build            # once, by the integrator, in the merge worktree
swift test
```

### 5.2 Banned-symbol grep gate

Run over `mac/Sources/MorbstackAppCore/` **excluding** `Design/` and `Theme.swift`.
**Any hit is a merge blocker.**

| Pattern | Why it's banned |
|---|---|
| `\.glassEffect\(`, `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `ToolbarSpacer`, `buttonStyle\(\.glass` | Must go through `MorbGlass`; a bare call does not compile at `.macOS(.v15)` and will break someone else's build |
| `@available\(macOS 26` | The availability branch is taken once, in `MorbGlass.swift` |
| `accentColor`, `controlAccentColor` | CRITIQUE §3; use `Theme.accent` |
| `\.shadow\(` | One shadow in the app, and it lives in `Design/` (IDENTITY §4.3) |
| `Color\(red:`, `Color\(white:`, `#[0-9A-Fa-f]{6}` | Every colour is a `Theme` token |
| `accessibilityReduceMotion` | Must go through `Theme.animation(_:reduceMotion:)` |
| `alternatingRowBackgrounds` | REPORT documents why it was removed |
| `\.cornerRadius\(` | Deprecated; use `.clipShape(RoundedRectangle(cornerRadius:style:.continuous))` |
| `Text\("[A-Z][A-Z ]{3,}"\)` | All-caps section headers (CRITIQUE §3.1) |
| `padding\((?!Theme\.)[0-9]`, `spacing: (?!Theme\.)[0-9]` | Literal spacing outside the six-value scale |

### 5.3 Visual verification

1. Regenerate all 36 shots: `swift run MorbShots --out dist/shots`.
2. **Diff every one against the current set.** A screen that did not change is a track that did not
   land — that is exactly how the current state went unnoticed.
3. Specifically confirm, per screen:
   - A **real titlebar with traffic lights** is in frame. If any screen still has a painted header,
     that track failed its primary objective.
   - Sidebar is translucent, rows are 28pt, icons are tinted.
   - Settings has **no Save/Revert** and uses grouped `Form` sections.
   - The palette has a scrim and differentiated result icons.
   - The menu-bar popover is ~560pt, not ~1500pt.
   - No red trash cans in the Images table.
   - No rendered backticks anywhere.
   - No lavender circle in any empty state.

### 5.4 Accessibility and appearance matrix

Every screen, four passes:

| Pass | What must hold |
|---|---|
| Light / Dark | Both deliberate; no inverted-afterthought surfaces |
| **Increase Contrast** | `MorbGlassModifier` falls back to `Material` — verify no glass survives, and that `Theme.hairline(contrast:)` / `Theme.chipAlpha(contrast:)` are actually being consulted |
| **Reduce Motion** | Nothing animates except `ProgressView` spinners. Verify no track bypassed `Theme.animation(_:reduceMotion:)` |
| Contrast re-check | Re-run `_contrast.py` against any token that changed in Phase 0 |

### 5.5 Cleanup, only after the above passes

- Delete the legacy forwards in `Theme.swift` (`StatusDot`, `Chip`, `SectionLabel`,
  `Theme.cornerRadius`, `Theme.chipRadius`, `Theme.rowPadding`) once
  `grep -rn` finds no call sites outside `Theme.swift`.
- Update `Shots/` for any view signature changes flagged in the handoffs.
- Rewrite `dist/shots/REPORT.md`'s "Known visual gaps" against what is actually still true.
  Gaps #1 (empty tables), #2 (clipped log line), #3 (clipped settings), #5 (64-char digest) and
  #6 (row banding) all have plan entries; #4 and #7 are by design.

---

## 6. Phase 3 — follow-ups, explicitly out of scope for the three agents

Logged so they are decisions, not omissions.

1. **Icon Composer.** `/Applications/Xcode.app/Contents/Applications/Icon Composer.app` exists.
   Moving to a layered `.icon` document would give the system's own material, shadow, specular and
   the dark/clear/tinted variants for free — better than the programmatic `.icns`, especially at
   16–32pt. It is a build-system change (IDENTITY §1.6).
2. **`degraded` promoted into `StatusTone`**, with the `TrackDChrome` switch updated in the same
   commit.
3. **Empty tables.** Networks / Volumes / Stacks leave 40–55% of a 900pt window blank
   (REPORT gap #1). Either design a summary section per screen or shoot them shorter. Pick one.
4. **Promote any component both C and B hand-rolled** in Phase 1.
5. **A UI-string review pass.** The rendered backticks were not a one-off failure of one string;
   they are a failure of never reading the copy in situ.

---

## 7. Why the last attempt produced nothing, and what changes

The previous run built the shared layer, wrote 2 468 lines of specification, and then the three
screen tracks did not execute — no worktrees, no branches, no diffs. The specification is not the
deliverable; the screenshots are.

Three concrete changes:

1. ~~**Commit the shared layer before forking.**~~ **STRUCK — this diagnosis was wrong.** The real
   cause was structural and had nothing to do with commits: worktree isolation failed at spawn with
   `Cannot create agent worktree: not in a git repository`, because the harness recorded this
   working directory as non-git at session start (`git init` ran moments after that check was
   cached). No worktree could ever be created in this session, at any commit. Committing the shared
   layer first is still good hygiene, but it would not have helped. **The actual fix adopted:** run
   the three screen tracks SERIALLY in the main tree, each inheriting the previous track's rendered
   screenshots — which also produces convergence a merge gate cannot, since a gate can detect
   divergence but cannot create a shared dialect.
2. **Phase 0 is a blocking, serial step with a named owner.** D1–D6 and the §4 divergences are
   decided *before* anyone forks, not discovered by three agents simultaneously.
3. **Phase 2 diffs the screenshots and treats "unchanged" as failure.** The current state — a
   complete design system with one adopting call site — passed every check that existed, because
   the only check that would have caught it is looking at the pictures.
