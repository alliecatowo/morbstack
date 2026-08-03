# Product parity audit

Status: active delivery contract. Last reconciled 2026-08-02 against the
repository and current official OrbStack documentation. This is a delivery
plan, not a claim that every item has shipped or been live-verified.

## Product outcome

Morbstack is the best macOS container stack: a free-for-everyone,
Apache-2.0, no-account, no-telemetry, genuinely drop-in replacement for
Docker Desktop. It must match or exceed the practical local-development
experience of OrbStack while retaining an inspectable, unmodified upstream
Docker Engine and a fully native macOS operations app.

The standard is not a compelling demo. A new user must be able to install
Morbstack on a Mac with no Docker tooling, open a terminal or IDE, and use
Docker, Compose, Buildx, Testcontainers, Dev Containers, Kubernetes and
local-service URLs without keeping the app open, exporting variables, or
following a repo-only setup guide.

## Product foundation that already exists

- A lightweight Virtualization.framework guest running upstream dockerd and
  containerd, with a persistent sparse disk and socket activation.
- Docker Engine API relay, loopback published ports, Compose, VirtioFS
  shares, Rosetta amd64 execution, and an opt-in k3s + cri-dockerd path
  sharing Docker's image store.
- A native SwiftUI/AppKit application using macOS tables, inspectors,
  sidebars, forms, standard toolbars, real empty-state actions and no web
  view or custom dashboard design system.
- A careful coexistence foundation: non-destructive Docker context setup,
  reversible CLI installation, safe kubeconfig merge, line-preserving config
  saves, deliberate destructive-action review, and daemon/Kubernetes
  reconciliation.

## Current implementation evidence

The entries below are deliberately narrower than release claims. They name code
that is integrated in the current branch; a new-Mac, real-VM compatibility
matrix is still required before an entry becomes a public out-of-the-box
guarantee.

| Delivery | Evidence | Status |
| --- | --- | --- |
| Self-contained runtime and host CLI | `e329140` packages a signed, versioned runtime manifest plus upstream Docker, Compose, and Buildx in the app; first-run setup links only reviewed user-owned locations. | Implemented; clean-profile live verification pending. |
| Direct Docker discovery and durable ownership | `e329140` creates `~/.docker/run/docker.sock` only when it is safely absent; `1dda777` adds an explicit signed per-user `SMAppService` LaunchAgent; `ddac4a3` offers it default-off in first run. | Implemented; registration and clean-profile live verification pending. |
| Diagnostics and recovery | `e329140` adds an offline, bounded, redacted `morb diagnose`; `cacda50` exposes actual Kubernetes startup diagnostics and an escape path. | Implemented; support-bundle smoke checked; full real-VM recovery matrix pending. |
| Operational UI | `0c45d08` makes BuildKit cache pruning a real engine-wide confirmed action; `317785f` makes disk-capacity states truthful; `51519d5`, `b63c813`, and `c39cf04` record full-window table readability repairs. | Implemented; real-window Computer Use review completed for these routes. |
| Port behavior | `c04e343` provides an explicit advisory TCP/UDP loopback preflight and records the protocol required for race-free create/start rejection. | Implemented as a diagnostic; synchronous reservation remains P1. |

## The parity program

### P0 — make the first ten minutes work

1. **Self-contained release runtime.** Package signed, versioned guest boot
   artifacts and their digest manifest in the app; atomically install and
   activate them in Morbstack-owned data with a retained prior version for
   recovery. K3s is an on-demand signed payload, never a repo-script error.
2. **Durable service and direct discovery.** Install a user-owned daemon
   service and a reversible `~/.docker/run/docker.sock` integration without
   clobbering another runtime. A clean install intentionally makes the
   Morbstack context current and does not require `DOCKER_HOST`.
