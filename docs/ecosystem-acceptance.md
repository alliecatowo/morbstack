# Ecosystem acceptance harness

Status: **executed 2026-08-04** against the running dev daemon (server
29.7.1). Results, exact commands, and per-suite verdicts live in
[`audit/ECOSYSTEM-MATRIX.md`](audit/ECOSYSTEM-MATRIX.md): Node/Python/Go and
Java-1.21.x Testcontainers and the Dev Containers CLI are `runs-here`;
testcontainers-java ≤1.20.x fails against any engine-29 daemon (docker-java's
pinned `/v1.32` probe vs upstream `MinAPIVersion 1.40`) and silently fails
over to a stale Docker Desktop socket. This is still not clean-profile
CP-06 / CP-07 evidence.

[`scripts/ecosystem-acceptance.sh`](../scripts/ecosystem-acceptance.sh) makes
the configuration boundary explicit. It does not build, sign, launch, stop, or
delete a VM or daemon. Its caller supplies a short, dedicated, already-running
`MORBSTACK_HOME`; it creates only a temporary `DOCKER_CONFIG`, registers a
throwaway Docker context in that directory, verifies the candidate CLI reaches
that context, and removes the directory on exit. It never reads or writes
`~/.docker`.

This is intentionally different from the clean-profile release gate:
[`clean-profile-acceptance.md`](clean-profile-acceptance.md) CP-06 and CP-07
require normal discovery on a brand-new account with *no* Morbstack-specific
environment. The harness below is for finding Engine/client interoperability
defects safely while that release gate remains pending.

## Preconditions

One evidence owner holds the machine lane. They prepare the candidate and a
disposable engine first, then run a probe in the foreground. The minimum setup
is:

```sh
export MORBSTACK_HOME=/tmp/mb-ecosystem
export MORBSTACK_DOCKER_BIN=/Applications/Morbstack.app/Contents/Resources/host-bin/docker
```

`MORBSTACK_HOME` must already contain a ready socket at
`$MORBSTACK_HOME/run/docker.sock`; choose a short path because Darwin limits a
Unix socket pathname to 104 bytes. The harness rejects a missing socket and
does not try to start one.

Before claiming guest-side evidence, verify that the candidate actually carries
the current guest bytes: the required serialized loop is `mise run guest-image`
→ `mise run app` → launch the candidate. `mise run guest-image` alone changes
neither the bundled nor staged runtime.

Every language probe must be immutable before it runs: record its runtime
version, Testcontainers version, lockfile or equivalent dependency receipt,
image digests, complete stdout/stderr, the candidate bundle digest, and cleanup
output. Give all Docker resources the label exported by the harness as
`$MORBSTACK_ECOSYSTEM_LABEL`, and remove only resources carrying that label.

## Testcontainers matrix

The wrapper first proves a disposable Docker context points at Morbstack. It
then selects the discovery mechanism the client actually supports:

| Suite | Probe discovery | Additional required setting |
| --- | --- | --- |
| `testcontainers-node` | direct `DOCKER_HOST` | none |
| `testcontainers-python` | direct `DOCKER_HOST` | none |
| `testcontainers-java` | direct `DOCKER_HOST` | none |
| `testcontainers-go` | direct `DOCKER_HOST` | none |

`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` is deliberately **unset** by the
harness (since ECO-2, 2026-08-04). Ryuk and Docker-in-Docker-style helpers
bind-mount the Mac-side socket path the client discovered; the engine's
`DockerBindMountPreflight` rewrites that exact daemon-socket source to the
guest's `/var/run/docker.sock`, so the override is unnecessary — and setting
it here would hide a regression in the very path these suites exist to prove.
A probe that fails on Ryuk's socket mount is a failing probe, not something to
work around by disabling Ryuk or reintroducing the override
(`docs/design/ZERO-CONFIG-DISCOVERY.md` records the decision and the trust
grant it implies).

Run each pre-locked language probe through the corresponding suite. For example:

