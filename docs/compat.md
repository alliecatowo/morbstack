# Compatibility contract

Status: living document. This is the drop-in compatibility contract
Morbstack commits to. It exists so "does my existing Docker workflow keep
working" has a precise, checkable answer rather than a marketing claim.

## What "drop-in" means

- **Unmodified `docker` CLI.** Morbstack does not ship or require a
  patched Docker CLI. Any stock `docker` binary (Homebrew, official
  release, etc.) works against Morbstack's relayed Engine API.
- **Docker contexts are respected, never stomped.** Morbstack adds itself
  as a context; it does not silently rewrite the user's existing default
  context or any other context they've configured. If the user has a
  non-Morbstack default context set (e.g. pointing at a remote Docker
  host, or at Docker Desktop during a side-by-side trial), Morbstack must
  not change that default without explicit user action.
- **Connection diagnostics follow Docker’s documented precedence.** A saved
  `currentContext` is not necessarily the endpoint a process will use.
  Morbstack’s read-only status and setup report resolve the process-visible
  choices as `DOCKER_CONTEXT` (when non-empty), then `DOCKER_HOST`, then the
  saved current context. A `DOCKER_CONTEXT` value therefore wins even when
  `DOCKER_HOST` is also set. Per-command `docker --context` and `docker
  --host` options have higher precedence and cannot be inferred from a
  process-level status report; that report never contacts an endpoint or
  exposes a `DOCKER_HOST` value.
- **Upstream Engine behind a transparent socket relay.** The API surface over
  `~/.morbstack/run/docker.sock` is supplied by the bundled upstream `dockerd`,
  and ordinary client traffic is relayed without a client endpoint whitelist.
  Morbstack intentionally intercepts bounded container-create and selected
  start/restart shapes to enforce bind-share safety and make host port publication
  truthful; those paths can reject unsupported forms before they reach the Engine.
  The exact API-version, relay, interception, and evidence boundary is maintained
  in [`docker-engine-compatibility-inventory.md`](docker-engine-compatibility-inventory.md).
  Version skew therefore includes both the selected upstream Engine and every
  explicitly documented host-integration policy; no source-level relay statement is
  a substitute for release acceptance evidence.
- **Compose v2 and buildx are bundled.** The packaged app carries pinned,
  unmodified upstream `docker`, `docker-compose`, and `docker-buildx`
  binaries. Its consented first-run transaction puts the client on PATH,
  installs both plugins in Docker's standard `cli-plugins` directory only
  when their targets are missing or positively identified as older Morbstack
  links, and registers a `morbstack` context without overwriting another
  explicit context. A user-owned plugin file/link is preserved and blocks the
  transaction rather than being replaced. See [`first-run.md`](first-run.md).
  The guest-side BuildKit
  capability remains subject to the clean-machine L1 release test; shipping
  a plugin is necessary but not by itself proof of end-to-end parity.
- **`~/.docker/config.json` is honored**, including:
  - `credHelpers` (credential helper delegation),
  - the macOS keychain credential helper (`osxkeychain`) specifically,
  - registry `mirrors` configuration.
  Morbstack reads this file the same way the standard Docker CLI/Engine
  tooling does; it does not require a separate, Morbstack-specific config
  file for any of the above.

## CI-enforced ecosystem compatibility matrix

Before this broader CI matrix can support a public drop-in claim, a packaged
candidate must pass the source-controlled
[clean-profile Docker acceptance matrix](clean-profile-acceptance.md). That
matrix proves default installation, context/socket discovery, bundled Compose
and Buildx, Testcontainers, and Dev Containers on a new account; it is a
release gate, not an assertion that the checks have already run.

The following are run in CI against Morbstack (target: M2 for the public,
CI-gated version of this matrix per `docs/roadmap.md`; some subset may run
earlier, ad hoc, during M0/M1 development):

- **Testcontainers** — Java, Go, Node, and Python client libraries.
- **VS Code Dev Containers.**
- **JetBrains** Docker/container tooling.
- **compose-spec** conformance suite.
- **DinD** (Docker-in-Docker) workloads.
- **buildx container driver.**
- **kind** (Kubernetes-in-Docker).
- **Tilt**, **Skaffold**, **act**, **Dagger**.
- **`--privileged`** containers, **cgroup v2**, and **seccomp** profile
  enforcement.

A workload class stays in this matrix once it's added; CI failures here
are release blockers from the milestone at which they're gated (see
`docs/roadmap.md`), not advisory.

## Explicit non-goals

Stated up front so they're not mistaken for gaps to be filled later:

- **Windows containers.** Never supported. Morbstack targets Linux
  containers only, matching the guest being a single Linux VM (see
  `docs/architecture.md`); there is no Windows container guest story on
  the roadmap at any milestone.
- **CRIU (checkpoint/restore).** Off. Not a target for 1.0 or the 1.x
  line as currently scoped.
- **CUDA / GPU passthrough.** Not supported. No commitment to add it.
- **Docker Desktop Extensions.** Not supported, and not planned as a
  compatibility target — Docker Desktop's extension model (web-view based)
  conflicts with Morbstack's "SwiftUI only, zero web views" host
  integration principle (see `docs/architecture.md`, host integration
  domain). A native plugin SDK is on the 1.x roadmap as the
  Morbstack-native replacement, but it is a different mechanism, not a
  compatibility shim for existing Docker Desktop Extensions.
