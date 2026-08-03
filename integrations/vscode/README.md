# Morbstack for VS Code

Manage containers, images, volumes and Kubernetes on the [Morbstack](https://github.com/alliecatowo/morbstack)
engine without leaving the editor.

Morbstack runs an unmodified upstream `dockerd` inside a lightweight Linux VM and
exposes the standard Docker Engine API on a Mac-side unix socket at
`~/.morbstack/run/docker.sock`. This extension is a client of that socket. It
adds nothing to the API and requires no Morbstack-specific protocol.

## What it does

**Containers view.** Every container, grouped by `com.docker.compose.project`
label so a Compose stack reads as one unit. Expand a container to see its
published ports; click a port to open `http://localhost:<port>`. Right-click for
start, stop, restart, remove, logs, shell and inspect. Project rows can start or
stop every container in the stack at once.

**Images and Volumes views.** Listing, size, inspect, remove.

**Kubernetes view.** Cluster phase, node and pod readiness, and the API server
port, read from `morb k8s status --json`. Read-only: enabling a cluster is a
heavyweight action that belongs in the app or the CLI.

**Logs.** `View Logs` follows a container's output into its own output channel.
Containers created without a TTY are demultiplexed out of dockerd's stdcopy
framing, so stdout and stderr both arrive intact rather than as binary noise.

**Shell.** `Open Shell in Container` attaches a real interactive terminal using
the Engine API's exec endpoints over a hijacked stream — resize included. It
does **not** shell out to `docker exec`, so it works even with no `docker` CLI
installed and no `DOCKER_HOST` set. It prefers `bash` and falls back to `sh`.

**Status bar.** Engine state and running-container count. It turns into a
warning when `morb status` reports published ports that could not be bound on
the Mac — a case where `docker ps` misleadingly shows the port as published
(see `docs/parity.md`, finding 27). Click it for engine actions.

**Engine control.** Start and stop the VM via the `morb` CLI.

Updates are driven by the engine's own `/events` stream, so the tree reacts the
moment something changes, with a configurable poll as a fallback.

## Requirements

macOS with Morbstack installed and its engine reachable. The extension is
useful with the engine stopped — it says so clearly and offers to start it —
but everything except engine control needs a live socket.

The `morb` CLI is optional. Without it you lose engine start/stop, the
Kubernetes view, and the unbindable-port warning; container, image and volume
management all still work, because those go straight to the socket.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `morbstack.socketPath` | `~/.morbstack/run/docker.sock` | Engine API socket. `~` is expanded. |
| `morbstack.morbPath` | *(empty)* | Path to `morb`. Empty searches `PATH`, then `/Applications/Morbstack.app/Contents/MacOS/morb`, then the same under `~/Applications`. |
| `morbstack.showStoppedContainers` | `true` | Include stopped containers in the tree. |
| `morbstack.groupByComposeProject` | `true` | Group by Compose project label. |
| `morbstack.refreshInterval` | `5` | Fallback poll, in seconds. `0` relies on the event stream alone (a slow liveness probe still runs, otherwise a stopped engine would never be noticed). |
| `morbstack.shell` | *(empty)* | Shell command for `Open Shell in Container`. Empty tries `bash`, then `sh`. |
| `morbstack.statusBar` | `true` | Show the status bar item. |
| `morbstack.logTail` | `500` | Historical lines fetched when opening logs. |

If the configured socket file does not exist but `morb status --json` reports a
different one — the usual cause is a non-default `MORBSTACK_HOME` — the
extension adopts the reported path for the session. It does not rewrite your
setting.

## Dev Containers interop

The Microsoft [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
extension is separate from this one and talks to Docker on its own. It shells
out to the `docker` CLI, so it reaches Morbstack by whatever the CLI resolves.

**Both of these were verified on a live Morbstack engine** using
`@devcontainers/cli` 0.88.0 — the same core the extension wraps — bringing up
`mcr.microsoft.com/devcontainers/base:alpine` end to end, `postCreateCommand`
included:

1. **`DOCKER_HOST`.**

   ```sh
   export DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock
   ```

2. **A docker context.** With no `DOCKER_HOST` set at all:

   ```sh
   docker context create morbstack \
     --docker "host=unix://$HOME/.morbstack/run/docker.sock"
   docker context use morbstack
   ```

   `devcontainer up` succeeded identically, with no `DOCKER_HOST` anywhere.
   Prefer this route. Microsoft's own documentation states that without the
   Container Tools extension installed, "Dev Containers will use the current
   context" ([Develop on a remote Docker host](https://code.visualstudio.com/remote/advancedcontainers/develop-remote-host)).

### If you launch VS Code from the Dock

A GUI-launched macOS app inherits its environment from `launchd`, not from your
shell, so `export DOCKER_HOST=...` in `~/.zshrc` is not reliably enough. Three
options, most robust first:

- **Use a docker context** (above). It lives in `~/.docker/contexts`, not in an
  environment variable, so how VS Code was launched stops mattering.
- **Install the separate Container Tools extension**
  (`ms-azuretools.vscode-containers`) and set, in `settings.json`:
  `"containers.environment": {"DOCKER_HOST": "unix:///Users/you/.morbstack/run/docker.sock"}`.
  This is the documented mechanism for pointing Dev Containers at a non-default
  daemon from settings rather than the environment.
- **Launch with `code .` from a terminal** that already has `DOCKER_HOST`
  exported.

### The socket-path trap

Do **not** point `dev.containers.dockerSocketPath` at
`~/.morbstack/run/docker.sock`. That setting supplies the socket that the
`docker-outside-of-docker` feature bind-mounts *into* the container, and
bind-mount sources are resolved by dockerd **inside the guest VM**, not on your
Mac. Verified live:

```
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock docker:cli \
      docker version --format '{{.Server.Version}}'
29.7.1                                                    # works

$ docker run --rm -v /Users/you/.morbstack/run/docker.sock:/var/run/docker.sock alpine
docker: Error response from daemon: error while creating mount source path
'/Users/you/.morbstack/run/docker.sock': mkdir ...: operation not supported
```

So the default `/var/run/docker.sock` is the correct value on Morbstack and
`docker-outside-of-docker` works with it unchanged — the guest's dockerd socket
is exactly where the feature expects to find it. The Mac-side path fails loudly
rather than silently, which is the good failure mode, but only if you never set
it.

The `docker-in-docker` feature is unaffected either way: it starts its own
nested `dockerd` inside the container and does not bind-mount a host socket at
all.

### Known gaps

- The guest now implements `host.docker.internal` and
  `gateway.docker.internal` through split DNS, but this Dev Containers path has
  not yet been rerun against a fresh VM. Treat a `devcontainer.json` that uses
  those names as needing verification rather than relying on the historical
  `docs/parity.md` findings 18, 19 and 22.
- Dev Containers detects "Docker is not running" by pattern-matching the
  `docker version` error string, and on macOS may respond by trying to launch
  Docker Desktop. If you see a confusing Docker-Desktop-flavoured error, check
  `docker version` directly against the Morbstack socket before believing it.
  This is reported behaviour from the extension's issue tracker rather than
  documented behaviour, and it was not reproduced here.

### What was and was not tested

Verified live on this machine: `devcontainer up` via `DOCKER_HOST`,
`devcontainer up` via a `docker context`, and both socket bind-mount cases
above. Not tested: the Dev Containers **VS Code extension** driving these paths
through its own UI. The CLI is the reference implementation the extension
wraps, so the daemon-facing behaviour is the same, but the extension's
environment plumbing and error handling are its own and were not exercised.

## Building from source

```sh
cd integrations/vscode
npm install
npm run compile
npx vsce package --no-dependencies
```

That produces `morbstack-<version>.vsix`. Install it with:

```sh
code --install-extension morbstack-0.1.0.vsix
```

or from the Extensions view: **…** → **Install from VSIX…**

The extension has no runtime dependencies. It speaks HTTP over the unix socket
using Node's built-in `http` module, which is why `--no-dependencies` is safe
and the package stays small and auditable.

### Testing against a live engine

`src/api.ts`, `src/demux.ts`, `src/engine.ts` and `src/trees.ts` do not need the
VS Code extension host to run — `api.ts` and `demux.ts` import nothing from
`vscode` at all, and the rest can be driven with a stubbed `vscode` module. That
is how the client was exercised against a real engine (ping, version, list,
inspect, lifecycle, stdcopy log demux, interactive exec over the hijacked
stream, `/events`, and both error paths) without launching an Extension
Development Host.

### Verification status

Honest accounting of what has and has not been exercised:

- **Verified against a live Morbstack engine** (29.7.1, API 1.55): `/_ping`,
  `/version`, container/image/volume listing and inspection,
  start/stop/restart, Compose-label grouping, published-port deduplication
  across IPv4 and IPv6, log streaming with stdcopy demultiplexing, an
  interactive `exec` shell over the hijacked upgrade stream including resize
  and exit-code reporting, the `/events` stream, socket rediscovery from
  `morb status --json`, and the missing-socket and HTTP 404 error paths.
- **Verified with a stubbed `vscode` module**: every tree provider's node
  shapes, labels, descriptions, icons and context values, in both the
  engine-up and engine-down states, with each grouping setting toggled.
- **Verified**: `tsc` compiles clean under `strict`; `vsce package` produces a
  16-file, 46 KB VSIX; that VSIX installs without error into a scratch
  extensions directory.
- **Not verified**: the extension has not been run inside a VS Code window.
  Nothing in the sidebar, status bar, context menus or terminal integration has
  been seen rendered. Menu `when` clauses, view registration and the welcome
  view are only exercised by VS Code at runtime and could be wrong in ways
  compilation cannot catch. Treat the UI layer as unproven until someone opens
  it.

## Licence

Apache-2.0. See `LICENSE`.