```sh
scripts/ecosystem-acceptance.sh testcontainers-node -- \
  node /absolute/path/to/locked-node-probe.mjs

scripts/ecosystem-acceptance.sh testcontainers-python -- \
  python3 /absolute/path/to/locked_python_probe.py

scripts/ecosystem-acceptance.sh testcontainers-java -- \
  /absolute/path/to/locked-java-probe/run.sh

scripts/ecosystem-acceptance.sh testcontainers-go -- \
  /absolute/path/to/locked-go-probe/run.sh
```

Each probe must start an `alpine:3.20` (or documented immutable equivalent)
container through its Testcontainers client, run a sentinel command in that
container, verify the sentinel result, and clean up. It must also verify that
Ryuk is enabled and that no helper/container labelled with the exported run ID
remains. A direct `docker run` is not a substitute: it does not exercise the
client's discovery, reaper, or socket-mount path.

Every Testcontainers client is deliberately tested with an explicit host even
though the harness made a valid context first: these libraries use Docker-client
discovery, not a Docker CLI context. In particular, Testcontainers Python
constructs docker-py's client from environment, so a context-only test would
fall back to a default socket and test the wrong contract. For Node this also
prevents the known wrong-daemon footgun where a stale Docker Desktop rootless
socket wins discovery. See
[`../integrations/ecosystem.md`](../integrations/ecosystem.md) for the evidence
and client-specific rationale.

## Dev Containers matrix

The Dev Containers CLI must use the isolated Docker context with no
`DOCKER_HOST`. The fixture is
[`../integrations/fixtures/devcontainer`](../integrations/fixtures/devcontainer):

```sh
scripts/ecosystem-acceptance.sh devcontainers-cli -- \
  devcontainer up \
    --workspace-folder "$PWD/integrations/fixtures/devcontainer" \
    --id-label "dev.morbstack.acceptance=devcontainers-cli-$(date +%s)"
```

Follow with an in-container sentinel and a foreground cleanup, using the same
workspace folder **and the same `--id-label`** — passing `--id-label` to `up`
replaces the CLI's default `devcontainer.local_folder` identity labels, so an
`exec` without it fails with `Error: Dev container not found.` (verified
against `@devcontainers/cli` 0.88.0):

```sh
scripts/ecosystem-acceptance.sh devcontainers-cli -- \
  devcontainer exec \
    --workspace-folder "$PWD/integrations/fixtures/devcontainer" \
    --id-label "dev.morbstack.acceptance=devcontainers-cli-<same stamp as up>" \
    sh -lc 'test "$(cat /tmp/morbstack-devcontainer-sentinel)" = ready'
```

`@devcontainers/cli` 0.88.0 has no `devcontainer down` subcommand. Teardown is
explicit, with the candidate CLI, scoped to the label you supplied:

```sh
scripts/ecosystem-acceptance.sh devcontainers-cli -- sh -c \
  '"$MORBSTACK_DOCKER_BIN" ps -aq \
     --filter "label=dev.morbstack.acceptance=devcontainers-cli-<stamp>" \
   | xargs "$MORBSTACK_DOCKER_BIN" rm -f'
```

Record the exact Dev Containers CLI version and fixture revision. If the CLI
does not remove every resource it created, remove only containers bearing the
printed label using the candidate Docker CLI, then treat that label-handling
difference as a fixture finding rather than broad-pruning the engine.

The separate VS Code Dev Containers extension needs a clean editor profile and
a real editor session. Start VS Code from a terminal that retains the temporary
`DOCKER_CONFIG`/`DOCKER_CONTEXT` for the session, open the same fixture, run
**Dev Containers: Reopen in Container**, execute the sentinel in its terminal,
then close and clean up. A Dock-launched editor does not inherit shell
environment; normal release evidence must therefore use its selected context or
the documented Container Tools setting. This UI workflow remains CP-07 until
recorded on a new account.

## Verdict vocabulary

Mark a completed row `runs-here` only when the recorded command used the
candidate's Docker CLI, printed the candidate server version, completed the
real third-party client workflow, and removed its labelled resources. Mark it
`accepted` only after the clean-profile CP-06/CP-07 matrix passes with no
Morbstack-specific environment or hand-created context.
