# Concurrency & protocol fixes — CONC-2..5, PROTO-1/3/5/6/7, MOD-4

**Date:** 2026-08-04 · **Branch:** `swarm/continuation` · **Scope:** `mac/Sources/MorbstackKit/**`, `guest/morbinit/**`
**Gate at completion:** 910 Swift tests / 240+ Rust tests green, `cargo clippy --all-targets -- -D warnings` clean, `mise run doctor` no drift.

Every ticket below was re-verified against current source before it was touched (the tree had
changed since the audit — the Moby patch and its allocator are gone; line numbers had drifted but
every defect was still live, with one partial exception noted under CONC-3).

A note on verification honesty, per this repo's standing rule: several of these are races that a
unit test cannot reliably reproduce. Where that is the case this document says "not unit-testable"
and points at the invariant comment instead of gesturing at a test that would pass for the wrong
reason.

---

## CONC-2 — stale-generation probe overwrites fresh diagnostics

**Defect.** `VMManager.beginControlProbe`'s `.ready` arm called `noteGuestPinged` /
`noteDockerDataOnDisk` / `noteGuestShares` on the probe worker *before* the
`generation == probeGeneration` guard. A probe from a superseded boot returning `.ready` after
`invalidateControlReadiness()` had wiped the snapshots would repopulate them with the previous
boot's answers, so `morb status`/`morb doctor` could report data the current guest never sent.
Confirmed before deleting: the three calls were exact duplicates of the ones already inside the
generation-checked `queue.async` block.

**Fix (three layers, because the defect had three copies):**
1. The unguarded `note*` calls (and the "guest ready" log + `reportShareMounts`, which would
   otherwise log a stale boot's success) moved inside the generation-checked block.
2. The `.dockerStarting` arm's `noteGuestPinged()` runs after a *blocking* network exchange, i.e.
   after the loop-top generation check has gone stale. It now uses a lock-atomic
   `noteGuestPinged(ifCurrent:)` that checks `_probeGeneration` inside the same `stateLock`
   critical section as the write. For that atomicity to close the window,
   `invalidateControlReadiness()` (and `beginControlProbe`) now **bump the generation before
   wiping** — once the wipe runs, any old-generation guarded write is already failing its check.
3. The same defect existed one function deeper: `probeGuestControlOnce` recorded the additive
   `info` fields (`rosetta`/`binfmt_amd64`, `tmp_alias_mounted`, `share_event_bridge`,
   `disk_resize`) from the probe worker with no guard at all. All four note functions gained the
   same `ifCurrent generation:` parameter. This was not in the ticket text; it is the identical
   bug class and is called out here so the extra diff is accounted for.

**Verification.** Not unit-testable (the window is between a wipe on the VM queue and a write from
the probe worker). The invariant — *bump before wipe; every off-queue snapshot write checks the
generation inside the state lock* — is documented at `invalidateControlReadiness`,
`noteGuestPinged(ifCurrent:)` and the `.ready` arm. Full suite green; `morb status` verified live
against a running daemon after the change.

## CONC-3 — `whenGuestPowersOff` races `guestDidStop`

**Defect (as re-verified, slightly narrower than the ticket).** The registration is scheduled from
the guest-control worker after the shutdown ack; the guest can power off — and `guestDidStop` land
on the serial queue — before that hop arrives. The ticket's headline consequence (burning the full
5 s deadline on every lost race) was already partially defended by a `virtualMachine != nil` guard
in `whenGuestPowersOff`, which the audit apparently missed: when `guestDidStop` wins, it nils the
slot and the late registration fired its body immediately. **The residual race was real, though:**
`startOnQueue` gates only on `virtualMachine == nil`, so a new boot could re-occupy the slot
between `guestDidStop` and the late registration — the nil-check then *passes*, the observer
latches onto a VM that will never power off, burns the 5 s, and then `hardStopOnQueue`s the fresh
boot. Nil-ness was the wrong predicate; identity is the right one.

