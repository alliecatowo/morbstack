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

   `devcontainer up` succeeded identically. Prefer this route: it survives a
   VS Code launched from the Dock, which does not inherit your shell
   environment the way one launched by `code .` from a terminal does.

### The socket-path trap

Do **not** point `dev.containers.dockerSocketPath` at
`~/.morbstack/run/docker.sock`. That setting is the socket path bind-mounted
*into* the container for the `docker-in-docker` and `docker-outside-of-docker`
features, and bind-mount sources are resolved by dockerd **inside the guest VM**,
not on your Mac. Verified live:

```
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock docker:cli \
      docker version --format '{{.Server.Version}}'
29.7.1                                                    # works

$ docker run --rm -v /Users/you/.morbstack/run/docker.sock:/var/run/docker.sock alpine
docker: Error response from daemon: error while creating mount source path
'/Users/you/.morbstack/run/docker.sock': mkdir ...: operation not supported
```

The default `/var/run/docker.sock` is correct on Morbstack and
docker-outside-of-docker works with it unchanged. The Mac-side path fails
loudly, which is the good failure mode, but only if you never set it.

### Known gap

Morbstack does not resolve `host.docker.internal` or `gateway.docker.internal`
inside containers today. A `devcontainer.json` that reaches the host by those
names will not work. See `docs/parity.md`, findings 18, 19 and 22.

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

## Licence

Apache-2.0. See `LICENSE`.
