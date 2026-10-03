# Product / competitive audit — 2026-08-03

> **Staleness note (2026-08-04):** the `-P`/publish-all findings below
> (`guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch`,
> `scripts/build-morbstack-dockerd.sh`, `dist/guest-bin/morbstack-dockerd`) describe a
> mechanism deleted under TECH-1. Morbstack now ships unmodified upstream `dockerd`;
> `-P` is served through its stock `--userland-proxy-path` hook instead. Findings left
> unchanged as dated evidence; see `docs/design/PATCH-FREE-PUBLISH-ALL.md`.

**Scope:** the high-value local-development ergonomics people pay OrbStack or
Docker Desktop for, what subsystem in this repo would have to exist to deliver
each, and where Morbstack actually stands — measured against source, not
against this repository's own documentation.

**Posture.** Everything below was checked against code on
`code/native-content-continuation` at `54de308`. A doc saying a feature exists
is not evidence. Where the docs and the source agree, this audit says so and
moves on; where they disagree, or where the source disagrees with itself, the
source wins. No build, test, daemon, container, VM or app launch was performed.

**Verdict vocabulary**

| Verdict | Meaning |
| --- | --- |
| REAL | The code does the work end to end, and nothing structural blocks it. |
| PARTIAL | A real mechanism exists but covers a narrow slice of the advertised behaviour. |
| STUB | Source exists and refuses at runtime — a plan, a validator, or a hardcoded "unavailable". |
| ABSENT | No implementation. Design documents do not count. |
| UNVERIFIABLE-WITHOUT-GUEST-REBUILD | Host and guest source exist, but the shipped guest image predates the guest code, so nobody has ever executed it. |

---

## 0. Two structural facts that colour every verdict below

### 0.1 The shipped guest image predates three headline features

| Artifact | Built |
| --- | --- |
| `~/.morbstack/data/kernel/initrd.img` (the guest) | 2026-08-02 19:46 |
| `guest/morbinit/target/aarch64-unknown-linux-musl/release/morbinit` | 2026-08-02 19:56 |
| `3115ff0` live-share notification transport (guest receiver) | 2026-08-03 12:55 |
| `103ab2d` publish-all guest allocator repair | 2026-08-03 12:55 |
| `53f6d4a` grow-only disk transaction (guest resize proof) | 2026-08-03 14:36 |

The cross-compiled `morbinit` is *newer than the initramfs that is supposed to
contain it*, and all three of the day's guest-side features are newer than
both. `dist/Morbstack.app/Contents/Resources/runtime/0.1.0-m0/kernel/initrd.img`
is a copy of that same 2026-08-02 image.

Consequence: **`-P`, the live-share/inotify bridge, and disk growth have never
been executed by anything.** They are not "implemented and awaiting
verification" in the ordinary sense — the bytes that would run them do not
exist on this machine. `docs/claude-audit-handoff-2026-08-03.md:97` and `:166`
say this for `-P` and live-share; nothing says it for disk growth, which
`53f6d4a` describes as "verified".

### 0.2 Morbstack no longer runs an unmodified upstream Docker Engine

This is the project's loudest differentiator. `README.md:33` — "**Unmodified
upstream `dockerd`.** Morbstack doesn't fork or patch Docker Engine".
`site/index.html:109` makes it one of the six "checkable" claims.
`docs/comparison.md:77-79` builds the entire architectural argument on it:
Morbstack is "the only one of the six with **zero modification to the actual
container engine**".

That is no longer true:

- `guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch` adds
  `daemon/morbstack_publish_all.go` (166 lines) and modifies `daemon/network.go`.
- `scripts/build-morbstack-dockerd.sh` checks out Moby `docker-v29.7.1`, applies
  that patch, and installs the result as `dist/guest-bin/morbstack-dockerd`.
- `scripts/mkinitramfs.sh:82-87` **hard-fails** if that patched binary is absent.
- `scripts/mkinitramfs.sh:215-219` explicitly skips the upstream `dockerd` and
  installs the patched one *under the name `dockerd`*.
- `mise.toml` `[tasks.guest-image]` now `depends = ["cross-build-guest",
  "build-patched-dockerd"]`.

