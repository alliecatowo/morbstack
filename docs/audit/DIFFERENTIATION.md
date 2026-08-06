# Differentiation — where to aim Morbstack next

Companion to [`PRODUCT-AUDIT.md`](PRODUCT-AUDIT.md), which establishes what
exists. This document is opinionated about what to build.

---

## 1. Correct the premise first

The question was "what non-barebones features do OrbStack and Docker Desktop
hide behind a paywall". The honest answer changes the strategy:

**OrbStack paywalls almost nothing.** Automatic `.orb.local` domains, zero-setup
HTTPS with a local CA, routable container IPs, Finder-native access to container
and volume files, Rosetta, Kubernetes, Linux machines, sub-second start — all
free tier. The *only* gated capability is the Debug Shell ($8/user/mo). What
OrbStack sells is a licence to use those features at work, at any company that
bills more than $10k/yr.

**Docker Desktop paywalls a lot, but almost none of it is an ergonomic.** Scout,
Build Cloud, Docker Offload, Enhanced Container Isolation, Hardened Desktop,
Registry/Image Access Management, Settings Management, air-gapped containers,
SSO/SCIM. Every one of those except Scout is fleet-and-compliance tooling sold
to a CISO, not a developer. That is the wrong market for a one-maintainer
Apache-2.0 project — you cannot win a compliance sale without an org behind you,
and trying will consume the whole roadmap.

So the strategy is **not** "give away paid features." It is:

> Build OrbStack's free-tier feature set, in the open, with no commercial-use
> asterisk — and be honest that this means building it, not undercutting it.

That is a real position. OrbStack's own community sentiment ("some appreciate
the quality, others would prefer if it were open source") is the opening. But it
only pays off if the features actually exist, because "free and Apache-2.0" is
already true of Podman Desktop, Rancher Desktop, Colima and Lima. Licence alone
ties you with four incumbents; it does not beat them.

---

## 2. Table stakes — if these are not true, nothing else matters

No differentiator earns a switch from a tool that can't run the user's project.
These are ordered by "how fast does a new user hit this".

| # | Table stake | Status | Why it is a gate |
| --- | --- | --- | --- |
| T1 | You can install it | ABSENT | No DMG, no notarised build, no cask. A prospective user cannot try it. |
| T2 | Stock `docker` works on a Mac with no Docker | REAL in source, never run | Everything downstream is unverifiable until CP-01–CP-07 passes on a clean account. |
| T3 | Testcontainers finds the socket | Untested, no fixture | This is the single most common silent adoption blocker. It probes conventional paths and gives up quietly. |
| T4 | `docker run -P` works | Cannot run today | Every `docker-compose` tutorial and a large share of Makefiles use it. "Most `-p` forms" is not a drop-in replacement. |
| T5 | Hot reload works | Untested mechanism | The #1 reason a developer abandons a container dev loop. |
| T6 | A shell into a running container, from the app | ABSENT | Docker Desktop and OrbStack both put this one click away. There is no `exec` in `DockerClient.swift` and no PTY view anywhere. |
| T7 | Add a shared folder without editing a TOML | ABSENT | `TrackDSharingSettings.swift:5-7` admits the config file is the editing surface. |
| T8 | Disk reclaims space | ABSENT | Docker Desktop's ever-growing disk is a top-3 user complaint. Reproducing it is not neutral, it is a known defect. |

