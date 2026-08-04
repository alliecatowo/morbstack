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

### SP-4 · Remove the Docker-to-build-Docker bootstrap · `decided`
**Decision:** [docs/design/ENGINE-BUILD-DECISION.md](docs/design/ENGINE-BUILD-DECISION.md). Publish
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

### SP-5 · Fate of the ~1,750 LOC of inert subsystems · `open`
**Deliverable:** wire-or-delete, per subsystem, with reasons. `MorbShareSyncProtocol.swift` (1,002
LOC, zero callers, complete auth + wire protocol), `MachineImageAdmission.swift` (581 LOC, zero
callers, `assess()` has **no success path at all**), `LocalDomainClaimReconciler`, `TarLite.swift`.
Dead code that ships is worse than a stub screen: it looks like a feature to every reader.
**Rewrites:** DIF-6, DIF-13.

### SP-6 · `-P` session persistence root cause · `in-flight` (source correction; runtime pending)
**Deliverable:** prove direct and restart-policy allocation ownership over a real guest/host lifecycle.
`3960359` makes direct one-shot allocator sessions close their guest fd at the observed
outcome, installs a durable owner before direct lifecycle admission for restart-policy
containers, and serializes direct/recovery registration by immutable container ID. It is a
source correction, not a result: prove normal start/restart, automatic policy restart on a
keep-alive API connection, direct/recovery contention, and VM restart against the rebuilt
candidate before closing this spike.
**Rewrites:** EN-2.

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
| EN-2 | `-P` across stop/start/restart | `3960359` is source-covered for direct/durable session ownership and direct-FD retirement; prove TCP/UDP reachability, automatic restart policy on a keep-alive client, direct/recovery contention, and VM restart after rebuilding the candidate. | `in-flight` (SP-6 runtime acceptance) |
| EN-3 | Bind mounts `/etc`, `/var`, unshared roots | The 2026-08-03 candidate recorded refusals for `/etc`, `/var`, `/Library`, and symlink traversal, plus working `/tmp`, `/private/tmp`, and `$HOME` bind writes. `33fd00e` then changed bind-admission and relay behavior; rebuild the guest and rerun this exact matrix before assigning those results to the current source. See `docs/audit/PROXY-FRAMING.md`. | `in-flight` (post-`33fd00e` rebuilt-guest acceptance) |
| EN-4 | `morb disk grow` | Fix `keyNotFound: 'device'` host/guest contract mismatch. Image grew to 72 GiB while the guest filesystem stayed 62.4 G, and a **refused** grow still mutated configured capacity. Add the journal tests it never had. | `in-flight` (`codex/parity-en4-disk-grow`) |
| EN-5 | Reclaim the 72 GiB `disk.img` | Safe reclamation path for the test artifact left on the dev machine | `open` |
| EN-6 | `host.docker.internal` without `--add-host` | Resolves by default | `open` |
| EN-7 | Live-share / hot reload proven | First compile was today. Publish a **watcher conformance matrix**: the mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB` only — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`. Also `liveSharePaths` defaults to `[]` with **no CLI or GUI writer**. | `open` |
| EN-8 | Testcontainers (Java/Go/Node/Python) | Never tested | `open` |
| EN-9 | Dev Containers | Never tested | `open` |
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
| OPS-8 | **Security review of untrusted-input surfaces** | vsock 1024/2375/2376/2377/2378/2379/2380/2381 and the MCP server. **Attempted three times, blocked by a model-side safety classifier every time. Treat as UNREVIEWED.** Needs a fresh session or an explicit permission rule. Gates REL-5. | `blocked` (tooling) |
| OPS-9 | CI guest-image job | Per SP-4: delete the "Require Docker Buildx" failing step, add `fetch-guest-assets.sh --morbstack-dockerd-only` (new flag) to download the pinned `morbstack-dockerd` Release asset instead of building it on the macOS runner | `open` |

## Tests — coverage runs backwards from risk

| ID | Ticket | Deliverable | State |
| --- | --- | --- | --- |
| TST-1 | `VMManager.swift` (2,097 LOC) | No test boots or restores a VM | `open` |
| TST-2 | `MorbDiskGrowth` journal | No test; it mutates a 68 GB disk image | `open` |
| TST-3 | Live-share transport + both guest modules | ~1,850 LOC, self-described "authority boundary", zero tests | `open` |
| TST-4 | `PublishAllPortAllocator` + guest `publish_all.rs` | Untested on both sides | `open` |
| TST-5 | vsock relay under load | Half-close, backpressure, cancellation | `open` |
| TST-6 | Keep-alive regression test | Assert the **second** request on a reused connection is inspected. Its absence is why EN-1 shipped. Focused source coverage exists; the recorded runtime result belongs to the dated matrix and must be rerun with EN-1. | `done` (source coverage; current runtime pending) |

## UI — [docs/audit/UI-AUDIT.md](docs/audit/UI-AUDIT.md), 32 issues: 3 blocker, 9 major, 14 minor, 8 polish

