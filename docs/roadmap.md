# Roadmap

Status: living document, updated per milestone. Timeframes are targets,
not commitments; scope within a milestone is more load-bearing than the
calendar date.

## Two tracks

This document tracks two things that move at different speeds and gate
each other in only one direction.

**The engine track (M0 … 1.0)** is the product: the VM, the relay, the
filesystem, the networking, the app. It is sequenced by what has to be
true before the next thing can work.

**The launch track (L0 … L3)** is everything between "the code works" and
"a stranger can download, trust and use it": packaging and distribution,
the website, brand assets, repository publication, the competitive
analysis, and editor integrations. It is sequenced by what has to be true
before the next person can *find* the thing.

The dependency runs one way. The launch track can run ahead of the engine
track right up to the point where it would require making a claim that
isn't true yet — and then it must stop and wait, because the entire pitch
of this project is that its documentation is accurate. Specifically:
**L1 (the first public binary release) is gated on the M1 items that
`docs/parity.md` shows are load-bearing for a first-day user**, not on M1
in its entirety. Shipping a DMG before `buildx` and zero-config socket
discovery exist means shipping something that fails a new user's first
`docker build` and their first Testcontainers run.

The launch track is written out in full after the 1.x section.

## M0 — Proof (~6 weeks) — done

Goal: prove the core bet (unmodified Docker Engine, one shared VM, fast
boot) actually works before investing in the surrounding product.

- `Virtualization.framework` VM boots the pinned kernel and `morbinit`. **Done.**
- `dockerd` inside the guest is reachable from the host via a
  socket-activated proxy (`morbstackd` relaying `~/.morbstack/run/docker.sock`
  to the guest over vsock port 2375). **Done.**
- `docker run hello-world` completes in under 3 seconds, cold (no
  pre-warmed VM state). **Done** — 2.09s observed cold, socket-activated.
- Published container ports reachable from the Mac (`docker run -d -p
  8080:80 nginx` + `curl 127.0.0.1:8080`), via a vsock stream-dial
  forwarder (port 2376). **Done** — not in the original M0 scope as
  written above, added once it became clear day-one usefulness needed it
  before VirtioFS; see `docs/protocol.md` §3.2.
- Container outbound networking (NAT), not just `dockerd` itself reaching
  the registry. **Done.**
- Disk persistence: images and containers survive a `morb stop`/`morb
  start` cycle (`/dev/vda` formatted on first boot, mounted as
  `/var/lib/docker`, overlay2). **Done** — also not in the original scope
  as written above; promoted out of M2 once the core boot gate proved
  solid, since "day-to-day use" is meaningless without it.
- `docker compose up -d` against a multi-service project, via the
  standard `docker compose` CLI plugin. **Done** — see README "Running"
  for the one-time plugin install step; the plugin is fetched and
  verified by this repo but not auto-installed into `~/.docker/`.
- A VirtioFS bind mount works end to end (host directory visible and
  writable inside a running container). **Done**, after initially slipping.
  It was out of scope for the M0 gates as first run — persistence and
  published ports turned out to matter more for "does this work at all"
  than a bind mount did — and was pulled back in once those landed. Tier-1
  sharing is live VirtioFS with same-path mapping: a host directory appears
  in the guest at its identical absolute path, so `-v` needs no
  translation. Roots are configured with `shared_paths` and inspected with
  `morb shares`. See `docs/sharing.md`; tier 2 (synced shares) and the
  FSEvents→inotify bridge remain M1+.
- amd64 container images run via Rosetta binfmt. **Done** — also not in
  the original M0 scope. Verified with an image that publishes no arm64
  manifest at all (`mysql:5.7`), computing a hash bit-identical to the
  host's. The qemu fallback for what Rosetta cannot translate is written
  but inert until a static `qemu-x86_64` ships in the guest image, so it
  stays an M1 item. See `docs/amd64.md`.

Deliverables at this stage are the protocol contract and design docs
(this document, `docs/protocol.md`, `docs/architecture.md`,
`docs/compat.md`, `proto/morbstack/v1/control.proto`), plus the
`morbstackd`/`morb`/`morbinit` implementations needed to hit the gates
above — no longer just skeletons.

## M1 — Alpha (~4 months)

Goal: a daily-driveable replacement for Docker Desktop's core workflow.

- Menu bar presence and core SwiftUI UI (container/image list, VM status,
  basic settings) — Morbstack.app exists as more than a design doc.
