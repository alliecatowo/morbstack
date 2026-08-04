# Core Docker usability roadmap

**Status:** planning and evidence reconciliation only — not a feature or
release claim.
**Reviewed:** 2026-08-03.
**Decision:** normal Docker workflows are the product-critical path. Kubernetes
remains opt-in maintenance work until the core sequence below has accepted live
evidence.

This document turns the existing broad product material into a sequenced,
open-source product backlog. It deliberately does not say that a source-level
implementation, a fixture, or a historical run is a released capability. The
authoritative current evidence and acceptance records remain the
[product audit](../product-audit.md), [drop-in delivery plan](../drop-in-delivery-plan.md),
[clean-profile acceptance matrix](../clean-profile-acceptance.md), and
[historical parity record](../parity.md).

## What counts as parity

Morbstack is useful as a Docker Desktop replacement only when ordinary tools
and ordinary projects work without a Morbstack-specific client dialect. The
primary customer workflows are:

1. Start the engine, select a normal Docker context/socket, then run, stop,
   inspect, log, and remove a container.
2. Pull/build an image, publish its ports, mount project data, and use normal
   local networking.
3. Bring a Compose project up and down, follow its services and logs, and
   understand its declared configuration without exposing its secret material.
4. Inspect and safely manage the images, volumes, networks, builders, cache,
   and disk space created by those workflows.
5. Let tools such as Buildx, Compose, Testcontainers, Dev Containers, and
   IDEs find that same engine through their existing discovery rules.

The native app should make these operations easier to see and recover, but it
must not become a second source of truth. Docker Engine and the bundled Docker
CLI/Compose/Buildx tools remain the operation authority; the app reads their
state and reports the exact operation, progress, error, and recovery action.

## External usability bar

The checklist below records documented behavior, not an assertion that a
competitor's implementation is independently verified or that Morbstack will
copy every UI detail.

| Surface | What the primary sources establish | Morbstack product response |
| --- | --- | --- |
| Containers and logs | Docker Desktop documents a real-time, searchable log view across containers and recent builds, while OrbStack documents a native manager for containers and volumes. | A selected container must expose truthful lifecycle state, inspect facts, ports, logs, and resource activity. A global log stream is worthwhile only when it identifies its container/build source and has bounded search/export behavior. |
| Images and image acquisition | Docker Desktop's Images view documents local-image management plus an authenticated Docker Hub repository view. OrbStack documents the normal Docker engine, Compose, and Buildx toolchain. | Keep local image inventory and actions first. Add an explicit `pull` flow for a person-entered image reference before attempting a registry-wide browser. Retain the existing Docker credential helper as the credential owner; do not make a second credential store. |
| Volumes and bind mounts | Docker Desktop documents volume inspection, in-use relationships, create/delete, and data-oriented operations. OrbStack documents persistent volumes and host bind mounts as ordinary Docker behavior. | Present each volume's drivers, mount/use relationships, and destructive consequences. Bind mounts must preserve host-file identity and fail clearly rather than substitute guest data. Export/import/clone are later, explicit transactions — not casual toolbar actions. |
| Networks and published ports | Compose documents its default project network, service-name discovery, custom networks, hostnames, port mappings, and debugging. OrbStack documents port forwards, host networking, IPv6, DNS/VPN behavior, and bind mounts as common Docker behavior. | Complete ordinary `-p` and `-P` behavior, restart recovery, `host.docker.internal`, and transparent network inspection before adding convenience domain features. Any non-loopback/LAN exposure must be an explicit, accurately described policy choice. |
| Compose projects | Compose documents project networking, environment precedence, and service-scoped secret grants. OrbStack documents running `docker compose` normally. | Make Compose CLI compatibility a release gate. The native Stacks experience can group services, lifecycle, logs, build state, and source documents, but must never silently deploy a selected file or infer secrets/values it has not been authorized to read. |
| Builds and builders | Docker documents Buildx as the client for BuildKit, and Docker Desktop documents builder inspection (status, driver, platforms, disk usage, endpoint) and selection. | Show build state from actual Buildx/BuildKit records, not inferred cache mutations. Prioritize reliable local build, logs, cancellation, result/image reference, builder inspection, and cache attribution before elaborate history visualizations. |
| Environment and secrets | Compose defines explicit environment precedence. It separately defines secrets as per-service file mounts and warns against using environment variables for secret material. | Show declarations, origin/provenance, and redacted status by default. Do not add an app-owned secret vault, copy Docker credentials, or expose effective secret values in routine app UI, logs, diagnostics, or screenshots. |
| Normal tool discovery | OrbStack documents a standard Docker context/socket and ordinary Compose/Buildx compatibility; Docker's tools use the Docker endpoint and selected context. | Prove clean-profile Docker context/socket discovery before branding anything a drop-in replacement. The test matrix must cover Compose, Buildx, Testcontainers, Dev Containers, and representative IDE paths with no Morbstack-specific environment variable. |

