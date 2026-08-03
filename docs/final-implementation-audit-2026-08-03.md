# Final implementation audit — 2026-08-03

**Review snapshot:** `code/native-content-continuation`, after the implementation
wave recorded below. This is a source-and-static-review hand-off for an external
reviewer. It is deliberately not a release note or a claim that the clean-profile
acceptance matrix has passed.

## Product decision

Morbstack is being built as the best normal Docker experience on macOS: free for
personal and commercial work under Apache-2.0, no account, no feature gate, no
telemetry, no web-extension marketplace, and no hidden privileged helper. It is
not sufficient for the engine to start containers; ordinary Docker tools must find
and use the runtime without a Morbstack-specific workaround.

The delivery rule is therefore:

1. Make ordinary Docker boringly compatible: CLI/context/discovery, Compose,
   Buildx, ports, bind mounts, lifecycle, IDEs, and Testcontainers.
2. Remove daily workflow friction with native operations, image discovery, safe
   Compose editing, and diagnostics.
3. Add differentiated service routing, synchronized project files, safe native
   file access, and separate Linux machines only behind explicit authority,
   recovery, and acceptance contracts.

The canonical backlog remains [`drop-in-delivery-plan.md`](drop-in-delivery-plan.md).

## Executive status

| Area | Current source status | What may honestly be said | What may not be claimed yet |
| --- | --- | --- | --- |
| Normal Docker runtime | Upstream dockerd/containerd VM foundation, native daemon/app, consented context/direct socket/service path. | Implemented foundation pending clean-profile verification. | Release-ready Docker Desktop replacement. |
| Fixed and ordinary dynamic TCP `-p` | Host-owned loopback lease/preflight exists for normal fixed TCP and bounded dynamic create forms. | The source supports fixed loopback TCP mappings and the documented empty/zero dynamic forms. | Full port-publication parity, `-P`, ranges, dynamic UDP, IPv6-literal parity, or live acceptance. |
| `-P` / `PublishAllPorts` | Audited and intentionally rejected before guest side effects. | The gap and required atomic Engine-level design are documented. | That `docker run -P` works. |
| Docker context/CLI diagnostics | Context status now follows Docker precedence: `DOCKER_CONTEXT`, then `DOCKER_HOST`, then saved context. | The diagnostics no longer misstate the shell's effective selection. | That a clean account has been proven end-to-end. |
| Builds | Native cache/history view with bounded selected detail/log reads. | Buildx history is an explicit read path, not inferred cache data. | Live build-history acceptance on a clean candidate. |
| Explore Images | Bounded public Docker Hub discovery service is implemented. | A future native command can explicitly search public Hub repositories without an account. | A finished Explore Images UI, private registry browsing, tags/digest resolution, pull, push, or universal OCI search. |
| Compose editing | No implementation landed in this wave. | The next UI feature has a clear safety shape below. | A live Compose editor, automatic validation, deployment, or a generic YAML dashboard. |
| Environment and secrets | No generic secret store landed. | Docker/Compose/Build secrets have been researched as distinct contracts. | That a Keychain field can transparently replace Swarm secrets, Compose secrets, `.env`, or BuildKit secrets. |
| Kubernetes | Bounded selected-Pod forwarding source/CLI exists behind a private helper boundary. | It is source groundwork only, currently unavailable because the verified helper bytes are absent. | A shipped Kubernetes port-forward, native action, broad workload control, or user-kubeconfig integration. |
| Shared-file hot reload | Host/guest contracts and validation foundations exist. | The system fails closed instead of simulating inotify. | A watcher, cache, transport, synchronized content, or hot reload. |
| Local domains/HTTPS | A security-first S5 contract exists. | The future authority, resolver, Keychain, revocation, and recovery decisions are recorded. | `*.morb.local`, `*.morb.test`, routing, DNS, HTTPS, or a trusted CA. |
| Linux machines | An M1 image admission/storage-plan boundary exists. | A valid declaration still returns unavailable; it cannot create a VM or disk. | Machines, SSH, cloud-init, image download, or isolation evidence. |

## Normal Docker is the immediate priority

### Published ports: `-p` versus `-P`

The user-facing priority is correct: `docker run -p …` is non-negotiable for a
drop-in replacement. Current source behavior is recorded in
[`dynamic-port-allocation.md`](dynamic-port-allocation.md):

- Fixed loopback TCP: normal `-p 8080:80`, `-p 8080:80/tcp`, explicit
  `127.0.0.1`, and compatible multiple mappings use the held-listener lifecycle.
