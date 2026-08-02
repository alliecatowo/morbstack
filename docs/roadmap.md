# Roadmap

Status: living document, updated per milestone. Timeframes are targets,
not commitments; scope within a milestone is more load-bearing than the
calendar date.

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
- `k3s` + `cri-dockerd` supported, for users who want a local Kubernetes
  story on top of the same Docker Engine.
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
