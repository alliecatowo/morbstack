# JetBrains IDEs and Morbstack

**Verdict: no plugin is needed.** JetBrains' Docker integration connects to any Engine-API-compatible daemon by unix socket path, TCP socket, or SSH — it is not Docker-Desktop-specific. Morbstack exposes a stock Docker Engine API (server 29.7.1, API 1.55) on a unix socket at `~/.morbstack/run/docker.sock`, and that socket is enough. Point the IDE at it and the Services tool window, Compose run configurations, and exec-into-container all work the same as against any other Engine-API daemon. The only genuinely missing piece is zero-config discovery (see below), and that depends on work in progress elsewhere in this repo, not on JetBrains.

This document was produced by reading JetBrains' own documentation and testing the Engine API directly with the `docker` CLI. **No JetBrains IDE is installed on the machine this was written on**, so nothing below about in-IDE behavior (menus rendering, Services tree populating, exec actually opening a shell) has been verified by driving the actual UI. Anywhere a claim is not sourced to a doc URL, that is stated explicitly.

## Setup

1. Open **Settings/Preferences | Build, Execution, Deployment | Docker** (`Ctrl+Alt+S` / `Cmd+,`, then navigate there).
2. Click **+** to add a new Docker connection.
3. Choose **Unix socket** as the connection type (see "Which radio button" below for why not "Docker for Mac").
4. Set the socket path to:

   ```
   unix:///Users/<you>/.morbstack/run/docker.sock
   ```

   Substitute your actual macOS username. **Use the fully expanded absolute path, not `~`.** JetBrains' own docs give socket paths as fully-qualified (`unix:///var/run/docker.sock`, `unix:///run/user/1000/docker.sock`), and none of the examples found in JetBrains documentation or third-party guides (e.g. the Podman-with-JetBrains write-up cited below) use `~`. Treat tilde-expansion as unsupported unless you verify otherwise in your own IDE version — expand it yourself.
5. Click **Test Connection**. It should report the server version (29.7.1) and API version (1.55) — the same values `docker version` reports against this socket on this machine.
6. If you plan to build images from a Dockerfile inside the IDE, make sure the `docker buildx` CLI plugin is discoverable — JetBrains' own docs state buildx is required for Dockerfile-based builds (see citations). **Morbstack ships it**: buildx v0.36.0 (darwin-arm64, sha256-pinned against its signed release sidecar by `scripts/fetch-guest-assets.sh` step 8) is bundled at `Contents/Resources/host-bin/cli-plugins/docker-buildx`, and `morb install-cli-plugins` symlinks it into `~/.docker/cli-plugins/` alongside Compose. `docker buildx version` / `docker buildx ls` are VERIFIED against the Morbstack engine in [`../ecosystem.md`](../ecosystem.md). Nothing needs installing from Homebrew.

### Which radio button, and why not "Docker for Mac"