## Product sequence

Each work item exits only with a focused source-level check **and** the stated
live acceptance evidence. A UI-only proof cannot accept an engine contract;
an engine-only proof cannot accept a user-facing app action. New work is added
to the integration plan only after its owner names the operation authority,
failure/cancellation behavior, destructive boundary, and live test case.

### Core 0 — engine and client contract (release-blocking)

1. **Install, service, context, and socket.** A clean user profile can install
   Morbstack's owned artifacts, intentionally start it, select a `morbstack`
   context, reach `/_ping`, restart it, and remove only Morbstack-owned
   integrations. Existing contexts, credentials, shell configuration, and
   other runtimes remain untouched.
2. **Everyday container contract.** Accept real CLI cases for create/run/stop/
   start/restart/remove, logs, exec, inspect, copy, stats, exit status, image
   pull/build, and cleanup. Confirm state after reconnect and VM restart rather
   than trusting a UI cache.
3. **Ports, files, and local networking.** Accept `-p` fixed, dynamic, ranges,
   TCP, UDP, and `-P` where Docker advertises the corresponding mapping;
   restart/recovery must preserve or truthfully reject a requested publication.
   Accept host bind mounts for representative file, directory, `/tmp`, and
   configuration paths; validate named volumes, DNS, Compose service discovery,
   `host.docker.internal`, and the documented host-networking policy.
4. **Ecosystem discovery.** Run the existing clean-profile matrix with pinned
   public fixtures for Docker CLI, Compose, Buildx, Testcontainers, Dev
   Containers, and representative IDE integrations. The phrase *drop-in
   replacement* remains unavailable until this matrix is current and passing.

The published source audit already identifies port recovery, `-P`, bind-mount
truthfulness, host resolution, disk growth, and clean-profile tool discovery as
areas requiring live proof. Those are Core 0 work, not optional polish.

### Core 1 — daily container, image, volume, and network operations

This is the first app-facing delivery tranche after Core 0 contracts are
working. It should favor the correct native container for each task: a resource
inventory for scanning, a selected-record inspector for facts and actions, a
log reader for a streaming transcript, and a dedicated form/sheet for an
operation that creates or destroys state. It should not flatten the entire
product into one generic dashboard/table.

| Work item | Required behavior | Exit evidence |
| --- | --- | --- |
| **C1 Containers** | List/filter/sort real containers; selected details show status, image, command, ports, mounts, network addresses, health, and lifecycle history where supplied by the daemon. Start/stop/restart/remove/rename/exec/log actions have live progress, failures, and confirmation for destructive actions. | A live container lifecycle matrix plus real-window exercise of empty, loading, failure, and selected-record states. |
| **C2 Images** | Local inventory/inspect/tag/remove/prune distinguish image references from IDs and show running/stopped dependent containers before deletion. A deliberate public search and person-entered pull may exist, but pulling must show transfer/result/failure and must reuse the installed Docker credential mechanism. | Live pull/build/tag/remove/prune cases, including a failed pull and an image protected by a container. |
| **C3 Volumes and mounts** | Inspect driver, labels, mountpoints/use relationships, disk facts if available, and dependency warnings. Create/delete/prune only through reviewed confirmation. Surface mount failures as engine errors; never replace host content with plausible guest content. | Live named-volume and bind-mount matrix, including a protected destructive refusal and a host-file identity assertion. |
| **C4 Networks and ports** | Inspect networks, members, aliases, published mappings, and actual reachability. Create/remove/connect/disconnect must preserve Docker errors and explain why an action is unavailable. | Live bridge/custom/Compose-network cases and a port reachability/restart matrix. |
| **C5 Logs and diagnostics** | Provide per-container streaming logs first; add an environment-wide stream only after it can label source, bound memory/search, and export exactly what it claims. Link engine failures to a bounded, redacted diagnostic/recovery route. | Live log rollover/disconnect/reattach, error, filtering, and export evidence; diagnostic evidence never includes secrets. |

### Core 2 — Compose as the project workflow

Compose is more valuable than a generic YAML editor. It earns first-class app
space when it stays aligned with the bundled Compose CLI and exposes the
project a developer is actually running.

1. **Project identity and lifecycle.** Discover/select projects from real
   Docker/Compose labels, group services and dependent resources, and invoke
   bounded `up`, `down`, `start`, `stop`, `restart`, `build`, and log actions
   through the bundled tools. A proposed action must show its project/file
   authority, current state, result, and failure output.
2. **Source documents by explicit consent.** Keep file open/save separate from
   daemon discovery. A project label does not grant source-tree access. The
   person explicitly chooses a Compose or `.env` document; external-change,
   dirty/discard, symlink, encoding, and cancellation cases remain part of the
   feature's acceptance matrix.
3. **Configuration explanation, not secret extraction.** Start with a
   read-only declaration view: services, `environment`, `env_file`, top-level
   secrets, service grants, networks, volumes, and build declarations. Explain
   documented precedence and source provenance without resolving hidden host
   values or reading a secret file. Any later reveal action requires an
   explicit, narrow consent design.