| ID | Ticket | Severity | State |
| --- | --- | --- | --- |
| UI-1 | Fixture-mode provenance — `--tour-fixtures` must be visibly and accessibly distinct from live data | blocker | `done` (title/footer/a11y truth plus `1f5d779` source guards against Builds/Stacks external operations; real-window/XCUITest evidence pending) |
| UI-2 | Port renders as `18,099` — thousands separator on a port | blocker | `done` (string-typed inspector display + focused regression) |
| UI-3 | Add Show/Hide Sidebar to the View menu | major | `open` |
| UI-4 | Unmatched search must use `ContentUnavailableView.search` | major | `open` |
| UI-5 | Selecting a container must expose inspector content | major | `open` |
| UI-6 | 8 undescribed elements, 3 contrast failures | major | `blocked` (SP-8) |
| UI-7 | Containers toolbar: ~12 symbol-only items in 6 groups against a cap of 3, incl. **two identical trash cans** | major | `open` |
| UI-8 | Toolbar items vanish at narrow width with no overflow — with UI-3, some commands become unreachable | major | `open` |
| UI-9 | Images table: Repository column crushes to one character per row | major | `done` (native `TableColumn` minimum width; narrow-window evidence still pending) |
| UI-10 | Disk inspector overlaps and overdraws the table | major | `open` |
| UI-11 | Container uptime freezes ("Up 23 seconds" vs `docker ps` "Up About a minute") | major | `open` |
| UI-12 | **Second UI pass** — Stacks, Kubernetes, Networks, Builds, Migration, Settings, ⌘K, menu-bar extra, light mode, prune/pull were never toured. The 32 issues are a floor. | major | `open` |
| UI-13 | Add accessibility identifiers | major | `blocked` (SP-8) |
| UI-14 | XCUITest cannot attach screenshots — "Image creation failed. Disable automatic screenshots in your test plan's configuration." | minor | `open` |
| UI-15 | The remaining 14 minor + 8 polish items in UI-AUDIT.md | minor/polish | `open` |

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
| REL-1 | `scripts/release.sh`, `docs/RELEASING.md`, `.github/workflows/release.yml` | All referenced by name as the source of truth; **none exist**. Shape now set by SP-4. | `open` |
| REL-2 | Notarization | Not one `notarytool` call in the repo | `blocked` (SP-9) |
| REL-3 | Homebrew cask | | `blocked` (SP-9) |
| REL-4 | Sparkle update channel | `docs/sparkle.md` referenced and absent | `blocked` (SP-9) |
| REL-5 | Make the repo public | | `blocked` (OPS-8) |

## Differentiation — only after parity is `accepted`

Ranked by impact per effort. Full rationale in [docs/COMPETITIVE-GAPS.md](docs/COMPETITIVE-GAPS.md).

| ID | Ticket | State |
| --- | --- | --- |
| DIF-1 | Hot reload on by default + published watcher conformance matrix | `blocked` (EN-7) |
| DIF-2 | Container `exec` + a real PTY in the app — no `exec` in `DockerClient.swift`, no PTY view; table stakes for both competitors | `open` |
| DIF-3 | Publish the benchmark harness; add `git-status-bindmount` and `npm-install-bindmount-vs-volume` | `open` |
| DIF-4 | **Container domains via unprivileged mDNS** — mechanism decided in [`docs/design/DNS-DECISION.md`](docs/design/DNS-DECISION.md). Six steps, **~3–4 weeks, zero admin prompts**: (0) prove host→guest reachability at `192.168.64.x` on Wi-Fi/Ethernet/VPN — **hard gate**, fall back to `127.0.0.1` + high-port URLs if it fails; (1) mDNS registrar in `morbstackd` (`A` records only, `LocalOnly`, no advertised service type, conflict handling, Docker-event lifecycle); (2) name derivation wired to the existing `MorbLocalDomain`/`LocalDomainClaimReconciler`; (3) guest-side Host-header reverse proxy owning `:80`/`:443` inside the VM, pinned like every other guest binary, with listening-port auto-detection; (4) withdrawal paths (stop/remove, suspend, wake, VPN transition, hostile-`.local` detection); (5) `morb domain` CLI + inspector affordance. No wildcards — do not advertise them. | `open` |
| DIF-5 | **HTTPS via a name-constrained local CA** — **~2–3 weeks after DIF-4**. CA key in the Keychain, ACL-restricted; per-name short-lived leaves; name constraints as defence in depth with honest browser-by-browser verification (Firefox has its own trust store). **Two things need a written ruling before code:** the trust installation is the one and only user password prompt in the whole domains feature, and if the proxy lives in the guest then leaf private keys live in the guest — recommended shape is issue-on-host, push over vsock, hold in guest tmpfs, CA key never leaves the host. | `blocked` (DIF-4) |
| DIF-6 | Routable container IPs | `blocked` (SP-5) |
| DIF-7 | Native file access to volumes (Finder) | `open` |
| DIF-8 | Distroless debug toolbox — **the one thing OrbStack actually paywalls** | `blocked` (DIF-2) |
| DIF-13 | Linux machines | `blocked` (SP-5) |

**Not building:** Docker Desktop's compliance suite — ECI, Hardened Desktop, registry access
management, SSO, air-gapped install, Settings Management. Enterprise procurement is the wrong market
for a one-maintainer open-source project.
