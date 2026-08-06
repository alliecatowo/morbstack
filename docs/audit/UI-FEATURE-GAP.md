# UI feature gap — Docker Desktop / OrbStack vs Morbstack

**Written 2026-08-05.** Evidence lives in
[COMPETITOR-UI-RESEARCH.md](COMPETITOR-UI-RESEARCH.md) (sourcing labels intact); this file is the
delta and the verdicts. Morbstack's side is read from source on `swarm/continuation` at the time of
writing — two agents are actively editing `MorbstackAppCore`, so "we have" claims carry file paths,
not permanence guarantees. Engine-level capability ranking is
[../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md); this file is about **screens**.

**The standard for every verdict** (user's words: *"set the bar as if they can do it we can do it
better for free and without as much overhead and cruft"*):

- **Better** — where their feature ships with a documented sharp edge, matching it is failure.
- **For free** — structural. No account, no credential store, no telemetry means some designs are
  available to us that are not available to them. Those are "build differently", not "build cheaper".
- **Without the cruft** — a skip verdict is a product decision, not a backlog omission. Absence is
  shipped by default and can only be spent once.

Verdicts: **build** · **build differently** · **in flight** (already ticketed/underway) ·
**defend** (we lead; do not regress) · **skip** (deliberate, with reasons).

---

## 1. Logs — verdict: **build** (make the good one better)

**Them.** Docker: ⌘F search with regex, highlighted matches, Enter/Shift+Enter stepping, timestamps
toggle, copy/clear, clickable links, per-container filter inside a Compose app (VERIFIED). ANSI,
wrap, follow, stdout/stderr distinction all *undocumented*. OrbStack v2.x: Compose logs merged into
one colour-coded stream, one colour per service (REPORTED, consistent); their tracker documents the
sharp edges — #2178 *"if you search in the logs it hides everything except the line you're searching
for"* (fixed only in v2.2.0), #536 no wrap toggle, #711 auto-scroll stealing the viewport.

**Us.** `Views/Containers/ContainerLogsTab.swift` + `LogPipeline.swift` + `ContainerLogStore.swift`:
filter with match count, timestamps toggle, follow with jump-to-newest (scroll-away disables follow —
#711 already handled), jump-to-next-stderr, real ANSI (`AnsiSGR.swift`), copy/export/clear,
dropped-lines marker, honest empty states. This is already more *documented* behaviour than Docker
ships. The user's "text blurb" read undersells it — the work is upgrade, not greenfield.

**The delta, in order:**

1. **Our filter is OrbStack #2178, unfixed.** `store.query` hides non-matching lines; there is no
   highlight-and-step mode that preserves context. A competitor ate two minor versions of complaints
   for exactly this. Cheapest, highest-frequency win in this entire document. → **UX-1**
2. **No Compose-aggregated view.** Stacks can only deep-link to one container's log
   (`StacksRootView.swift` → `TrackDAppBridge.reveal`). The merged, per-service-coloured stream is
   the thing people actually praise OrbStack for. Our `LogPipeline` already normalizes lines; the
   aggregation is a UI-and-merge problem, not a transport problem. → **UX-2**
3. **No wrap toggle, no clickable links.** Both documented as wants/haves elsewhere (#536; Docker's
   clickable links VERIFIED). Small. → **UX-3**

"Block based" (the user's phrase) is best read as: lines that belong together *look* grouped —
per-service colour bands in the aggregated view, a visually distinct match-navigation state, and the
existing stream/timestamp columns. Not cards, not bubbles; the design law (§1.7) still holds.

## 2. Container filesystem browsing — verdict: **build** (read-first)

**Them.** Docker Desktop has a **Files** tab: browse, edit in place, drag-and-drop, download to host
(VERIFIED). OrbStack has a Files tab *and* the same tree in Finder at
`~/OrbStack/docker/containers/<name>` (VERIFIED).

**Us.** Nothing. `ContainerDetailView.swift` tabs are Overview/Logs/Statistics/Inspect. The only
file affordance is reveal-in-Finder for *bind mounts* (`ContainerMountRow.swift`) — which is the
host's own directory, not the container's filesystem.

**Delta.** Whole feature. The Engine API already carries it with no credentials and no new
transport: `HEAD/GET /containers/{id}/archive` (stat + tar out) and `PUT` (tar in). An honest first
ship is browse + download ("Save to host…"); in-place edit/upload is a second decision because it
rewrites a running container's filesystem and deserves its own confirmation semantics. → **UX-4**.
OrbStack's Finder projection of *containers* is a much bigger engine commitment; the volumes half of
that idea is already DIF-7 and stays there.

## 3. Registries and Hub — verdict: **build differently**

**Them.** Docker Desktop: sign-in, Hub search, **Local vs Docker Hub repositories** tabs, push/pull
with stored credentials, org/team views, Scout on images. Hub-only — no built-in browsing of ghcr,
ECR, or anything else, because the UI is built around one vendor's account (VERIFIED). Registry
Access Management (allowlisting registries for a fleet) is Business-tier admin surface.

**Us.** Deliberately account-free: read-only public Hub search
(`Views/Images/PublicImageDiscoverySheet.swift`, no credentials by construction), pull, tag, run,
archive import/export, with every sheet stating exactly what it will not do. No push, no login, no
credential store — and `MorbDockerContext.swift` goes out of its way to *preserve* the user's own
`credsStore` so the Docker CLI keeps handling auth.

**The honest subset, stated as design:**

- **Discovery** — Hub is the only major registry with an anonymous *search* API; ghcr/ECR/GCR mostly
  are not searchable anonymously, but **manifest/tag browsing by name** is anonymous on any registry
  serving the OCI distribution API. Since we have no credential store biasing us toward one vendor,
  "paste any `registry/repo` reference, browse its public tags and platforms" is a feature Docker
  Desktop structurally does not offer. Whether that is worth a screen is a decision, not a sprint.
  → **UX-5 (spike → decision)**
- **Push and private pulls stay in the CLI.** The GUI never holds a credential; the CLI already uses
  the user's `credsStore`. This is a boundary to write down and defend, not a gap to close.
- **Org/team views, RAM, IAM** — skip (see §12).

## 4. Container list — verdict: **build** (grouping), decided (columns)

**Them.** Docker groups containers by **Compose project into collapsible entries** (VERIFIED);
per-row hover actions incl. "Open in terminal"; copy-docker-run; open port in browser. List columns
and bulk-select mechanics unverified. OrbStack's list columns/sort likewise unverified.

**Us.** `ContainersRootView.swift`: flat `List` (name + ticking status), All/Running scope, search
that already matches compose project/service names, full context menu, port open-in-browser, live
updates that UI-AUDIT calls the app's strongest property.

**Delta.** Grouping: a compose project's containers appear as unrelated peers; the project exists
only as hidden search text. Collapsible project sections with an aggregate header row (n of m
running, project lifecycle menu) fold Docker's best list idea into our existing `List` without
reopening UI-011 (Table-vs-List was **decided** 2026-08-04 — keep `List` + inspector; this respects
that). → **UX-6**. Copy-`docker run`-command is a nice-to-have for the context menu, folded into the
same ticket. Noise handling (k8s scaffolding, exited containers): our All/Running scope covers
exited; neither vendor's k8s-scaffolding filtering could be verified, and our k3s runs in its own
route anyway — no ticket.

## 5. Terminal / exec — verdict: **in flight** (DIF-2)

Both competitors put a shell one click away; OrbStack embeds Ghostty (VERIFIED). Our bounded exec
sheet (`ContainerExecSheet.swift`) is honest but deliberately not a terminal. A real PTY terminal is
being built **right now** (`mac/Sources/MorbstackAppCore/Terminal/`, DIF-2). No new ticket; the only
UX note is that when it lands it must be reachable from the container context menu, detail view, and
menu-bar extra in one click, like theirs. Debug-shell-for-distroless is DIF-8, already ticketed as
the one genuine paywall in this market to give away.

## 6. Volumes — verdict: **build differently** (browse), **in flight** (Finder = DIF-7)

**Them.** Docker: **Stored data** tab browses contents, right-click → Save as…; export/import/clone
**require sign-in**, scheduled exports are paid (VERIFIED). OrbStack: volumes visible in Finder under
`~/OrbStack` (VERIFIED).

**Us.** `VolumesRootView.swift`: sortable table with size/in-use (fed by the Disk scan, UI-025),
create, **export with no account** (`VolumeArchiveExportWorkflow.swift`) — we already beat Docker's
sign-in gate for the same local file operation, and the doc should say so out loud.

**Delta.** No way to *see inside* a volume without running a container by hand. Mechanism is
genuinely open — the Engine API has no volume-contents endpoint; the options (throwaway helper
container with the volume mounted vs a guest-agent path in `morbinit` vs waiting for DIF-7's Finder
projection) have different costs and different honesty. This project's rule: decide before
implementing. → **UX-7 (spike → decision)**

## 7. Images — verdict: **build differently** (scanning), small build (layer detail)

**Them.** Docker: Local + Hub tabs, In-use/Unused/Dangling filters, detail with history, layers,
base images, and Scout vulnerability breakdown grouped by package with expandable fixes (VERIFIED) —
tied to a Docker account and per-tier repo quota.

**Us.** `ImagesRootView.swift`: sortable table, tagged/dangling sections, in-use column, history,
container references, arch compatibility, prune with byte counts, pull/tag/run/import/export. Layer
detail is a flat history section rather than a per-layer size+command inspector — small polish, folded
into no ticket yet; not day-changing.

**Delta.** Vulnerability scanning with no account and no quota is the "free is structural" story at
its clearest — `syft`/`grype` locally. But `morb scan` currently references a fetch script that does
not exist (DOC-5): **the CLI promise must be kept before any GUI surface repeats it.** Decision
needed on bundling vs first-run fetch (both sha256-pinned per repo law), then an Images-inspector
surface. → **UX-8 (spike → decision, after DOC-5)**

## 8. Builds — verdict: **skip for now** (record why)

Docker's Build view is the most sophisticated screen either product has: real-vs-accumulated time,
cache usage, eight operation types, dependency graphs, failure inlined against the Dockerfile, trend
charts (VERIFIED). It is genuinely good — and it is also in service of selling Build Cloud, and it is
weeks of UI for a surface most developers visit only when a build breaks. We have a real Builds route
(`BuildsRootView.swift`: buildx cache + history tables, logs with save). The honest next increment
would be failure-against-Dockerfile inlining, and even that ranks below everything above. Skip until
the day-changing list is done; revisit when a real user asks.

## 9. Stats / activity — verdict: small **build**, low rank

OrbStack's Activity Monitor graphs CPU/memory/network/disk per container (VERIFIED, v2.1.1) plus an
`orb top` TUI. Our Statistics tab (`ContainerStatsTab.swift`) has real Swift Charts for CPU/memory,
verified accurate against `docker stats` (UI-AUDIT "genuinely good" §2). Delta: network and disk I/O
series — the fields are already in the stats payload. → **UX-9**. An `orb top` clone is cruft for us;
the menu-bar extra already shows per-container CPU.

**Update (UX-9, 2026-08-05).** Network was already decoded and charted; the missing field was
`blkio_stats`, which nothing in the app read. What we established about it on our own guest, since
the honest outcome depends on whether the kernel accounts block I/O at all:

- The pinned guest kernel — kata-containers 3.28.0, Linux 6.18.15, the `vmlinux` at
  `$MORBSTACK_HOME/data/kernel/` — carries `CONFIG_BLK_CGROUP=y`, `CONFIG_BLK_CGROUP_RWSTAT=y`,
  `CONFIG_BLK_DEV_THROTTLING=y` and `CONFIG_CGROUP_WRITEBACK=y`. Read directly out of the image's
  embedded `IKCFG` blob, not inferred. So `io.stat` exists, and buffered writes are charged back to
  the originating cgroup rather than to a flusher thread.
- The pinned guest `dockerd` (29.7.1, `dist/guest-bin/dockerd`) exports
  `github.com/moby/moby/v2/daemon.(*Daemon).statsV2` alongside `statsV1`, and the cgroup v2 metrics
  type it consumes (`containerd/cgroups/v3/cgroup2/stats.IOEntry`, with `Rbytes`/`Wbytes`) has no
  equivalent of v1's other blkio arrays. On our guests, therefore, **only**
  `io_service_bytes_recursive` is ever populated; `io_serviced_recursive` and the rest are
  structurally empty and are deliberately not modelled.
- **The caveat that shapes the UI:** cgroup v2's `io.stat` lists a device only once that cgroup has
  moved bytes over it, so an idle container legitimately yields an empty array — indistinguishable
  from an engine that does not account block I/O at all. The Disk tab therefore states the Engine's
  listing rule ("lists a block device only after a container reads from or writes to it, and it
  listed none for this container") rather than claiming a cause it cannot know, and never renders
  the empty case as a flat zero line.
- **Not verified:** no live container was run for this ticket (machine lane held elsewhere), so the
  claim that our guests do in practice emit non-empty `io_service_bytes_recursive` under real I/O
  is a kernel-config and binary-symbol inference, not an observation. Confirming it is one
  `docker run --rm alpine dd if=/dev/zero of=/x bs=1M count=64` away for whoever next holds the lane.

## 10. Menu-bar extra — verdict: **build** (stay lean)

OrbStack's does container/project lifecycle, logs, terminal, open-in-browser, ports, mounts, machine
controls, copy IDs/domains (VERIFIED — "substantially richer than ours"). Ours
(`MenuBar/MorbMenuBar.swift`) shows engine state/actions, running containers with CPU and a stop
action, published ports, and app shortcuts. Delta: per-container "View Logs" (the bridge exists —
`TrackDAppBridge.reveal(showingLogs:)`), Compose-project grouping with project lifecycle, copy
name/ID, and — once DIF-2 lands — open terminal. Keep it a menu, not a dashboard. → **UX-10**

## 11. Domains, machines, Kubernetes

- **Domains.** OrbStack's "domains UI" is barely a UI: `http://orb.local` renders an index page
  linking every running container; no dedicated tab (VERIFIED). That is the right amount of UI and
  we should copy the *restraint*: when DIF-4 lands, an inspector affordance + a served index page,
  not a new route. Recorded as design guidance on DIF-4; no separate UX ticket.
- **Linux machines.** OrbStack's machines UI (distro picker, per-machine limits, isolated machines
  for agent sandboxing) is real and their docs are honest that isolation is *"not a full security
  boundary"*. Whether Morbstack enters this space at all is DIF-13, explicitly a decision-first
  ticket. No UX ticket until that decision exists.
- **Kubernetes — defend.** OrbStack's k8s GUI is thin: no evidence of pods/services list or detail
  screens. Our route (`KubernetesRootView.swift`) has pods/nodes/events tables with sort, detail,
  and port-forward. **We lead here.** Do not let a parity sweep "simplify" it away.

## 12. The cruft — verdict: **skip**, and mean it

Gordon (AI agent), Docker Model Runner, Docker Offload, the extensions marketplace, Settings
Management, Registry/Image Access Management, Domain Audit, SSO/SCIM, org/team admin views, Build
Cloud, scheduled backups (all VERIFIED as shipped surface). Every one is a screen a developer
scrolls past; most exist to serve enterprise procurement or to upsell cloud services — the two
motives Morbstack structurally does not have. TASKS.md already records the compliance-suite refusal;
this file extends it to the AI/cloud/extensions surface. **Not building these is the product
decision**, and it is what "without the cruft" costs: nothing now, everything if we drift.

An extensions/plugin system specifically: a one-maintainer project cannot review third-party
panels, an ecosystem of two extensions is worse than none, and MCP (`MorbMCP` exists) is the
extension surface this decade actually rewards. Skip.

## 13. Empty states, errors, onboarding — verdict: **defend**

Neither vendor documents its empty states; both were researched from docs/trackers, not running
apps. Ours are a strength on the record: real `ContentUnavailableView`s everywhere, honest copy
("This container is not running. Its resource history is available only while it runs."),
`ContentUnavailableView.search` on every searchable route (UI-028), engine state honestly surfaced
in the sidebar footer and menu-bar extra. The standing rule ("all functional, no coming soon")
already outlaws the lazy version. Onboarding: Docker ships walkthroughs; our first-run is
`FirstRunCLISetup` + the consented zero-config install (`docs/design/ZERO-CONFIG-DISCOVERY.md`) —
right-sized; no ticket.

---

## Ranked: what changes a user's day

1. **Context-preserving log search (UX-1).** Everyone who reads logs hits it daily; we currently
   ship a competitor's documented, complained-about, since-fixed bug; and it is the cheapest item on
   this page. (Coordinator ranked files-browsing first; I moved this above it on frequency × cost —
   files browsing is used often, but log search is used *constantly* and this is a defect-class fix,
   not a feature.)
2. **Container Files tab, read-first (UX-4).** Both competitors have it; we have nothing; it
   replaces `docker cp` guesswork with a screen.
3. **Compose-aggregated, per-service-coloured logs (UX-2).** The single most-praised OrbStack log
   feature; our pipeline already does the hard half.
4. **Compose grouping in the container list (UX-6).** Docker's best list idea; makes Stacks and
   Containers tell one story.
5. **Menu-bar extra depth (UX-10)** — with DIF-2's terminal wired in when it lands.

**Deliberately not building:** everything in §12, Docker's Build-view telemetry theatre (§8, for
now), an `orb top` TUI, a domains route (an index page is enough), and any GUI that holds a
credential.