**Fix.** The event is recorded rather than merely broadcast:
- `whenGuestPowersOff(vm, timeout:, body:)` now takes the `VZVirtualMachine` being stopped and
  registers only while `virtualMachine === vm`; anything else means the power-off (or its moral
  equivalent) already happened, and the body runs immediately.
- `releaseVirtualMachine` — the single point where the VM slot empties, on every path (clean
  power-off, error stop, hard stop, suspend) — is now the single flush point for pending
  observers. The two delegate callbacks lost their manual flush calls.
- The flush fires observers on the **next queue turn**, not inline: an observer body runs
  `hardStopOnQueue`, which services run-waiters, and doing that reentrantly inside `guestDidStop`
  (before *its* `flushWaiters(.failure)`) could boot a new VM before the callback finished
  recording that the old one stopped.

**Verification.** Not unit-testable (needs VZ delegate timing). Invariants documented at
`whenGuestPowersOff`, `flushGuestStopObservers` and `releaseVirtualMachine`. Full suite green;
clean stop/start cycles exercised live via `mise run dev`'s restart.

## CONC-4 — `Daemon.shutdown()` bypasses `forwarderQueue`

**Defect.** `shutdown` called `forwarder.stop()` directly (on whatever thread the signal source
ran it), while every other start/stop funnels through the serial `forwarderQueue` precisely so a
running → stopped → running flap cannot reorder. Masked today by the `exit(0)` a few lines later;
live the moment shutdown grows a tail.

**Fix.** The stop now runs inside `forwarderQueue.sync { … }`, which both serialises it behind any
queued `forwarder.start()` from a late VM state change and keeps shutdown's synchronous contract.
Deadlock-safe because nothing scheduled on `forwarderQueue` blocks back on its caller — verified
by reading every block enqueued to it (they hop onward with `async` only). Found and fixed in the
same block: shutdown never tore down the Kubernetes API forward listener or invalidated scheduled
reconciliations; it now bumps `kubernetesForwardGeneration` (orphaning any timer that would
re-publish 127.0.0.1:6443 between here and exit) and stops `k8s.forward` with the rest of the
ports, matching the teardown the VM state-change path performs.

**Verification.** Ordering not unit-testable. Reasoning documented at the call site. Daemon
restart (SIGTERM path) exercised live by `mise run dev`; clean shutdown log, no port leaks.

## CONC-5 — `UnixSocketServer.stop()` does not wait for its cancel handler

**Defect.** `TCPListener.stop()` blocks on `closedSignal` so "stop returned" means "descriptor
closed, port free"; `UnixSocketServer.stop()` cancelled the source and returned, leaving the fd to
be closed whenever the queue drained — and then unlinked the path while the descriptor could still
be open. Two listener types that mirror each other disagreed on what `stop()` means.

**Fix.** `TCPListener`'s private `ListenSocket` (idempotent close + `closedSignal` + lock-guarded
`acceptOne`, plus the 2 s `cancelHandlerGrace`) was extracted as the shared internal
`POSIXListenSocket`, used by both listeners. `UnixSocketServer.stop()` now cancels, waits on
`closedSignal` with the same grace, closes from the caller on timeout, and only then does its
inode-checked unlink. As a side effect the unix listener also gained TCP's accept/close
serialisation (`acceptOne` under the same lock as `close`), closing the theoretical
descriptor-reuse race on the timeout path.

**Verification.** `swift test` green (DockerProxy/Daemon control-socket paths exercise the unix
listener heavily); daemon stop/restart live via `mise run dev`. The wedged-queue fallback branch is
not practically testable — same status as TCPListener's, which shipped with the same caveat.

## MOD-4 — `K8s.installPort` outside `MorbVsockPorts`

Port 2377 now lives in `MorbVsockPorts.k8sInstall` with the other six vsock ports;
`K8s.installPort` is a documented alias into the registry instead of a second literal. Call sites
unchanged. Build + suite green.

