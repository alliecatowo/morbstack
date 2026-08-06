# SSH agent forwarding (UX-19)

Two separate questions hide behind "does SSH agent forwarding work":
build-time (`docker buildx build --ssh default`, forwarding into `RUN
--mount=type=ssh`) and runtime (a running container that wants to `git push`
or otherwise use the user's own keys). This doc covers both, in the order
the ticket asked for them to be answered: evidence first, code only where
evidence does not already answer the question.

## Commit one: the build-time path — evidence, not code

**Claim: `docker buildx build --ssh default` already works against Morbstack,
by construction, with no SSH-specific code anywhere in this repo.**

### The mechanism

BuildKit's `--ssh` forwarding does not use a bind mount or an environment
variable at build time. When the `docker` CLI's `buildx` plugin runs a build
against the `docker` driver (BuildKit embedded in the daemon, the default
since Docker 23+), it:

1. Opens a **second** HTTP connection to the Engine API, `POST /session`,
   and immediately upgrades it — this carries a gRPC stream for the whole
   life of the build, including an `sshforward.v1.SSH` service that proxies
   whatever `SSH_AUTH_SOCK` the *client* (the machine running `docker
   buildx`, i.e. the Mac) has configured.
2. Sends the ordinary `POST /build` request, referencing that session by ID
   in the build request's query.
3. Inside the build, `RUN --mount=type=ssh` asks BuildKit's executor to dial
   the forwarded agent back through that same session.

None of this touches the container's filesystem or a bind-mounted socket
path. The whole mechanism is: one extra HTTP connection that immediately
stops being HTTP.

### Why Morbstack's proxy already carries it

`mac/Sources/MorbstackKit/DockerRequestFraming.swift`,
`DockerHijackDetection.isHijackCandidate`:

```swift
// BuildKit's session and gRPC upgrades.
if last == "session" || last == "grpc" { return true }
```

This check runs **before** the generic `Upgrade`-header check and does not
require one — `POST /session` and `POST /grpc` are unconditional hijack
candidates by path alone. Separately, and just as load-bearing, `POST
/build` is hardcoded to **never** be a hijack candidate regardless of
headers — the classic build request must keep its ordinary chunked-JSON
progress stream even if a stale `Upgrade` header shows up, because it is not
the connection carrying the session.

`DockerFramedRelay.handle(...)` (`DockerFramedRelay.swift`) writes an
admitted request's head and body to the guest exactly as received. For a
hijack candidate with no buffered body — which is what `POST /session` is,
an upgrade with no ordinary request body — it does not frame, inspect, wait
for a specific reply shape, or rewrite anything; it writes the head through
and then waits for the Engine's response to decide whether the connection
has actually been taken over (`DockerHijackDetection.confirmsHijack`, a
`101` or a Docker raw/multiplexed content type). This is the identical
"candidate, then response-confirmed" design already source-covered for
`exec`/`attach` in `docs/parity.md` rows #30 and #32 — `/session` gets no
special case beyond the one line above that nominates it.

Put together: the byte-exact splice the relay already performs for every
other hijacked Engine route (`exec`, `attach`) applies to `/session`
identically. There is no code path that could distinguish "a `/session`
connection carrying gRPC" from "an `attach` connection carrying a raw
stream" — both are opaque bytes to the relay from the moment the hijack is
confirmed. Nothing about SSH forwarding specifically had to be built,
because nothing about it needed to be recognized; it rides the same generic
mechanism BuildKit itself designed to look like any other HTTP/1.1 upgrade.

### What this is not

This is source reasoning from reading the relay and the framing detector,
not a command run against a live guest. The machine lane (VM boot, real
`docker buildx`) was held by another agent for the duration of this pass —
see the coordination note in the commit that added this doc. **The command
that turns this into a live PASS**, to run the next time the machine lane is
free:

```sh
# A private repo the runner's SSH agent can actually clone, and a Dockerfile like:
#   FROM alpine
#   RUN apk add --no-cache openssh-client git
#   RUN --mount=type=ssh git clone git@github.com:you/private-repo.git /src
DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock \
  docker buildx build --ssh default -t ssh-forward-probe .
```

A clean build (not a `Host key verification failed` or `Permission denied
(publickey)` failure) is the pass condition. Record the result as a new
dated line in `docs/parity.md` row #41, moving it from
`SOURCE-COVERED; live acceptance pending` to `PASS`/`FAIL` per that
document's existing discipline — a verdict there is the result of one dated
command against one build, not a inference from source, even a strong one.

## Commit two: the runtime path

The build-time case above covers "clone a private dependency during a
build," which is most of what people mean by "SSH agent forwarding" in a
container tool. It does not cover a **running** container that wants to use
the user's SSH keys itself (a `git push` from inside a dev container, an
SSH-based deploy script, etc.). Docker Desktop's documented answer to that
case is a fixed guest-side path:

```
/run/host-services/ssh-auth.sock
```