- Bounded dynamic TCP: `-p 80`, Docker API omitted `HostPort`, exact empty
  `HostPort`, and exact `HostPort: "0"` are rewritten before create to a real
  loopback reservation, then activated only after the Engine's successful start.
- Fixed UDP is event-confirmed forwarding, not a synchronous dynamic allocation
  guarantee.

The remaining gaps are material: IPv6 literal forms currently do not have a
matching IPv6 listener/reservation path; `-P`, ranges, dynamic UDP, non-loopback
and ambiguous forms, opaque/chunked framing, and live VM acceptance are not done.

`-P` is **not** another spelling of dynamic `-p`. Docker resolves image `EXPOSE`
ports inside dockerd and may reallocate them across lifecycle transitions. A proxy
that materializes fixed ports from an image pre-inspect would change Docker's
semantics. Morbstack must either add an atomic guest-Engine allocation handshake
or keep `-P` explicitly unavailable. The source audit is
[`dynamic-port-allocation.md`](dynamic-port-allocation.md#source-audit-why--p-is-not-another-empty-hostport).

### Compatibility posture

The target is the unmodified upstream Engine API and normal Docker discovery, not
a partial wrapper that claims “all Docker spec” while intercepting only the happy
path. The concrete next step is an API/client compatibility matrix with real
clean-profile runs for Docker CLI, Compose, Buildx, Java/Go/Node/Python
Testcontainers, Dev Containers, fixed/dynamic ports, mounts, restart/recovery, and
context/socket discovery. That matrix is a release gate in
[`clean-profile-acceptance.md`](clean-profile-acceptance.md); it is not run yet.

## Quality-of-life feature direction

### Images and public registry discovery

Docker Desktop's Images workflow combines local images with Hub discovery and
explicit run/pull/inspect actions. Morbstack's safe first slice is implemented in
[`image-discovery.md`](image-discovery.md): a person explicitly initiates one
credential-free public Docker Hub query; it returns at most 25 bounded results and
surfaces cancellation, rate limit, timeout, redirect, malformed, and unavailable
states. It never performs a pull, reads Docker credentials, contacts the daemon,
or turns an OCI registry host into a generic search endpoint.

Next implementation: make this a native Images scope using the existing system
toolbar/search/`Table`/inspector patterns. A search result should prefill an
explicit Pull or Run flow; it must not pull merely because a result was selected.
Private Hub and other registries need a separately consented authentication and
provider contract.

### Compose editing

The desired feature is an explicit document workflow, not a web-form approximation
of Compose. The first version should let a person choose a local `compose.yaml`,
edit plain source with normal macOS document semantics, expose unsaved/save/discard
state, and never deploy or rewrite the project automatically. A later explicit
Validate action may run the bundled `docker compose config` only after showing the
Compose trust boundary: Compose files can reference host files, symlinks, images,
bind mounts, devices, provider binaries, and secret/config inputs.

The editor must preserve comments and unsupported YAML rather than attempting a
lossy “visual builder.” A visual project creator can follow as an optional, narrow
generator whose output is ordinary editable Compose YAML.

### Environment variables and secrets

There must not be one misleading “secret manager” abstraction:

- **Compose environment / `.env`:** an explicit project-file editor can redact
  values by default, explain precedence, and write only on Save. The values remain
  project files and must not be represented as encrypted Docker secrets.
- **Compose secrets:** file/environment-backed Compose secrets must keep their
  declared source, per-service grant, target/mode, and source-file trust warnings.
- **Swarm secrets:** these are Engine/Swarm objects, encrypted at rest/in transit
  in Swarm and mounted into service tasks; they are not available to standalone
  containers.
- **BuildKit secrets:** these are explicit build-session mounts and must never be
  serialized into an image or silently copied into a project file.

The next implementation is a native, explicit Compose `.env` document model and
editor, followed by a distinct Swarm-secrets surface only when Swarm capability and
its lifecycle are proven. No secret value should enter logs, diagnostics, title
strings, clipboard by default, or a generic global store.

## Source work committed in this wave

The following commits are all on `code/native-content-continuation` and were
static-checked before commit. They are grouped by outcome rather than presented as
release claims.

| Outcome | Commits |
| --- | --- |
| Product truth and CLI context precedence | `daf5579`, `2ad1346` |
| TCP lifecycle and normal-port audit | `c1715ea`, `b5cfde0`, `e2742ef` |
| Buildx history/detail/log handling | `276664c`, `c46062f`, `f61a1ac`, `0aa2069`, `7dbe878`, `5577f44`, `852ac32`, `9f4d9b0`, `8eab128` |
| Kubernetes helper provenance, bounded coordinator, and explicit CLI lifecycle | `2e1b3ed`, `f9a2867`, `b4fb28e` |
| Synchronized-share design and exact host/guest validation contracts | `351d701`, `cb70007`, `566d559`, `dde8cb5`, `aef003a` |
| Safe debug toolbox acquisition contract | `c9cb70c` |
| Local-service and Linux-machine delivery designs / machine admission boundary | `c81e66c`, `3107643`, `3157c39` |
| Public Docker Hub discovery foundation | `1382201` |

The current working tree is clean at this audit's creation. No destructive Git
operation, service lifecycle operation, Docker/Kubernetes action, VM action,
network fetch, test run, bundle build, or Computer Use action was performed in this
final source-only wave.

## What has not been executed

The current user constraint intentionally deferred the expensive acceptance lane.
Therefore none of the following may be silently inferred from source review:

- Swift/Rust compilation of this full commit range;
- signed-bundle assembly or launch;
- real WindowServer/Computer Use review of new visible routes;
- Docker, Compose, Buildx, port, bind-mount, or restart behavior against a live VM;
- Kubernetes port-forward against a live cluster;
- Docker Hub search against the public endpoint;
- Testcontainers, Dev Containers, or clean-profile integration acceptance.

The acceptance owner must run these serially once permission is available, using the
existing visual and clean-profile standards. A failure in that lane changes the
status from “source-backed implementation” to “not working”; it is not paperwork.

## Recommended next order

1. **Run the normal Docker acceptance lane first.** Build/sign once, then execute
   the clean-profile context/socket/service checks and a focused port matrix. Start
   with fixed `-p`, dynamic `-p`, multi-port TCP, stop/start/restart, bind mounts,
   Compose, and Buildx.
2. **Close the highest-impact Docker gaps.** Add a correct dual-stack listener
   lifecycle for IPv6 `-p`; then design an atomic guest allocation protocol for
   `-P` rather than a proxy rewrite. Treat ranges and dynamic UDP as independent
   protocols with their own conflict and recovery semantics.
3. **Finish normal-Docker UX.** Wire public image discovery into the native Images
   route; build the safe Compose document editor; then add the project `.env`
   workflow and Compose trust/secret warnings. Each external effect remains an
   explicit action.
4. **Prove ecosystem discovery.** Add immutable Testcontainers and Dev Containers
   fixtures, then run them only through standard Docker context/socket behavior.
5. **Return to differentiators.** Complete actual synchronized sharing before
   claiming hot reload; then local-service routing, native files, and isolated
   machines in their documented authority order. Kubernetes remains useful but is
   not on the critical path for a normal Docker Desktop replacement.

## External review prompts

1. Is the `-p`/`-P` boundary technically correct, and is an Engine-side allocator
   the right next design for standard `-P` semantics?
2. Does the image-search contract have the right minimum privacy and correctness
   boundary before a native UI is added?
3. Does the Compose editor proposal preserve source fidelity and Compose's trust
   model, or should a first release be read-only plus explicit handoff to an editor?
4. Is the secret/environment separation sufficiently strict—Compose project files,
   Compose secrets, Swarm secrets, and BuildKit secrets should not collapse into one
   product abstraction?
5. Is the ordered acceptance plan strong enough to prevent a source-only feature
   from being promoted before real Docker ecosystem evidence exists?

## Primary research consulted

- Docker's [Images view](https://docs.docker.com/desktop/use-desktop/images/) and
  [Docker Hub search](https://docs.docker.com/docker-hub/image-library/search/)
  establish the useful local-image/discovery/run/pull workflow, while Morbstack's
  first slice deliberately avoids account-gated private repositories.
- Docker's [Compose environment interpolation guidance](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/),
  [Compose services reference](https://docs.docker.com/reference/compose-file/services/),
  and [Compose trust model](https://docs.docker.com/compose/trust-model/) establish
  the `.env`, secrets/configs, and host-file trust boundaries.
- Docker's [Swarm secrets guidance](https://docs.docker.com/engine/swarm/secrets/)
  and [Build secrets guidance](https://docs.docker.com/build/building/secrets/)
  establish why those two mechanisms cannot be represented as ordinary environment
  variables or as a project-file convenience field.
- Docker's [port publishing documentation](https://docs.docker.com/engine/network/port-publishing/)
  plus the Docker CLI/Moby source references in
  [`dynamic-port-allocation.md`](dynamic-port-allocation.md) establish the `-p` and
  `-P` distinction used above.
