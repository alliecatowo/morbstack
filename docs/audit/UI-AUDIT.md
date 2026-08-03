# Morbstack UI Audit — durable issue register

**Method:** real screenshots of the real window, driven with Computer Use against
`dist/Morbstack.app` (built 2026-08-03 14:54). Launched via `scripts/ui-tour.sh`.
No `dist/shots` / MorbShots renders were used or cited.

**Status:** OPEN. This is a register, not a one-shot report. Add rows; do not rewrite.
Update `Status` per row as issues are fixed. Keep IDs stable forever.

---

## READ THIS FIRST — coverage is partial and the gaps are not evenly distributed

This audit did **not** achieve the coverage the brief asked for. Being specific about
what was and was not looked at matters more than the issue count.

| Area | Covered? |
|---|---|
| Containers route — list, selection, all 4 inspector tabs, context menu, toolbar, live updates, stop/start | **Yes, thoroughly** |
| Narrow window width (~875pt) + live resize | **Yes** — produced UI-017/018/019/026 |
| View menu | **Yes** — produced UI-016, UI-031 |
| Volumes, Images, Disk routes | Observed (list/table + empty state + one inspector); no actions performed |
| Stacks route | **No** — only ever seen with fixture data. The real `morbaudit` stack was never viewed in the app. |
| Kubernetes, Networks, Builds, Migration | **No** |
| Settings (⌘,) and its tabs | **No** |
| Command palette (⌘K) | **No** |
| Menu-bar extra popover | **No** |
| File / Edit / Engine / Image / Compose / Window / Help menus | **No** — names observed in the menu bar only |
| Light appearance | **No** |
| Search behaviour + unmatched-search empty state | **No** — synthetic typing was blocked all session |
| VoiceOver / accessibility labels | **No** manual pass; machine audit results folded in as UI-027 |

**Why:** the machine lane was contended. Two separate XCUITest runs (`audit2-152336`,
`clean-152651`) were started by another agent during this audit, each launching its own
`MorbstackApp --tour-fixtures` instance. My own instance was displaced, and for several
minutes I was unknowingly driving the *test harness's* fixture window. Every observation
below has been checked against process `argv` to confirm which instance produced it.

**Screenshots were not written to `artifacts/audit/`.** They were captured inline and
reasoned from, but `save_to_disk` was not set, and by the time this was noticed the GUI
lane was blocked and they could not be retaken. The Evidence column therefore describes
what was seen rather than naming a file. This is a real defect in this audit; the next
pass must save every frame. Rows marked **[unverified-by-file]** need a screenshot
attached before they are cited externally.

---

## Severity definitions

- **blocker** — ships wrong information to the user, or prevents a core task.
- **major** — violates the project's own written standard in a way a reviewer would reject.
- **minor** — noticeable defect, does not block the task.
- **polish** — cosmetic.

---

## Issue register