4. **Compose reliability fixtures.** Test multi-service health dependencies,
   rebuilds, logs, named volumes, default/custom/external networks, ports,
   `.env`/`--env-file` precedence, secret grants, and teardown. A normal
   Compose project must work from the terminal whether or not its source file
   is open in the app.

### Core 3 — build and storage operations

1. **Local build execution.** A user-selected build invocation has exact
   context/Dockerfile/platform/tag/build-argument disclosure, live BuildKit
   progress, cancel/error/result handling, and a link to the resulting image
   when one is reported. No UI should manufacture a durable build record from
   cache state.
2. **Builder and history inspection.** Read actual Buildx builder facts and
   records: selected builder, driver, status, platforms, disk use, record
   details, and logs. Management operations remain CLI-backed until their
   implications and cleanup boundaries are equally well defined.
3. **Disk and cache honesty.** Show Docker-attributed storage separately from
   host-image capacity and shared attribution. Destructive cache/image/volume
   cleanup tells the user what will be removed and what cannot be reclaimed;
   grow-only disk work needs a stopped-VM, journaled, verified transaction.

### Core 4 — configuration safety and operational quality of life

This tranche adds speed without inventing a competing configuration system:

- Read Docker daemon settings through an explicit, validated document flow;
  apply only a reviewed, restart-aware operation and retain a clear recovery
  path.
- Provide an Environment & Secrets declaration/provenance view that remains
  redacted by default. Docker credential helpers, Keychain items, secret files,
  process environments, app logs, and support bundles are separate authority
  domains.
- Improve discoverability with command/menu actions for current selection,
  safe copy/open/reveal actions, empty-state next steps, and unambiguous
  destructive confirmations. Every app action must map to a real operation,
  not a fabricated completed state.
- Continue migration/debug/file-access/domain ideas only as separately designed
  capabilities with their own security and recovery evidence. They are
  differentiators, not substitutes for Core 0–3 compatibility.

## Kubernetes is deliberately demoted

Kubernetes is not removed, but it is no longer a competing top-level delivery
track. The rule is:

> No new Kubernetes feature work, UI expansion, port-forward refinement, or
> convenience work starts until Core 0 through Core 3 have current live
> acceptance evidence. Existing Kubernetes behavior receives only correctness,
> safety, and regression maintenance while that work proceeds.

When the core Docker path is accepted, Kubernetes resumes as a separate,
opt-in product with its own enable/disable/recovery, workload, logs/events,
and port-forward acceptance plan. It cannot borrow "Docker replacement"
evidence from the normal Docker matrix, and normal Docker cannot be held
hostage by a cluster feature.

## Delivery controls

- **Truthful state:** real daemon/Compose/Buildx data is visually distinct from
  deterministic fixture data; the app never reports a running engine it has
  not contacted.
- **One source of authority:** use Docker's APIs and bundled CLI tools, not
  app-maintained parallel models, to decide lifecycle, ports, project state,
  image identity, and build history.
- **No secret leakage:** do not retrieve or persist registry credentials,
  secret contents, or resolved environment values as a routine consequence of
  browsing an app screen. Redaction applies to UI, copied text, logs,
  diagnostics, tests, and screenshots.
- **Safety at mutation boundaries:** show target, dependencies, data-loss or
  network-exposure consequence, progress, cancellation scope, completion, and
  recovery. Disable rather than pretending an operation succeeded.
- **Evidence before promotion:** source/unit tests are necessary but are not
  compatibility proof. Each Core item needs a current live engine check;
  app-facing work additionally needs real-window/XCUITest accessibility and
  visual evidence under the project's native macOS acceptance process.
- **No competitor feature-count race:** automatic domains/HTTPS, native file
  browsing, debug shells, machines, cloud integrations, AI, and an extension
  marketplace are explicitly after the reliable normal-Docker loop.

## Primary sources consulted

- Docker: [Images view](https://docs.docker.com/desktop/use-desktop/images/),
  [Volumes view](https://docs.docker.com/desktop/use-desktop/volumes/),
  [Logs view](https://docs.docker.com/desktop/use-desktop/logs/),
  [Build overview](https://docs.docker.com/build/concepts/overview/), and
  [Desktop builders](https://docs.docker.com/desktop/settings-and-maintenance/settings/).
- Docker Compose: [environment precedence](https://docs.docker.com/compose/how-tos/environment-variables/envvars-precedence/),
  [secrets](https://docs.docker.com/compose/how-tos/use-secrets/), and
  [networking](https://docs.docker.com/compose/how-tos/networking/).
- OrbStack: [Docker containers, Compose, ports, mounts, volumes, networking,
  toolchain, manager, context, and socket](https://docs.orbstack.dev/docker).

These links are the external experience bar. The local documents linked at the
top remain the source of truth for what Morbstack has actually implemented and
verified.
