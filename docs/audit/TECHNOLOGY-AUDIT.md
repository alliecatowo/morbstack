# Technology foundations audit

**Date:** 2026-08-03. **Scope:** is the technology Morbstack is built on sound, and what would
make it genuinely better than Docker Desktop and OrbStack rather than merely comparable.
Companion to [MASTER-AUDIT.md](MASTER-AUDIT.md) (what exists) and
[DIFFERENTIATION.md](DIFFERENTIATION.md) (what to build). This document judges the *bets*.

**Evidence discipline.** Every load-bearing claim below is labeled:

- **VERIFIED** — checked against a primary source during this audit: Apple/Docker/vendor
  documentation fetched today, the Moby patch and morbinit/MorbstackKit source in this repo,
  or an empirical result recorded in this repo's own docs.
- **REPORTED** — from a named secondary source (a GitHub issue, a competitor's docs read
  through a summary, subagent research with citations) not independently re-derived here.
- **INFERRED** — reasoned from verified facts; the reasoning is stated so it can be attacked.

Where the honest answer is *unknown*, it says unknown and names the experiment.

---

## Verdict

The foundation is sound, and the strongest possible evidence arrived this year: Apple shipped
its own VM-based container stack for macOS 26 and deliberately declined to build the thing
Morbstack is — a real Docker Engine with a real API, real Compose, one shared kernel
(REPORTED: apple/container#66 closed "not planned"; see §Apple below). One shared VM on
Virtualization.framework running boring upstream Moby, with all differentiation in mac-side
glue, is the same load-bearing shape Docker Desktop and OrbStack chose (VERIFIED: OrbStack's
architecture docs — "all while sharing the same kernel"), and nothing found in this audit
falsifies it. But two of the ten bets are strained in ways that matter now: **the Moby patch
is probably unnecessary** — the ecosystem's patch-free mechanisms (Docker Desktop's own
pluggable userland proxy above all) appear to answer the exact objection recorded in
`ENGINE-BUILD-DECISION.md`, and deleting the patch would collapse a whole chain of open
problems it created — and **the `fchmod`→`IN_ATTRIB` hot-reload bridge is a leaky
approximation with a documented production failure precedent** (REPORTED: colima#1244), fine
as an accelerant, wrong as the *only* signal. Neither strains the architecture; both strain
specific mechanism choices that have patch-free or layered alternatives. The rest of the
foundation's problems are absences, not wrong bets: no sleep/wake handling, no disk reclaim on
the shipped ext4 path, a balloon device attached but never driven, and a broken-but-maybe-
fixable save/restore that is the single biggest performance lever the project owns.

---

## Apple's Containerization framework — threat or validation

Primary research recorded 2026-08-03 in [`../COMPETITIVE-GAPS.md`](../COMPETITIVE-GAPS.md)
§"Apple is now a competitor"; this section builds on it rather than re-deriving it, and adds
the technology-audit reading.

**What it is now** (REPORTED, from that research against GitHub releases and Apple docs):
`container` v1.2.0 (29 Jul 2026), API frozen at 1.0 in June, monthly releases, 48.6k stars.
Architecture is **VM-per-container** on the Containerization framework, itself on
Virtualization.framework. Apple closed the Docker Engine API compatibility request as
**"not planned"** (apple/container#66). No native Compose, no Docker CLI compatibility.
Container-to-container networking needs macOS 26. virtiofs bind mounts slow enough that a
maintainer recommends named volumes. **Freed guest memory is never returned to the host**, so
the per-VM model accumulates cost at scale. No prebuilt kernel — a config recipe derived from
Kata's (VERIFIED against this repo's own experience: the kata release tarball is Morbstack's
practical kernel source for exactly this reason).

**What it means for Morbstack — three distinct things:**

1. **It validates the platform bet.** Apple building its container stack *on
   Virtualization.framework* makes vz the sanctioned, invested-in substrate. The shared
   kernel Morbstack boots is derived from the same Kata lineage Apple's recipe uses. The risk
   that Apple abandons or deprioritizes vz — the main falsifier for Bet 1 — went down, not up.

2. **It validates the differentiation bet by omission.** Every gap Apple explicitly declined
   — Engine API, Compose, the Docker ecosystem, shared-kernel density — is precisely
   Morbstack's thesis. The ecosystem's reaction is the tell (REPORTED): no major tool adopted
   Containerization as a backend; instead third parties bolt Docker-ish layers *onto* it
   (`socktainer`, `container-compose`). Bolting the world's most compatibility-sensitive API
   onto a VM-per-container substrate is structurally harder than what Morbstack does; those
   projects will spend years rediscovering why `--network container:x`, shm sharing, and
   Compose networks want one kernel (see Bet 2).

3. **The one real threat is `container machine`** — the persistent shared VM with the home
   directory mounted that Apple shipped in 1.0 (REPORTED). If Apple ever runs `dockerd`-shaped
   workloads in that machine, or blesses it as the place third parties do, Apple has quietly
   rebuilt Morbstack's architecture with OS-level distribution. Nothing suggests that today.
   **Watch it per release; do not react to it.** The correct hedge is already the plan:
   Morbstack's moat is the mac-side glue (fail-closed admission, port leases, lifecycle,
   provenance), which survives even a world where Apple ships the VM.

