# Drop-in delivery plan

Status: active source-backed triage, reconciled 2026-08-03. This is the
implementation order for Morbstack's claim to be a free, Apache-2.0,
no-account Docker Desktop replacement with OrbStack-style local-development
advantages. It does **not** promote an implemented path to a released claim.

## Decision rule

The first release claim is not "the engine can run Docker." It is: on a clean
Mac account with no Docker Desktop or Homebrew Docker, a person can install the
signed app once, close its window, and use ordinary Docker tooling without an
environment-variable workaround. The complete, source-controlled proof for
that statement is the seven-row [clean-profile acceptance matrix](clean-profile-acceptance.md).
Until it passes for the shipped candidate, the only honest status is
**implemented pending clean-profile verification**.

This plan keeps three kinds of evidence separate:

- [`parity.md`](parity.md) is a historical real-VM audit at `081aa29`; its
  failures remain historical results, even where later source has a targeted
  implementation.
- The current checkout packages the upstream Docker CLI, Compose, and Buildx
  (`mise.toml`; `MorbCliInstallation` and `CliPlugins`), and has a consented
  context/direct-socket/service path (`MorbDockerContext`,
  `MorbBackgroundService`, and `MorbSetupVerification`). Those are
  implementation facts, not clean-account proof.
- CP-06 and CP-07 are a release contract, not runnable fixtures today. This
  checkout has no pinned Java, Go, Node, Python Testcontainers probe or Dev
  Containers CLI/editor fixture and lockfile. Add those immutable fixtures
  before anyone runs or relies on the matrix.
- A product action is only available when its service boundary is real. For
  example, `morb debug` is an inspection plan, not a shell; current domains
  are inactive claim models, not hostname routing; and the share-event
  contract reports `unavailable`, not hot reload. The guest's retained
  version-1 record shape is compatibility metadata, not an event receiver.

## Product direction

Morbstack is intended to be the best default Docker experience on macOS, not
merely a compatible implementation or a cheaper Docker Desktop tier. That
means the ordinary path must be faster to understand, safer to repair, and
more pleasant to use than Docker Desktop, while the local-development
advantages people value in OrbStack are earned as open, inspectable features.

The non-negotiable product constraints are Apache-2.0 licensing for commercial
and personal use, no account requirement, no feature gate, no telemetry, no
web-extension marketplace, and no hidden privileged helper. Those constraints
do not lower the compatibility bar: normal Docker CLI clients, Compose,
Buildx, IDEs, Testcontainers, published ports, project files, and the local
Kubernetes workflow must work through their standard contracts. A future
convenience feature is valuable only when it has an explicit authority model,
reversible lifecycle, truthful unavailable state, and a real recovery path.

The delivery order below therefore starts with boring compatibility, then
removes daily workflow friction, then adds the differentiated local-service,
data-access, and machine experiences. No marketing copy, route, control, or
setting may imply an operation exists before its boundary and acceptance proof
exist.

## Canonical sequenced capability backlog

