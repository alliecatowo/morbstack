# Architecture audit — 2026-08-04

Every prior audit in `docs/audit/` asked *what is broken*. This one asks a different question:
**is this the right structure, and will it hold?** Companion: [TECHNOLOGY-AUDIT.md](TECHNOLOGY-AUDIT.md)
asks whether the platform bets are sound. This asks whether the code that sits on them is.

**Coverage, stated first.** Four parallel readings were commissioned: the host↔guest protocol
contract, concurrency and ownership, the module graph and change-scaling, and failure modes /
fail-open analysis. **Three delivered. The fourth — failure modes — was killed by a model-side
safety classifier**, the same one that has now refused OPS-8 four times. So *this document does not
cover fail-open analysis*, which is precisely the class that produced this project's worst defect
(a proxy that inspected only the first request per connection). Treat that as unreviewed.

---

## Verdict

The structure is better than its history suggests. This is not AI slop: the module graph is acyclic,
there are no duplicate implementations of the same thing across 186 Swift files, comments explain
*why* rather than restating the code, and the concurrency discipline is genuinely above average —
mutable state is behind a lock or a documented serial queue, generation counters consistently discard
stale async work, and several classes narrate the exact invariant they protect.

What is wrong is narrow and specific rather than systemic, and it clusters in three places: an
undifferentiated `MorbstackKit` that has become a dumping ground, a protocol family with eight
hand-rolled framings and no coherent versioning story, and a set of races that a test cannot catch
and therefore nobody caught.

---

## 1. `MorbstackKit` is a dumping ground with a clean seam hiding inside it

53 files, 29,390 LOC. Grepping every major type against every downstream target produces a sharp
bimodal split:

- **Consumed only by `morbstackd`** (~20 files): `VMManager.swift` (2,120), `PortForwarder.swift`
  (2,641), `Daemon.swift` (1,325), `DockerProxy.swift`, `K8s*.swift`, `Rosetta.swift`,
  `DirectoryShares.swift`, `RegistryImageDiscovery.swift`, `MorbLiveShare*`, `MorbDiskGrowth/Resize`,
  `CliPlugins`, `BackgroundService`, `Entitlement`, `MorbLocalDomain`.
- **Genuinely shared client surface**: `IPC`, `MorbConfig`, `Paths`, `Version`, `Doctor`,
  `MorbDiagnostics`, `MorbSetupVerification`, `MorbDockerContext`.

**The daemon/client boundary already exists in practice and is respected by every consumer** — `morb`,
the app, and the feature modules all talk to the daemon over IPC rather than linking its guts. It is
simply not expressed as a module boundary, so there is no natural home for new daemon-only code and it
keeps landing in the shared library.

Proposed, and cheap because the boundary already holds:

```
MorbstackProtocol   (no deps)  — IPC, MorbConfig, Paths, Version, MorbDockerContext,
                                 Doctor, MorbDiagnostics, MorbSetupVerification
        ↑                    ↑
MorbstackDaemonCore    MorbFeatures / MorbMCP / MorbMigrate / MorbBench / MorbScan / MorbExport
(VMManager, PortForwarder,     (already correctly isolated from AppCore)
 Daemon, DockerProxy, K8s*, …)
        ↑
   morbstackd  (only consumer)
```

~30 file moves plus one `import` line each. **Zero logic changes.** Filed as MOD-2.

## 2. Two hand-maintained Docker model sets that will drift

`MorbstackAppCore/DockerClient.swift` (1,846 LOC) with typed models in `Models.swift` (1,450 LOC),
versus `MorbFeatures/EngineClient.swift` (651 LOC) returning raw `[String: Any]`. Chunked-transfer
decoding *is* shared (`MorbstackKit/HTTP.swift`), so the wire layer is singular — but the Docker JSON
shapes are maintained twice, and `morb` deliberately never links `AppCore`.

This is a real architectural fork, not an oversight, so collapsing it is expensive: either the GUI
loses its type safety or the CLI targets take a dependency the package deliberately avoids. **Decide
and document the fork, or pay to unify it — but stop letting it drift silently.** Filed as MOD-3.

Related naming trap: `MorbstackKit/DockerAPI.swift` is **not** a REST client despite the name. It is
port/host-address modelling consumed by the proxy and forwarder. `MorbLive/RawEngine.swift` *is* a
third client, but a sanctioned one — deliberately dumb, existing to verify `DockerClient`
independently.

## 3. The protocol family: eight framings, no versioning story

Seven live vsock ports plus one defined outside the registry. Each protocol's *wire shape* is
legitimately different — HTTP relay, line+splice, line+framed-datagram, line+bulk-body,
HMAC-authenticated line protocol. **The plumbing underneath them is not.** Byte-at-a-time line
reading is reimplemented three times; `err_line`, `negotiate`, `DeadlineStream`/`ConnGuard`,
`send_busy` and the accept-loop skeleton are each duplicated two to five times. That
`live_share_receiver.rs` already calls `dial::read_preamble_line` proves the primitive is reusable —
it was extracted once and then not used anywhere else. (PROTO-6.)

**Versioning is the sharper problem.** `morbinit_version` is the field `docs/protocol.md` nominates as
*the* compatibility probe. It is decoded into `GuestReply` and **referenced nowhere else** but two
test assertions — never compared, never branched on, never surfaced. There is no code path anywhere
that says "if the guest is older than X, do Y". (PROTO-1.)