**Action:** track `container` releases quarterly (TECH-11); adopt nothing from it yet — its
kernel recipe is the one artifact worth borrowing when Morbstack forks a kernel (btrfs,
Bet 8).

---

## The ten bets

### Bet 1 — Virtualization.framework as the hypervisor

**Buys:** a maintained, sanctioned hypervisor with zero third-party dependencies; vsock,
VirtioFS, virtio-blk/net devices for free; **Rosetta for Linux VMs, which only vz offers** —
QEMU, libkrun/krunkit, and raw Hypervisor.framework all lack `VZLinuxRosettaDirectoryShare`
(VERIFIED for Morbstack's own working Rosetta integration; REPORTED for the alternatives'
lack of it); the unprivileged `com.apple.security.virtualization` entitlement model that
makes the no-admin story possible (Bet 10). Apple's own container stack now sits on the same
foundation (§Apple).

**Costs:** Apple's API surface is a hard ceiling with no escape hatch. Three ceilings are
live today: (a) `VZVirtioFileSystemDeviceConfiguration` exposes only `share`, `tag`, and
`macOSGuestAutomountTag` — **no DAX window, no cache-mode knob at all**, unlike QEMU's
virtiofsd (REPORTED from Apple API docs research; the guest kernel's `CONFIG_FUSE_DAX=y` is
therefore unusable — VERIFIED that `disk.rs`-adjacent mount code passes no `data` string
because anything but `dax`/`source` is `EINVAL`, and DAX has no window to map). (b)
`restoreMachineStateFrom` fails for direct-kernel (`VZLinuxBootLoader`) guests on macOS 26.4
even though `validateSaveRestoreSupport()` passes and save succeeds — VERIFIED empirically in
a standalone minimal harness (see memory/`morbstack-guest-kernel-constraints`); research
corroborates that restore appears to require a `VZVirtioGraphicsDeviceConfiguration` with a
scanout, which a headless guest lacks (REPORTED — treat as hypothesis, not fact). (c) The
balloon device exists but its reclaim behavior is undocumented and Morbstack never drives it
(VERIFIED: `VMManager.swift:1906` attaches `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`;
zero occurrences of `targetVirtualMachineMemorySize` in the tree).

