# Competitive capability roadmap

**Status:** active implementation guide. Researched 2026-08-03. This narrows
[`product-audit.md`](product-audit.md) into capability slices that make
Morbstack a free, open, genuinely drop-in macOS Docker Desktop replacement
rather than merely a Docker client with a VM.

## How to read this document

- **Repository evidence** names code or a dated, local live-parity result. It
  means the capability exists in this checkout; it is *not* a release claim
  until the clean-profile acceptance check has passed.
- **Competitor evidence** is a primary vendor or project source, checked on
  2026-08-03. It records the experience bar, not independent performance or
  security verification of a competitor's claim.
- **Inference** is an explicit product-priority judgement based on that
  evidence. It is deliberately labelled so it cannot turn into marketing by
  accident.

The product promise is uncompromising: Apache-2.0, commercial use included,
no account, no telemetry, unmodified upstream Docker Engine, and a native
macOS app. "Better" means a first-day developer can use the Docker ecosystem
without Docker Desktop installed or an environment-variable ritual—not a
larger feature checklist.

## The external bar, grounded in primary sources

| Experience bar | Competitor evidence | Consequence for Morbstack |
| --- | --- | --- |
| A Docker runtime should become usable with ordinary `docker` tooling, ports, mounts, and Kubernetes—not a new CLI dialect. | [Colima's README](https://github.com/abiosoft/colima#features) documents automatic port forwarding, Docker runtime, volume mounts, and optional Kubernetes; [Rancher Desktop](https://docs.rancherdesktop.io/) documents selectable Moby/containerd and built-in k3s. | Compatibility and installation are release gates; a beautiful app cannot compensate for an IDE or Testcontainers failing to find Docker. |
| Docker Desktop makes published ports a host networking feature, and operates Kubernetes as a real product surface. | Docker's [networking](https://docs.docker.com/desktop/features/networking/) documentation describes the backend owning the host listener and forwarding to the VM. Its [Kubernetes documentation](https://docs.docker.com/desktop/use-desktop/kubernetes/) describes live resource views, configuration, stop/reset, and recovery. | A port shown as published must be reachable or the Docker operation must fail. Kubernetes needs actionable state and recovery before more cosmetic controls. |
| OrbStack turns local services into an ambient Mac experience. | OrbStack documents per-container and Compose [domains](https://docs.orbstack.dev/docker/domains), automatic local [HTTPS](https://docs.orbstack.dev/features/https), and direct Finder/app access to [container, image, and volume files](https://docs.orbstack.dev/features/native-files). | `*.morb.local` plus HTTPS and native file access are the highest-value differentiators *after* Docker compatibility is dependable. They cannot be faked by merely showing an “Open” button. |
| Fast recovery matters when an image has no shell or data must move off another runtime. | OrbStack documents a [Debug Shell](https://docs.orbstack.dev/features/debug) and Linux [machines](https://docs.orbstack.dev/machines/). Docker Desktop's [Extensions page](https://docs.docker.com/extensions/) also warns that extensions gain elevated host and Docker access. | Ship a narrowly scoped, audited debug toolbox and migration workflow before a general extension marketplace. Do not copy Docker Desktop's web-extension privilege model. |

## Repository capability audit

| Capability | Repository evidence | Honest status and gap |
| --- | --- | --- |
| Upstream Docker runtime | `RuntimeArtifacts.swift`, `VMManager.swift`, `guest/morbinit`, and the dated checks in [`parity.md`](parity.md). | Implemented foundation. The historical live matrix is useful evidence, but must be rerun on a clean profile before release claims. |
| Native operations app | `MorbstackAppCore` has real containers, stacks, images, volumes, networks, builds, Kubernetes, disk, and migration routes; `DockerClient.swift` performs real lifecycle, log, stats, inspection, and prune API calls. | Implemented surface. It is not a reason to defer behavioral gaps below. |
| Self-contained CLI, standard plugins, context, direct discovery, and opt-in service | `CliPlugins.swift`, `MorbCliInstallation.swift`, `MorbDockerContext.swift`, `BackgroundService.swift`, and `MorbSetupVerification.swift`. The service is a signed per-user `SMAppService` LaunchAgent, not a root daemon. | Implemented pending one complete, fresh-user proof: install → selected integrations → service → engine start → Docker `/_ping` → Compose/buildx/Testcontainers/IDE discovery. |
| Kubernetes and recovery | `guest/morbinit/src/k8s.rs`, `K8sRuntime.swift`, the Kubernetes route, and `k8s-diagnose`. | Opt-in cluster and diagnosis exist. Missing are safe workload-level logs, events, exec, and port-forward operations with clear cancellation/recovery. |
| Migration | `MigrationReadOnlyPlanner` derives a read-only image comparison and conservative named-volume eligibility from the two Engine inventories. `ImageMigrationTransaction` and `morb migrate run` execute an explicitly selected images-only transfer with one confirmation, typed progress, post-load image-ID verification, and a durable report. `morb migrate volumes` remains a separately confirmed helper-container CLI path; the native app route currently exposes images only. | Images-only transaction implemented pending real-engine acceptance. The volume eligibility plan is read-only: only missing `local` volumes are eligible, and existing destination contents are not inspected. A reusable volume transaction, native workflow, bind mounts, containers, CLI configuration, credentials, registry/provenance policy, resumable cancellation, and automatic rollback remain deliberately out of scope. |
| Filesystem sharing | VirtioFS same-path sharing and share inspection are implemented; [`sharing.md`](sharing.md) records that host edits do not emit guest inotify events. | Day-to-day hot reload remains broken. Silent unshared/misresolved source behavior is still too dangerous. |
| Published ports | `PortForwarder.swift` forwards TCP loopback. For a normally encoded fixed supported TCP `docker run -p <port>:...`, `DockerProxy` binds and retains the listener before create, associates it from a bounded standard create response, and hands it off before an exact start `204` reaches the client. Explicit UDP and unsupported host-address publishes reject instead of pretending to publish. | Dynamic/ranged allocation, UDP, opaque/chunked create responses, start by name/nonstandard framing (eventual event-based promotion only), and survival through VM/daemon shutdown remain absent. |
| Disk management | `DiskCapacity.swift` supplies the RAW-image facts. `MorbDiskResize` combines those facts with VM state and the guest's explicit `disk_resize` capability; the current guest reports `unavailable`. | No host image mutation occurs. A grow transaction still needs an explicit target, stopped-VM ownership, retained prior-capacity journal, guest filesystem identity/resize, and post-resize proof. Shrinking remains unsupported. |
| Debug toolbox | `MorbScan/DebugToolboxPlan.swift` and `morb debug check` expose static readiness; `morb debug [plan] <container>` makes only `GET /containers/{id}/json` and reports its non-actions. | Read-only foundation. A verified pinned asset, consented acquisition/update policy, isolated namespace/cleanup policy, and interactive PTY bridge are still required before an executor or app action exists. |
| Local domains, HTTPS, Finder-native files, Linux machines | Explicitly absent from current runtime/app implementation; see [`product-audit.md`](product-audit.md). | Differentiators, not P0 compatibility gates. They need a security and macOS-capability design before UI work. |

### Documentation reconciliation is a release prerequisite

**Repository evidence:** the current `README.md` still says there is no durable
background service, while `BackgroundService.swift` implements the consented
per-user service; older comparison text also describes an app state that has
since changed. **Inference:** after every capability below passes live
acceptance, reconcile README, comparison, compatibility, roadmap, and
release notes in the same change. A replacement cannot ask users to guess
which of its own documents is current.

## Priority order: implementation slices, not a feature wish list

### R0 — prove the first ten minutes on a clean Mac profile

**Why now (inference):** every competing option in the sources above makes
ordinary Docker workflow available immediately. This is the binary release
gate and the highest-value free/open differentiator.

**Slice:** make first-run one resumable, explicit transaction with a durable
result record: install only approved user-owned links/plugins/context/direct
socket; optionally register the per-user service; start the engine only after
confirmation; then verify `/_ping`, `docker version`, Compose, buildx, direct
socket discovery, Testcontainers, Dev Containers, and one IDE integration.
Show the exact item that failed and a repair action; never replace another
runtime's socket, context, PATH entry, or credentials.

**Acceptance:** a new macOS user with Docker Desktop/Homebrew Docker absent can
install Morbstack, close its window, open a new shell/IDE, run a Compose build,
and have Docker auto-discovered. Re-run must be idempotent and uninstall must
remove only Morbstack-owned state.

**Authority:** **no elevated privilege.** Home-directory links, a per-user
`SMAppService` agent, and loopback sockets are sufficient. Keep it that way.

### R1 — make Docker-visible failures truthful

**Why now (repository evidence):** port publication and bind mounts are the
two places where a successful Docker command can currently describe a state
that is not actually usable.

**Slice A — publication contract:** reserve fixed TCP host endpoints
transactionally against Docker create/start, retain the listener/lease until
container removal or failed start, and relay UDP as bounded event-confirmed
datagram flows. Return a Docker-compatible conflict before the TCP container is
reported running; retain a readable diagnostic for the app and `morb status`.

**Slice B — share contract:** canonicalize macOS source paths before guest
mapping, validate them against the configured share set, and reject a missing
or unshared bind source through the Engine-facing path. The result must be a
clear error, never an empty guest directory.

**Acceptance:** race a bound TCP and UDP loopback port against a container
start; both must either forward or fail synchronously. Exercise a file bind
under `/tmp`, `/private/tmp`, a symlinked source, and an unshared source; each
must bind the intended file or fail plainly.

**Authority:** **no elevated privilege.** This is daemon/relay protocol work
on Morbstack-owned loopback listeners and user-selected paths.

### R2 — restore the Mac edit → container watch loop

**Why now:** Docker Desktop's synchronized-file-sharing feature and
OrbStack's documented two-way sharing make hot reload table stakes; polling
is a mitigation, not parity.

**Slice:** add an FSEvents watcher only for explicitly shared roots, coalesce
and canonicalize events, send a bounded ordered event protocol to the guest,
and inject the corresponding Linux inotify events. Preserve move/rename and
overflow semantics; when an event cannot be represented, surface a rescan
condition rather than silently losing it. Make the status visible in Sharing
settings and diagnostics.

**Acceptance:** Node/Vite, Python, Go, and a rename-heavy watcher test observe
host edits through a bind mount; reconnect, overflow, stop/start, and a
non-shared path have deterministic outcomes. Benchmark against a native Linux
tree and publish the result instead of borrowing competitor performance claims.

**Authority:** **no elevated privilege.** FSEvents observes directories the
user selected/shared; it must not watch the whole disk or install a helper.

### R3 — complete the operations people use to escape Docker Desktop

**Why now (repository evidence):** the native app already has authentic
lists, inspection, logs, stats, lifecycle, and destructive confirmations.
Finish workflows rather than adding dashboard panels.

1. **Migration transaction:** selected local-image planning, confirmation,
   typed progress, report, and image-ID verification exist in `MorbMigrate`.
   Complete separately proven volume/bind-mount transfer, resumable cancellation,
   credential/provenance remediation, and rollback *guidance* that never destroys
   the source runtime. Keep the app read-only until each shared primitive exists.
2. **Debug toolbox:** the read-only readiness and target-plan boundary exists;
   ship its executor only with a pinned, signed toolbox image, provenance,
   expiry/update policy, namespace/cleanup rules, and a real interactive PTY
   bridge. Keep `morb debug` unavailable whenever any safety primitive is missing.
3. **Kubernetes operations:** add selected-resource events/logs/describe,
   cancellable port forward, and guarded exec; retain `k8s-diagnose` as the
   first recovery action. Do not create/delete workloads behind a decorative
   control.
4. **Capacity recovery:** replace the current negative guest capability with a
   stop-only grow-only disk expansion transaction: explicit target, retained
   prior-capacity journal, in-guest filesystem resize, post-resize verification, and
   a hard no-shrink invariant.

**Acceptance:** each action has live progress, cancellation/failure state,
exact effects, and a test against a real engine/cluster. No one-click action
may alter the source runtime, active containers, or user data unexpectedly.

**Authority:** **no elevated privilege.** These operate through Docker/Kubernetes
APIs and Morbstack-owned VM storage. Registry access and a toolbox image pull
need user-visible network/provenance policy, not administrator rights.

### R4 — earn the OrbStack-style local-service advantage

**Why next (competitor evidence):** readable service domains, zero-setup
HTTPS, and native file access remove daily friction once compatibility is
solid. They are more compelling than imitating a Docker Desktop extension
marketplace.

1. **Domains and HTTPS:** implement `service.project.morb.local`, collision
   handling, listener/HTTP detection, a local reverse proxy, and an opt-in
   narrowly scoped CA. Do not auto-trust a broad CA or silently claim every
   domain. Support explicit labels for ambiguous ports and explain VPN/DNS
   state in diagnostics.
2. **Native file access:** start with explicit read-only image inspection and
   controlled volume/container export/import. Only add Finder mounts once
   their read/write, lifecycle, locking, and failure semantics are proven.
3. **Linux machines:** build a separate machine abstraction—image provenance,
   cloud-init, SSH/editor integration, deletion/export—rather than turning the
   shared Docker VM into a mutable general-purpose machine.

**Acceptance:** domains resolve only while their service is valid, HTTPS trust
has explicit revocation/removal, and file operations cannot corrupt Docker
storage. A machine can be created, stopped, reached over SSH, exported, and
deleted without changing the container engine's state.

### Current OrbStack capability map — what to copy, what to avoid

This map is a design input, not a claim of feature parity. It was refreshed
against OrbStack's own documentation on 2026-08-03. Its purpose is to keep
Morbstack's feature work anchored in concrete developer workflows while
preserving the project's open, least-privilege contract.

| Workflow OrbStack documents | Morbstack delivery response | Priority and boundary |
| --- | --- | --- |
| Container and Compose service domains, detected HTTP routing, explicit port labels, and a local service index ([domains](https://docs.orbstack.dev/docker/domains)) | `service.project.morb.local` should be driven only by observed running containers, Compose labels, and an explicit user opt-in. A first version must have exact collision, stop, DNS/VPN, and port-selection semantics; it must not scrape the host network or silently route arbitrary names. | Highest differentiator after R0/R1. |
| HTTPS backed by a local CA, Keychain-protected keys, explicit first-use trust, and name-constrained certificates ([HTTPS](https://docs.orbstack.dev/features/https)) | Keep the CA, trust request, names, revocation, and proxy lifecycle separate from ordinary Docker setup. A self-contained status/repair surface comes before a toggle. No broad CA, global resolver file, or undocumented certificate injection. | Build only with a macOS security design and explicit consent. |
| Debugging an image with no shell without modifying the target container ([Debug Shell](https://docs.orbstack.dev/features/debug)) | The pinned-asset/provenance/compatibility contract precedes any executor. A future toolbox must have an isolated namespace, exact target/permission disclosure, cleanup receipt, live cancellation, and a proper PTY bridge. | R3; no placeholder shell. |
| Finder/editor access to container, image, and volume files ([native files](https://docs.orbstack.dev/features/native-files)) | Start with an explicit read-only image inspection/export path, then a separately proven volume export/import transaction. A Finder filesystem mount is later because locking, consistency, durability, and lifecycle errors must be truthful before writable access exists. | R4; preserve Docker-storage integrity over convenience. |
| Separate Linux machines, isolated sandboxes, cloud-init, and SSH ([machines](https://docs.orbstack.dev/machines/), [isolated machines](https://docs.orbstack.dev/machines/isolated), [cloud-init](https://docs.orbstack.dev/machines/cloud-init), [SSH](https://docs.orbstack.dev/machines/ssh)) | A machine is a separate product abstraction and persistent disk, never an escape hatch that mutates the Docker VM. Image provenance, SSH key ownership, cloud-init retention, export/delete, and isolation must be designed together. | R4, after Docker compatibility and local-service fundamentals. |
| Host networking, direct container access, USB passthrough, sound, and a menu-bar workflow ([network](https://docs.orbstack.dev/docker/network), [host networking](https://docs.orbstack.dev/docker/host-networking), [USB](https://docs.orbstack.dev/features/usb), [menu bar](https://docs.orbstack.dev/menu-bar)) | Keep the existing native menu bar as the operational entry point. Treat direct networking, USB, and sound as separate entitlement/threat-model projects: each needs an opt-in capability, narrow discovery surface, clean detach/recovery, and no privileged helper shortcut. | Do not block the replacement on these; never imply parity before the security model is proven. |

The ordering is intentional: first make a normal Docker project boringly
compatible; then remove daily friction with domains, HTTPS, debug, and safe
file work; only then widen the trusted hardware/network surface or add Linux
machines. That produces a stronger free replacement than copying a closed
product's broad permissions or web-extension model.

## Authority and security boundary

| Category | Work | Policy |
| --- | --- | --- |
| **No elevated privilege** | R0–R3, FSEvents bridge, Docker/Kubernetes actions, direct Docker discovery, per-user service, loopback TCP/UDP relay, user-selected shares. | This is the default. All normal Docker replacement work should remain here. |
| **User approval / Apple capability feasibility spike** | Local CA trust, system-visible DNS via a Network Extension, and Finder integration such as FSKit. | These are not root-helper work by default, but may require explicit keychain consent, signed entitlements, user approval, or Apple distribution approval. Prove the exact macOS deployment path before promising the feature. Relevant platform references: [NetworkExtension](https://developer.apple.com/documentation/networkextension) and [FSKit](https://developer.apple.com/documentation/fskit). |
| **Privileged or system-wide mutation — avoid for 1.0** | Writing `/etc/resolver`, installing global routes or packet-filter rules, a privileged LaunchDaemon/helper, broad certificate trust, unrestricted filesystem access, USB/GPU forwarding. | Do not use these as a shortcut. They need a separate threat model, least-privilege command allowlist, install/uninstall story, and explicit user authorization. No current R0–R4 acceptance depends on them. |

Docker Desktop's own Extensions documentation is an important negative lesson:
it says extensions receive elevated host, Docker Engine, filesystem, and native
binary access. Morbstack should offer narrow native integrations and a
permissioned future plugin SDK, not inherit that attack surface for parity's
sake.

## Deferred on purpose

- Docker Desktop Extensions compatibility: a web-view marketplace conflicts
  with the native-app and least-privilege product direction.
- GPUs, USB, host/LAN-routable container addresses, and broad hardware
  forwarding: valuable only after the core compatibility contract and security
  boundary are demonstrably reliable.
- General Linux machines: an R4 differentiator, never an excuse to delay R0–R2.

## Source register

All external links below were checked 2026-08-03. Competitor statements are
their publishers' statements; no performance, privacy, or security claim here
is inferred solely from a feature page.

- OrbStack: [Docker Desktop comparison](https://docs.orbstack.dev/compare/docker-desktop), [domains](https://docs.orbstack.dev/docker/domains), [HTTPS](https://docs.orbstack.dev/features/https), [native files](https://docs.orbstack.dev/features/native-files), [Debug Shell](https://docs.orbstack.dev/features/debug), [Linux machines](https://docs.orbstack.dev/machines/).
- Docker: [Desktop networking](https://docs.docker.com/desktop/features/networking/), [Desktop Kubernetes](https://docs.docker.com/desktop/use-desktop/kubernetes/), [Extensions and security boundary](https://docs.docker.com/extensions/).
- Open-source alternatives: [Colima README](https://github.com/abiosoft/colima#features), [Rancher Desktop introduction](https://docs.rancherdesktop.io/).
- Apple platform feasibility references: [NetworkExtension](https://developer.apple.com/documentation/networkextension), [FSKit](https://developer.apple.com/documentation/fskit).
