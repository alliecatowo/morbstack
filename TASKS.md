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

### SP-8 · Accessibility identifier scheme · `open`
**Deliverable:** a naming convention, before anyone adds hundreds of them. The codebase currently has
**zero** `accessibilityIdentifier`. Decide route-scoped vs global, and how identifiers relate to the
XCUITest queries that currently rely on system semantics alone.
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
| OPS-8 | **Security review of untrusted-input surfaces** | vsock 1024/2375/2376/2377/2378/2381/2382 and the MCP server. (2379, the publish-all allocator, and 2380, the listener probe, are both DELETED — 2380 in `51dc543`, 2379 with the rest of the publish-all path in TECH-1 on 2026-08-04. New surface added by TECH-1: the 2382 host-side port-lease listener's request-line parser — `GuestPortLease.parseRequest` in `mac/Sources/MorbstackKit/GuestPortLease.swift` — and the wrapper's reply parser — `parse_reply`/`parse_invocation` in `guest/morbinit/src/proxy_wrapper.rs`. Both parse guest-controlled input and need review.) **Attempted three times, blocked by a model-side safety classifier every time. Treat as UNREVIEWED.** Needs a fresh session or an explicit permission rule. Gates REL-5. | `blocked` (tooling) |
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
| REL-5 | Make the repo public | | `blocked` (OPS-8) |

## Differentiation — only after parity is `accepted`

Ranked by impact per effort. Full rationale in [docs/COMPETITIVE-GAPS.md](docs/COMPETITIVE-GAPS.md).