**Falsifiers:** Apple deprecating a needed vz API; the virtiofs ceiling proving fatal against
OrbStack on metadata-heavy workloads *after* tuning (Bet 3's benchmarks decide this);
save/restore staying broken across macOS releases *and* the graphics-device hypothesis
failing (TECH-4 decides this).

**Verdict: sound — the alternatives are all worse.** QEMU costs performance, Rosetta, and a
huge dependency; libkrun costs Rosetta and maturity on macOS; Hypervisor.framework directly
costs re-implementing every device. Protect this bet by *testing its edges*: TECH-4
(save/restore with a scanout), TECH-5 (drive the balloon), TECH-3 (discard/TRIM behavior).

### Bet 2 — One shared VM, not VM-per-container

**Buys:** exactly what `architecture.md` claims and Apple's model now demonstrates by
counterexample — Compose networks and `--network container:x` need one kernel's namespace
set; shm/IPC workloads need one kernel; page cache shared across containers; fixed per-VM
overhead paid once. Apple's VM-per-container stack exhibits the predicted costs in production
today: memory never returned to the host per VM, container-to-container networking arriving a
year late (REPORTED, §Apple).

**Costs:** blast radius — one guest kernel panic kills every container (and nothing in
`VMManager` currently auto-recovers: `didStopWithError` sets `.error` and flushes waiters,
VERIFIED; recovery is manual). No microVM-grade isolation between containers — explicitly a
non-goal, and correctly argued: it matches upstream Docker-on-Linux's isolation model rather
than weakening it.

**Falsifiers:** a market shift making per-container hardware isolation table stakes for
*local development* (no sign of it; Docker sells ECI to CISOs, not developers — VERIFIED
against DIFFERENTIATION.md's market read); or Docker workloads becoming so kernel-divergent
that one kernel cannot serve them (no sign).

**Verdict: sound, and now a differentiator against Apple rather than a liability.** Both
incumbents made the same choice (VERIFIED for OrbStack: "sharing the same kernel"). Protect
it: add a VM-crash recovery policy (auto-restart with backoff + a truthful `morb doctor`
account of what died) so the blast-radius cost is bounded by seconds, not by the user
noticing. That is TECH-10 territory ("proper" drills), not an architecture change.

### Bet 3 — VirtioFS with same-absolute-path mounts

**Same-path is a genuine simplification, not a constraint.** It is what both incumbents do
(VERIFIED: `protocol.md` §5's design mirrors Docker Desktop's; OrbStack mounts host paths so
`-v $PWD` works unprefixed) and it eliminates an entire class of path-translation bugs by
construction — dockerd never learns it is in a VM. The one place it bites — macOS aliasing
(`/tmp` vs `/private/tmp`, `/etc`, `/var`) — has already been hit, understood, and
fail-closed correctly (VERIFIED: the `tmp_alias_mounted` fact and the `/etc`,`/var` 400s in
`protocol.md` §3.2). Keep it.

**The performance profile is the open question, not the design.** VirtioFS streaming
throughput is fine (1.1 GB/s write, runs-here). The known industry weakness is
metadata-heavy workloads — `git status`, `npm install` — and Morbstack has **never measured
them** (VERIFIED: DIF-3 explicitly lists both as missing from MorbBench). OrbStack claims
"custom dynamic caching and optimizations" on top of VirtioFS and itself admits "there is
still an inherent cost associated with going through macOS for file access," recommending
volumes for hot data (VERIFIED: OrbStack docs, fetched today). With no DAX and no cache knobs
on vz (Bet 1), Morbstack's tuning space is narrower than OrbStack's (they control their own
guest agent and, reportedly, substantial custom FS machinery). The realistic outcome is
parity-ish on streaming, a measurable gap on metadata until tier-2/tier-3 work.

**Falsifier:** the two missing benchmarks showing a >2–3× gap to OrbStack on bind-mount `git
status`/`npm install` that mount-option tuning cannot close — that is the trigger for tier 2
(synced shares), which also happens to be the hot-reload fix (Bet 4). Run DIF-3 before
believing any claim in this area, including this one.

**Verdict: sound design, unmeasured performance.** The tiered plan (tuned VirtioFS → synced
shares → morbfs) is the right shape because it spends effort only where measurement says to.

### Bet 4 — Hot reload via same-mode `fchmod(2)` emitting `IN_ATTRIB` only

**This is a simulation, and the failure tail is structural, not incidental.** The facts:

- Native virtiofs/FUSE has **no inotify passthrough at all** — the 2021 RFC (LWN 874000)
  never merged (REPORTED). Nobody gets host→guest file events for free; everyone in this
  market fakes it, syncs it, or doesn't have it.
- The `fchmod` trick emits `IN_ATTRIB`. Node's `fs.watch`/chokidar (Vite, nodemon) and Python
  watchdog treat that as a change; **Go's fsnotify maps `IN_ATTRIB` to a distinct `Chmod` op
  that consumers like `air` routinely filter out**, and Rust's notify-rs (cargo-watch,
  watchexec) does the same (REPORTED, from library sources). This exact pattern has already
  failed in production: colima#1244, "All inotify filesystem events are chmod/attribute
  events" — watchers that rebuild on write silently stopped rebuilding (REPORTED). The same
  mechanism exists in the wild only as a third-party shim (`docker-windows-volume-watcher`),
  not as anyone's primary signal (REPORTED).
- The incumbents: OrbStack's docs make **no documented claim about inotify fidelity at all**
  (VERIFIED today — community reports say watching works, but the mechanism and its limits
  are undocumented). Docker Desktop's VirtioFS mounts have long-standing inotify gaps; its
  real answer is Synchronized File Shares (Mutagen) — files genuinely written in the guest,
  so watchers get genuine full-fidelity events — sold as a paid feature (REPORTED).

**Verdict: sound as an accelerant, unsound as the foundation.** An `IN_ATTRIB`-only bridge
will *permanently* carry a tail of silently-broken watchers, and "silently" is the part that
violates this project's own honesty standard — a watcher that never fires looks exactly like
a user error. Three-part correction, filed as TECH-2:

1. **Reframe the bridge as best-effort** in every doc and in `morb status` — it accelerates
   chokidar/watchdog-class watchers, it does not implement inotify.
2. **Detection over documentation:** the conformance matrix (EN-7) is necessary but
   insufficient because users don't read matrices. `morb doctor` (or the live-share status
   itself) should detect the known-filtered ecosystems where practical and say so — even a
   static "Go fsnotify/air and cargo-watch will not see these events; use polling or a synced
   share" in the feature's own output beats a wiki page.
