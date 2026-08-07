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
| EN-2 | `-P` across stop/start/restart | Rescoped by TECH-1/SP-6: prove `-P` under the userland-proxy wrapper — TCP/UDP reachability, stop/start/restart, restart-policy recovery, and VM restart — against the current wrapper implementation (`guest/morbinit/src/proxy_wrapper.rs`, `mac/Sources/MorbstackKit/GuestPortLease.swift`). | `open`; runtime acceptance in progress 2026-08-04 |
| EN-3 | Bind mounts `/etc`, `/var`, unshared roots | The 2026-08-03 candidate recorded refusals for `/etc`, `/var`, `/Library`, and symlink traversal, plus working `/tmp`, `/private/tmp`, and `$HOME` bind writes. `33fd00e` then changed bind-admission and relay behavior; rebuild the guest and rerun this exact matrix before assigning those results to the current source. See `docs/audit/PROXY-FRAMING.md`. | `in-flight` (post-`33fd00e` rebuilt-guest acceptance) |
| EN-4 | `morb disk grow` | Fix `keyNotFound: 'device'` host/guest contract mismatch. Image grew to 72 GiB while the guest filesystem stayed 62.4 G, and a **refused** grow still mutated configured capacity. Add the journal tests it never had. | `in-flight` (`codex/parity-en4-disk-grow`) |
| EN-5 | Reclaim the 72 GiB `disk.img` | Safe reclamation path for the test artifact left on the dev machine | `open` |
| EN-6 | `host.docker.internal` without `--add-host` | Resolves by default | `open` |
| EN-7 | Live-share / hot reload proven | First compile was today. Publish a **watcher conformance matrix**: the mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB` only — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`. Also `liveSharePaths` defaults to `[]` with **no CLI or GUI writer**. The correctness-mode alternative for `air`-class watchers is DIF-1a. | `open` |
| EN-8 | Testcontainers (Java/Go/Node/Python) | Executed 2026-08-04 with real Postgres suites via `scripts/ecosystem-acceptance.sh`: Node 12.1.0, Python 4.15.0, Go v0.43.0, Java 1.21.4 all PASS with `DOCKER_HOST` + `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`; Ryuk works in all four. Java ≤1.20.x FAILs against any engine-29 daemon (docker-java `/v1.32` probe vs upstream `MinAPIVersion 1.40`) and, like Node/Go zero-config, **silently runs against a stale Docker Desktop socket** — see `docs/audit/ECOSYSTEM-MATRIX.md`. Proposed guest-side mitigation: `DOCKER_MIN_API_VERSION=1.24` in morbinit's dockerd env (guest lane owns the change). | `done` (evidence: `docs/audit/ECOSYSTEM-MATRIX.md`; CP-06 clean-profile still pending) |
| EN-9 | Dev Containers | Executed 2026-08-04: `@devcontainers/cli` 0.88.0 `up`/`exec` PASS against Morbstack with context-only discovery — lifecycle, two-way workspace bind mount, `postCreateCommand`, and a features/derived-image build (Go feature) all worked. Two harness-doc bugs fixed (`exec` needs the same `--id-label` as `up`; CLI 0.88 has no `down`). VS Code extension flow remains untested (CP-07). | `done` (CLI; extension/CP-07 pending) |
| EN-10 | Clean-profile CP-01–CP-07 | The release gate. Never run. Nobody has ever installed this. | `blocked` (EN-1, REL-2) |
| EN-11 | Pinned `kubectl` for pod port-forward | `KubectlTool.swift:16-30` needs a binary not in the repo; the path is a hardcoded unavailable | `open` |

## Operations and repo health

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| OPS-1 | Push and prove CI red-then-green | CI has never run once in 273 commits | `open` |
| OPS-2 | Install the pre-commit hook | `mise run install-hooks`, documented in CONTRIBUTING | `open` |
| OPS-3 | `mise run doctor` in CI and `check` | Wire the staleness check into the gates | `open` |
| OPS-4 | Swift lint/format config | Neither `.swift-format` nor SwiftLint config exists, so CI has no Swift lint job. Adding one means agreeing rules first. | `open` |
| OPS-5 | shellcheck locally | Not installed; CI shellchecks but developers cannot | `open` |
| OPS-6 | `.gitignore` / tracked `dist/` audit | 7 tracked files under `dist/`; confirm intent | `open` |
| OPS-7 | Build warnings | `DockerAPI.swift:65` and `UDPListener.swift:101` form `UnsafeRawPointer` to a generic `T` in socket-option code — real, not cosmetic | `open` |
| OPS-8 | **Security review of untrusted-input surfaces** | **Two passes done, both in [docs/audit/INPUT-VALIDATION-REVIEW.md](docs/audit/INPUT-VALIDATION-REVIEW.md).** Part 1 (2026-08-04): ten guest wire parsers incl. 2377 and the live-share port — SEC-1, SEC-2 and a staged-file leak fixed, SEC-3 filed. Part 2 (2026-08-05): all of `mac/Sources/MorbMCP/**`, every process-spawning site under `mac/Sources/**`, and the four guest files part 1 deferred (`binfmt.rs`, `disk.rs`, `dns.rs`, `mounts.rs`) — **MCP-1 (high)** fixed, plus MCP-2, GUEST-1, GUEST-2; SEC-4/5/6 filed below. Verified and now pinned by test: read-only *is* the default, the permission check sits on the single path every `tools/call` crosses, and the audit log is complete. **Judgement for REL-5: these surfaces are safe to publish.** Still unreviewed, and the honest remainder: vsock 1024/2375/2376/2378/2381/2382, specifically `GuestPortLease.parseRequest` (`mac/Sources/MorbstackKit/GuestPortLease.swift`) and `proxy_wrapper.rs`'s `parse_reply`/`parse_invocation`, both added by TECH-1 and both parsing guest-controlled input. Neither is agent- or network-reachable; sequencing them after REL-5 is a defensible call, blocking on them is not required. (2379 and 2380 are DELETED — 2380 in `51dc543`, 2379 with the publish-all path in TECH-1.) | `done` (parts 1–2); port-lease parsers `open` |
| OPS-9 | CI guest-image job | Per TECH-1: no rewrite needed — the guest-image job needs no Docker/buildx and no engine-artifact release fetch, because Morbstack ships unmodified upstream dockerd fetched like every other pinned third-party guest binary. `build-engine.yml` and the "Require Docker Buildx" step are deleted. Remaining work is just confirming the job passes on hosted runners. | `open` |

