# Docker Engine API compatibility inventory

Status: source-reviewed on 2026-08-03; **no live Docker, VM, bundle, or
ecosystem acceptance has been run for this inventory**. This is the engineering
ledger for making Morbstack a drop-in Docker Desktop replacement. It deliberately
separates a byte-relay observation from a demonstrated compatibility guarantee.

The release gate remains [clean-profile Docker acceptance](clean-profile-acceptance.md).
No row below may be promoted to "compatible" until its named acceptance evidence
exists for the signed candidate being described.

## Terms and version boundary

| Term | Meaning in this document |
| --- | --- |
| **Relay-reviewed** | Source review shows that this request is not interpreted by Morbstack's Docker proxy and is passed through its raw descriptor relay after the VM is available. This is not an end-to-end claim. |
| **Intercepted** | Morbstack reads enough of a request or response to enforce a host boundary or to make local port forwarding truthful. It may reject a request before the guest Engine sees it. |
| **Accepted** | A release candidate has passed the specified live, clean-profile evidence. There are no Accepted rows yet. |
| **Engine capability** | Capability supplied by the bundled upstream `dockerd`; it still has to be enabled, configured, and supported by the selected Engine version. Raw relay cannot create a capability the Engine lacks. |

Docker's [Engine API overview](https://docs.docker.com/reference/api/engine/) says
that client and daemon negotiate API versions, with a client able to downgrade to a
daemon's supported level. The official reference retrieved for this audit on
2026-08-03 described Docker Engine 29.6.1 with API maximum `v1.55` and minimum
`v1.40`. Those reference-site values are research context, **not** a statement of
the Morbstack runtime version. The shipped daemon version, image digest, API
minimum, API maximum, and BuildKit version must be recorded from the signed
candidate's `docker version` evidence for every release.

The public socket does not use Morbstack's internal API pin as its compatibility
limit:

- `DockerProxy` accepts a connection on `~/.morbstack/run/docker.sock`, starts the
  VM on demand, and forwards an ordinary client request to the guest Docker API.
  Its endpoint classifiers compare the tail components of the path, so an optional
  caller API-version prefix does not avoid the intentional create/start/restart
  policies below.
- `DockerAPIDecoding.apiVersion` is `v1.43`, but only for Morbstack's own host-side
  reads of `containers/json`, `events`, and exact-ID container inspect. It is not a
  public-socket whitelist or a declaration that the bundled Engine is `v1.43`.