| ID | Ticket | State |
| --- | --- | --- |
| DIF-1 | Hot reload on by default + published watcher conformance matrix | `blocked` (EN-7) |
| DIF-1a | **Synchronized shares on the live-share transport** — the correctness-mode alternative to the `fchmod`→`IN_ATTRIB` bridge (colima#1244 is that bridge's documented production failure) and the honest successor to the deleted `MorbShareSyncProtocol` (SP-5). Scope: (1) extend the existing authenticated vsock-2381 session (`MorbLiveShareTransport` ↔ `live_share_receiver.rs`) with content-bearing messages — per-file records carrying bytes + SHA-256, chunked, over the already-proven HMAC handshake; (2) guest writer in `morbinit` doing atomic tmp-write→fsync→rename into a real guest-local directory (ext4/virtio-blk data disk, **not** the virtiofs mount — the guest kernel has no btrfs), so watchers get real `IN_MODIFY`/`IN_CREATE`/`IN_DELETE`; (3) per-share opt-in surfaced in config/CLI (`liveSharePaths` still has no writer — EN-7); (4) guest-image rebuild + repin (guest lane). **Acceptance: a Go watcher using `air` rebuilds on host edits** — fsnotify treats `Chmod` as a distinct op, so `air` is precisely the case the current bridge cannot serve; chokidar/watchdog re-verified unbroken. See `docs/design/INERT-SUBSYSTEMS-DECISION.md` §1 and TECH-2 option (b). | `open` (needs guest lane + live engine; 1–2 wk) |
| DIF-2 | Container `exec` + a real PTY in the app — no `exec` in `DockerClient.swift`, no PTY view; table stakes for both competitors | `open` |
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

### TECH-3 · Does vz virtio-blk discard punch holes in `disk.img`? · `open` (spike)
**Deliverable:** a measured result and decision. Guest: mount ext4 `-o discard` (or run `fstrim`) after
deleting images; host: compare `disk.img` allocated blocks (`du` vs `ls -l`) before/after. If holes are
punched, ship `discard`/periodic `fstrim` and the never-shrinks defect (DIFFERENTIATION T8) dies for ~free;
if not, design compact-by-copy. Note: `disk.rs`'s btrfs `discard=async` path is dead code on the shipped
kata kernel (no btrfs).
**Rewrites:** EN-4/EN-5 scope, the kernel-fork (btrfs) priority.

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
| CONC-2 | Stale-generation probe overwrites fresh diagnostics | `VMManager.beginControlProbe` calls `noteGuestPinged`/`noteDockerDataOnDisk`/`noteGuestShares` on the probe queue **before** the `generation == probeGeneration` guard (`VMManager.swift:1661-1684`). A probe from a superseded boot returning `.ready` after `invalidateControlReadiness()` clobbers the freshly-reset snapshots, so `morb status`/`morb doctor` can report the wrong boot's data. Fix: move the three `note*` calls inside the generation-checked block — they are already duplicated there. | `open` |
| CONC-3 | `whenGuestPowersOff` registration races `guestDidStop` | Both are scheduled onto the same serial queue from different triggers with no ordering guarantee (`VMManager.swift:936-947` vs `:2073-2081`). Losing the race burns the full 5 s `guestPowerOffTimeout` on every clean stop where the guest powers off faster than the control-ack round trip — contradicting the comment at `:2078` that says releasing early "saves the five seconds its deadline would otherwise burn". | `open` |
| CONC-4 | `Daemon.shutdown()` bypasses `forwarderQueue` | `Daemon.swift:1300` calls `forwarder.stop()` directly on `controlQueue`, while every other call site funnels through `forwarderQueue` precisely so "a fast running → stopped → running flap cannot reorder into a stop that lands after the start it preceded" (`Daemon.swift:109-116`). Currently masked by the `exit(0)` shortly after; becomes live the moment shutdown grows a longer tail. | `open` |
| CONC-5 | `UnixSocketServer.stop()` does not wait for its cancel handler | Asymmetric with `TCPListener.stop()`, which blocks on `closedSignal` for exactly this reason (`TCPListener.swift:322-354`). Not currently exploited, but two listener types that otherwise mirror each other disagree on whether `stop()` means "the path is free". | `open` |

## Protocol contract — from the deep architecture audit (2026-08-03)

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| PROTO-1 | **`morbinit_version` is parsed and never consulted** | The field `docs/protocol.md` nominates as *the* compatibility probe has zero live consumers — decoded at `GuestControl.swift:91,163` and referenced nowhere else but two test assertions. Every future breaking change therefore has no host-side gate, despite the doc claiming one exists. Make the host read it once per boot and surface it when older than a compiled-in minimum. | `open` |
| PROTO-2 | Stale docs for removed port 2380 | `listen_probe.rs` and `GuestListenerProbe.swift` were deleted in `51dc543`; `docs/protocol.md` was scrubbed but `architecture.md` (3 sites) and `ENGINE-MATRIX.md` still describe it as live. Already corrected in `TASKS.md` and `MASTER-PLAN.md`. | `open` |
| PROTO-3 | Inconsistent backpressure at connection caps | 2376/2378 emit `ERR busy\n` — a deliberate hardening pass their own comments describe as fixing exactly this. 1024, 2375 and 2381 still **silently drop** over-cap connections with only a log line, which is indistinguishable from a peer that never spoke the protocol. Apply the fix uniformly. | `open` |
| PROTO-4 | 2377 k8s transfer has no in-flight timeout and is serial | A 10 s preamble wait bounds negotiation, but nothing bounds the body afterwards. One stalled ~512 MB `PUT` wedges every later `morb k8s enable` from any client indefinitely (`k8s.rs:1022-1026` documents the serial design as intentional). | `open` |
| PROTO-5 | jsonlite's flat-only contract is enforced only by convention | `jsonlite` rejects **any** nesting, poisoning the whole frame (`jsonlite.rs:123-140`). Every host MRB0 struct goes through Foundation's fully general `JSONEncoder` with no check. Adding one nested field compiles, passes Swift round-trip tests, and then fails 100% of that message type at runtime with a generic "invalid JSON". Add a host-side flatness assertion. | `open` |
| PROTO-6 | Guest plumbing duplicated across protocols | Byte-at-a-time line reading is reimplemented three times (`dial.rs:125`, `datagram.rs:49`, `k8s.rs:850`) — and `live_share_receiver.rs:463` already calls `dial::read_preamble_line`, proving it is reusable. `err_line`, `negotiate`, `DeadlineStream`/`ConnGuard`, `send_busy` and the accept-loop skeleton are each duplicated 2–5 times. Three primitives would replace all of it. | `open` |

## Module graph — from the deep architecture audit (2026-08-03)

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| MOD-1 | **2,603 LOC of confirmed-dead code in MorbstackKit** | Resolved by SP-5 (2026-08-03): all three files deleted, plus the `LocalDomainClaimReconciler` loopback model and its dead `PortForwarder` snapshot producer. See [`docs/design/INERT-SUBSYSTEMS-DECISION.md`](docs/design/INERT-SUBSYSTEMS-DECISION.md); recoverable from git (`aef003a`, `3157c39`). | `done` |
| MOD-2 | Split MorbstackKit along the boundary it already respects | ~20 files are linked only by `morbstackd`; everyone else talks over IPC. Proposed `MorbstackProtocol` (no deps) ← `MorbstackDaemonCore` ← `morbstackd`. ~30 file moves plus one import line each, **zero logic changes**, because the consumer boundary already matches. | `open` |
| MOD-3 | Two hand-maintained Docker Engine model sets will drift | `AppCore/Models.swift` (1,450 LOC typed structs) vs `MorbFeatures/EngineClient.swift` raw `[String: Any]`. `morb` deliberately never links AppCore, so this is a real architectural fork, not an oversight — collapsing it is multi-day. Decide whether to unify or to accept and document the fork. | `open` |
| MOD-4 | `K8s.installPort` = 2377 lives outside `MorbVsockPorts` | The port-constant registry is not actually singular (`K8s.swift:53` vs `VMManager.swift:2102-2119`). | `open` |
| MOD-5 | Adding one MRB0 field touches 6–9 files across 3 modules | Wire protocol is hand-duplicated on both sides with no codegen. Shotgun surgery by construction; grows linearly with feature count. | `open` |

## Ecosystem — from EN-8/EN-9 acceptance (2026-08-04)

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| ECO-1 | **Silent wrong-daemon execution — the biggest ecosystem gap** | Unconfigured, Morbstack is *invisible* to Testcontainers Node/Go/Java: they never read `docker context`, find no `DOCKER_HOST`, fall through to whatever socket exists, and run **green against Docker Desktop 27.4.0**. Reconfirmed live in three languages. This is worse than failing — a user's suite passes while testing the wrong engine. Fix so that a correctly installed Morbstack is discoverable with **no environment variables at all**: own `/var/run/docker.sock` (or a documented equivalent), and make first-run create *and select* a `morbstack` docker context. Directly serves the standing "single-path install" requirement. | `open` |
| ECO-2 | `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` is mandatory, not optional | Without `=/var/run/docker.sock`, Ryuk's socket mount **500s in every language**. Ryuk itself works fine once set (0.14.0/0.8.1/0.12.0, self-reaps in ~10 s, `TESTCONTAINERS_RYUK_DISABLED` never needed). Requiring the incantation is a gap; folds into ECO-1. | `open` |
| PROTO-7 | dockerd `MinAPIVersion` blocks older clients | Verified on the live socket: `/v1.32/info` → **400**, `/v1.44/info` → **200**. This is upstream moby 29's default of 1.40, **not** a Morbstack behaviour. `testcontainers-java` ≤1.20.x probes `/v1.32/info`, gets the 400, and silently fails over to another daemon. Proposed: `DOCKER_MIN_API_VERSION=1.24` in morbinit's dockerd env — verify moby 29 honours a floor that low before shipping. Would make Morbstack the engine-29 distribution that the ≤1.20.x installed base works against; Docker Desktop is only insulated because it still ships engine 27. | `open` (routed to the guest lane) |

**What passed**, all with real Postgres-backed suites against server 29.7.1: Testcontainers Node 12.1.0,
Python 4.15.0, Go v0.43.0 and Java 1.21.4 (warm totals 1.7–5.9 s, clean teardown, zero leftovers), and
Dev Containers CLI 0.88.0 in full — `up`, two-way workspace bind mount, `postCreateCommand`, `exec`,
and a features/derived-image build through Morbstack BuildKit. Only Testcontainers **Python** and the
Dev Containers CLI find Morbstack without `DOCKER_HOST`; they are the two that read `docker context`.
Evidence: [audit/ECOSYSTEM-MATRIX.md](docs/audit/ECOSYSTEM-MATRIX.md).