As of `103ab2d` it is **structurally impossible to build a Morbstack guest image
containing an unmodified engine.** The patch is small, well-scoped and honestly
described in its own commit message ("intentionally a small, version-pinned
downstream patch"), but the marketing has not caught up, and a downstream Moby
fork carries a real maintenance cost the docs do not price in.

The claim appears unqualified in at least twelve places — `README.md:9,33,300`,
`docs/architecture.md:139,144`, `docs/comparison.md:65,182,203,501`,
`docs/parity.md:71`, `docs/product-audit.md:12,28`, `docs/roadmap.md:36,219`,
and four spots in `site/`. Exactly one document is honest about it:
`docs/dynamic-port-allocation.md:80-87` explains that `-P` now depends on the
patch and that guest-image inclusion is pending. Nothing else cross-references
it. Today the claim survives only on the technicality that
`dist/guest-bin/morbstack-dockerd` was never built — the moment `-P` ships, it
is simply false.

Secondary consequence: `scripts/build-morbstack-dockerd.sh:44-47` requires
`docker buildx` with a working BuildKit builder. **You now need a working Docker
to build Morbstack.** For a project whose thesis is "you shouldn't need Docker
Desktop", that is a bootstrap problem worth naming.

---

## 1. What the competition actually charges for

The framing question was "features OrbStack / Docker Desktop hide behind a
paywall". That premise needs one correction before the rest is useful.

### OrbStack — the paywall is a licence, not a feature gate

OrbStack Pro is **$8/user/month ($96/yr)**; Enterprise is quote-only with a
15-seat SAML minimum. The free tier is *personal, non-commercial only* — you owe
a licence if you are a freelancer, employed by any commercial/non-profit/
government entity, or generate more than **$10,000/yr** in work connected to
OrbStack use. 30-day commercial evaluation. 5 devices per user.
(`docs.orbstack.dev/licensing`, `orbstack.dev/pricing`)

**The only capability behind the paywall is the Debug Shell.** Everything people
actually rave about — `.orb.local` domains, automatic HTTPS with a local CA,
routable container IPs, native file access, Rosetta, Kubernetes, Linux machines,
sub-second start, sub-0.1% idle CPU — is in the *free* tier
(`docs.orbstack.dev/docker/domains`, `.../features/https`).

So the strategic answer to "what does OrbStack hide behind a paywall that
Morbstack could give away" is: **almost nothing.** What OrbStack sells is the
right to use those features at work. Morbstack's differentiation is therefore
not "free versions of paid features" — it is **the same features, inspectable,
with no commercial-use asterisk**. That is a real and defensible position, but
it means Morbstack has to actually *build* the free-tier feature set, not just
undercut a price.

### Docker Desktop — the paywall is a real feature gate

Personal $0 · Pro $9/mo annual ($11 monthly) · Team $15 ($16) · Business $24.
Free commercial use only under **250 employees AND under $10M revenue**;
government entities excluded outright; effective 2024-12-10, unchanged.
(`docker.com/pricing`, `docker.com/pricing/faq`)

Genuinely gated capabilities:

| Capability | Gate |
| --- | --- |
| Docker Scout (continuous vuln analysis) | 1 repo Personal · 2 Pro · unlimited Team/Business |
| Docker Build Cloud | 200 / 500 / 1500 min/mo by tier |
| Docker Offload (cloud engine + NVIDIA L4, GA 2026-04-02) | paid |
| Enhanced Container Isolation (Sysbox) | Business |
| Hardened Docker Desktop | Business |
| Registry Access Management / Image Access Management | Business |
| Settings Management | Business |
| Air-gapped containers (4.31+) | Business |
| SSO / SCIM | Business |
| Docker Hardened Images | separate, from ~$5k/repo |

Not gated: Kubernetes, Compose, Build, the CLI, and — as of 2025 — pull limits
were *relaxed* rather than tightened, with unlimited pulls for all paid tiers.

**Reading for Morbstack:** of that list, only *Scout* is a local-development
ergonomic. The rest is enterprise fleet policy — the wrong market for a
one-maintainer Apache-2.0 project. The features that make people *pay* Docker
are compliance features; the features that make people *leave* Docker for
OrbStack are ergonomics. Aim at the second list.

### The free field

Colima, Rancher Desktop, Podman Desktop and Lima are all free with no
commercial trigger. None of them ships automatic per-container domains with
working HTTPS. None ships Mutagen-grade bidirectional sync (Docker bought
Mutagen and folded it into Docker Desktop). Colima has no GUI at all, and its
mount driver / arch / runtime are immutable after VM creation. Most of them sit
on the same Lima + vz + virtiofs stack, whose `vz`/virtiofs/Rosetta path is
still labelled experimental in Lima's own docs as of 2026.

---

## 2. Capability ledger

| # | Capability | What the competition gives (price) | Morbstack verdict |
| --- | --- | --- | --- |
| 1 | Stock `docker` CLI finds the engine out of the box | Docker Desktop, OrbStack: free | REAL in source, never run on a clean account — see §2.1 |
| 2 | Fixed `-p` published ports | free everywhere | REAL (loopback TCP/IPv4-UDP) |
| 3 | `-P` / `PublishAllPorts` | free everywhere | UNVERIFIABLE-WITHOUT-GUEST-REBUILD |
| 4 | Fast native-speed file sharing | free everywhere | REAL (VirtioFS, unbenchmarked) |
| 5 | Working inotify / hot reload inside containers | Docker Desktop (free), OrbStack (free) | UNVERIFIABLE-WITHOUT-GUEST-REBUILD, and mechanism is `IN_ATTRIB`-only |
| 6 | Automatic `*.local` container domains | OrbStack free tier | ABSENT |
| 7 | Automatic local HTTPS via a trusted CA | OrbStack free tier | ABSENT |
| 8 | Routable container IPs from the host | OrbStack free tier | ABSENT |
| 9 | Native macOS/Finder access to volume + image contents | OrbStack free tier | ABSENT (export only) |
| 10 | Rosetta amd64 | free everywhere | REAL |
| 11 | Kubernetes that starts fast | Docker Desktop free, OrbStack free, Rancher free | REAL for the cluster; STUB for pod port-forward |
| 12 | Migration from Docker Desktop | OrbStack free | REAL for images + named volumes |
| 13 | Per-container resource visibility | free everywhere | REAL |
| 14 | Debug/exec toolbox for distroless | **OrbStack Pro $8/mo**; Docker Desktop `docker debug` | ABSENT — and there is no plain `exec` terminal either |
| 15 | Image vulnerability scanning | **Docker Scout, gated by repo count** | ABSENT in practice — see §2.14 |
| 16 | Build caching + Buildx ergonomics | free everywhere | REAL (read path), unproven live |
| 17 | Dev Containers / Testcontainers | free everywhere | ABSENT as tested capability |
| 18 | VS Code integration | free everywhere | REAL |
| 19 | JetBrains integration | free everywhere | ABSENT (a README) |
| 20 | Menu bar + CLI experience | free everywhere | REAL |
| 21 | Container logs | free everywhere | REAL |
| 22 | Disk that grows and reclaims honestly | free everywhere | UNVERIFIABLE (grow); ABSENT (reclaim) |
| 23 | Instant start / low idle CPU+RAM | OrbStack's headline; free tier | PARTIAL — fast cold boot, no suspend/resume, idle unmeasured |
| 24 | Linux machines | OrbStack free tier | ABSENT |

### 2.1 Stock CLI discovery — REAL in source, and the public docs say the opposite

The single most important question for a "drop-in replacement" is whether a
`docker` command works on a Mac that has never had Docker. This is the area
where the code is *further ahead* than the documentation, which is its own kind
of problem.

What actually exists:

- `docker`, `docker-compose` and `docker-buildx` are genuinely bundled with
  pinned SHA-256s. `dist/host-bin/docker` hashes to `49d98ab8…`, matching the
  pin at `CliPlugins.swift:93`; the same set is present in
  `dist/Morbstack.app/Contents/Resources/host-bin/`.
- `MorbCliInstallation.swift:31-35` symlinks `~/.morbstack/bin/docker`;
  `CliPlugins.swift:145-155` installs the two CLI plugins into Docker's standard
  `~/.docker/cli-plugins/` location.
- `MorbDockerContext.swift:576-620` creates a user-owned
  `~/.docker/run/docker.sock` and never overwrites another tool's socket.
- `MorbDockerContext.swift:267-284` registers and selects a `morbstack` context
  only when the existing one is unset or default — the documented "never stomp"
  rule, actually implemented.
- `MorbCliInstallation.swift:355-378` adds a reversible marked block to
  `~/.zprofile`/`~/.bash_profile`, and only when no other `docker` resolves first.
- It refuses to touch root-owned `/var/run/docker.sock`, printing the `sudo ln -sf`
  for the user instead (`MorbDockerContext.swift:790-796`).

On the code's own account (`FirstRunCLISetup.swift:760`), after the first-run
sheet a new Terminal has working `docker` / `docker compose` / `docker buildx`
with no further action. That is the correct design and it is not a stub.

Two problems remain. First, it has **never been executed on a clean account** —
`docs/drop-in-delivery-plan.md:29-32` states the release gate is not runnable:
"CP-06 and CP-07 are a release contract, not runnable fixtures today. This
checkout has no pinned Java, Go, Node, Python Testcontainers probe or Dev
Containers CLI/editor fixture." Second, the *public* comparison document still
says the feature does not exist: `docs/comparison.md:346-357` — "**Morbstack does
not install a Docker client. Every product in this document does.** This is the
single largest gap in the list… On a Mac that has never had Docker, nothing
works." That paragraph, and its mirror in `site/comparison.html`, is what an
outsider reads.

**Remaining:** run CP-01–CP-07; add the Testcontainers and Dev Containers
fixtures that block it; reconcile `comparison.md` / `site/comparison.html`.

### 2.2–2.3 Ports — REAL for the boring case, unrunnable for `-P`

`PortForwarder.swift` (2799 lines), `DockerPortPublicationPreflight.swift` (1223),
`DockerDynamicCreateTransaction.swift` and `HostPortPreflight.swift` implement a
genuinely careful host-owned lease: the Mac listener is bound *before* create and
handed off on the exact `204`, closing the race where a port appears published
but is not reachable. This is better engineering than the problem usually gets.

The covered set is narrow and the docs say so
(`docs/competitive-capability-roadmap.md:47`): fixed loopback TCP, IPv4 UDP,
CLI-normalised equal-length fixed ranges, and exactly three dynamic spellings
(omitted `HostPort`, `""`, `"0"`). Excluded: `-P`, raw dynamic host-port ranges,
paired dual-family IPv6, SCTP, non-loopback addresses, opaque/chunked framing,
starts by name or ID prefix.

One deliberate exception to "transparent relay" lives here and is worth naming:
for the bounded dynamic-create path, `DockerProxy.swift:541-590` consumes the
client's exact bytes and forwards a **rewritten** body and `Content-Length`.
It is narrowly scoped (256 KiB preflight window, `Expect: 100-continue` and
chunked bodies excluded) and openly designed, but it means the relay is
byte-transparent for everything *except* one recognised shape.

`-P` is the interesting one. `guest/moby-patches/0001-…` +
`PublishAllPortAllocator.swift` + `guest/morbinit/src/publish_all.rs` (broker on
`/run/morbstack/publish-all.sock`, spawned at `guest/morbinit/src/main.rs:406`)
are a real design — allocate at the point Moby has expanded `EXPOSE`,
all-or-nothing, `HostConfig` untouched so Moby's reallocation semantics survive.

It cannot work today, for two independent reasons:

1. `dist/guest-bin/dockerd` is vanilla. `dist/guest-bin/PROVENANCE.txt` records
   it as the unmodified `download.docker.com` static 29.7.1 extraction, dated
   2026-08-01. It has never heard of `/run/morbstack/publish-all.sock`.
   **`dist/guest-bin/morbstack-dockerd` does not exist anywhere in the repo** —
   `scripts/build-morbstack-dockerd.sh` has never been run to completion here.
2. Even with a patched engine, the guest broker postdates the running initramfs
   by ~19 hours.

`docs/final-implementation-audit-2026-08-03.md:34` still says `-P` was "audited
and intentionally rejected before guest side effects" — the opposite of what
`103ab2d` did nine hours later.

### 2.4–2.5 File sharing and hot reload

**Sharing: REAL.** VirtioFS, same-absolute-path mapping, defaults
`["/Users", "/Volumes", "/private/tmp"]` (`DirectoryShares.swift:68`), capped at
8 VirtioFS devices with a 2048-byte cmdline ceiling and an explicit refusal to
share `/`, `/usr`, `/etc`. `docs/parity.md` #8 verified fresh content on re-read
against a live VM. Known, documented limits: everything is `root:root` in the
guest and container-side `chown` is silently discarded (`docs/sharing.md`); a
bare `/tmp` source used to silently produce an empty directory (`parity.md` #9)
and now has a guest alias plus a Docker-shaped error.

There is **no way to add or remove a shared path except by editing
`~/.morbstack/config.toml` and restarting the engine.** The Settings pane says
so itself — `TrackDSharingSettings.swift:5-7`: "It is intentionally read-only:
the writer cannot safely round-trip the shared paths array yet… The config file
is therefore the deliberate editing surface." `morb shares` is status-only
(`main.swift:791`, `:821`). Every competitor lets you add a folder from a GUI.
No second "synced copy" filesystem tier exists — VirtioFS is the only option.

**Hot reload: UNVERIFIABLE-WITHOUT-GUEST-REBUILD, and narrower than it sounds.**
`parity.md` #10 confirmed with a live `nodemon` that *zero* inotify events cross
a VirtioFS mount. `3115ff0` is the fix attempt, and the mechanism deserves
scrutiny because it is clever and partial:

- Host: `MorbLiveShareTransport.swift:579-610` opens a scoped FSEvents stream.
- Wire: an authenticated line protocol on vsock 2381 with a per-connection
  HMAC capability (`guest/morbinit/src/live_share_receiver.rs:15-28`).
- Guest: `sys::nudge_metadata` (`guest/morbinit/src/sys.rs:221-232`) performs a
  **same-mode `fchmod(2)`** on the existing object.

That emits `IN_ATTRIB`, not `IN_MODIFY` or `IN_CLOSE_WRITE`
(`live_share_receiver.rs:4-10` is explicit and honest about this). Consequences:

- Node's libuv inotify backend and Python `watchdog` include `IN_ATTRIB`, so
  chokidar-based watchers (nodemon, vite, webpack) will probably see a change.
- Go's `fsnotify` maps `IN_ATTRIB` to a `Chmod` op, which many Go live-reload
  tools (e.g. `air`) filter out. Those will probably *not* reload.
- File *creation* is signalled by nudging the parent directory, which produces
  `IN_ATTRIB` on the directory rather than `IN_CREATE` for the child. Whether a
  watcher rescans is watcher-specific.
- The guest's `fchmod` writes back through VirtioFS and is itself visible to
  host FSEvents. `MorbLiveShareTransport.swift:64-66` suppresses the matching
  path for one coalescing window to break the loop — a real risk, handled, but
  only testable live.

And the whole thing is off by default: `MorbConfig.swift:73` documents
`liveSharePaths` as "intentionally empty by default" and `:109` defaults it to
`[]`. **Update, 2026-08-05 (UX-21): the "unreachable through any user
interface" half of this claim is stale.** Settings › Sharing has "Add Project
Folder…" behind an `NSOpenPanel` plus per-row Remove, validated through
`MorbLiveShareBridge.plan` before it writes
(`mac/Sources/MorbstackAppCore/Settings/TrackDSharingSettings.swift:95,179-198`).
There is still no `morb` subcommand — the TOML parser at `MorbConfig.swift:640`
and the Settings pane are the only two writers.

**Remaining:** rebuild the guest; run a real matrix of watchers (chokidar, Go
fsnotify, Java `WatchService`, Ruby `listen`) and publish which ones work;
consider a real write nudge or a guest-side inotify shim for the ones that
don't; expose the setting somewhere a human will find it.

### 2.6–2.8 Domains, HTTPS, routable IPs — ABSENT

This is OrbStack's single clearest UX win and no free tool matches it.
`docs/domains.md` is an excellent 324-line security-first design document that
states its own status in the first sentence: Morbstack "does not currently
resolve a local name, listen for local HTTP(S), modify macOS DNS, install a
Network Extension, issue a certificate, or trust a local CA."

Source confirms exactly that. `MorbLocalDomain.swift:6` — "A pure, inactive
registry for future `*.morb.local` HTTP routing." It is a hostname validator and
a duplicate-name check. `LocalDomainClaimReconciler` (`:224`) has **zero callers
anywhere in the repository**; the only cross-file reference to the whole module
is `PortForwarder.swift:448`, which produces a snapshot nobody consumes. There
is no `ServiceRouter`, no `ServiceRouteCoordinator`, no CA, no resolver.

Two smaller notes: `MorbLocalDomain.swift:17` still hardcodes `morb.local` even
though `docs/domains.md:37` decided `.test` is the recommended canonical suffix
because `.local` collides with mDNS — the source has not followed the decision.
And routable container IPs are not merely unimplemented but architecturally
foreclosed for now: `VMManager.swift:1882-1884` uses `VZNATNetworkDeviceAttachment`
with the comment "NAT is enough for M1; bridged/vmnet comes later".

### 2.9 Native file access — ABSENT

OrbStack mounts container, image and volume filesystems into Finder.
`VolumesRootView.swift:1-10` states the deliberate position: show the guest
mount point "without pretending it is a Finder-accessible location on this Mac."
The only `activateFileViewerSelecting` calls reveal an *exported archive*
(`VolumesRootView.swift:325-326`) or a bind-mount host path
(`ContainerMountRow.swift:30`) — the latter being trivially true, since a bind
mount already is a host path. There is a real `morb export` /
`MorbExport/ExportCLI.swift` archive path. That is a workaround, not the feature.

### 2.10 Rosetta — REAL

`Rosetta.swift` maps `VZLinuxRosettaDirectoryShare.Availability` and installs on
explicit consent (it refuses `--force`, `main.swift:1435-1667`);
`guest/morbinit/src/binfmt.rs` (853 lines) registers the interpreter.
`docs/amd64.md` has real measured slowdowns (SHA-256 ~5.1x, RSA-2048 sign ~3.8x,
general compute ~1.8–2x). The qemu fallback is written but inert — no static
`qemu-x86_64` ships, so anything Rosetta can't translate simply fails.

### 2.11 Kubernetes — REAL cluster, STUB pod port-forward

k3s `v1.36.2+k3s1` + `cri-dockerd` `v0.4.4` pointed at the *same* `dockerd`
(`guest/morbinit/src/k8s.rs:1-45`) — a genuinely good architectural choice,
because `docker build` output is visible to the cluster with no registry push.
Payload transfer over vsock 2377 with digest verification is implemented on both
sides. `KubernetesAPIClient.swift` does real mTLS to the local API server; the UI
is not a fixture. `docs/k8s.md` records 8.3s cold enable, ~4s warm.

Caveats: `dist/guest-k8s/` is gitignored, so a fresh clone must run
`scripts/fetch-guest-assets.sh --k8s-only`. And the selected-Pod port-forward
requires a hash-pinned `kubectl` at `Contents/Resources/host-bin/kubernetes/kubectl`
(`KubectlTool.swift:16-73`) **that does not exist anywhere in the repo** — the
CLI surface, IPC and coordinator are all built around a binary that was never
shipped. `docs/product-audit.md:58` says this plainly; `docs/comparison.md:206`
says only "Kubernetes: **working**".

### 2.12 Migration — REAL, with real limits

`ImageMigrationTransaction.swift:522-565` streams `GET /images/get` from the
source socket to a temp file and `POST /images/load` into Morbstack.
`VolumeMigrationTransaction.swift:575-619` uses the standard helper-container
`GET/PUT .../archive` technique. `MigrationRootView.swift` is wired to the real
transactions, not a mock. Peak temp disk is roughly the largest single item, so
a 100 GB Docker Desktop install is slow but architecturally fine.

Limits, honestly declared in `ImageMigrationTransaction.swift:258-263`: no bind
mounts, no containers, no stacks, no k8s workloads, no CLI contexts, no registry
credentials. Buildx cache and Compose projects are not mentioned anywhere — they
are simply not migrated. **Docker Desktop must be running**: `Runtimes.swift:103-122`
probes its socket with a real `_ping`; there is no cold read of its VM disk.
That is the right call for correctness and the wrong one for the user whose
Docker Desktop licence just expired.

### 2.13 Resource visibility — REAL

`ContainerStatsTab.swift` renders live CPU/memory series from real `/stats` with
Swift Charts and an `AXChartDescriptor` for accessibility.
`ContainerLogsTab.swift` + `LogPipeline.swift` + `AnsiSGR.swift` implement real
streaming logs with ANSI SGR handling. This is the part of the app that is
straightforwardly good.

### 2.14 Debug toolbox — ABSENT, and so is plain exec

This is the *only* feature OrbStack actually paywalls, so it is the most
strategically interesting gap in the list.

`MorbScan/DebugCLI.swift` returns exit status 2 unconditionally at `:47` and
`:63`. `morb debug check` reads a local JSON manifest describing a hypothetical
future toolbox image and never touches Docker. `morb debug plan <container>`
makes one `GET /containers/{id}/json` and reports what it did not do. There is
no `exec`, no `nsenter`, no ephemeral container, no PTY anywhere in the repo.
`docs/debug.md:131-157` lists a five-item execution gate, none of which exists.
The CLI help is honest — `main.swift:48` says "does not open a shell yet".

Worse for daily use: **the native app has no container terminal at all.** There
is no `exec` call in `DockerClient.swift` and no PTY view under
`MorbstackAppCore/`. Docker Desktop and OrbStack both put a shell one click from
a running container. `morb debug` is a differentiator; an exec terminal is table
stakes, and it is missing.

### 2.15 Vulnerability scanning — ABSENT in practice

`morb scan`'s help says "SBOM and CVE scan an image, entirely on this machine"
(`main.swift:46`). The implementation (`MorbScan/ScanEngine.swift:194-206`,
`:275-285`) shells out to **syft** and **grype**. That is the right choice — do
not homegrow CVE matching. But:

- Neither binary is bundled. `find` for `*syft*`/`*grype*` across the repo
  returns nothing.
- `ToolLocator.swift:90` tells the user to run `scripts/fetch-scan-tools.sh`.
  **That script does not exist.** It is referenced five times
  (`ToolLocator.swift:5,52,87,90`, `ScanCLI.swift:403`) and `ls scripts/`
  confirms it is absent.
- grype fetches its vulnerability database from `grype.anchore.io`
  (`ScanEngine.swift:251-257`), so "entirely on this machine" is true only after
  a network download, or with `--offline` against a pre-existing cache.

So `morb scan` cannot work for any user who has not independently installed
Anchore's tools, and the remedy the error message offers 404s.

### 2.16 Builds — REAL read path

`BuildsRootView.swift` (1347 lines), `BuildRunner.swift`, `BuildxHistoryClient.swift`
run real bundled Buildx and read real `buildx history`, explicitly not inferring
history from BuildKit cache. `0d132e6` keeps the cache total to Docker-attributed
non-shared bytes so it does not double-count with images. Never exercised against
a clean engine.

### 2.17 Dev Containers / Testcontainers — ABSENT as a tested capability

Both are named as release gates in `docs/clean-profile-acceptance.md` (CP-06,
CP-07) and both are declared unrunnable in `docs/drop-in-delivery-plan.md:29-32`
for lack of fixtures. There is no devcontainer support, no Testcontainers probe,
and no lockfile. Testcontainers in particular is the thing that silently decides
whether a team can switch: it probes conventional socket paths and gives up.

### 2.18–2.19 Editor integrations

`integrations/vscode/src/extension.ts` is a **real** extension — tree providers,
start/stop/restart/remove/exec/logs against the live Engine API, status bar,
confirmed prune. `integrations/jetbrains/` contains **only a README.md**. It
documents (candidly) that JetBrains' generic Docker support works if you paste
the socket path in by hand. Zero code.

### 2.20 Menu bar and CLI — REAL

`MenuBarExtra` with a real settings-bound toggle (`App.swift:119`). The `morb`
CLI is 25 commands, and per an independent pass over every dispatch arm, the
overwhelming majority do the work their help text claims: `status/start/stop/
suspend/resume`, `shares`, `rosetta`, `k8s`, `doctor`, `diagnose`, `disk`,
`ports`, `context`, `service`, `install-cli`, `reset-disk`, `mcp`, `export`, and
6 of 8 `bench` targets are all real. No TODO/FIXME markers and no error-swallowing
catch blocks were found in the CLI surface.

Two defects: shell completions in `integrations/shell/` are hand-written and now
stale — 7 top-level commands missing (`diagnose`, `disk`, `ports`, `export`,
`service`, `install-cli`, `uninstall-cli`), and `_morb:42` describes `debug` as
"Open a toolbox shell in a container, even a distroless one", which is the
opposite of what the command does. `morb bench` publishes 8 roadmap targets but
implements 6; the two bind-mount filesystem benchmarks — the ones that would
answer the most commercially important performance question — report
`status: "not implemented"` (`MorbBench/Support/Targets.swift:67-71`) rather than fabricating a
number, which is the right behaviour and still a gap.

### 2.22 Disk — grow UNVERIFIABLE, reclaim ABSENT

`MorbDiskGrowth.swift` + `MorbDiskResize.swift` implement a journaled grow-only
transaction with a stopped-VM ownership guard and a guest resize proof. Per §0.1
it has never run. `docs/competitive-capability-roadmap.md:48` still says "the
current guest reports `unavailable`" and "No host image mutation occurs" — one
of several places where the 2026-08-03 morning docs contradict the 2026-08-03
afternoon commits.

Reclaim does not exist. `MorbDiskResize.swift:126` — "Morbstack never shrinks an
existing VM disk." The guest mounts with `discard=async`
(`guest/morbinit/src/disk.rs:269-273`), which lets the sparse host image release
blocks passively, but there is no `docker system prune` → host-disk-shrink story
and no UI for it. On this machine the disk is a 64 GiB sparse file using 3.4 GiB.
Docker Desktop's disk that never shrinks is one of the top user complaints about
it; matching that behaviour is not a win.

### 2.23 Start time and idle footprint — PARTIAL

Measured (`docs/architecture.md`, via `docs/comparison.md:262-273`): cold
socket-activated `docker run --rm hello-world` 2.09s; repeat cold boot to
responsive `docker ps` 1.69–1.73s. Those are genuinely competitive.

But `morb suspend` is a graceful stop plus cold boot —
`Virtualization.framework`'s `restoreMachineStateFrom` does not work for a
direct-kernel-boot guest on macOS 26.4, recorded on disk as
`~/.morbstack/data/save-restore-unsupported`. The roadmap's "resume ≤500ms"
target has nothing behind it. Idle CPU, idle wakeups and host RSS have benchmark
implementations (`IdleMetrics.swift`) but no published measurement anywhere in
the docs — so OrbStack's headline claim ("less than 0.1% background CPU") is
currently unanswered.

---

## 3. Claims that overstate reality

Ranked by how badly an outsider would be misled.

**1. "Unmodified upstream `dockerd`." (`README.md:33`, `site/index.html:109`,
`site/index.html:16`, `docs/comparison.md:65,77-79`, `site/comparison.html:112`)**
False as of `103ab2d`/`mkinitramfs.sh:82-87`. The guest image cannot be built
without a patched Moby. This is the project's *headline architectural
differentiator*, stated on the marketing site as one of six "checkable" claims,
and it is the one claim that is now checkably wrong.

**2. `53f6d4a` "Add **verified** grow-only Docker disk transaction."**
Nothing was verified. The commit landed 2026-08-03 14:36; the guest image that
would contain the resize proof was built 2026-08-02 19:46. The same word appears
in `docs/claude-audit-handoff-2026-08-03.md:171` ("guest `/dev/vda` … resize
proof") immediately before the sentence admitting it must still be guest-image
rebuilt. Commit subjects are read by more people than caveat paragraphs.

**3. `docs/comparison.md:206` — "Kubernetes: **working** — `morb k8s`,
single-node k3s+cri-dockerd on the same engine, measured 8.3s cold enable."**
The cluster is real. But the same repo's `docs/product-audit.md:58` says the
Kubernetes port-forward is "Unavailable and not a product capability: the
verified helper is absent from the current bundle" — and `KubectlTool.swift:16-73`
confirms the pinned `kubectl` is not in the repo. `comparison.html` is the
document a prospective user reads; `product-audit.md` is not.

**4. `morb scan` — "SBOM and CVE scan an image, entirely on this machine"
(`main.swift:46`).** Requires two unbundled third-party binaries, points at a
setup script that does not exist (`ToolLocator.swift:90` vs `ls scripts/`), and
downloads a vulnerability database over the network unless `--offline`. Three
separate ways the one-line description is wrong.

**5. The word "implemented" throughout `docs/product-audit.md` and
`docs/competitive-capability-roadmap.md`.** The repo has carefully defined
"implemented in source" vs "live accepted"
(`docs/claude-audit-handoff-2026-08-03.md:14-19`) and then uses "Implemented"
as the *status column value* in tables a skimmer will read as shipped. For
several rows the honest status is stronger than "not verified": the code has
never been compiled and executed together in any form. There is a real category
difference between "compiled, ran, not yet accepted on a clean profile" and
"the binary that would run this does not exist", and the docs use one word for
both.

**Runners-up**

- `docs/final-implementation-audit-2026-08-03.md:34` says `-P` was "audited and
  intentionally rejected before guest side effects." Nine hours later `103ab2d`
  shipped a guest allocator for it. Two documents dated the same day give
  opposite answers, and neither links to the other.
- `docs/competitive-capability-roadmap.md:48` says "the current guest reports
  `unavailable`" for disk resize, contradicted by `53f6d4a` the same day.
- `docs/comparison.md:346-357` tells the world Morbstack does not install a
  Docker client, which stopped being true before that document was published.
- `docs/sharing.md:6` — "Status: **tier 1 (live VirtioFS)**, working." True for
  reads and writes; a reader will take it to include change notification, which
  is the thing that does not work.
- `integrations/shell/_morb:42` claims `morb debug` opens a shell.
- `README.md:34` — "no telemetry, verified by grepping `mac/Sources`". A grep
  for SDK names is not a verification that nothing egresses; `grype`'s database
  fetch and `RegistryImageDiscovery`'s Hub query are both real network calls
  from a "no telemetry" product. They are user-initiated and disclosed, so the
  claim survives — but "verified by grepping" is not how you'd want that
  sentence to age.

The pattern is not dishonesty. Each individual document is unusually careful,
and several (`domains.md`, `machines.md`, `debug.md`, `drop-in-delivery-plan.md`)
are models of self-reporting. The failure is **temporal**: six status documents
are maintained in parallel, they are reconciled by hand, and on a fast day the
commits outrun them in both directions. `docs/competitive-capability-roadmap.md:70-78`
names this exact risk ("Documentation reconciliation is a release prerequisite")
and it happened anyway, twice, on the day it was written.

---

## 4. What this actually is

Morbstack is a real container runtime with a real native app. `docs/parity.md`'s
live audit passed 19 of 29 checks against a cold-booted VM including two
non-trivial Compose stacks (WordPress+MySQL rendering an install wizard,
Flask+Redis+Postgres round-tripping through both). 75,000 lines of Swift, 13,800
of Rust, 739 test functions, and a CLI whose commands overwhelmingly do what they
say. That is not a demo.

It is also not a Docker Desktop replacement yet, for three reasons that have
nothing to do with feature count:

1. **Nobody has ever installed it.** No DMG, no notarised build, no Homebrew
   cask, no clean-account run of CP-01–CP-07. Every demonstration to date has
   run on a machine that already had Docker Desktop's client.
2. **The differentiators are all still design documents.** Domains, HTTPS,
   native files, machines, debug shell — five OrbStack features, five
   well-written specs, zero routers/CAs/mounts/VMs/PTYs in the source tree.
3. **The daily-loop fix is untested.** Hot reload is the single most common
   reason a developer abandons a container setup, and the fix for it is a
   `fchmod`-based `IN_ATTRIB` nudge that has never executed and will not satisfy
   every watcher even when it does.