## PROTO-1 — `morbinit_version` parsed but never consulted

**Defect.** The field `docs/protocol.md` calls *the* compatibility probe had zero live consumers.

**Fix (no negotiation protocol invented — the field simply stops being dead):**
- `MorbVersion.minimumCompatibleMorbinit` (currently `0.1.0-m0`) is the compiled-in minimum;
  raising it is the whole mechanism for a future breaking change.
- `MorbVersion.isOlder(_:than:)` orders `X.Y.Z[-mN]` strings (milestone suffix precedes bare core,
  semver-style; unparseable strings are never "older", so a future format cannot trip the gate by
  accident).
- The boot probe records the reported version once per boot (generation-guarded like every other
  snapshot) and logs a warning when it is older than the minimum — or absent entirely.
- Surfaces: `status` IPC gains `morbinit_version` (null until a guest answers), `morb status`
  gains a `guest morbinit` row with an inline "older than supported" flag, `morb doctor` gains a
  `guest-morbinit` check (pass / warn-with-remediation / info when nothing has booted).

**Verification.** `MorbVersionCompatibilityTests` (6 tests) pins the ordering rules including the
self-consistency of the shipped constants. Verified live: `morb status` shows
`guest morbinit 0.1.0-m0`; `morb doctor` shows
`[ok] guest-morbinit … (minimum supported 0.1.0-m0)`.

## PROTO-3 — inconsistent backpressure at connection caps

**Defect.** vsock 2376/2378 send `ERR busy\n` at their caps; 1024/2375/2381 silently dropped,
indistinguishable from a peer that never spoke.

**Fix (per-protocol framing respected, one reason word `busy` everywhere):**
- **1024 (control, MRB0):** a complete MRB0 frame carrying the ordinary
  `{"type":"error","message":"busy"}` reply — never a bare line, which would desync the
  length-prefixed reader. The host needed no change: `GuestControl.unexpected` already turns an
  `error` reply into `"guest reported: busy"`.
- **2375 (Docker relay, HTTP):** a synthetic `HTTP/1.1 503 Service Unavailable` with a JSON body
  and `Connection: close`, which the host relay passes through verbatim; it pairs with the host's
  existing synthetic 502 for "guest unreachable", so a client can now tell the two apart.
- **2381 (live-share, line protocol):** `ERR busy\n` in place of the `BOOT` greeting. The host
  side (`MorbLiveShareTransport.Session.open`) previously reported any non-`BOOT` opener as a
  generic boot-identity violation, which would have thrown the distinction away; it now surfaces
  `ERR`-prefixed openers as "live-share receiver refused the connection: busy".
- All three copy dial.rs's discipline: `poll(2)`-bounded 250 ms best-effort write, then close;
  a wedged peer cannot hold the accept loop, and a failed send cannot corrupt the counter guard.

**Verification.** Three new Rust unit tests (well-formedness of each payload); 240 Rust tests
green, clippy `-D warnings` clean, musl cross-build clean. `docs/protocol.md` updated where it
already documented over-cap behaviour (2375). Driving a real listener to its cap was not attempted
(64–128 concurrent vsock connections against a live guest); payload paths are unit-covered and the
accept-loop deltas are three lines each, identical in shape to the already-shipped 2376/2378 code.

## PROTO-5 — jsonlite's flat-only contract enforced only by convention

**Defect.** The guest's MRB0 parser rejects any nesting and poisons the whole frame; host structs
go through Foundation's fully general `JSONEncoder`, so one nested field compiles, passes Swift
round-trip tests, and fails 100 % of that message type at runtime.

