# Clean-profile Docker acceptance

Status: release-gate contract; **not run**. This document defines evidence that
must exist before Morbstack is described as an out-of-the-box Docker Desktop
replacement. It is not a script, does not launch Docker, and does not turn the
implementation described elsewhere into a release claim.

## Scope and test environment

Run the matrix once per release candidate on a new, standard macOS user account
with a signed candidate in `/Applications`. Do not "clean" a real account by
deleting Docker data. The account must begin without `~/.docker`,
`~/.morbstack`, Docker Desktop, Homebrew Docker tooling, a selected Docker
context, or a shell-profile Docker override.

The evidence owner uses a new login shell after the consented first-run flow,
and leaves `DOCKER_HOST`, `DOCKER_CONTEXT`, `DOCKER_CONFIG`, and
`MORBSTACK_HOME` unset. The candidate—not a source checkout, a manually copied
plugin, or a helper environment variable—must supply the client and reach the
engine. Network access is allowed only for ordinary image/dependency pulls.

One owner runs this stateful matrix serially. Each result records the candidate
version and bundle digest, macOS and hardware version, full commands and output,
fixture/lockfile revisions, and cleanup result. A missing, skipped, or blocked
row is not a pass. Historical entries in [`parity.md`](parity.md) cannot satisfy
this new-account gate.

## Release matrix

| ID | Check | Required observation | Pass condition |
| --- | --- | --- | --- |
| CP-01 | Distributed payload | Inspect `/Applications/Morbstack.app/Contents/Resources/host-bin/` for regular, executable `docker`, `cli-plugins/docker-compose`, and `cli-plugins/docker-buildx`, plus `TOOLCHAIN.plist`; verify the installed bundle with `codesign --verify --deep --strict` and the applicable Gatekeeper assessment. Confirm the manifest has exactly the pinned Docker, Compose, and Buildx `source_sha256` values and its final hashes match the sealed bundled files. | The signed candidate contains one complete, hash-verified three-tool root; no file is a symlink or borrowed from Docker Desktop, Homebrew, or the test account. |
| CP-02 | Consented installation and normal discovery | Complete the displayed first-run transaction, choose the explicit engine-start verification path, then open a new ordinary login shell. Record `command -v docker`, `docker context show`, `docker context inspect morbstack`, `docker version`, `docker compose version`, and `docker buildx version`. | `docker` resolves to the Morbstack-owned installation, the clean account selects `morbstack`, and client/server, Compose, and Buildx all succeed with no Docker environment override. |
| CP-03 | Direct socket consumers | With the same unset environment, record that `~/.docker/run/docker.sock` exists after the engine is ready, then run a stock client through both its normal configuration and `unix://$HOME/.docker/run/docker.sock`. | Both paths reach the same ready Engine without exporting `DOCKER_HOST` or manually creating a context/socket. |
| CP-04 | Core Docker, Compose, and Buildx | Run a pulled `alpine:3.20` container; run an immutable small Compose fixture through `up --wait` and `down --volumes`; build a one-file Dockerfile with `docker buildx build --load`, then run the resulting image. | Each workload reaches the candidate engine and completes its expected command/health result. Compose resources and the test image are removed afterward. |
| CP-05 | App-window independence | Quit the Morbstack application after setup. From a new normal shell, repeat a read-only Docker health command and one short container command without reopening the app or changing environment. | The documented selected service/runtime path keeps Docker usable while no Morbstack window is open. The evidence records the selected background-service setting rather than assuming a hidden default. |
| CP-06 | Testcontainers discovery | Run the locked Java, Go, Node, and Python Testcontainers probes named by [`compat.md`](compat.md), using their normal default Docker discovery. Each probe must start a container, use a dynamically published port or observable container result, and clean up. | All four probes discover the engine from the standard context/socket path; none receives a Docker host override, patched library, or Morbstack-specific setup. |
| CP-07 | Dev Containers discovery | Run a version-pinned Dev Containers CLI fixture and the corresponding VS Code Dev Containers extension fixture from a clean editor profile. Exercise `up`, an in-container command, and cleanup with normal Docker discovery. | Both the CLI and editor workflow create and use the development container without an exported Docker variable, a hand-created context, or a running app window. |

## Fixture and failure rules

The release evidence for CP-04, CP-06, and CP-07 must name immutable fixture
revisions and dependency lockfiles before the run begins. Fixtures must use
public upstream images, generate unique project/container names, assert a real
container result, and remove only resources they created. They may not mount a
person's home directory, credentials, Docker socket into a workload unless that
specific behavior is the subject of the probe, or modify a pre-existing Docker
context.

When a row fails, retain its redacted command output and classify the failure as
payload, consent/install, socket/context discovery, Engine behavior, client
compatibility, or fixture defect. Fix or explicitly narrow the public contract;
do not add an environment-variable workaround and call the row passed.

## Evidence promotion

After a complete passing run, add a dated evidence record that links the
immutable release candidate and all seven result logs. Until then, public
documentation must continue to say **implemented pending clean-profile
verification**. A later candidate, host macOS major release, client-plugin
update, or change to socket/context installation requires a new run.