bind-mounted into the container and pointed at with
`SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock`. A Compose file or
devcontainer config copied from a Docker Desktop machine already has this
baked in; matching the path (not inventing our own) is what makes that copy
just work instead of silently failing to find the socket.

### Threat model — read this before turning it on

**This forwards the Mac's SSH agent into the guest VM.** Once enabled, every
container that bind-mounts `/run/host-services/ssh-auth.sock` and sets
`SSH_AUTH_SOCK` to it can ask the host agent to sign with the user's own
keys, for as long as this daemon process is running — identical in shape to
what Docker Desktop and OrbStack both already ship, but worth restating
because nothing about `docker run`ning an image implies "and it can now
authenticate as me." An agent (`ssh-agent`, `1Password`'s SSH agent, etc.)
does not hand out the private key itself, but it will sign whatever a
connected client asks it to sign — the guest cannot exfiltrate a key file,
but any container with the mount can produce a valid signature under it.

Because of that:

- **Off by default.** `MorbConfig.sshAgentForwarding` (`ssh_agent_forwarding`
  in `config.toml`) defaults to `false`. The guest-side local socket always
  exists (matching Docker Desktop's static contract, so a copied Compose
  file finds the *path*), but every connection to it is refused by the host
  with an explicit reason until the person running Morbstack opts in.
- **No blanket bind mount.** Nothing adds
  `/run/host-services/ssh-auth.sock` to any container automatically.
  Forwarding only happens for a container whose own `compose.yaml`/`docker
  run` explicitly names that bind mount — same as Docker Desktop.
- **Read fresh, not cached.** The host resolves `SSH_AUTH_SOCK` from its own
  process environment at the moment of each guest connection, so an agent
  that is not currently running (or was never started with an
  `SSH_AUTH_SOCK` in `morbstackd`'s launch environment) fails the connection
  with an honest reason rather than silently forwarding to nothing.

### Wire protocol

New vsock port, registered alongside the existing guest-initiated channel:

| Port | Purpose |
|------|---------|
| 2383 | Guest-initiated: the guest's local `/run/host-services/ssh-auth.sock` listener asks the host to splice a new connection to the host's real `SSH_AUTH_SOCK` |

Guest-initiated, following the exact shape of the existing port-lease
channel (2382, `docs/protocol.md` §3.6) rather than inventing a new
direction: the host is a listener the guest connects out to, one bounded
ASCII exchange, then the connection becomes the raw byte stream.

```text
guest -> host:  "SSHAUTH\n"
host  -> guest: "OK\n"             then the connection splices to $SSH_AUTH_SOCK
           or:  "ERR <reason>\n"   then the connection closes
```

Unlike the port-lease channel there is nothing to parametrize — the mapping
is always "the one host SSH agent" — so the request line carries no fields.
`ERR` reasons are specific and actionable: `"ssh agent forwarding is
disabled; set ssh_agent_forwarding = true in ~/.morbstack/config.toml to
enable it"` when the feature is off, or `"no SSH agent is available on the
host (SSH_AUTH_SOCK is not set)"` / a connect failure detail when it is on
but there is nothing to forward to.

### Implementation

- Guest: `guest/morbinit/src/ssh_agent_forward.rs`. Binds a Unix listener at
  `/run/host-services/ssh-auth.sock` (world read/write — the security
  boundary is the host's enable decision, not which guest UID can dial a
  local socket inside an already-isolated VM, matching Docker Desktop's own
  permissive local contract). Each accepted local connection dials
  `sys::vsock_connect(VMADDR_CID_HOST, 2383)`, writes the preamble, reads the
  bounded reply, and on `OK` splices bytes both ways with
  `proxy::copy_stream` — the same primitive `dial.rs`'s stream dialer uses,
  in the same half-close-aware shape. On `ERR` or an unreachable host, it
  logs the reason and closes; the local SSH client sees an ordinary
  connection reset, the same failure shape a missing Unix socket would
  produce on real Docker Desktop.
- Host: `mac/Sources/MorbstackKit/SSHAgentForward.swift`
  (`SSHAgentForwardServer`), registered via
  `VMManager.setGuestInitiatedConnectionHandler(port:
  MorbVsockPorts.sshAgentForward)` next to the existing port-lease server in
  `Daemon.swift`. Dials `SSH_AUTH_SOCK` with the existing
  `UnixSocketClient.connect(path:timeout:)` and splices with the existing
  `FDRelay` — no new transport primitive, only a new negotiation in front of
  primitives the docker-socket relay and the port-lease channel already use.

### What is deliberately not built

- No per-container or per-key ACL. The host-side gate is binary
  (forwarding on or off for the whole guest); a finer-grained policy (only
  these containers, only these keys) is a real Docker Desktop/OrbStack gap
  too and is future work, not a regression here.
- No agent auto-discovery beyond `$SSH_AUTH_SOCK`. If the person running
  Morbstack has an agent that does not export that variable into
  `morbstackd`'s environment (a GUI-launched daemon started before a login
  shell set it, for instance), forwarding fails with the honest "not set"
  reason rather than guessing a keychain-specific path.
