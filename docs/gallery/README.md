# Gallery

Real windows, real data — a live `shopdemo` Compose project (five current services, one
publishing two TCP ports, one publishing UDP), three standalone containers reused across
sessions (`web-front`, `cache-node`, `dns-probe`), a real Kubernetes workload contributing
sixteen more, a real BuildKit cache, and 38 containers total on a working engine. Captured
with [`scripts/capture-window.sh`](../../scripts/capture-window.sh), which grabs a single
window's own composited content rather than a screen region, so nothing else on the desktop
can leak in.

**Nothing here is staged, retouched or cropped to hide anything.** Where a screen still has a
known defect it is either absent from this page or the defect is named below it. This project
has spent real effort undoing claims that outran the code; a screenshot is a claim like any
other.

This pass also required teaching the tour tooling to reach screens that only open as their own
window or their own inspector tab — `--tour-tab`, `--tour-stat-metric`, `--tour-open-terminal`
and `--tour-project-logs`, alongside the existing `--tour-container` — so a container's Files
and Statistics tabs, its terminal window, and a Compose project's log window can all be reached
without a click. `scripts/ui-tour.sh` now forwards any argument past the first three straight
to the app. See `LaunchOptions` in `App.swift`/`AppModel.swift`.

Two routes below are deliberately absent rather than stale: **Kubernetes**, because a different
session is actively driving Kubernetes work on this same machine this session was asked not to
collide with, and the **menu-bar extra**, which only opens by clicking its status-bar icon and
has no scriptable equivalent. Both are named honestly under
[Not yet captured](#not-yet-captured) instead of being left under an old caption pretending to
be current.

A fuller set, including light appearance and narrow widths, lives in `artifacts/` and is
deliberately untracked — it is regenerated every review pass.

---

### Containers, grouped by Compose project

![Containers](containers-compose-grouping.png)

16 running, 38 total. `shopdemo` collapses to a disclosure row headed **5 of 8 running** —
Compose has seen eight service names under that project across this sandbox's repeated demo
runs, five of them currently up — and **Kubernetes-Managed** collapses its own sixteen
`k8s_POD_*`/`k8s_*` containers into one row headed **8 of 16 running**, rather than burying the
containers someone actually typed `docker run` for under sixty-character machine names. Toolbar
search is now a glyph: the magnifying glass next to the inspector toggle, not a field in the bar
— no route keeps a permanent search field any more. The remaining toolbar controls sit in two
glass capsules at the trailing edge: the filter menu alone at the head of the run (a `Menu` is
the one thing that splits a placement run, so it moved there instead of fragmenting the group
behind it), record actions/search/inspector-toggle together in the second capsule.

### Containers, a selected record's detail tabs

![Container detail](containers-detail-tabs.png)

`shopdemo-web-1` selected. The five tabs — Overview, Logs, Files, Statistics, Inspect — are now
a segmented `Picker`, not a `TabView` (UI-055): a `TabView` inside `.inspector` draws a bordered
content box whose leading edge overdrew the inspector's own divider, measured at the seam as a
real pixel difference (`444f51` vs `61686b`) and reproduced in stock SwiftUI before the fix. The
inspector also now renders at its declared width — `.inspectorColumnWidth(min: 340, ideal: 400,
max: 520)` was previously discarded because the modifier sat underneath `.toolbar`/`.searchable`
instead of outermost on the inspector's content, so every route was stuck at SwiftUI's ~270 pt
default and clipping values ("Running" as "Runnin", "linux" as "linu"). Nothing here is clipped.

### Containers, the Files tab on a real container

![Container files](containers-files-tab.png)

`shopdemo-web-1`'s actual root filesystem (UX-4), read live through
`HEAD /containers/{id}/archive?path=X` with no exec and no shell in the container — `bin`,
`dev`, `etc`, `docker-entrypoint.d`, real entry counts per folder, `.dockerenv`,
`docker-entrypoint.sh`. Reached this pass via `--tour-tab files`, not a click.

### The container terminal, a live shell

![Container terminal](container-terminal.png)

An interactive `exec` session connected to `shopdemo-web-1` — the window title tracks the
resolved shell (`shopdemo-web-1 — /bin/sh`) and the prompt (`/ #`) with a live cursor is real
output from the container, not a placeholder. Opened this pass with `--tour-open-terminal`,
which calls the same `ContainerTerminalWindowController.open(for:client:)` the toolbar button,
context menu, and ⌃⌘T all call.

### Containers, the Compose-aggregated log window

![Compose project logs](containers-compose-logs.png)

The `shopdemo` project's merged log (UX-2/UX-3), opened this pass with `--tour-project-logs
shopdemo`: five services' `stdout`/`stderr` interleaved by real arrival time, each line
colour-coded and labelled by service, 3,038 lines and counting. **A real defect this capture
caught**: the window opens scrolled to the oldest lines still in the buffer rather than the
newest, even though the surface declares `.defaultScrollAnchor(.bottom)` and an
auto-follow-on-append rule — the `Jump to Newest` button stays visible instead of the tail. Not
fixed in this pass; worth its own ticket. The header's "5 of 8 services streaming" reflects the
same repeated-demo-run history as the Containers screen above, not a bug in the header itself.

### Containers, the Statistics tab's network rate chart

![Container network statistics](containers-statistics-network.png)

`shopdemo-web-1`, Network Activity selected via `--tour-stat-metric network` — reachable in the
app today only by a click on the Metric picker until this pass added the flag. Received/Sent are
cumulative Engine counters (90 KB / 236 KB here); the chart plots the derived per-interval rate,
visibly spiking to the mid-teens of KB/s while this capture ran repeated `curl` requests against
the container's published port and settling back to zero once they stopped — a real, driven
signal, not a static mock.

### Containers, the Statistics tab's disk rate chart

![Container disk statistics](containers-statistics-disk.png)

The same container, Disk Activity via `--tour-stat-metric disk`. Written climbs to 115.3 MB and
the chart shows a real spike from a `dd if=/dev/zero` run inside the container moments before
the capture, tapering to zero as the write finished — reads and writes served from page cache
never reach a block device and correctly never appear here, which the section's own footnote
states.

### Stacks

![Stacks](stacks.png)

`shopdemo` expanded by default, headed **5 of 8 services running · 1 degraded**. Eight service
rows, not five, because this sandbox has run the same Compose project name more than once
without cleanup — three exited rows (`api`, `cache`, `web`, no `-1` suffix) are leftovers from an
earlier untagged run sitting beside the five current `-1`-suffixed ones. Real, if untidy, data:
nothing here was trimmed to look cleaner than the engine's own history. The toolbar carries only
the filter menu and search glyph now; Stacks' three separate menus from before this session
merged into one `Divider`-sectioned menu (UI-054).

### Images

![Images](images.png)

31 images, 4.99 GB, 2 dangling. **In use** now shows real counts (0, 2, 8, 9…) instead of an
em-dash in every row — but only because this capture ran with `--tour-warm-disk-scan`, which
fires the same `/system/df` fetch a visit to Disk would. `GET /images/json` reports every
container count as `-1` on this engine, so the column is filled in from the most recent Disk
scan the same way Volumes' Size/In use columns are (`AppModel.mergeImageUsageFromDisk`); a
session that opens straight into Images without ever visiting Disk still shows every row as
unscanned, which is the honest state and the reason TASKS.md's TASTE-5 is still open rather than
closed by this screen alone.

### Disk

![Disk](disk.png)

**5.26 GB in use, 4.01 GB reclaimable** across Images (4.91 GB / 3.82 GB), Containers (207.6 MB
/ 163.9 MB estimated), Volumes (136 MB / 95.6 MB) and Build cache (6 MB / none). The VM disk
section now states reclaim is automatic and names the outcome of the last sweep in one sentence
— "Morbstack reclaims space from deleted images and containers automatically — periodically
while the guest runs, and once more every time it stops. The most recent sweep found nothing to
reclaim." — replacing copy that used to describe the recovery state machine itself. Apparent
77.31 GB against 6.57 GB actually on APFS is the pair that answers "why is Docker eating my
disk" on its own.

### Volumes

![Volumes](volumes.png)

Unchanged pattern, still correct: **Size** and **In use** are blank because Docker's volume list
never reports them, and the inspector says so once — *"Size and container references come from
the Disk scan. Open Disk to compute them."* — rather than printing a zero. This session's capture
never visited Disk first, which is why Volumes stays unscanned even though Images (captured with
`--tour-warm-disk-scan`, above) does not; the two screens are consistent with each other once you
know which one asked for the scan.

### Networks

![Networks](networks.png)

Six networks, three user-defined, two unused. `bridge` selected: Kind **Built-in**, seven
attached containers, full IPAM/capabilities/options detail, and **Show in Containers** to jump
straight to the seven members (the real `bridge` network holding `shopdemo`'s services and the
standalone containers together).

### Builds

![Builds](builds.png)

31 cache records, 6 MB deduplicated, 31 unused — a real cache from real `docker build` runs
against this engine. The **Cache/History** segmented picker sits centred in the toolbar; the
inspector shows both the aggregate (Deduplicated Total, Records, Unused, Shared, with a footnote
explaining the 13 records Docker marks shared are excluded from the deduplicated total so the
same storage is not counted twice) and the selected record's own detail (status, size, type,
record ID, created/last-used timestamps, use count, and whether its storage is exclusive or
shared).

### Migration

![Migration](migration.png)

Previously unphotographed — the ninth sidebar route, now populated: Docker Desktop detected as a
running source (7 images, 3 volumes, 1.25 GB, engine 27.4.0) compared directly against the
running Morbstack engine as destination (31 images, 6 volumes, 4.99 GB). The image plan states
what a copy would actually do — **2 to copy, 4 already present** — before anything is selected,
and the volume eligibility table gives per-volume reasons (3 eligible, 0 already existing at the
destination, 0 on an unsupported driver) rather than one blanket verdict.

---

## Not yet captured

- **Kubernetes.** A different session is actively driving Kubernetes work on this machine this
  pass, and was asked explicitly not to collide with it, so the route was skipped entirely
  rather than risk racing that work. The previous `kubernetes.png` in this gallery documented a
  now-fixed ECDSA/`SecKeyCreateWithData` credential defect and is now doubly stale — both its
  toolbar chrome (pre-UI-051/UI-055) and its cluster data predate this session. Left out rather
  than published under a caption it no longer earns.
- **The menu-bar extra.** Real and reachable in the running app, but it only opens by clicking
  its status-bar icon; there is no `--tour-*` or scriptable equivalent, and this pass's rule was
  no computer-use tools. The previous `menubar.png` predates this session's toolbar and inspector
  changes and is not republished here as current evidence.
- **The Compose log window's initial scroll position** (named above, under Containers) is a real
  defect, not a missing capture, but it was caught rather than fixed in this pass.
