# First run and removal

Status: L1 implementation. This document is intentionally about a Mac that
has never had Docker Desktop, Homebrew's `docker`, or a pre-existing
`~/.docker` directory. Morbstack presents a native, terminal-free consent
sheet on a normal app launch when setup is needed; it is suppressed for
fixtures, captures, and diagnostics. It is not a substitute for a
clean-machine release test; that test remains an L1 gate in
[`roadmap.md`](roadmap.md).

## What a packaged app carries

`mise run app` refuses to assemble a release bundle unless these
hash-verified host executables have been fetched first:

```text
Morbstack.app/Contents/Resources/host-bin/docker
Morbstack.app/Contents/Resources/host-bin/cli-plugins/docker-compose
Morbstack.app/Contents/Resources/host-bin/cli-plugins/docker-buildx
```

They are the pinned, unmodified upstream client and plugins described in
[`NOTICE`](../NOTICE) and `scripts/fetch-guest-assets.sh`; they are not
borrowed from Docker Desktop or discovered from the user's `PATH`. The app
bundle signs those nested executables before sealing the outer bundle, so they
remain launchable after a quarantined DMG is installed.

For a source checkout, fetch just this host toolchain with:

```sh
./scripts/fetch-guest-assets.sh --host-cli
```

## The consented setup transaction

`MorbCliInstallation` is the shared implementation for the app's first-run
sheet and the transparent CLI equivalent:

```sh
/Applications/Morbstack.app/Contents/MacOS/morb install-cli --print-plan
/Applications/Morbstack.app/Contents/MacOS/morb install-cli
```

The plan is shown before any write. On a clean, default-zsh Mac, consenting
does all of the following without administrator access:

1. Symlinks the bundled `docker` to `~/.morbstack/bin/docker`.
2. Symlinks `docker-compose` and `docker-buildx` to Docker's standard
   `~/.docker/cli-plugins/` directory (or `$DOCKER_CONFIG/cli-plugins` when
   the user deliberately set `DOCKER_CONFIG`).
3. Adds one uniquely marked, reversible line block to `~/.zprofile`, placing
   `~/.morbstack/bin` on the PATH of future login shells.
4. Registers the standard Docker context named `morbstack`. If Docker is on
   its ordinary `default` context, it becomes current; if the person already
   selected any named context, that selection remains untouched.

The setup starts no VM and does not alter Docker data, credentials,
`credHelpers`, `credsStore`, or another Docker context. A Homebrew or Docker
Desktop client already first on PATH remains first by default; the explicitly
consented `--make-default` option is required to put Morbstack's client ahead
of it. Unsupported shells and a temporary `MORBSTACK_HOME` override are never
silently written into a persistent profile.

The graphical first-run sheet invokes this same plan/transaction only after
showing the exact links, PATH effect, and Docker-context effect. Its native
`Form` provides `Not Now`, explicit `Set Up Docker CLI`, error/retry, and
completion states; it never enables `--make-default` behavior. The terminal
commands remain available for inspection and for automation.

After opening a new terminal, the clean-machine smoke checks are:

```sh
docker version
docker compose version
docker buildx version
docker context show   # morbstack on a clean Docker config
```

The release gate adds an actual `docker run`, BuildKit build, Compose stack,
and Testcontainers/IDE discovery test with Docker Desktop and Homebrew removed
from PATH. Merely proving these files exist is not evidence that those tools
work end to end.

## Safe removal

The inverse is explicit and inspectable:

```sh
morb uninstall-cli --print-plan
morb uninstall-cli
```

It removes only links that point into a Morbstack bundle/check-out, the exact
marked shell-profile block, and a `morbstack` Docker context only when that
context still points at Morbstack's own socket. A same-named context pointing
somewhere else, any non-Morbstack link, every image/volume, runtime data, and
the app bundle itself are preserved.

Deleting the app or `~/.morbstack/data` is broader and potentially destructive
(the latter owns Docker images and volumes). A product-level app removal flow
must present those targets and their data-loss consequence separately; it is
not smuggled into the CLI-toolchain cleanup command.