**Fix.** `MRB0FlatnessTests.swift`: encodes a fully-populated instance of every type the host
actually sends over MRB0 — `GuestRequest` directly, and `K8s.Request` (private) by driving the
real `K8s.requestStatus` over a `socketpair(2)` and asserting on the literal frame bytes the
production path wrote, which is strictly stronger than testing a duplicated definition. Failure
messages name the offending type and key. Its teeth were verified by temporarily planting a nested
field (test failed naming it) and reverting. The reply side needs no mirror: the guest builds
every reply through `jsonlite::emit` over a `Value` enum (`Str`/`Int`/`Bool`) that cannot express
nesting. Types that travel other transports (live-share line protocol, port-lease ASCII, k8s
resource reads, on-disk journal) are enumerated in the test header as deliberately out of scope.

**Verification.** Test-based by design (the ticket asked for a test, cheaper than a runtime
check). Full suite green.

## PROTO-6 — duplicated guest plumbing

Done last, as directed, after everything else was green. See the summary appended below after the
refactor's own verification; the deliverable was the three primitives (preamble line reader,
bounded best-effort reply sender, connection-count guard) extracted and used everywhere, with
behavior preserved and each caller's exact limits/timeouts kept.

## PROTO-7 — dockerd's minimum API version blocks older clients (guest lane addition)

**Defect (upstream default, not Morbstack behaviour — worth stating plainly):** stock moby 29
defaults its minimum accepted API version to 1.44 and answers older probes with HTTP 400.
`testcontainers-java` ≤ 1.20.x (docker-java ≤ 3.4.0) probes `GET /v1.32/info` during daemon
discovery, reads the 400 as "not a working daemon", and silently fails over to any other engine on
the machine — a green suite against the wrong Docker. No client-side setting rescues old versions.

**Fix.** `DOCKER_MIN_API_VERSION=1.24` set unconditionally in morbinit's dockerd environment
(`supervisor.rs`, next to `DOCKER_RAMDISK`). 1.24 is upstream's hard floor
(`MinSupportedAPIVersion`); the shipped 29.7.1 static binary was confirmed to carry both the env
var and its validation string before relying on it. Always-on rather than a config toggle,
deliberately: the failure it prevents is silent and severe, and lowering the minimum only widens
what is accepted — modern clients negotiate exactly as before.

**Verification — empirical, on the live socket after `mise run dev`:**

| probe | before | after |
| --- | --- | --- |
| `GET /v1.32/info` | 400 | **200** |
| `GET /v1.24/info` | (untested) | **200** |
| `GET /v1.44/info` | 200 | **200** |
| `GET /v1.23/info` | — | **400** (below upstream's floor, correctly refused) |

`docker version` now reports `API version: 1.55 (minimum version 1.24)` — negotiation for modern
clients unchanged. A regression test pins the env pair on the dockerd `ServiceSpec` for both
storage layouts. Recorded as a competitive win in `docs/COMPETITIVE-GAPS.md`: Docker Desktop is
only insulated because it still ships engine 27.

---

## Found along the way, not on any ticket

- **`Daemon.shutdown` never stopped the Kubernetes API forward listener** nor invalidated its
  scheduled reconciliation timers (fixed inside the CONC-4 block; a timer could otherwise
  re-publish 127.0.0.1:6443 between teardown and `exit`).
- **`probeGuestControlOnce`'s four additive `info` recordings had the CONC-2 defect** one level
  below where the audit looked (fixed as part of CONC-2, layer 3).
- **The host live-share transport would have discarded PROTO-3's busy signal** as a generic
  protocol violation (fixed alongside PROTO-3, host side).
- **A start can begin while a stop is in flight** (`startOnQueue` gates only on
  `virtualMachine == nil`, not on `stopInFlight`), which is what turned CONC-3's nil-check into a
  wrong-VM hazard. The identity-keyed observer removes the worst consequence, but stop/start
  mutual exclusion as such remains unaddressed and is worth its own ticket.
- **`suspendOnQueue` is likewise not excluded against an in-flight clean stop**; a suspend racing
  a stop parked in `whenGuestPowersOff` ends with the state flapping `.suspended` → `.stopped`.
  Harmless today (the saved blob still restores), but the same missing-exclusion family.
