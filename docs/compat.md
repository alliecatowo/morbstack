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
- **Engine API = upstream moby, verbatim.** The API surface exposed over
  `~/.morbstack/run/docker.sock` is whatever the bundled upstream
  `dockerd` version exposes — Morbstack does not add, remove, or
  reshape API endpoints. Version skew concerns are the same ones that
  exist between any two upstream Docker Engine versions, not
  Morbstack-specific ones.
- **Compose v2 and buildx are bundled.** The packaged app carries pinned,
  unmodified upstream `docker`, `docker-compose`, and `docker-buildx`
  binaries. Its consented first-run transaction puts the client on PATH,
  installs both plugins in Docker's standard `cli-plugins` directory, and
  registers a `morbstack` context without overwriting another explicit
  context. See [`first-run.md`](first-run.md). The guest-side BuildKit
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
