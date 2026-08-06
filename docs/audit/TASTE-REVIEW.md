# Taste review — is this good, not is this broken

A defect register answers "is it broken" ([UI-AUDIT.md](UI-AUDIT.md), 48 rows). This document
answers the other question. Every finding is marked **LAW** (follows from
[DECISIONS.md](../design/DECISIONS.md) / [HIG-FINDINGS.md](../design/tahoe/HIG-FINDINGS.md), not
negotiable) or **TASTE** (opinion — argue with it). Findings become `TASTE-` tickets in
[TASKS.md](../../TASKS.md).

---

## Pass 1 — 2026-08-05, commit `de17215` (branch `swarm/cleanup`, main at `7f9af0d`)

Evidence: 35 real WindowServer captures in `artifacts/taste/` — all nine routes dark at
1600×1000, six light, three at 1100×700. Live engine, real data: 16 containers, 26 images,
the `shopdemo` Compose project, a populated BuildKit cache.

Known defects were not graded: the clipped inspector labels on Containers/Volumes/Networks/Disk
("ocker Name") are a filed layout bug. Where a judgement below touches a clipped pane, it is
about composition that would still hold after the clip is fixed.

### The best screen: Images at 1600, dark

`images-selected-dark-1600.png`. This is the bar the other routes should meet, and it is worth
saying exactly why it works:

- **The table earns its columns.** Repository, Tag, Image ID (dimmed monospace), Size, Created —
  five of six columns carry real, scannable information, and the eye lands on repository names
  first because everything secondary is visually quieter.
- **Grouping follows the data.** "Tagged Images" / "Dangling Images" is a real distinction Docker
  makes, not a decoration, and the one dangling 945 MB image is impossible to miss.
- **The subtitle is an honest summary**: "26 images · 2.99 GB · 1 dangling" tells you the state of
  the route before you read a single row.
- **The inspector is organized by question**: Image (identity), History, Repo Tags (collapsed),
  Container References, Archive, Actions. Buttons are grouped by kind, labeled with words, and
  carry ellipses where they open review.
- **It degrades with grace.** At 1100 wide the columns middle-truncate (`rancher/mirro…edns-coredns`)
  instead of collapsing, and the inspector holds its shape.

One flaw, filed below as TASTE-5: the "In use" column is an em-dash 26 times out of 26.

Honorable mention: **Disk**. Storage categories + largest individual resources is exactly the
right information architecture for "where did my disk go", and the Allocated bar (9.7% of a
77.31 GB sparse file) is factual capacity, not decoration — LAW-compliant use of a progress bar.
Its inspector prose is the problem (TASTE-6).

### What is already good and should not be touched

- **Empty states across the app are the honest kind, with actions.** "Kubernetes Is Off →
  Enable Kubernetes", "No Build Cache → Build Image / Refresh", "Build History Unavailable →
  Retry" with the truthful reason ("Buildx history did not return the documented JSON record
  list"). This is the "all functional, no coming soon" rule executed well. **LAW** — keep.
- **Cross-route rhythm is mostly there.** Same title+subtitle header, same accent selection, same
  search-field placement, same inspector-on-the-right grammar on every route. The app reads as
  one app. The sidebar with its counts (Containers 3, Stacks 1) is quiet and correct.