3. **Make tier-2 synced shares the correctness path**, not just a performance path: really
   writing files in the guest is the only mechanism that produces `IN_MODIFY`/`IN_CREATE`/
   `IN_DELETE` with true fidelity, and it converts Docker Desktop's paid answer into a free
   one. That is the durable differentiator hiding inside this bug.

One more falsifiable detail worth pinning in the spike: the design assumes a *same-mode*
`fchmod` still emits `IN_ATTRIB`. Linux emits the notification from the setattr path
regardless of whether the mode value changed (INFERRED from kernel behavior — verify with a
5-line C probe in the guest and record it, because the whole mechanism rests on it).

### Bet 5 — vsock for every host↔guest channel

**Buys:** the right transport, chosen for the right reason — no network listener anywhere, no
firewall interaction, unreachable from the LAN by construction; per-connection cost is a
thread pair, bounded by explicit caps (VERIFIED: `proxy.rs` 64, `dial.rs` 128). The framing
designs are individually careful: half-close correctness, backpressure, magic-prefixed
length-checked frames that close on desync, budget ladders pinned by tests on both ends
(VERIFIED: `protocol.md` §1, §3.1–3.2 and the named test pairs).

**Costs:** eight protocols on eight ports, each with its own hand-rolled parser — MRB0,
raw-relay, stream-dial preamble, datagram framing, payload-install lines, publish-all broker,
listener probe, live-share HMAC lines. Every one is an untrusted-input surface, and the
security review of exactly those surfaces is **blocked and unreviewed** (VERIFIED: OPS-8).
The cost of "no multiplexing" is not performance (one vsock connection per Docker connection
is the correct shape for hijack-heavy HTTP), it is *audit surface*: eight bespoke grammars
instead of one.

**Falsifiers:** a parser bug in any one of the eight (OPS-8 is the test); vsock connection
scaling failing under a heavy Compose project (TST-5 covers this; no evidence of strain
today).

**Verdict: sound transport, sprawling protocol surface.** Do not multiplex — the reasoning in
§3.1 against it is correct. Instead: freeze the port registry (already the rule), factor the
shared line-protocol/framing primitives so the eight parsers share one hardened core where
they can, and treat OPS-8 as the gating debt it is. gRPC adoption remains correctly gated on
an offline toolchain; it would collapse the grammar count but is not urgent.

### Bet 6 — Patching Moby, and the `-P` allocator

**The patch itself is well-made; the *decision* to patch is the most strained bet in the
project.** VERIFIED from the patch: 174 lines (166 in a new `daemon/morbstack_publish_all.go`,
8 hooked into `daemon/network.go`), active only when `HostConfig.PublishAllPorts` is set,
all-or-nothing allocation, `HostConfig` untouched so upstream restart-reallocation semantics
survive. As downstream patches go, this is the minimal, disciplined shape.