JetBrains' Docker connection dialog offers several presets: **Docker for Windows**, **Docker for Mac**, **Unix socket**, **TCP socket**, **SSH**, **WSL**, and **Minikube**. The docs describe **Docker for Mac** as "the recommended option when using Docker Desktop for macOS" and **Unix socket** as "the recommended option when using Docker Desktop for Linux" — i.e., these are Desktop-oriented presets, not a technical requirement. JetBrains' own documentation was not specific enough to confirm from text alone whether "Docker for Mac" hardcodes a socket path versus just pre-filling one; it was not possible to inspect the actual preset behavior without a running IDE. Given the ambiguity, use **Unix socket**, which every source (official docs and the Podman-on-JetBrains guide used as a corroborating precedent for connecting a non-Desktop engine) confirms accepts an arbitrary `unix://` path in the Engine API URL field — this is the option other non-Docker-Desktop engines (Colima, Rancher Desktop's dockerd, rootless Podman) use to connect, and it is the safer choice until "Docker for Mac" is confirmed not to force a different path.

## Feature matrix

| Feature | Status | Note |
|---|---|---|
| Basic connection test (`Test Connection`) | Works — verified via docs + CLI | Docs confirm the connection type accepts an arbitrary Engine API URL/socket path; independently confirmed the socket itself answers correctly (`docker version`, `docker info` against `unix:///Users/allie/.morbstack/run/docker.sock` return server 29.7.1 / API 1.55). Not verified inside an actual IDE window. |
| Services tool window (images, containers, volumes, networks, logs) | Documented to work over any Engine-API connection | JetBrains docs describe these as generic Engine API features, with no Docker Desktop-specific requirement called out. Not verified by running the IDE. |
| Exec/terminal into a running container | Documented to work over any Engine-API connection | Same basis as above — generic Engine API feature per docs. Not run in an actual IDE. |
| Docker Compose run configurations | Works, with one caveat | Docs describe Compose support as engine-agnostic. The guest now implements `host.docker.internal` and `gateway.docker.internal`; a Compose run using either alias still needs a fresh VM validation, so this is a Morbstack verification gap, not a JetBrains-specific limitation. |
| Building images from a Dockerfile (Dockerfile run configuration) | Requires `docker buildx` CLI plugin — Morbstack ships it | JetBrains docs state plainly that the Buildx plugin is needed for Dockerfile-based image builds with Docker Engine 19.03+. Morbstack bundles buildx v0.36.0 (sha256-pinned, `scripts/fetch-guest-assets.sh` step 8) and `morb install-cli-plugins` links it into `~/.docker/cli-plugins/`; `docker buildx ls` is VERIFIED against the engine in [`../ecosystem.md`](../ecosystem.md). Run that once and Dockerfile builds have what the IDE looks for. Not verified from inside an IDE window. |
| `DOCKER_HOST` env var picked up automatically | Not reliable — treat as unsupported | JetBrains' settings UI is a persisted, explicit configuration (socket path/URL typed into the dialog), not a live read of the shell environment. The one documented use of `DOCKER_HOST` is as a value you copy in manually for Minikube setups. A open JetBrains bug report (IDEA-267675) is titled "Since 2021.1, `DOCKER_HOST` environment variable cannot be overridden in Docker Compose," and user reports describe GoLand ignoring `DOCKER_HOST` outright with no env-var field in the settings UI. Conclusion: configure the socket path explicitly in Settings; do not rely on `DOCKER_HOST`. |
| `docker context` support | Not found in JetBrains documentation | No official JetBrains Docker documentation page found mentions `docker context` at all — not in the settings page, the feature overview page, or the troubleshooting page. Treat JetBrains as **not** reading `~/.docker/config.json` contexts. This means the other agent's in-flight `morbstack` docker-context work will not, by itself, make JetBrains zero-config — see below. |
| JetBrains Gateway / Dev Containers | Should work; local Docker CLI is required | The Dev Containers FAQ states the local Docker CLI is required "to collect the correct context and clone only the necessary files into the remote machine," for both local and SSH-remote Docker Engine cases. Nothing in the docs found ties Dev Containers to Docker Desktop specifically — it talks generically about "local Docker" and "remote Docker Engine." Not verified by running Gateway. |
| SSH connection type | Ultimate/paid editions only | Docs state SSH connections to a Docker daemon are supported only in Ultimate-tier editions (IntelliJ IDEA Ultimate etc.), not Community. Not relevant to the plain local-socket setup above, which works in Community. |
| Path mapping / bind mounts from host into containers | Should be transparent | JetBrains' path-mapping feature exists specifically for Docker Desktop's VM-in-the-middle model on macOS/Windows ("containers can only access files that exist inside" the VM). Morbstack also runs a Linux VM under the hood, so the same host↔VM mapping concern likely applies whenever the IDE tries to bind-mount a Mac path into a container — this was not tested and is flagged as a plausible friction point, not a confirmed one. |

## What would make this zero-config

Today you must manually type the absolute socket path into Settings. Two things could remove that step, neither of which JetBrains' docs confirm is supported today:

- **`docker context` support in JetBrains.** Not found anywhere in the official docs surveyed. Morbstack's side of this has since landed — `morb context create` / `morb context use`, and `morb install-cli` registering and selecting the `morbstack` context on a free machine ([`../../docs/design/ZERO-CONFIG-DISCOVERY.md`](../../docs/design/ZERO-CONFIG-DISCOVERY.md)) — and it is what makes the Docker CLI, Compose, the Dev Containers CLI and Testcontainers-Python zero-config. JetBrains is the one that does not read it. Do not build workflow around JetBrains following the context; that half is still speculative.
- **`DOCKER_HOST` auto-detection.** Also not reliably supported per the bug reports above — JetBrains reads it, at most, as a one-time copy-paste convenience for Minikube, not as a live/ambient setting.

Given both are absent, the realistic zero-config path is: ship a short doc (this one) with the exact socket path, and optionally have the Morbstack Mac app show the socket path in its UI for copy-paste (out of scope for this document — that would be a change under `mac/`, not `integrations/jetbrains/`).

## Citations

- [Docker connection settings | IntelliJ IDEA Documentation](https://www.jetbrains.com/help/idea/settings-docker.html) — connection type list (Docker for Windows/Mac, Unix socket, TCP socket, SSH, WSL, Minikube), Engine API URL field, Certificates folder = `DOCKER_CERT_PATH`, path-mapping table description, no mention of `docker context`.
- [Docker | IntelliJ IDEA Documentation](https://www.jetbrains.com/help/idea/docker.html) — Docker plugin bundled/enabled by default in Ultimate; Community requires marketplace install; Services tool window feature list; remote Docker Engine requires local Docker CLI and the Buildx plugin.
- [Docker troubleshooting | IntelliJ IDEA Documentation](https://www.jetbrains.com/help/idea/docker-troubleshooting.html) — no coverage of custom socket paths, `DOCKER_HOST`, or `docker context`; TCP-socket workaround for Unix-socket TLS errors on Ubuntu.
- [Docker | PhpStorm Documentation](https://www.jetbrains.com/help/phpstorm/docker.html) — "bundled and enabled in PhpStorm by default."
- [Docker | GoLand Documentation](https://www.jetbrains.com/help/go/docker.html) — "bundled and enabled in GoLand by default."
- [Docker | WebStorm Documentation](https://www.jetbrains.com/help/webstorm/docker.html) — "bundled and enabled in WebStorm by default."
- [Docker | RubyMine Documentation](https://www.jetbrains.com/help/ruby/docker.html) — "bundled and enabled in RubyMine by default."
- [Docker | JetBrains Rider Documentation](https://www.jetbrains.com/help/rider/docker.html) — "bundled and enabled in JetBrains Rider by default."
- [Docker | PyCharm Documentation](https://www.jetbrains.com/help/pycharm/docker.html) and community thread on PyCharm CE — Docker plugin available by default in PyCharm Professional; must be installed manually in PyCharm Community; Docker-as-remote-interpreter is Professional-only.
- [FAQ about Dev Containers | IntelliJ IDEA Documentation](https://www.jetbrains.com/help/idea/faq-about-dev-containers.html) — local Docker CLI required to "collect the correct context and clone only the necessary files into the remote machine" for local and SSH-remote Docker Engine.
- [Since 2021.1 DOCKER_HOST environment variable cannot be overridden in Docker Compose — YouTrack IDEA-267675](https://youtrack.jetbrains.com/issue/IDEA-267675/Since-2021.1-DOCKERHOST-environment-variable-cannot-be-overridden-in-Docker-Compose) — corroborates that `DOCKER_HOST` handling in the IDE is limited/inconsistent, not a live ambient setting.
- [How to Use Podman with JetBrains IDEs (oneuptime.com)](https://oneuptime.com/blog/post/2026-03-18-use-podman-jetbrains-ides/view) — third-party precedent for connecting a non-Docker-Desktop engine via the "Unix socket" (or engine-specific preset) option with an absolute custom socket path; no `~` expansion shown; "Test Connection" used to verify.
- Local verification (this repo, not a citation): `DOCKER_HOST=unix:///Users/allie/.morbstack/run/docker.sock docker version` and `docker info` against the running Morbstack engine — confirmed server 29.7.1, API 1.55, `overlay2` storage driver, engine reachable and empty (0 containers, 18 images) at time of writing.

## Explicitly not verified

- No JetBrains IDE is installed on the machine used for this research (checked `/Applications` and `~/Library/Application Support/JetBrains` — both empty of JetBrains products). Every claim above about in-IDE behavior (Services tree, exec terminal, Compose run configuration UI, Gateway/Dev Containers wizard, the exact effect of the "Docker for Mac" preset) is sourced to JetBrains documentation text, not to driving the actual application.
- Whether the "Docker for Mac" preset in current 2024.x/2025.x IDEs hardcodes a socket path different from a manually-entered Unix socket path was not confirmed either way from the documentation text available. The setup steps above sidestep the question by using "Unix socket" instead.
- Whether `host.docker.internal` / `gateway.docker.internal` are needed by any JetBrains-specific feature (as opposed to user Compose files) was not found in the docs surveyed; Morbstack now implements both aliases in the guest, but no JetBrains-specific run has verified them yet.
