# Zero-config discovery (ECO-1 / ECO-2)

Date: 2026-08-04. Status: **implemented and proven live** against server
29.7.1 (evidence in [`../audit/ECOSYSTEM-MATRIX.md`](../audit/ECOSYSTEM-MATRIX.md),
zero-config section).

The standing requirement, verbatim: *"someone who has no docker on their
system should just need to install morbstack... drop in replacement means
single path install too."*

The failure it fixes, from the first ecosystem acceptance run: unconfigured,
Morbstack was invisible. Testcontainers Node, Go, and Java never read `docker
context`, found no `DOCKER_HOST`, fell through to whatever socket existed, and
ran their suites green against Docker Desktop 27.4.0 — no error, no warning, a
user's tests passing against the wrong engine.

## The options, and what was decided

### 1. Own `/var/run/docker.sock` — rejected as an automatic step

The conventional path everything falls back to. It is also a root-owned system
location: creating even a symlink there requires administrator authority.
Morbstack's install pitch is *no privilege required*, and spending admin
rights silently in first-run would break that promise once and forever.

Decision: never automatic. `morb context status` prints the exact optional
command (`sudo ln -sf ~/.morbstack/run/docker.sock /var/run/docker.sock`) for
people who want it, clearly labelled as user-run and only if nothing else owns
the path (`MorbDockerContext.suggestedSymlinkCommand`). With the socket-mount
rewrite below, a client that discovers Morbstack through that link also gets a
working Ryuk.

### 2. Per-user conventional socket + selected context — the chosen path

`morb install-cli` (and the app's first-run sheet, which calls the same
`MorbCliInstallation.install`) performs, unprivileged and only after showing
its plan and getting consent:

- **`~/.docker/run/docker.sock` → `~/.morbstack/run/docker.sock`** — a
  user-owned symlink at the conventional per-user location Docker Desktop
  established, created **only when the path is free**
  (`MorbDockerContext.installDirectSocket`). This is the exact path the
  rootless/desktop discovery strategies of Testcontainers Node, Go, and Java
  all probe. A dangling link while the daemon is stopped is harmless: every
  client treats a non-connectable socket as absent.
- **A `morbstack` Docker context**, written in the Docker CLI's own on-disk
  format (`MorbDockerContext.create`), and **selected** — but only when the
  current context is Docker's ordinary default. An explicit context someone
  else chose (`desktop-linux`, a remote engine…) is never stomped
  (`docs/compat.md`). This is what makes the Docker CLI, Testcontainers
  Python (docker-py), and the Dev Containers CLI find Morbstack unaided.
- The `docker`/`docker-compose`/`docker-buildx` links and one managed PATH
  block, as before.

Why this fixes the fallback and not just the lookup: on the machine the
requirement describes — **no Docker at all** — both `/var/run/docker.sock`
and `~/.docker/run/docker.sock` are absent. After `morb install-cli`, the
per-user conventional socket exists and points at Morbstack, so even the
clients that read neither contexts nor `DOCKER_HOST` fall through *into
Morbstack* instead of into nothing (or into a stale competitor).

### 3. `DOCKER_HOST` in the shell profile — rejected

Most invasive, least honest option: it applies only to shells that sourced
the profile (not IDEs, not launchd-spawned processes), it shadows Docker
contexts for every tool including ones the user pointed elsewhere on purpose,
it breaks the "never stomp another engine" rule for anyone who also runs
Docker Desktop, and it leaves the silent-wrong-daemon hazard fully intact for
any process launched outside that shell. Not implemented; nothing writes
`DOCKER_HOST` anywhere.

## ECO-2: the Ryuk socket mount, and the trust decision