- `morbnet` (gvisor-tap-vsock fork) networking online, `morbdns` resolving
  container/service names.
- qemu fallback for amd64 images wired up for what Rosetta can't handle.
  Rosetta binfmt itself landed in M0; the fallback needs a static
  `qemu-x86_64` in the guest image before the plumbing that already exists
  does anything.
- `compose` (v2) and `buildx` bundled and working against the relayed
  Engine API. Compose already works as of M0 (`docker compose up -d`
  passes, see `docs/compat.md`), but only via a manual one-time symlink
  of the fetched plugin binary into `~/.docker/cli-plugins/`; "bundled"
  here means the install step itself goes away — a first-run flow that
  wires the plugin in automatically, and `buildx` bundled the same way,
  neither of which exists yet.
- VM suspend/resume implemented (not yet necessarily hitting the 500ms
  perf target — that's tracked as a perf target, see below — but
  functionally correct).
- Memory balloon elasticity: guest memory footprint grows and shrinks with
  actual container workload rather than being fixed at VM boot.
- A documented, tested migration path off Docker Desktop (import existing
  contexts/config without clobbering anything Docker Desktop itself still
  owns).

## M2 — Beta (~8 months)

Goal: feature-complete enough for the compat matrix to matter, and for
Morbstack to make specific, checkable performance claims publicly.

- `*.morb.local` domains resolvable, HTTPS via the name-constrained local
  CA, host-routable container IPs.
- Synced shares (filesystem tier 2) available as an alternative to
  VirtioFS bind mounts.
- FSEvents -> inotify bridge reaches GA (out of tier-1 filesystem beta).
- ~~`k3s` + `cri-dockerd` supported, for users who want a local Kubernetes
  story on top of the same Docker Engine.~~ **Done** — pulled forward
  from M2, off by default and zero-cost until `morb k8s enable`. `k3s`
  is wired to the same `dockerd` every other Morbstack workload uses via
  `cri-dockerd`, so a `docker build` is immediately deployable with
  `imagePullPolicy: IfNotPresent` and no registry push — verified live,
  along with a cold enable-to-Ready time, a `LoadBalancer` Service
  reachable from the Mac, a clean disable, and the idle CPU/memory cost
  of leaving it on. See [`k8s.md`](k8s.md) for the numbers and
  [`protocol.md`](protocol.md) §3.3 for the payload-install wire
  protocol (vsock port 2377).
- `syft`/`grype` integration for image scanning.
- `morb debug` — a bundle-the-diagnostics command for bug reports.
- MCP server ships (host integration domain).
- Public compat-matrix CI stood up and green, plus `morb bench` as a
  user-runnable perf-target checker (see table below).

## 1.0 (~12-15 months)

Goal: ship it.

- Every perf target in the table below is either green or *publicly*
  reported red with a tracked reason — no silent misses.
- Documentation complete for install, migration, and troubleshooting.
- Independent security audit completed and findings addressed.
- App Intents (Shortcuts/Spotlight/Siri) shipped.

## 1.x — post-1.0

No fixed order; roughly in decreasing likelihood of near-term pickup.

- **Linux Machines** — general-purpose Linux VMs alongside the
  container-focused one, for users who want a scratch Linux box, not just
  container hosting.
- **FSKit Finder integration** — surface guest/container filesystem state
  natively in Finder via FSKit, rather than only through bind mounts.
- **morbfs** — filesystem tier 3, a purpose-built protocol for the
  bind-mount path.
- **morbnet v2** — rewritten in Rust on `smoltcp`, replacing the
  gvisor-tap-vsock-derived userspace stack from M1.
- **Plugin SDK** — a native (non-web-view) extension mechanism, the
  spiritual replacement for Docker Desktop Extensions (see
  `docs/compat.md` non-goals).
- **FEX-Emu productionized** — promoted from contingency to a supported
  path if/when it's actually needed (see `docs/architecture.md`,
  amd64 domain).

---

# The launch track

Everything between "the code works" and "a stranger can download, trust
and use it". Sequenced the same way the engine track is: by dependency,
not by calendar.

A note on the statuses below, because it matters here more than anywhere
else in this document. Most of the L0 work is *preparation a human then
has to execute* — a cask formula that cannot be submitted until a release
exists, a release script that refuses to run without a Developer ID, a
publishing runbook for an org that does not exist yet. Those are marked
**Prepared** rather than **Done**, and the thing the human must supply is
named. Nothing here is marked done because a file was written.