- API compatibility must be evaluated against the Engine version that actually
  ships. Relevant field changes are listed in Docker's
  [version history](https://docs.docker.com/reference/api/engine/version-history/);
  any intercepted create field needs an explicit review at that version.

## Transport contract and intentional deviations

The proxy uses a Unix socket on the Mac and a vsock connection to the guest. For
unclassified traffic, `FDRelay` copies descriptors in both directions; it does not
parse, normalize, or re-encode Docker HTTP. That preserves unknown endpoints,
streaming response bodies, connection upgrades, and future versioned paths at the
transport layer, but it is not evidence that every one works through the guest.

The following deviations are intentional and must remain visible in compatibility
copy and diagnostics:

| Request class | Source-reviewed behavior | Required proof before a compatibility claim |
| --- | --- | --- |
| VM unavailable or guest Docker API connection fails | The proxy returns a Docker-style JSON `502` rather than silently resetting the client connection. | Startup, suspension, and shutdown behavior in the clean-profile release run. |
| Unclassified Engine request, including chunked and upgraded traffic | Relay-reviewed as opaque bytes after VM startup. There is no endpoint whitelist in the normal relay. | Representative HTTP, streaming, hijacked, and keep-alive cases in the family matrix below. |
| `POST /containers/create` | Intercepted only when the bounded preflight can read a fixed-length JSON create request. Bind-source policy and published-port policy can reject it before forwarding; all other create framing stays raw relay. | Container, bind-mount, port, and malformed/request-framing scenarios below. |
| `POST /containers/{id}/start` and `/restart` | A bodyless request may be observed to activate a held fixed-port TCP/UDP lease, or an exact full-ID stopped container may have a bounded inspect recovery before relay. Name/prefix identifiers, bodies, and unsupported forms remain raw relay. | Start/restart, failed start, restart, VM-stop recovery, name/prefix, and keep-alive scenarios. |
| `-p` published ports | Phase 1 has source-level support for compatible fixed TCP/UDP and bounded dynamic TCP/IPv4-UDP create shapes. It reserves the complete real Mac loopback listener/socket set before a successful create can be returned. Docker CLI `create -p` and `run -p` share that create shape; `create` retains an inactive held lease until a later start. Exact coverage and gaps are in [dynamic-port-allocation.md](dynamic-port-allocation.md). | The `-p` matrix in that document plus clean-profile CP-04 and CP-06. Until then it is **implemented pending live acceptance**, not established drop-in parity. |
| `-P` / `PublishAllPorts` | Kept outside the bounded request-rewrite path; served by the unmodified upstream Engine's own `--userland-proxy-path` hook instead of a request rewrite. The Engine resolves its own effective exposed-port set at start and execs Morbstack's userland-proxy wrapper once per resulting binding; the wrapper leases the Mac endpoint from the host over vsock before the Engine lets the container start succeed. | The full `-P` acceptance matrix in [the source-level contract](#publish-all--p-source-level-contract). Until it runs, this is **implemented pending live acceptance** (in progress 2026-08-04), not established drop-in parity. |
| Host bind mounts on create | An interceptable request is checked against the running VM's declared/attached shared paths. An unshared, escaping, unmounted, nonabsolute, or required-missing bind source gets a Docker-style pre-create error. Exact guest Docker-socket sources (`/var/run/docker.sock` and `/run/docker.sock`) are intentionally passed to the guest without a Mac share check for Docker-outside-of-Docker/Dev Containers. Engine-owned malformed/unknown grammar remains with `dockerd`. | Valid `-v` and `--mount`, missing source, symlink escape, unshared source, share remount, Compose, Dev Containers workspace, and Docker-socket fixtures. |

The fixed-length dynamic create transaction is intentionally narrow: it rejects
`Expect: 100-continue`, requires a single numeric `Content-Length` and bounded JSON
body, and requires one bounded nonchunked `201` response before that response reaches
the client. It preserves unread bytes for a following keep-alive request. This is a
correctness boundary, not a reason to broaden a partial HTTP parser. Chunked,
oversized, malformed, upgraded, or otherwise opaque creates retain the raw relay
unless and until a separately designed protocol owns their framing.

## Engine API surface ledger

The categories below track the official Docker Engine API tags and the non-tagged
build-session transports that normal tools rely upon. An entry saying
"relay-reviewed" means only that the proxy source has no category-specific handler;
the guest Engine's availability and semantics still require live evidence.

| Engine API family | Proxy path today | Interception / known boundary | Minimum acceptance evidence |
| --- | --- | --- | --- |
| Version and system: `/_ping`, `/version`, `/info`, `/events`, `/system/*`, `/distribution/*` | Relay-reviewed for a client connection. Morbstack separately makes internal, pinned `v1.43` reads for its own port reconciler. | Event stream must tolerate long-lived bodies; the internal reader is not on the client's connection. | CP-02/CP-03 plus `_ping`, `docker version`, `docker info`, a filtered event stream, and registry distribution inspection against a disposable registry. |
| Containers: list, inspect, create, start, stop, restart, kill, wait, remove, rename, pause, unpause, update, prune, changes, top, stats | Relay-reviewed except create/start/restart as described above. | Create can be rejected for bind/port policy; bodyless exact-ID lifecycle may be observed. There is no source proof for every container field or lifecycle edge. | `run`, detached lifecycle, exit-code/wait, rename/remove/prune, stats, logs, failure paths, keep-alive reuse, and start/restart after VM restart. Include the `-p` and `-P` matrices separately. |
| Interactive container transports: attach, logs follow, exec create/start/resize, archive get/put | Relay-reviewed. These forms often use streaming or upgraded/hijacked connections and must not be reduced to ordinary JSON success checks. | No special endpoint handling found in `DockerProxy`; the byte relay preserves archive payload and Docker metadata headers unchanged. Guest PID 1 ignores `SIGPIPE`, so a cancelled tar/log/terminal receiver becomes a per-relay I/O failure rather than a guest crash. Raw transport is necessary but insufficient proof of Engine archive semantics. | Interactive TTY attach, stdin/stdout/stderr multiplexing, `docker exec -it`, `docker cp` both directions including ownership/mode/symlink/path-error fixtures, `docker logs -f`, cancellation, and client disconnect. |
| Images and registry transfer: list, inspect/history, pull, push, tag, remove, load/save, search, prune, commit, import/export | Relay-reviewed. | Registry credentials are supplied by standard Docker client configuration/credential helpers, not invented by the proxy. The relay does not prove auth or credential-helper behavior. | Public pull and local-registry push/pull; `docker login` with redacted credentials; `credHelpers`/`osxkeychain` fixture; image load/save; `docker image prune`; CP-04. |
| Build and BuildKit: `POST /build`, build progress, builder lifecycle, `/session`, `/grpc` | Relay-reviewed as opaque bytes. Buildx may use an Engine-bound builder or a separate `docker-container`, remote, or Kubernetes builder. | Build sessions are specifically streaming/upgrade-sensitive. The relay preserves normal EOF half-closes, but terminal I/O errors abort both endpoints so a cancelled session cannot pin its guest connection slot. Docker has deprecated some session endpoints in newer API history, but that is not evidence of their absence in a selected Engine. | CP-04 `docker buildx build --load` followed by run; `docker build`; Buildx builder create/inspect; build secret/SSH fixture with redacted outputs; cache/export behavior only when claimed; container-driver fixture. |
| Networks: list, inspect, create, connect/disconnect, remove, prune | Relay-reviewed. | Published-port forwarding is a host integration layered around container create; it is not proof of every Docker network driver or host-network behavior. | Bridge network create/connect/DNS/disconnect/remove; Compose project network; IPv4/IPv6 behavior only after its own evidence; host network reported exactly as guest Engine supports. |
| Volumes: list, inspect, create, remove, prune | Relay-reviewed. | Named volumes, including `POST /volumes/create` driver options and Compose `driver_opts`, remain opaque Engine payloads. Host bind mounts are different and are subject to the create policy above. Morbstack's separate archive-copy migration helper accepts only option-free `local` volumes; it refuses rather than drops or replays mount/device options. | Named volume round-trip and removal; `docker volume create --driver local --opt …` followed by inspect/mount; Compose named volume with `driver_opts`; `-v` and `--mount type=bind` valid/failure matrix; Dev Containers mount fixture. |
| Swarm control plane: swarm, nodes, services, tasks | Relay-reviewed. | The relay does not enable swarm mode, manager quorum, overlay networking, or multi-node semantics. | Only claim if an explicitly provisioned, version-pinned swarm fixture covers init/join, service scale/update/rollback, secrets/configs, tasks, network, leave, and complete cleanup. Otherwise report the Engine configuration truthfully. |
| Swarm resources: configs and secrets | Relay-reviewed. | No source evidence says the selected Engine runs as a swarm manager. Secret values must never be retained in fixture output or diagnostics. | Manager-only fixture creating, consuming, rotating/removing configs and secrets, with redacted logs and cleanup. |
| Plugins | Relay-reviewed. | Plugin availability depends on the guest Engine, plugin privileges, and networking; it cannot be inferred from the host app. | Explicit opt-in guest plugin fixture, install/enable/disable/remove, capability review, and full cleanup. Do not call this Docker Desktop parity merely because endpoints relay. |
| Legacy or daemon-specific extensions, future versioned endpoints, and requests outside the documented tag set | Relay-reviewed when they are not one of the classified paths. | No endpoint contract is inferred from byte relay. A new path can still fail in `dockerd`, the guest, credentials, or host integration. | Add a version-pinned fixture and a row in this ledger before public support is claimed. |

This matrix does not reduce compatibility to CRUD. The Docker client uses long-lived
event connections, attached/hijacked terminals, tar streams, registry auth, BuildKit
sessions, and HTTP keep-alive. A passing `docker ps` never proves those paths.

## Normal Docker ecosystem acceptance

These are the client paths Morbstack must protect first. They all use the selected
Docker context/socket; none should require a Morbstack-only environment override or
a patched client.

| Ecosystem | Why it is a compatibility boundary | Release evidence | Source |
| --- | --- | --- | --- |
| Docker CLI | Negotiates API version and exercises virtually every Engine API family through a context or `DOCKER_HOST`. | CP-02, CP-03, CP-04, and focused API-family cases above. Include normal context, direct Unix socket, and no app window. | [Docker Engine API overview](https://docs.docker.com/reference/api/engine/) |
| Docker Compose v2 | Materializes Compose services, networks, volumes, logs, exec, build, environment interpolation, and port/bind-mount forms through the normal Engine client path. | CP-04 immutable Compose fixture and additional ports, bind mounts, secrets/configs if claimed. | [Compose CLI reference](https://docs.docker.com/reference/cli/docker/compose/), [Compose specification reference](https://docs.docker.com/compose/compose-file/) |
| Buildx / BuildKit | Uses the selected builder and can use Engine-bound or independently managed builder backends. Build requests may depend on BuildKit sessions, secrets, SSH, cache, and content streaming. | CP-04 `--load`, then run; version-pinned `docker-container` driver and `docker buildx ls`; secret/SSH redaction fixture before those features are claimed. | [Docker Build overview](https://docs.docker.com/build/concepts/overview/), [builders](https://docs.docker.com/build/builders/), [Buildx create](https://docs.docker.com/reference/cli/docker/buildx/create/) |
| Testcontainers (Java, Go, Node, Python) | Normal discovery finds a Docker-compatible endpoint, starts disposable containers, and often depends on dynamic port publication and cleanup. | CP-06: all four locked probes, no Docker override or Morbstack-specific setup, each starts, observes, and removes a real container. | [Testcontainers Java Docker environments](https://java.testcontainers.org/supported_docker_environment/) (the other language probes must be locked and recorded in the release fixture) |
| Dev Containers CLI and VS Code extension | Uses Docker context discovery, image build/pull, create, bind mounts, exec/attach, port forwarding, and cleanup in a developer workflow. | CP-07 clean editor profile: `up`, in-container command, cleanup, without custom host/socket configuration. | [Development Containers specification](https://containers.dev/implementors/spec/) |

The complete CP-01 through CP-07 commands, fixture rules, cleanup requirements, and
evidence-promotion rule are authoritative in
[clean-profile-acceptance.md](clean-profile-acceptance.md). A library working with a
hand-exported `DOCKER_HOST` is a diagnosis, not a passing replacement test.

### Host installation and discovery ledger

The table below is an exact source audit of the consented `morb install-cli`
path, refreshed 2026-08-03. It follows Docker's documented client configuration
rules where they are observable in a host-only installer. It does **not** prove
that any selected client, IDE, Testcontainers binding, or guest Engine completed a
real connection.

| Contract | Source-reviewed implementation | Still required before a compatibility claim |
| --- | --- | --- |
| Docker client configuration and context | `MorbDockerContext` writes the standard context metadata below `$DOCKER_CONFIG/contexts/meta/…/meta.json` (or `~/.docker`) and preserves other `config.json` keys while setting `currentContext`. That atomic update follows an existing `config.json` symlink to retain the target and its POSIX mode, which protects inline registry `auths` as well as `credHelpers`/`credsStore`. Status reports the documented process-visible precedence: nonempty `DOCKER_CONTEXT`, then `DOCKER_HOST`, then saved `currentContext`; command-line `--context`/`--host` are intentionally outside a process snapshot. A same-named foreign or malformed context is preserved. | CP-02 must use `docker context show` and `docker context inspect morbstack` with a clean, ordinary shell. Verify the selected bundled CLI against the shipped Engine rather than treating compatible JSON layout as a successful connection. |
| Bundled Compose v2 and Buildx plugin discovery | `MorbCliPlugins` resolves the normal per-user `$DOCKER_CONFIG/cli-plugins` directory, installing only the bundle's pinned upstream `docker-compose` and `docker-buildx`. It accepts one complete root only: three regular executable files, the exact compiler-pinned source hashes in `TOOLCHAIN.plist`, and matching final hashes. For a packaged app, the valid outer code signature seals that manifest and its signed nested tools; an invalid/incomplete bundle never falls back to a checkout. A non-Morbstack file or link is a blocking conflict; only a recognisable older Morbstack bundle/check-out link can be upgraded. The legacy `morb install-cli-plugins` path preserves an unmanaged collision too. | CP-01 validates the signed payload; CP-02 records `docker compose version` and `docker buildx version`; CP-04 runs a real Compose project and `buildx build --load`. The audit does not prove Docker CLI plugin search precedence beyond the documented user directory. |
| Direct Unix-socket discovery | `MorbDockerContext` can create only a missing, user-owned `~/.docker/run/docker.sock` symlink to Morbstack's private socket. It rejects symlinked/unsafe parents and preserves an existing link, file, socket, or directory. The direct-discovery path intentionally stays under the real home directory even if a process chooses a separate `DOCKER_CONFIG`; it is a compatibility path for context-blind consumers, not Docker CLI configuration. | CP-03 must prove that the link exists after the Engine is ready and that a stock client reaches the same Engine by normal configuration and by the direct Unix path. This source audit does not establish how every Testcontainers language binding ranks candidate sockets. |
| System socket and context-blind tools | Morbstack never writes `/var/run/docker.sock`; it offers only a displayed manual command because that is a system-owned path. `Doctor` identifies competing user-level discovery sockets but does not force an environment override as a fix. | CP-06 and CP-07 must run locked Testcontainers and Dev Containers fixtures with no Docker override. A manual `/var/run/docker.sock` link or exported `DOCKER_HOST` is diagnostic evidence only, never a passing drop-in result. |
| Reinstall and removal ownership | Combined setup preflights all CLI links before writing; it refuses unmanaged collisions and rechecks ownership immediately before replacement. Cleanup removes only symlinks whose resolved targets match a Morbstack bundle/check-out layout, including nested `host-bin/cli-plugins` links. | CP-02/CP-05 need an idempotent-reinstall and owned-state-cleanup observation on a signed candidate. The source check cannot prove macOS permissions, quarantine, bundle movement, or an interrupted upgrade's recovery behavior. |

## Published ports: `-p` first, then `-P`

`-p` is a required normal Docker path. The current implementation deliberately
addresses it before Kubernetes or UI expansion. The source-level Phase 1 contract is
documented in [dynamic-port-allocation.md](dynamic-port-allocation.md): compatible
TCP and fixed IPv4/default UDP bindings reserve real Mac loopback endpoints before
the Engine receives the create; exact omitted/empty/`"0"` TCP and IPv4/default UDP
bindings use the bounded rewrite path and are retained in the same atomic lease. A
normal Docker CLI equal-length fixed TCP or supported UDP range is normalized into
those same individual concrete bindings, so it takes the fixed-port atomic lease
path. Raw dynamic host-port ranges, broad/ambiguous shapes, IPv6 UDP, and
non-loopback external publication are not silently presented as supported. The
cross-transport source boundary and pending live matrix are in
[`dynamic-port-allocation.md`](dynamic-port-allocation.md).

Docker documents `-P` as publishing every exposed port to a random host port; it is
not a syntactic alias for a request-visible `-p <container-port>` binding. See the
[port publishing guide](https://docs.docker.com/engine/network/port-publishing/) and
[Docker run reference](https://docs.docker.com/reference/cli/docker/container/run/#publish-all-exposed-ports--p---publish-all).

### Publish-all (`-P`) source-level contract

The normal `docker run -P image` create body sets `HostConfig.PublishAllPorts`, but
does not necessarily contain the image's final `EXPOSE` set. The daemon resolves the
image reference and merges image configuration as part of creation, then expands the
effective exposed ports and allocates bindings. The relevant upstream implementation
must be reviewed at the exact Moby tag bundled in the candidate, not only at `main`:
[Docker CLI create options](https://github.com/docker/cli/blob/master/cli/command/container/opts.go),
[Moby create/image resolution](https://github.com/moby/moby/blob/master/daemon/create.go),
and [Moby network port-map expansion](https://github.com/moby/moby/blob/master/daemon/network.go).

The source implementation follows this boundary without touching the Engine at all:
Morbstack ships the unmodified upstream Engine and starts it with
`--userland-proxy-path=/usr/local/bin/morbstack-docker-proxy` (a multi-call symlink
to `morbinit`, `guest/morbinit/src/proxy_wrapper.rs`) — a stock dockerd flag, the
same hook Docker Desktop's vpnkit uses. Stock dockerd execs that wrapper once per
published port, *after* it has already expanded the effective port map (including
`-P`/`EXPOSE`-derived allocations) and *before* it lets the container start succeed.
The wrapper connects to the host over the guest-initiated vsock port-lease channel
(host port 2382, `mac/Sources/MorbstackKit/GuestPortLease.swift`), asks it to bind
the Mac-side endpoint, and only then execs the stock `docker-proxy` with dockerd's
original argv — so the in-guest listener and fd-3 readiness signal are unmodified
upstream behavior throughout. Lease lifetime equals that stock proxy process's
lifetime (EOF releases the Mac listener), so `HostConfig.PublishAllPorts` never needs
touching and the Engine reallocates on its own on a later start, exactly as it would
natively. This is source-implemented and unit-tested on both sides; the guest image
and signed bundle have not been verified to include it, and live Docker/VM acceptance
is in progress (2026-08-04).

A correct normal-CLI `-P` implementation has this non-negotiable boundary. The
wrapper design satisfies most of these by construction rather than by bookkeeping,
because it delegates to the real Engine instead of reimplementing any part of its
decision:

1. **Resolve where the Engine resolves.** Satisfied trivially: the unmodified
   upstream Engine resolves the image/config itself and the wrapper never inspects
   or re-derives that result — it only reacts to the concrete binding dockerd
   already decided on.
2. **Allocate before persistence.** dockerd execs the wrapper per binding after
   expanding the effective port map but before it lets the container start
   succeed; the wrapper must obtain the host's `OK` before it execs the stock
   `docker-proxy`, so the Mac endpoint is held before the Engine's own start
   response can report success.
3. **Preserve Docker's effective-port semantics.** Satisfied trivially: nothing
   clears or reinterprets `HostConfig.PublishAllPorts`; the Engine's own
   `EXPOSE`/`--expose`/`-p` precedence is untouched.
4. **Make lifecycle ownership explicit.** Satisfied by construction, not by a
   separate release protocol: lease lifetime equals the stock `docker-proxy`
   process's lifetime, so create failure, client disconnect, start failure,
   destroy, stop, start, restart, and Engine/VM restart all resolve to "the
   proxy process exited, so the lease ends" with nothing to reconcile.
5. **Fail before side effects for unsupported protocols/forms.** TCP and UDP go
   through the lease; SCTP passes straight through to the stock guest-side proxy
   with no Mac listener (matches Docker Desktop's own behavior, a documented
   residual gap, not a silent claim of support).
6. **Return ordinary Engine-visible truth.** Satisfied trivially: `docker port`,
   `docker inspect`, and the create/start responses come straight from the
   unmodified Engine; only host reachability and the forwarder ledger are
   Morbstack's own state, and they are driven directly by the same lease grant.

The first acceptance matrix for `-P` must cover, at minimum: image-provided TCP,
UDP, and SCTP exposures; explicit `--expose`; explicit `-p` precedence; multiple
ports; mutable-tag replacement race; preoccupied host port; create and start failure;
client disconnect; stop/start/restart; destroy; Engine/VM restart; `docker port` and
inspect agreement; real TCP and UDP reachability where supported; and cleanup. Until
the guest-image/bundle integration and that matrix pass, `-P` is **implemented pending
live acceptance**, not an established compatibility claim.

## Evidence register and promotion rule

| Evidence | Present status | What it proves |
| --- | --- | --- |
| Proxy source inspection | Complete for this inventory on 2026-08-03. | The routing/interception statements above, not guest/host behavior. |
| `-p` source design and focused static coverage | Implemented according to [dynamic-port-allocation.md](dynamic-port-allocation.md); live result absent. | Bounded implementation intent and its explicit exclusions, not host/guest allocation success. |
| CP-01 payload, CP-02 discovery, CP-03 direct socket | Not run. | Clean-account tooling, context, version negotiation, and socket availability. |
| CP-04 Docker/Compose/Buildx | Not run. | Core engine, Compose, Buildx, image, and basic networking behavior. |
| CP-05 app-window independence | Not run. | Normal Docker use while the UI is closed. |
| CP-06 Testcontainers | Not run. | Default discovery and dynamic-port behavior across four client ecosystems. |
| CP-07 Dev Containers | Not run. | Editor/CLI workflow including build, bind mount, create, exec, and cleanup. |
| API-family extensions in this ledger | Not run. | Each specialized public claim beyond the clean-profile core. |

For a release, attach the signed bundle digest, guest image digest, `docker version`
output, Docker/Compose/Buildx/Testcontainers/Dev Containers versions, macOS/hardware
version, immutable fixture revisions, redacted logs, and cleanup result. If any
entry is skipped, blocked, or fails, the public contract must remain narrowed to the
evidence that exists; relay-reviewed is never a synonym for compatible.

## Source map for future implementation reviews

- `mac/Sources/MorbstackKit/DockerProxy.swift` — public Unix-socket admission,
  VM/vsock connection, endpoint suffix classifiers, preflight, raw relay handoff,
  and Docker-style errors.
- `mac/Sources/MorbstackKit/Relay.swift` — bidirectional raw descriptor relay and
  passive response observation.
- `mac/Sources/MorbstackKit/DockerRequestFraming.swift` — HTTP/1.1 request framing for
  the client-to-guest direction, hijack classification, and head rewriting.
- `mac/Sources/MorbstackKit/DockerFramedRelay.swift` — the per-connection relay that
  frames every request until the Engine hijacks, and owns the request
  rewrite/response-association hold-back for dynamic TCP/UDP create. It replaced the
  former `DockerDynamicCreateTransaction`; see `docs/audit/PROXY-FRAMING.md`.
- `mac/Sources/MorbstackKit/DockerPortPublicationPreflight.swift` — supported and
  rejected published-port shapes.
- `mac/Sources/MorbstackKit/DockerBindMountPreflight.swift` — host bind-share
  admission policy.
- `mac/Sources/MorbstackKit/DockerAPI.swift` and `PortForwarder.swift` — internal
  `v1.43` reads and port-reconciliation behavior.
- `mac/Sources/MorbstackKit/MorbCliInstallation.swift` — consented, reversible
  bundled-client links, ownership preflight, and shell-profile integration.
- `mac/Sources/MorbstackKit/CliPlugins.swift` — standard CLI-plugin directory,
  bundle source lookup, and conservative plugin-link ownership classifier.
- `mac/Sources/MorbstackKit/MorbDockerContext.swift` — standard context metadata,
  selection-status model, and direct per-user socket ownership boundary.
- `docs/dynamic-port-allocation.md` — detailed `-p` contract and `-P` source audit.
- `docs/clean-profile-acceptance.md` — serial release gate; it is intentionally not
  replaced by this inventory.