- **The Statistics tab** is restrained and right: one metric picker, one Swift Chart with an
  honest 0–10% scale, current value as text, sample values behind a disclosure. Only nit: it
  states its sampling twice ("5 readings over 8 seconds" and "Showing 5 readings, sampled about
  every 2 seconds" three sections apart).
- **The Inspect tab** is appropriately raw: searchable JSON, no attempt to prettify what is
  explicitly the raw document.

### Verdict on the new Compose grouping (Containers)

**It is a real improvement.** The three running containers now sit at the top of a 9-row list
instead of buried among 16, and the eight k8s scaffolding rows collapse to a single
"Kubernetes-Managed — 8 containers" line. The eye finds the signal first now. Verdict: keep.

Two problems it introduced, both cheap to fix (TASTE-2):

1. **Two grouping idioms on one screen.** `shopdemo` is a small lowercase section header;
   `Kubernetes-Managed` is a full list row with disclosure chevron, icon, and trailing count.
   They are the same concept — "a group of containers" — drawn two different ways, and the
   ungrouped five containers at the top have no header at all, so "shopdemo" floats mid-list
   looking like it might label the rows *above* it.
2. **Group headers say nothing.** UX-6's own deliverable specified "aggregate header row
   (n of m running)". `shopdemo` should read its state (0 of 3 running) without expanding.

### Findings

**F1 · TASTE · Stacks is the weakest screen in the app.** A live 3-service Compose project
renders as one collapsed pink bar above ~850 pt of void, and the inspector for that project has
four rows, one of which is "Compose files — Not reported". The route whose entire purpose is
"what is my project doing" hides the answer behind a disclosure chevron and shows almost nothing
when asked. Ticket TASTE-1: projects expand by default (at minimum when there are ≤3 projects),
service rows show status/image/ports inline, and the project inspector grows the per-service
breakdown it already has the data for (the subtitle can count "0 of 3 services running", so the
model knows).

**F2 · TASTE · The Containers list wastes its middle.** At 1600 pt each row is a name, ~900 pt
of nothing, and a status. The search placeholder promises "Name, image, or project" but the image
is invisible anywhere in the list — you cannot tell `lonely` from `netA` without selecting them.
Ticket TASTE-3: show the image reference as secondary text (subtitle or dimmed middle column),
and ports for running containers. Name, image, ports, status is the right handful; it is what
`docker ps` shows, and `docker ps` is the muscle memory this list replaces.

**F3 · TASTE · Absence is stated up to five times.** Volumes inspector, one unscanned volume:
"Size — Not reported", "Docker Usage — Usage unreported", "Docker References — Not reported",
then two footnote paragraphs restating both facts, and the table shows the same absence as two
em-dash columns. Five statements of one fact ("no disk scan yet"). The same disease in milder
form: Images ("Reported use — Not reported" + a paragraph + a dead column), Networks
("Containers — 0 attached" + "No containers are attached to this network."). Ticket TASTE-4:
state an absence once — one labeled row, one footnote per pane at most, and the footnote earns
its place only if it says what would change the state ("Run a Disk scan to populate usage").
This is the operator's "small and empty inspectors" and "prettify text blurbs" complaint; the
fix is subtraction, not decoration.

**F4 · TASTE · A column of 26 em-dashes.** Images table, "In use": every cell is "—". A column
whose every value is the same non-value is negative information — it teaches the eye to skip
columns. Ticket TASTE-5: populate it the way Volumes' usage columns populate after a Disk scan,
or drop it and leave the fact to the inspector.

**F5 · TASTE · Disk inspector leaks the state machine.** "Recovery Phase — host-grown",
"Saved Target — 77.31 GB", "The RAW image reached the saved target, but the guest filesystem
still needs verified proof.", "The daemon has not reported disk-growth readiness. Morbstack
checks the same preconditions again before any reviewed growth transaction." This is internal
recovery vocabulary ("verified proof", "growth transaction") printed as UI copy. Ticket TASTE-6:
one human status line ("Disk growth is paused until the guest filesystem check completes"),
detail rows behind a disclosure for the operator who wants them.

**F6 · TASTE · The Migration inspector is a wall.** ~17 LabeledContent rows and four footnote
paragraphs in one unbroken scroll, mixing runtime facts, plan counts, three zero-value
eligibility rows ("Eligible — 0 volumes", "Destination Exists — 0 volumes", "Unsupported
Driver — 0 volumes"), and defensive copy ("Morbstack never selects every image automatically").
Ticket TASTE-7: collapse the zero rows to one line when the source reports no volumes; cut each
footnote to one sentence; and either badge Morbstack in the sources table as the destination or
remove it from a list of things to migrate *from* — a destination listed among sources is an IA
wrinkle every new user will trip on once.

**F7 · TASTE · Long identifiers fight trailing alignment in the container Overview.** Separate
from the filed clipping bug: full `sha256:` digests, image references, and multi-sentence port
copy will always lose in a ~300 pt trailing-aligned value column. The Volumes inspector already
has the answer on screen — "Guest Mount Point" stacks its label above a full-width wrapping
monospaced value. Ticket TASTE-8: stack long identifiers (label above value, middle-truncated,
copyable), keep short facts as aligned pairs, and demote the Ports explanation ("Browser actions
use only Docker-reported bindings…") to a one-line footnote. Also nine section headers for one
container (Identity/Lifecycle/Configuration/Resource Limits/Networks/Ports/Environment/Mounts/
Labels) is more skeleton than body when half the sections hold one or two rows — merge
Identity+Lifecycle+Configuration into one "Container" group.

**F8 · TASTE · Small unit-and-word inconsistencies.** Networks "Containers" column mixes a
numeral ("3") with a word ("None") — a count column should say 0. Builds inspector carries a
filler row ("Storage — Included in deduplicated total"). Statistics states its sampling twice.
One sweep, ticket TASTE-9.

### Gallery shortlist — honest README shots

Rules applied: no staging, no cropping; if the best honest shot of a route shows a live problem,
the route stays out.

1. `images-selected-dark-1600.png` — the app's best screen: 26 real images, grouped table,
   selection, full inspector. Leads the gallery.
2. `containers-dark.png` — the Compose grouping doing its job (running containers on top, k8s
   noise as one collapsed row) and the well-composed no-selection state.
3. `containers-tab-statistics-dark-1600.png` — live CPU chart on a real container; proof the
   stats path is real, and the most restrained screen in the app.
4. `disk-dark.png` — the strongest information architecture: storage categories, largest
   resources, allocation bar, real reclaimable numbers.
5. `builds-list-dark-1600.png` — BuildKit cache with deduplicated accounting; depth competitors
   don't show.
6. `networks-selected-dark-1600.png` — a dense, fully-populated inspector with no visible
   clipping; the table's Kind column (Built-in/User-defined) is a genuinely useful editorial call.
7. `migration-dark.png` — the differentiator feature: Docker Desktop/Colima/OrbStack detected as
   sources with a real image plan. Verbose inspector (F6), but the shot is honest and strong.
8. `images-light.png` — appearance parity; the same screen holding up in light.

Excluded, and why:
- **Containers with selection** (`containers-selected-dark-1600.png`) — the inspector's clipped
  labels ("ntainer ID") are a live filed defect; a screenshot is a claim.
- **Volumes** — the honest shot is half em-dashes plus the five-fold "not reported" inspector
  (F3/F4). Gallery-ready after TASTE-4.
- **Stacks** — one collapsed row in a void (F1). Weakest screen; do not show it until TASTE-1.
- **Kubernetes** — the empty state is well made, but a README gallery slot spent on an off
  feature is a slot wasted.

### Overall verdict

**Structurally this already reads as a native Mac app** — real `NavigationSplitView`, real
tables, a real inspector, honest empty states, one consistent accent, and it survives light mode
and narrow widths without changing its grammar. Nothing here needs decoration, and nothing
recommended above adds any.

What separates it from first-class is **editorial, not structural**: two routes are under-fed
(Stacks shows almost nothing; the Containers list hides the image), absence is narrated instead
of stated, and internal vocabulary leaks into user copy on Disk and Migration. Every one of
those is subtraction or rearrangement inside the existing system vocabulary. Fix TASTE-1 through
TASTE-4 and the honest gallery grows by three routes.

*Pass 2 will re-capture these screens after the tickets land and judge each change on whether it
improved the screen — including the license to say a fix made it worse.*

---

## Pass 2 — 2026-08-05, commit `47adb92` (branch `swarm/cleanup`)

Evidence: the refreshed `docs/gallery/*.png` (real WindowServer captures, dark, 1600×1000, taken
after the fixes) plus the working captures in `/tmp/mrbcap/` — including the pre-fix Containers
shots (`verify.png`, `swallow-open.png`), which make honest before/after comparison possible.
Judged: TASTE-1, TASTE-2, TASTE-3, TASTE-4, TASTE-6. Not judged: UI-051 (the on-disk probes
predate the one-cluster implementation, which is in flight in another lane).

Two evidence gaps, stated up front rather than papered over:

1. **No narrow or light re-captures of the changed routes exist.** All five verdicts below hold
   at 1600 dark; TASTE-3's layout-priority behaviour (the image yields first when space runs out)
   is exactly the width-dependent claim pass 1 warned about, and it is unverified. Next capture
   session should include Containers at ~1100.
2. **No container in the capture set publishes a port**, so the ports third of TASTE-3 has no
   visual evidence either way. The code renders published ports monospaced-digit and sorted;
   whether the row still balances with a port list in the middle is unproven.

Neither gap is worth taking the machine lane for today. Both belong in the next routine capture.

### Verdicts on the landed tickets

**TASTE-1 (Stacks) — better, decisively.** The one collapsed pink bar became a legible project
block: `shopdemo` with "0 of 3 running" in the header, and three service rows each carrying
symbol, name, dimmed image, and status. The route now answers "what is my project doing" in one
glance without a single click, and the ~800 pt below is honest emptiness — one project is one
project. The row grammar matches Containers exactly, which is the cross-route rhythm pass 1
asked for. One deliverable did not land: the project inspector never gained its per-service
breakdown. **The list expansion demoted that deliverable** — with services inline, the inspector
no longer carries the route — so I am not re-filing it. What remains wrong in that pane is its
"Compose files — Not reported" row, which is an absence-vocabulary problem, folded into
TASTE-12 below.

**TASTE-2 (Containers grouping) — better.** One idiom now: both `shopdemo` and
`Kubernetes-Managed` are disclosure rows with a symbol and "n of m running". The before/after
pair proves the count change earns its place — in `verify.png` shopdemo's header says nothing
and the project looks plausibly alive; in the current shot "0 of 3 running" announces it is dead
before you read a row. The pass-1 worry about the five ungrouped containers needing an anchor
**dissolved without one**: once shopdemo became a chevroned row with indented children, nothing
floats and nothing is ambiguous. Not adding a "Standalone" header was the right call — it would
have been a label for the absence of a label.

**TASTE-3 (container rows) — better, two-thirds proven.** `lonely alpine:3.20` and
`netA nginx:alpine` are now different things at a glance, and the three running rows read like
`docker ps` output, which is the muscle memory this list replaces. Middle truncation for image
references is the right cut. The ports third is unproven (evidence gap 2), and the narrow
behaviour is unproven (gap 1). Nothing visible got worse.

**TASTE-6 (Disk inspector) — better; the fix exposed the next layer.** "Transaction Readiness",
"Recovery Phase — host-grown" and "verified proof" are gone, and each landed "no" names its
remedy. What the removal uncovered, in the captured state:

- The pane still states **one capacity five ways in seven lines**: "Apparent — 77.31 GB" in the
  section above, then "Current Raw Capacity — 77.31 GB", "Configured Capacity — 77.31 GB",
  "Capacity State — Matches configuration", and the summary sentence "The existing disk matches
  the configured capacity." Three names for one number across two adjacent sections, then a row
  and a sentence for one state. This is TASTE-4's disease, one route over. → TASTE-10.
- When readiness is unreported but the pending action is Stop Engine, the lead sentence
  ("Morbstack has not checked yet whether this disk can grow…") sits directly above a
  **Stop Engine** button it never mentions — the sentence and its own remedy disagree. Part of
  TASTE-10.

The verdict stands at better: what was removed was worse than what remains.

**TASTE-4 (Volumes inspector) — better on Volumes; the sweep stopped early.** The pane now says
"Usage — Not scanned yet" once, with one footnote that names the remedy ("Size and container
references come from the Disk scan. Open Disk to compute them."). That is exactly what the
ticket asked for, and nothing wanted was lost — the deleted "Docker Usage" row was derived from
a count the pane still prints after a scan. Three residuals:

- **Same pane, same disease, different fact**: "Volume — Anonymous" and "Prune — Eligible" are
  two rows computed from the one predicate `isAnonymousVolumeName`. The second restates the
  first, and "Eligible" reads as a safety verdict sitting directly above a Usage row that says
  usage is unknown. → TASTE-11.
- The ticket's own scope named the milder Images and Networks cases; **Images was not swept**.
  Its inspector still says "Reported use — Not reported" plus a remedy-free footnote, and the
  app now has two vocabularies for one category of absence: "Not scanned yet" (Volumes) versus
  "Not reported" (Images). → TASTE-12.
- One line, not graded, possibly a defect or capture ordering: the Disk route's "Largest
  Individual Resources" lists volume sizes (morbaudit_dbdata 47.8 MB, 9e1e5361fbbb 47.7 MB)
  while the Volumes route in the same gallery session says "Not scanned yet". If visiting Disk
  does not actually populate Volumes' usage, the footnote's remedy is a promise the app does not
  keep. Defect lane should verify the propagation.

**Did any fix make anything worse? No.** All five commits are net improvements, and none
overshot into removing information anyone would miss.

### Open tickets, updated view

- **TASTE-5** — still live, confirmed in `images.png`: 26 em-dashes out of 26. New constraint
  from this pass: whatever populates or replaces the column must share vocabulary with the
  Volumes pane ("Not scanned yet" where a scan is the remedy) — see TASTE-12.
- **TASTE-7, TASTE-8** — no new captures of Migration or the container Overview; pass-1
  judgements stand unchanged.
- **TASTE-9** — confirmed still live in `networks.png`: the Containers column mixes "3" with
  "None" on adjacent rows.
- **UI-051** — not judged this pass; the captures on disk predate the implementation.

### The bar, revisited

Images remains the best-composed route, but **Containers at rest is now the shot the gallery
should lead with**: three running containers on top with image and uptime, a dead project that
says it is dead, and eight rows of Kubernetes noise as one honest line. Two passes ago that
screen was sixteen undifferentiated rows. The delta is entirely subtraction and arrangement —
no decoration was added anywhere in these five commits, which is what this loop was for.
