# Debug toolbox contract

`morb debug` deliberately has a **read-only planning surface**, not a shell.
It is the foundation for an isolated toolbox that can diagnose a distroless or
otherwise shell-less container without pretending that `docker exec` solves
that problem.

## Current commands

```console
morb debug check
morb debug [plan] <container>
```

`morb debug check` reads only the local feature contract. It does not open the
Docker socket, start the daemon, pull an image, or access a network.

`morb debug <container>` (also spelled `morb debug plan <container>`) makes one
read-only Docker Engine request:

```text
GET /containers/{id-or-name}/json
```

It extracts a redacted target summary—identity, image reference/ID, and
state—then records both the request made and the actions deliberately not
performed. It does not retain or print environment variables, labels, process
arguments, mounts, or credentials from the inspect document.

Both forms exit with status `2` while a toolbox cannot safely be offered. This
is an intentional unavailable result, not a partially working shell.

## Why an ordinary exec is not this feature

An exec session requires an executable already inside the target image. It
cannot help a distroless image that has no shell or diagnostic tools, and the
current client only collects complete exec output; it cannot safely relay a
live terminal. Docker itself treats its `docker debug` toolbox as a separate
tool-rich environment rather than a synonym for `docker exec`.

Morbstack must not suggest an exec command as a workaround for the toolbox
feature. A person may use their normal Docker tooling for a container they
already know contains a suitable executable, but that is a different operation
with different security and failure semantics.

## Execution gate

No `run` action or native-app Debug button may be added until every requirement
below is implemented and independently verified against a real engine:

1. **Verified immutable toolbox asset.** A local toolbox image needs a pinned
   digest plus verifiable provenance/signature before it is allowed into a
   target's namespaces.
2. **Consented acquisition and update policy.** If the asset is absent or
   expired, fetching it is a separately announced, user-approved network
   action. The product must define verification, retention, expiry, and
   rollback behavior; `morb debug` must never silently pull or refresh it.
3. **Isolated session policy.** The helper-container lifecycle must define the
   exact PID, network, filesystem/mount, user, capability, secret, and
   namespace boundaries. It must include cancellation, cleanup, and visible
   handling for a failed cleanup. The target container remains unmodified.
4. **Interactive terminal bridge.** A full-duplex stdin/stdout/stderr and TTY
   relay needs terminal-resize, disconnect, cancellation, and exit-status
   semantics. Capturing a completed Engine exec response is not sufficient.
5. **Truthful progress and recovery.** The command and any native UI must show
   the selected asset/provenance, the exact requested isolation, network
   consent, helper lifecycle progress, and cleanup result. No target state may
   be implied when it was not achieved.

The Engine API's container-inspect endpoint supports the current planner. The
future executor will require separately scoped, mutating Docker API calls only
after the preceding contract exists.

## Sources

- [Docker Engine API: inspect a container](https://docs.docker.com/reference/api/engine/version/v1.46/#tag/Container/operation/ContainerInspect)
- [Docker Debug CLI](https://docs.docker.com/reference/cli/docker/debug/)

These sources describe Docker's interfaces and toolbox behavior. They do not
authorize Morbstack to copy Docker's image, network, or privilege policy; this
document defines Morbstack's stricter execution gate.
