# Switching from Docker Desktop, Colima, or OrbStack

What actually happens in the first ten minutes after you point `docker` at
Morbstack instead, and what to do about each thing that is different. Every
item here is a real behavior checked in source or run live — see
[`audit/ECOSYSTEM-MATRIX.md`](audit/ECOSYSTEM-MATRIX.md) Part 2 for the full
evidence and citations this page summarizes.

If you have containers, images, or volumes to bring over rather than just the
CLI, the **Migration** section in the app (or `morb migrate`, see
[`migrate.md`](migrate.md)) does that; this page is about the parts of
switching that migration doesn't cover.

## `credsStore: "desktop"` hangs every credential-needing `docker` command

**This is the one that looks like a hang, not an error.** If `~/.docker/config.json`
still has `credsStore: "desktop"` from your Docker Desktop install, every
`docker` command that needs a registry credential — `docker pull` of a
private image, `docker push`, sometimes `docker login` — calls
`docker-credential-desktop` to fetch it. Once Docker Desktop has stopped
running, that helper never answers, and the command never times out on its
own.

We do not fix this for you: writing another program's credential
configuration is exactly the thing Morbstack promises not to do, so we
detect and report it rather than edit it (`morb doctor`'s `docker-credentials`
check, `MorbstackKit/Doctor.swift`).

**What to do:** run `morb doctor` and look for a `docker-credentials` warning,
or fix it directly —

```sh
# Remove the credsStore line from ~/.docker/config.json, or:
DOCKER_CONFIG=/path/to/a/config/without/credsStore docker pull ...
```

If you use registries that need real authentication, switch to a credential
helper that doesn't depend on Docker Desktop still running (`docker-credential-osxkeychain`
is the common choice) before you remove the `desktop` one.

## Some file watchers go quiet, others don't

Live-edited files on a bind mount (`-v ./src:/app/src`) show correct content
immediately — this is a real mount, not a sync — but a hot-reload tool that
depends on filesystem *change events* rather than re-reading the file may not
notice the edit. Whether it does depends on which inotify event your watcher
reacts to; the full matrix, with the mechanism, is in
[`benchmarks.md`](benchmarks.md#live-share-watcher-conformance-matrix) — link
rather than repeat: chokidar/nodemon/Vite and Python's `watchdog` keep
working, Go's `fsnotify` (`air`, most Go live-reload tools) and Rust's
`notify-rs` (`cargo-watch`, `watchexec`) do not.

**What to do:** if your dev-server reload stops working after switching,
check the matrix before assuming your container is broken — the file is
correct, only the reload notification is missing. A process that polls
instead of watching, or one you restart manually after an edit, is
unaffected.

## Bind mounts outside `/Users`, `/Volumes`, `/private/tmp` are a hard failure

Docker Desktop shares more of your disk by default. Morbstack shares three
roots (`shared_paths` in `~/.morbstack/config.toml`), and a bind mount whose
host path isn't under one of them is refused outright with Docker's own
`invalid mount config for type "bind": ...` error — see
[`sharing.md`](sharing.md#engine-side-bind-validation) for exactly what is
checked and why. This mostly bites a `compose.yaml` that bind-mounts
something under `/opt`, `/srv`, or another path outside your home directory.

**What to do:** add the missing root to `shared_paths`, then **restart the
engine** — shares are attached when the VM boots, so editing the config file
alone changes nothing until you do:

```sh
# ~/.morbstack/config.toml
shared_paths = ["/Users", "/Volumes", "/private/tmp", "/opt/data"]
```

```sh
morb stop && morb start
```

## A `DOCKER_HOST` already in your shell profile silently wins

Docker's own precedence is `DOCKER_CONTEXT`, then `DOCKER_HOST`, then the
saved current context. If an old `export DOCKER_HOST=...` from a previous
setup (Colima, a manual socket forward, an old CI script you sourced) is
still in your shell profile, it beats the `morbstack` context every time —
`docker` will look like it's ignoring the context you just switched to,
because it is.

**What to do:** `morb context status` states which of the three is actually
in effect for your shell right now. If `DOCKER_HOST` is what's winning,
either remove it from your profile or override it for one shell:

```sh
DOCKER_CONTEXT=morbstack docker ps
```

## The login item starts the service, not the VM

Registering Morbstack's background service in Login Items (offered during
first-run setup, or `morb service enable`) starts a lightweight host process
at login — it does not start the VM, and it does not start any containers.
This is different from Docker Desktop, which starts its VM at login by
default.

Practically: a container you started with `--restart unless-stopped` **will
not come back on its own after a reboot**, because nothing brings the VM back
up until something asks it to (the VM boots on the first client connection,
whether that's opening the app, running a `docker` command, or `morb start`).
Restart policies do work correctly across an explicit `morb stop`/`morb
start` — it's specifically the reboot case that differs from Desktop's
always-on-at-login behavior.

**What to do:** if you rely on containers surviving a reboot unattended, open
the app or run `morb start` after logging in, or script that into your own
login sequence. There is no setting that reproduces Desktop's login-boots-VM
behavior today.

## See also

- [`audit/ECOSYSTEM-MATRIX.md`](audit/ECOSYSTEM-MATRIX.md) Part 2 — the full
  step-by-step comparison against OrbStack these items are drawn from, with
  file-line citations for every claim.
- [`migrate.md`](migrate.md) — bringing over images and volumes, not just the
  CLI.
- [`sharing.md`](sharing.md) — the complete file-sharing model.
- [`first-run.md`](first-run.md) — what the first-run setup sheet does and
  does not touch.