Each row is a shippable slice, not a promise that its foundation is already
verified. A slice advances only with the listed live acceptance. “No macOS
administrator privilege” does **not** make Docker authority harmless: a process
that can use the Docker socket can create containers and bind mounts. Keep that
socket private to the signed-in user, never publish it as unauthenticated TCP,
and treat every new path to it as a security boundary. Docker gives the same
warning for remote daemon access and documents contexts as the standard
mechanism for selecting an Engine ([socket security](https://docs.docker.com/engine/security/protect-access/),
[contexts](https://docs.docker.com/engine/manage-resources/contexts/)).

| Order and user-visible outcome | Boundary, security, and authority | Owning modules | Live acceptance required before promotion |
| --- | --- | --- | --- |
| **S0 — install once, then use ordinary Docker with no Morbstack window open.** The signed bundle provides Docker, Compose, Buildx, a conventional user socket, and a chosen `morbstack` context without changing an existing runtime. | Per-user links, profile block, context, socket, and `SMAppService` only; each must be reversible and owned by Morbstack. Explicitly choose service registration and engine start. Never replace `/var/run/docker.sock`, a non-Morbstack context, PATH choice, credentials, or shell content. | `RuntimeArtifacts`, `MorbCliInstallation`, `CliPlugins`, `MorbDockerContext`, `MorbSetupVerification`, `BackgroundService`, `FirstRunCLISetup`. | CP-01–CP-05 on a signed candidate: new account, normal shell, `/_ping`, Compose/Buildx, direct socket, app-window independence, idempotent reinstall, and owned-state cleanup. |
| **S1 — a successful Docker create/start has a usable host port and intended bind source.** Standard fixed TCP/IPv4-UDP publication and the bounded dynamic TCP/IPv4-UDP forms—an omitted `HostPort`, `HostPort: ""`, or exact `HostPort: "0"`—behave predictably; unsupported shapes fail plainly. | Bind only Morbstack-owned loopback listeners/sockets. Preserve an atomic reservation/hand-off and exact conflict/restart semantics; do not parse opaque/chunked bodies unsafely. Canonicalize only user-selected share roots and reject missing/unshared sources before a misleading container starts. | `DockerProxy`, `DockerPortPublicationPreflight`, `DockerDynamicCreateTransaction`, `PortForwarder`, `DirectoryShares`, `VMManager`, `guest/morbinit`. | Real VM: fixed-port race/conflict, each supported dynamic TCP/UDP request shape used by normal clients, restart/release, TCP and UDP request/reply, `/tmp`/`/private/tmp`/symlink bind success, and unshared bind error. A dated follow-up belongs in `parity.md`. |
| **S2 — Testcontainers and Dev Containers discover the runtime normally.** A language test or editor starts, reaches, and cleans up a dynamically published container with no Morbstack variables or patched library. | Fixtures use public pinned images, unique names, cleanup of only their own resources, no home/credential mount, and no Docker-host override. Discovery must use normal context/socket rules; Testcontainers’ documented default discovery is the compatibility target, not a custom provider configuration. | New pinned fixtures and lockfiles under `integrations/`; the S0/S1 modules above; release evidence in `clean-profile-acceptance.md`. | First add immutable Java, Go, Node, Python, Dev Containers CLI, and clean VS Code-extension fixtures. Then pass CP-04, CP-06, and CP-07 serially on the signed candidate. [Testcontainers Java](https://java.testcontainers.org/supported_docker_environment/) and [Dev Container supporting tools](https://containers.dev/supporting.html) establish the normal-discovery bar. |
| **S3 — edit on macOS and every normal container watcher sees the change.** Shared project roots give dependable bytes *and* observable guest-side change behavior. | Opt in to narrow project roots only; never watch a home directory or fabricate inotify events. Define initial sync, rename, conflict, overflow/rescan, reconnect, stop/start, and delete semantics before a host watcher begins. The current bridge contract is unavailable, not a live feature. | `DirectoryShares`, `MorbShareSurface`, `MorbLiveShareBridge`, `MorbConfig`, `VMManager`, daemon transport, `guest/morbinit`, Sharing settings and diagnostics. | Node/Vite, Python, Go, and rename-heavy workloads observe edits in the guest; prove initial/reconnect/overflow/non-shared outcomes and publish a benchmark against a native Linux tree. Docker describes its synchronized shares as a VM-local synchronized cache, which is the relevant behavioral bar—not FSEvents alone ([Docker docs](https://docs.docker.com/desktop/features/synchronized-file-sharing/)). |
| **S4 — finish the native operations that remove daily escape hatches.** Builds tell the truth about cache and durable history; migration, debug, disk recovery, and Kubernetes actions have real effects and recovery. | A build-history UI reads Buildx history records rather than inferring history from cache. Migration remains selected-only/no-overwrite; toolbox acquisition needs disclosed network, pinned provenance, isolation, cleanup, and PTY cancellation; disk growth is stopped-VM, grow-only, journaled, and verified. Kubernetes starts only by explicit opt-in. Its only proposed port-forward is a daemon-owned selected-Pod TCP lease on `127.0.0.1`, using bundled pinned `kubectl` plus Morbstack-private credentials: no user binary/config, no reconnect/retarget, with revalidation, cancellation, and complete cleanup. Exec remains a separate future capability, not an implied consequence of port-forward. | `BuildRunner`, `BuildsRootView`, new Buildx-history client in `MorbstackKit`; `MorbMigrate`; `MorbScan`; `MorbDiskResize`; `K8sRuntime`, `KubernetesAPIClient`, `KubernetesRootView`, `guest/morbinit/src/k8s.rs`; planned port-forward coordinator and bundled-tool provenance manifest. | Real clean engine/cluster and two-engine matrices: build record → inspect/logs; selected image/volume transfer plus changed-preflight review; debug cleanup after cancel; grow journal/recovery; Kubernetes enable, local-image workload, logs/events/describe, then the selected-Pod port-forward matrix in [`k8s.md`](k8s.md#planned-selected-pod-local-port-forward), diagnose/disable, and kubeconfig coexistence. No S4 item is a release claim until its stated matrix passes. |
| **S5 — local services feel native to macOS.** An explicitly chosen running service gains an exact local name, then optional HTTPS, with reliable stop/revoke behavior. | Existing `MorbLocalDomain` reconciliation is pure and fail-closed; it grants neither DNS nor routing. The S5.0 naming decision must resolve the current `.local` mDNS conflict before UI/host work. A daemon-owned loopback router requires a fresh running-owner proof **and** an opaque owner/generation-bound forwarder transport lease; proving a port then dialing it by number is insufficient. Resolver, CA/trust, Keychain, VPN/sleep, collision, and revoke state are separately consented capability work. Avoid `/etc/resolver`, broad DNS authority, a broad CA, global routing, and a privileged helper. | `MorbLocalDomain`, `LocalDomainClaimReconciler`, `PortForwarder`, new service-route coordinator/router/DNS/CA modules, `docs/domains.md`, native service status/repair UI. | First prove the canonical suffix and scoped resolver/standard-port feasibility. Then prove exact owner/port routing, port-reuse resistance, collision withdrawal, resolver/VPN/sleep behavior, opt-out, certificate removal, and native recovery. No name or HTTPS claim is public beforehand. |
| **S6 — add safe native files and separate Linux machines.** People can inspect/export data safely and later create disposable, SSH-ready machines without mutating the Docker VM. | Start read-only; never expose Docker storage as a writable Finder folder. A file-provider/FSKit path needs lifecycle, locking, consistency, quotas, and revoke semantics. A machine has its own disk, provenance, cloud-init/SSH-key ownership, export/delete, and isolation—not a mutable Docker-VM side door. The canonical planned boundary and promotion gates are in [`machines.md`](machines.md). | Existing archive workflows; new file-access/FSKit feasibility module; `MachineRegistry`, new machine VM/runtime modules, native files/machines routes. | Read-only inspection and controlled export/import preserve Docker storage under failure; any writable surface proves locking/recovery. A machine can be created, stopped, reached over SSH, exported, and deleted while the container Engine state remains unchanged. |

## Explicit non-claims

- Morbstack is not yet a publicly proven out-of-the-box Docker Desktop
  replacement; the clean-profile matrix is **not run**.
- It does not currently provide host-originated inotify/hot reload, full
  dynamic or raw-host-range-publication parity, synchronous dynamic-UDP leases, all
  arbitrary Docker proxy framing/start shapes, or a general host-networking
  promise. The bounded TCP creation path for omitted, empty, or literal-zero
  `HostPort` is implementation evidence, not that broader compatibility claim.
- `MorbLocalDomain` and `LocalDomainClaimReconciler` validate inactive,
  fail-closed prospective claims only. `*.morb.local` resolution or routing,
  automatic HTTPS, a local CA, active service routing, Finder-native
  container/image/volume access, a distroless debug shell, and general Linux
  machines are not shipped capabilities.
- Kubernetes is an opt-in local cluster with bounded read-only operational
  surfaces; it is not a general workload-control or port-forward product.
- Morbstack will not attain parity by silently modifying another runtime,
  `/var/run/docker.sock`, an existing Docker context, `~/.kube/config`,
  credentials, global DNS, a broad CA trust store, or privileged system
  services.

## Implementation cadence

One integration owner serializes builds, real VM checks, candidate assembly,
and clean-profile evidence. Other work can proceed in bounded source/docs
slices, but no feature is marked delivered until the owning implementation,
failure/recovery behavior, and evidence record land together. Update
[`product-audit.md`](product-audit.md), this plan, and the dated historical
follow-up in [`parity.md`](parity.md) in the same change that promotes a claim.