What exists instead is three *independent* ad-hoc mechanisms: MRB0's optional-field convention (`nil`
means old guest, documented per field — the one place skew is handled with real discipline), 2379's
bespoke additive-field `TRACE` suffix, and 2381's `share_event_bridge` capability gate. Each invented
separately. The system relies on a convention holding across every future patch, which is exactly the
kind of rule that erodes silently.

**It has already eroded once.** Port 2380 (the listener probe) was deleted in `51dc543` along with its
host side, and `docs/protocol.md` was correctly scrubbed — but `architecture.md`, `MASTER-PLAN.md`,
`ENGINE-MATRIX.md` and `TASKS.md` all still described it as live, **including the OPS-8 security-review
scope**, which would have sent a reviewer at a port that does not exist.

Also inconsistent: 2376 and 2378 emit `ERR busy\n` at their connection cap — a deliberate hardening
pass their own comments describe as fixing exactly this. 1024, 2375 and 2381 still silently drop, which
is indistinguishable from a peer that never spoke the protocol. The fix was applied once and not
propagated. (PROTO-3.)

And `jsonlite` rejects **any** nesting, poisoning the entire frame — while every host MRB0 struct goes
through Foundation's fully general `JSONEncoder` with no check. One nested field would compile, pass
Swift round-trip tests, and fail 100% of that message type at runtime with a generic "invalid JSON".
(PROTO-5.)

## 4. Concurrency: disciplined, with four specific breaks

The pattern is genuinely good. `TCPListener.stop()` blocks on a `closedSignal` specifically to avoid
the classic descriptor-reuse race, and says so. `UDPListener` holds its lock *across* the `recvfrom`
syscall, which is stronger. `PortForwarder` keys `connectionCounts` per-generation so a stale relay
completion cannot corrupt a new generation's count. `CompletionOnce` guards against a dropped
completion becoming a hung caller.

The breaks are narrow — see CONC-1…CONC-5 in `TASKS.md`. The instructive one is **CONC-1**, a
guaranteed fd double-close: `Session.deinit` closed `fd` unconditionally while the caller's `catch`
closed it explicitly, so every handshake failure closed one descriptor twice, and between the two
closes that number could already belong to an unrelated connection. Not probabilistic. Found by
reading, invisible to every test.

**The general lesson:** `VMManager`'s queue-confined state (`virtualMachine`, `controlReady`,
`runWaiters`, `stopWaiters`, …) has **no lock at all** — correctness rests entirely on every call site
remembering to hop onto the queue first. Comments say "Queue-confined". Nothing enforces it. That is
the single largest concurrency risk in the codebase and it is a design choice, not a bug.

## 5. What will not scale — change, not performance

- **Adding one MRB0 field touches 6–9 files across 3 modules.** The wire protocol is hand-duplicated
  on both sides with no codegen, and MRB0's per-field nil-semantics documentation convention adds real
  overhead per field. Shotgun surgery by construction. (MOD-5.)
- **26 documents carry per-feature status claims**, `docs/` holds ~70 markdown files, `docs/design/pass2/`
  duplicates five filenames from its parent, and three same-dated handoff/audit docs were added in one
  day. This is accelerating, and it is why SP-7 (one generated status doc) exists.
- **The `#[cfg(target_os = "linux")]` gates are better than feared.** 82 gates across 18 of 21 files,
  but they are overwhelmingly single-line and function-body-level, not whole-module stubs — `disk.rs:163`
  gates one `sync()` call inside an otherwise portable function. `jsonlite.rs`, `sha256.rs` and
  `live_share.rs` (1,499 LOC) are entirely gate-free. This is a well-factored crate; the danger was
  never the gates but that nothing *checked* the gated target, which `mise run check` now does.

---

## What is architecturally right, and should be protected

A refactor that damages any of these makes the system worse:

- **Fail-closed guards as a habit.** The bind-mount preflight, the disk-grow journal, the
  runtime-artifact verification, and now the userland proxy all refuse rather than guess. The one place
  that failed *open* produced the worst defect in the project's history.
- **`morb` delegating six subsystems to their own modules** with an explicit comment explaining that
  the alternative "is how a CLI ends up with five subtly different ideas of what `--force` means".
- **Asset provenance.** Every third-party binary SHA-256 pinned, several doubly.
- **Comments that explain why.** `mise-tasks/*` teaches which bug each line prevents; `sys.rs` explains
  why `reboot` is declared with one argument and what happens if you get it wrong.
- **`MorbLive/RawEngine.swift`** — deliberate, documented duplication whose whole purpose is
  independent verification. Do not "deduplicate" it.
- **The MRB0 optional-field convention.** It is the only working version-skew mechanism in the system.
  Extend it; do not replace it with something cleverer.

## Ranked by cost-if-ignored

| # | Finding | Ticket |
| --- | --- | --- |
| 1 | Fail-open analysis was never done — the reviewer was blocked | OPS-8 |
| 2 | `morbinit_version` parsed and never consulted; no version gate exists | PROTO-1 |
| 3 | `VMManager` queue-confinement enforced only by convention | — (new) |
| 4 | Two hand-maintained Docker model sets, drifting | MOD-3 |
| 5 | `MorbstackKit` has no daemon/client boundary | MOD-2 |
| 6 | Guest plumbing duplicated 2–5× across protocols | PROTO-6 |
| 7 | Backpressure semantics inconsistent across protocols | PROTO-3 |
| 8 | jsonlite flatness enforced only by convention | PROTO-5 |
| 9 | Status-doc proliferation, accelerating | SP-7 |