But look at what the choice costs, all of it already on the books: it falsified the
"unmodified upstream dockerd" claim (DOC-1's 26 corrections); it is the sole reason building
Morbstack requires Docker (`docker buildx` bake); it is why the CI guest-image job cannot run
on hosted macOS runners; it forced the entire SP-4 release-artifact apparatus (build
workflow, attestation, provenance exception — VERIFIED: `ENGINE-BUILD-DECISION.md` exists
*only* because this one asset has no upstream checksum); and it is a rebase tax on every
Moby release forever.

**And no comparable tool pays it.** (REPORTED, from primitives research with sources:) Lima
runs a guest agent that polls `/proc/net/tcp`/`tcp6`, discovers newly-listening sockets, and
opens matching host ports reactively (gRPC over AF_VSOCK since 1.1.0); gvisor-tap-vsock
(Podman Machine) exposes an explicit `Expose()`/`Unexpose()` forwarder; both run dockerd's
in-guest allocator **unmodified** and bind late. Docker Desktop does something better still:
it points stock dockerd at a custom userland proxy binary, and that hook is a **stock dockerd
flag** — `--userland-proxy-path`, present in today's dockerd reference (VERIFIED, fetched
today). vpnkit's own design doc describes the contract (VERIFIED, fetched today): dockerd
invokes the proxy per published port with `-proto/-host-ip/-host-port/-container-ip/
-container-port`, the custom proxy asks the host to bind, and it receives "success or error
(e.g. `EADDRINUSE` or `EADDRNOTAVAIL`)" back — a failed host bind fails the container start,
and a crashed proxy's closed descriptor auto-releases the forward.

**Does patch-free answer `ENGINE-BUILD-DECISION.md`'s objection?** The recorded objection is
that Moby only knows the effective `-P` set after `HostConfig` is fixed, so nothing published
by `-P` is host-reachable without the patch. Two patch-free mechanisms answer it differently:

- **Late-binding discovery (Lima-style)** answers it by observing what actually got bound
  instead of predicting it — `docker port`/`inspect` agree because the forwarded number *is*
  the in-guest allocation, and restart reallocation is upstream behavior untouched. What it
  sacrifices is exactly the property Morbstack's port design is proudest of: fail-closed
  honesty. A Mac-side conflict yields a running container whose published port silently
  doesn't work, plus a start-to-forward race window. INFERRED: this is why it should not be
  Morbstack's shape, and that reasoning — currently missing from the repo — is now written
  down.
- **The userland-proxy-path wrapper (Docker Desktop's shape) appears to answer it
  completely.** dockerd's in-guest allocator picks the port; dockerd execs Morbstack's
  wrapper per publication; the wrapper asks the host broker (the vsock 2379 machinery already
  exists) to bind that port on the Mac and only on success execs/impersonates the stock
  `docker-proxy` so the guest-local listener the stream-dial path needs still exists; on
  `EADDRINUSE` it exits nonzero and the start fails honestly — *identical semantics to Docker
  on Linux*. libnetwork's portmapper retries dynamic allocations against proxy startup
  failure (INFERRED from libnetwork source knowledge — the spike must pin the exact behavior
  in Moby 29.x), which would make `-P` self-heal around Mac-side conflicts. `docker port`,
  `inspect`, and restart behavior are upstream code paths, untouched.

If the spike confirms the wrapper shape, the payoff is large and enumerable: delete the
patch, restore the honest "unmodified upstream dockerd" claim, drop the Docker-to-build-
Docker bootstrap, collapse SP-4/OPS-9/parts of REL-1 into "fetch stock binaries like
everything else," end the rebase tax — and possibly retire chunks of the create-preflight
TCP lease machinery, since host-authoritative binding would now happen at the moment dockerd
publishes rather than by peeking at create bodies (do not overclaim this last one; the
preflight also does bind-mount admission, which stays regardless).

**Filed as TECH-1, a spike whose deliverable is a decision.** The patch is not wrong — it is
disciplined engineering against a real problem — but it is the expensive answer to a question
the ecosystem answers cheaply, and the repo currently contains no recorded reasoning for why
the cheap answers were rejected. Either that reasoning gets written (and survives contact
with the vpnkit precedent), or the patch goes.

### Bet 7 — Zero-dependency Rust PID 1

**Buys:** no supply chain in the guest's most privileged process, a small static binary, and
total control of boot ordering. The dreaded costs turn out to be better-managed than the
project's reputation suggests: the hand-rolled SHA-256 tests against published vectors
(VERIFIED: `sha256.rs`), the HMAC comparison is constant-time (VERIFIED:
`live_share_receiver.rs:530`), and PID-1 discipline is right — a single `waitpid(-1)` reaper
with an explicit comment that a second reaper is "a race no amount of care survives"
(VERIFIED: `main.rs`). This is not amateur crypto hygiene.

**Costs:** morbinit is now **~14,200 lines across 21 modules** (VERIFIED) — a parser
(`jsonlite`), an HTTP-adjacent relay, five wire protocols, SHA-256, HMAC, disk provisioning,
DNS, binfmt. The zero-crate rule made every one of those a from-scratch implementation whose
bugs are Morbstack's alone. The realistic risk is not the crypto primitives (tested, simple,
stable) but the *protocol parsers* — which is Bet 5's audit-surface problem wearing a
different hat, and lands on the same remedy (OPS-8).

