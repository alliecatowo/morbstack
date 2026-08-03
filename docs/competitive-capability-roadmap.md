# Competitive capability roadmap

**Status:** active experience-bar and source audit, reconciled 2026-08-03.
The executable sequence, owners, authority boundaries, and live gates live in
the canonical [`drop-in delivery plan`](drop-in-delivery-plan.md). This document
keeps that work anchored to the experience Morbstack must exceed, rather than
turning an implementation detail into a marketing claim.

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
| Self-contained CLI, standard plugins, context, direct discovery, and opt-in service | `CliPlugins.swift`, `MorbCliInstallation.swift`, `MorbDockerContext.swift`, `BackgroundService.swift`, and `MorbSetupVerification.swift`. The service is a signed per-user `SMAppService` LaunchAgent, not a root daemon; a current `morbstack` context must also name this runtime's socket. | Implemented pending one complete, fresh-user proof: install → selected integrations → service → engine start → Docker `/_ping` → Compose/buildx/Testcontainers/IDE discovery. No pinned Testcontainers or Dev Containers fixture/lockfile is currently tracked, so those must be added before the clean-profile matrix can be run. |
| Kubernetes and recovery | `guest/morbinit/src/k8s.rs`, `K8sRuntime.swift`, the Kubernetes route, and `k8s-diagnose`. | Opt-in cluster and diagnosis exist. Missing are safe workload-level logs, events, exec, and port-forward operations with clear cancellation/recovery. |
| Diagnostics-bundle recovery | `MorbDiagnostics` and `morb diagnose` collect a bounded, redacted local bundle. `DiagnosticsBundleWorkflow` makes the same collector a native engine-error recovery action: a person picks the parent folder, collection does not start or contact Docker/the daemon, and success points them to the reviewable bundle in Finder. | Implemented mechanics and local smoke evidence exist; full real-VM recovery and real-window acceptance remain pending. The app does not upload, share, or claim an in-flight cancel contract. |
| Migration | `MigrationReadOnlyPlanner` derives independent read-only image and named-volume comparisons. The native Migration inspector shows eligible, existing-destination, and unsupported-driver volume results without a helper container. `ImageMigrationTransaction` backs the reviewed native selected-image flow and `morb migrate run`; `VolumeMigrationTransaction` backs separately confirmed CLI and native selected-volume flows. | Implemented pending clean source/destination-engine acceptance. Volume execution is limited to selected missing `local` volumes: it re-prepares selected names before review, performs one final Transfer-click reprepare, returns any changed source/destination/item/helper/safety fact to review, and rechecks before each creation. It never reads/merges/replaces/deletes an existing destination, needs separate consent before a missing helper image is pulled, and writes a durable report. Bind mounts, containers, credentials/provenance policy, resumable cancellation, and automatic rollback remain out of scope. |
| Filesystem sharing | VirtioFS same-path sharing and share inspection are implemented; [`sharing.md`](sharing.md) records that host edits do not emit guest inotify events. The guest retains the version-1 share-event record schema while explicitly reporting the bridge unavailable. | Day-to-day hot reload remains broken. A schema version reserves neither a host watcher nor a guest receiver, and silent unshared/misresolved source behavior is still too dangerous. |
| Published ports | `PortForwarder.swift` forwards TCP loopback and event-confirmed UDP. For a normally encoded fixed supported TCP `docker run -p <port>:...`, including the Docker CLI's normalized equal-length fixed ranges, `DockerProxy` binds and retains every listener before create, associates it from a bounded standard create response, and hands it off before an exact start `204` reaches the client. A narrow, bounded dynamic TCP `HostPort` create transaction admits only an omitted `HostPort`, exact `HostPort: ""`, or exact `HostPort: "0"`; it allocates a real loopback listener, rewrites that exact create body with its concrete port, and retains the same lease. A VM/daemon stop deliberately releases listeners while no guest service exists; after recovery, a bodyless start by the canonical full container ID can inspect the same stopped container's fixed loopback TCP `HostConfig.PortBindings` and atomically rebuild/associate its lease before the unchanged start reaches dockerd. Reconciliation withholds any TCP or UDP endpoint that Docker reports with competing targets rather than choosing one by list order. | The narrow dynamic path excludes `-P`, raw dynamic host-port ranges, all dynamic spellings other than omitted, exact-empty, or exact-literal-zero `HostPort`, malformed/opaque dynamic bindings, mixed non-TCP documents, non-loopback addresses, and opaque/chunked framing. UDP has no synchronous held dynamic lease. Starts by name/ID prefix, unsupported inspect documents, and live VM/Docker acceptance evidence remain incomplete. |
| Disk management | `DiskCapacity.swift` supplies the RAW-image facts. `MorbDiskResize` combines those facts with VM state and the guest's explicit `disk_resize` capability; the current guest reports `unavailable`. | No host image mutation occurs. A grow transaction still needs an explicit target, stopped-VM ownership, retained prior-capacity journal, guest filesystem identity/resize, and post-resize proof. Shrinking remains unsupported. |
| Debug toolbox | `MorbScan/DebugToolboxPlan.swift`, `DebugToolboxAcquisitionPlan.swift`, and `morb debug check` expose static readiness plus a non-executing, machine-readable acquisition/activation/rollback contract; `morb debug [plan] <container>` makes only `GET /containers/{id}/json` and reports its non-actions. | Read-only foundation. The new contract does not fetch, import, inspect, verify, activate, or remove an asset. A verified pinned asset, consented acquisition controller, isolated namespace/cleanup policy, and interactive PTY bridge are still required before an executor or app action exists. |
| Local domains, HTTPS, Finder-native files, Linux machines | `MorbLocalDomain` and `LocalDomainClaimReconciler` provide a pure, inactive, fail-closed exact-claim boundary tied to a running-container list and atomic `PortForwarder` snapshot. They do not bind, resolve, route, issue a certificate, watch Docker, or present a URL. Native files and machines have no shipped service surface. | Prospective local-domain claims are implementation groundwork, not a user-visible domain capability. DNS/router/HTTPS and native files/machines remain differentiators that need a security and macOS-capability design before UI work. |