| ID | Route / screen | Sev | What it does now | What it should do instead | Evidence | Status |
|---|---|---|---|---|---|---|
| UI-001 | Global (any `--tour-fixtures` launch) | **blocker** | A fixture-mode window is **visually indistinguishable** from a live one. It showed 11 fabricated containers (`shopfront-postgres-1` "Up 12 days (healthy)", `legacy-jenkins` "Up 9 days (Paused)", `registry-mirror` "Restarting (1) (unhealthy)"), consistent sidebar badges, and a Stacks header reading "2 projects · 8 of 9 services running · 1 degraded". The sidebar footer still read **"Engine running"** — affirmatively false, since fixture mode never dials the engine. | Any `tourFixtures` launch must carry a non-dismissible on-screen marker — window-title suffix and/or replacing the "Engine running" footer with an explicit fixture caption — so no fixture screenshot can ever be mistaken for evidence. | Fooled this auditor for ~60s; caught only by `docker inspect` showing none of the 11 exist, then confirmed via `argv` (`--tour-fixtures`). Same failure class the brief warns about for MorbShots. | Open |
| UI-002 | Containers — Overview tab | **blocker** | Published port renders as **`0.0.0.0:18,099`** — a thousands separator inside a port number. | Ports are identifiers, not quantities. Format with no grouping separator. | Zoomed Overview inspector; real port was 18099 and `curl localhost:18099` returned HTTP 200. | Open |
| UI-003 | Containers — toolbar | **major** | Toolbar reaches **~12 symbol-only items in 6 visual groups** when a container is selected with the Logs tab open: custom title+subtitle block, refresh, `···` menu, trash, "All" filter popup, sidebar toggle, play, **a second trash**, two more glyphs, two accent-filled circular toggles, warning triangle, search field. | Project's own rule (`HIG-FINDINGS.md`) is **max ~3 groups** and **≤1 primary action per screen**. Demote to a `Menu` / `.secondaryAction`. | Zoomed toolbar strip at 1440x900, dark. | Open |
| UI-004 | Containers — toolbar | **major** | **Two visually identical trash-can glyphs** sit in the same toolbar simultaneously, with no text and no visual distinction. Destroy different things (one list-scoped, one selection-scoped). | Two adjacent destructive controls that look the same is a correctness problem. Differentiate the glyphs, or collapse into one scoped action. | Same zoomed toolbar strip. Tooltips not captured for both — **[unverified-by-file]**, needs hover capture per item. | Open |
| UI-005 | Containers — toolbar | **minor** | Toolbar item set **changes on both selection change and inspector-tab change** — items appear/disappear as you click between Overview/Logs/Statistics/Inspect. | Toolbar should be stable for a route; contextual commands belong in the inspector or a menu. Churn defeats motor memory and is a likely contributor to UI-010. | Compared toolbar across Overview vs Logs vs Inspect on the same container. | Open |
| UI-006 | Containers — Statistics tab | **minor** | Grammar: **"1 readings over 1 second."** | Pluralize properly ("1 reading"). Exactly the "janky writing" class previously flagged. | Zoomed Statistics tab on first sample. | Open |
| UI-007 | Containers — Statistics tab | **minor** | Memory chart Y-axis is scaled to the **limit** (268.4 MB) not the data (1.2 MB), so the series is a flat line pinned to the axis. The memory-limit annotation label is **clipped by the pane edge** ("Me…"). | Scale to data with the limit drawn as a reference rule, and keep the annotation inside the plot area. | Zoomed Statistics tab, 34s window. | Open |
| UI-008 | Containers — Statistics tab | **minor** | X-axis over a 34-second window prints **"3:16 PM" six times**, last one truncated ("3:1…"). | Minute-resolution labels on a seconds-scale window carry no information. Use relative seconds or seconds-resolution ticks. | Zoomed Statistics tab. | Open |
| UI-009 | Containers — Logs tab | **minor** | **Every** nginx line rendered red with a warning triangle, including `[notice]` lines. Colour appears driven by *stream* (stderr) rather than by severity or ANSI codes. | nginx writes notices to stderr; stderr is not an error. Render real ANSI colour; do not synthesise severity from stream. | Logs tab on a stopped nginx container, 68 lines, all red. ANSI-colour rendering itself **not tested** — no container emitting ANSI was run. **[unverified-by-file]** | Open |
| UI-010 | Containers / global | — | **SIGTRAP: REFUTED.** Four independent attempts, all on `argv`-verified live instances (no `--tour-fixtures`), all clean: (1) open Logs then Inspect on a stopped container at 1440x900; (2) same on a running container; (3) **15× rapid ⌘1–⌘9 route switching at 1440x900**; (4) **16× rapid sidebar-click route switching at ~875pt narrow width**, cycling all seven `.searchable(placement: .toolbar)` routes including the toolbar-overflow transition. No crash, no NSToolbar assertion. | — | Repro attempts documented above. Note an earlier "no crash" result was **void** (it drove another agent's fixture instance) and was re-run from scratch. | **Refuted** |
| UI-011 | Containers — list | **minor** | The list is `List(selection:)` showing only **name + status**. No image, ports, CPU, or created columns; no sortable headers; **no sorting available at all**. | These are peer records with many attributes — the natural control is a real `Table` with sortable columns. `TABLE-SEMANTICS-AUDIT.md` sanctions `List` here, so this is a challenge to that decision, not a violation of it. A published port is invisible until you select the row. | Containers list, 6 real containers, dark, 1440x900. | Open — needs a decision |
| UI-012 | Containers — Overview tab | **minor** | Section headers ("State", "Configuration", "Ports") render in the **value column**, visually indistinguishable from data, while the label column holds the field names. Bottom "Memory Limit" group in Statistics uses right-aligned labels while the sections above use left-aligned — inconsistent within one tab. | Section headers should read as headers. Pick one alignment per pane. | Zoomed Overview and Statistics inspectors. | Open |
| UI-013 | Containers — Inspect tab | **polish** | Long JSON values are **clipped at the pane edge** with no wrap and no horizontal scroll (`"PATH": "/usr/local/sbin:/usr/local/bin:/usr/` just stops). Same in Overview for `Image ID` and `Command`. | Wrap, or provide horizontal scrolling, or truncate in the middle with a tooltip carrying the full value. | Zoomed Inspect tab. | Open |
| UI-014 | `morb status` (CLI, adjacent) | **minor** | Every published port is listed **twice** and the count is doubled: "published ports (8…)" for 4 actual ports, each of `18099/18100/18101/19999` printed twice. | Dual-stack (IPv4 + IPv6) listeners are one logical publication. Deduplicate. Matches the "paired dual-stack listener lifecycle" open item in the handoff doc. | `morb status` with 4 published ports. | Open |
| UI-015 | Window chrome | **polish** | There is no real window title; "Containers / 0 running · 4 total" is drawn as **custom toolbar content** in the leading position. | `HIG-FINDINGS.md` presumes a real window title (<15 chars, never the app name). A hand-drawn title+subtitle block is the custom chrome the design docs set out to remove. | All Containers screenshots. | Open |
| UI-016 | View menu | **major** | **No "Show Sidebar" / "Hide Sidebar" command exists.** View menu contains only: Show Tab Bar, Show All Tabs, the nine route items (⌘1–⌘9), Enter Full Screen. The sidebar toggle exists **only** as a toolbar button. | The single most standard macOS view command must be present, and the project's own rule is that every toolbar item has a menu-bar equivalent. | Confirmed twice: XCUITest `testSidebarUsesTheSystemViewMenuCommand` FAILED, and visually in the real View menu at narrow width. | Open |
| UI-017 | Images route, narrow width | **major** | At ~875pt window width the Images table collapses: the **Repository column header truncates to "R"** and every cell shows **one character** (`i`, `n`, `p`, `al`, `ra`…). Size column clips mid-unit ("52.8 M", "180.9"). No minimum column widths, no horizontal scroll. | Table is functionally unusable — you cannot tell which image is which. Enforce minimum column widths and scroll horizontally rather than crushing columns. | Narrow-width Images route, 15 real images. | Open |
| UI-018 | Disk route, narrow width | **major** | Inspector content **overlaps and overdraws the table** — two layers of text render on top of each other. Labels clip on the left ("Reclaimable" → "claimable"); body text runs off the right edge ("so category tota", "Named volumes"). | Panes must not overlap. Enforce a minimum content width and let the inspector collapse, as it does on Containers. | Narrow-width Disk route. | Open |
| UI-019 | Toolbar, narrow width | **major** | Toolbar items **silently disappear** as the window narrows — the `···` overflow menu present at 1440pt is simply gone at ~875pt, with **no `»` overflow affordance**. Commands living only in that menu become unreachable. | Items must overflow into the system toolbar overflow menu, never vanish. Compounds UI-016: commands with no menu-bar equivalent become completely unreachable. | Compared toolbar at 1440pt vs ~875pt on Containers. | Open |
| UI-020 | Containers — list | **major** | Running containers displayed **"Up 23 seconds"** while `docker ps` reported **"Up About a minute"** for the same containers at the same moment. The relative-time string does not refresh on a timer; it appears to update only when a Docker event arrives, so a steady-state container's uptime freezes. | Uptime must tick, or not be shown. This is stale data presented as live — the same defect class as UI-001, in miniature. | Side-by-side: UI screenshot at 15:34 vs `docker ps` at 15:34:10. | Open |
| UI-021 | Disk route | **minor** | Header reads **"1.31 GB reclaimable"**; `docker system df` totals **1.21 GB** reclaimable (Images 1.21GB + Containers 2.186kB + Volumes 0 + Build Cache 1.549kB). **~100 MB / 8% overstatement.** "1.34 GB in use" matches docker's 1.342GB correctly. | Reclaimable must match the engine's own accounting, or the differing definition must be stated. Overstating reclaimable space sets up a prune that under-delivers. | App Disk header vs `docker system df`. | Open |
| UI-022 | Empty states | **polish** | Inconsistent verb across routes: Containers says **"Select** a container to see…", Images says **"Pick** an image to see…", Volumes says **"Pick** a volume to see…". | One verb. Pick one and apply it everywhere. | Three empty-state screenshots. | Open |
| UI-023 | Containers — empty state | **polish** | "Select a container to see its configuration, logs, statistics, and **inspect document**." — "inspect document" is internal jargon; no user calls it that. | Name it in user terms, e.g. "…and its raw inspect JSON". | Containers empty state. | Open |
| UI-024 | Images — empty state | **minor** | `ContentUnavailableView` offers a **"Select First Image"** button. Selecting the first row is not a goal a user has; it is a workaround for having no selection. | Empty-state actions should offer something the user actually wants (Pull Image…). | Narrow-width Images route. | Open |
| UI-025 | Volumes route | **minor** | Table shows **"—" for both Size and In use** on a real volume. Both are obtainable (`docker system df -v`). Two em-dashes make the row information-free. | Populate, or state why unavailable. | Volumes route, `shopdemo_data`. | Open |
| UI-026 | Containers — list, narrow width | **minor** | Name and status columns **collide** at ~875pt — `api` / `Exited (0) 11 hours ago` sit ~2pt apart with no minimum gap and no truncation. A long container name would overlap the status outright. | Enforce minimum spacing; truncate the name with a tail ellipsis. | Narrow-width Containers list. | Open |
| UI-027 | Global — accessibility | **major** | XCUIAccessibilityAudit reports **8× "Element has no description"** and **3× "Contrast failed"** (+1 "nearly passed"). The app contains **zero `accessibilityIdentifier`**. | Every symbol-only control needs an accessible label. Given UI-003/UI-004 (≈12 symbol-only toolbar items, two identical trash cans), undescribed elements are almost certainly those buttons — which makes this a correctness bug, not polish. | XCUITest `testFixtureAccessibilityAudit` FAILED. **The individual 8 elements and 3 contrast pairs were NOT identified** — the audit test cannot attach screenshots ("Failed to get screenshot: Image creation failed"). **[unverified-by-file]** | Open |
| UI-028 | Search / empty results | — | XCUITest asserts "An unmatched search must use `ContentUnavailableView.search`, not an empty custom table". | Unmatched search should show `ContentUnavailableView.search`. | XCUITest `testSearchSelectionAndInspectorUseNativeControls` FAILED. **I could not confirm in the real window** — synthetic typing into the search field was blocked throughout this session. Needs manual confirmation. | Unconfirmed |
| UI-029 | Inspector | — | XCUITest asserts "Selecting a container must expose its inspector content" — failed under fixtures. | — | **Contradicted by my live testing**: selecting a container with a live engine reliably exposed Overview/Logs/Statistics/Inspect with real content, repeatedly. Likely fixture-specific or a query-semantics failure, not a live functional defect. Recheck before acting. | Likely not-a-bug |
| UI-030 | Test harness | **minor** | XCUITest accessibility audit cannot attach evidence: "Failed to get screenshot: Image creation failed. Disable automatic screenshots in your test plan's configuration." | Fix the `.xctestplan` screenshot setting so accessibility failures come with images — otherwise UI-027 can never be actioned. | XCUITest run output. | Open |
| UI-031 | View menu | **polish** | "Show Tab Bar" / "Show All Tabs" are advertised on a single-window utility app that has no meaningful tab model. | Suppress window tabbing (`NSWindow.allowsAutomaticWindowTabbing = false`) so the menu doesn't offer dead commands. | View menu screenshot. | Open |
| UI-032 | Sidebar / route switching | **polish** | Under rapid clicking, **route-selection clicks are dropped** — a 16-click sequence ended on the 15th target, not the 16th. | Not harmful, but it means click-driven automation cannot trust its final state. Worth a look alongside UI-005. | Narrow-width rapid switch sequence. | Open |

---

## What is genuinely good — preserve this

Specific, and verified against the real window, not inferred from source.

1. **Live updates are excellent and are the app's strongest UI property.** `docker run -d`
   from the CLI put the new row on screen with a green running dot in **under two seconds**,
   with no manual refresh; the header count moved `0 running · 4 total` → `1 running · 5 total`
   and the sidebar badge updated in step. Stopping from the UI updated the row to
   `Exited (137) Less than a second ago` and re-sorted it immediately. **Selection was
   correctly preserved** across list mutation — it did not jump to the new row. That is the
   hard part of live-updating lists and it is done right.

2. **The Statistics first-sample bug is genuinely fixed.** The known past defect (first
   sample was a lifetime average because `precpu` was zero-filled) does not reproduce. First
   reading was **100.6%** against `docker stats` **100.14%** at the same moment; after 34s the
   app read **99.9%** against **99.93%**. Memory (1.2 MB), limit (268.4 MB = 256 MiB) and
   percent (0.4% vs 0.43%) all matched. Real Swift Charts, real data.

3. **Empty states are correct and well written.** `No Live Statistics — "This container is
   not running. Its resource history is available only while it runs."` is honest, specific,
   and explains the *why*. Real `ContentUnavailableView`, not a hand-rolled panel.

4. **Toolbar tooltips are specific, not generic.** Hovering play gave **"Start auditburn"** —
   the actual container name, not "Start". Given UI-003/UI-004, these labels are doing a lot
   of load-bearing work.

5. **The context menu is a clean native `NSMenu`** with correct grouping and separators:
   Stop / Restart / Pause — Copy Name / Copy Container ID — Remove…. Nothing custom, nothing
   extraneous, destructive item last and correctly suffixed with an ellipsis.

6. **The inspector is a real `Form` + `LabeledContent` with `DisclosureGroup`s**
   ("Environment (7 variables)", "Labels (3 labels)") — counts in the summary line so you know
   whether expanding is worth it. Inspect tab shows genuine `docker inspect` JSON with its own
   scoped "Search document" field.

7. **No glass in the content layer.** Independently confirmed by source sweep: zero
   `.ultraThinMaterial` / `.thinMaterial` / `glassEffect` / `GlassEffectContainer` /
   card-shaped `RoundedRectangle` / `.shadow(` / `.cornerRadius(` anywhere under `Views/`,
   `App.swift`, `MenuBar/`, `Palette/`, `Settings/`. No `Theme.swift`, no `Design/**`, no
   `Morb{Card,Chip,Pill,Glass,Status,Row}` types. The Liquid Glass rewrite did land, and the
   content layer is clean. Selection colour is the **system accent**, not a brand pink —
   confirmed by the sidebar showing the correct unfocused-grey selection at the same moment.

---

## Notes for the next pass

- **Save every screenshot to `artifacts/audit/`** with a descriptive name. This pass did not.
- **Verify `argv` of the app you are driving before every session** — `ps -o args=` and check
  for `--tour-fixtures`. Two runs were contaminated by another agent's harness.
- Rows marked **[unverified-by-file]** need evidence attached before external citation.
- UI-010 (SIGTRAP) is **untested, not refuted**. Retry at narrow width, where toolbar overflow
  changes which `NSToolbarItem`s are realized at the moment two `.searchable(placement:
  .toolbar)` routes swap — a plausible trigger a wide-window test would miss.
- Seven of nine routes declare `.searchable(placement: .toolbar)` and swap through one
  `NavigationSplitView` detail column (`App.swift:569`) with no `.id()` identity break. That
  remains the best structural hypothesis for the reported crash.
- The app contains **zero `accessibilityIdentifier`**. Combined with ~12 symbol-only toolbar
  items (UI-003) including two identical trash cans (UI-004), VoiceOver quality is the single
  highest-value untested area.