**Falsifiers:** a CVE-class bug in a hand-rolled component that a vendored audited
implementation would have avoided. Mitigation short of abandoning the policy: extend the
SHA-256/HMAC tests to full NIST CAVP vector sets and add differential fuzzing of `jsonlite`
and the line protocols against reference implementations *on the host side, in tests* — the
zero-crate rule constrains the shipped binary, not the test suite (INFERRED; filed inside
TECH-9).

**Verdict: sound, with the caveat that "no crates" is a security posture only if the review
debt (OPS-8) is actually paid.** An unreviewed hand-rolled parser is strictly worse than a
widely-fuzzed dependency.

### Bet 8 — ext4 on a grow-only raw disk image

**Current reality, all VERIFIED:** the kata 6.18.15 kernel has no btrfs (empirical; mount
fails ENODEV), so `disk.rs`'s btrfs-first preference — including the `discard=async` mount
option whose whole point is letting "the sparse host image shrink back" — is **dead code on
every shipped install**. The ext4 path mounts with kernel defaults: no `discard`, and there
is no `fstrim` anywhere in the tree. Consequence: `disk.img` genuinely never returns space to
the Mac. That reproduces Docker Desktop's single most-complained-about defect
(DIFFERENTIATION.md T8 calls this out) in a project whose pitch is being better. Meanwhile
`morb disk grow` is broken in both directions (EN-4: guest FS didn't grow, a *refused* grow
still mutated config) — evidence the storage layer is the least "proper" subsystem today.

**The fix is cheap if one unknown resolves:** does Virtualization.framework's virtio-blk
translate guest discard into hole-punching on the raw file? If yes (unknown — Apple does not
document it; the experiment is trivial), then `-o discard` or a periodic `fstrim` on ext4
reclaims space with zero new architecture. If no, reclamation needs the heavier compact-by-
copy path. **TECH-3 is that experiment**; run it before designing anything.

**btrfs remains the better end-state** (compression shrinks the layer store; reflinks;
`discard=async`) and requires exactly the kernel fork the project already plans, with Apple's
Containerization kernel recipe as the sanctioned starting point (§Apple). Sequencing: TECH-3
first (may make ext4 good enough), kernel fork second, and the M2 disk-root/`switch_root`
work — which also fixes the `DOCKER_RAMDISK` chroot weakness — stays on its existing track.

**Verdict: the bet (raw image + boring filesystem) is sound; the missing reclamation is a
product defect, not a design flaw.** Grow-only-never-shrink for the *image file* is the right
safety posture (never truncate live data); reclaim must come from TRIM, not truncation.

### Bet 9 — Rosetta binfmt for amd64

**Verified working, honestly measured:** amd64-only mysql:5.7 boots, digests bit-identical to
host, ~1.0× container start, 1.5–1.7× compute (VERIFIED, runs-here). The binfmt `F` flag
insight — interpreter pinned at registration so `/run/rosetta/rosetta` needn't exist in
container images — is exactly right (VERIFIED empirically).

**Where it breaks** (REPORTED/known-class, to be pinned by the amd64 test matrix rather than
prose): no 32-bit x86; historically no AVX-class instruction sets inside Linux VMs (some
software probes CPUID and falls back, some — older TensorFlow wheels, certain databases —
aborts); JIT-heavy and self-modifying workloads carry the worst multipliers; `ptrace`-based
debugging of translated processes is unreliable. The qemu-user fallback for these cases is
documented as the plan and **absent** (VERIFIED: architecture.md lists it, nothing ships it).
The untaken cheap win is `VZLinuxRosettaUnixSocketCachingOptions` AOT caching, already noted
in project memory (VERIFIED note; effect unmeasured).

**Falsifier:** Apple sunsetting Rosetta for Linux VMs — already hedged with the FEX-Emu
contingency on paper. **Verdict: sound; ship the failure-mode matrix before someone else
writes it as a bug report**, and don't build the qemu fallback until a real workload demands
it.

### Bet 10 — The macOS integration surface and the privilege model