### Documentation reconciliation is a release prerequisite

The initial source audit once incorrectly said `README.md` denied a background
service and that local-domain groundwork was absent. Neither statement is true:
the README describes the consented Login Item, and the current source has an
inactive domain-claim boundary. After every accepted slice, reconcile README,
comparison, compatibility, the delivery plan, and release notes in the same
change. All public statuses must remain *planned*, *implemented pending live
verification*, or *released*; the clean-profile matrix has not run.

## Execution order

The delivery plan’s S0–S6 order is intentional: first make normal Docker
projects boringly compatible; then repair the edit/watch loop and operational
escape hatches; then add local-service and native-file/machine advantages. That
sequence gives a better free replacement than copying a closed product’s broad
permissions or web-extension marketplace.

### Current OrbStack capability map — what to copy, what to avoid

This map is a design input, not a claim of feature parity. It was refreshed
against OrbStack's own documentation on 2026-08-03. Its purpose is to keep
Morbstack's feature work anchored in concrete developer workflows while
preserving the project's open, least-privilege contract.

| Workflow OrbStack documents | Morbstack delivery response | Priority and boundary |
| --- | --- | --- |
| Container and Compose service domains, detected HTTP routing, explicit port labels, and a local service index ([domains](https://docs.orbstack.dev/docker/domains)) | `service.project.morb.local` should be driven only by observed running containers, Compose labels, and an explicit user opt-in. A first version must have exact collision, stop, DNS/VPN, and port-selection semantics; it must not scrape the host network or silently route arbitrary names. | S5, after S0–S4. |
| HTTPS backed by a local CA, Keychain-protected keys, explicit first-use trust, and name-constrained certificates ([HTTPS](https://docs.orbstack.dev/features/https)) | Keep the CA, trust request, names, revocation, and proxy lifecycle separate from ordinary Docker setup. A self-contained status/repair surface comes before a toggle. No broad CA, global resolver file, or undocumented certificate injection. | Build only with a macOS security design and explicit consent. |
| Debugging an image with no shell without modifying the target container ([Debug Shell](https://docs.orbstack.dev/features/debug)) | The pinned-asset/provenance/compatibility contract precedes any executor. A future toolbox must have an isolated namespace, exact target/permission disclosure, cleanup receipt, live cancellation, and a proper PTY bridge. | S4; no placeholder shell. |
| Finder/editor access to container, image, and volume files ([native files](https://docs.orbstack.dev/features/native-files)) | Start with an explicit read-only image inspection/export path, then a separately proven volume export/import transaction. A Finder filesystem mount is later because locking, consistency, durability, and lifecycle errors must be truthful before writable access exists. | S6; preserve Docker-storage integrity over convenience. |
| Separate Linux machines, isolated sandboxes, cloud-init, and SSH ([machines](https://docs.orbstack.dev/machines/), [isolated machines](https://docs.orbstack.dev/machines/isolated), [cloud-init](https://docs.orbstack.dev/machines/cloud-init), [SSH](https://docs.orbstack.dev/machines/ssh)) | A machine is a separate product abstraction and persistent disk, never an escape hatch that mutates the Docker VM. Image provenance, SSH key ownership, cloud-init retention, export/delete, and isolation must be designed together. | S6, after Docker compatibility and local-service fundamentals. |
| Host networking, direct container access, USB passthrough, sound, and a menu-bar workflow ([network](https://docs.orbstack.dev/docker/network), [host networking](https://docs.orbstack.dev/docker/host-networking), [USB](https://docs.orbstack.dev/features/usb), [menu bar](https://docs.orbstack.dev/menu-bar)) | Keep the existing native menu bar as the operational entry point. Treat direct networking, USB, and sound as separate entitlement/threat-model projects: each needs an opt-in capability, narrow discovery surface, clean detach/recovery, and no privileged helper shortcut. | Do not block the replacement on these; never imply parity before the security model is proven. |

The ordering is intentional: first make a normal Docker project boringly
compatible; then remove daily friction with domains, HTTPS, debug, and safe
file work; only then widen the trusted hardware/network surface or add Linux
machines. That produces a stronger free replacement than copying a closed
product's broad permissions or web-extension model.

## Authority and security boundary

| Category | Work | Policy |
| --- | --- | --- |
| **No macOS administrator privilege** | S0–S5 installation/service, Docker/Kubernetes actions, loopback TCP/UDP relay, user-selected shares, and an eventual local router. | This is the default. It does not lessen Docker-socket authority: only the signed-in user and explicitly trusted local processes may reach that socket. |
| **User approval / Apple capability feasibility spike** | Local CA trust, system-visible DNS via a Network Extension, and Finder integration such as FSKit. | These are not root-helper work by default, but may require explicit keychain consent, signed entitlements, user approval, or Apple distribution approval. Prove the exact macOS deployment path before promising the feature. Relevant platform references: [NetworkExtension](https://developer.apple.com/documentation/networkextension) and [FSKit](https://developer.apple.com/documentation/fskit). |
| **Privileged or system-wide mutation — avoid for 1.0** | Writing `/etc/resolver`, installing global routes or packet-filter rules, a privileged LaunchDaemon/helper, broad certificate trust, unrestricted filesystem access, USB/GPU forwarding. | Do not use these as a shortcut. They need a separate threat model, least-privilege command allowlist, install/uninstall story, and explicit user authorization. No current S0–S6 acceptance depends on them. |

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
- General Linux machines: an S6 differentiator, never an excuse to delay S0–S3.

## Source register

All external links below were checked 2026-08-03. Competitor statements are
their publishers' statements; no performance, privacy, or security claim here
is inferred solely from a feature page.

- OrbStack: [Docker Desktop comparison](https://docs.orbstack.dev/compare/docker-desktop), [domains](https://docs.orbstack.dev/docker/domains), [HTTPS](https://docs.orbstack.dev/features/https), [native files](https://docs.orbstack.dev/features/native-files), [Debug Shell](https://docs.orbstack.dev/features/debug), [Linux machines](https://docs.orbstack.dev/machines/).
- Docker: [Desktop networking](https://docs.docker.com/desktop/features/networking/), [Desktop Kubernetes](https://docs.docker.com/desktop/use-desktop/kubernetes/), [contexts](https://docs.docker.com/engine/manage-resources/contexts/), [daemon-socket security](https://docs.docker.com/engine/security/protect-access/), [synchronized file shares](https://docs.docker.com/desktop/features/synchronized-file-sharing/), [Buildx history](https://docs.docker.com/reference/cli/docker/buildx/history/), and [Extensions and security boundary](https://docs.docker.com/extensions/).
- Open-source alternatives: [Colima README](https://github.com/abiosoft/colima#features), [Rancher Desktop introduction](https://docs.rancherdesktop.io/).
- Ecosystem compatibility: [Testcontainers Java runtime requirements](https://java.testcontainers.org/supported_docker_environment/), [Testcontainers Go discovery](https://golang.testcontainers.org/features/configuration/), [Dev Container supporting tools](https://containers.dev/supporting.html), and [Kubernetes port-forward](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/).
- Apple platform feasibility references: [NetworkExtension](https://developer.apple.com/documentation/networkextension), [FSKit](https://developer.apple.com/documentation/fskit).
