# SP-5 decision — fate of the inert subsystems

**Status:** decision record, executed 2026-08-03. Closes SP-5 and MOD-1.
Every verdict below was judged against the evidence available today (Apple's
`container machine`, the decided DNS mechanism in
[`DNS-DECISION.md`](DNS-DECISION.md), and the file-event research summarized
under "Share sync" below), not against each subsystem's original intent.

2,603 LOC shipped inside the binary with zero callers anywhere, including
tests. The standing product rule is "all functional, no coming soon"; dead code
that ships is a worse violation than a stub screen, because a stub is honest
while this read as working features to anyone browsing the source. Every
deleted design is recoverable from git history at the commits named per
section.

| Subsystem | LOC | Verdict |
| --- | --- | --- |
| `MorbShareSyncProtocol.swift` | 1,002 | **Deleted.** Second, unreachable, content-less notification protocol duplicating the shipped live-share transport. The Mutagen-style sync answer is real — build it on `MorbLiveShareTransport` instead (follow-on DIF-1a). |
| `MachineRegistry.swift` | 1,020 | **Deleted.** ~80%+ pure validation, no VM/runtime contact; abandoned mid-design. `docs/machines.md` remains the spec. |
| `MachineImageAdmission.swift` | 581 | **Deleted.** `assess()` structurally cannot succeed — its result enum has no admitted case. |
| `LocalDomainClaimReconciler` (+ loopback claim model in `MorbLocalDomain.swift`, + `PortForwarder.localDomainForwardSnapshot`) | ~250 | **Deleted.** It encoded the host-loopback-router design SP-2/SP-3 rejected. `MorbLocalDomain.Name` kept (with new tests) — the decided DIF-4 design consumes it. |
| `TarLite.swift` | 63 | **Finished.** Wired into `morb migrate volumes`: each copied volume's report and CLI table now carry the exported archive's regular-file count. Tests added. |

Net: **2,854 LOC of unreachable code deleted; 63 LOC wired; ~170 LOC of tests
added.**

---

## 1. `MorbShareSyncProtocol.swift` — deleted, but the problem it gestured at is real

**What it was for.** A "fail-closed share sync protocol foundation"
(`aef003a`): an authenticated binary envelope (`MSYN` magic, HMAC-SHA256
frames) with a `disabled → denied → requiresAuthenticatedTransport →
awaitingReady → active → closed` host-session state machine, intended as
groundwork for two-way host/guest file sync.

**What it actually contained.** Essentially 100% envelope, validation, and
state-machine plumbing; zero mechanism:

- **No file content, by design.** `Record` carried a header only; its own doc
  comment said the content format "belongs beside the guest durable journal,
  not here" — and no such journal exists anywhere in `guest/`.
- **Unreachable by construction.** `VerifiedTransport` (the authority every
  post-handshake method required) was `internal` with no public initializer
  and no key exchange; no production code could ever construct one. There was
  no socket/vsock code in the file at all.
- **A duplicate.** Its hello/ready/record/ack/close lifecycle re-specified, in
  an incompatible binary format, what the *shipped and wired*
  `MorbLiveShareTransport` (host, `Daemon.swift:198`) +
  `guest/morbinit/src/live_share_receiver.rs` already do over vsock 2381 with
  a working HMAC handshake — even its `RecordHeader` fields were documented as
  "intentionally match guest `live_share::RecordHeader`".

**Why the new evidence does not save it.** Today's research strengthened the
case *for a sync engine* and *against this file*:

- Native virtiofs has no inotify passthrough (the 2021 RFC, LWN 874000, never
  merged); nobody gets host→guest file events for free.
- Morbstack's hot-reload bridge is a same-mode `fchmod(2)` in the guest
  (`sys.rs` `nudge_metadata`) emitting `IN_ATTRIB` only. `fsnotify` (Go) and
  `notify-rs` treat Chmod as a distinct op; Go's `air` filters it out —
  colima/colima#1244 is this exact silent-failure precedent in production.
- Docker Desktop's answer (Mutagen "Synchronized File Shares") is a synced
  copy on a real guest filesystem, so the guest watches real local files.

A sync engine that fixes the `air` case must move **file bytes** into a
**real guest filesystem**. `MorbShareSyncProtocol` structurally excluded file
content, had no transport, and the guest receiver it would pair with is
deliberately read-only (`O_RDONLY | O_NOFOLLOW`, metadata nudges only).
Finishing it would mean first building the auth/transport layer
`MorbLiveShareTransport` already has, then breaking the protocol to add the
content field it was designed not to carry. It was never a foundation for the
industry's answer; it was a second copy of the notification channel we already
ship.

**Follow-on (DIF-1a in `TASKS.md`).** Build synchronized shares as an
extension of the proven live-share session: content-bearing messages on the
existing authenticated vsock protocol, a guest writer with atomic
rename+fsync semantics into a real guest-local directory, per-share opt-in,
and an acceptance test whose watcher is a Go tool using `air` — the
adversarial case the `IN_ATTRIB` bridge cannot serve. This requires guest
image changes and a live engine lane; it was out of scope for SP-5 to
half-ship.

**Recover from git:** `aef003a` (and `dde8cb5`, `566d559` context).

## 2. `MachineRegistry.swift` + `MachineImageAdmission.swift` — deleted

