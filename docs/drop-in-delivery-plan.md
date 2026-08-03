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
- A product action is only available when its service boundary is real. For
  example, `morb debug` is an inspection plan, not a shell; current domains
  are inactive claim models, not hostname routing; and the share-event
  contract reports `unavailable`, not hot reload.

## P0 — release blockers for a credible Docker Desktop replacement

### P0.1 Ship and prove the complete first-run contract

**Current foundation:** the packaged bundle requires `docker`,
`docker-compose`, and `docker-buildx`; `morb install-cli` plans, obtains
consent for, and reversibly installs user-owned links/plugins/context/direct
socket integration. It intentionally preserves a conflicting Docker context,
PATH selection, or socket. The native first-run sheet uses the same model.

**Remaining implementation decision:** make the durable, no-window runtime
choice unmistakable in onboarding. A per-user background service is present
but remains an explicit choice; no release may imply app-window independence
unless the selected path has passed CP-05. Do not solve compatibility by
overwriting `/var/run/docker.sock`, another context, or a shell profile.

**Release evidence:** CP-01 through CP-05: signed payload, ordinary `docker`
discovery, `~/.docker/run/docker.sock`, Compose/Buildx, and app-window
independence. Record exact candidate digest, macOS version, consent choices,
and cleanup.

### P0.2 Prove the ecosystem, not only `docker version`

**Current foundation:** the real historical audit proves upstream Engine,
Compose, persistence, Docker-in-Docker, Rosetta, and BuildKit once a client
plugin is present. The new bundle/install path now supplies that plugin, but
has not been proved on a clean account.

**Work:** execute the locked Testcontainers Java/Go/Node/Python probes and the
Dev Containers CLI/editor fixtures with normal discovery only. Failures must
be classified as payload, install/consent, socket/context, Engine behavior,
client compatibility, or fixture defect—never papered over with `DOCKER_HOST`.

**Release evidence:** CP-04, CP-06, and CP-07. This is the gate for calling
the product a drop-in replacement in an IDE, CI-like local workflow, or
language toolchain.

### P0.3 Never acknowledge an unusable Docker resource as successful

**Current foundation:** `DockerProxy`/`PortForwarder` holds a supported fixed
loopback TCP listener through the recognized create/start exchange and can
reclaim it for a canonical full-ID restart. The guest now has targeted
`/tmp` sharing and `host.docker.internal`/`gateway.docker.internal` code.

**Work:** run a new real-VM follow-up for historical checks #9, #18, and #19,
then prove fixed TCP conflict and restart behavior. For every remaining
unsupported publication shape—`-P`, ranges, dynamic UDP, opaque/chunked
framing, name/ID-prefix starts, unsupported addresses—the Engine-facing path
must reject or state its limitation plainly rather than return success with no
usable listener. Canonicalize and validate every bind source against explicit
shares so an unshared/misresolved source cannot become an empty guest path.

**Release evidence:** commands and real reachability/negative cases, with no
claim that the historical tally has changed until a dated rerun is recorded in
[`parity.md`](parity.md).

### P0.4 Keep Kubernetes scoped and recoverable

**Current foundation:** opt-in k3s shares Docker's image store; it has
enable/disable/status/diagnose/kubeconfig and bounded selected Pod/Node
descriptions. The native route provides read-only Pod logs and retained
events.

**Work:** make the initial enabled/off/recovery contract dependable in the
same clean profile. Do not put Kubernetes workload mutation behind decorative
controls. Cluster exec, attach, port-forward, create/delete, and generic
`kubectl` proxying are separate capabilities, not requirements to claim the
current local cluster works.

**Release evidence:** clean enable, local-image workload, host-reachable
Service, diagnostic/recovery path, disable, and kubeconfig coexistence with a
non-Morbstack configuration.

## P1 — daily-workflow accelerators once P0 is proven

1. **Restore host edit → watcher behavior.** The highest day-to-day gap is
   hot reload. VirtioFS has coherent reads but does not deliver guest inotify
   events. Start with a guest-side observable filesystem/sync mechanism; the
   current `share_event_bridge` version is only an unavailable contract. A
   host FSEvents watcher alone would be false progress. Require scoped roots,
   acknowledgement, overflow/rescan behavior, stop/restart recovery, and
   real Node/Python/Go watcher evidence.
2. **Finish escape-hatch workflows.** Complete the existing reviewed
   image/volume migration foundation with a real two-engine matrix, then a
   native volume transfer only after that proof. Add grow-only disk expansion
   only with a stopped-VM journal, guest filesystem resize, and postcondition
   check. Keep `morb debug` unavailable until a verified toolbox asset,
   consented acquisition, isolation, cleanup, and duplex TTY are all real.
3. **Turn local services into a Mac-native advantage.** After P0/P1.1,
   implement opt-in exact `*.morb.local` claim reconciliation, narrow
   loopback HTTP routing, and only then separately consented local HTTPS/CA
   trust. Resolver, VPN/sleep, collision, and revoke/removal behavior are
   release requirements; a label or prospective URL is not a route.
4. **Offer files safely before Finder mounts.** Begin with explicit
   read-only image inspection and controlled export/import. A Finder/FSKit
   surface requires separate locking, consistency, lifetime, and
   read/write-failure proof; it must not expose Docker storage as a casual
   writable folder.
5. **Broaden native operations deliberately.** Add Kubernetes exec and
   cancellable port-forward only with progress, cancellation, recovery, and
   least-privilege authorization. Linux machines, hardware forwarding, and
   broad host/container networking are distinct products with their own
   security models—not shortcuts around Docker-compatibility work.

## Explicit non-claims

- Morbstack is not yet a publicly proven out-of-the-box Docker Desktop
  replacement; the clean-profile matrix is **not run**.
- It does not currently provide host-originated inotify/hot reload, dynamic
  or range publish parity, synchronous dynamic-UDP leases, all arbitrary
  Docker proxy framing/start shapes, or a general host-networking promise.
- `*.morb.local`, automatic HTTPS, a local CA, active service routing,
  Finder-native container/image/volume access, a distroless debug shell, and
  general Linux machines are not shipped capabilities.
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