> **Three of these have been met since, 2026-08-05 (UX-21).** The table is kept
> as the dated snapshot; this is what the code did to it.
>
> - **T3 — met, and it is now a lead.** Fixture and harness both exist
>   (`integrations/fixtures/devcontainer`, `scripts/ecosystem-acceptance.sh`),
>   and Testcontainers **Node 12.1.0, Go v0.43.0, Java 1.21.4 and Python
>   4.15.0** all passed real Postgres round trips with Ryuk against server
>   29.7.1 — under `env -i`, **no `DOCKER_*` or `TESTCONTAINERS_*` variables at
>   all**, no `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`
>   ([ECOSYSTEM-MATRIX.md](ECOSYSTEM-MATRIX.md) zero-config rerun; ECO-1/ECO-2,
>   design in [../design/ZERO-CONFIG-DISCOVERY.md](../design/ZERO-CONFIG-DISCOVERY.md)).
>   OrbStack has an open Testcontainers issue (#2035, since 2025-07-10) and
>   Docker meters Testcontainers Cloud; see [CAPABILITY-GAP.md](CAPABILITY-GAP.md) §12.
> - **T4 — met.** TECH-1 ships stock upstream dockerd driven through its own
>   `--userland-proxy-path` hook, no engine patch; `docker run -P nginx:alpine`
>   served `curl` an HTTP 200 in 4.3 ms against a rebuilt guest
>   ([../design/PATCH-FREE-PUBLISH-ALL.md](../design/PATCH-FREE-PUBLISH-ALL.md)).
> - **T6 — the stated evidence is now false, though the user-visible gate is
>   only half open.** `DockerClient.swift` has exec (`executeContainerCommand`
>   :1042, `createExec`/`resizeExec`/`inspectExec` :1524-1547) and there *is* a
>   PTY view: `mac/Sources/MorbstackAppCore/Terminal/` holds
>   `DockerExecPTYSession`, `TerminalEmulator`, `TerminalKeyEncoding`,
>   `TerminalSurfaceView` and `ContainerTerminalWindowController` with four test
>   files. No UI entry point calls it yet, so "one click away" is still DIF-2's
>   to close — but the VS Code extension already ships the interactive shell
>   over a hijacked exec stream (`integrations/vscode/src/api.ts:329-402`).
>
> **T7 and T8 stand as written.** `sharedPaths` is still config-file-only, and
> disk space still never returns to the Mac — see the Tier B correction below.

**T1 is the one that should be uncomfortable.** 75,000 lines of Swift, 739 test
functions, a genuinely careful port-lease design, an excellent security posture
— and zero people have ever run it. Every additional week of feature work
compounds the amount of unvalidated code. The highest-value engineering action
available right now is not a feature; it is rebuilding the guest image, running
CP-01–CP-07, and shipping a DMG to ten strangers.

---

## 3. The differentiator shortlist, ranked by impact per unit of effort

Effort is calibrated in weeks of one focused engineer. Impact is "would this
make a working developer switch".

### Tier A — build these

#### A1. Automatic container domains + local HTTPS
**Impact: very high. Effort: high (6–10 weeks). Prerequisite: a router that
does not exist.**

This is OrbStack's clearest single win and **no free tool has it.** The
alternative today is hand-wiring Traefik + mkcert + dnsmasq per project, which
is genuinely miserable: you must install a CA, configure a resolver for a TLD,
and hand-write routing labels per container. Browsers won't accept a wildcard
`*.test` certificate, so each name needs explicit cert coverage.

Architectural prerequisites in this codebase, none of which exist:
1. A `ServiceRouter` — a daemon-owned loopback HTTP/1.1+TLS reverse proxy.
   `docs/domains.md:145-152` already made the right call: use a pinned,
   audited SwiftNIO rather than hand-rolling HTTP. Do not relitigate that.
2. A generation-bound **transport lease** from `PortForwarder`. This is the
   subtle part and `docs/domains.md:53-57` already identified it: the router
   must not prove a port and then `connect("127.0.0.1", n)` by number, because
   that races a withdrawn listener and a new process binding the same port.
   `PortForwarder.localDomainForwardSnapshot` (`:448`) is the seed of this and
   currently has no consumer.
3. A scoped DNS answer for one suffix. `docs/domains.md:181-189` correctly
   forbids `/etc/resolver` writes and `scutil` hacks, which leaves a
   user-approved `NEDNSSettings` with `matchDomains`. **This needs a
   feasibility spike before anything else** — if the entitlement forces
   Morbstack to become a general DNS proxy, the whole feature changes shape.
4. A per-user CA in the Keychain with exact-SAN leaf issuance.

Two decisions to make now, cheaply:
- **Retire `.local`.** `docs/domains.md:37` already decided `.test` is
  canonical because `.local` is reserved for mDNS, but
  `MorbLocalDomain.swift:17` still hardcodes `morb.local` and so does every
  README mention. Fix the source to match the decision before anyone builds on
  the wrong string.
- **Sequence it as three shippable products, not one.** (a) A router with
  explicit `http://localhost:PORT/name` routing needs no DNS and no CA and can
  ship in ~2 weeks — that alone beats hand-written Traefik configs. (b) Scoped
  DNS. (c) HTTPS. Each is independently useful; bundling them guarantees none
  ships.

#### A2. Make hot reload actually work, and prove which watchers it satisfies
**Impact: very high. Effort: low-to-medium (2–4 weeks, mostly testing).
Prerequisite: a guest image rebuild.**

The mechanism already exists and is clever. It is also `IN_ATTRIB`-only — a
same-mode `fchmod(2)` (`guest/morbinit/src/sys.rs:221-232`). That satisfies
Node/libuv (so chokidar, nodemon, vite, webpack) and Python `watchdog`. It
maps to a `Chmod` op in Go's `fsnotify`, which tools like `air` filter out. And
file *creation* nudges the parent directory's attributes rather than emitting
`IN_CREATE` for the child.

What to do, in order:
1. Rebuild the guest. This has to happen anyway.
2. Build a watcher conformance matrix — chokidar, Go `fsnotify`, Java
   `WatchService`, Ruby `listen`, `entr`, `watchexec` — and *publish the
   results*. "Hot reload works for these 9 of 12 frameworks, here is the
   evidence" is a stronger and more credible marketing claim than OrbStack's
   unqualified assertion, and nobody else in this market publishes one.
3. For whatever fails, decide between a guest-side inotify shim and accepting
   the gap loudly.
4. Turn it on. Today `liveSharePaths` defaults to `[]` (`MorbConfig.swift:109`)
   and there is no CLI or GUI writer anywhere. A feature reachable only by
   hand-editing TOML is a feature nobody uses. The right default is probably
   "the bind-mount sources of currently running containers", derived
   automatically, with an opt-out.

This is the best impact-per-effort item on the list: the hard engineering is
done, what remains is a rebuild and a test matrix.

#### A3. A container shell — plain exec first, distroless toolbox second
**Impact: high. Effort: low for exec (1–2 weeks), medium for the toolbox
(3–5 weeks).**

`morb debug` is aimed squarely at the one thing OrbStack charges for, which is
strategically correct. But the project is trying to build the differentiator
before the table stake. There is no `exec` in `DockerClient.swift` and no PTY
view under `MorbstackAppCore/` — you cannot get a shell into an *ordinary*
container from the app.

Ship in this order:
1. `POST /containers/{id}/exec` + hijacked stream + a real PTY view in the
   container detail. This is well-trodden and unblocks daily use.
2. `morb debug` on top of it: pinned toolbox image, consented acquisition,
   namespace-joined ephemeral container, cleanup receipt. `docs/debug.md`'s
   five-item execution gate is the right spec; it just needs (1) underneath it.

The PTY component is shared, so doing exec first makes the toolbox cheaper, not
more expensive.

#### A4. Prove the performance claims nobody else proves
**Impact: high. Effort: low (1–2 weeks). Prerequisite: `MorbBench` already
exists.**

OrbStack markets "less than 0.1% background CPU" and third parties repeat "~2s
start, ~200MB idle vs Docker Desktop's ~4GB". Nobody publishes a reproducible
harness. Morbstack has one — `MorbBench` already implements cold boot, idle
CPU, idle wakeups, host RSS and guest memory floor against real processes.

Two things are missing and they are the two that matter most commercially:
`git-status-bindmount` and `npm-install-bindmount-vs-volume` both report
`status: "not implemented"` (`MorbBench/Support/Targets.swift:67-71`). Bind-mount filesystem
throughput is *the* number people compare, and it is the number the roadmap
promises (`≤2x native` for `git status`, `≤1.5x` for `npm install`).

Implement those two, run the whole suite, publish the raw output plus the
harness. "Here is the benchmark, run it yourself" is a differentiator a closed
competitor structurally cannot match, and it costs two weeks.

#### A5. Cold-start economics for agent workloads
**Impact: high and rising. Effort: medium (3–5 weeks). Prerequisite: honest
suspend/resume.**

The 2025–26 shift nobody's local container tool is optimised for: coding agents
spinning up and tearing down many short-lived, isolated containers in parallel
(Dagger's `container-use`, agent sandboxes, per-task worktrees). That workload
rewards exactly the axis Morbstack already measures well — cold boot — and
punishes idle overhead.

The blocker is that `morb suspend` is a graceful stop plus cold boot, because
`restoreMachineStateFrom` doesn't work for a direct-kernel-boot guest on macOS
26.4 (recorded on disk as `~/.morbstack/data/save-restore-unsupported`). The
roadmap's "resume ≤500ms" target has nothing behind it.

Two options, and the first is probably right: (a) accept it, delete the
suspend/resume target, and market the ~1.7s cold boot as the number — it is
already competitive, and honesty about it is on-brand; or (b) investigate
whether a disk-root boot (`MorbConfig.BootMode.disk` already exists) makes VZ's
save/restore work where the initramfs path does not. Do not leave a published
performance target with no implementation behind it.

### Tier B — worth doing, lower leverage

- **Dev Containers support.** `devcontainer.json` is now editor-agnostic (the
  `@devcontainers/cli`, JetBrains Gateway, DevPod all implement it). Being a
  *good host* for it is mostly free once T2/T3 pass — it needs a pinned fixture
  and a CI job, not a feature.

  > **Mostly done, 2026-08-05 (UX-21).** The pinned fixture exists
  > (`integrations/fixtures/devcontainer`), the harness exists
  > (`scripts/ecosystem-acceptance.sh`, suite `devcontainers-cli`), and
  > `@devcontainers/cli` 0.88.0 passed live and **zero-config** — context-only,
  > no `DOCKER_HOST` — including exec, a two-way workspace bind mount,
  > `postCreateCommand`, and a features/derived-image build through Morbstack
  > BuildKit ([ECOSYSTEM-MATRIX.md](ECOSYSTEM-MATRIX.md), EN-9). What is still
  > missing is only the CI job: `.github/workflows/ci.yml` has no ecosystem
  > suite, which is why [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) reads
  > `runs-here` and not `accepted` (CP-07).

- **A GUI for shared folders (T7) and live-share paths.** Half a week each.
  Currently both are TOML-only, which no competitor requires.

  > **Half done, 2026-08-05 (UX-21).** Live-share paths have their GUI:
  > Settings › Sharing writes `liveSharePaths` through an `NSOpenPanel` "Add
  > Project Folder…" with per-row Remove, validated by `MorbLiveShareBridge.plan`
  > before it saves (`mac/Sources/MorbstackAppCore/Settings/TrackDSharingSettings.swift:95,179-198`).
  > `sharedPaths` (T7) is the half still standing: same screen, "Open
  > config.toml" only (lines 43, 56).

- **Volume browsing.** Full Finder mounting (FSKit) is a large project with
  hard consistency and durability semantics. A *read-only browser* inside the
  app, on top of the existing archive/export machinery, gets 80% of the value
  for 10% of the risk. `docs/competitive-capability-roadmap.md:100` already
  sequences it this way; agree.
- **Disk reclaim.** Corrected 2026-08-06 (TECH-3/UX-16) — this bullet
  previously claimed `discard=async` was "already on the guest mount", which
  was wrong in our own favour. `disk.rs:271-275` puts `discard=async` on the
  **btrfs arm only**, and the shipped kata kernel has no btrfs
  (`docs/architecture.md:183`; regression-tested at `disk.rs:1299-1302`), so
  the option is dead code: the guest actually mounts ext4 with no `discard`,
  there is no `fstrim` anywhere in the tree, and resize is grow-only. Disk
  space genuinely never returns to macOS today — Docker Desktop's own
  most-complained-about behaviour, reproduced faithfully. Before any plumbing
  work: the open, undocumented-by-Apple question is whether
  `VZDiskImageStorageDeviceAttachment` even translates a guest `discard` into
  hole-punching on the raw file at all. See
  `docs/design/DISK-RECLAIM-DECISION.md` for the experiment and its verdict.
  If discard passes through, this is close to "more plumbing than research"
  after all; if it does not, the honest scope is compact-by-copy, which is
  not free.
- **Fix the leaks in what exists.** `scripts/fetch-scan-tools.sh` referenced
  five times and absent; shell completions stale by 7 commands and factually
  wrong about `debug`; JetBrains "integration" is a README. Each is under a day
  and each is the kind of thing a first user finds in the first hour.

### Tier C — do not build

- **Docker Desktop's enterprise gate.** Enhanced Container Isolation, Hardened
  Desktop, Registry/Image Access Management, Settings Management, air-gapped
  containers, SSO/SCIM. These are sold to compliance buyers who need a vendor,
  an audit and a support contract. A one-maintainer project cannot serve that
  buyer and will burn a year finding out.
- **Docker Scout equivalence.** Keep `morb scan` as the thin syft/grype wrapper
  it is — that is exactly right. Bundle the binaries, write the missing fetch
  script, stop claiming "entirely on this machine", and go no further. Do not
  build a vulnerability service.
- **Build Cloud / Offload equivalence.** Cloud build farms are a hosting
  business. An account-free, no-telemetry project cannot and should not.
- **A Docker Desktop Extensions-compatible marketplace.** Already an explicit
  non-goal (`docs/compat.md:88`) and correctly so — Docker's own docs say
  extensions get elevated host, Engine, filesystem and native-binary access.
  Inheriting that attack surface for parity would destroy the security posture
  that is currently one of this project's genuine advantages.
- **Linux machines, for now.** OrbStack has 16 distros and SSH; it is a real
  feature and it is also a second product with its own image provenance, disk
  lifecycle, cloud-init and key-management surface. `MachineRegistry.swift:425-433`
  currently returns unavailable unconditionally, which is the right amount of
  machine support until domains, hot reload and exec all work.
- **GPU passthrough, USB, audio.** Correctly deferred. Note only that Lima's
  own 2026 roadmap is explicitly "hardening AI", and Podman Desktop ships
  libkrun/krunkit for GPU workloads — so this is where the *rest* of the free
  field is investing. Not a reason to follow; a reason to know the axis you are
  ceding.
- **Windows containers, CRIU.** Already non-goals. Keep them non-goals.

---

## 4. The order I would actually work in

1. **Rebuild the guest image and run CP-01–CP-07.** Nothing on this page is
   real until the guest matches the source. This is one day of machine time
   and it invalidates or confirms three headline features at once.
2. ~~**Fix the "unmodified upstream dockerd" claim.**~~ **Resolved 2026-08-04
   (TECH-1), the other direction from what this item recommended:** rather than
   qualifying the claim, the downstream patch it was about was deleted entirely.
   Morbstack now ships unmodified upstream `dockerd`, published ports go through
   dockerd's own `--userland-proxy-path` hook, and the "unmodified upstream
   dockerd" claim is true again — restored across the docs it had been corrected
   away from (see `docs/TRUTHFULNESS-PASS.md`'s third-pass section). The
   second-order bootstrap problem (needing `docker buildx` to build Morbstack's
   own engine) is resolved the same way: there is no patched engine left to
   build.
3. **Ship exec + a PTY** (A3.1). Two weeks, removes the most conspicuous
   daily-use gap.
4. **Prove hot reload** (A2) — rebuild, matrix, publish, enable by default.
5. **Publish the benchmark suite** (A4) including the two missing bind-mount
   targets.
6. **Spike the DNS entitlement** (A1.3) — a one-week feasibility answer that
   determines whether the domains feature is 6 weeks or impossible.
7. **Ship the router without DNS or TLS** (A1.a). Then DNS. Then HTTPS.
8. **Then** debug toolbox, volume browsing, disk reclaim.

Notice that steps 1–5 are almost entirely *validation and honesty* work rather
than new capability. That is the correct shape for a project with this ratio of
unvalidated code to users.

---

## 5. The one-sentence positioning that survives this audit

Not "OrbStack's paid features, free" — OrbStack barely has paid features.

**"Everything OrbStack does, in the open, at any company size — and we publish
the benchmark so you can check."**

That is a claim the competition structurally cannot match, and it is only
credible if the benchmark harness ships alongside the features. The project
already has the harness. It does not yet have the features.