Even with discovery fixed, every Testcontainers language used to need
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`. Without it, the
client bind-mounts *the Mac-side socket path it discovered* into Ryuk; that
path does not exist inside the Linux guest (and a VirtioFS share can never
carry a live socket inode across), so `POST /containers/create` failed with a
500 in every language.

Fix, in the engine (`DockerBindMountPreflight` via `DockerProxy`): a bind
source that is **the daemon's own published socket** — matched by exact,
symlink-resolved path identity, never by pattern — is rewritten to
`/var/run/docker.sock`, the guest's spelling of the same resource. This
covers every discovery flavour: `DOCKER_HOST=unix://~/.morbstack/run/docker.sock`,
the `~/.docker/run/docker.sock` link, and a user-made `/var/run/docker.sock`
symlink (that one already passed through as the guest's socket).

**What this grants, stated plainly.** A container that mounts the Docker
socket has root-equivalent control of the engine: it can start privileged
containers, mount host shares, and reach every other container. This rewrite
does not create that grant — the user's own Testcontainers/compose
configuration asked for exactly that socket — it makes the grant *work*
instead of failing with an incomprehensible 500. It is the same behaviour
Docker Desktop implements for the same reason (its `dockerSocketProxied`
binds), and it is never inferred: only a bind whose resolved source is
byte-identical to this daemon's socket path is rewritten. A foreign engine's
socket (for example a live Docker Desktop `~/.docker/run/docker.sock`) is
never redirected to Morbstack — resolution would yield a different path, and
the ordinary share rules apply to it unchanged. If you disagree with
socket-mounting as a practice, the lever is the same as on any Docker engine:
don't mount the socket (e.g. `TESTCONTAINERS_RYUK_DISABLED`, though Ryuk is
recommended); Morbstack adds no new ambient grant.

Consequence: `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` is now unnecessary in
every language. `scripts/ecosystem-acceptance.sh` deliberately no longer sets
it, so a regression in this path fails the suite instead of hiding.

## Exactly what installation touches, and how it is reversed

`morb install-cli` / first-run, after consent (`morb install-cli --print-plan`
shows all of it beforehand; every item is also reported afterwards):

| Touched | Created | Reversed by `morb uninstall-cli` |
| --- | --- | --- |
| `~/.morbstack/bin/docker` (+ `docker-compose`, `docker-buildx` under the CLI-plugins dir) | symlinks into Morbstack.app | removed only when they are positively Morbstack's own links |
| One byte-stable PATH block in `~/.zprofile`/`~/.bash_profile` | appended | the exact block removed; hand-edited blocks preserved |
| `~/.docker/run/docker.sock` | symlink, **only if the path was free** | removed only when it still points at Morbstack's socket |
| `~/.docker/contexts/meta/<sha256>/meta.json` | the `morbstack` context | removed only when it points at Morbstack's socket |
| `~/.docker/config.json` `currentContext` | set to `morbstack` **only if current was `default`** | key removed (Docker's own spelling of "default") only if still `morbstack` |

Nothing else in `~/.docker` is read, rewritten, or reformatted;
`config.json` writes preserve every other key (`credsStore`, `credHelpers`,
`auths`), the file's mode, and any symlink identity (`MorbDockerContext`
writes the resolved target atomically). This matters concretely on machines
where `credsStore` points at Docker Desktop's helper — corrupting or dropping
that key can hang every `docker` command.

No step requires or requests administrator authority. The only privileged
integration (`/var/run/docker.sock`) is a printed suggestion the user runs
themselves.

## Coexistence with Docker Desktop

On a machine where Docker Desktop is installed and running (this dev machine:
Desktop 4.37.0, engine 27.4.0, live socket at `~/.docker/run/docker.sock`,
current context `desktop-linux`):

- The conventional socket is **occupied** → preserved, reported as such.
- `desktop-linux` is an explicit context → `morb context use` refuses without
  `--force`; installation registers `morbstack` but does not select it.
- Result: Docker Desktop keeps working exactly as before, and context-blind
  tools keep finding it. **Deferring is correct** — the engine the user
  explicitly configured stays in charge.
- The gap that remains is *silence*, and it is now surfaced twice: `morb
  install-cli` ends with an explicit `[!!] Morbstack is installed, but it is
  NOT what Docker tools on this machine will discover` block naming the
  owning context and the three ways out, and `morb doctor`'s
  `docker-discovery` check warns whenever a competing conventional socket
  would win over Morbstack. `morb context status` shows the full state on
  demand.

Uninstalling (or quitting) Docker Desktop frees both avenues; re-running
`morb install-cli` then claims them, and `morb uninstall-cli` hands them back
by removing only Morbstack-owned artifacts.

## Proof

See the zero-config section of
[`../audit/ECOSYSTEM-MATRIX.md`](../audit/ECOSYSTEM-MATRIX.md): with **no
Docker-related environment variables at all** and a home directory containing
only what `morb install-cli` creates, Testcontainers Node 12.1.0, Go v0.43.0,
Java 1.21.4, and Python 4.15.0 each ran a real Postgres round trip against
server **29.7.1** (Morbstack; Docker Desktop here is 27.4.0 — the version gap
is the daemon-identity check), with Ryuk enabled and working and no
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`. The engine-recorded Ryuk-style bind
after rewrite: `"/var/run/docker.sock:/var/run/docker.sock"`.