**The no-admin/no-sysext/no-LaunchDaemon posture is a lasting advantage, not a ceiling — and
the project has already proved the hard cases.** SP-2/SP-3 (VERIFIED decision docs):
unprivileged mDNS `A`-record registration works on macOS 26.4 with no entitlement, no
password, no dialog; `.local` chosen with the tradeoffs priced; the "non-root cannot bind
80/443" wall answered by moving the listener into the guest. The SMAppService LaunchAgent
with `KeepAlive` + throttle (VERIFIED: `dev.morbstack.daemon.plist`) gives daemon-crash
recovery without a privileged daemon. Every macOS release tightens what privileged/kernel-
adjacent software may do; the incumbents' installers fight that trend, Morbstack rides it.

**The genuine ceilings, named honestly:** NAT-only networking today — bridged interfaces need
Apple's restricted `com.apple.vm.networking` entitlement (REPORTED, Apple docs), and
host-routable container IPs (DIF-6) will need the planned userspace stack (morbnet, a
gvisor-tap-vsock fork) rather than kernel routes; that is buildable unprivileged, as
OrbStack's "custom virtual network stack" existence proves (VERIFIED that theirs is custom
and NAT-based, from their docs; their exact routing mechanism is not documented). VPN
coexistence (split-DNS, corporate resolvers) is designed for (morbdns honoring scoped
resolvers) but entirely unbuilt. **Verdict: sound, and strategically so; the ceiling is real
but high, and everything above it is enterprise-fleet territory the project has correctly
declined to chase.**

---

## What "proper" requires

"Proper" means: correct under conditions nobody demoed, degrades honestly instead of lying,
survives upgrades and crashes, and a stranger can install it and trust it. Scored against
that standard, mechanism by mechanism (all VERIFIED against the tree today):

**Already thought about, genuinely well:**
- **Concurrent daemons/CLIs** — `flock`-serialized single instance, TOCTOU-aware, plus
  live-socket double-check (`Daemon.swift`). Per-connection IPC error containment.
- **Crash of the daemon** — launchd `KeepAlive` with `ThrottleInterval`; socket activation
  means clients re-trigger service.
- **Shutdown integrity** — the nested budget ladder (guest 54s ⊂ host 65s ⊂ stop 90s ⊂ CLI
  120s), pinned by tests on both sides, with `ok`-after-flush semantics. This is the single
  most "proper" artifact in the repo.
- **Restore failure** — detected once, recorded (`save-restore-unsupported` marker), degraded
  to a path that is itself fast; never retried blindly.
- **Persistence honesty** — `docker_data_on_disk` reported by the guest and surfaced by
  `morb doctor` instead of assumed. mkfs only on positively-verified-blank devices.
- **Version drift** — additive-fields rules, `morbinit_version`/`version` probes, `Bool?`
  decoding for fields older guests never send.

**Not thought about at all (the checklist this project should be held to):**

| # | Condition | Today | Required |
| --- | --- | --- | --- |
| P1 | **Host sleep/wake** | Zero handlers in the tree (no `willSleep`/`didWake`/IOKit power hooks) | Register for wake; re-probe guest, re-sync clock, verify forwarders |
| P2 | **Guest clock skew** | `clock_sync` computes and logs the delta, never applies it (no `CAP_SYS_TIME` step) | Apply on wake/resume; containers doing TLS fail on skew, silently |
| P3 | **Host disk pressure** | Nothing watches Mac free space; a sparse `disk.img` grows into a full volume and the guest gets undefined I/O errors | Low-space detection → honest pause/warning before corruption territory |
| P4 | **Guest disk full** | ext4-full → dockerd errors (fine) but untested; no reclaim (Bet 8) means it *will* happen | TECH-3 + a `docker system df`-aware doctor check |
| P5 | **VM panic / unexpected stop** | `.error` state, message logged; no recovery policy | Auto-restart with backoff + truthful post-mortem in `morb doctor` |
| P6 | **Upgrade across versions** | Compat rules exist on the wire; no test ever ran old-daemon/new-guest or the reverse; config has no schema versioning | One cross-version matrix run per release; version the config |
| P7 | **Corrupted state** | Blank-probe protects the disk; nothing validates `config.toml`, `vmstate.bin`, or a torn `disk.img` superblock on the host side | Fault-injection drills; doctor checks that read, not assume |
| P8 | **Machine restart** | `RunAtLoad` + socket activation — covered | Keep |

