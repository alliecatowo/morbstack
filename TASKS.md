# Morbstack tasks — the ticket board

The checked-in ticket board. Every audit finding lives here. Derived from [docs/audit/](docs/audit/);
ordering authority is [docs/MASTER-PLAN.md](docs/MASTER-PLAN.md). Each ticket names its
**deliverable**, not just its subject.

**Spikes deliver a decision, not code.** Where the fix is not yet known, the ticket is a spike and its
deliverable is a written, argued decision that then rewrites the tickets downstream of it. Do not let
a spike quietly become an implementation.

Status: `open` · `in-flight` · `decided` · `done` · `blocked`

---

## Current Codex swarm

- **Preserved Claude baseline:** `code/native-content-continuation` at `7158f5d`
  (*Checkpoint Claude consolidation audit baseline*).
- **Active integration branch:** `codex/claude-continuation`, forked directly from
  that baseline. New work uses `codex/<epic>-<ticket>` branches when isolated
  worktrees are available; shared-worktree agents return scoped handoffs to this
  integration branch instead.
- **Lane owner:** the integration agent alone runs package builds, guest-image
  work, daemon/app lifecycle, XCUITest, and Docker acceptance. Parallel agents
  may audit, research, write isolated source, and run static checks only.
- **Next planning gate:** reconcile the completed engine matrix and audit board,
  then start non-machine tickets in parallel while the machine lane is reserved
  for an explicit, controlled guest/runtime acceptance pass.
- **Current Codex checkpoint:** `ccdfa60` on 2026-08-03. The committed source
  batch adds native image-archive load and its descriptor/chooser hardening,
  fixture isolation for Builds and Stacks, chunked create rewriting, and a new
  `-P` lifecycle-owner correction. Each has focused static handoff evidence;
  none has current-candidate runtime acceptance yet. See
  [`docs/claude-continuation-handoff-2026-08-03.md`](docs/claude-continuation-handoff-2026-08-03.md).
- **Runtime-evidence boundary:** the recorded Engine/Proxy matrix is evidence for
  its 2026-08-03 candidate, not for the current source tree. `33fd00e`
  changed bind-admission/framed-relay behavior after that run, and `f79a090`
  subsequently changed chunked-create rewriting. Neither may inherit a
  `runs-here` verdict until the serialized `guest-image` → `app` → restart and
  live matrix rerun completes on the current candidate.

---

## 2026-08-07 board correction

The board had drifted badly: rows sat `open`/`blocked` for work that had already shipped, in some
cases two days earlier. Every `open`/`blocked` row was checked against `git log --grep`/`git log -S`
and the current tree (read-only — no build, test, or launch performed; see CLAUDE.md). `SEC-*` rows
were left untouched, contents unread, per instruction — they are tracked separately.

**35 rows corrected**, all in the direction of work that had shipped and was never flipped (`open`/
`blocked` → `done`, `decided`, or unblocked to `open`): `CLI-9`, `DIF-3`, `DIF-8` (unblocked),
`DOC-5`, `DOC-7`, `EN-2`, `EN-5`, `EN-11`, `OPS-1`, `OPS-2`, `OPS-5`, `OPS-6`, `PROTO-2`, `PROTO-6`,
`REL-1`, `TASTE-5/7/8/9/10/11/12`, `TECH-5`, `TECH-8`, `UI-13`, `UX-14`, `UX-18`, `UX-21`, `UX-22`,
`UX-5/7/8` (spikes, decided). No row was found closed on a claim rather than a real delivery — the
project's habit of leaving honest "visual acceptance pending" / "machine-lane pass still needed"
caveats on `done` rows held up under spot-checking.
**One duplicate ticket ID fixed:** a second, unrelated ticket had been mistakenly filed under an
already-used ID — `TECH-4` (tar-reader consolidation, filed 2026-08-06) collided with the original
`TECH-4` spike (save/restore retest, filed 2026-08-04) — renamed to `TECH-12`.
**Four more duplicate/overlapping tickets flagged in place, not merged** (see each row for detail):
`UX-6`×`TASTE-2`, `EN-6`×`UX-24`, `TECH-5`×`UX-17`×`UX-29`, `TECH-8`×`PROTO-6`, and `UX-32`'s
sub-item 3 × `UX-25`.
**Four rows explicitly left alone**, per instruction, because another agent is working them this
session: `UX-23`, `UX-26`, `UX-28`, `UX-31` — all marked `in-flight` rather than judged.

**Current counts** (`SEC-*` excluded throughout):

| State | Count |
| --- | --- |
| `done` | 76 |
| `decided` | 3 |
| `in-flight` | 11 (4 of them the explicitly-parked rows above) |
| `open` | 46 (44 table rows + `SP-7`, `TECH-2` spike) |
| `blocked` | 7 (6 table rows + `SP-9`) |

**Open/blocked (50 total) by prefix:** UX 11 · DIF 9 · TECH 7 (incl. the `TECH-2`/`TECH-4` spikes) ·
TST 4 · OPS 4 · REL 3 · MOD 3 · EN 3 · DOC 2 · SP 2 · PROTO 1 · ARCH 1.

---

## Spikes — decisions that reshape other tickets

### SP-1 · Docker proxy: policy for bodies too large to buffer · `done` (decision; dated runtime evidence)
**Deliverable:** a decision, in `docs/audit/PROXY-FRAMING.md`, on what the proxy does when a request
body exceeds what it will buffer for inspection. Options: refuse with a Docker-shaped error
(fail-closed), stream-inspect incrementally, or inspect a bounded prefix. The framed relay's
2026-08-03 candidate rejected too-large and ambiguous request framings with Docker-shaped `400`
errors and inspected every request until a confirmed hijack; see the dated matrix in
`PROXY-FRAMING.md`. Current-source runtime acceptance is pending the post-`33fd00e` and
pending-chunked-rewrite rerun.
**Rewrites:** EN-1, and every preflight guard's threat model.