**What they were for.** M0/M0.1 of the Linux-machines design (DIF-13,
`docs/machines.md`): a validated machine/image inventory model and an
image-acquisition admission policy.

**What they actually contained.** 1,601 LOC that never touch
Virtualization.framework, `VMManager`, the filesystem, or the network. 80%+ is
error taxonomy, fail-closed validation, and strict-key JSON shape checking.
`MachineRegistry`'s only runtime answer is hardcoded unavailable
(`MachineRuntimeAvailability.isAvailable = false`). `MachineImageAdmission
.assess()` has **no success path**: its result enum has only `.rejected` and
`.unavailable` cases — "no ready/attachable case by design" — and the best
possible input returns `.unavailable(..., reason:
.acquisitionAndVerificationNotImplemented)`.

That absence is *evidence about maturity*, not a bug: the design was stopped
before anyone decided what success even looks like, so there was nothing
half-working to preserve. Everything hard about machines (VM supervisor,
image acquisition/verification, rootfs/boot, guest agent, SSH relay, UI) was
0% started; these files were the easiest 5–10% of the feature.

**Judged against today.** Apple shipped `container machine` in 2026 — a
persistent VM with the home directory mounted, "the closest thing to WSL on
macOS", with Kubernetes and a WSL competitor reportedly on Apple's roadmap.
[`docs/COMPETITIVE-GAPS.md`](../COMPETITIVE-GAPS.md) already rules: "Compete
there deliberately or not at all; do not drift into it." Keeping 1,601 LOC of
unreachable scaffolding is exactly the drift. The valuable artifact is
`docs/machines.md` (kept, status corrected to "planned architecture only");
if DIF-13 is ever staffed, the code would be rewritten alongside real
Virtualization work anyway, since none of it was ever exercised.

**Recover from git:** `3157c39` (admission) and its ancestry (registry).

## 3. `LocalDomainClaimReconciler` and the loopback claim model — deleted; `Name` kept and tested

**What it was for.** DIF-4 container domains, in the era when the candidate
mechanism was a host-side HTTP router: a pure reconciler validating a
`*.morb.local` claim against a fresh running-container list and an atomic
`PortForwarder` loopback TCP snapshot.

**Judged against the mechanism that won.**
[`DNS-DECISION.md`](DNS-DECISION.md) (SP-2/SP-3, verified on macOS 26.4)
decided: unprivileged mDNS proxy `A` records under `.local`, pointed at the
guest VM's `192.168.64.x`, with a **guest-side** Host-header reverse proxy
owning 80/443 inside the VM. Every fact the reconciler proved is about the
losing model — host loopback targets, host port ownership, `127.0.0.1:port`
routing. None of it transfers: the winning design has no host router, no
per-claim host port, and its withdrawal lifecycle keys on Docker events and
mDNS record ownership, not forwarder snapshots.

Deleted accordingly: `LocalDomainClaimReconciler`, `MorbLocalDomain.Claim`,
`.Registry`, `.LoopbackTCPForward`, `.LoopbackTCPForwardSnapshot`, and the
dead `PortForwarder.localDomainForwardSnapshot` producer (coordinated with the
session lead; its removal also retired the now-dangling DocC reference).

**Kept:** `MorbLocalDomain.suffix` and `MorbLocalDomain.Name` — exact,
reject-don't-normalize hostname validation below `morb.local`. DIF-4 step 2
explicitly consumes it for `A`-record name derivation, and it now has unit
tests (`MorbLocalDomainNameTests`) so it is exercised code with a named,
decided consumer rather than dead weight.

**Recover from git:** any commit before this change (file history of
`mac/Sources/MorbstackKit/MorbLocalDomain.swift`).

## 4. `TarLite.swift` — finished and wired

**What it was for.** Its own header says it: counting regular files in a tar
already on disk "for the 'file counts' `morb migrate volumes` reports" — but
the report path never called it.

**Duplication check (the Codex import/export path).** Verified none: the
native image archive import/export features (`ImageArchiveImport.swift`,
`ImageArchiveExport.swift`, `VolumeArchiveExport.swift` in `MorbFeatures`)
deliberately treat Docker as authoritative for the tar stream (`POST
/images/load`, archive endpoints) and never parse tar headers. TarLite's
ustar walk is the only one in the repo.

**What was wired.** `VolumeMigrationTransaction` now counts the exported
volume archive after a complete export: `VolumeMigrationItemReport` gains an
optional `archiveFileCount` (nil for pre-existing reports and for transfers
that failed before export; the field is a progress fact, not verification),
and the `morb migrate volumes` report table gains a FILES column. ustar
parsing is pinned by `TarLiteTests` (directories/symlinks/hardlinks excluded,
historical NUL typeflag counted, garbage input degrades to 0 without
throwing).

---

## Ticket effects

- **SP-5 / MOD-1:** done — this document.
- **DIF-4:** unchanged mechanism; step 2 now references `MorbLocalDomain.Name`
  only (the reconciler is gone).
- **DIF-6, DIF-13:** unblocked from SP-5. DIF-13 is spec-only
  (`docs/machines.md`); entering it is a deliberate competitive decision.
- **DIF-1a (new):** synchronized shares on the live-share transport — the
  honest successor to what `MorbShareSyncProtocol` pretended to be, and the
  durable fix for the `air`-class watcher gap tracked by EN-7.