## Tests — coverage runs backwards from risk

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| TST-1 | `VMManager.swift` (2,097 LOC) | No test boots or restores a VM | `open` |
| TST-2 | `MorbDiskGrowth` journal | No test; it mutates a 68 GB disk image | `open` |
| TST-3 | Live-share transport + both guest modules | ~1,850 LOC, self-described "authority boundary", zero tests | `open` |
| TST-4 | ~~`PublishAllPortAllocator` + guest `publish_all.rs`~~ — moot, both deleted 2026-08-04 (TECH-1) | The publish-all allocator this ticket targeted no longer exists; its replacement, the port-lease channel (`GuestPortLease.swift` / `proxy_wrapper.rs`), already has unit tests on both sides (`GuestPortLease.parseRequest`, `proxy_wrapper.rs`'s `parse_invocation`/`parse_reply`/`lease_line` tests). Superseding coverage question, if any gap remains, belongs to EN-2. | `done` (moot) |
| TST-5 | vsock relay under load | Half-close, backpressure, cancellation | `open` |
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
| UI-13 | Add accessibility identifiers | major | `blocked` (SP-8) |
| UI-14 | XCUITest cannot attach screenshots — "Image creation failed. Disable automatic screenshots in your test plan's configuration." | minor | `done` in source (`MorbstackUITests.xctestplan`: `systemAttachmentLifetime: keepNever`, explicit `screenshots` capture format); validation blocked on Automation Mode |
| UI-15 | The remaining 14 minor + 8 polish items in UI-AUDIT.md | minor/polish | `in-flight` — all register rows fixed except UI-014 (CLI/daemon lane, outside GUI scope), UI-030 (validation blocked on Automation Mode), UI-032 (retest with settle delay pending) |

## Documentation

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| DOC-1 | "Unmodified upstream dockerd" retraction | Done: 26 corrections across 11 files; 17 hits deliberately left because `containerd`, the `docker` CLI, Compose and Buildx really are unmodified. See `docs/TRUTHFULNESS-PASS.md`. | `done` |
| DOC-2 | Collapse six status docs into one generated file | | `blocked` (SP-7) |
| DOC-3 | `morb scan` docs | Site copy corrected to describe the real behaviour | `done` |
| DOC-4 | `.local` vs `.test` contradiction | Settled by SP-3 in favour of the **source** constant (`morb.local`). `docs/domains.md` now needs four corrections, listed at the end of `docs/design/DNS-DECISION.md`: withdraw the `*.morb.test` recommendation; delete "there is no `/etc/resolver` fallback" (there is, priced in the decision); retire the "prove the per-user process can own loopback :80" gate (proved impossible); scope the host-side router + transport-lease contract to the fallback path only. | `open` |
| DOC-5 | **`morb scan` tells users to run a script that does not exist** | Code scope, so the doc pass could not fix it: `ToolLocator.swift:90` is a user-facing *error message* directing you to `scripts/fetch-scan-tools.sh`, and `ScanCLI.swift:403` repeats it in `--help`. Either ship the script or rewrite both strings. An error message that prescribes a nonexistent remedy is worse than no message. | `open` |

## Release and distribution — nobody has ever installed this

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| REL-1 | `scripts/release.sh`, `docs/RELEASING.md`, `.github/workflows/release.yml` | All referenced by name as the source of truth; **none exist**. Shape now set by TECH-1, not SP-4: there is no non-upstream engine artifact to build or release, so drop the engine-artifact shape from these notes entirely. Release contents are all stock, pinned upstream artifacts (dockerd, containerd, the Docker CLI, Buildx, etc.) plus Morbstack's own binaries (`morbstackd`, `morb`, the guest image, `morbstack-docker-proxy`). | `open` |
| REL-2 | Notarization | Not one `notarytool` call in the repo | `blocked` (SP-9) |
| REL-3 | Homebrew cask | | `blocked` (SP-9) |
| REL-4 | Sparkle update channel | `docs/sparkle.md` referenced and absent | `blocked` (SP-9) |
| REL-5 | Make the repo public | OPS-8's gating review is done (parts 1–2, [docs/audit/INPUT-VALIDATION-REVIEW.md](docs/audit/INPUT-VALIDATION-REVIEW.md)) and its verdict is that the reviewed surfaces — the MCP server, every shell-out, and the guest wire parsers — are safe to publish. Remaining before the flip is disclosure hygiene, not unknown risk: SEC-4 (a ruling), SEC-5 (`docs/mcp.md` is cited at runtime and does not exist), and the two TECH-1 port-lease parsers named in OPS-8. | `unblocked` (SEC-5 first) |

## Differentiation — only after parity is `accepted`

Ranked by impact per effort. Full rationale in [docs/COMPETITIVE-GAPS.md](docs/COMPETITIVE-GAPS.md).

| ID | Ticket | State |
| --- | --- | --- |
| DIF-1 | Hot reload on by default + published watcher conformance matrix | `blocked` (EN-7) |
| DIF-1a | **Synchronized shares on the live-share transport** — the correctness-mode alternative to the `fchmod`→`IN_ATTRIB` bridge (colima#1244 is that bridge's documented production failure) and the honest successor to the deleted `MorbShareSyncProtocol` (SP-5). Scope: (1) extend the existing authenticated vsock-2381 session (`MorbLiveShareTransport` ↔ `live_share_receiver.rs`) with content-bearing messages — per-file records carrying bytes + SHA-256, chunked, over the already-proven HMAC handshake; (2) guest writer in `morbinit` doing atomic tmp-write→fsync→rename into a real guest-local directory (ext4/virtio-blk data disk, **not** the virtiofs mount — the guest kernel has no btrfs), so watchers get real `IN_MODIFY`/`IN_CREATE`/`IN_DELETE`; (3) per-share opt-in surfaced in config/CLI (`liveSharePaths` still has no writer — EN-7); (4) guest-image rebuild + repin (guest lane). **Acceptance: a Go watcher using `air` rebuilds on host edits** — fsnotify treats `Chmod` as a distinct op, so `air` is precisely the case the current bridge cannot serve; chokidar/watchdog re-verified unbroken. See `docs/design/INERT-SUBSYSTEMS-DECISION.md` §1 and TECH-2 option (b). | `open` (needs guest lane + live engine; 1–2 wk) |
| DIF-2 | Container `exec` + a real PTY in the app — table stakes for both competitors. Transport, screen model, view and window shipped; `TerminalEmulator.feed`/`resize` and all of `TerminalKeyEncoding` were stubs returning nothing and are now implemented (141 unit tests incl. two fuzz soaks and a hostile-input suite). Reachable from the Containers contextual menu, the toolbar (`containers.openTerminal`), and the Container menu (⌃⌘T), disabled with a remedy for any non-running container. See [`docs/exec.md`](docs/exec.md). | `open` (code complete; **needs a machine-lane pass** — nobody has yet held a real shell against a running container) |
| DIF-3 | Publish the benchmark harness; add `git-status-bindmount` and `npm-install-bindmount-vs-volume` | `open` |
| DIF-4 | **Container domains via unprivileged mDNS** — mechanism decided in [`docs/design/DNS-DECISION.md`](docs/design/DNS-DECISION.md). Six steps, **~3–4 weeks, zero admin prompts**: (0) prove host→guest reachability at `192.168.64.x` on Wi-Fi/Ethernet/VPN — **hard gate**, fall back to `127.0.0.1` + high-port URLs if it fails; (1) mDNS registrar in `morbstackd` (`A` records only, `LocalOnly`, no advertised service type, conflict handling, Docker-event lifecycle); (2) name derivation wired to the existing `MorbLocalDomain.Name` validator (the loopback claim reconciler was deleted under SP-5; the registrar owns its own name→container index and duplicate rejection); (3) guest-side Host-header reverse proxy owning `:80`/`:443` inside the VM, pinned like every other guest binary, with listening-port auto-detection; (4) withdrawal paths (stop/remove, suspend, wake, VPN transition, hostile-`.local` detection); (5) `morb domain` CLI + inspector affordance. No wildcards — do not advertise them. | `open` |
| DIF-5 | **HTTPS via a name-constrained local CA** — **~2–3 weeks after DIF-4**. CA key in the Keychain, ACL-restricted; per-name short-lived leaves; name constraints as defence in depth with honest browser-by-browser verification (Firefox has its own trust store). **Two things need a written ruling before code:** the trust installation is the one and only user password prompt in the whole domains feature, and if the proxy lives in the guest then leaf private keys live in the guest — recommended shape is issue-on-host, push over vsock, hold in guest tmpfs, CA key never leaves the host. | `blocked` (DIF-4) |
| DIF-6 | Routable container IPs | `open` (SP-5 resolved; nothing deleted touches this — design from scratch) |
| DIF-7 | Native file access to volumes (Finder) | `open` |
| DIF-8 | Distroless debug toolbox — **the one thing OrbStack actually paywalls** | `blocked` (DIF-2) |
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

### TECH-2 · Hot-reload foundation ruling · `open` (spike)
**Deliverable:** a written ruling that the `fchmod(2)`→`IN_ATTRIB` bridge is a best-effort accelerant, not
the inotify story, plus the chosen correctness path. Evidence: colima#1244 is this exact pattern failing in
production; Go fsnotify maps `IN_ATTRIB` to a distinct `Chmod` op that `air`-class tools filter; notify-rs
(cargo-watch, watchexec) likewise; virtiofs has no inotify passthrough (2021 RFC, LWN 874000, never merged).
Decide: (a) reframe bridge + `morb doctor`/status detection of known-filtered watchers, (b) promote tier-2
synced shares to the *correctness* mode (real guest writes → real `IN_MODIFY`/`IN_CREATE`/`IN_DELETE` —
the free version of Docker's paid Mutagen mode), (c) verify same-mode `fchmod` emits `IN_ATTRIB` with an
in-guest probe and record it.
**Rewrites:** EN-7, DIF-1, `docs/live-share-bridge.md` framing.

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
| TECH-5 | Drive the memory balloon | `VMManager` attaches the balloon device but never sets `targetVirtualMachineMemorySize`. Shrink on idle, restore on wake; measure real host RSS reclaim with MorbBench. | `open` |
| TECH-6 | Sleep/wake + clock correctness | Zero power-event handlers exist and `clock_sync` is observe-only. Register `NSWorkspace` wake notifications; implement guest `clock_settime` (CAP_SYS_TIME) behind the existing MRB0 message; acceptance: guest clock within tolerance after a forced overnight-sleep test, TLS-in-container works on wake. | `open` |
| TECH-7 | Host disk-pressure policy | Nothing watches Mac free space while sparse `disk.img` grows. Define and implement low-space detection → honest warning/pause before guest I/O errors. | `open` |
| TECH-8 | Shared framing core for the vsock protocols | Factor the line/frame parsing primitives shared by MRB0, stream/datagram-dial, payload-install, live-share, and the port-lease channel (2382, replacing the deleted publish-all/probe protocols as of 2026-08-04) so OPS-8 reviews one hardened core plus thin grammars. No multiplexing — §3.1's reasoning stands. | `open` |
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
| PROTO-2 | Stale docs for removed port 2380 | `listen_probe.rs` and `GuestListenerProbe.swift` were deleted in `51dc543`; `docs/protocol.md` was scrubbed but `architecture.md` (3 sites) and `ENGINE-MATRIX.md` still describe it as live. Already corrected in `TASKS.md` and `MASTER-PLAN.md`. | `open` |
| PROTO-3 | Inconsistent backpressure at connection caps | 2376/2378 emit `ERR busy\n` — a deliberate hardening pass their own comments describe as fixing exactly this. 1024, 2375 and 2381 still **silently drop** over-cap connections with only a log line, which is indistinguishable from a peer that never spoke the protocol. Apply the fix uniformly. **2026-08-04:** fixed — 1024 answers with a well-formed MRB0 `error` frame (`busy`), 2375 with a synthetic HTTP 503 + `Connection: close` (pairs with the host's 502-when-unreachable), 2381 with `ERR busy\n` in place of `BOOT`; all use dial.rs's bounded best-effort send discipline. Host `MorbLiveShareTransport` now names a busy rejection distinctly instead of reporting a generic boot-identity violation. 3 new Rust tests; protocol.md updated for 2375.  | `done` |
| PROTO-4 | 2377 k8s transfer has no in-flight timeout and is serial | A 10 s preamble wait bounds negotiation, but nothing bounds the body afterwards. One stalled ~512 MB `PUT` wedges every later `morb k8s enable` from any client indefinitely (`k8s.rs:1022-1026` documents the serial design as intentional). | `open` |
| PROTO-5 | jsonlite's flat-only contract is enforced only by convention | `jsonlite` rejects **any** nesting, poisoning the whole frame (`jsonlite.rs:123-140`). Every host MRB0 struct goes through Foundation's fully general `JSONEncoder` with no check. Adding one nested field compiles, passes Swift round-trip tests, and then fails 100% of that message type at runtime with a generic "invalid JSON". Add a host-side flatness assertion. **2026-08-04:** fixed — `MRB0FlatnessTests.swift` encodes every host-encoded MRB0 type (`GuestRequest` directly; `K8s.Request` by capturing the real frame bytes over a socketpair) and asserts every top-level value is a scalar; failure names the type and key. Verified it has teeth by planting a nested field. Reply-side needs no mirror: jsonlite's `Value` enum cannot construct nesting.  | `done` |
| PROTO-6 | Guest plumbing duplicated across protocols | Byte-at-a-time line reading is reimplemented three times (`dial.rs:125`, `datagram.rs:49`, `k8s.rs:850`) — and `live_share_receiver.rs:463` already calls `dial::read_preamble_line`, proving it is reusable. `err_line`, `negotiate`, `DeadlineStream`/`ConnGuard`, `send_busy` and the accept-loop skeleton are each duplicated 2–5 times. Three primitives would replace all of it. | `open` |

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
| UX-5 | **Spike: registry discovery beyond Docker Hub — deliverable is a decision.** Docker Desktop's browsing is Hub-only because its UI is built around one vendor's account; we have no credential store to bias us. But only Hub has an anonymous *search* API; other registries offer anonymous manifest/tag browsing by name only. | A written ruling: does a "paste any public `registry/repo`, browse tags/platforms anonymously" surface earn a screen, and if so where (extend `PublicImageDiscoverySheet` vs pull sheet)? Must restate the boundary: the GUI never holds a credential; push and private pulls remain the CLI's job via the user's own `credsStore`. | `open` |
| UX-6 | **Compose grouping in the container list** — Docker groups containers into collapsible Compose-project entries (VERIFIED); our list is flat and the project exists only as hidden search text. Respects the decided UI-011 outcome (keep `List` + inspector). | Collapsible project sections in `ContainersRootView`'s existing `List`: aggregate header row (n of m running, project lifecycle menu), ungrouped containers in a trailing section. Add "Copy `docker run` Command" to the container context menu in the same pass. | `open` |
| UX-7 | **Spike: volume content browsing — deliverable is a decision.** Docker's Stored-data tab needs sign-in for export (a purely local file operation); OrbStack projects volumes into Finder. The Engine API has **no** volume-contents endpoint, so the mechanism is genuinely open. | A written ruling choosing between: throwaway helper-container mount (works today, pulls nothing if we ship a pinned busybox), a guest-agent path in `morbinit`, or waiting for DIF-7's Finder projection — with the read-only-vs-write boundary stated. Blocked-by: nothing (DIF-7 is related, not prerequisite). | `open` |
| UX-8 | **Spike: image vulnerability surface — deliverable is a decision.** Scout ties scanning to a Docker account and repo quota; local `syft`/`grype` has neither. But `morb scan` currently tells users to run a script that does not exist (DOC-5) — the CLI promise must be kept before a GUI repeats it. | A written ruling: bundle syft/grype (sha256-pinned, per repo law) vs first-run fetch; then scope the Images-inspector surface (per-image CVE summary, grouped by package, expandable fixes). Blocked-by: DOC-5. | `blocked` (DOC-5) |
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
| UX-16 | **Disk space never returns to macOS** — `guest/morbinit/src/disk.rs:273`'s `discard=async` is dead code: the kata kernel has no btrfs (`architecture.md:183`), ext4 mounts with no `discard`, no `fstrim` anywhere in the tree, resize is grow-only. We reproduce Docker Desktop's single most-complained-about behaviour. DIFFERENTIATION Tier B and TECHNOLOGY-AUDIT Bet 8 flatly contradict each other here; TECHNOLOGY-AUDIT is right. | **TECH-3 spike answered 2026-08-06: yes, `VZDiskImageStorageDeviceAttachment` punches real holes for both `-o discard` and `fstrim` — measured, numbers in `docs/design/DISK-RECLAIM-DECISION.md` §4/§5.** Shipped: `disk::spawn_periodic_trim` runs an hourly `fstrim` sweep of `/var/lib/docker` from a background thread (10-minute post-boot warmup, guest side), deliberately *not* a live `-o discard` mount — see the reasoning on `disk.rs`'s `mount_data` doc comment: `discard` pays a synchronous TRIM round trip inline with every delete, which is exactly why production Linux distros schedule periodic `fstrim` instead. The result rides `info`'s `disk_last_trim_bytes` → `morbstackd status`'s `guest_disk_last_trim_bytes` → `Doctor.diskTrimCheck` (a `morb doctor` line) → `DaemonClient.guestDiskLastTrimBytes()` → the Disk inspector's VM-disk footnote (`TrackCDiskReclaimPresentation`), which now says reclaim is automatic instead of the pre-fix "remains allocated until trimmed or recreated." Not yet done: the code has not been through `mise run guest-image` + a live re-measurement on the rebuilt guest (CLAUDE.md §1.5) — the §4 numbers in the decision doc are from the spike's manual remount/`fstrim`, not from this shipped background thread. That measurement is next, blocked on the machine lane being free. | `open` (mechanism + reporting + UI shipped; rebuilt-guest verification pending) |
| UX-18 | **No proxy support at all** — grep for `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`/`socks` across `guest/morbinit/src`, `MorbstackKit` and `morb` returns zero hits. OrbStack inherits macOS proxy settings for free; Docker gates SOCKS5 and Kerberos/NTLM behind Business. Disqualifying on a corporate network. | Inherit the Mac's configured proxy into dockerd's environment by default (`supervisor.rs` already builds that environment), with a `config.toml` override and an off switch, plus a `morb doctor` check that says whether containers are actually using it. Corporate CA injection is a separate later commit. | `open` |
| UX-21 | **Our own docs call our strongest capabilities `absent`** — eleven rows tabulated in CAPABILITY-GAP §16. COMPETITIVE-GAPS says Testcontainers and Dev Containers were "never tested" (ECOSYSTEM-MATRIX has four languages plus the Dev Containers CLI passing zero-config), VS Code/JetBrains `absent` (a built `.vsix` with a hijacked-stream exec terminal ships in `integrations/vscode/`), pinned kubectl "not in the repo" (`fetch_kubectl` pins v1.36.2), and "no exec, no PTY anywhere" (`Terminal/` exists with tests). An advantage nobody can see is not shipping. | One reconciliation pass over COMPETITIVE-GAPS, DIFFERENTIATION, `integrations/jetbrains/README.md`, `integrations/shell/_morb`, `docs/architecture.md` and `docs/parity.md` #18, each row checked against the code that overtook it. Audit docs keep their findings and get dated resolution notes; current-behaviour docs are simply corrected. | `open` |
| UX-22 | **Migration only points inward** — `MorbMigrate` has the transactions, helper-container volume reads and a checksum `verify`, and no way out. OrbStack has no data path out either (their #2517 is open), so this is a differentiator, and it is the answer to "what if I want to leave". | `morb migrate --to <runtime\|socket>` reusing the same transactions and verification, plus `morb export --all` writing a directory a stock `docker load` restores. Then one README line above the fold: leaving is one command, and it is tested. | `open` |
| UX-11 | **Anonymous registry reference resolver** — resolves spike UX-5. OCI Distribution defines no portable search, so a multi-registry search surface needs five vendor APIs, four of them credentialed; `RegistryImageDiscovery.swift` already encodes that refusal in its types. Tag and manifest browsing *is* anonymous everywhere, and answers "does this tag have an arm64 manifest" **before** the pull — `TrackCImageArchitecture.swift` only answers it after. | `RegistryReferenceResolver` in MorbstackKit beside `RegistryImageDiscovery.swift`: parse a reference, anonymous bearer exchange, first page of tags plus the tag's platform list. Bounded body, no redirects, no ambient config, fixture-tested. Pull-sheet disclosure is commit two. The GUI never holds a credential. | `open` |
| UX-12 | **Read-only volume content browser** — resolves spike UX-7. The mechanism was never closed: `MorbFeatures/VolumeArchiveExport.swift` and `MorbMigrate/HelperContainer.swift:117` already read volume bytes through a **stopped** `:ro` helper and `/containers/{id}/archive`. Browsing is that same lifecycle with a `HEAD` and a different `path`. A guest agent was rejected — it widens exactly the surface OPS-8 just narrowed. DIF-7 (Finder) is a successor, not a prerequisite. | `VolumeContentBrowser` in MorbFeatures sharing the helper lifecycle (create → read → always remove): one bounded directory listing from the `HEAD …/archive` stat header plus tar enumeration, tested against a recorded tar and header with no engine running. The Volumes-inspector surface is commit two. Write is out of scope. | `open` |
| UX-13 | **Image vulnerability surface** — resolves spike UX-8. `morb scan` is already a complete local pipeline (export → syft → announced-then-fetched grype DB → scan) with both tools' phone-home defaults disabled by hand. Only the binaries and the screen are missing. Bundling ~100 MB buys nothing — the grype DB makes a download unavoidable anyway — and adds two nested helpers to the signing order CLAUDE.md §1.1 calls a landmine. | A Vulnerabilities section in the Images inspector: severity counts grouped by package, expandable to fixed-in, the DB build date, and "scanned on this Mac, nothing uploaded". A real `ContentUnavailableView` when the tools are absent — no disabled placeholder. No severity column in the images table. | `blocked` (needs the first-run `scripts/fetch-scan-tools.sh`) |
| UX-14 | **Publish the benchmark harness and the watcher matrix** — we measure 1.79 s cold boot and 0% idle CPU (ENGINE-MATRIX §10); Docker publishes no macOS startup figure at all and OrbStack's benchmarks page is v0.17.0 from August 2023 with its figures locked inside images. `MorbBench` is missing only the two workloads people actually compare. | Add `git-status-bindmount` and `npm-install-bindmount-vs-volume` to `MorbBench/Benchmarks/`; publish which file watchers the `IN_ATTRIB` live-share bridge satisfies; put the cold-boot number and the one-command harness in the README's first screenful, so the claim arrives with the way to check it. | `open` |
| UX-17 | **Drive the memory balloon** — `VMManager.swift` attaches a `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` and nothing ever set `targetVirtualMachineMemorySize`; the device was configured and inert. | A slow-timer (30 min) balloon target tracking the guest's `/proc/meminfo` `MemAvailable`, extended over MRB0's `info` reply (additive `mem_total_kb`/`mem_available_kb`, guest side in `guest/morbinit/src/meminfo.rs` + `control.rs`). Pure decision logic in `MemoryBalloonPolicy.swift` (floor, headroom, unthrottled growth, step-limited/hysteresis-gated shrink — fully unit-tested, `MemoryBalloonPolicyTests.swift`), wired into `VMManager` via the existing boot-generation guard. Reasoning: `docs/design/MEMORY-BALLOON.md`. No "dynamic memory" claim added anywhere user-facing — not measured yet. **Guest-side `meminfo` reporting does nothing until `mise run guest-image` rebuilds the initramfs (CLAUDE.md §1.5); not yet verified end to end.** | `done` (source + unit tests; real-host RSS measurement via `MorbBench` and a guest-image rebuild still pending — machine lane) |
| UX-19 | **SSH agent forwarding** — no `SSH_AUTH_SOCK` handling anywhere, but `DockerHijackDetection.isHijackCandidate` nominates `POST /session`/`/grpc` unconditionally, so buildx's `--ssh` session plausibly already passes through untouched. | Commit one (evidence, not code): a **static-code trace only** of the hijack/relay path confirming `/session` is always spliced raw, recorded in `docs/parity.md` row #41 with the exact `docker buildx build --ssh default` command that would promote it to a dated PASS — that live run has not happened yet. Commit two (code): the Docker-compatible `/run/host-services/ssh-auth.sock` runtime path — guest listener always present (`guest/morbinit/src/ssh_agent_forward.rs`), host-side gate off by default (`MorbConfig.sshAgentForwarding`, `SSHAgentForward.swift`/`SSHAgentForwardServer`, vsock 2383). Full threat model and off-by-default rationale in `docs/design/SSH-AGENT-FORWARDING.md`. **Guest-side runtime path does nothing until `mise run guest-image` rebuilds the initramfs (CLAUDE.md §1.5); not yet verified end to end.** | `open` (source + unit tests done; live buildx `--ssh` acceptance and a real guest-image boot of the runtime path both queued behind the machine lane) |
| UX-15 | **Surface the guest-reachable container address** — Docker documents plainly that it "can't route traffic to Linux containers"; OrbStack's routable IPs are a headline feature. DIF-4 step 0 already mandates proving host→guest reachability at `192.168.64.x`, so this is half a day on top of work we are doing anyway. | When DIF-4's gate passes, show the container's guest-reachable address in the inspector and in `morb status --json` — before domains land, since the address is the useful half. | `open` (after DIF-4 step 0) |
| SEC-9 | **`DockerClient` builds request targets as one string, so an identifier decides where encoding stops** — `MinimalHTTP.percentEncodePath` splits at the first `?` and passes everything after it through verbatim, because five callers hand in a whole target with its query attached (`post("/exec/\(id)/resize?h=\(rows)&w=\(columns)")`, `delete("/containers/\(id)?v=1&force=1")`, `stop?t=10`, `restart?t=10`, `volumes/\(name)?force=…`). The identifier is interpolated *before* that `?`, so an id containing its own `?` moves the split left and the remainder of the target — including any control byte — is emitted raw. `MorbFeatures.EngineClient` does not have this shape: `path(_:query:)` takes the query as `[(String, String)]` and encodes each value with `percentEncodeQueryValue`, so its encoder never has to guess where the path ends. Also: `RequestPathEncodingTests.testAQuestionMarkInsideAnIdentifierIsEscaped` feeds an already-encoded `%3F`, so it cannot fail, and the behaviour its name claims is false (`docs/audit/TEST-QUALITY.md`). | Give `DockerClient` the shape `EngineClient` already has — `url(_ path: String, query: [(String, String)] = [])` — and move the five query strings into it, then drop the split so `?` is escaped like any other unsafe byte and the two implementations are identical. Fix the test to feed a raw `?`. **Do not just delete the split**: it is load-bearing today, and removing it without moving the callers first fails 13 tests in `DockerExecPTYSessionTests` — verified 2026-08-06. Grep for `post(`/`get(`/`delete(`/`put(` with a `?`, not only for direct `url(` callers; the wrappers are where the query strings live. | `open` |
| TECH-4 | **Three independent tar readers, and they have already drifted** — `mac/Sources/MorbstackAppCore/Views/Containers/ContainerFileArchive.swift` (`ContainerTarHeaderReader`, general streaming reader for arbitrary in-container paths), `mac/Sources/MorbFeatures/VolumeContentBrowser.swift` (`TarChildWalker`, immediate children of the fixed `/data` mount) and `mac/Sources/MorbMigrate/TarLite.swift` (full-file, regular entries only). This is not theoretical: the base-256 numeric field had an overflow guard in one and not the other, and a GNU long-name NUL-termination bug in the second would have made **every real-world long-name entry silently vanish from a listing** — neither could have happened with one reader. A third reader means a fourth is coming. | Promote the shared primitives into `MorbstackKit`, which all three already depend on: ustar checksum (both unsigned and historical-signed), octal and base-256 numeric decode with the overflow refusal, PAX extended-header parsing, GNU `L`/`K` long name and link handling, `cString` NUL truncation. Leave the *policies* where they are — entry budgets, root-membership rules and payload capture genuinely differ per caller and should not be unified. Note the dependency direction: `MorbFeatures` is a dependency of `MorbstackAppCore`, so the shared code cannot live in either; `MorbstackKit` is the only common base. Port each reader's tests to the shared implementation rather than deleting them. | `done` (`MorbstackKit/TarArchiveFormat.swift`: checksum, octal/base-256 decode, `cString`, typeflag→kind, PAX records, all three callers now delegate to it. Reading all three side by side turned up three more bugs beyond the two already on file: `TarChildWalker` applied a PAX *global* (`g`) header's records to the next entry as though it were per-entry (`x`); it skipped GNU `K` long-link entirely, truncating any symlink target over 100 bytes; and its own typeflag switch (plus `TarLite`'s) missed typeflag `7` (contiguous file), showing/counting it as "other" instead of a regular file. `TarLite` also had no checksum validation and no base-256 support at all — a >8 GB entry silently read as size 0 and desynced everything after it. All fixed by adopting the shared code; regression tests added for each. Swift test count 1367 → 1398, 0 failures.) |
| CLI-9 | **Shell completions promise a command we do not have, and omit seven we do** — `integrations/shell/_morb` is missing `disk`, `ports`, `diagnose`, `service`, `install-cli`, `uninstall-cli` and `export`; `morb.bash` and `morb.fish` are almost certainly the same. Worse, its `debug` description reads "Open a toolbox shell in a container, even a distroless one" while `mac/Sources/morb/main.swift:48` says the command "does not open a shell yet". That is help text promising behaviour the implementation does not have — the exact thing CLAUDE.md §1.8 forbids. `docs/DIFFERENTIATION.md` predicted "stale by 7 commands" and was exactly right, which means we knew. | One pass over all three completion files against the real subcommand list in `main.swift`, plus a check that keeps them from drifting again — a test or a `mise run check` step that diffs the completions against the parser's own command table, so the next added subcommand fails the gate rather than silently going missing. Fix `debug`'s description to say what it does today. | `open` |
| DOC-7 | **kubectl is opt-in, so a normal build cannot port-forward** — `fetch_kubectl` pins v1.36.2 against a sha256 sidecar and `mise-tasks/app` stages and signs it, but it is behind `--host-kubectl-only` and is not fetched by default. A stock `mise run app` therefore produces a bundle where the selected-Pod port-forward is simply unavailable. The COMPETITIVE-GAPS row said "not in the repo", which was wrong in a way that hid the real gap. | Decide: fetch it by default (it is pinned and verified, so the cost is download size) or state the unavailability at the point of failure rather than letting the affordance look broken. Either is fine; the current silence is not. | `open` |
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
| TASTE-5 | **`TASTE` Images "In use" column is an em-dash 26 times out of 26** — a column whose every value is the same non-value teaches the eye to skip columns (review F4). | Populate it the way Volumes' usage columns fill after a Disk scan, or drop the column and leave the fact to the inspector. Blocked-by: nothing. | `open` |
| TASTE-6 | **`TASTE` Disk inspector leaks the recovery state machine** — "Recovery Phase — host-grown", "Saved Target", "the guest filesystem still needs verified proof", "reviewed growth transaction" printed as user copy (review F5). | One human status line ("Disk growth is paused until the guest filesystem check completes"); internal detail rows behind a disclosure. Blocked-by: nothing. | `done` |
| TASTE-7 | **`TASTE` Migration inspector is a wall** — ~17 rows + 4 footnotes in one scroll, three zero-value eligibility rows, defensive copy; and Morbstack lists itself among migration *sources* (review F6). | Collapse zero rows to one line when the source reports no volumes; one sentence per footnote; badge Morbstack as the destination or remove it from the source table. Blocked-by: nothing. | `open` |
| TASTE-8 | **`TASTE` Long identifiers fight trailing alignment in the container Overview** — full digests, image refs, and multi-sentence Ports copy in a ~300 pt trailing value column; nine section headers where half hold 1–2 rows (review F7). Composition issue independent of the filed clipping bug. | Stack long identifiers label-above-value full-width (the Volumes "Guest Mount Point" pattern), middle-truncated and copyable; merge Identity/Lifecycle/Configuration into one group; demote the Ports explanation to a one-line footnote. Blocked-by: the clipping fix (same file, coordinate to avoid churn). | `open` |
| TASTE-9 | **`TASTE` Unit-and-word sweep** — Networks "Containers" column mixes "3" with "None" (a count column says 0); Builds inspector filler row "Storage — Included in deduplicated total"; Statistics states its sampling cadence twice (review F8). | One pass fixing all three; no layout changes. Blocked-by: nothing. | `open` |
| TASTE-10 | **`TASTE` Disk inspector states one capacity five ways** — "Apparent — 77.31 GB", "Current Raw Capacity — 77.31 GB", "Configured Capacity — 77.31 GB", "Capacity State — Matches configuration", and the summary sentence "The existing disk matches the configured capacity." Three labels for one number across two adjacent sections, then a row and a sentence for one state; and when readiness is unreported but the pending action is Stop Engine, the lead sentence ("Morbstack has not checked yet whether this disk can grow…") never names the remedy the button under it offers (pass 2, exposed by the TASTE-6 fix). | Merge the two capacity sections into one story: show "Configured Capacity" only when it differs from current; suppress `diskCapacity.summary` when the Capacity State row already says it (`matchesConfiguration`); when the action is Stop Engine, lead with the stop-engine sentence. Pure subtraction. Blocked-by: nothing. | `open` |
| TASTE-11 | **`TASTE` One predicate, two rows in the Volumes Identity section** — "Volume — Anonymous" and "Prune — Eligible" are both computed from `isAnonymousVolumeName`; the second restates the first, and "Eligible" reads as a safety verdict directly above "Usage — Not scanned yet", where usage is exactly what is unknown (pass 2, found in the pane TASTE-4 cleaned). | Keep "Volume — Anonymous/Named"; delete the "Prune" row and leave the prune consequence where it already costs something — the Remove button's caption. Blocked-by: nothing. | `open` |
| TASTE-12 | **`TASTE` The absence sweep stopped at Volumes** — Images inspector still says "Reported use — Not reported" plus a remedy-free footnote ("Docker did not report container usage for this image."), the Stacks project inspector still carries "Compose files — Not reported", and the app now has two vocabularies for one category of absence: "Not scanned yet" (Volumes) vs "Not reported" (Images) (pass 2). | Apply the TASTE-4 pattern to Images and the Stacks project inspector: one row per absence, at most one footnote, footnote names what changes the state; one vocabulary — "Not scanned yet" where a scan is the remedy, "Not reported" only where Docker genuinely has no answer. Coordinate with TASTE-5 so the "In use" column and the inspector speak the same words. Blocked-by: nothing. | `open` |

## UI-051 · Right-side controls should be swallowed by the inspector · `done`

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
