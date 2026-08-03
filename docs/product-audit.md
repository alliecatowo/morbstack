# Product parity audit

Status: active delivery contract. Last reconciled 2026-08-03 against the
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

The prioritized execution order and non-claims are maintained in
[`drop-in-delivery-plan.md`](drop-in-delivery-plan.md). It distinguishes the
historical live parity audit from source that is implemented but still awaiting
the clean-profile release proof.

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
| Direct Docker discovery and durable ownership | `e329140` creates `~/.docker/run/docker.sock` only when it is safely absent; `1dda777` adds an explicit signed per-user `SMAppService` LaunchAgent; `ddac4a3` offers it default-off in first run. `38e423a` also requires a current `morbstack` context to point at this runtime's socket before reporting it already current. | Implemented; registration and clean-profile live verification pending. |
| Diagnostics and recovery | `e329140` adds an offline, bounded, redacted `morb diagnose`; `cacda50` exposes actual Kubernetes startup diagnostics and an escape path; `2e44f05` adds the same `MorbDiagnostics` collector to the native engine-error state. `196a9de` adds an inspection-only Settings command-line status section: it reads the existing Docker context, discovery socket, bundled-tool plans, and process overrides, and sends any proposed change back through the reviewed setup flow. The app asks for an explicit parent folder, never starts or contacts Docker/the daemon during collection, tells the person to review the bundle, and offers Finder reveal rather than upload/share. | Implemented; support-bundle smoke checked. The Settings status has source evidence but no clean-profile or real-window acceptance yet. The native recovery route has source/HIG evidence but awaits serialized real-window acceptance, and the full real-VM recovery matrix remains pending. |
| Builds and operational UI | `9c0cee5` adds a reviewed, native BuildKit local-build workflow; `5577f44`, `9f4d9b0`, and `8eab128` add a bounded active-builder Buildx history workflow. It explicitly lists completed Buildx records, then reads details only for a selected record, and logs only after a separate request; it never infers history, detail, or logs from BuildKit cache. Each read uses the Morbstack socket and bundled tools, is time- and output-bounded, and presents truncation rather than claiming a complete transcript. `e066891` adds a native selected-images migration workflow; `d77b81a` makes the native Migration inspector show the read-only named-volume eligibility plan; `6b3aa92` adds real container network statistics; `34f3353` adds pod log/event inspection; `acd0925` makes disk-capacity and resize-readiness states truthful. `0d132e6` keeps the Builds cache total to Docker-attributed nonshared bytes, so it does not overstate storage also attributed to images. | Implemented pending corresponding real-engine acceptance. In particular, the Buildx list/details/logs path has not been exercised against a clean engine or promoted to a durable-history/release claim. The full-window Computer Use review is recorded for safe routes; no build, migration, or Kubernetes mutation was performed during it. |
| Migration transfer boundary | `MigrationReadOnlyPlanner` reads image and named-volume inventories without mutation. `ImageMigrationTransaction` supports the selected-image native/CLI workflow; `VolumeMigrationTransaction` backs the separately confirmed CLI **and native** selected-volume workflows. | Mechanically implemented pending a real two-engine matrix. The native document-modal flow starts with an empty selection of eligible records, re-prepares those exact names before review, gates a missing helper-image pull behind separate default-off consent, reports completed-volume count plus real archive bytes without a false percentage/cancel/verification claim, and presents the durable report. It never offers `--all`, overwrites, merges, deletes, or inspects existing destination contents. `8130382` adds the final Transfer-click reprepare: a changed source/destination/item/helper/safety fact returns to review before execution, and selection/dismissal are held while rechecking. Per-item execution still rechecks helper and destination state before creation. |
| Port behavior | The fixed-TCP Docker create/start path retains a real loopback listener through a bounded create-ID response and exact-204 handoff. A narrow dynamic TCP `HostPort` create transaction accepts only an omitted value, exact `HostPort: ""`, or exact string `HostPort: "0"`; it allocates a concrete loopback port, rewrites only that bounded create document, and retains the same listener through the recognized handoff. `46d0b23` adds restart-safe recovery: after VM/daemon shutdown deliberately releases the listener, a bodyless canonical-full-ID start can inspect the same stopped container's fixed loopback TCP `HostConfig.PortBindings` and atomically re-reserve/associate it before relaying the unchanged start. `50a28cc` withholds a TCP or UDP endpoint whose Docker snapshot reports competing targets, emitting a diagnostic instead of letting collection order route traffic. | Fixed and the three bounded dynamic TCP forms have source-level race-resistance through recognized exchanges, including the bounded exact-ID restart recovery path. `-P`, ranges, every other dynamic spelling or opaque/mixed creation, UDP synchronous leases, opaque framing, name/ID-prefix starts, unsupported inspect shapes, and live VM/Docker acceptance evidence remain incomplete. |
| Kubernetes port-forward | The app has read-only selected-Pod logs, events, and descriptions; its only forward design is the narrow selected-Pod TCP loopback lease specified in [`k8s.md`](k8s.md#planned-selected-pod-local-port-forward). | Planned only: no port-forward coordinator, bundled `kubectl` provenance, listener, child process, or acceptance result exists. It is not an implementation or release claim. |

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
   offer a specific repair path. **Current implementation:** the explicit
   first-run transaction presents every host-owned change, keeps the background
   service opt-in, starts only Morbstack after explicit confirmation, then
   performs a bounded Docker health verification and exposes a repair action.
   Clean-profile live evidence remains the P0 release gate.
4. **Release evidence, not documentation promises.** Run the
   [clean-profile Docker acceptance matrix](clean-profile-acceptance.md) for
   direct socket discovery, Docker contexts, Buildx, Compose, Testcontainers,
   Dev Containers and core IDE paths.

### P1 — make the daily development loop reliable

1. Complete Docker publication parity beyond the fixed-TCP create/start lease: execute
   the live evidence for Phase 1's explicit-empty TCP allocation transaction and the
   exact-ID post-VM-stop TCP re-reservation path, then add `-P`, ranges, and dynamic
   UDP while preserving loopback-safe defaults. The implementation deliberately does
   not retain a listener while no guest exists; names/prefixes and opaque/unsupported
   start shapes remain event-reconciled rather than claiming synchronous recovery.
   UDP already uses a real framed datagram relay after Docker confirms a concrete
   publication, but deliberately has no invented reservation. The dynamic-port
   boundary and delivery constraints are in [`dynamic-port-allocation.md`](dynamic-port-allocation.md).
2. Turn unshared/misresolved bind sources into clear Docker errors, then ship
   a guest-local synced-share tier or other guest-side observable mechanism.
   A host FSEvents stream alone, including synthetic inotify injection, is not
   a hot-reload claim.
3. Add an end-to-end grow-only disk expansion transaction (the current guest exposes
   an explicit `disk_resize: unavailable` capability and the daemon has a read-only
   stop/preflight diagnostic, but no host image is resized), truthful idle-stop wording
   until genuine suspend/restore is demonstrated, and live acceptance for the existing
   redacted diagnostics bundle across VM/DNS/share/forwarder/Kubernetes failure states.
4. Finish the remaining operational app workflows: exercise the implemented
   local BuildKit workflow against a clean engine; complete stack actions,
   container exec/debug, safe image/volume export and inspection, and
   Kubernetes exec and the planned selected-Pod port-forward with reasons and
   recovery. Container
   logs/stats and selected-pod logs/events already use real read-only APIs.
5. Finish migration beyond the implemented native selected-image and selected-volume
   preparation/review/progress/report workflows: run real source/destination acceptance
   for the local-volume archive path and its final Transfer-click reprepare/review
   boundary, then add bind-mount transfer, resumable cancellation, rollback guidance,
   and explicit credential remediation.

### P2 — exceed the competing native experience

1. `*.morb.local`, automatic local HTTPS with a narrowly scoped CA, direct
   service opening/copying, macOS scoped DNS and VPN correctness. The staged
   resolver/router/CA contract and its inactive claim foundation are in
   [`domains.md`](domains.md); no local-domain route is currently claimed.
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
