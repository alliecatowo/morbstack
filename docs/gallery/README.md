# Gallery

Real windows, real data — a live `shopdemo` Compose project (5 services, one publishing two TCP
ports, one publishing UDP), a running k3s cluster, a real BuildKit cache, and 36 containers total on
a working engine. Captured with
[`scripts/capture-window.sh`](../../scripts/capture-window.sh), which grabs a single window's own
composited content rather than a screen region, so nothing else on the desktop can leak in.

**Nothing here is staged, retouched or cropped to hide anything.** Where a screen still has a known
defect it is either absent from this page or the defect is named below it. This project has spent
real effort undoing claims that outran the code; a screenshot is a claim like any other.

One route below — Kubernetes — is shown in a genuinely broken state, not an empty-by-design one; the
caption says exactly what is wrong and what was and was not fixed. Nothing here was filled in to
make a page look busier. Where a route has more to show than the capture caught, that is stated in
the caption and listed under [Not yet captured](#not-yet-captured).

A fuller set, including light appearance and narrow widths, lives in `artifacts/` and is
deliberately untracked — it is regenerated every review pass.

---

### Containers, grouped by Compose project

![Containers](containers-compose-grouping.png)

The list groups by Compose project — `shopdemo` holds its five services — and collapses
Kubernetes' own scaffolding into a single **Kubernetes-Managed** row. `shopdemo-web-1` publishes two
TCP ports (8090, 8443) and `shopdemo-dns-probe-1` publishes UDP (5300/udp), both visible in the Ports
column without opening the row. The running/stopped dot, the relative uptime and the project heading
are doing all the work; there is no custom chrome on this screen at all. The toolbar is this
session's other change: the search field sits centred (`.searchable(placement: .toolbarPrincipal)`),
the filter menu immediately left of it, and `+`/inspector-toggle at the far right, against the
inspector edge — see [`../../TASKS.md`](../../TASKS.md)'s UI-051 entry for the mechanism and why the
previous trailing-edge placement read as a detached strip.

### Containers, a selected record's detail tabs

![Container detail](containers-detail-tabs.png)

`shopdemo-web-1` selected, showing the detail pane's five tabs — Overview, Logs, **Files**,
**Statistics**, Inspect — the two bolded ones new this session (UX-4's read-first filesystem browser,
UX-9's network/disk-I/O rate charts on top of the existing CPU/memory charts). This capture is the
Overview tab only; driving to Files or Statistics needs a real click and this session's evidence tools
could not reliably deliver one against this route's real (non-fixture) data — see
[Not yet captured](#not-yet-captured).

### Stacks

![Stacks](stacks.png)

A Compose project's services *are* its content, so projects open by default and the header carries
the fact you would expand it for — **5 of 8 running**. Each service shows its image and status, the
same handful `docker ps` shows, so the screen answers "what is this and is it up" without a click.

### The menu-bar extra, expanded

![Menu bar](menubar.png)

UX-10's depth: containers grouped by Compose project (`shopdemo`, 5 of them) and by origin
(**Standalone**, **Kubernetes-Managed** with an 8-more overflow), and a **Published Ports** section
naming which container owns each forwarded port — real ports from the same `shopdemo` project shown
above. It stays a menu, not a second dashboard.

### Images

![Images](images.png)

A real `Table` with sortable columns, dangling images in their own section, and an inspector showing
the reference, image ID, size, architecture and container references. The architecture row matters on
Apple silicon: an `amd64` image is flagged before you run it, rather than failing later with
`exec format error`.

### Disk

![Disk](disk.png)

Storage by category and the largest individual resources, with the VM disk's real numbers beside
them — **apparent size versus actual APFS usage**, which are wildly different for a sparse image and
are the source of most "why is Docker eating my disk" confusion. The prune action states exactly
what it will and will not remove.

### Volumes

![Volumes](volumes.png)

The interesting part of this one is the two em-dashes. **Size** and **In use** are blank because
Docker's volume list does not report them, and the inspector says so in as many words — *"Size and
container references come from the Disk scan. Open Disk to compute them."* — rather than printing a
zero and letting you believe it. `Usage` reads **Not scanned yet**, not `0 B`. Remove explains that
Docker will refuse if the volume is attached, and that it cannot tell you what is in there first.

### Kubernetes

![Kubernetes](kubernetes.png)

**This is a real defect, captured honestly rather than avoided.** The cluster behind this screen is
enabled and healthy — `morb k8s status` reports `1 of 1 node ready`, `4 of 4 pods ready`, matching the
header — and a real `kubectl` against the same kubeconfig file works. But the app's own resource
reader cannot authenticate to it: `KubernetesAPICredential` builds a `SecIdentity` from the
kubeconfig's client certificate and key, and it assumed an RSA key. k3s (Morbstack's bundled
Kubernetes) issues ECDSA keys by default. This session fixed that specific assumption
(`KubernetesAPIClient.swift`, reading the PEM header instead of hardcoding `kSecAttrKeyTypeRSA`), but
the exact same failure persists after the fix, which means a second problem sits behind it —
plausibly `SecIdentityCreate` itself, which is not a conventional public constructor on macOS (unlike
iOS, macOS normally mints a `SecIdentity` by importing a cert+key pair into a keychain, not by
pairing bare `SecCertificate`/`SecKey` objects). Not resolved this session; recorded in the commit
history rather than declared fixed. The picker at the toolbar's centre (Pods/Nodes, a `.principal`
item) and the search field this session moved to `.toolbarPrincipal` cannot be shown coexisting as a
result — this screen is the one case where the data path that mounts search never renders.

### Networks

![Networks](networks.png)

Built-in and user-defined networks, told apart by a **Kind** column rather than by folklore about
which names are special. The inspector carries driver, scope, network ID, capabilities, IPAM pools,
options and the five attached containers (the real `bridge` network, holding `shopdemo`'s services
plus the standalone containers), with **Show in Containers** to jump straight to them.

### Builds

![Builds](builds.png)

A real, populated cache — 31 records, 6 MB deduplicated, from real `docker build` runs against this
engine (one with `--no-cache` specifically to produce unshared, attributable bytes). This capture
also proves a real, reproducible bug found and fixed this session: on first navigation to this route
directly (which is what happens whenever it is the last-viewed route, or is opened via
`--tour-select`), the cache load raced the daemon's first engine-status round trip and silently never
retried, leaving a truthful-looking but wrong "No Build Cache" empty state forever. Fixed by folding
`engine.isRunning` into the `.task(id:)` that gates the fetch, in `App.swift`, alongside the same
latent bug on the Disk route. The **Cache/History** segmented picker (`.principal`) sits left of
centre and the search field (`.toolbarPrincipal`) sits right of it in the same centre run, answering
this session's one open toolbar question: the two placements share the region sequentially rather
than colliding.

---

## Not yet captured

Everything above is a real window. These are real screens too, but nobody has photographed them, so
this page says nothing about how they look:

- **Kubernetes, resources actually listed** — blocked on the `SecIdentityCreate` failure described
  above, not on anything this page could stage around.
- **Migration** — the ninth sidebar route, which compares another runtime's images against
  Morbstack's and imports selected ones ([`../migrate.md`](../migrate.md)).
- **The Statistics tab's charts** (network + disk I/O rates, UX-9) and the **Files tab** (UX-4) with
  a real directory listing, both reachable in the app right now but not driven to in this pass — see
  below.
- **The container terminal**, actually opened and holding a live shell — the interactive `exec`
  window described in [`../exec.md`](../exec.md).
- **The Compose-aggregated log window** (UX-2/UX-3) — per-service interleaved output, the wrap toggle,
  clickable links.
- **Settings and the light appearance** of every route above.

**Why the interactive captures above are missing, specifically.** This session had no Computer Use
access and no Accessibility permission for scripted mouse/keyboard control (`osascript`/System Events
both refused with "not allowed assistive access"), so the only interaction channel left was
`XCUITest`. That worked for the sidebar and for buttons the moment a route had focus, but clicking a
real (non-fixture) `List` row to select a container — the one action every capture above needed —
did not reliably register a selection in this environment; a synthetic click that silently fails to
select, followed by an arrow-key fallback, was once observed to move the *sidebar's* selection
instead (confirmed by capturing the wrong route entirely), because keyboard focus had never actually
reached the content list. The menu-bar and Builds/Disk captures above did not need a row selection and
came through the same harness cleanly. This is recorded here rather than worked around with a fixture
window standing in for a real one.

**There are no animated captures.** No `.gif` or video exists anywhere in this repository, and
nothing on this page is a still frame lifted from one.
[`scripts/capture-window.sh`](../../scripts/capture-window.sh) takes single stills via
`screencapture -l` and has no frame loop; recording a real interaction would need a separate capture
path — a timed still sequence assembled into a GIF, or a WindowServer screen recording scoped to the
one window. Until that exists, this page shows what a window looked like, not what using it feels
like, and it will not pretend otherwise.