3. **One transactional onboarding.** Preflight, show the exact changes,
   install the runtime/service/`morb`/Docker/Compose/Buildx/context/socket,
   start the engine, and run real health probes. It must be resumable and
   offer a specific repair path. **Current implementation:** the explicit CLI
   setup and first-run sheet now re-read every host integration and report
   daemon/Docker reachability without starting a stopped runtime; the complete
   engine-starting transaction and clean-profile live evidence remain P0 work.
4. **Release evidence, not documentation promises.** Run a clean-profile
   compatibility matrix for direct socket discovery, Docker contexts,
   Buildx, Compose, Testcontainers, Dev Containers and core IDE paths.

### P1 — make the daily development loop reliable

1. Extend the current explicit-create port preflight into a create/start TCP lease
   protocol, then add UDP forwarding while preserving loopback-safe defaults. The
   preflight rejects known fixed TCP conflicts before an ordinary create reaches the
   guest, but it is intentionally not a reservation and does not cover dynamic/range
   ports or later starts.
2. Turn unshared/misresolved bind sources into clear Docker errors, then
   ship FSEvents-to-inotify forwarding or an explicit synced-share tier.
3. Add grow-only disk expansion, truthful idle-stop wording until genuine
   suspend/restore is demonstrated, and a redacted `morb diagnose` bundle
   with structured VM/DNS/share/forwarder/Kubernetes health.
4. Make the operations app real: durable build progress/cancel/cache,
   stack actions, container logs/stats/exec/debug, safe image/volume export
   and inspection, and Kubernetes workload/event/log/exec/port-forward
   operations with reasons and recovery.
5. Finish a non-destructive native migration assistant: detect, dry run,
   selected image/volume transfer, verification, report, rollback guidance
   and explicit credential remediation.

### P2 — exceed the competing native experience

1. `*.morb.local`, automatic local HTTPS with a narrowly scoped CA, direct
   service opening/copying, macOS scoped DNS and VPN correctness.
2. Native file access with truthful read/write semantics; use explicit safe
   export or temporary inspection until Finder integration is real.
3. Toolbox-backed `morb debug` for distroless containers; never market a
   placeholder shell.
4. Isolated, ephemeral agent/untrusted-code sandboxes first; then general
   Linux machines, cloud-init, SSH/editor integration and, only where the
   service foundation supports it, advanced hardware forwarding.

## What OrbStack establishes as the experience bar

OrbStack currently offers automatic local domains and HTTPS, host/container
networking, native access to container/image/volume files, a distroless
debug shell, operational menu-bar actions, and Linux machines. Morbstack
matches the direction with a stronger user contract: free for commercial use,
Apache-2.0, no account, no required licensing network path, no telemetry,
and upstream-engine provenance that can be inspected and reproduced.

Primary sources:

- [OrbStack domains](https://docs.orbstack.dev/docker/domains)
- [OrbStack HTTPS](https://docs.orbstack.dev/features/https)
- [OrbStack native files](https://docs.orbstack.dev/features/native-files)
- [OrbStack Debug Shell](https://docs.orbstack.dev/features/debug)
- [OrbStack Linux machines](https://docs.orbstack.dev/machines/)
- [OrbStack licensing](https://docs.orbstack.dev/licensing)
- [OrbStack pricing](https://orbstack.dev/pricing)

## Claims discipline

The destination above is binding. Public status must remain evidence-based:
implemented code is marked *pending live verification* until the real
clean-profile or real-VM check passes. `docs/parity.md` preserves historical
results and must gain dated follow-up evidence rather than silently changing
past results. Comparison, site and setup documentation must say *released*,
*implemented pending verification*, or *planned* explicitly.

## Delivery rules

- Reliability, installation and API behavior precede ornamental UI work.
- A claimed user action has a real service implementation, progress,
  cancellation/failure behavior and recovery path.
- Do not silently touch other runtimes, Docker contexts, kubeconfig files,
  sockets, credentials or user data.
- Run builds and live VM checks in one serialized integration lane; agents
  use static review and focused tests only when explicitly scheduled.
- Every completed delivery is committed deliberately and the audit/roadmap is
  updated with its evidence state.