## L0 — Launch preparation — mostly prepared, nothing published

Goal: have every artefact a public launch needs sitting in the repository,
reviewed, and honest — so that publication becomes a sequence of decisions
rather than a sequence of writing tasks.

- **Brand and identity assets.** **Done.** `docs/design/IDENTITY.md` §1
  specified the mark; `brand/` now implements it as vectors: the mark at
  both detail levels, a menu-bar template symbol, a wordmark, favicons, a
  1200×630 social card, and unmasked 1024×1024 layers for Apple's Icon
  Composer pipeline (`brand/icon/`, deliberately flatter than the mark —
  `docs/design/tahoe/HIG-FINDINGS.md` requires layered icons carry no baked
  highlights, shadows or bevels). All original work, Apache-2.0, no
  third-party asset and no embedded font; `brand/README.md` records why the
  wordmark sets in a live system font rather than being outlined.
  `brand/render.sh` regenerates every raster from the vectors.

- **Competitive white-box analysis.** **Done.** `docs/comparison.md`:
  Morbstack against Docker Desktop, OrbStack, Podman Desktop, Rancher
  Desktop, Colima and Apple's `container`, on architecture, licensing,
  features, and performance-claims-versus-measured-reality — with a
  section on where Morbstack is *worse* that is at least as detailed as any
  section favouring it. Every competitor claim is cited; every Morbstack
  number traces to a file in this repository. Notable finding: Docker
  Desktop is itself on `Virtualization.framework` now, so "uses Apple's
  hypervisor" is not a differentiator — the unmodified upstream engine and
  the licence are.

- **Packaging and distribution.** See `docs/RELEASING.md`,
  `scripts/make-dmg.sh`, `scripts/release.sh`, `packaging/`. The `.app`
  bundle pipeline already existed (`mise run app`); L0 adds a DMG with a
  drag-to-Applications layout, a Homebrew cask ready to submit, and a
  release script that runs what it safely can and refuses loudly where a
  credential is required. **Prepared, blocked on an Apple Developer
  account** — see "What a human must supply" below.

- **Website, documentation and download page.** `site/`. Static
  HTML and CSS, no framework, no build step, no external requests, works
  from `file://`. Landing, download, documentation, comparison. The
  download page's honest state today is "there is no binary; build from
  source", and it says so at the top rather than in a footnote.
  **Prepared, not hosted** — hosting is an L1 decision.

