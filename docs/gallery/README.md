# Gallery

Real windows, real data — 16 containers, 26 images, a live `shopdemo` Compose project on a working
engine. Captured with [`scripts/capture-window.sh`](../../scripts/capture-window.sh), which grabs a
single window's own composited content rather than a screen region, so nothing else on the desktop
can leak in.

**Nothing here is staged, retouched or cropped to hide anything.** Where a screen still has a known
defect it is either absent from this page or the defect is named below it. This project has spent
real effort undoing claims that outran the code; a screenshot is a claim like any other.

Two of the routes below — Kubernetes and Builds — were empty on the captured engine, and are shown
empty. An empty state is a screen you will actually see, and both of these say something true while
they are on screen. Nothing here was filled in to make a page look busier. Where a route has more to
show than the capture caught, that is stated in the caption and listed under
[Not yet captured](#not-yet-captured).

A fuller set, including light appearance and narrow widths, lives in `artifacts/` and is
deliberately untracked — it is regenerated every review pass.

---

### Containers, grouped by Compose project

![Containers](containers-compose-grouping.png)

The list groups by Compose project — `shopdemo` holds its three services — and collapses
Kubernetes' own scaffolding into a single **Kubernetes-Managed** row. Before this, eight
`k8s_POD_*` containers with 60-character names sat inline and buried the three containers you
actually care about. The running/stopped dot, the relative uptime and the project heading are doing
all the work; there is no custom chrome on this screen at all.

### Stacks

![Stacks](stacks.png)

A Compose project's services *are* its content, so projects open by default and the header carries
the fact you would expand it for — **0 of 3 running**. Each service shows its image and status, the
same handful `docker ps` shows, so the screen answers "what is this and is it up" without a click.

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

Kubernetes is **off by default**, and this is what off looks like: a real
`ContentUnavailableView` with one honest sentence and one button, not a greyed-out dashboard with
"coming soon" written across it. Enabling it installs a single-node k3s cluster into the same VM,
wired to the same `dockerd` everything else uses — see [`../k8s.md`](../k8s.md). **The enabled
cluster is not captured here.** A screenshot of the running resource browser belongs on this page
and does not exist yet; see "Not yet captured" below.

### Networks

![Networks](networks.png)

Built-in and user-defined networks, told apart by a **Kind** column rather than by folklore about
which names are special. The inspector carries driver, scope, network ID, capabilities, IPAM pools,
options and the three attached containers, with **Show in Containers** to jump straight to them.
`Connect Container…` is visible but disabled for this selection; the sentence explaining why sits
directly under it, below the bottom edge of this capture.

### Builds

![Builds](builds.png)

Also an empty state, and also worth keeping. There is no build cache on this engine, so the route
says exactly that — and uses the empty state to explain the accounting rule you would otherwise
discover by arithmetic: **records Docker marks shared are kept out of the route's storage total, so
the same bytes are not counted twice.** The Cache/History control is live; a populated cache list is
not captured yet.

---

## Not yet captured

Everything above is a real window. These are real screens too, but nobody has photographed them, so
this page says nothing about how they look:

- **Kubernetes, enabled** — the pod, node and event browser behind `morb k8s enable`.
- **Builds, populated** — BuildKit cache records and `buildx history` entries with per-record size,
  type, last-used and shared flags.
- **Migration** — the ninth sidebar route, which compares another runtime's images against
  Morbstack's and imports selected ones ([`../migrate.md`](../migrate.md)).
- **The container detail tabs** — Overview, Logs, Statistics and Inspect, each of which has more in
  it than the list row that opens it.
- **The container terminal** — the interactive `exec` window described in [`../exec.md`](../exec.md).
- **Settings, the menu-bar extra, and the light appearance** of every route above.

**There are no animated captures.** No `.gif` or video exists anywhere in this repository, and
nothing on this page is a still frame lifted from one.
[`scripts/capture-window.sh`](../../scripts/capture-window.sh) takes single stills via
`screencapture -l` and has no frame loop; recording a real interaction would need a separate capture
path — a timed still sequence assembled into a GIF, or a WindowServer screen recording scoped to the
one window. Until that exists, this page shows what a window looked like, not what using it feels
like, and it will not pretend otherwise.
