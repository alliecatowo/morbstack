# Gallery

Real windows, real data — 16 containers, 26 images, a live `shopdemo` Compose project on a working
engine. Captured with [`scripts/capture-window.sh`](../../scripts/capture-window.sh), which grabs a
single window's own composited content rather than a screen region, so nothing else on the desktop
can leak in.

**Nothing here is staged, retouched or cropped to hide anything.** Where a screen still has a known
defect it is either absent from this page or the defect is named below it. This project has spent
real effort undoing claims that outran the code; a screenshot is a claim like any other.

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
the reference, digest, size, architecture and container references. The architecture row matters on
Apple silicon: an `amd64` image is flagged before you run it, rather than failing later with
`exec format error`.

### Disk

![Disk](disk.png)

Storage by category and the largest individual resources, with the VM disk's real numbers beside
them — **apparent size versus actual APFS usage**, which are wildly different for a sparse image and
are the source of most "why is Docker eating my disk" confusion. The prune action states exactly
what it will and will not remove.

### Kubernetes

![Kubernetes](kubernetes.png)

A single-node k3s cluster with real pods, nodes and events browsing. Worth noting because
OrbStack's Kubernetes UI has effectively none of this — logs and open-in-browser, and no resource
browser at all.

### Networks

![Networks](networks.png)

Built-in and user-defined networks, with the inspector showing driver, scope, IPAM pools, options
and attached members. Connect and disconnect explain in plain language what Docker will and will not
do to the container.

### Builds

![Builds](builds.png)

BuildKit cache records and build history, with per-record size, type, last-used and whether the
record is shared. The header is honest that the deduplicated total excludes records Docker marks
shared, so the same storage is not counted twice.