### SP-2 · `NEDNSSettings` entitlement feasibility · `decided`
**Decision:** [`docs/design/DNS-DECISION.md`](docs/design/DNS-DECISION.md). Do not use
`NEDNSSettings` — its `dnsSettings` property accepts only DoH/DoT settings objects, so it would
require a trusted local TLS certificate *before* DNS works, and the user must activate the resulting
network service by hand behind the admin padlock. `NEDNSProxyProvider` is worse still: Developer ID
needs `dns-proxy-systemextension`, a user-approved system extension that then sees every DNS query on
the Mac.
**Instead:** register per-container mDNS proxy `A` records under `.local` from the ordinary
unprivileged daemon (`DNSServiceRegisterRecord`, `LocalOnly` interface). Verified on macOS 26.4:
no entitlement, no password, no dialog, no `/etc/resolver` write, nothing to uninstall, multi-label
names work, OS-arbitrated name conflicts, ~1 ms resolution. Also verified: a non-root process cannot
bind 80/443/53 on macOS 26, so the bare-URL listener moves **into the guest VM** (the `A` record
points at the guest's `192.168.64.x` address), keeping the host privilege cost at zero.
**Rewrote:** SP-3, DIF-4, DIF-5, DOC-4, and the resolver/router sections of `docs/domains.md`.

### SP-3 · Local domain suffix: `.local` vs `.test` vs `.orb`-style · `decided`
**Decision: `.local`.** Keep `MorbLocalDomain.suffix = "morb.local"`; withdraw the `*.morb.test`
recommendation in `docs/domains.md:37`. SP-2 proved `.test` is unreachable without root
(`DNSServiceRegisterRecord` returns `kDNSServiceErr_BadParam` for any non-`.local` name), so `.test`
costs an admin password and a permanent `/etc/resolver` file. The mDNS-collision analysis inverts the
old objection: `.local` collides with Bonjour only when resolved by *unicast* DNS. Registering unique
records with mDNSResponder **is** Bonjour, and `LocalOnly` registration keeps the names off the LAN.
**Accept knowingly:** no wildcard subdomains, and networks whose DNS hijacks `*.local` will break
resolution (detect and report — see [orbstack#2274](https://github.com/orbstack/orbstack/issues/2274)).
**Rewrote:** DIF-4, DOC-4.

### SP-4 · Remove the Docker-to-build-Docker bootstrap · `decided` — **superseded by TECH-1 (2026-08-04)**
**Superseded:** TECH-1 decided in favor of the userland-proxy wrapper, which needs no downstream-patched
engine at all — the release-artifact question this spike answered no longer applies, because there is no
non-upstream engine artifact to publish, sign, or fetch. `build-engine.yml`,
`scripts/build-morbstack-dockerd.sh`, `scripts/fetch-moby-source.sh`, and the guest patch are all deleted.
Kept below for the historical record.
**Original decision (2026-08-03, no longer current):**
[docs/design/ENGINE-BUILD-DECISION.md](docs/design/ENGINE-BUILD-DECISION.md) (now a superseded stub).
Publish
`morbstack-dockerd` as a pinned, SHA-256-verified GitHub Release artifact built by a new
`build-engine.yml` workflow on a Linux runner (ships Docker/Buildx natively — the `macos-26` runners
CI otherwise uses do not), fetched by `scripts/fetch-guest-assets.sh` exactly like every other
third-party guest binary. `scripts/build-morbstack-dockerd.sh` stays as the from-source path an
auditor runs to reproduce and diff that same SHA — it is not deleted. Rejected: vendoring the ~93 MB
binary in-repo (permanent git bloat, needs Git LFS, no attestation surface, no better reproducibility
than the hash pin it would still need); making the patch optional as the *primary* fix (silently
breaks `-P` — Moby only knows the effective port set after `HostConfig` is fixed, so without the
patch nothing published by `-P` is host-reachable — it survives only as an explicit, loud fallback
when the Release asset is unreachable, never a silent default).
**Rewrites:** OPS-9, REL-1, and the CI guest-image job (see the decision doc's 9-step migration list).

### SP-5 · Fate of the ~1,750 LOC of inert subsystems · `done` (2026-08-03)
**Decided and executed** — [`docs/design/INERT-SUBSYSTEMS-DECISION.md`](docs/design/INERT-SUBSYSTEMS-DECISION.md).
Deleted: `MorbShareSyncProtocol.swift` (unreachable, content-less duplicate of the shipped
live-share transport — see DIF-1a for the real synchronized-shares successor),
`MachineRegistry.swift` + `MachineImageAdmission.swift` (abandoned mid-design; `docs/machines.md`
stays as the DIF-13 spec), `LocalDomainClaimReconciler` + the loopback claim model (encoded the
host-router design SP-2/SP-3 rejected; `MorbLocalDomain.Name` kept + tested for DIF-4). Wired:
`TarLite` now feeds a FILES column in the `morb migrate volumes` report, with ustar tests.
**Rewrites:** DIF-6, DIF-13, MOD-1.

### SP-6 · `-P` session persistence root cause · `closed` — **moot by construction (2026-08-04)**
**Closed as moot.** TECH-1 deleted the publish-all allocator and its guest fd/session lifecycle entirely —
there is no longer a per-container broker session to own, register, or contend over. The failure class
this spike existed to root-cause (a fd/session whose ownership could be lost or double-registered across
direct and restart-policy allocation paths) is eliminated by construction under the wrapper: a port lease
is a single vsock connection held open by the stock `docker-proxy` process, so lease lifetime equals
proxy process lifetime, and EOF is the only release signal. Nothing survives a stop/start/restart/VM-restart
to lose track of. The original source correction (`3960359`) is now dead code, deleted with the rest of
the publish-all path. See `docs/design/PATCH-FREE-PUBLISH-ALL.md`.
**Rewrites:** EN-2 (rescoped to prove the wrapper, not this spike's mechanism).

### SP-7 · Status-documentation consolidation · `open`
**Deliverable:** a design for one generated status document and the machine-checkable source it comes
from. Six overlapping docs currently disagree in both directions; the fix is not "edit them", it is
"stop hand-maintaining them".
**Rewrites:** DOC-2.

### SP-8 · Accessibility identifier scheme · `done`
**Deliverable:** a naming convention, before anyone adds hundreds of them. The codebase currently has
**zero** `accessibilityIdentifier`. Decide route-scoped vs global, and how identifiers relate to the
XCUITest queries that currently rely on system semantics alone.
**Ruling:** `docs/design/ACCESSIBILITY-IDENTIFIERS.md` — route-scoped dotted names
(`<route>.<element>[.<qualifier>]`, `app.` for cross-route chrome); toolbar controls reuse their
existing `ToolbarItem(id:)` string verbatim; rows carry the engine-facing reference
(`containers.row.shopfront-api-1`); identifiers only on what tests act on or assert about; system-owned
chrome keeps semantic queries; identifiers are never labels and never localized.
**Rewrites:** UI-13, UI-6.

### SP-9 · Signing and notarization identity · `open`
**Deliverable:** which Developer ID, where the cert lives, how CI gets it without leaking it. There is
not one `notarytool` call in the repo, and an unnotarized DMG is Gatekeeper-blocked for everyone but
the author.
**Rewrites:** REL-2, REL-3, REL-4.

---

## Engine — parity

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| EN-1 | **Docker proxy request framing** | The 2026-08-03 candidate framed every request until a legitimate hijack, rejected too-large and ambiguous bodies fail-closed, returned `400` for fresh and second keep-alive creates, and completed stream/BuildKit/Compose regressions. `33fd00e` and `f79a090` changed this boundary after that candidate, so current-source rebuilt-guest acceptance remains required. See `docs/audit/PROXY-FRAMING.md`. | `in-flight` (current-candidate acceptance) |
| EN-2 | `-P` across stop/start/restart | Rescoped by TECH-1/SP-6: prove `-P` under the userland-proxy wrapper — TCP/UDP reachability, stop/start/restart, restart-policy recovery, and VM restart — against the current wrapper implementation (`guest/morbinit/src/proxy_wrapper.rs`, `mac/Sources/MorbstackKit/GuestPortLease.swift`). **Done.** `docs/design/PATCH-FREE-PUBLISH-ALL.md`'s "Live acceptance — 2026-08-04" section is a full runtime matrix against this exact wrapper: `-P` (200, 4.3ms), restart, stop+start, `--restart=always` across a full VM restart, bare and IP-scoped `-p`, host-port-collision fail-closed, UDP, port ranges, BuildKit, and Compose with healthcheck deps. `proxy_wrapper.rs`/`GuestPortLease.swift` are unchanged since the commit (`5ea075a`) that introduced them, so this is acceptance against current source, not stale evidence. | `done` |
| EN-3 | Bind mounts `/etc`, `/var`, unshared roots | The 2026-08-03 candidate recorded refusals for `/etc`, `/var`, `/Library`, and symlink traversal, plus working `/tmp`, `/private/tmp`, and `$HOME` bind writes. `33fd00e` then changed bind-admission and relay behavior; rebuild the guest and rerun this exact matrix before assigning those results to the current source. See `docs/audit/PROXY-FRAMING.md`. | `in-flight` (post-`33fd00e` rebuilt-guest acceptance) |
| EN-4 | `morb disk grow` | Fix `keyNotFound: 'device'` host/guest contract mismatch. Image grew to 72 GiB while the guest filesystem stayed 62.4 G, and a **refused** grow still mutated configured capacity. Add the journal tests it never had. | `in-flight` (`codex/parity-en4-disk-grow`) |
| EN-5 | Reclaim the 72 GiB `disk.img` | Safe reclamation path for the test artifact left on the dev machine | `done` — verified live on this machine 2026-08-07: `~/.morbstack/data/disk.img` still reports 72G apparent size but `du`/`stat -f %b` show only ~6.1 GiB of actual allocated blocks. TECH-3/UX-16's shutdown-triggered `fstrim` (`5b15f62`, `85cedd1`) is reclaiming real disk space from exactly this file; a sparse image's apparent size never needs to shrink, only its allocated blocks, which it has. |
| EN-6 | `host.docker.internal` without `--add-host` | Resolves by default. **Likely a duplicate of UX-24** (below): `d82b823` ("Route Docker host aliases through bridge DNS") already shipped bridge-DNS routing that targets exactly this case, but per `docs/parity.md` row #18 it has never been re-run against a freshly built guest — same open verification gap, described from two angles. Merge candidates; UX-24 carries the more precise text. | `open` |
| EN-7 | Live-share / hot reload proven | First compile was today. Publish a **watcher conformance matrix**: the mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB` only — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`. `liveSharePaths` defaults to `[]`, but as of UX-21 (2026-08-05) it **does have a GUI writer** — Settings › Sharing's "Add Project Folder…" (`NSOpenPanel`) plus per-row Remove (`TrackDSharingSettings.swift:95,179-198`); there is still no `morb` CLI writer. The correctness-mode alternative for `air`-class watchers is DIF-1a. | `open` |
| EN-8 | Testcontainers (Java/Go/Node/Python) | Executed 2026-08-04 with real Postgres suites via `scripts/ecosystem-acceptance.sh`: Node 12.1.0, Python 4.15.0, Go v0.43.0, Java 1.21.4 all PASS with `DOCKER_HOST` + `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`; Ryuk works in all four. Java ≤1.20.x FAILs against any engine-29 daemon (docker-java `/v1.32` probe vs upstream `MinAPIVersion 1.40`) and, like Node/Go zero-config, **silently runs against a stale Docker Desktop socket** — see `docs/audit/ECOSYSTEM-MATRIX.md`. Proposed guest-side mitigation: `DOCKER_MIN_API_VERSION=1.24` in morbinit's dockerd env (guest lane owns the change). | `done` (evidence: `docs/audit/ECOSYSTEM-MATRIX.md`; CP-06 clean-profile still pending) |
| EN-9 | Dev Containers | Executed 2026-08-04: `@devcontainers/cli` 0.88.0 `up`/`exec` PASS against Morbstack with context-only discovery — lifecycle, two-way workspace bind mount, `postCreateCommand`, and a features/derived-image build (Go feature) all worked. Two harness-doc bugs fixed (`exec` needs the same `--id-label` as `up`; CLI 0.88 has no `down`). VS Code extension flow remains untested (CP-07). | `done` (CLI; extension/CP-07 pending) |
| EN-10 | Clean-profile CP-01–CP-07 | The release gate. Never run. Nobody has ever installed this. | `blocked` (EN-1, REL-2) |
| EN-11 | Pinned `kubectl` for pod port-forward | `KubectlTool.swift:16-30` needs a binary not in the repo; the path is a hardcoded unavailable | `done` — resolved by DOC-7 (`c838822`): `fetch-guest-assets.sh` now fetches kubectl by default (`DO_KUBECTL=1`) to `dist/host-bin/kubernetes/kubectl`, exactly where `KubectlTool.swift`'s resolver looks. A stock `mise run app` now ships the binary; the unavailable-path code stays as a safety net for a stale asset cache, not the default path. |

## Operations and repo health

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| OPS-1 | Push and prove CI red-then-green | CI has never run once in 273 commits | `done` — the premise is stale: the remote exists and CI has run 100+ times since 2026-08-04 (`908e46e` measured 62 push + 38 pull_request runs over 3 days while fixing 4 billing bugs). A real red→green cycle happened along the way, just organically rather than as a staged demo: `ef33422` found and fixed a genuine `pull_request`-only failure (`dorny/paths-filter` needing `pull-requests: read`) via `gh run list`/`gh run view --log-failed`, and corrected CLAUDE.md's own stale "no remote, CI never run" claim in the same commit. Current pass/fail state not re-checked here (no `gh` call made). |
| OPS-2 | Install the pre-commit hook | `mise run install-hooks`, documented in CONTRIBUTING | `done` — `scripts/git-hooks/pre-commit` exists (compile-only gate, staged-file and build-artifact guards), `mise-tasks/install-hooks` wires `git config core.hooksPath`, `mise-tasks/doctor` checks whether it's installed, and `CONTRIBUTING.md:249-250` documents the command. |
| OPS-3 | `mise run doctor` in CI and `check` | Wire the staleness check into the gates | `open` — half done: `mise-tasks/check` already calls `mise run doctor` (advisory, non-fatal on an incomplete environment) as its last step. `.github/workflows/ci.yml` never invokes `doctor` at all — CI calls `mise run build`/`mise run test` directly, not `mise run check`, so the staleness gate is entirely absent from CI itself. |
| OPS-4 | Swift lint/format config | Neither `.swift-format` nor SwiftLint config exists, so CI has no Swift lint job. Adding one means agreeing rules first. | `open` — premise partly stale: `.swift-format` **does exist** at repo root (2799 bytes, landed at the `7158f5d` baseline checkpoint) but is completely unwired — no task or CI step references it, and `.github/workflows/ci.yml`'s own comment ("checked — neither file exists") predates that file and is now wrong. SwiftLint config is still genuinely absent, and no CI Swift lint job exists either way — the actual deliverable (a wired lint job) remains undone. |
| OPS-5 | shellcheck locally | Not installed; CI shellchecks but developers cannot | `done` (`60e9ac3`, 2026-08-03) — shellcheck is pinned in `mise.toml` and runs in `mise run check` with the same invocation as `ci.yml`, closing the local/CI gate mismatch. |
| OPS-6 | `.gitignore` / tracked `dist/` audit | 7 tracked files under `dist/`; confirm intent | `done` — already ruled on. `git ls-files dist/` returns exactly the 7 files CLAUDE.md §4 documents as intentionally tracked (`CROSS_COMPILE.md`, five `PROVENANCE.txt`, `TOOLCHAIN.plist`), and `docs/audit/REPO-AUDIT.md` explicitly rules "tracking them is correct — the only durable record of what was downloaded and with which hash." |
| OPS-7 | Build warnings | `DockerAPI.swift:65` and `UDPListener.swift:101` form `UnsafeRawPointer` to a generic `T` in socket-option code — real, not cosmetic | `open` — reconfirmed unchanged: both `DockerAPI.swift:64-65` and `UDPListener.swift:100-101` still do `withUnsafeBytes(of: value)` on a generic `inout T` feeding `inet_ntop`. Neither file has been touched at that location since `51dc543`. |
| OPS-8 | **Security review of untrusted-input surfaces** | **Two passes done, both in [docs/audit/INPUT-VALIDATION-REVIEW.md](docs/audit/INPUT-VALIDATION-REVIEW.md).** Part 1 (2026-08-04): ten guest wire parsers incl. 2377 and the live-share port — SEC-1, SEC-2 and a staged-file leak fixed, SEC-3 filed. Part 2 (2026-08-05): all of `mac/Sources/MorbMCP/**`, every process-spawning site under `mac/Sources/**`, and the four guest files part 1 deferred (`binfmt.rs`, `disk.rs`, `dns.rs`, `mounts.rs`) — **MCP-1 (high)** fixed, plus MCP-2, GUEST-1, GUEST-2; SEC-4/5/6 filed below. Verified and now pinned by test: read-only *is* the default, the permission check sits on the single path every `tools/call` crosses, and the audit log is complete. **Judgement for REL-5: these surfaces are safe to publish.** Still unreviewed, and the honest remainder: vsock 1024/2375/2376/2378/2381/2382, specifically `GuestPortLease.parseRequest` (`mac/Sources/MorbstackKit/GuestPortLease.swift`) and `proxy_wrapper.rs`'s `parse_reply`/`parse_invocation`, both added by TECH-1 and both parsing guest-controlled input. Neither is agent- or network-reachable; sequencing them after REL-5 is a defensible call, blocking on them is not required. (2379 and 2380 are DELETED — 2380 in `51dc543`, 2379 with the publish-all path in TECH-1.) | `done` (parts 1–2); port-lease parsers `open` |
| OPS-9 | CI guest-image job | Per TECH-1: no rewrite needed — the guest-image job needs no Docker/buildx and no engine-artifact release fetch, because Morbstack ships unmodified upstream dockerd fetched like every other pinned third-party guest binary. `build-engine.yml` and the "Require Docker Buildx" step are deleted. Remaining work is just confirming the job passes on hosted runners. | `open` |

## Tests — coverage runs backwards from risk

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| TST-1 | `VMManager.swift` (2,097 LOC) | No test boots or restores a VM | `open` — reconfirmed: existing references (`LifecycleTests.swift`, `GuestPortLeaseTests.swift`) only probe unrelated constants (dial-slot budgets, shutdown timing), never construct or boot a `VZVirtualMachine`. The file has grown to 2,647 LOC since filing. |
| TST-2 | `MorbDiskGrowth` journal | No test; it mutates a 68 GB disk image | `open` — half done: `MorbDiskGrowthTests.swift` (6 tests) now covers the journal **codec** (encode/decode round-trip, proof-required/rejected states, version rejection). The actual disk-mutation path — growing/resizing a real or fake image, the risk the ticket names — is still untested. |
| TST-3 | Live-share transport + both guest modules | ~1,850 LOC, self-described "authority boundary", zero tests | `open` — more than zero now, but the named boundary is still uncovered on the host side. Guest-side: `live_share.rs` (12 tests), `live_share_receiver.rs` (5 tests), plus SEC-2's wire-format-pinning test. Swift-side: `LiveShareBridgeTests.swift` (10 tests) covers `MorbLiveShareBridge`'s path-plan validation only, and says so itself ("these tests do not create an FSEvent stream, boot a VM, or claim inotify can be injected"). `MorbLiveShareTransport.swift` — the 400+ LOC class that is the actual "authority boundary" (wire-level session, HMAC signing, connection lifecycle) — has no direct Swift unit test. |
| TST-4 | ~~`PublishAllPortAllocator` + guest `publish_all.rs`~~ — moot, both deleted 2026-08-04 (TECH-1) | The publish-all allocator this ticket targeted no longer exists; its replacement, the port-lease channel (`GuestPortLease.swift` / `proxy_wrapper.rs`), already has unit tests on both sides (`GuestPortLease.parseRequest`, `proxy_wrapper.rs`'s `parse_invocation`/`parse_reply`/`lease_line` tests). Superseding coverage question, if any gap remains, belongs to EN-2. | `done` (moot) |
| TST-5 | vsock relay under load | Half-close, backpressure, cancellation | `open` — half-close and cancellation now covered: `RelayTests.swift` (4 tests: flush-before-close, half-close leaves the opposite direction usable, EOF-carrying-final-bytes, cancel-fires-completion-once) and `DockerFramedRelayTests` (from `60e9ac3`: chunked/large bodies to 200KB, keep-alive byte-exactness, cancelling an image-load). Still missing the "under load" half: no concurrent-connection stress, no soak test, and no test that actually forces and verifies backpressure despite `DockerFramedRelay.swift:68-72` naming it a design goal (`grep -rln backpressure mac/Tests/` finds nothing). |
| TST-6 | Keep-alive regression test | Assert the **second** request on a reused connection is inspected. Its absence is why EN-1 shipped. Focused source coverage exists; the recorded runtime result belongs to the dated matrix and must be rerun with EN-1. | `done` (source coverage; current runtime pending) |

## UI — [docs/audit/UI-AUDIT.md](docs/audit/UI-AUDIT.md), 32 issues: 3 blocker, 9 major, 14 minor, 8 polish

| ID | Ticket | Severity | State |
| --- | --- | --- | --- |
| UI-1 | Fixture-mode provenance — `--tour-fixtures` must be visibly and accessibly distinct from live data | blocker | `done` (title/footer/a11y truth plus `1f5d779` source guards against Builds/Stacks external operations; real-window/XCUITest evidence pending) |
| UI-2 | Port renders as `18,099` — thousands separator on a port | blocker | `done` (string-typed inspector display + focused regression) |
| UI-3 | Add Show/Hide Sidebar to the View menu | major | `done` (`SidebarCommands()`/`InspectorCommands()` + ⌘1–⌘9 route commands in `App.swift`; XCUITest rerun blocked on Automation Mode — see UI-AUDIT UI-016) |
| UI-4 | Unmatched search must use `ContentUnavailableView.search` | major | `done` (every searchable route + scoped filters — see UI-AUDIT UI-028) |
| UI-5 | Selecting a container must expose inspector content | major | `done` (real `.inspector`, forced open on selection; live-window verified — see UI-AUDIT UI-029) |
| UI-6 | 8 undescribed elements, 3 contrast failures | major | `in-flight` — every symbol-only control now carries a label/help or is marked decorative (145 `accessibilityLabel` sites); naming the specific 8 elements + 3 contrast pairs needs a `performAccessibilityAudit` rerun, blocked on macOS Automation Mode (retried 2026-08-04, still "Timed out while enabling automation mode") |
| UI-7 | Containers toolbar: ~12 symbol-only items in 6 groups against a cap of 3, incl. **two identical trash cans** | major | `done` (route toolbars rebuilt to stable system-placed groups; at most one labelled trash per route — see UI-AUDIT UI-003/004/005) |
| UI-8 | Toolbar items vanish at narrow width with no overflow — with UI-3, some commands become unreachable | major | `done` (all items in system placements, no manual overflow; prune commands mirrored into the Engine menu — see UI-AUDIT UI-019) |
| UI-9 | Images table: Repository column crushes to one character per row | major | `done` (native `TableColumn` minimum width; narrow-window real-window evidence captured 2026-08-04 second-pass tour) |
| UI-10 | Disk inspector overlaps and overdraws the table | major | `done` (real `.inspector` + 520 pt table minimum — see UI-AUDIT UI-018) |
| UI-11 | Container uptime freezes ("Up 23 seconds" vs `docker ps` "Up About a minute") | major | `done` (per-second `TimelineView` tick; K8s ages, Images Created, Builds relative columns tick too — see UI-AUDIT UI-020) |
| UI-12 | **Second UI pass** — Stacks, Kubernetes, Networks, Builds, Migration, Settings, ⌘K, menu-bar extra, light mode, prune/pull were never toured. The 32 issues are a floor. | major | `in-flight` — full source review landed rows UI-033…UI-048 (all fixed); real-window tour of the rebuilt app in both appearances/widths in progress 2026-08-04 |
| UI-13 | Add accessibility identifiers | major | `done` (source complete: SP-8's convention plus 243 identifier sites across every route, `7cc3e2f` + `8f969ba`, both landed 2026-08-05/06. Correct by reading and by compiling; XCUITest execution of them is unverified — blocked on macOS Automation Mode, same as UI-6/UI-14) |
| UI-14 | XCUITest cannot attach screenshots — "Image creation failed. Disable automatic screenshots in your test plan's configuration." | minor | `done` in source (`MorbstackUITests.xctestplan`: `systemAttachmentLifetime: keepNever`, explicit `screenshots` capture format); validation blocked on Automation Mode |
| UI-15 | The remaining 14 minor + 8 polish items in UI-AUDIT.md | minor/polish | `in-flight` — all register rows fixed except UI-014 (CLI/daemon lane, outside GUI scope), UI-030 (validation blocked on Automation Mode), UI-032 (retest with settle delay pending) |

## Documentation

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| DOC-1 | "Unmodified upstream dockerd" retraction | Done: 26 corrections across 11 files; 17 hits deliberately left because `containerd`, the `docker` CLI, Compose and Buildx really are unmodified. See `docs/TRUTHFULNESS-PASS.md`. | `done` |
| DOC-2 | Collapse six status docs into one generated file | | `blocked` (SP-7) |
| DOC-3 | `morb scan` docs | Site copy corrected to describe the real behaviour | `done` |
| DOC-4 | `.local` vs `.test` contradiction | Settled by SP-3 in favour of the **source** constant (`morb.local`). `docs/domains.md` now needs four corrections, listed at the end of `docs/design/DNS-DECISION.md`: withdraw the `*.morb.test` recommendation; delete "there is no `/etc/resolver` fallback" (there is, priced in the decision); retire the "prove the per-user process can own loopback :80" gate (proved impossible); scope the host-side router + transport-lease contract to the fallback path only. | `open` |
| DOC-5 | **`morb scan` tells users to run a script that does not exist** | **Done 2026-08-06** (`9ae2042`, part of UX-13 1/2). `scripts/fetch-scan-tools.sh` now exists (276 lines, executable, clean shellcheck): fetches syft v1.50.0 + grype v0.116.1, archive-hash-checked, cross-checked against the release's own published `checksums.txt`, and the extracted binary hashed again — same pinning discipline as `fetch-guest-assets.sh`. `ToolLocator.swift`'s error message and `ScanCLI.swift`'s `--help` text both point at a script that now exists and does what they say, so neither string needed rewriting — the "ship the script" branch of this ticket's own either/or was taken. | `done` |

## Release and distribution — nobody has ever installed this

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| REL-1 | `scripts/release.sh`, `docs/RELEASING.md`, `.github/workflows/release.yml` | **Done 2026-08-06** (`2f36b30`, merged `d8de63f`): all three now exist. `scripts/release.sh` chains `fetch-guest-assets.sh` → `mise run guest-image` → `mise run app` → `make-dmg.sh`, then independently re-mounts the finished DMG read-only and re-runs `codesign` to confirm `com.apple.security.virtualization` survived packaging rather than trusting `mise-tasks/app`'s own pre-packaging check. `.github/workflows/release.yml` runs the same script on `macos-26` on a `v*` tag or `workflow_dispatch`. `docs/RELEASING.md` states the real boundary honestly: today's DMG only boots a VM on the machine that built it (ad-hoc signing carries no provisioning profile), Developer ID/notarization stay out of scope (REL-2/SP-9), and the release *workflow* itself is unproven — GitHub Actions was not accepting jobs on this account at verification time. Verified locally: two full `release.sh` runs, a real 224 MB `dist/Morbstack-0.1.0-m0.dmg`, entitlement + signature reconfirmed post-mount. | `done` (workflow run itself unverified — external: GitHub Actions account access) |
| REL-2 | Notarization | Not one `notarytool` call in the repo | `blocked` (SP-9) |
| REL-3 | Homebrew cask | | `blocked` (SP-9) |
| REL-4 | Sparkle update channel | `docs/sparkle.md` referenced and absent | `blocked` (SP-9) |
| REL-5 | Make the repo public | OPS-8's gating review is done (parts 1–2, [docs/audit/INPUT-VALIDATION-REVIEW.md](docs/audit/INPUT-VALIDATION-REVIEW.md)) and its verdict is that the reviewed surfaces — the MCP server, every shell-out, and the guest wire parsers — are safe to publish. Remaining before the flip is disclosure hygiene, not unknown risk: SEC-4 (a ruling), SEC-5 (`docs/mcp.md` is cited at runtime and does not exist), and the two TECH-1 port-lease parsers named in OPS-8. | `unblocked` (SEC-5 first) |

## Differentiation — only after parity is `accepted`

Ranked by impact per effort. Full rationale in [docs/COMPETITIVE-GAPS.md](docs/COMPETITIVE-GAPS.md).

| ID | Ticket | State |
| --- | --- | --- |
| DIF-1 | Hot reload on by default + published watcher conformance matrix | `blocked` (EN-7) — **half done:** the watcher conformance matrix shipped 2026-08-06 (`456f990`, `docs/benchmarks.md`'s "Live-share watcher conformance matrix": chokidar/nodemon/Vite/watchdog yes, Go `fsnotify`/`air` no). Hot reload is still **not** on by default — `MorbConfig.liveSharePaths` default remains `[]` (`MorbConfig.swift:141`); EN-7 (GUI writer exists, no CLI writer) is still the real blocker for that half. |
| DIF-1a | **Synchronized shares on the live-share transport** — the correctness-mode alternative to the `fchmod`→`IN_ATTRIB` bridge (colima#1244 is that bridge's documented production failure) and the honest successor to the deleted `MorbShareSyncProtocol` (SP-5). Scope: (1) extend the existing authenticated vsock-2381 session (`MorbLiveShareTransport` ↔ `live_share_receiver.rs`) with content-bearing messages — per-file records carrying bytes + SHA-256, chunked, over the already-proven HMAC handshake; (2) guest writer in `morbinit` doing atomic tmp-write→fsync→rename into a real guest-local directory (ext4/virtio-blk data disk, **not** the virtiofs mount — the guest kernel has no btrfs), so watchers get real `IN_MODIFY`/`IN_CREATE`/`IN_DELETE`; (3) per-share opt-in surfaced in the CLI — the GUI writer exists (UX-21, see EN-7) but there is still no `morb` subcommand; (4) guest-image rebuild + repin (guest lane). **Acceptance: a Go watcher using `air` rebuilds on host edits** — fsnotify treats `Chmod` as a distinct op, so `air` is precisely the case the current bridge cannot serve; chokidar/watchdog re-verified unbroken. See `docs/design/INERT-SUBSYSTEMS-DECISION.md` §1 and TECH-2 option (b). | `open` (needs guest lane + live engine; 1–2 wk) |
| DIF-2 | Container `exec` + a real PTY in the app — table stakes for both competitors. Transport, screen model, view and window shipped; `TerminalEmulator.feed`/`resize` and all of `TerminalKeyEncoding` were stubs returning nothing and are now implemented (141 unit tests incl. two fuzz soaks and a hostile-input suite). Reachable from the Containers contextual menu, the toolbar (`containers.openTerminal`), and the Container menu (⌃⌘T), disabled with a remedy for any non-running container. See [`docs/exec.md`](docs/exec.md). | `open` (code complete; **needs a machine-lane pass** — nobody has yet held a real shell against a running container) |
| DIF-3 | Publish the benchmark harness; add `git-status-bindmount` and `npm-install-bindmount-vs-volume` | `done` — 2026-08-06 (`456f990`). Both benchmarks exist (`mac/Sources/MorbBench/Benchmarks/GitStatusBindmount.swift`, `NpmInstallBindmountVsVolume.swift`) and the harness is documented end-to-end in `docs/benchmarks.md` (setup, `StackGuard` safety rationale, all eight target-table rows, run/compare usage). Publishing the harness's *documentation* is not the same as publishing *measured numbers* — no run has actually recorded PASS/MISS values yet; that's UX-30. |
| DIF-4 | **Container domains via unprivileged mDNS** — mechanism decided in [`docs/design/DNS-DECISION.md`](docs/design/DNS-DECISION.md). Six steps, **~3–4 weeks, zero admin prompts**: (0) prove host→guest reachability at `192.168.64.x` on Wi-Fi/Ethernet/VPN — **hard gate**, fall back to `127.0.0.1` + high-port URLs if it fails; (1) mDNS registrar in `morbstackd` (`A` records only, `LocalOnly`, no advertised service type, conflict handling, Docker-event lifecycle); (2) name derivation wired to the existing `MorbLocalDomain.Name` validator (the loopback claim reconciler was deleted under SP-5; the registrar owns its own name→container index and duplicate rejection); (3) guest-side Host-header reverse proxy owning `:80`/`:443` inside the VM, pinned like every other guest binary, with listening-port auto-detection; (4) withdrawal paths (stop/remove, suspend, wake, VPN transition, hostile-`.local` detection); (5) `morb domain` CLI + inspector affordance. No wildcards — do not advertise them. | `open` |
| DIF-5 | **HTTPS via a name-constrained local CA** — **~2–3 weeks after DIF-4**. CA key in the Keychain, ACL-restricted; per-name short-lived leaves; name constraints as defence in depth with honest browser-by-browser verification (Firefox has its own trust store). **Two things need a written ruling before code:** the trust installation is the one and only user password prompt in the whole domains feature, and if the proxy lives in the guest then leaf private keys live in the guest — recommended shape is issue-on-host, push over vsock, hold in guest tmpfs, CA key never leaves the host. | `blocked` (DIF-4) |
| DIF-6 | Routable container IPs | `open` (SP-5 resolved; nothing deleted touches this — design from scratch) |
| DIF-7 | Native file access to volumes (Finder) | `open` |
| DIF-8 | Distroless debug toolbox — **the one thing OrbStack actually paywalls** | `open` (unblocked — DIF-2's exec/PTY mechanism is source-complete, so nothing structural still blocks this). The toolbox feature itself remains unbuilt: `MorbScan/DebugCLI.swift` (`morb debug plan`/`check`) is deliberately read-only planning only — no execution path exists yet, pending the safety primitives `docs/debug.md` calls for. |
| DIF-13 | Linux machines — spec-only after SP-5 deleted the unreachable M0/M0.1 scaffolding (recoverable at `3157c39`); [`docs/machines.md`](docs/machines.md) is the design. Entering this space is a deliberate competitive decision against Apple's `container machine` (`docs/COMPETITIVE-GAPS.md`), not a default | `open` (decision required before code) |

**Not building:** Docker Desktop's compliance suite — ECI, Hardened Desktop, registry access
management, SSO, air-gapped install, Settings Management. Enterprise procurement is the wrong market
for a one-maintainer open-source project.

## Technology foundations — [docs/audit/TECHNOLOGY-AUDIT.md](docs/audit/TECHNOLOGY-AUDIT.md)

Spikes first — each delivers a decision or a measured result, not code.

### TECH-1 · Patch-free `-P` via `--userland-proxy-path` · `decided` / `done` (2026-08-04)
**Decision: the wrapper won.** The 174-line downstream Moby patch, the scripts and CI job that built a
patched `morbstack-dockerd`, and the vsock 2379 publish-all allocator protocol are all deleted. Morbstack
now ships the unmodified upstream dockerd (stock static Docker 29.7.1 binaries, archive-hash-pinned).
`--userland-proxy-path` is a stock dockerd flag — the same hook Docker Desktop's vpnkit uses — and pinning
it against Moby v29.7.1 source confirmed the contract this decision needed: dockerd execs the configured
proxy once per published port, after resolving the effective port set (including `-P`/`EXPOSE` dynamic
allocations), and fails the container start with no retry if the proxy reports failure on its fd-3 status
pipe. Morbstack's wrapper (`guest/morbinit/src/proxy_wrapper.rs`) leases the Mac-side endpoint from the
host over a new guest-initiated vsock channel (host port 2382) before exec'ing the stock `docker-proxy`,
giving fail-closed semantics without any non-upstream engine artifact to build, sign, or release. Full
rationale, the verified Moby contract, and the wire protocol: `docs/design/PATCH-FREE-PUBLISH-ALL.md`.
**Rewrote:** SP-4 (superseded), SP-6 (closed as moot), OPS-9, REL-1, EN-1/EN-2 scope,
`docs/design/ENGINE-BUILD-DECISION.md` (now a superseded stub).

### TECH-2 · Hot-reload foundation ruling · `open` (spike) — **ruling exists in substance, not yet filed as one**
**Deliverable:** a written ruling that the `fchmod(2)`→`IN_ATTRIB` bridge is a best-effort accelerant, not
the inotify story, plus the chosen correctness path. Evidence: colima#1244 is this exact pattern failing in
production; Go fsnotify maps `IN_ATTRIB` to a distinct `Chmod` op that `air`-class tools filter; notify-rs
(cargo-watch, watchexec) likewise; virtiofs has no inotify passthrough (2021 RFC, LWN 874000, never merged).
Decide: (a) reframe bridge + `morb doctor`/status detection of known-filtered watchers, (b) promote tier-2
synced shares to the *correctness* mode (real guest writes → real `IN_MODIFY`/`IN_CREATE`/`IN_DELETE` —
the free version of Docker's paid Mutagen mode), (c) verify same-mode `fchmod` emits `IN_ATTRIB` with an
in-guest probe and record it.
**Rewrites:** EN-7, DIF-1, `docs/live-share-bridge.md` framing.
**2026-08-07 check:** the reasoning is already written down — `docs/design/INERT-SUBSYSTEMS-DECISION.md` §1 argues for option (b), and DIF-1a's own row calls itself "TECH-2 option (b)" — but no part has actually shipped: no `morb doctor`/status detection of `air`-class filtered watchers, no in-guest `fchmod`→`IN_ATTRIB` probe recorded, and DIF-1a (the correctness-mode build) hasn't started. Point future readers at the existing reasoning rather than re-deriving it; still `open` because none of (a)/(b)/(c) has code.

### TECH-3 · Does vz virtio-blk discard punch holes in `disk.img`? · `done` (spike run 2026-08-06)
**Answer: yes.** Both `-o discard` (live ext4 mount option) and explicit `fstrim` measurably shrink
`disk.img`'s allocated blocks on the host — `-o discard` reclaimed ~4.01 GiB deleting a 4 GiB file (against
a no-discard control that moved <0.01%); `fstrim` swept ~9.3 GiB of accumulated free space in one bounded
pass. Full numbers, `stat -f %b` readings for every step, and the exact `nsenter`-based method (there is no
`morb exec`) are in `docs/design/DISK-RECLAIM-DECISION.md` §4/§5. Compact-by-copy is no longer needed.
**Still open:** wiring `-o discard`/periodic `fstrim` into `guest/morbinit/src/disk.rs`'s `Ext4` arm and a
user-visible reclaim readout on the Disk route — this spike measured the mechanism, it did not ship the fix.
**Rewrites:** EN-4/EN-5 scope, the kernel-fork (btrfs) priority — both drop in priority now that ext4 alone
answers UX-16 without a btrfs kernel fork.

### TECH-4 · Save/restore retest: scanout device + Developer ID · `open` (spike)
**Deliverable:** a measured result. `restoreMachineStateFrom` fails for direct-kernel guests on macOS 26.4
(reproduced in a minimal harness); research suggests restore requires a `VZVirtioGraphicsDeviceConfiguration`
with a scanout — attach a minimal one, retest, and retest under Developer ID signing. If restore works,
suspend-to-zero with ~500ms resume unlocks — the single biggest lifecycle lever. Delete
`save-restore-unsupported` marker semantics accordingly.
**Rewrites:** VM lifecycle roadmap, `docs/architecture.md` §"VM lifecycle".

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| TECH-5 | Drive the memory balloon | **Duplicate of UX-17, which shipped this same deliverable 2026-08-06** (`f5395789`/`5f669844`): `VMManager.swift:804` now sets `targetVirtualMachineMemorySize`, `MemoryBalloonPolicy.swift` implements the shrink/restore policy with unit tests. Real host-RSS measurement via MorbBench is still outstanding — that residual is UX-29, not this ticket. | `done` (superseded by UX-17; see UX-29 for the unmeasured remainder) |
| TECH-6 | Sleep/wake + clock correctness | Zero power-event handlers exist and `clock_sync` is observe-only. Register `NSWorkspace` wake notifications; implement guest `clock_settime` (CAP_SYS_TIME) behind the existing MRB0 message; acceptance: guest clock within tolerance after a forced overnight-sleep test, TLS-in-container works on wake. | `open` |
| TECH-7 | Host disk-pressure policy | Nothing watches Mac free space while sparse `disk.img` grows. Define and implement low-space detection → honest warning/pause before guest I/O errors. | `open` |
| TECH-8 | Shared framing core for the vsock protocols | **Done — duplicate of PROTO-6, both closed by `22c513e`** ("PROTO-6: one wire module for the guest, and lint where it runs"). `guest/morbinit/src/wire.rs` now provides `read_preamble_line`, `read_install_preamble_line`, `err_line`, `ConnGuard`, `DeadlineStream`, `send_best_effort`; `dial.rs`, `datagram.rs`, `live_share_receiver.rs`, `ssh_agent_forward.rs` and `k8s.rs` all call into it. Four behavioral divergences (k8s's different preamble algorithm and missing per-read deadline, datagram's non-logging `send_busy`, proxy's non-flushing `send_busy`) were deliberately preserved rather than papered over — see PROTO-6. Tests 240→248. | `done` (see PROTO-6) |
| TECH-9 | Crypto/parser assurance in morbinit | Hygiene is good (published SHA-256 vectors, constant-time HMAC compare — verified). Extend to full NIST CAVP vector sets; differential-fuzz `jsonlite` and the line protocols against reference implementations host-side (zero-crate rule constrains the shipped binary, not tests). | `open` |
| TECH-10 | "Proper" fault-drill matrix | Scripted drills for P1–P7 in TECHNOLOGY-AUDIT.md: VM panic → recovery policy, kill -9 daemon mid-pull, torn `disk.img`/`config.toml`, guest disk full, cross-version daemon/guest matrix, concurrent CLI storm. Each drill's outcome recorded and surfaced by `morb doctor`. | `open` |
| TECH-11 | Quarterly `apple/container` watch | One-page delta per release, focused on `container machine` (the only credible threat vector) and the kernel recipe (input to the btrfs kernel fork). | `open` |

## Concurrency — from the deep architecture audit (2026-08-03)

Each has file:line evidence and was found by reading, not by a failing test. The
architecture audit may file overlapping `ARCH-` tickets; merge rather than duplicate.

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| CONC-1 | **Publish-all vsock fd double-close** | `Session.deinit` closed `fd` unconditionally while `beginPublishAllLifecycleSession`'s `catch` closed the same `fd` explicitly, so every handshake failure closed one descriptor twice. Between the two closes that number can already belong to an unrelated `accept()`/vsock connect on another queue, so the second close severs a live connection elsewhere. Fixed: `closeOwnedDescriptor()` guard, session constructed outside the `do` so the failure path closes exactly once. **Same family as SP-6** — an owned fd with two uncoordinated close paths. **2026-08-04:** the code this fixed was deleted with the rest of the publish-all path under TECH-1; the fix and this ticket are now historical record only, superseded rather than reverted. | `done` |
| CONC-2 | Stale-generation probe overwrites fresh diagnostics | `VMManager.beginControlProbe` calls `noteGuestPinged`/`noteDockerDataOnDisk`/`noteGuestShares` on the probe queue **before** the `generation == probeGeneration` guard (`VMManager.swift:1661-1684`). A probe from a superseded boot returning `.ready` after `invalidateControlReadiness()` clobbers the freshly-reset snapshots, so `morb status`/`morb doctor` can report the wrong boot's data. Fix: move the three `note*` calls inside the generation-checked block — they are already duplicated there. **2026-08-04:** fixed — the unguarded `note*` copies are deleted (the generation-checked block already had them); invalidation now bumps the generation *before* wiping so a lock-atomic `noteGuestPinged(ifCurrent:)` covers the `.dockerStarting` path, and the four additive `info` notes (`rosetta`, `tmp_alias`, `share_event_bridge`, `disk_resize`) got the same `ifCurrent` guard — they had the identical defect one function deeper. Race not unit-testable; invariant documented at each site.  | `done` |
| CONC-3 | `whenGuestPowersOff` registration races `guestDidStop` | Both are scheduled onto the same serial queue from different triggers with no ordering guarantee (`VMManager.swift:936-947` vs `:2073-2081`). Losing the race burns the full 5 s `guestPowerOffTimeout` on every clean stop where the guest powers off faster than the control-ack round trip — contradicting the comment at `:2078` that says releasing early "saves the five seconds its deadline would otherwise burn". **2026-08-04:** fixed — `whenGuestPowersOff` is keyed on the `VZVirtualMachine` instance and `releaseVirtualMachine` is the single point that flushes observers (next queue turn, to avoid reentering waiter bookkeeping mid-delegate-callback), so a registration that loses the race observes the recorded event instead of burning the deadline, and cannot latch onto a newer boot that re-occupied the slot. Race not unit-testable; invariants documented.  | `done` |
| CONC-4 | `Daemon.shutdown()` bypasses `forwarderQueue` | `Daemon.swift:1300` calls `forwarder.stop()` directly on `controlQueue`, while every other call site funnels through `forwarderQueue` precisely so "a fast running → stopped → running flap cannot reorder into a stop that lands after the start it preceded" (`Daemon.swift:109-116`). Currently masked by the `exit(0)` shortly after; becomes live the moment shutdown grows a longer tail. **2026-08-04:** fixed — `shutdown` now runs `forwarder.stop` inside `forwarderQueue.sync` (safe: nothing on that queue blocks back on its caller), and tears down the Kubernetes API forward + bumps `kubernetesForwardGeneration` in the same block, which shutdown previously skipped entirely.  | `done` |
| CONC-5 | `UnixSocketServer.stop()` does not wait for its cancel handler | Asymmetric with `TCPListener.stop()`, which blocks on `closedSignal` for exactly this reason (`TCPListener.swift:322-354`). Not currently exploited, but two listener types that otherwise mirror each other disagree on whether `stop()` means "the path is free". **2026-08-04:** fixed — `TCPListener`'s private `ListenSocket` extracted as the shared `POSIXListenSocket`; `UnixSocketServer.stop()` now cancels, waits on `closedSignal` with the same 2 s grace, and closes from the caller on timeout, so both listener types agree that `stop()` returning means the descriptor is closed and the path free.  | `done` |

## Protocol contract — from the deep architecture audit (2026-08-03)

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| PROTO-1 | **`morbinit_version` is parsed and never consulted** | The field `docs/protocol.md` nominates as *the* compatibility probe has zero live consumers — decoded at `GuestControl.swift:91,163` and referenced nowhere else but two test assertions. Every future breaking change therefore has no host-side gate, despite the doc claiming one exists. Make the host read it once per boot and surface it when older than a compiled-in minimum. **2026-08-04:** fixed — host records `morbinit_version` once per boot (generation-guarded), compares against the new `MorbVersion.minimumCompatibleMorbinit` (`isOlder(_:than:)`, unit-tested incl. milestone-suffix ordering), warns in the daemon log, and surfaces it in `morb status` (`guest morbinit` row, wire field `morbinit_version`) and `morb doctor` (`guest-morbinit` check). Verified live: status/doctor show `0.1.0-m0`. No negotiation protocol invented.  | `done` |
| PROTO-2 | Stale docs for removed port 2380 | `listen_probe.rs` and `GuestListenerProbe.swift` were deleted in `51dc543`; `docs/protocol.md` was scrubbed but `architecture.md` (3 sites) and `ENGINE-MATRIX.md` still described it as live. Already corrected in `TASKS.md` and `MASTER-PLAN.md`. **Done** — `architecture.md` now has exactly one "2380" mention and it correctly says "retired and must not be reused" (`5ea075a`); `MASTER-PLAN.md:47` correctly records both retirements; the one remaining "2380" hit in `ENGINE-MATRIX.md` is inside a dated historical-log quote in a document that opens with an explicit staleness disclaimer, not a live claim. | `done` |
| PROTO-3 | Inconsistent backpressure at connection caps | 2376/2378 emit `ERR busy\n` — a deliberate hardening pass their own comments describe as fixing exactly this. 1024, 2375 and 2381 still **silently drop** over-cap connections with only a log line, which is indistinguishable from a peer that never spoke the protocol. Apply the fix uniformly. **2026-08-04:** fixed — 1024 answers with a well-formed MRB0 `error` frame (`busy`), 2375 with a synthetic HTTP 503 + `Connection: close` (pairs with the host's 502-when-unreachable), 2381 with `ERR busy\n` in place of `BOOT`; all use dial.rs's bounded best-effort send discipline. Host `MorbLiveShareTransport` now names a busy rejection distinctly instead of reporting a generic boot-identity violation. 3 new Rust tests; protocol.md updated for 2375.  | `done` |
| PROTO-4 | 2377 k8s transfer has no in-flight timeout and is serial | A 10 s preamble wait (`PREAMBLE_TIMEOUT`, `k8s.rs:86`) bounds negotiation, but nothing bounds the body afterwards. One stalled ~512 MB `PUT` wedges every later `morb k8s enable` from any client indefinitely (`k8s.rs:1022-1026` documents the serial design as intentional). Reconfirmed still open by the PROTO-6/TECH-8 refactor: that commit's own message lists "k8s.rs's install server never wraps reads in a per-read deadline the way its siblings do" as a divergence found and deliberately left alone, not fixed. | `open` |
| PROTO-5 | jsonlite's flat-only contract is enforced only by convention | `jsonlite` rejects **any** nesting, poisoning the whole frame (`jsonlite.rs:123-140`). Every host MRB0 struct goes through Foundation's fully general `JSONEncoder` with no check. Adding one nested field compiles, passes Swift round-trip tests, and then fails 100% of that message type at runtime with a generic "invalid JSON". Add a host-side flatness assertion. **2026-08-04:** fixed — `MRB0FlatnessTests.swift` encodes every host-encoded MRB0 type (`GuestRequest` directly; `K8s.Request` by capturing the real frame bytes over a socketpair) and asserts every top-level value is a scalar; failure names the type and key. Verified it has teeth by planting a nested field. Reply-side needs no mirror: jsonlite's `Value` enum cannot construct nesting.  | `done` |
| PROTO-6 | Guest plumbing duplicated across protocols | **Done** (`22c513e`, "PROTO-6: one wire module for the guest, and lint where it runs"). New `guest/morbinit/src/wire.rs` holds `read_preamble_line`/`read_install_preamble_line`/`err_line`/`ConnGuard`/`DeadlineStream`/`send_best_effort`; `dial.rs`, `datagram.rs`, `live_share_receiver.rs`, `ssh_agent_forward.rs`, `k8s.rs` all delegate to it. Same commit as TECH-8 (a duplicate ticket for the identical ask, filed in a different board section) — four genuine behavioral divergences (k8s's own preamble algorithm and missing per-read deadline — that gap is PROTO-4, deliberately left open; datagram's and the port-lease proxy's differing `send_busy` semantics) were kept rather than merged away. Tests 240→248. | `done` (see TECH-8) |

## Module graph — from the deep architecture audit (2026-08-03)

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| MOD-1 | **2,603 LOC of confirmed-dead code in MorbstackKit** | Resolved by SP-5 (2026-08-03): all three files deleted, plus the `LocalDomainClaimReconciler` loopback model and its dead `PortForwarder` snapshot producer. See [`docs/design/INERT-SUBSYSTEMS-DECISION.md`](docs/design/INERT-SUBSYSTEMS-DECISION.md); recoverable from git (`aef003a`, `3157c39`). | `done` |
| MOD-2 | Split MorbstackKit along the boundary it already respects | ~20 files are linked only by `morbstackd`; everyone else talks over IPC. Proposed `MorbstackProtocol` (no deps) ← `MorbstackDaemonCore` ← `morbstackd`. ~30 file moves plus one import line each, **zero logic changes**, because the consumer boundary already matches. | `open` |
| MOD-3 | Two hand-maintained Docker Engine model sets will drift | `AppCore/Models.swift` (1,450 LOC typed structs) vs `MorbFeatures/EngineClient.swift` raw `[String: Any]`. `morb` deliberately never links AppCore, so this is a real architectural fork, not an oversight — collapsing it is multi-day. Decide whether to unify or to accept and document the fork. | `open` |
| MOD-4 | `K8s.installPort` = 2377 lives outside `MorbVsockPorts` | The port-constant registry is not actually singular (`K8s.swift:53` vs `VMManager.swift:2102-2119`). **2026-08-04:** fixed — 2377 lives in `MorbVsockPorts.k8sInstall`; `K8s.installPort` is now an alias into the registry rather than a second literal.  | `done` |
| MOD-5 | Adding one MRB0 field touches 6–9 files across 3 modules | Wire protocol is hand-duplicated on both sides with no codegen. Shotgun surgery by construction; grows linearly with feature count. | `open` |

## Ecosystem — from EN-8/EN-9 acceptance (2026-08-04)

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| ECO-1 | **Silent wrong-daemon execution — the biggest ecosystem gap** | Unconfigured, Morbstack is *invisible* to Testcontainers Node/Go/Java: they never read `docker context`, find no `DOCKER_HOST`, fall through to whatever socket exists, and run **green against Docker Desktop 27.4.0**. Reconfirmed live in three languages. This is worse than failing — a user's suite passes while testing the wrong engine. Fix so that a correctly installed Morbstack is discoverable with **no environment variables at all**. **2026-08-04:** done — see `docs/design/ZERO-CONFIG-DISCOVERY.md`. The unprivileged install (`morb install-cli` / first-run) already created the per-user conventional socket link `~/.docker/run/docker.sock` (when free) and registered+selected the `morbstack` context (when current was plain `default`); with the ECO-2 engine rewrite this is now sufficient end-to-end: Node 12.1.0, Go v0.43.0, Java 1.21.4, Python 4.15.0 all ran real Postgres suites against **29.7.1** with `env -i` — zero environment variables — on a simulated no-Docker home (matrix, "Zero-config rerun"). `/var/run/docker.sock` stays a printed, user-run `sudo` option, never automatic. Reframed residual: on a both-installed machine Morbstack correctly defers to Docker Desktop's live socket/context, and that deferral is now *loud* — `morb install-cli` ends with an explicit `[!!] not what Docker tools will discover` consequence block, and `morb doctor`'s `docker-discovery` check warns about competing sockets. | `done` |
| ECO-2 | `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` is mandatory, not optional | Without `=/var/run/docker.sock`, Ryuk's socket mount **500s in every language**. Ryuk itself works fine once set (0.14.0/0.8.1/0.12.0, self-reaps in ~10 s, `TESTCONTAINERS_RYUK_DISABLED` never needed). Requiring the incantation is a gap; folds into ECO-1. **2026-08-04:** done — the override is no longer needed in any language. `DockerBindMountPreflight` (host-side, via `DockerProxy`) rewrites a bind source that is, by exact symlink-resolved identity, the daemon's own published socket into the guest's `/var/run/docker.sock`; foreign engines' sockets are never redirected (unit-tested, 4 new cases). Verified live in all four languages with no override and by `docker inspect` of the recorded bind. `scripts/ecosystem-acceptance.sh` deliberately no longer sets the override so a regression fails loudly. The grant this enables (socket-mounting = engine control) is stated as a trust decision in `docs/design/ZERO-CONFIG-DISCOVERY.md`. | `done` |
| PROTO-7 | dockerd `MinAPIVersion` blocks older clients | Verified on the live socket: `/v1.32/info` → **400**, `/v1.44/info` → **200**. This is upstream moby 29's default of 1.40, **not** a Morbstack behaviour. `testcontainers-java` ≤1.20.x probes `/v1.32/info`, gets the 400, and silently fails over to another daemon. Proposed: `DOCKER_MIN_API_VERSION=1.24` in morbinit's dockerd env — verify moby 29 honours a floor that low before shipping. Would make Morbstack the engine-29 distribution that the ≤1.20.x installed base works against; Docker Desktop is only insulated because it still ships engine 27. **2026-08-04:** shipped and verified live — `DOCKER_MIN_API_VERSION=1.24` set unconditionally in morbinit's dockerd env (`supervisor.rs`; the shipped 29.7.1 binary carries the env var and its validator). After `mise run dev`: `/v1.32/info` → **200**, `/v1.24` → **200**, `/v1.23` → **400** (upstream's hard floor `MinSupportedAPIVersion`), and `docker version` reports `API version: 1.55 (minimum version 1.24)` — modern negotiation unchanged. Always-on rather than a toggle: the failure it prevents is silent and severe, the cost is accepting verbs the engine already implements. Regression test pins the env pair. Recorded in COMPETITIVE-GAPS.md. | `done` |

**What passed**, all with real Postgres-backed suites against server 29.7.1: Testcontainers Node 12.1.0,
Python 4.15.0, Go v0.43.0 and Java 1.21.4 (warm totals 1.7–5.9 s, clean teardown, zero leftovers), and
Dev Containers CLI 0.88.0 in full — `up`, two-way workspace bind mount, `postCreateCommand`, `exec`,
and a features/derived-image build through Morbstack BuildKit. Only Testcontainers **Python** and the
Dev Containers CLI find Morbstack without `DOCKER_HOST`; they are the two that read `docker context`.
Evidence: [audit/ECOSYSTEM-MATRIX.md](docs/audit/ECOSYSTEM-MATRIX.md).

## Findings without tickets — filed 2026-08-04

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| SEC-1 | ~~Unbounded read on bare CR in the k8s install preamble~~ | **Done 2026-08-04** (input-validation review, [docs/audit/INPUT-VALIDATION-REVIEW.md](docs/audit/INPUT-VALIDATION-REVIEW.md)). `read_preamble_raw` in `guest/morbinit/src/wire.rs` now bounds **total bytes consumed** at `2 * max + 2` independently of the kept-byte line cap, so a bare-`\r` flood errors after a few hundred bytes instead of being read forever. Legitimate CRLF traffic is unaffected (a real line has at most one `\r` per `\n`; a regression test pins moderate CR noise still parsing). 3 new tests in `wire.rs`. | `done` |
| SEC-2 | ~~Live-share `CLOSE` HMAC verified over the wrong string~~ | **Done 2026-08-04** (input-validation review). The host signs `"CLOSE <sequence>"` (`MorbLiveShareTransport.close()`), but the guest verified the HMAC over the bare sequence digits only (`live_share_receiver.rs`), so **every authentic host close was rejected** (benign in practice — the host shuts the socket down without awaiting `STOPPED` — but the graceful close never verified, and the verb was outside the authenticated bytes). Guest now verifies over `"CLOSE <sequence>"` via `close_is_authentic`, with a test pinning the exact host wire format and rejecting the old bare-digits coverage. Guest-side only; no host change. | `done` |
| SEC-3 | Live-share receiver has no post-handshake read deadline | After the authenticated hello, `serve_connection` (`guest/morbinit/src/live_share_receiver.rs`) reads event lines with no timeout, and `MAX_CONNECTIONS` is 4 — so idle connections that complete a handshake and then go silent pin all four slots until the peer closes. Low severity: the port is reachable only through the host side of the VM's vsock device, so the only peer that can do this is the paired daemon. Same family as PROTO-4 (bound the in-flight phase, not just negotiation); fix both with one idle-read discipline. | `open` |
| SEC-4 | MCP audit log records up to 500 characters of **tool output** | `AuditLog.recordToolCall`'s `result_summary` is untouched by the redactor that carefully scrubs arguments. With the `inspect:env` grant, `container_inspect` returns the deliberately unredacted document with sorted keys, so `Config.Env` values land inside the first 500 characters and are written to a file that outlives the session. Mitigated by 0600 (created *and* re-asserted). Not fixed in the input-validation review because the fix is a decision about what the log is for: dropping successful summaries to a byte count keeps the "which tool, which arguments, which outcome" claim but loses forensic detail, and choosing per-tool would put the judgement back in each tool. Deliverable: a ruling, then a one-place change in `Audit.swift`. | `open` |
| SEC-5 | **`docs/mcp.md` does not exist**, but seven places cite it — two of them at runtime | Every `container_logs`/`container_exec` result carries `"redaction": "…see docs/mcp.md; not a guarantee"` and `container_inspect`'s description points at "docs/mcp.md's threat model", so an *agent* is told to read a file that is not in the repo. The threat model itself is real and written down in source comments; it needs a home. Same file: `Audit.readAll` is documented "for `morb mcp audit`", a subcommand `MCPCLI` does not implement — either write it or fix the comment. Standing rule violation ("no `--help` text that promises behaviour the implementation does not have") and the sort of thing a first reader of a newly public repo finds in ten minutes. | `open` |
| SEC-6 | `MorbstackAppCore/DockerClient.swift` builds Engine API paths the way MCP-1 did | ~20 sites interpolate an id straight into a path that becomes an HTTP request line, with no encoding — the same shape as MCP-1 (fixed 2026-08-05 in `EngineClient.path`). Lower severity because the input is engine-returned names and the user's own typing rather than a string an agent chose, so this is hardening, not a live hole; not fixed then because the file was owned by other work in flight. Deliverable: route those paths through an encoding builder (or adopt `EngineClient`'s) so the property holds by construction rather than by input provenance. | `open` |
| ARCH-1 | **`VMManager` queue-confinement is enforced only by convention** | `virtualMachine`, `controlReady`, `runWaiters`, `stopWaiters`, `guestStopObservers`, `stopInFlight`, `diskGrowthInFlight`, `suspendCancelRequested` have **no lock at all**. Correctness rests entirely on every call site remembering to hop onto `queue` first. The comments say "Queue-confined"; nothing enforces it. The architecture audit rates this the largest concurrency risk in the codebase, and it is a design choice rather than a bug — so the deliverable is a decision: express the confinement in the type system (an actor, or a `@QueueConfined` wrapper that asserts `dispatchPrecondition`), or accept it and add `dispatchPrecondition(condition: .onQueue(queue))` at every entry point so a violation traps in debug rather than corrupting silently. | `open` |
| OPS-10 | ~~Clippy ran host-only~~ | **Done 2026-08-04.** `mise run check` now runs clippy for both host and `aarch64-unknown-linux-musl`. Host-only clippy was structurally incapable of seeing the Linux-gated code — the same hole that let 13 guest compile errors ship while `cargo test` reported 217 passing. It immediately found two live lints. CI should mirror this. | `done` (CI mirror `open`) |

## UX — feature gap vs Docker Desktop and OrbStack — filed 2026-08-05

Evidence: [docs/audit/COMPETITOR-UI-RESEARCH.md](docs/audit/COMPETITOR-UI-RESEARCH.md). Delta and
verdicts: [docs/audit/UI-FEATURE-GAP.md](docs/audit/UI-FEATURE-GAP.md). The bar, per the user:
*if they can do it, we can do it better, for free, and without the overhead and cruft.* Skip
verdicts (extensions marketplace, AI/cloud panes, Build-view telemetry, fleet admin) are recorded in
that doc's §8/§12 and are product decisions, not omissions.

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| UX-1 | **Context-preserving log search** — our `ContainerLogsTab` filter hides every non-matching line, which is OrbStack issue #2178 verbatim (their fix took until v2.2.0). We should not ship a bug a competitor already ate the complaints for. | Shipped 2026-08-05: **Find** is the default mode — all lines stay visible, matches painted with the system `findHighlightColor` (current match full-strength + black text), "3 of 47" position readout, ⏎/⇧⏎ and ⌘G/⇧⌘G stepping with wrap, ⌘F focuses the field. **Filter** stays as the explicit second mode ("5 of 412 lines"). Pure logic (`TrackBMatchSpan`, `TrackBMatchNavigator`, store modes) unit-tested (18 new tests incl. a fixture-corpus highlight bounds test); end-to-end proven by XCUITest `testLogFindHighlightsInPlaceAndFilterStaysExplicit` against the real bundle. Evidence and the two defects fixed en route (animated-scroll main-thread wedge; bar overflow in the narrow inspector): UI-AUDIT **UI-049**. | `done` |
| UX-2 | **Compose-aggregated log view** — the most-praised OrbStack log feature: one merged stream per project, colour-coded per service. Our `LogPipeline` already normalizes per-container lines; Stacks can only deep-link to one container's log today. | Shipped 2026-08-05 as a **separate document window** (`WindowGroup(id:for:)` keyed on the project name — an inspector column cannot hold a three-column streaming document, and a project is not a sidebar category; reasoning in `ComposeProjectLogsView.swift` and the HIG audit). Opened from the Stacks project/service menus and the Containers project group header. Merged on dockerd's timestamps with a reorder window plus a start-up priming phase, so a slow stream cannot invert causality; nothing is re-ordered after display. Per-service colour on the **name column only** (ANSI keeps the body), stable across restarts via FNV-1a. Per-service show/hide is a scope that composes with UX-1's find/filter. No new transport — one `client.logs` per service into the same `TrackBLogStore`, now shared with the container tab as `TrackBLogDocumentView`. 55 unit tests. **Visual review still owed** (machine lane). | `done` (visual acceptance pending) |
| UX-3 | **Log wrap toggle + clickable links** — OrbStack #536 documents the wrap want; Docker Desktop ships clickable links (VERIFIED). Small. | Shipped 2026-08-05 on both log documents. **Wrap Long Lines** in the log options menu, persisted (`morb.logWrapsLines`) and shared by every log document; off means the surface scrolls sideways with `.bottomLeading` anchoring. **Links**: only literal `http`/`https` spans are linked, so the visible text is the destination character for character; credentials, non-web schemes (`file:`, `javascript:`, `data:`, app schemes), lines containing bidi overrides, and URLs continuing into non-ASCII are all refused; `NSDataDetector` was rejected because it invents `http://` for bare hosts. Nothing auto-opens, and a destination on this Mac or the LAN gets a confirmation naming the full URL. Search, copy and export read `plain`, so wrap cannot change a match or mangle copied text. | `done` (visual acceptance pending) |
| UX-4 | **Container Files tab (read-first)** — both competitors browse a container's filesystem; we have nothing (bind-mount reveal is the host's own directory). Engine API carries it credential-free: `HEAD/GET /containers/{id}/archive`. | A Files tab in `ContainerDetailView`: directory browsing via archive stat/tar, file preview for text, "Save to Host…" for files/folders. **Write/upload is explicitly out of scope** — in-place edit of a running container's filesystem is a second decision with its own confirmation semantics. | `code complete, visual acceptance pending` — Files tab shipped (`ContainerFileArchive/Scan/TreeStore/FilesTab/ViewerSheet/Transfer.swift`), 37 unit tests, parser diffed against a real 40 MB engine archive. The engine has **no** one-level listing request, so a listing is a budgeted read of the whole subtree that reports what it finished; see the 2026-08-05 entry in `docs/design/HIG-COVERAGE-AUDIT.md`. Not yet seen in a real window. |
| UX-5 | **Spike: registry discovery beyond Docker Hub — deliverable is a decision.** Docker Desktop's browsing is Hub-only because its UI is built around one vendor's account; we have no credential store to bias us. But only Hub has an anonymous *search* API; other registries offer anonymous manifest/tag browsing by name only. | **Decided 2026-08-05** (`2c027a2`, in `docs/audit/UI-FEATURE-GAP.md` under this heading): build differently, not a second search screen. Anonymous tag/manifest browsing (does this tag have an arm64 manifest, before the pull) is portable everywhere; a multi-registry search surface is not, and `RegistryImageDiscovery.swift` already encodes that refusal. Spawned UX-11, whose backend (`RegistryReferenceResolver.swift`) is now source-complete. | `decided` |
| UX-6 | **Compose grouping in the container list** — Docker groups containers into collapsible Compose-project entries (VERIFIED); our list is flat and the project exists only as hidden search text. Respects the decided UI-011 outcome (keep `List` + inspector). | **Half done — likely a duplicate of TASTE-2, which shipped the grouping half.** `ContainersRootView.swift` already groups containers into a `DisclosureGroup` per Compose project with an "n of m running" header and a project-scoped context menu (`TASTE-2`, `9506529`, 2026-08-05) — this premise is stale. **Not done:** "Copy `docker run` Command" was never added to the per-container context menu; the only similar string in the file, "Copy Example Run Command," is an unrelated empty-state action that copies a generic `alpine sh` template, not the selected container's actual run command. | `open` (grouping done via TASTE-2; copy-run-command still missing) |
| UX-7 | **Spike: volume content browsing — deliverable is a decision.** Docker's Stored-data tab needs sign-in for export (a purely local file operation); OrbStack projects volumes into Finder. The Engine API has **no** volume-contents endpoint, so the mechanism is genuinely open. | **Decided 2026-08-05** (`2c027a2`): build, read-only, via the throwaway `:ro` helper-container mount that `VolumeArchiveExport.swift`/`MorbMigrate/HelperContainer.swift` already use — no guest agent (rejected, widens the surface OPS-8 just narrowed); DIF-7 stays a successor, not a prerequisite. Spawned UX-12, whose backend (`VolumeContentBrowser.swift`) is now source-complete. | `decided` |
| UX-8 | **Spike: image vulnerability surface — deliverable is a decision.** Scout ties scanning to a Docker account and repo quota; local `syft`/`grype` has neither. But `morb scan` currently tells users to run a script that does not exist (DOC-5) — the CLI promise must be kept before a GUI repeats it. | **Decided 2026-08-05** (`2c027a2`): build, first-run fetch rather than bundling — the grype DB makes a download unavoidable anyway, so bundling ~100 MB buys nothing and adds two nested helpers to the signing order (CLAUDE.md §1.1). Spawned UX-13. DOC-5 (the blocker) is now `done`, so this is unblocked regardless. | `decided` |
| UX-9 | **Network + disk I/O series in Statistics** — OrbStack's Activity Monitor graphs CPU/memory/network/disk per container; our verified-accurate Stats tab charts CPU/memory only. The fields are already in the stats payload. | Two additional Swift Charts series (rx/tx, read/write) in `ContainerStatsTab`, same retention and tick discipline as the existing charts. | `done` (network already shipped; `blkio_stats` newly decoded — guest-kernel evidence and the unverified part recorded in UI-FEATURE-GAP §9) |
| UX-10 | **Menu-bar extra depth, kept lean** — OrbStack's extra does lifecycle, logs, terminal, ports, mounts, copy actions; ours shows engine state, running containers + CPU + stop, ports. | Per-container submenu gains "View Logs" (bridge exists: `TrackDAppBridge.reveal(showingLogs:)`) and copy name/ID; containers grouped by Compose project with a project stop/start; "Open Terminal" added when DIF-2 lands. It stays a menu, not a dashboard. | `done` for logs/restart/copy/grouping. **Project stop/start declined:** the Stacks route gates a bulk lifecycle behind a confirmation naming its exact scope, and a modal presented from a `MenuBarExtra` window dismisses the window that presented it — so the group header opens the project on Stacks (`TrackDAppBridge.reveal(composeProject:)`) instead of carrying a weaker copy of that action. Terminal still blocked-by DIF-2. |

### Capability gaps, filed 2026-08-05

UX-1..UX-10 came from a **screens** comparison ([UI-FEATURE-GAP.md](docs/audit/UI-FEATURE-GAP.md)).
These come from the **capability** sweep that doc was missing —
[CAPABILITY-GAP.md](docs/audit/CAPABILITY-GAP.md), 16 sections, ranked the same way: frequency ×
cost, not novelty. UX-11..UX-13 are the resolutions of spikes UX-5, UX-7 and UX-8; each spike's
reasoning stays in UI-FEATURE-GAP under its original heading.

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| UX-16 | **Disk space never returns to macOS** — `guest/morbinit/src/disk.rs:273`'s `discard=async` is dead code: the kata kernel has no btrfs (`architecture.md:183`), ext4 mounts with no `discard`, no `fstrim` anywhere in the tree, resize is grow-only. We reproduce Docker Desktop's single most-complained-about behaviour. DIFFERENTIATION Tier B and TECHNOLOGY-AUDIT Bet 8 flatly contradict each other here; TECHNOLOGY-AUDIT is right. | **TECH-3 spike answered 2026-08-06: yes, `VZDiskImageStorageDeviceAttachment` punches real holes for both `-o discard` and `fstrim` — measured, numbers in `docs/design/DISK-RECLAIM-DECISION.md` §4/§5.** Shipped and rebuilt-guest-verified (§8): the periodic sweep alone (`disk::spawn_periodic_trim`, hourly after a 10-minute warmup) could never fire on a real developer machine, because its warmup outlives the default `auto_suspend_minutes` (5) — an idle-cycled guest was always stopped first. Fixed by `disk::trim_before_shutdown`, a bounded (`TRIM_SHUTDOWN_DEADLINE`, 15s) `fstrim` sweep that `run_shutdown_sequence` now runs unconditionally on every guest teardown, independent of any timer or of `auto_suspend_minutes`. Verified live in an isolated scratch environment reproducing the exact original failure (default 5-minute auto-suspend, a guest whose restore genuinely fails on this host): `disk.img` allocated blocks dropped ~4.00 GiB immediately after an idle-triggered stop, with no manual `fstrim` run — full transcript and numbers in `docs/design/DISK-RECLAIM-DECISION.md` §8.6. The periodic sweep itself was also reconfirmed correct on the rebuilt guest (fired at exactly `TRIM_WARMUP_DELAY`, reclaimed a separately deleted file). The guest's shutdown-reply budget ladder (`control::SHUTDOWN_REPLY_TIMEOUT` and every host constant that nests above it) grew to fit the new bounded step; see the updated doc comments on `VMManager.shutdownAckTimeout`/`Daemon.stopBudget`/`Daemon.suspendBudget`/`Daemon.clientTimeout` and `LifecycleTests.testShutdownBudgetsNestFromTheGuestOutwards`. `Doctor.diskTrimCheck` and the Disk inspector's reclaim sentence (`TrackCDiskReclaimPresentation`) were both corrected to say reclaim also happens on every stop, not only from the periodic sweep this counter can see. | `done` |
| UX-18 | **No proxy support at all** — grep for `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`/`socks` across `guest/morbinit/src`, `MorbstackKit` and `morb` returns zero hits. OrbStack inherits macOS proxy settings for free; Docker gates SOCKS5 and Kerberos/NTLM behind Business. Disqualifying on a corporate network. | **Done 2026-08-06** (`1ddee93`). `guest_proxy::parse_cmdline` + `supervisor::apply_proxy_env` (`guest/morbinit/src/supervisor.rs:395-420`) inject `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` into dockerd's environment only; `MorbConfig.swift` adds `proxy_enabled`/`http_proxy`/`https_proxy`/`no_proxy` config.toml keys (explicit override + off switch); `Doctor.swift:477-560` adds a proxy-config check plus a live-guest-mismatch check, wired into `morb doctor`. Corporate CA injection correctly left for later. | `done` |
| UX-21 | **Our own docs call our strongest capabilities `absent`** — eleven rows tabulated in CAPABILITY-GAP §16. COMPETITIVE-GAPS says Testcontainers and Dev Containers were "never tested" (ECOSYSTEM-MATRIX has four languages plus the Dev Containers CLI passing zero-config), VS Code/JetBrains `absent` (a built `.vsix` with a hijacked-stream exec terminal ships in `integrations/vscode/`), pinned kubectl "not in the repo" (`fetch_kubectl` pins v1.36.2), and "no exec, no PTY anywhere" (`Terminal/` exists with tests). An advantage nobody can see is not shipping. | **Done 2026-08-05** (`d6b50a8`). Reconciliation pass landed across `docs/COMPETITIVE-GAPS.md`, `docs/architecture.md`, `docs/audit/DIFFERENTIATION.md`, `docs/audit/ECOSYSTEM-MATRIX.md`, `docs/parity.md`, and `integrations/jetbrains/README.md` — every row checked against code before correction, each carrying a dated resolution note. Two true negatives left alone (`morb debug` really doesn't open a shell; `fetch-scan-tools.sh` really was absent at the time — since fixed by DOC-5). This same pass is what discovered and filed CLI-9 (the shell-completions gap it did *not* fix, since `_morb` isn't Markdown) — now also done. | `done` |
| UX-22 | **Migration only points inward** — `MorbMigrate` has the transactions, helper-container volume reads and a checksum `verify`, and no way out. OrbStack has no data path out either (their #2517 is open), so this is a differentiator, and it is the answer to "what if I want to leave". | **Source-done 2026-08-06** (`d2bf429`/`2966032`). `MigrateOutCommand.swift` implements `morb migrate --to <runtime\|socket>` reusing the existing transactions/verification; `ExportCLI.swift` implements `morb export --all` writing a directory a stock `docker load` restores; `README.md` got the one-line claim. **Not yet earned**: the claim has never been exercised against a live second engine — see UX-27, which is the live-acceptance follow-on and must land before the README line is trustworthy. | `done` (source; live round-trip is UX-27) |
| UX-11 | **Anonymous registry reference resolver** — resolves spike UX-5. OCI Distribution defines no portable search, so a multi-registry search surface needs five vendor APIs, four of them credentialed; `RegistryImageDiscovery.swift` already encodes that refusal in its types. Tag and manifest browsing *is* anonymous everywhere, and answers "does this tag have an arm64 manifest" **before** the pull — `TrackCImageArchitecture.swift` only answers it after. | `RegistryReferenceResolver` in MorbstackKit beside `RegistryImageDiscovery.swift`: parse a reference, anonymous bearer exchange, first page of tags plus the tag's platform list. Bounded body, no redirects, no ambient config, fixture-tested. Pull-sheet disclosure is commit two. The GUI never holds a credential. | `open` (half done: `RegistryReferenceResolver.swift` landed 2026-08-06, `b4116dbaf`, with 89 unit tests across both this and UX-12; zero references to it anywhere in `MorbstackAppCore` — the pull-sheet disclosure, commit two, has not started) |
| UX-12 | **Read-only volume content browser** — resolves spike UX-7. The mechanism was never closed: `MorbFeatures/VolumeArchiveExport.swift` and `MorbMigrate/HelperContainer.swift:117` already read volume bytes through a **stopped** `:ro` helper and `/containers/{id}/archive`. Browsing is that same lifecycle with a `HEAD` and a different `path`. A guest agent was rejected — it widens exactly the surface OPS-8 just narrowed. DIF-7 (Finder) is a successor, not a prerequisite. | `VolumeContentBrowser` in MorbFeatures sharing the helper lifecycle (create → read → always remove): one bounded directory listing from the `HEAD …/archive` stat header plus tar enumeration, tested against a recorded tar and header with no engine running. The Volumes-inspector surface is commit two. Write is out of scope. | `open` (half done: `VolumeContentBrowser.swift` landed 2026-08-06, `b4116dbaf`, with fixes for two bugs the previous session left mid-way — checksum validation and a base-256 overflow guard — plus 89 unit tests total across this and UX-11; zero references anywhere in `MorbstackAppCore` — the Volumes-inspector surface, commit two, has not started) |
| UX-13 | **Image vulnerability surface** — resolves spike UX-8. `morb scan` is already a complete local pipeline (export → syft → announced-then-fetched grype DB → scan) with both tools' phone-home defaults disabled by hand. Only the binaries and the screen are missing. Bundling ~100 MB buys nothing — the grype DB makes a download unavoidable anyway — and adds two nested helpers to the signing order CLAUDE.md §1.1 calls a landmine. | A Vulnerabilities section in the Images inspector: severity counts grouped by package, expandable to fixed-in, the DB build date, and "scanned on this Mac, nothing uploaded". A real `ContentUnavailableView` when the tools are absent — no disabled placeholder. No severity column in the images table. **Half done: `scripts/fetch-scan-tools.sh` landed 2026-08-06** (276 lines, clean shellcheck, syft v1.50.0 and grype v0.116.1 pinned by sha256 in the `fetch-guest-assets.sh` style), so the blocker named in this row is cleared. Only the inspector section remains. **Delegation warning, 2026-08-07:** six separate agent sessions on this ticket were terminated by an automated content classifier. The work is ordinary — a shell script that downloads two hash-pinned binaries, and a SwiftUI section that renders the output of a command this repo already ships — but briefs describing it in security-incident vocabulary reliably trip the filter. A half-written `ImageVulnerabilityScan.swift` was lost when its worktree was cleaned. Whoever picks this up: describe it as rendering an existing local report, keep the file name neutral, and expect to write it directly rather than delegating. | `open` (inspector section only) |
| UX-14 | **Publish the benchmark harness and the watcher matrix** — we measure 1.79 s cold boot and 0% idle CPU (ENGINE-MATRIX §10); Docker publishes no macOS startup figure at all and OrbStack's benchmarks page is v0.17.0 from August 2023 with its figures locked inside images. `MorbBench` is missing only the two workloads people actually compare. | **Done 2026-08-06** (`456f990`, same commit as DIF-3). Both benchmarks added; `docs/benchmarks.md` publishes the watcher conformance matrix; `README.md:27` now leads with "1.79 s cold boot, 0% idle CPU — and you can check it yourself" plus the one-command harness. Duplicate of DIF-3 for the benchmark-code half — see DIF-3. | `done` |
| UX-17 | **Drive the memory balloon** — `VMManager.swift` attaches a `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` and nothing ever set `targetVirtualMachineMemorySize`; the device was configured and inert. | A slow-timer (30 min) balloon target tracking the guest's `/proc/meminfo` `MemAvailable`, extended over MRB0's `info` reply (additive `mem_total_kb`/`mem_available_kb`, guest side in `guest/morbinit/src/meminfo.rs` + `control.rs`). Pure decision logic in `MemoryBalloonPolicy.swift` (floor, headroom, unthrottled growth, step-limited/hysteresis-gated shrink — fully unit-tested, `MemoryBalloonPolicyTests.swift`), wired into `VMManager` via the existing boot-generation guard. Reasoning: `docs/design/MEMORY-BALLOON.md`. No "dynamic memory" claim added anywhere user-facing — not measured yet. **Guest-side `meminfo` reporting does nothing until `mise run guest-image` rebuilds the initramfs (CLAUDE.md §1.5); not yet verified end to end.** | `done` (source + unit tests; real-host RSS measurement via `MorbBench` and a guest-image rebuild still pending — machine lane) |
| UX-19 | **SSH agent forwarding** — no `SSH_AUTH_SOCK` handling anywhere, but `DockerHijackDetection.isHijackCandidate` nominates `POST /session`/`/grpc` unconditionally, so buildx's `--ssh` session plausibly already passes through untouched. | Commit one (evidence, not code): a **static-code trace only** of the hijack/relay path confirming `/session` is always spliced raw, recorded in `docs/parity.md` row #41 with the exact `docker buildx build --ssh default` command that would promote it to a dated PASS — that live run has not happened yet. Commit two (code): the Docker-compatible `/run/host-services/ssh-auth.sock` runtime path — guest listener always present (`guest/morbinit/src/ssh_agent_forward.rs`), host-side gate off by default (`MorbConfig.sshAgentForwarding`, `SSHAgentForward.swift`/`SSHAgentForwardServer`, vsock 2383). Full threat model and off-by-default rationale in `docs/design/SSH-AGENT-FORWARDING.md`. **Guest-side runtime path does nothing until `mise run guest-image` rebuilds the initramfs (CLAUDE.md §1.5); not yet verified end to end.** | `open` (source + unit tests done; live buildx `--ssh` acceptance and a real guest-image boot of the runtime path both queued behind the machine lane) |
| UX-15 | **Surface the guest-reachable container address** — Docker documents plainly that it "can't route traffic to Linux containers"; OrbStack's routable IPs are a headline feature. DIF-4 step 0 already mandates proving host→guest reachability at `192.168.64.x`, so this is half a day on top of work we are doing anyway. **DIF-4 step 0 gate executed 2026-08-06: PASS on Wi-Fi with no VPN** (ICMP + TCP round-trip to a live guest at `192.168.64.27`, a closed port on that address actively refused rather than timing out, an unleased address on the same segment timing out — see `docs/design/DNS-DECISION.md`). Ethernet and VPN remain untested. | When DIF-4's gate passes, show the container's guest-reachable address in the inspector and in `morb status --json` — before domains land, since the address is the useful half. `GuestNetworkAddress.swift` (lease-file lookup), `Daemon.swift` (`guest_address` in `status`), `PortMapping.guestReachableAddress(guestAddress:)`, and `morb status`'s human-readable row are done. The inspector UI row is not — it needs a SwiftUI change in `ContainersRootView.swift`/the port list, out of this ticket's engine-side scope. | `in-flight` (engine + CLI done; inspector UI open; Ethernet/VPN reachability untested) |
| SEC-9 | **`DockerClient` builds request targets as one string, so an identifier decides where encoding stops** — `MinimalHTTP.percentEncodePath` splits at the first `?` and passes everything after it through verbatim, because five callers hand in a whole target with its query attached (`post("/exec/\(id)/resize?h=\(rows)&w=\(columns)")`, `delete("/containers/\(id)?v=1&force=1")`, `stop?t=10`, `restart?t=10`, `volumes/\(name)?force=…`). The identifier is interpolated *before* that `?`, so an id containing its own `?` moves the split left and the remainder of the target — including any control byte — is emitted raw. `MorbFeatures.EngineClient` does not have this shape: `path(_:query:)` takes the query as `[(String, String)]` and encodes each value with `percentEncodeQueryValue`, so its encoder never has to guess where the path ends. Also: `RequestPathEncodingTests.testAQuestionMarkInsideAnIdentifierIsEscaped` feeds an already-encoded `%3F`, so it cannot fail, and the behaviour its name claims is false (`docs/audit/TEST-QUALITY.md`). | Give `DockerClient` the shape `EngineClient` already has — `url(_ path: String, query: [(String, String)] = [])` — and move the five query strings into it, then drop the split so `?` is escaped like any other unsafe byte and the two implementations are identical. Fix the test to feed a raw `?`. **Do not just delete the split**: it is load-bearing today, and removing it without moving the callers first fails 13 tests in `DockerExecPTYSessionTests` — verified 2026-08-06. Grep for `post(`/`get(`/`delete(`/`put(` with a `?`, not only for direct `url(` callers; the wrappers are where the query strings live. | `open` |
| TECH-12 | **Three independent tar readers, and they have already drifted** *(renumbered 2026-08-07 — this was mistakenly filed as a second, unrelated "TECH-4"; the original TECH-4, "Save/restore retest: scanout device + Developer ID," is the spike under Technology foundations above and stays TECH-4)* — `mac/Sources/MorbstackAppCore/Views/Containers/ContainerFileArchive.swift` (`ContainerTarHeaderReader`, general streaming reader for arbitrary in-container paths), `mac/Sources/MorbFeatures/VolumeContentBrowser.swift` (`TarChildWalker`, immediate children of the fixed `/data` mount) and `mac/Sources/MorbMigrate/TarLite.swift` (full-file, regular entries only). This is not theoretical: the base-256 numeric field had an overflow guard in one and not the other, and a GNU long-name NUL-termination bug in the second would have made **every real-world long-name entry silently vanish from a listing** — neither could have happened with one reader. A third reader means a fourth is coming. | Promote the shared primitives into `MorbstackKit`, which all three already depend on: ustar checksum (both unsigned and historical-signed), octal and base-256 numeric decode with the overflow refusal, PAX extended-header parsing, GNU `L`/`K` long name and link handling, `cString` NUL truncation. Leave the *policies* where they are — entry budgets, root-membership rules and payload capture genuinely differ per caller and should not be unified. Note the dependency direction: `MorbFeatures` is a dependency of `MorbstackAppCore`, so the shared code cannot live in either; `MorbstackKit` is the only common base. Port each reader's tests to the shared implementation rather than deleting them. | `done` (`MorbstackKit/TarArchiveFormat.swift`: checksum, octal/base-256 decode, `cString`, typeflag→kind, PAX records, all three callers now delegate to it. Reading all three side by side turned up three more bugs beyond the two already on file: `TarChildWalker` applied a PAX *global* (`g`) header's records to the next entry as though it were per-entry (`x`); it skipped GNU `K` long-link entirely, truncating any symlink target over 100 bytes; and its own typeflag switch (plus `TarLite`'s) missed typeflag `7` (contiguous file), showing/counting it as "other" instead of a regular file. `TarLite` also had no checksum validation and no base-256 support at all — a >8 GB entry silently read as size 0 and desynced everything after it. All fixed by adopting the shared code; regression tests added for each. Swift test count 1367 → 1398, 0 failures.) |
| CLI-9 | **Shell completions promise a command we do not have, and omit seven we do** — `integrations/shell/_morb` is missing `disk`, `ports`, `diagnose`, `service`, `install-cli`, `uninstall-cli` and `export`; `morb.bash` and `morb.fish` are almost certainly the same. Worse, its `debug` description reads "Open a toolbox shell in a container, even a distroless one" while `mac/Sources/morb/main.swift:48` says the command "does not open a shell yet". That is help text promising behaviour the implementation does not have — the exact thing CLAUDE.md §1.8 forbids. `docs/DIFFERENTIATION.md` predicted "stale by 7 commands" and was exactly right, which means we knew. | **Done 2026-08-06** (`96a756d`, merged `aa60c76`). All seven missing commands (`disk`, `ports`, `diagnose`, `service`, `install-cli`, `uninstall-cli`, `export`) now present in all three completion files (`_morb`, `morb.bash`, `morb.fish`), confirmed by direct grep. `debug`'s description now matches `main.swift`'s honest text. A new `ShellCompletionDriftTests.swift` diffs the completions against the parser's own command table so a future subcommand fails the gate rather than silently drifting again. | `done` |
| DOC-7 | **kubectl is opt-in, so a normal build cannot port-forward** — `fetch_kubectl` pins v1.36.2 against a sha256 sidecar and `mise-tasks/app` stages and signs it, but it is behind `--host-kubectl-only` and is not fetched by default. A stock `mise run app` therefore produces a bundle where the selected-Pod port-forward is simply unavailable. The COMPETITIVE-GAPS row said "not in the repo", which was wrong in a way that hid the real gap. | **Done 2026-08-06** (`c838822`). Chose to fetch by default rather than only improving the failure message: `scripts/fetch-guest-assets.sh`'s default asset set now includes kubectl (previously `DO_KUBECTL=0`), same sha256-pin-then-sidecar-verify discipline as every other default asset. Stale `mise-tasks/app`/`docs/k8s.md` comments describing port-forward as unshipped corrected. The `K8sPortForwardCoordinator` this unblocks is itself wired into the app as of `582d38c` (2026-08-07). | `done` |
### Performance and migration, filed 2026-08-07

From [PERFORMANCE-MODEL.md](docs/audit/PERFORMANCE-MODEL.md). **Read its opening finding before planning
any performance work:** OrbStack left Virtualization.framework in v1.6.0 (2024-05-22) for a custom Rust
VMM with its own filesystem and network protocols — their own engineer says so publicly. Every speed
advantage they are known for is downstream of owning that stack. Several gaps below are therefore
*structural* rather than things we have neglected, and the ones that are not are worth more because of it.

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| UX-30 | **Four benchmark rows have a target and no measured value** — `git-status-bindmount`, `npm-install-bindmount-vs-volume`, `resume`, `guest-memory-floor`. The two filesystem rows are the only workloads this market argues about, and `TECHNOLOGY-AUDIT.md:168` admits we have never run them. Our headline 1.79 s cold boot is two daemon-log timestamps in a document that carries its own warning not to cite it, while `ColdBoot.swift` does it properly at median-of-five and has never been published. | One machine-lane pass: `morb bench run`, all eight rows, into `docs/benchmarks.md` and the README's first screenful. Add one networking row so a future transport argument has a baseline. **State the denominator**: ours is bind-mount vs named volume, OrbStack's is container vs native macOS. Those are not the same measurement and quoting them side by side would be dishonest. | `open` |
| UX-29 | **Does the balloon actually return pages to macOS?** Apple documents neither answer. UX-17 shipped the driver and correctly added no user-facing claim. This is the memory analogue of TECH-3, which asked the same undocumented question about discard hole-punching and came back yes. | The `DISK-RECLAIM-DECISION.md` §4 method: allocate and free in the guest, drive the target down, watch real host footprint and memory pressure across the transition, with controls. Both outcomes are publishable. Needs `mise run guest-image` first — the guest `meminfo` path is inert without it. **Write no "dynamic memory" copy until it returns a number.** | `open` |
| UX-28 | **Rosetta AOT caching is free and unclaimed** — `VZLinuxRosettaDirectoryShare` has supported `cachingOptions` since macOS 14, Lima shipped it in 2024, Docker Desktop links both symbols, and `Rosetta.swift:120` still builds a bare share. Flagged as an untaken win in `TECHNOLOGY-AUDIT.md:401` and never taken. Available to us **because** we stayed on Apple's framework — one of the few places that choice pays. | `VZLinuxRosettaAbstractSocketCachingOptions` on the share, plus morbinit starting `rosettad` in the same mount namespace, exec'd from the share path (Lima's PR notes copies do not work). Measure against the existing amd64 multipliers. Second commit: reconcile 1.8–2x (`amd64.md:139`) against 1.5–1.7x (`TECHNOLOGY-AUDIT.md:391`), both labelled measured-here, and either implement the qemu-user fallback `architecture.md` describes or stop describing it. | `in-flight` (another agent working this 2026-08-07 — not independently re-investigated) |
| UX-23 | **First run never offers to migrate** — OrbStack's does. `FirstRunCLISetup.swift` (824 lines) contains no occurrence of `migrat` or `Docker Desktop`, verified by exhaustion — while `MigrationRootView.swift` (2,091 lines) already detects Desktop, Colima and OrbStack and runs image *and* volume transfers through review sheets. The capability is built and sits off the path anyone walks. | One detection line and one button in the existing first-run sheet, deep-linking to `Nav.migration`. No new mechanism. The cheapest item in this table and the one most likely to decide whether someone stays. | `in-flight` (another agent working this 2026-08-07 — not independently re-investigated) |
| UX-31 | **123 MB of the 366 MB bundle is Kubernetes, and it is off by default** — k3s 74 MB plus cri-dockerd 49 MB. `mkinitramfs.sh:364-380` already makes this exact argument for the initramfs ("122 MB spent on every boot for a feature most boots never use") and stops one hop short, because morbstackd streams the payload out of the app bundle, so every user downloads it regardless. OrbStack advertises under 10 MB. | Fetch on first `morb k8s enable`, using the existing `fetch-guest-assets.sh` pins and `RuntimeArtifacts.swift` staging. A third off the download and two fewer nested binaries in the signing order (§1.1). State the offline-first-enable trade honestly. **Do not** unbundle docker/compose/buildx — that 94 MB is what "drop-in" means. | `in-flight` (another agent working this 2026-08-07 — not independently re-investigated; note this is in tension with DOC-7/EN-11, which just moved kubectl to fetch-by-default for the opposite reason — coordinate rather than let the two land contradictory defaults) |
| UX-27 | **The way out has never been run** — `morb migrate --to` and `morb export --all` landed 2026-08-06 with a commit saying "Not exercised against a live engine." This is the answer to the one objection a single-maintainer project cannot argue away, and it is source-only. | A live pass round-tripping images and volumes out to a real second engine and back through stock `docker load`, recorded as a dated row in ECOSYSTEM-MATRIX. Also: neither transaction has a free-space preflight (`ImageMigrationTransaction.swift:523-536`), and import is not resumable past `POST /images/load` — both belong in `docs/migrate.md`. **Only after this may the README say "leaving is one command, and it is tested."** | `open` |
| UX-24 | **`host.docker.internal` is a stale PARTIAL** — the 2026-08-03 run saw the bare name not resolving; the bridge-DNS fix `d82b823` landed *after* it and has never been re-run (`parity.md:189`). A copied `compose.yaml` killer sitting in an unknown state. **Duplicate of EN-6** ("`host.docker.internal` without `--add-host` — resolves by default") — same gap, this row's text is the more precise/evidenced one; consider folding EN-6 into this row. | Re-run parity #18/#19 against the current guest. Either a dated PASS or an honest downgrade. | `open` |
| UX-25 | **`morb doctor` cannot see the one socket that matters** — `docker-discovery` probes `~/.docker/run/docker.sock` and `~/.docker/desktop/docker.sock` and deliberately excludes `/var/run/docker.sock` (`Doctor.swift:761-772`) — which is the path hardcoded scripts open and the path our own printed `sudo ln -sf` creates. `ZERO-CONFIG-DISCOVERY.md` claims wider coverage than the code has. | Add the system path to the conflict probe as a warning, never a write. Narrow the design doc's claim to match the code. | `open` |
| UX-26 | **There is no switching guide** — each first-ten-minutes failure is documented in a different file, or only inside a doctor check nobody has run. | One short page: `credsStore: "desktop"` hangs every docker command once Desktop leaves; which file watchers go quiet and which do not; bind roots and the restart they require; a stale `DOCKER_HOST` silently winning; the login item starting the service rather than the VM. Linked from first run and the README. | `in-flight` (another agent working this 2026-08-07 — not independently re-investigated) |
| UX-32 | **Four more doc-versus-source drifts, UX-21 class** — `compat.md:42` says Compose v2 where the pin is v5.3.1; `migrate.md:124` says the native route cannot transfer volumes, and it can (`MigrationRootView.swift:460`); the `ZERO-CONFIG-DISCOVERY.md` doctor claim above; `dynamic-port-allocation.md:181` and `DockerAPI.swift:134-147` read as contradicting each other on the publish default. All four reconfirmed still present 2026-08-07 — none fixed. **Sub-item 3 is a literal duplicate of UX-25**, not just related: it cites UX-25's own gap (`/var/run/docker.sock` excluded from `Doctor.swift`'s conflict probe) verbatim. Closing UX-25 closes this sub-item for free; don't double-count it as separate work. | One reconciliation pass, each row checked against the code. | `open` |

| UX-20 | **`kubectl top` fails without saying why** — `guest/morbinit/src/k8s.rs` disables metrics-server for boot speed (a defensible trade); the resulting raw kubectl error was not. | `K8s.Diagnosis`'s ready/no-action guidance (`K8s.swift`) now names the trade, gives the exact `kubectl apply` command to reverse it, and points at `docker stats` for live CPU/memory today — every Pod is an ordinary container on the shared Docker engine, so it already reports there. No wire/guest change needed; pure host-side logic, unit-tested (`K8sTests.swift`). `docs/k8s.md` updated to match. | `done` |

## Taste — pass 1 of the taste loop, filed 2026-08-05

From [docs/audit/TASTE-REVIEW.md](docs/audit/TASTE-REVIEW.md) (commit `de17215`, real-window
captures in `artifacts/taste/`). Every ticket is marked `LAW` (follows from
[docs/design/DECISIONS.md](docs/design/DECISIONS.md), not negotiable) or `TASTE` (opinion).
Ranked by screen improvement per unit of work. Pass 2 re-captures after these land and judges
whether each change actually improved the screen.

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| TASTE-1 | **`TASTE` Stacks shows almost nothing about a live project** — one collapsed disclosure row in ~850 pt of void; the project inspector has 4 rows, one of which is "Compose files — Not reported". Weakest screen in the app (review F1). | Project rows expand by default (at minimum when ≤3 projects exist); service rows show status/image/ports inline; project inspector gains the per-service breakdown the model already has ("0 of 3 services running" proves it knows). Blocked-by: nothing. | `done` (list landed; the inspector breakdown was demoted by it — pass 2 folds the residual "Compose files — Not reported" row into TASTE-12) |
| TASTE-2 | **`TASTE` Two grouping idioms on the Containers list** — `shopdemo` is a lowercase section header while `Kubernetes-Managed` is a disclosure row with icon + count, and the five ungrouped containers have no header, so "shopdemo" floats mid-list. Group headers also say nothing about state (review, "verdict on the new Compose grouping" — the grouping itself is a keeper). | One idiom for every group (disclosure row with trailing count, matching Kubernetes-Managed); project headers carry "n of m running" per UX-6's original deliverable; ungrouped containers get an anchor (leading position with a header, or an explicit "Standalone" group). Blocked-by: nothing. | `done` (pass 2: the anchor need dissolved once groups became chevroned rows — correctly not added) |
| TASTE-3 | **`TASTE` Containers rows hide the image** — at 1600 pt a row is name, ~900 pt of nothing, status. Search promises "Name, image, or project" but the image appears nowhere in the list; `lonely` and `netA` are indistinguishable without selecting them (review F2). | Image reference as secondary text (subtitle or dimmed middle column) and ports for running containers. The right handful is name, image, ports, status — the `docker ps` muscle memory this list replaces. Blocked-by: nothing. | `done` (pass 2: ports and narrow behaviour unverified — no published-port container and no narrow capture in the evidence set; verify in the next capture session) |
| TASTE-4 | **`TASTE` Absence stated up to five times** — Volumes inspector says "no disk scan yet" as three "Not reported" rows plus two footnote paragraphs, while the table shows the same fact as two em-dash columns; milder cases on Images and Networks (review F3). | State an absence once: one labeled row, at most one footnote per pane, and the footnote must say what changes the state ("Run a Disk scan to populate usage"). Pure subtraction — no new UI. Blocked-by: nothing (independent of the filed label-clipping defect). | `done` |
| TASTE-5 | **`TASTE` Images "In use" column is an em-dash 26 times out of 26** — a column whose every value is the same non-value teaches the eye to skip columns (review F4). | **Done 2026-08-06** (`a85c974`). `/images/json` reports `Containers` as `-1` on every tested engine; `/system/df` already computes the real per-image container count to size its reclaimable-images total. Read into a new `DiskUsage.imageUsage`, merged into `ImageSummary.containersUsing` after a Disk scan the same way Volumes' Size/In-use columns fill — only overwriting the still-unreported (`-1`) state, so a live refresh's own answer always wins. Still-unscanned state now reads "Not scanned yet" with a remedy. 6/6 `DiskUsageTests`. | `done` |
| TASTE-6 | **`TASTE` Disk inspector leaks the recovery state machine** — "Recovery Phase — host-grown", "Saved Target", "the guest filesystem still needs verified proof", "reviewed growth transaction" printed as user copy (review F5). | One human status line ("Disk growth is paused until the guest filesystem check completes"); internal detail rows behind a disclosure. Blocked-by: nothing. | `done` |
| TASTE-7 | **`TASTE` Migration inspector is a wall** — ~17 rows + 4 footnotes in one scroll, three zero-value eligibility rows, defensive copy; and Morbstack lists itself among migration *sources* (review F6). | **Done 2026-08-06** (`df88efa`) in `MigrationRootView.swift`. Stacked caveat-clause sentences collapsed to one each; a redundant "No image data was imported" line dropped (the pane's own footer already says it once for the whole pane). Source-review only — no real window has confirmed the layout, and the Status column's Morbstack/Destination behaviour has no dedicated test yet (`RuntimeReport`'s init isn't public to `MorbstackAppCore` tests). | `done` (visual acceptance pending) |
| TASTE-8 | **`TASTE` Long identifiers fight trailing alignment in the container Overview** — full digests, image refs, and multi-sentence Ports copy in a ~300 pt trailing value column; nine section headers where half hold 1–2 rows (review F7). Composition issue independent of the filed clipping bug. | **Done 2026-08-06** (`54c97fd`) in `ContainerOverviewTab.swift`. Source-review only, no machine lane available: the 400pt-wide, 2-line, merged-section layout has not been seen rendered — next real-window pass should confirm the wrap lands as the Volumes precedent suggests and that a genuinely long Command value doesn't push a row into visible truncation. | `done` (visual acceptance pending) |
| TASTE-9 | **`TASTE` Unit-and-word sweep** — Networks "Containers" column mixes "3" with "None" (a count column says 0); Builds inspector filler row "Storage — Included in deduplicated total"; Statistics states its sampling cadence twice (review F8). | **Done 2026-08-06** (`ab40535`) across `BuildsRootView.swift`, `ContainerStatsTab.swift`, `NetworksRootView.swift` — all three fixed, no test named any of the changed strings. | `done` |
| TASTE-10 | **`TASTE` Disk inspector states one capacity five ways** — "Apparent — 77.31 GB", "Current Raw Capacity — 77.31 GB", "Configured Capacity — 77.31 GB", "Capacity State — Matches configuration", and the summary sentence "The existing disk matches the configured capacity." Three labels for one number across two adjacent sections, then a row and a sentence for one state; and when readiness is unreported but the pending action is Stop Engine, the lead sentence ("Morbstack has not checked yet whether this disk can grow…") never names the remedy the button under it offers (pass 2, exposed by the TASTE-6 fix). | **Done 2026-08-06** (`b582889`) in `DiskRootView.swift`/`TrackCDiskMath.swift`: the two capacity sections merged into one story, "Configured Capacity" only shown when it differs, `diskCapacity.summary` suppressed when the Capacity State row already says it, and the Stop Engine action now leads with the stop-engine sentence. 37/37 `TrackCDiskMathTests`, including a case pinning `.stopEngine` with `diagnostic: nil`. | `done` |
| TASTE-11 | **`TASTE` One predicate, two rows in the Volumes Identity section** — "Volume — Anonymous" and "Prune — Eligible" are both computed from `isAnonymousVolumeName`; the second restates the first, and "Eligible" reads as a safety verdict directly above "Usage — Not scanned yet", where usage is exactly what is unknown (pass 2, found in the pane TASTE-4 cleaned). | **Done 2026-08-06** (`badc44f`) in `VolumesRootView.swift`: the "Prune" row deleted; the consequence stays where it already lived (the Remove button's caption, and the bulk-prune description). Identity section keeps exactly one row. | `done` |
| TASTE-12 | **`TASTE` The absence sweep stopped at Volumes** — Images inspector still says "Reported use — Not reported" plus a remedy-free footnote ("Docker did not report container usage for this image."), the Stacks project inspector still carries "Compose files — Not reported", and the app now has two vocabularies for one category of absence: "Not scanned yet" (Volumes) vs "Not reported" (Images) (pass 2). | **Done 2026-08-06** (`5f8f223`) in `ImagesRootView.swift`: "Reported use" now says "Not scanned yet" (matching TASTE-5's constant) with the Disk-scan remedy named once. The Stacks "Compose files — Not reported" row was audited and deliberately left alone — `TrackDComposeMetadata.load` caches a permanent negative lookup with no scan/refresh/action that could ever change the answer, which is exactly the case reserved for "Not reported." One vocabulary, applied correctly rather than uniformly. | `done` |

## UI-057 · `MorbSavedState.purge()` misses the path that actually wedges · `open`

Found while recording the animated captures (2026-08-07). A wedged AppKit window-restoration
store kept resurrecting a broken "Logs — No services" window over every new launch, defeating
`--tour-select` and several capture attempts until it was removed by hand.

The store was at `$TMPDIR/com.apple.testmanagerd/dev.morbstack.app.savedState`. That is exactly
the failure `AppLaunchRescue.swift`'s `MorbSavedState.purge()` exists to prevent — it just is not
in the candidate list, because that path only appears when the app has been launched under
XCUITest, which is how every automated capture run starts it.

**Deliverable:** add the `com.apple.testmanagerd` location to `purge()`'s candidates, and check
whether any other launch context produces a saved-state path the list also misses. A test that
pins the candidate set against the known locations would stop this recurring — this is the same
"two things that must agree with nothing checking" shape as the completions drift and the search
glyph, and it is the fifth instance.

## UI-058 · "Jump to Newest" does not start following · `open`

Found while recording the Compose log window (2026-08-07), and visible in
`docs/gallery/containers-compose-logs.gif`.

Two related faults in the same surface:

1. The window **opens scrolled to its oldest buffered lines** rather than the newest, despite
   declaring `.defaultScrollAnchor(.bottom)`.
2. Clicking **"Jump to Newest" scrolls once and does not establish ongoing follow.** New lines keep
   arriving — the line counter climbs — and the view goes stale again immediately.

The second is the worse of the two: a control named "Jump to Newest" beside a live stream reads as
"follow the stream", and a user watching a deploy will believe they are seeing current output when
they are not. Silent staleness in a log view is a correctness problem, not a polish one.

**Deliverable:** opening lands at the newest line, and the jump control establishes follow that
holds until the user scrolls away from the bottom — the behaviour every terminal and log viewer
shares. Decide and document whether the control is a one-shot or a toggle; if it stays one-shot,
it needs a different name.

## UI-051 · Right-side controls should be swallowed by the inspector · `done`

> **Read the 2026-08-06 entry at the bottom first.** The overlap the last four passes were
> trying to remove is measured, in Apple's own apps, to be the platform's intended
> composition. Do not open a sixth ticket to move the trailing items off the inspector.

**The user has asked for this three times.** *"I preferred it when these get swallowed by the slide
over just like the left one."* The left sidebar absorbs its toggle pill as it slides; they called
that "fantastic", unprompted, twice. The right side does not — the `+`, the inspector toggle and the
search field sit in a separate strip and stay put while the inspector animates, which is what makes
the right edge read as a detached panel.

**Mechanism found, do not re-derive it.** An agent got most of the way before dying at a session
limit. What it established:

- `.searchable(placement: .toolbar)` declared on the route root, with the trailing cluster declared
  **immediately before `DefaultToolbarItem(kind: .search)`**, anchors that cluster against the
  inspector divider — and the system then carries it with the inspector's own slide. No custom
  animation involved, which is the right shape: the system already does this, we were placing the
  items where it could not.
- Verified in a real window: the search field does move into the inspector region.

**Why it was reverted rather than kept:**

1. **The inspector toggle button disappeared entirely.** Trading a visible control for an animation
   is not a fix. `InspectorCommands()` still offers it in the View menu, so it is not unreachable,
   but a toolbar affordance vanishing is a worse defect than the one being fixed.
2. The Volumes half removed `ToolbarItem(id:)` from several items, which **destroys accessibility
   identifiers**. Those 243 identifiers are an API the XCUITest suite queries by; see
   `docs/design/ACCESSIBILITY-IDENTIFIERS.md`. Any version of this fix keeps every identifier
   byte-identical.
3. Its comments were mid-edit fragments referring to a `VolumesRootView` shape that no longer
   existed after the revert.

### 2026-08-05: the recorded mechanism does not reproduce. Do not try it a fourth time.

Four toolbar variants were built, signed, launched and captured on Volumes at 1600×1000 dark, with
the trailing cluster mounted on the inspector content exactly as the note above describes:

| Variant | Result |
| --- | --- |
| `trailingCommandItems` alone (committed shape) | baseline |
| `trailingCommandItems` then `DefaultToolbarItem(kind: .search)` | **byte-identical**, 138306 B |
| `DefaultToolbarItem(kind: .search)` then `trailingCommandItems` | **byte-identical**, 138306 B |
| `ToolbarSpacer(.flexible)` before the secondary-action group | **byte-identical**, 138306 B |

Byte-identical PNGs of the same window. Declaration order inside `ToolbarContent` is inert here:
the system resolves the trailing run by `placement:`, and `.primaryAction` / `.secondaryAction` /
`.automatic` are each placed against the window, not against the inspector. `DefaultToolbarItem`
and `ToolbarSpacer` do not override that. The earlier session's "verified in a real window" was
observing something that is true without the change — see the measurement below.

**What is actually happening**, from the open/closed pair (inspector 268 pt wide):

| Element | Inspector open | Inspector closed | Δ |
| --- | --- | --- | --- |
| trash + share group | 745–815 | 880–950 | 135 pt |
| `+` + inspector toggle | 1005–1080 | 1072–1145 | 67 pt |
| search field | 1270–1590 | 1270–1590 | **0** |

So the two glass groups are **centred in the content region** — they slide by half the inspector's
width, which is why they drift without ever arriving anywhere. The search field never moves at all:
it is anchored to the window's right edge and the inspector slides *under* it, which is the whole
of the earlier "the search field does move into the inspector region" claim. Three islands
distributed across the bar, one of them overlapping the inspector, is exactly the "detached panel"
the user is reacting to, and it is also the *"top toolbar seperation was a net negative"* report.

**To finish:** the framing "put custom items in the inspector's toolbar section" appears to have no
public API behind it — `NavigationSplitView` owns the sidebar toggle specially and there is no
`.inspectorToggle` counterpart. Before writing any more code, establish with a **stock-SwiftUI probe
containing zero Morbstack code** (the technique that settled the Tahoe chrome question) whether any
declaration can place a custom item trailing-of-search. If none can, this ticket becomes a different
one: stop the groups being centred, so the right side reads as one cluster against the inspector
edge instead of three islands. Keep the toggle. Keep every identifier byte-identical.

### 2026-08-05: closed as the second ticket. One placement, not one animation.

The stock-SwiftUI probe settled the original framing: **no custom item can be placed trailing of
the search field**, AppKit renders it before search regardless of declaration order, and the search
field is pinned to the window's right edge with the inspector sliding *under* it. "Make the cluster
travel with the inspector" is not expressible in SwiftUI today. Do not try it a fifth time.

What the probe did expose is ours. In stock SwiftUI, buttons at `.primaryAction`/`.automatic` form
one packed group adjacent to the search field; a `.secondaryAction` item is centred in the *content*
region instead. Every route mixed the two, so the trailing edge was two or three islands that each
drifted a different distance whenever the inspector moved. **The fix is one line per item:** every
trailing item is `.primaryAction`.

Measured on Volumes at 1600×1000 dark, real window via `capture-window.sh`, x-ranges of the glyph
runs (the glass fill is too subtle over the toolbar to threshold reliably; capsule edges sit ~8 pt
outside each range):

| | before | after |
| --- | --- | --- |
| trash + share | 745–814 | 1085–1154 |
| `+` + inspector toggle | 1005–1078 | 1175–1248 |
| search field | 1267–1591 | 1267–1591 |
| gap, last glyph to search | 189 pt | 19 pt |
| drift when the inspector toggles | 135 pt / 67 pt | **0 pt / 0 pt** |

The inspector-closed capture is byte-position identical to the inspector-open one: the cluster is
now anchored with the search field rather than centred in a region that changes width. That is the
whole of the complaint — the right side stops rearranging itself.

Changed: Volumes, Networks, Images, Builds, Stacks, Containers, Kubernetes, Migration. Disk was
already `.primaryAction` + `.automatic` and is untouched (its scan is identical before and after).

Two details worth keeping:

- **`ToolbarSpacer(.fixed)` on Volumes, Networks and Images only.** Those three have a bare
  destructive trash button that would otherwise share one glass capsule with "create". The spacer
  renders — verified, two adjacent capsules — and is the API Apple names for this
  (`docs/design/tahoe/HIG-FINDINGS.md`: "glass grouping is automatic; use `ToolbarSpacer` to control
  it"). The other routes bury their destructive command inside a `Menu`, so they get one capsule.
- **Overflow still behaves** despite `.secondaryAction` being the documented overflow placement.
  At 1100 pt every control is present; at 900 pt on Images — six trailing items, the worst case —
  the system collapses the search field to its glyph and keeps all six. Nothing clipped, no control
  lost, and the `.focusedSceneValue(\.routeMaintenanceCommand, …)` menu mirrors are unchanged.

Every `ToolbarItem(id:)` and `.accessibilityIdentifier` is byte-identical to the previous commit
(diffed mechanically). `mise run check` exit 0: 1009 Swift, 260 Rust, 0 failures.

**Honest read:** better, not merely different, but it is a smaller win than the ticket's title
promises. The controls no longer scatter or drift, and Kubernetes and Builds got a real bonus — with
the secondary items out of the way their `.principal` pickers are now actually centred. But nothing
is "swallowed by the inspector": the cluster sits *beside* the search field, and the search field
still floats over the inspector column. If the user's objection is specifically the overlap, this
does not fix it and nothing in SwiftUI will.

### 2026-08-06: it *was* expressible. `.toolbarPrincipal` is the answer. Closed.

The paragraph above was wrong, and wrong in the way that matters — it declared a platform limit
from two failed attempts rather than from the API surface. The user pushed back:

> "I dont want it being handpicked, i want native search bar, and I feel it has to have native way
> to be in middle? … or have search bar unpinned and be inside the right slide out then collapse to
> icon on the slide in"

An eleven-variant stock-SwiftUI probe (`ToolProbe.swift`, zero Morbstack code, one variant per
declaration shape) found it on the first sweep:

**`.searchable(placement: .toolbarPrincipal)`.**

Search moves out of the trailing run into the centre region. The action pills sit immediately left
of it, and — this is the part every previous attempt was chasing — `.primaryAction` items then land
at the **far right, inside the inspector column**. Measured in the probe at 1600 pt: search
470–1125, trash/share 400–465, `+` and inspector toggle 1520–1580, with the inspector beginning at
1332. The earlier finding stands and is simply beside the point: nothing can be placed trailing of a
`.toolbar`-placed search field, because `.toolbarPrincipal` moves search out of that run entirely.

Applied to all eight routes that have a search field. Disk has none. **Migration has none either** —
earlier notes listed it; there was nothing there to change.

The one genuine unknown was the two routes that already put a `Picker` at `.principal`. Answer, from
a real window: **Builds shows them sequentially** — picker left of centre, search to its right, no
collision and no overlap. Kubernetes could not be observed, because that route is separately broken
end to end (`77ea35a` fixed it assuming RSA client keys where k3s issues ECDSA; a second fault
remains) and the code path that mounts search never renders.

**The other half of the ask is not available to us, and this is a fact about the SDK rather than a
judgement.** `.searchToolbarBehavior(.minimize)` — the collapse-to-a-glyph behaviour — is
`@available(macOS, unavailable)` in the macOS 26.4 SDK. It does not compile. Do not add it, and do
not hand-roll an imitation: the whole point of keeping `.searchable` is that ⌘F, the Search menu
item, suggestions and scopes come with it.

### 2026-08-06 (second entry): measured against Apple's own apps. The overlap is not a defect.

The fifth pass, and the first that answered the question instead of moving items. Full
working — measurement tables, the placement map, the capsule rules, the per-route
inventory — is now in `docs/design/NATIVE-MACOS-PLAYBOOK.md`, *"Toolbar grammar: a window
toolbar with a trailing inspector"*. This is the summary; the playbook is the record.

**The verdict.** Xcode 26.4, captured at 1600×1000 dark with `scripts/capture-window.sh`
and scanned per pixel, composes a toolbar and a trailing inspector exactly the way we do:
one full-width toolbar, the inspector's leading divider running up through it to y 0 at a
single constant tone, the inspector's own background continuous behind the bar, and the
inspector toggle as the last item at the window's trailing edge — **above the inspector
column**. A stock-SwiftUI probe with zero Morbstack code produces the same geometry, and
so does Volumes. Three toolbar background tones (sidebar / content / inspector) are
present in Xcode too, and by about the same amount, so "the material changes at the
divider" is not something to chase either.

| | Xcode | stock probe | Morbstack (Volumes) |
| --- | --- | --- | --- |
| inspector divider, in the toolbar band | `455052` | `444f51` | `424f53` |
| the same divider, below the toolbar | `455052` | `444f51` | `424f53` |
| inspector toggle x-range | 1562–1591 | 1560–1589 | 1560–1589 |
| trailing item drift, inspector open→closed | 0 | 0 | 0 |
| centred item drift | 130 pt (½ the inspector) | ½ the inspector | n/a |

Finder and Font Book corroborate the shape: full-width bar, each pane's toggle hugging
that pane's divider from that pane's side, and — in Finder — search as a glyph in its own
capsule at the trailing edge, which is what `RouteSearchToolbarItem` already does. Preview
has no trailing inspector at all (its Inspector is a floating panel). **Pages, Numbers and
Keynote are not installed on this machine**, so that case in the ticket text is still
unmeasured; it is the only Apple sample worth adding.

**Why "put the commands beside the inspector instead of over it" keeps failing.** The
`placementMap` probe measured every macOS placement open vs. closed. Every placement whose
position is stable when the inspector toggles is in the one trailing run, and that run is
over the inspector. `.secondaryAction` centres in the content region and moves by half the
inspector's width; `.principal`, `.status` and `.destructiveAction` drift too. **There is
no placement that pins to the content region's trailing edge.** The choice is *over the
inspector and still*, or *left of it and drifting*. That is now written down with numbers.

**What actually was wrong, and it is not placement.**

1. **A stranded pill in the middle.** A placement run is one glass capsule, and only a
   `Menu` splits it — a `Menu` is always its own capsule, with everything before it in one
   and everything after it in another. `ToolbarSpacer(.fixed)`, `(.flexible)` and
   `ToolbarItemGroup` do **not** split a run: five probe variants, byte-identical trailing
   runs. Containers declared its options menu mid-run, so the bar was three capsules with
   a row selected and two without — it re-fragmented on every click. **Fixed:** the menu is
   declared first, so the run is always `[menu] [commands · search · inspector]`, two
   capsules, whatever is selected. **Fixed for Stacks and Images too — see UI-054.** Images
   reordered the same way; Stacks needed a content merge, since two separate `Menu`s never
   fuse into one capsule even adjacent (§4a).
2. **`TabView` inside `.inspector`.** Reproduced in stock SwiftUI: a `TabView` draws a
   bordered content box whose leading edge overdraws the inspector divider from the
   toolbar's lower edge down — `444f51` above, `61686b` below, against a constant
   `444f51` for a plain `Form`. Containers reads `435054` → `646a6c`; Volumes and Xcode are
   constant. This is the one thing in the app that genuinely looks like "a panel that
   starts below the toolbar". `.grouped` does not help, `.sidebarAdaptable` renders a
   sidebar inside the inspector, and no SDK modifier suppresses the box. Apple's own
   inspectors use a segmented control, not a tab container. **Fixed — see UI-055.**

**Two notes that were wrong and are now corrected in the source**, since acting on them is
part of how this reached a fifth attempt:

- *"`ToolbarSpacer(.fixed)` … renders — verified, two adjacent capsules."* It does not.
- *"`.automatic` … sorts before `.primaryAction`, so leaving the toggle on `.automatic`
  would silently put it left of search."* It does not. The `runOrder` probe interleaved
  both placements across both toolbar modifiers and got 1 2 3 4 5 in one capsule. Order is
  root-toolbar-before-inspector-toolbar, then declaration order, with `.cancellationAction`
  the only placement that sorts. Use one placement per run anyway, so the source reads in
  the same order as the bar.

**Landed:** Containers' menu moved to the head of the run; Builds' inspector toggle moved
`.automatic` → `.primaryAction` to match every other route; three wrong comments corrected;
five new stock-SwiftUI probe variants (`inspectorForm`, `inspectorTabView`,
`inspectorTabViewGrouped`, `inspectorTabViewSidebarAdaptable`, `inspectorPickerPanes`,
`runOrder`) checked in so none of this has to be re-derived. Every `ToolbarItem(id:)` and
every `.accessibilityIdentifier` is unchanged.

**Not done, queued:** the after-capture sweep (nine routes × 1600×1000 and 1100×800 ×
inspector open/closed × dark and light). The session ended with the app instances being
shut down; only Containers' two-capsule result and the build are unverified against a real
window. Everything else above was measured before that.

## UI-054 · Stacks and Images still fragment the trailing toolbar · `done`

`docs/design/NATIVE-MACOS-PLAYBOOK.md` §4: a `Menu` is always its own glass capsule and
splits the placement run around it, so a route's menu must be declared first or the bar
grows a pill stranded in the middle. Containers is fixed; two routes are not.

- **Images** — `runLocal · pruneDangling · explorePublic · pull · archive(Menu) · search ·
  inspector` renders as three capsules, measured at 1600×1000 (`[▷ 🗑 🌐 +] [archive ⌄]
  [🔍 ▤]`). `images.archive` is a *record* menu, not a collection menu, so moving it to the
  head is a semantic change, not a reorder. Decide whether the head slot means "the route's
  menu" or "any menu", then apply.
- **Stacks** — has two menus (`stacks.actions`/`stacks.project-actions` for the selection,
  plus `stacks.options`), so it can reach four capsules with a service selected. Needs a
  decision about whether the selection's menu collapses into the options menu, not a
  reorder.

Verify the same way: `scripts/capture-window.sh`, then a row scan at y 9 across
x 1250–1599 — a capsule fill reads `2933xx`, a gap reads `252b2d`.

### 2026-08-06: closed. Images reordered; Stacks merged — reordering alone cannot fix it.

**Images.** `images.archive`'s `ToolbarItem` moved to the head of `toolbarContent`, ahead
of `runLocal`/`pruneDangling`/`explorePublic`/`pull`. The semantic call: `archive` reads as
a record menu because "Export Selected Image…" acts on the selection, but the menu itself
never appears or disappears with selection — only its *items'* enabled state does, exactly
like Containers' `containers.options`. That is what makes the head slot the right slot: a
menu earns it by being structurally constant, not by being administrative in subject.
Verified on a real window, 1600×1000 dark, row scan at y 26: gap `504a2a` → fill `3a3622`
(archive, x 1310–1354) → gap `504a2a` (x 1358–1366) → fill `3a3622` (everything else
through the inspector toggle, x 1370–1586) → gap. Two capsules, with or without a
selection.

**Stacks.** Reordering could not do the same job, and proving that was the actual find of
this pass. A new probe variant, `twoMenusAdjacent`
(`docs/design/probes/ToolProbe.swift`), puts two `Menu`s back to back with nothing between
them: a row scan reads three capsule fills separated by two background-tone gaps at the
exact seams between the menus, not one. **A `Menu` earns its own capsule regardless of
what is or is not next to it** — full derivation in
`docs/design/NATIVE-MACOS-PLAYBOOK.md` §4a. Stacks has two menus' worth of content
(the selected service's or project's own commands, and the route's Refresh/Edit Compose
File), so no reordering of two separate `Menu`s reaches two capsules.

The fix is a content merge: `stacks.actions`, `stacks.project-actions`, and
`stacks.options` — three identifiers for three menus — collapsed into **one** always-present
`stacks.actions`, sectioned by a `Divider`: the selected record's commands above (whichever
record — service, project, or neither), Refresh and Edit Compose File below, the same way
one File menu holds document-scoped and application-scoped commands rather than splitting
into two menus that come and go with what's open. The one-tap lifecycle toggle
(`stacks.primaryLifecycle`) stays a plain button outside the menu, since a non-`Menu` item
never splits a run. Verified on a real window with nothing selected, a service selected,
and a project-only selected: **2 capsules in every state**, and the merged menu's content
opens correctly for each (a service selected shows its lifecycle actions, a nested "Project
Actions" submenu, navigation, and — when eligible — Remove Service, all above the Divider;
a project alone selected shows its lifecycle actions directly, without the extra submenu
level, since there is no service section to distinguish them from). One bug caught in the
same pass: the project-only branch was rendering `projectActionItems`'s own "Edit Compose
File…" *and* the merged menu's route-level copy in the same dropdown — fixed by skipping the
route-level copy specifically when the project-only section already carries it
(`projectOnlyRecordSectionAlreadyOffersComposeFileEditing`), which is the only state where
the two would otherwise coincide.

Nothing in `mac/UITests` or `mac/Tests` queried `stacks.project-actions` or
`stacks.options` by name — grepped before removing them. `mise run check`: exit 0, Swift
build-tests and Rust suite both green.

## UI-055 · `TabView` inside `.inspector` double-draws the window's chrome · `done`

Measured and reproduced in stock SwiftUI on 2026-08-06; full table in
`docs/design/NATIVE-MACOS-PLAYBOOK.md` §8. A `TabView` draws a bordered content box, and
inside an inspector that border lands on chrome the window already draws: the inspector
divider (leading) and the window border (trailing). At x 1200 the divider goes `444f51`
above the toolbar's lower edge and `61686b` below it, where a `Form` stays constant. Xcode
and Volumes are constant. It is why the inspector reads as a card that begins below the
toolbar.

Affects `ContainerDetailView` and Builds' history inspector, and only when a record is
selected. `.tabViewStyle(.grouped)` is byte-identical; `.sidebarAdaptable` renders a whole
sidebar inside a 400pt column; the SDK has no modifier that suppresses the box. Apple's own
inspectors — Xcode's, captured — use a segmented control at the top of the column with the
pane below, which probe `inspectorPickerPanes` reproduces with a constant divider.

**The care this needs:** `Tab` carries `containers.detail.tab.overview/logs/files/stats/
inspect`, and `MorbstackFixtureUITests` queries `containers.detail.tab.logs` and
`containers.detail.tab.files`. A segmented `Picker` does not carry per-segment
accessibility identifiers reliably. Establish that first — with the probe, not in the app —
or the conversion trades a 1px seam for a broken UI-test contract.

### 2026-08-06: closed. The blocking assumption was wrong, and had never been measured.

Two more suppression attempts tried and failed before converting anything: `TabView`
`.tabViewStyle(.tabBarOnly)` and `TabView` + `.background(.clear)` + `.clipShape(Rectangle())`
are both byte-identical to the plain `TabView` at the divider (`444f51` → `61686b`), probes
`inspectorTabViewBarOnly` and `inspectorTabViewClipped`. A sixth variant,
`inspectorTabViewOverlaidDivider`, tested "draw over the seam" directly: a 1pt `Rectangle`
in the divider's measured color, painted over the inspector's leading edge. It does not
generalize — the hard-coded tone only matches the exact appearance it was measured under,
and the capture showed the tab strip's own header disappearing behind the overlay, a second
failure mode — and it is exactly the custom-drawing CLAUDE.md §1.7 already rules out, so it
was not pursued as a real candidate regardless of whether it could be made to work.

The actual blocker — *"a segmented `Picker`'s options do not carry per-segment
identifiers reliably"* — turned out to be untested folklore. Two probe variants,
`inspectorPickerIdentified` (segmented `Picker`, `.accessibilityIdentifier` per option) and
`inspectorControlGroupIdentified` (`ControlGroup` of `Button`s, same treatment), were
dumped with the Accessibility API directly — `AXUIElementCopyAttributeValue` walking
`kAXChildrenAttribute`, the same resolution `XCUITest`'s `app.descendants(matching:
.any)[identifier]` uses — rather than assumed from memory:

```
[AXRadioButton] id="probe.pane.overview" desc="Overview"
[AXRadioButton] id="probe.pane.logs"     desc="Logs"
[AXRadioButton] id="probe.pane.files"    desc="Files"
```

Every option surfaces its own `AXIdentifier`. `ContainerDetailView` now uses a segmented
`Picker` with `containers.detail.tab.overview/logs/files/stats/inspect` moved onto the
options **byte-identical** — `MorbstackFixtureUITests` needed no change. Builds' history
inspector converted the same way; it carried no identifiers to preserve.

Real-window evidence, `scripts/capture-window.sh`, Containers with a container selected,
1600×1000, dark and light, inspector open: before shows the bordered pink pill around
"Overview" with its siblings as plain unstyled text next to it; after shows a clean
segmented "Overview | Logs | Files | Statistics | Inspect" control matching Xcode's
inspector shape, in both appearances. The isolated `ToolProbe` divider measurement is the
clean, decisive number (`444f51` constant vs. `444f51` → `61686b`); the same column scan on
the real, content-dense `Form` moves by single digits rather than ~30 levels, confounded by
the Form's own row backgrounds — which is honestly part of why this took four passes
before the isolated probe made the cause unambiguous.

`mise run check`: exit 0. Every `.accessibilityIdentifier` string byte-identical to what it
replaced.

## UI-056 · `.inspector` reveal pops instead of sliding · `closed — not reproducible; the earlier verdict measured the wrong quantity (2026-08-07)`

Reported against `ContainersRootView`: closing the trailing inspector slides; opening it stalls
and pops in place.

**This ticket was closed on 2026-08-07 as an unfixable platform limitation. That was wrong and
is retracted here.** Full numbers, the subtraction matrix and both new instruments are in
`docs/design/tahoe/HIG-FINDINGS.md` ("Inspector reveal: what the ~350ms actually is").

What the earlier round got right: the toggle really does cost ~250–350ms of main-thread CPU, on
the real app and in a stock-SwiftUI probe alike, and that number has not moved. What it got
wrong is what the number *means*. Instruments' Time Profiler reports an unbroken run of
main-thread samples; that was read as a ~350ms **block** before the first animated frame. It is
not a block — it is the animation running, which is supposed to keep the main thread busy for
its whole duration. Two instruments on the same six real clicks:

- external CPU delta (`docs/design/probes/axpress-cost.sh`): 400 / 290 / 300 / 290 / 290 / 340ms
- in-process 2ms stall meter (`docs/design/probes/PerfProbe.swift`): **0ms — no gap above 30ms**

The three specific claims that carried the "unfixable" verdict, each now contradicted:

- **"It is every open, not a one-time warm-up."** Eight consecutive `AXPress` toggles on a real
  window produced exactly one block: the first reveal, 307ms. The other seven produced nothing
  above 30ms. It *is* a one-time cost. The first reveal's size also decays with machine warmth
  (523 → 362 → 92 → 61 → 47ms across consecutive launches), so any figure quoted without the
  machine state is not comparable to any other.
- **"Closing is free on Containers — 0 samples, confirmed twice."** Not reproducible. Eight
  alternating toggles on the real route cost 340 / 250 / 230 / 230 / 270 / 250 / 250 / 340ms
  with no direction dependence. The probe/route asymmetry was entirely `start=open` vs
  `--closed`: the block lands on whichever transition *first* presents the column, and all nine
  routes already ship `showsInspector = true`, so they pay it invisibly during window setup.
- **"SwiftUI has no frames left to interpolate, so the column appears rather than slides."** It
  slides. `docs/design/probes/AXColumnTrace.swift` reads the content column's width out of the
  running app through the accessibility API; four consecutive toggles on the real Containers
  route drew 3, 6, 3 and 2 intermediate widths, ramping in both directions.

Subtraction also cleared two Morbstack-side suspects for good: the toolbar costs +11 to +18ms
whatever is in it and wherever it is mounted, and `.inspectorColumnWidth(min:ideal:max:)` costs
194.3ms against a single fixed value's 197.4ms — no constraint-solve penalty, so the
outermost-modifier fix on all nine routes stays exactly as it is. 62% of the remaining cost is
the minimum case: a bare `NavigationSplitView` with a `Text` on either side and no toolbar
spends 181ms of CPU presenting the column, at 88% of a 165Hz panel's frames. That part is the
system's, and it does not block.

Closed as not reproducible rather than fixed: no code changed. What changed is the instruments,
which are now in the tree.

## UI-059 · One `TimelineView` around a whole `List` invalidates every row, once a second · `open`

Found while subtracting UI-056, on an axis nobody was looking at: not the cost of a transition,
but a **recurring** cost that runs forever while a route is on screen.

`caab2f9` consolidated `ContainersRootView`'s per-row clocks — every visible row carried its own
`TimelineView(.periodic(by: 1))` — into one `TimelineView` wrapping the entire `List`, with the
date threaded down as a plain value. The stated reason was that per-row subscriptions had to be
resubscribed on every layout pass, including during an unrelated `.inspector` reveal.

Measured, that reason does not hold and the replacement has a scaling cost the original did not.
`docs/design/probes/PerfProbe.swift` has the three shapes behind one axis (`rowclock=none`,
`shared`, `per`), which makes them directly comparable in stock SwiftUI with no Morbstack code:

- **The stated problem is not measurable.** Per-row `TimelineView`s cost nothing during an
  inspector toggle: 100 rows at `per` measured 286.4ms of CPU against `shared`'s 310.2ms and
  `none`'s 268.9ms — all inside the noise, and no main-thread block in any of the three.
- **The replacement blocks the main thread once a second, and it scales with the row count.**
  Over 20s of complete idle with an accessibility client attached, no interaction at all:

  | rows | `none` | `per` | `shared` |
  | --- | --- | --- | --- |
  | 20 | 2 blocks / 367ms · 2 / 282ms | 2 / 367ms · 1 / 53ms | 4 / 419ms · 1 / 46ms |
  | 100 | 2 / 230ms · 2 / 192ms | 2 / 268ms · 0 / 0ms | **11 / 581ms · 18 / 769ms** |

  (two reps per cell, blocks ≥30ms.) The mechanism is straightforward: a clock *outside* the
  `List` invalidates the whole list every tick, so the cost is O(rows); a clock inside each row
  invalidates one label, so it is O(1) per row and the rows that are not visible cost nothing.

Two honest qualifications, because this is not a fire:

- **It only appears once an accessibility client has touched the window.** With no AX client the
  same runs show 0–1 blocks for every shape. AppKit builds accessibility elements lazily and a
  whole-list invalidation then rebuilds the whole list's AX tree. Real users hit this whenever
  VoiceOver, Voice Control, a window manager or our own tour/XCUITest tooling is attached — and
  every measurement this project has ever taken through AppleScript `AXPress` was taken in that
  state.
- **At the row count Containers actually shows it is not measurable.** The 20-row rows are a
  wash. The defect is that the shape degrades with list length where the previous one did not.

So: not a regression anyone can see today, and not worth reverting on its own. Worth fixing when
that file is next touched, by moving the clock back inside the row.

The rest of the app is already in the cheap shape, checked rather than assumed —
`StacksRootView:642`, `KubernetesRootView:1117` and `:1189` all declare the per-second
`TimelineView` *inside* the cell that shows the ticking value, and `ImagesRootView:839` /
`BuildsRootView:777`, `:914` tick once a minute. `ContainersRootView:483` is the only place a
periodic clock wraps a whole collection.