- **Repository publication preparation.** `LICENSE`, `NOTICE`,
  `CONTRIBUTING.md` (DCO), `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue and
  PR templates, a CI workflow that matches how the project actually builds,
  and `docs/PUBLISHING.md` — the ordered runbook for creating the org and
  pushing. **Prepared. Nothing has been pushed to any remote and no
  account or organisation has been created.**

### What a human must supply before L1 can start

Not a to-do list for a future contributor; a hard blocker list. None of
these can be produced by writing more code.

| Blocker | Needed for | Notes |
| --- | --- | --- |
| Apple Developer Program membership | Signing, notarisation, a DMG that opens without a Gatekeeper override | The single largest gate. Everything in `scripts/release.sh` that touches `codesign`/`notarytool` refuses without it. |
| A Developer ID Application certificate | `codesign` | Derived from the membership. |
| App-specific password or a `notarytool` keychain profile | `notarytool submit` | |
| A GitHub organisation or user account, and a repository name | Publication, CI, releases, the cask's `url` | `docs/PUBLISHING.md` is the runbook; the name is still a decision. |
| A domain, or a decision to use GitHub Pages | The website, and the absolute URL an OG image tag requires | |
| A security-contact email | `SECURITY.md`, `CODE_OF_CONDUCT.md` | Both currently carry `TODO(human)` markers. |
| The auto-update decision | Whether L1 ships an updater at all | See `docs/sparkle.md`, which lays out Sparkle 2 against a zero-dependency check-only notifier and against cask-upgrade-only, and ends in an explicit decision block. Not decided. |

## L1 — First public release — gated

Goal: a stranger downloads a DMG, drags it to Applications, opens it, and
their existing Docker workflow works.

Gated on the human blockers above **and** on the subset of M1 that
`docs/parity.md` shows a first-day user hits immediately. Shipping before
these is shipping something that breaks on first contact:

- **`docker-buildx` shipped.** `docs/parity.md` #13/#14: the guest's
  BuildKit is completely functional, multi-platform builds and cache
  mounts included; the only missing piece is the client-side plugin
  binary. Until it ships, the modern default `docker build` path is broken
  out of the box. Highest return on effort in the entire report.
- **Zero-config Docker socket discovery.** `docs/parity.md` #17: with no
  `DOCKER_HOST` and no context configured, nothing finds Morbstack —
  Testcontainers, most IDE Docker integrations and `docker-py`'s default
  client all fail. First-run should register a context the way a Desktop
  install does.
- **`host.docker.internal` / `gateway.docker.internal`.** `docs/parity.md`
  #18/#19: absent, not degraded. #22 shows the network path to the host
  already works, so this is DNS plumbing rather than new networking.
- **The `/tmp` bind-mount footgun fixed or made loud.** `docs/parity.md`
  #9: silently mounts an empty directory instead of the file. `morb doctor`
  already detects it; the failure itself must stop being silent.

Then, and only then:

- Signed, notarised, stapled DMG, published as a GitHub release.
- Homebrew cask submitted (or a personal tap stood up), so
  `brew install --cask morbstack` works.
- The website hosted at a real URL, with the download page pointing at a
  real artefact rather than at build-from-source instructions.
- The auto-update decision executed, whichever way it went.
- A published `docs/comparison.md` and `docs/parity.md` kept current with
  the release — the parity audit is a one-time snapshot today and must be
  re-run against the release commit before it is cited on a marketing page.

## L2 — Editor and IDE integrations — not started

Goal: Morbstack is reachable from where people actually work, without
Morbstack shipping a web view (`docs/architecture.md`, host integration
domain).

Ordered by leverage, which here means "how many users get it for free":

1. **Zero-config discovery is most of this, and it is L1 work.** VS Code's
   Docker/Dev Containers extensions, the JetBrains Docker plugin, and
   Testcontainers all talk to the Engine API through a socket they
   discover. Fix discovery and a large fraction of "IDE support" arrives
   with no extension written at all. This is why L2 is *after* L1 rather
   than parallel to it.
2. **A compatibility CI matrix that proves it.** `docs/compat.md` already
   commits to running Testcontainers (Java/Go/Node/Python), VS Code Dev
   Containers, JetBrains container tooling, the compose-spec conformance
   suite, kind, Tilt, Skaffold, act and Dagger, gated from M2. Publishing
   that matrix green is worth more than any extension.
3. **A VS Code extension**, only for what discovery cannot give away free:
   engine start/stop, VM status, `morb doctor` surfaced in the problems
   panel, the log stream. Deliberately thin — anything that duplicates the
   Docker extension is a maintenance liability.
4. **A JetBrains plugin**, same scope, same reasoning, and only if the VS
   Code one earns its keep first.
5. **A Zed extension** if Zed's extension API can host it.

Explicit non-goal, restated from `docs/compat.md`: this is not a Docker
Desktop Extensions compatibility shim. That model is web-view based and
conflicts with the SwiftUI-only host integration principle. The native
plugin SDK on the 1.x list is the Morbstack-native replacement, and it is
a different mechanism.

## L3 — Sustained public project — not started

Goal: the project survives contact with users.

- `morb debug` (M2) wired into the issue templates, so a bug report
  arrives with a diagnostics bundle attached.
- The compat matrix (M2) published on the website, generated from CI
  rather than hand-maintained.
- `morb bench` (M2) published on the website, so the performance target
  table below stops being aspirational and starts being a live scoreboard
  — including the red rows.
- Release cadence, changelog discipline, and a triage rotation that a
  one-maintainer project can actually sustain. `SECURITY.md` deliberately
  does not promise a 24-hour response for this reason.
- The independent security audit (1.0) — and publishing its findings,
  including the ones that were not fixed.

## Public performance target table

These are the numbers Morbstack commits to publishing accurate, current
status against (via `morb bench` from M2 onward), not just aspirational
marketing figures.

| Target                                   | Goal        |
|-------------------------------------------|-------------|
| Cold boot                                  | ≤ 2.0 s     |
| Resume (from suspend-to-zero)              | ≤ 500 ms    |
| Idle host CPU                              | ≤ 0.1 %     |
| Idle wakeups                               | < 20 / s    |
| Host RSS (morbstackd, idle)                | ≤ 120 MB    |
| Guest memory floor                         | ≤ 256 MB    |
| `git status` on a Linux source tree (bind mount, vs. native Linux) | ≤ 2x native |
| `npm install` on a bind-mounted project (vs. native Linux) | ≤ 1.5x native |
