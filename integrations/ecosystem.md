# Ecosystem discovery: how tools find (or fail to find) Morbstack

Status: one-time audit, tested against the running engine on git HEAD
(`ba9afc6`) via `DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock`,
server version 29.7.1 / API 1.55 (see `docs/parity.md`, the source audit
this document extends specifically into ecosystem-tool territory:
`docs/parity.md` #17-#23 already established the socket-discovery and
`docker context` baseline; this document goes deeper, tool by tool, and
adds live tests this pass ran that `docs/parity.md` didn't).

Every claim below is marked **VERIFIED** (a real command was run against
the real engine in this session, output shown or described) or
**DOCUMENTED** (read from the tool's own source or official docs, not run
here — usually because the tool, a runtime it needs, or Go itself wasn't
installed in this environment). Nothing below is asserted from memory
alone without one of those two tags.

## The one root cause

Morbstack's Engine API lives at `~/.morbstack/run/docker.sock`. That is
not a path any Docker tool guesses by default:

- It is not `/var/run/docker.sock` (the traditional Linux/Docker Desktop
  path).
- It is not `~/.docker/run/docker.sock` (Docker Desktop's rootless-socket
  path) or `~/.docker/desktop/docker.sock` — and on a machine that also
  has (or once had) Docker Desktop installed, as this one does, those
  paths **exist** but point at Docker Desktop, not Morbstack. A tool
  that falls through to them doesn't error — it silently connects to the
  wrong daemon (see the Testcontainers section below for a live
  reproduction of exactly this).
- There is no Morbstack-registered `docker context`. Morbstack creates
  nothing in `~/.docker/contexts` on its own today; a context only
  exists if the user runs `docker context create` by hand.

Every tool in this document either (a) reads `DOCKER_HOST`, (b) reads a
`docker context`, (c) reads both, or (d) reads neither and hard-codes a
guess list of conventional paths. Which bucket a tool falls into is the
entire story of whether it finds Morbstack zero-config, config-once (env
var or context), or not at all.

## Summary table

| Tool | Works today | Minimum config | Zero-config blocker |
|---|---|---|---|
| `docker` CLI / `docker context` | **Works** (VERIFIED) | `docker context create morbstack --docker "host=unix://$HOME/.morbstack/run/docker.sock"` once, or `DOCKER_HOST` per-shell | No context is auto-registered on install/first-run |
| `docker compose` (bundled plugin) | **Works** (VERIFIED) | Plugin installed into a `cli-plugins` dir on `PATH` for the active `DOCKER_CONFIG`; inherits whatever `DOCKER_HOST`/context the `docker` CLI resolves | Plugin isn't auto-installed into `~/.docker/cli-plugins/` yet (fetched to `dist/host-bin/docker-compose` only) |
| `docker buildx` (bundled plugin) | **Works** (VERIFIED) | Same as Compose — plugin binary now exists at `dist/host-bin/docker-buildx` (fetched by `scripts/fetch-guest-assets.sh`, landed already) | Same as Compose: not auto-installed into `~/.docker/cli-plugins/` yet |
| Testcontainers — Node | **Works with one env var** (VERIFIED) | `DOCKER_HOST` + `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` | Does not read `docker context` at all; without `DOCKER_HOST` it silently falls through to a stale Docker Desktop socket if one exists (see below) |
| Testcontainers — Python | **Works, context-aware** (VERIFIED) | `DOCKER_HOST` (or a `docker context`) + `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` | Ryuk/socket-mount override still required; everything else is zero-config once a context exists |
| Testcontainers — Java/Go | Not tested here (no JDK/Go installed) | Same env vars as Node/Python per the shared testcontainers spec (DOCUMENTED) | Same shape of gap expected; unverified in this session |
| `docker-py` (`docker.from_env()`) | **Works, context-aware** (VERIFIED) | `DOCKER_HOST`, or nothing if a `docker context` is current (installed version 7.2.0) | None once a context exists — this is the one client library that Just Works with only a context |
| Docker Go SDK (`client.FromEnv`) | Not tested here (no Go installed) | `DOCKER_HOST` (DOCUMENTED — the SDK does not read contexts; only the `docker` CLI does) | Never reads contexts; always needs `DOCKER_HOST` |
| Tilt | Not tested here (not installed) | `DOCKER_HOST` env var (DOCUMENTED) | Does not read `DOCKER_CONTEXT`/contexts (open feature request, tilt-dev/tilt#4769) |
| Skaffold | Not tested here (not installed) | `DOCKER_HOST` env var, expected via its Go docker-client dependency (DOCUMENTED, lower confidence) | Local-cluster heuristics are k8s-context-driven, not `docker context`-driven; no evidence it reads `docker context` |
| `act` (nektos/act) | Not tested here (not installed) | `DOCKER_HOST` env var (DOCUMENTED); `--container-daemon-socket` flag exists but has open reliability reports | Doesn't read contexts; actions that mount `/var/run/docker.sock` need it remapped to Morbstack's socket |
| Dagger | Not tested here (not installed) | Likely zero-config once a context exists — its default provisioner shells out to the real `docker` binary (DOCUMENTED); `_EXPERIMENTAL_DAGGER_RUNNER_HOST` overrides entirely | Depends on shelling out to `docker` actually inheriting context/env correctly — unverified here |
| GitLab Runner (docker executor) | Not tested here (not installed) | `host = "unix://..."` under `[runners.docker]` in `config.toml` (DOCUMENTED) | Config-file key, not context-aware; DinD/socket-bind jobs hit the same in-guest-vs-Mac-path issue as Testcontainers |

## `docker context` — the canonical mechanism

**VERIFIED.** Ran in an isolated scratch `DOCKER_CONFIG` (never touched
the user's real `~/.docker`):

```
$ docker context create morbstack --docker "host=unix://$HOME/.morbstack/run/docker.sock"
morbstack
Successfully created context "morbstack"

$ docker context use morbstack
morbstack
Current context is now "morbstack"

$ docker ps          # no DOCKER_HOST set anywhere
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES

$ docker version --format '{{.Server.Version}}'
29.7.1
```

`docker context inspect morbstack` shows the endpoint exactly as
expected: `"Host": "unix:///Users/allie/.morbstack/run/docker.sock"`.

**Precedence, verified live:** with `morbstack` set as the current
context, setting `DOCKER_HOST=unix:///nonexistent.sock` in the
environment broke the connection (`Cannot connect to the Docker daemon
at unix:///nonexistent.sock`) — i.e. **`DOCKER_HOST` env var wins over
the active context**, which in turn wins over the built-in `default`
context. This is standard `docker` CLI behavior, not anything
Morbstack-specific, and it matters because several tools below only ever
set/read `DOCKER_HOST` and are completely blind to context state.

**Which tools respect contexts vs. only `DOCKER_HOST`,** established in
this pass:

- Respects contexts: `docker` CLI itself, `docker compose` (any CLI
  plugin invoked as `docker <subcommand>` inherits the CLI's own
  resolution — VERIFIED), `docker buildx` (same reasoning — VERIFIED),
  `docker-py`'s `docker.from_env()` (VERIFIED, see below), and by
  extension Testcontainers **Python**, which calls `docker.from_env()`
  internally (VERIFIED, see below).
- Does **not** respect contexts, `DOCKER_HOST`-only: Testcontainers
  **Node** (VERIFIED — has its own strategy list that never looks at
  `~/.docker/contexts`), the Docker Go SDK's `client.FromEnv`
  (DOCUMENTED — context resolution lives in `docker/cli`, not in
  `docker/docker/client`, and the Go SDK imports the latter only), Tilt
  (DOCUMENTED, open feature request), `act` and GitLab Runner's docker
  executor (DOCUMENTED, config-key/env-var only).

**Coordination note:** another agent in this session is adding a
`morbstack` docker context automatically and shipping the `buildx` CLI
plugin. The exact invocation above is what that work should produce (or
run on the user's behalf) — it already works by hand today, verified in
this pass. What's still open, and what the in-flight work presumably
closes: (1) nothing runs this for the user today — `morb doctor`
currently only checks whether `~/.docker/contexts` exists at all
(`mac/Sources/MorbstackKit/Doctor.swift:281-290`), it does not create or
offer to create the `morbstack` context itself; (2) the `docker-buildx`
plugin binary already exists at `dist/host-bin/docker-buildx` (fetched
by `scripts/fetch-guest-assets.sh`, confirmed present and dated this
session) and **works** when manually placed in `cli-plugins/` — VERIFIED
below — but nothing installs it into `~/.docker/cli-plugins/`
automatically, same gap as Compose. Every recommendation in this
document that says "once a context exists" is written to be correct
either way — whether the user runs the command by hand per the block
above, or the in-flight work makes it automatic.

## Testcontainers (all languages)

This is the highest-value entry in the whole document, and the one with
the subtlest failure mode.

### Discovery algorithm (read from source, `testcontainers` npm package
v12.0.4 and `testcontainers` PyPI package, both installed fresh this
session)

Node tries strategies **in this fixed order**, first one whose target
responds to `docker info` wins:

1. `TestcontainersHostStrategy` — only fires if `tc.host` is set in
   `~/.testcontainers.properties`.
2. `ConfigurationStrategy` — reads `DOCKER_HOST` (env, or `docker.host`
   in the properties file), plus `DOCKER_TLS_VERIFY`/`DOCKER_CERT_PATH`
   (env, or `docker.tls.verify`/`docker.cert.path` in the properties
   file — irrelevant to Morbstack, which has no TLS).
3. `UnixSocketStrategy` — hardcoded `/var/run/docker.sock` only.
4. `RootlessUnixSocketStrategy` — tries, in order: `$XDG_RUNTIME_DIR/docker.sock`,
   `~/.docker/run/docker.sock`, `~/.docker/desktop/docker.sock`,
   `/run/user/$UID/docker.sock`.
5. `NpipeSocketStrategy` — Windows only.

None of these steps ever consult `~/.docker/contexts`. Python's
discovery is functionally identical but wraps `docker-py`'s own
`from_env()`/socket-guess logic, which is what gives Python its
context-awareness as a side effect (see below) — Node has no such
dependency and is genuinely blind to contexts.

### The subtle bug: `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`

**VERIFIED, reproduced end-to-end in both Node and Python.** Once
Testcontainers picks a Docker host (say, `DOCKER_HOST` pointing at
Morbstack's Mac-side socket), it separately computes a *second* path:
the one it bind-mounts as `/var/run/docker.sock` (or whatever the target
container expects) into Ryuk (the reaper that cleans up orphaned test
containers) and into any DinD-style helper container. By default that
computed path is **the same Mac-side path as `DOCKER_HOST`** — because
the library's logic is "use the URI's path unless the daemon reports
`OperatingSystem: Docker Desktop`" (Morbstack's guest reports `Alpine
Linux v3.24`, not `Docker Desktop`, so this special case doesn't trigger
for Morbstack). That Mac-side path does not exist inside the guest VM's
filesystem, where the bind mount actually gets created by the guest's
dockerd. Reproduced directly, Node:

```
$ DOCKER_HOST=unix:///Users/allie/.morbstack/run/docker.sock node test1.js
...
FAILED: Error: (HTTP code 500) server error - error while creating mount
source path '/Users/allie/.morbstack/run/docker.sock':
mkdir /Users/allie/.morbstack/run/docker.sock: operation not supported
```

and the identical failure, byte-for-byte, in Python
(`testcontainers-python`, same `DockerContainer(...).start()` call).
Independently confirmed with a raw `docker run` (no Testcontainers
involved) bind-mounting the Mac-side path — same
`mkdir ... operation not supported` error — versus the in-guest path
`/var/run/docker.sock`, which works (also matches `docs/parity.md` #21,
which bind-mounted `/var/run/docker.sock` successfully for a DinD test).

The fix is one environment variable, and it is the single most
important line in this document:

```
TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
```

This is **not** Morbstack's own socket path — it is the path Morbstack's
guest dockerd listens on *inside the Linux VM*, which is where the bind
mount actually gets created. With this set, Ryuk starts, connects, and
runs correctly — VERIFIED end-to-end in both Node and Python:

```
$ TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock node test1.js
Started: ad0c633fef29...
Exec output: hello-from-testcontainers
Stopped OK
```

Ryuk itself then self-terminated correctly ~10s after the process
exited (its default `reconnection_timeout`), leaving no orphaned
container — confirmed by checking `docker ps -a` after each run.

### Does Ryuk work at all here? Is `TESTCONTAINERS_RYUK_DISABLED` needed?

**VERIFIED: Ryuk works correctly, and `TESTCONTAINERS_RYUK_DISABLED` is
not needed** — it's a workaround for people who don't want to set the
one socket-override variable above, and using it means orphaned
containers from crashed test runs never get cleaned up. Don't recommend
it as the fix; recommend the socket override instead.

### The dangerous default: silently connecting to the wrong daemon

**VERIFIED, and worth flagging loudly.** This machine has a real Docker
Desktop install alongside Morbstack (`docs/parity.md` already notes
`~/.docker/run/docker.sock` is "a stale leftover from a real Docker
Desktop install"). With the `morbstack` docker context set as current
but **no `DOCKER_HOST` env var** — i.e., exactly the state a user is in
if they followed "just create a context" advice without also knowing
Testcontainers ignores contexts — Testcontainers Node did not fail. It
silently connected to something else:

```
$ DEBUG=testcontainers* node -e "... getContainerRuntimeClient() ..."
...
"operatingSystem": "Docker Desktop",
"serverVersion": "27.4.0",
...
CONNECTED via localhost 27.4.0
```

That's Docker Desktop, not Morbstack (Morbstack reports server 29.7.1
and `Alpine Linux v3.24`). `RootlessUnixSocketStrategy` found
`~/.docker/run/docker.sock` and happily used it. No error, no warning —
tests would run, containers would start, and they'd be running against
the wrong engine entirely, with zero indication anything was wrong. For
someone who doesn't also have a stray Docker Desktop socket lying
around, the outcome is at least an honest connection failure; for
someone who does (a very plausible state during a side-by-side
Morbstack/Desktop trial, which is an explicit scenario the project
already accommodates per `docs/compat.md`), it's silent wrong-daemon
execution. **Always set `DOCKER_HOST` explicitly for Testcontainers; do
not rely on a context alone.**

Testcontainers **Python**, run through the identical scenario (context
current, no `DOCKER_HOST`), connected correctly to Morbstack
(`29.7.1`/`linux`) — because `testcontainers-python`'s `DockerClient`
calls `docker.from_env()` internally, inheriting `docker-py`'s
context-awareness. This is a genuine, verified cross-language
difference: Python Testcontainers is context-safe, Node Testcontainers
is not.

### `TESTCONTAINERS_HOST_OVERRIDE` and `Testcontainers.exposeHostPorts()`

**VERIFIED — this works today, and it does not depend on
`host.docker.internal` at all**, which is worth calling out given
`docs/parity.md` #18/#19 document that hostname as completely absent.
`exposeHostPorts()` doesn't use DNS-based host resolution; it spins up a
`testcontainers/sshd` helper container, publishes its port 22 the normal
way (which already works on Morbstack per `docs/parity.md` #3/#27), and
opens a reverse SSH tunnel from the Node/Python process on the Mac back
through that published port. Other containers reach the exposed host
port via the `host.testcontainers.internal` alias, which Testcontainers
manages itself — it is unrelated to `host.docker.internal`. Reproduced
end-to-end:

```js
await TestContainers.exposeHostPorts(hostPort); // hostPort: a plain
                                                  // http.Server on the Mac
// from inside a fresh alpine container:
// wget -qO- http://host.testcontainers.internal:$hostPort
// -> "hello-from-mac-host"
```

Output: `wget exit: 0 output: hello-from-mac-host`. No extra
configuration beyond the `DOCKER_HOST`/socket-override pair above was
needed for this to work.

`TESTCONTAINERS_HOST_OVERRIDE` (used by `resolveHost()` when
`allowUserOverrides` is true) is the escape hatch for the reverse case —
forcing what hostname *other containers* use to reach the Testcontainers
process itself when the automatic `localhost`-based resolution isn't
correct for a given topology. Not needed in the default Morbstack setup
tested here; not exercised in this session (DOCUMENTED from source
only).

### `~/.testcontainers.properties`

Confirmed by reading Node's `strategies/utils/config.js`: only
`tc.host`, `docker.host`, `docker.tls.verify`, and `docker.cert.path`
are read from this file in the Node client. `ryuk.disabled` and
`ryuk.container.privileged` are **env-var only in Node**
(`TESTCONTAINERS_RYUK_DISABLED`, `TESTCONTAINERS_RYUK_PRIVILEGED`), not
readable from the properties file in this client. `docker.client.strategy`
is a Java-Testcontainers-specific key (historically used to pick between
several JVM-only client provider strategies); it does not exist as a
concept in the Node or Python clients at all — don't tell a Node/Python
user to set it, it will simply be ignored. Python's config module
(`testcontainers/core/config.py`) supports the equivalent set through
both env vars and the same properties file, confirmed by reading source;
not independently re-verified property-file parsing live (env vars were
used for the live Python test above).

### Java and Go Testcontainers

Not tested in this session — no JDK and no Go toolchain available in
this environment. DOCUMENTED only, based on the shared cross-language
Testcontainers spec (the env var names above are standardized across all
official clients) and Node/Python's confirmed behavior: expect the same
socket-override requirement, and expect Go's client — like Node's — to
have no special context-reading behavior (it doesn't wrap the Docker CLI
or `docker-py`), so treat Go Testcontainers like Node for planning
purposes until someone verifies it on a machine with Go installed.

## `docker-py`

**VERIFIED.** Installed fresh this session: `pip install docker` ->
`docker` 7.2.0. Its `DockerClient.from_env()` signature documents the
order explicitly and it matches what was observed:

```python
def from_env(cls, **kwargs):
    ...
    use_context = kwargs.pop('use_context', True)   # default True
    params = kwargs_from_env(**kwargs)                # reads DOCKER_HOST etc.
    if use_context and 'base_url' not in params:
        for k, v in ContextAPI.kwargs_from_context(...).items():
            params.setdefault(k, v)
```

i.e.: **`DOCKER_HOST` (or `DOCKER_TLS_VERIFY`/`DOCKER_CERT_PATH`) wins if
set; otherwise it falls back to the current `docker context`** (reading
the same `DOCKER_CONTEXT` env var / `~/.docker/config.json` /
`~/.docker/contexts/...` state the `docker` CLI itself uses) — this is a
relatively recent capability (the docstring frames it as "allows the
client to talk to Docker Desktop out of the box," clearly added to
mirror Desktop's own context-based setup). Verified both paths live:

```
# DOCKER_HOST set directly, no context involved
$ DOCKER_HOST=unix:///Users/allie/.morbstack/run/docker.sock python3 -c \
  "import docker; print(docker.from_env().version()['Version'])"
29.7.1

# no DOCKER_HOST, morbstack context current instead
$ DOCKER_CONFIG=.../scratch python3 -c \
  "import docker; print(docker.from_env().version()['Version'])"
29.7.1
```

Both connect correctly. **This is the one client library in this whole
document that needs nothing beyond a `docker context` — no extra env
vars, no socket-override caveat** (docker-py's own `from_env()` has no
Testcontainers-style dual-path-computation problem; it only ever talks
to the one host it resolved).

Caveat: this context-reading behavior is present in the version tested
(7.2.0, current on PyPI as of this session) but is a newer addition to
docker-py's history — code pinning an old `docker` package version
(roughly pre-7.x, exact cutoff not verified here) should not assume it
and should set `DOCKER_HOST` explicitly instead.

## Docker Go SDK (`github.com/docker/docker/client`)

**DOCUMENTED, not run** — no Go toolchain is installed in this
environment (`which go` found nothing). Based on the SDK's well-known
design: `client.NewClientWithOpts(client.FromEnv)` reads `DOCKER_HOST`,
`DOCKER_API_VERSION`, `DOCKER_CERT_PATH`, and `DOCKER_TLS_VERIFY`
directly from the process environment. It does **not** read `docker
context` — context resolution (parsing `~/.docker/contexts`,
`~/.docker/config.json`'s `currentContext`) is implemented in
`docker/cli`'s command package, one layer above the SDK that CLI wraps;
`docker/docker/client` has no dependency on it. Any Go program using
this SDK directly (not shelling out to the `docker` binary) needs
`DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock` set explicitly; a
`docker context` alone will not help it.

## Tilt

**DOCUMENTED, not run** — Tilt is not installed in this environment.
Per Tilt's own docs and issue tracker: `tilt doctor` reports "Docker
host and version" among its diagnostics. Tilt reads the standard Docker
env vars directly (`DOCKER_HOST`, `DOCKER_API_VERSION`,
`DOCKER_CERT_PATH`, `DOCKER_TLS_VERIFY`) — confirmed via Tilt's FAQ,
which shows it constructing `docker build` invocations with those
variables explicitly (its minikube-integration example: `Running Docker
command as: DOCKER_HOST=tcp://... DOCKER_CERT_PATH=... DOCKER_TLS_VERIFY=1
docker build ...`). Docker-context support is an **open, unresolved
feature request** (tilt-dev/tilt#4769, "support DOCKER_CONTEXT env
variable") as of this pass — so, like the Go SDK, Tilt needs
`DOCKER_HOST` set explicitly; a `morbstack` context alone will not be
picked up.

For the Kubernetes side: Morbstack ships k3s via `morb k8s enable`, with
a kubeconfig written to `~/.morbstack/kubeconfig` (confirmed present on
this machine, `mac/Sources/morb/main.swift` also shows a `k8s
kubeconfig --merge` subcommand that can merge it into
`~/.kube/config` and optionally switch `current-context`). Tilt reads
`KUBECONFIG`/the current kube-context the same way `kubectl` does, so
either merge Morbstack's kubeconfig in, or export
`KUBECONFIG=~/.morbstack/kubeconfig` before running `tilt up` — the
`morbstack-env.sh` helper below does the latter.

## Skaffold

**DOCUMENTED, not run** — Skaffold is not installed in this environment.
Public docs describe Skaffold's *cluster* selection as kube-context-name
heuristics (recognizing `minikube`, `docker-desktop`, `kind-*`,
`k3d-*` context names to decide whether to skip pushing to a registry),
with `minikube docker-env` handled automatically as a special case. For
non-minikube local clusters (which is what a k3s-via-`morb k8s enable`
cluster is), the docs explicitly tell the user to export the right
`DOCKER_HOST`/related vars into the shell Skaffold runs in themselves —
there is no documented `docker context`-aware path for Skaffold's local
Docker builder found in this pass. Treat it the same as the Go SDK/Tilt:
export `DOCKER_HOST` explicitly. For the k8s deploy side, same guidance
as Tilt — point `KUBECONFIG` at `~/.morbstack/kubeconfig` or merge it,
and use `--kube-context morbstack` (or whatever name the merge step
picks) if `~/.kube/config` has multiple contexts.

## `act` (nektos/act)

**DOCUMENTED, not run** — `act` is not installed in this environment.
Per its own docs (`nektosact.com/usage/custom_engine.html`) and source
(`cmd/root.go`), the primary supported mechanism is the `DOCKER_HOST`
environment variable:

```
DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock act
```

A `--container-daemon-socket` CLI flag also exists in the codebase, but
multiple open GitHub issues (nektos/act#2314, #2016) report it being
silently ignored or behaving inconsistently, with `DOCKER_HOST` reported
as the reliable path in the same threads — recommend `DOCKER_HOST`, not
the flag, until those are resolved upstream.

Separately: any workflow step that itself mounts
`/var/run/docker.sock:/var/run/docker.sock` (common in actions that
build/push images) hits the exact same in-guest-vs-Mac-path issue
documented in the Testcontainers section — the in-guest path
(`/var/run/docker.sock`) is what needs to be the bind-mount *source*,
not Morbstack's Mac-side socket path. `act` itself doesn't have an env
var for this the way Testcontainers does; it's a per-workflow-file
concern (the workflow author controls the bind-mount source in their own
YAML/action).

## Dagger

**DOCUMENTED, not run** — Dagger is not installed in this environment.
Per Dagger's own docs (`docs.dagger.io/reference/container-runtimes/`):
by default, `dagger` "attempt[s] to detect an available container
runtime on the host — no need for additional configuration," and when
using Docker specifically, the CLI "download[s] the engine image that
matches its own version, start[s] it in a container, then connect[s] to
it" — i.e. it shells out to the real `docker` binary, the same one a
user would run by hand. If that's accurate (not independently verified
in this pass), Dagger should inherit whatever `DOCKER_HOST`/`docker
context` state is active in the shell it's invoked from, the same as any
other `docker run` — meaning it may well be **zero-config once a
`morbstack` context exists**, unlike Tilt/Skaffold/the Go SDK/act. This
is the one tool in this document where the docs suggest a better outcome
than most of the others, but it's unverified — worth a follow-up test
once Dagger can be installed in a test environment.

`_EXPERIMENTAL_DAGGER_RUNNER_HOST` is the override for all of this — set
to `docker-container://<name>` or a raw address to point at a specific,
already-running engine container instead of letting Dagger provision its
own. Not needed for the default case; useful if pre-warming a
Dagger engine is ever worth doing against Morbstack.

## GitLab Runner (docker executor)

**DOCUMENTED, not run** — `gitlab-runner` is not installed in this
environment. Per GitLab's own docs, the `[runners.docker]` section of
`config.toml` supports a `host` key that points the executor at any
Engine-API-compatible socket/TCP endpoint (documented for Podman, applies
identically to any custom Docker host):

```toml
[[runners]]
  executor = "docker"
  [runners.docker]
    host = "unix:///Users/YOU/.morbstack/run/docker.sock"
    # ... image, volumes, etc.
```

This is a config-file key, not context-aware — same bucket as the Go SDK
and Tilt. For jobs that use Docker-in-Docker (`services: [docker:dind]`),
GitLab's docs require `privileged = true` on the executor and describe
the runner creating a per-job bridge network between the build container
and the `dind` service; any job that instead tries to bind-mount the
*runner's own* `/var/run/docker.sock` into a job container hits the same
in-guest-vs-Mac-path caveat as Testcontainers and `act` above — the
`host` key controls where the **runner** connects, not what path gets
bind-mounted inside jobs.

## Docker Compose

**VERIFIED — already works, this is the one already-solved case.** The
plugin binary is fetched by `scripts/fetch-guest-assets.sh` to
`dist/host-bin/docker-compose`; the user (today) has to copy or symlink
it into a `cli-plugins/` directory on the active `DOCKER_CONFIG` path
(conventionally `~/.docker/cli-plugins/docker-compose`) themselves.
Verified in an isolated scratch `DOCKER_CONFIG`, with the `morbstack`
context active and no `DOCKER_HOST` set:

```
$ cp dist/host-bin/docker-compose $DOCKER_CONFIG/cli-plugins/
$ docker compose version
Docker Compose version v5.3.1
$ docker compose ps
NAME      IMAGE     COMMAND   SERVICE   CREATED   STATUS    PORTS
```

Correctly picked up the current context with zero extra configuration —
exactly the "respects contexts" behavior documented above, since `docker
compose` is invoked through the `docker` CLI's own plugin-dispatch
mechanism. Full multi-service Compose stacks against Morbstack are
already proven end-to-end in `docs/parity.md` #5/#6/#7; this pass only
re-confirmed the plugin-discovery path specifically.

`docker buildx`, fetched the same way to `dist/host-bin/docker-buildx`,
behaves identically — VERIFIED this session:

```
$ cp dist/host-bin/docker-buildx $DOCKER_CONFIG/cli-plugins/
$ docker buildx version
github.com/docker/buildx v0.36.0 ...
$ docker buildx ls
NAME/NODE      DRIVER/ENDPOINT   STATUS    BUILDKIT   PLATFORMS
morbstack*     docker
 \_ morbstack   \_ morbstack     running   v0.32.0    linux/arm64
```

Both plugins need the same fix: install into `~/.docker/cli-plugins/`
automatically (or document the one-line copy step prominently), which is
exactly what `docs/parity.md` #13/#14 already recommend for buildx
specifically.

## What Morbstack should do, in priority order

1. **Auto-register a `docker context` on install/first daemon start,
   the same way Docker Desktop writes `desktop-linux`.** This is the
   single highest-leverage fix, because it's the one thing that makes
   `docker` CLI, Compose, buildx, and `docker-py`/Testcontainers-Python
   all work with **zero** user action. It does nothing for
   Tilt/Skaffold/the Go SDK/act/GitLab Runner, which need `DOCKER_HOST`
   regardless — but those tools are a smaller slice of the ecosystem
   than "anything that shells out to the `docker` CLI or uses
   `docker-py`." (Coordinated: this is exactly what the in-flight
   context-automation work in this session should deliver; the exact
   command it needs to run is verified above.)

2. **Auto-install `docker-compose` and `docker-buildx` into
   `~/.docker/cli-plugins/`** (or into whatever `cli-plugins` directory
   the active `DOCKER_CONFIG` resolves to). Both binaries already exist
   in `dist/host-bin/` and both were verified working in this pass —
   this is pure plumbing, not an engineering gap. (Also in-flight per
   this session's coordination note for buildx specifically; Compose has
   the identical gap and should land the same way.)

3. **Document `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`
   prominently**, ideally right next to wherever the project documents
   the `docker context create` command. This is the single most
   valuable line for anyone adopting Morbstack for CI/testing — the
   failure it prevents (HTTP 500 on Ryuk startup) is confusing and gives
   no hint that the fix is one env var, and the *silent-wrong-daemon*
   failure mode documented above (Node Testcontainers + stale Desktop
   socket + no `DOCKER_HOST`) is actively dangerous, not just
   inconvenient.

4. **Ship `morbstack-env.sh`** (this directory,
   `integrations/env/morbstack-env.sh`) somewhere discoverable —
   README, `morb doctor` output, or both — for the tools that will never
   read a `docker context` no matter what Morbstack does
   (Tilt/Skaffold/Go SDK/act). A context fixes the CLI-shaped tools;
   these need `DOCKER_HOST` in their shell, full stop.

5. **Have `morb doctor` flag the stale-Docker-Desktop-socket footgun
   explicitly** when both `~/.morbstack/run/docker.sock` and
   `~/.docker/run/docker.sock`/`~/.docker/desktop/docker.sock` exist —
   today `Doctor.swift` only checks whether `~/.docker/contexts` exists
   at all (line 281-290), not whether a *different*, real daemon's
   socket is sitting at one of the conventional auto-discovery paths
   that a `DOCKER_HOST`-less tool might silently prefer. This is a
   direct, verified consequence of finding #3 above (the Testcontainers
   Node wrong-daemon repro) — worth a dedicated `morb doctor` check
   distinct from the existing `credsStore` and `/tmp`-symlink checks.

## How to set your environment

For anything that reads `docker context` (the `docker` CLI itself,
Compose, buildx, `docker-py`, Testcontainers Python), this is the
one-time, durable fix:

```sh
docker context create morbstack --docker "host=unix://$HOME/.morbstack/run/docker.sock"
docker context use morbstack
```

For everything else — Testcontainers Node, the Go SDK, Tilt, Skaffold,
`act`, GitLab Runner's docker executor — export the env vars directly.
The helper script in this directory does exactly that, and only that (it
does not create or touch a `docker context` — use the command above for
that):

```sh
eval "$(/path/to/morbstack/integrations/env/morbstack-env.sh)"
```

which is equivalent to, and was verified in this session to produce:

```sh
export DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
export KUBECONFIG=$HOME/.morbstack/kubeconfig   # only if morb k8s enable has run
```

Run both — the `docker context` command once per machine, and `eval` the
script (or just export those three lines yourself) in any shell where
you're about to run Testcontainers, Tilt, Skaffold, `act`, or a Go
program using the Docker SDK directly.

## Roadmap note (out of scope here)

The following are real gaps but out of scope for this document (see
`docs/parity.md` for the full audit and priority list):
`host.docker.internal`/`gateway.docker.internal` DNS resolution inside
containers (absent entirely today; `docs/parity.md` priority #1), and
`--network host` only ever reaching the guest VM's network, not the
Mac's (matches Docker Desktop's own long-standing behavior, not a new
Morbstack gap). Neither blocks anything documented above — Testcontainers'
`exposeHostPorts()` in particular was verified in this pass to work
despite the `host.docker.internal` gap, since it doesn't depend on that
mechanism at all.