P1+P2 compound: a MacBook that sleeps overnight with the VM running wakes with a guest clock
hours behind and no code path that notices. That is the "behaves correctly under conditions
nobody tested" failure in its purest form, and it is the gap most likely to burn a real user
in week one. Filed as TECH-6 (sleep/wake+clock) and TECH-10 (the drill matrix for the rest).

---

## How to be genuinely better — the three capabilities

Not a feature list; the technical positions that would make Morbstack the obvious choice, and
why *this* codebase specifically can hold them.

**1. The only container platform whose claims are checkable.** The pieces exist here and
nowhere else in this market: a publishable benchmark harness (MorbBench), a SHA-pinned
provenance chain for every third-party byte, fail-closed admission that returns honest
Docker-shaped errors instead of silently substituting guest state, truth-telling status
(`docker_data_on_disk`, `userland_proxy`, shares degradation), and — if TECH-2 lands — the
industry's first *published watcher conformance matrix* for hot reload. Closed competitors
structurally cannot match "here is the harness, run it yourself; here is the matrix, here is
the hash." This is "proper" converted into the product's identity, and it is protected by
culture (the evidence vocabulary, the truthfulness passes), which is why it must be defended
against well-meaning marketing edits (see below).

**2. Zero-cost idle with instant, honest wake.** Cold boot is already ~2s; `morb stop` is
~0.3s. If TECH-4 (scanout + Developer ID save/restore retest) unlocks `vmstate.bin` restore,
Morbstack gets true suspend-to-zero with ~500ms socket-activated resume — beating OrbStack's
"low idle" positioning with literally-zero idle, something neither incumbent offers because
both keep a VM warm. Possible *here specifically* because the guest is a tiny owned initramfs
(nothing to re-warm), lifecycle is one process end-to-end, and the degraded path is already
built and honest. Even if TECH-4 fails, drive the balloon (TECH-5) and own the measured-idle
crown with the harness from (1).

**3. Hot reload as a *contract*, not folklore.** Everyone's file-event story on macOS is
undocumented mush — OrbStack doesn't document fidelity (VERIFIED today), Docker charges for
the mode that actually works. Morbstack can ship: same-path VirtioFS + the fchmod accelerant
for the forgiving 80% + tier-2 synced shares as the *free*, full-fidelity correctness mode +
doctor-level detection of watchers the accelerant can't serve + the published matrix proving
all of it. The live-share bridge's authenticated, bounded transport (already built) is the
hard part of a synced mode's control plane; the market's paid answer (Mutagen) becomes the
free one. That converts this audit's harshest finding (Bet 4) into the sharpest wedge.

---

## What is already right and must be protected

- **The shared-VM, boring-upstream-engine architecture** (Bets 1–3). Apple just spent a year
  validating it by building the other thing. Do not let per-container-VM envy in.
- **Same-absolute-path mounts with no translation layer.** Every alternative reintroduces the
  bug class this eliminates by construction.
- **The fail-closed admission philosophy** — refusing with a Docker-shaped error rather than
  silently substituting guest state. TECH-1's patch-free evaluation must be held to this bar
  (it is why Lima's reactive model is rejected even as its existence proves the patch
  optional).
- **The shutdown budget ladder and its cross-language pinning tests.** The template for every
  future timeout in the system.
- **Provenance pinning and the evidence vocabulary** (`source-only`/`runs-here`/`accepted`).
  The audit trail is a product feature (capability 1); treat edits that soften it as
  regressions.
- **The no-admin privilege posture**, including the guest-side answers to privileged-port and
  DNS problems. Never accept a design that needs a password prompt when a guest-side or
  mDNS-shaped answer exists.
- **Honest degradation paths** — tmpfs fallback with truth-telling, restore-failure marker,
  `502`-with-reason instead of connection reset. Extend them (P1–P7); never trade them for
  demo polish.

---

## Tickets filed

TECH-1 … TECH-11, appended to [`../../TASKS.md`](../../TASKS.md) under "Technology
foundations". TECH-1 (patch-free `-P`), TECH-2 (hot-reload foundation), TECH-3 (TRIM/discard
experiment) and TECH-4 (save/restore scanout experiment) are spikes whose deliverable is a
decision; they reshape SP-4/OPS-9/REL-1, EN-7/DIF-1, EN-5/T8, and the lifecycle roadmap
respectively.
