# Ecosystem matrix: Testcontainers and Dev Containers vs Morbstack (EN-8 / EN-9)

Date: 2026-08-04. Engine: the running dev daemon (`dist/Morbstack.app`,
`morbstackd` PID from `mise run doctor`, all green), socket
`/Users/allie/.morbstack/run/docker.sock`, server **Docker Engine - Community
29.7.1**, ApiVersion 1.55, **MinAPIVersion 1.40** (stock upstream default —
verified via `curl --unix-socket ... /version`; Morbstack does not modify it).

> **Superseded 2026-08-05 (UX-21), for the MinAPIVersion line only.** That
> reading was true of the daemon this pass ran against and is false of the
> daemon shipped since. This document was committed at 13:26 on 2026-08-04;
> **nine minutes later**, PROTO-7 (`cfde3b7`) took the mitigation this file
> recommends below and shipped it: `guest/morbinit/src/supervisor.rs:191-192`
> now sets `DOCKER_MIN_API_VERSION=1.24` **unconditionally** in dockerd's
> environment — deliberately not behind a toggle, because the failure it
> prevents is silent. Verified live in that commit by probing downward until it
> broke: `/v1.23/info` → 400 (upstream's real hard floor), `/v1.24/info` → 200,
> `/v1.32/info` → 200 (was 400), negotiation for modern clients unchanged at
> 1.55. So Morbstack **does** modify the floor now, and does so to widen it.
> Everything else in the header still describes the run. The two claims never
> overlapped in time; there is no live contradiction to resolve.

All probes ran through `scripts/ecosystem-acceptance.sh` with
`MORBSTACK_HOME=/Users/allie/.morbstack`, which creates a scratch
`DOCKER_CONFIG`, proves a throwaway context reaches the engine, then hands the
probe `DOCKER_HOST=unix:///Users/allie/.morbstack/run/docker.sock` and
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` (Testcontainers
suites) or context-only discovery (Dev Containers suite). `~/.docker` was never
written; several probes deliberately *read* the conventional Docker Desktop
socket paths, because that fallthrough is part of what was under test. This
machine has a live Docker Desktop 4.37.0 (engine 27.4.0) socket at
`~/.docker/run/docker.sock` — the worst-case side-by-side scenario.

Every Testcontainers probe was a **real Postgres test**: start
`postgres:16-alpine` through the language's Testcontainers client, connect with
a real driver, `CREATE TABLE` / `INSERT` / `SELECT`, assert the rows, confirm a
`testcontainers/ryuk` container is running against the engine while the test
container is up, stop, then verify zero leftovers. A plain `docker run` proves
none of that: discovery, the reaper, and the socket bind mount are the point.

## Verdict table

| Suite | Explicit config (harness) | Zero-config discovery | Ryuk | Verdict |
| --- | --- | --- | --- | --- |
| Testcontainers Node (testcontainers 12.1.0, @testcontainers/postgresql, node 22.23.2) | **PASS** — 3.5 s total (image cached) | **FAIL-DANGEROUS**: with a current `morbstack` context and no `DOCKER_HOST`, silently connected to Docker Desktop 27.4.0 | works (ryuk 0.14.0), self-reaped ~10 s | `runs-here` with env vars; never context/zero-config |
| Testcontainers Python (testcontainers 4.15.0, psycopg 3.3.4, Python 3.14.6) | **PASS** — 3.8 s total | **PASS**: context-only (no `DOCKER_HOST`) connected to Morbstack 29.7.1 via docker-py's context awareness | works (ryuk 0.8.1) | `runs-here`; best-in-class discovery |
| Testcontainers Go (testcontainers-go v0.43.0, pgx v5, go 1.26.5) | **PASS** — 1.7 s test (cached) | **FAIL-DANGEROUS**: no `DOCKER_HOST` → silently ran the whole suite against Docker Desktop 27.4.0, green | works | `runs-here` with env vars; never zero-config |
| Testcontainers Java 1.21.4 / docker-java 3.4.2 (Temurin 21, Maven 3.9.16) | **PASS** — 5.9 s total incl. ryuk pull; preflight socket-mount check passed | **FAIL-DANGEROUS** (like Node/Go): env-only discovery; older clients fail over silently | works (ryuk 0.12.0) | `runs-here` on 1.21.x with env vars |
| Testcontainers Java **1.20.4** (docker-java 3.4.0) | **FAIL** — engine-29 API floor (`/v1.32` probe vs `MinAPIVersion 1.40`), see below | **FAIL-DANGEROUS**: silent failover to Docker Desktop in *both* modes | started (0.11.0) — on the wrong daemon | FAIL on ≤1.20.x against any engine-29 daemon |
| Dev Containers CLI (@devcontainers/cli 0.88.0) | **PASS** — up 34 s incl. pull; exec, sentinel, two-way workspace bind mount, features/derived-image build all worked | **PASS** — context-only by design (`DOCKER_CONTEXT` + scratch `DOCKER_CONFIG`), no `DOCKER_HOST` anywhere | n/a | `runs-here`, zero-config once a context exists |

"FAIL-DANGEROUS" means: no error, no warning — the test suite goes green
against the wrong daemon. On a machine that has (or once had) Docker Desktop,
that is silent misdirection of a user's entire test run.

> **Update, 2026-08-04 (later the same day):** ECO-1/ECO-2 landed. The
> zero-config column above records the pre-fix state; see
> [Zero-config rerun](#zero-config-rerun-2026-08-04-after-eco-1--eco-2) for
> the post-fix evidence: Node, Go, Java, and Python all green against
> **29.7.1** with no environment variables at all, Ryuk included, no
> `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`. Design and coexistence rules:
> [`../design/ZERO-CONFIG-DISCOVERY.md`](../design/ZERO-CONFIG-DISCOVERY.md).

## Testcontainers Node — exact commands and output

```
$ MORBSTACK_HOME=/Users/allie/.morbstack scripts/ecosystem-acceptance.sh \
    testcontainers-node -- node .../tc-node/probe.mjs
ecosystem acceptance suite=testcontainers-node server=29.7.1
  docker-host=unix:///Users/allie/.morbstack/run/docker.sock
  testcontainers-socket=/var/run/docker.sock
engine: server= os=Alpine Linux v3.24 version=29.7.1
postgres started: id=22beb4a61d75 host=localhost port=49454
query result: n=2 vs=hello,morbstack
ryuk containers running: 1 (testcontainers/ryuk:0.14.0)
timings ms: discovery=16 start=3260 sql=32 stop=189 total=3497
NODE PROBE PASS
```

Cleanup verified: after Ryuk's ~10 s reap window, `docker ps -a`,
`volume ls`, `network ls` showed nothing new.

**Zero-config variant** (scratch `DOCKER_CONFIG` with `morbstack` context
current, no `DOCKER_HOST`):

```
connected: host=localhost serverVersion=27.4.0 os=Docker Desktop
DAEMON: OTHER (wrong daemon!)
```

testcontainers-node's strategy list (properties file → `DOCKER_HOST` →
`/var/run/docker.sock` → `~/.docker/run/docker.sock` → …) never consults
contexts, so it walked straight past Morbstack into the Docker Desktop
rootless socket. Reconfirmed on today's build, matching
`integrations/ecosystem.md`.

**No-override variant** (`DOCKER_HOST` set, no
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`): fails exactly as documented —

```
FAILED as expected: (HTTP code 500) server error - error while creating mount
source path '/Users/allie/.morbstack/run/docker.sock': mkdir ...: operation not supported
```

Ryuk bind-mounts the `DOCKER_HOST` path, which doesn't exist inside the guest
VM. The override (`/var/run/docker.sock`, the *guest* dockerd path) is
mandatory. `TESTCONTAINERS_RYUK_DISABLED` is not needed and must not be the
recommendation. The failed run left zero resources behind.

## Testcontainers Python — exact commands and output

```
$ MORBSTACK_HOME=/Users/allie/.morbstack scripts/ecosystem-acceptance.sh \
    testcontainers-python -- .../tc-py/venv/bin/python .../tc-py/probe.py
engine: version=29.7.1 os=Alpine Linux v3.24
postgres started: id=79d526b9ffba host=localhost port=49675
query result: n=2 vs=hello,morbstack
ryuk containers running: 1 (testcontainers/ryuk:0.8.1)
timings s: discovery=0.03 start=3.55 sql=0.03 stop=0.20 total=3.81
PYTHON PROBE PASS
```

**Zero-config variant** (context-only): connected to **Morbstack 29.7.1** —
testcontainers-python builds its client through docker-py 7.2.0's
`from_env()`, which falls back to the current docker context. Python is the
only Testcontainers client that is context-safe.

**No-override variant**: identical HTTP 500 mount failure as Node
(`error while creating mount source path '/Users/allie/.morbstack/run/docker.sock'`),
on ryuk's own start. No leftovers.

## Testcontainers Go — exact commands and output

testcontainers-go v0.43.0 (now on `moby/moby/client` v0.4.0, not
`docker/docker/client`), postgres module, pgx v5, Go 1.26.5 via mise.

```
$ MORBSTACK_HOME=/Users/allie/.morbstack scripts/ecosystem-acceptance.sh \
    testcontainers-go -- .../tc-go/probe.test -test.v -test.run TestPostgresRoundTrip
GO PROBE DISCOVERY elapsed=19.97ms api_version=1.55 server_version=29.7.1 os=linux
GO PROBE START_CONTAINER elapsed=1.457s
GO PROBE RYUK_CHECK found=true
GO PROBE SQL row_id=1 msg="morbstack-testcontainers-go-probe"
GO PROBE PASS
--- PASS: TestPostgresRoundTrip (1.73s)
```

**Zero-config variant** (`env -i`, empty scratch `DOCKER_CONFIG`, no
`DOCKER_HOST`): the entire suite ran green against
`server_version=27.4.0 platform="Docker Desktop 4.37.0"` — silent
wrong-daemon, same shape as Node. testcontainers-go reads env only, never
contexts. Cleanup on Morbstack verified clean; the wrong-daemon container
self-terminated via the probe's own `TerminateContainer`.

## Testcontainers Java — FAIL, with the one real engine-interop finding

Toolchain: Temurin 21.0.12 + Maven 3.9.16 via mise (~14 s install).
testcontainers-java **1.20.4**, `org.postgresql:postgresql` 42.7.4.

The probe printed `JAVA PROBE PASS` — **against the wrong daemon**. With
`DOCKER_HOST` correctly pointed at Morbstack,
`EnvironmentAndSystemPropertyClientProviderStrategy` connected to the socket
and issued docker-java's hardcoded compatibility probe `GET /v1.32/info`.
Engine 29 answers:

```
HTTP/1.1 400 Bad Request
Api-Version: 1.55
{"message":"client version 1.32 is too old. Minimum supported API version is 1.40,
 please upgrade your client to a newer version"}
```

docker-java treats that 400 as "no daemon here", and testcontainers-java
silently walks its strategy chain to `DockerDesktopClientProviderStrategy`,
which found `~/.docker/run/docker.sock` and ran everything against Docker
Desktop 27.4.0. Same result zero-config. No warning at default log levels.

**This is not a Morbstack modification.** Verified directly:

```
$ curl --unix-socket ~/.morbstack/run/docker.sock http://localhost/v1.32/version
400 {"message":"client version 1.32 is too old. Minimum supported API version is 1.40, ..."}
$ curl ... /v1.40/version   -> 200
$ curl ... /version | jq .MinAPIVersion  -> "1.40"
```

`MinAPIVersion: 1.40` is stock upstream moby 29.7.1. The consequence is
ecosystem-wide: **testcontainers-java ≤ 1.20.x cannot talk to any Docker
Engine 29 daemon**, and on a machine with an older daemon lying around it
silently defects to it rather than erroring. Docker Desktop is currently
insulated only because it still ships engine 27.x (MinAPIVersion 1.24).

Follow-up run with the **latest released testcontainers-java** and with
`DOCKER_API_VERSION` overrides: see addendum below.

What Morbstack can do about it (finding filed with the orchestrator; guest
lane is owned elsewhere): upstream dockerd honors a `DOCKER_MIN_API_VERSION`
environment variable (daemon-side, since 25.0) that lowers the floor. Setting
`DOCKER_MIN_API_VERSION=1.24` in morbinit's dockerd environment would let
docker-java's 1.32 probe through and make every existing testcontainers-java
release work unmodified — worth verifying that moby 29 still allows a floor
that low, then a one-line supervisor change in `guest/morbinit`.

Wrong-daemon side effects: the Java runs pulled `postgres:16-alpine` and
`testcontainers/ryuk:0.11.0` into Docker Desktop's image cache. Its
containers self-reaped; the images were left (cleaning them would mean
operating against `~/.docker`, which this pass never does).

### Addendum: latest testcontainers-java retest — PASS

Retested with **testcontainers-java 1.21.4** (latest on Maven Central; no
2.x line exists), which transitively pulls **docker-java 3.4.2**. Fixed:
docker-java 3.4.2's compatibility probe is `GET /v1.44/_ping`, which clears
the 1.40 floor. Debug log shows the first strategy winning:

```
Found Docker environment with Environment variables, system properties and defaults.
Resolved dockerHost=unix:///Users/allie/.morbstack/run/docker.sock
Connected to docker:
  Server Version: 29.7.1
  API Version: 1.55
  Operating System: Alpine Linux v3.24
```

Ryuk 0.12.0 started and was confirmed running via `listContainersCmd()`;
the "Checking the system..." preflight (which bind-mounts the socket —
exactly the VM corner under test) passed against the real Morbstack daemon;
Postgres CRUD round-tripped; total wall time 5 887 ms including the ryuk
pull; `JAVA PROBE PASS`; cleanup verified to baseline. Minor cosmetic noise:
two `java.nio.channels.ClosedChannelException` traces from docker-java's
zerodep transport after container-create; containers started fine.

So the Java verdict splits by client version: **1.21.x (docker-java ≥3.4.2)
= `runs-here`, same two env vars as the other languages; ≤1.20.x
(docker-java ≤3.4.0, pinned probe 1.32) = silent wrong-daemon failover
against any stock engine-29 daemon, Morbstack included.** No user-side env
knob rescues the old versions; the daemon-side `DOCKER_MIN_API_VERSION`
mitigation above is the only fix that doesn't require users to upgrade.

## Dev Containers CLI — exact commands and output

Fixture: `integrations/fixtures/devcontainer` (already in-repo:
`mcr.microsoft.com/devcontainers/base:alpine`, sentinel via
`postCreateCommand`). CLI: `@devcontainers/cli` 0.88.0, node 22.23.2. Run
through the `devcontainers-cli` suite — **context discovery only**, no
`DOCKER_HOST`, candidate `docker` CLI first on `PATH`.

```
$ ... devcontainer up --workspace-folder integrations/fixtures/devcontainer \
      --id-label "dev.morbstack.acceptance=devcontainers-cli-1785874382"
[20:13:03] Error fetching image details: No manifest found for mcr.microsoft.com/devcontainers/base:alpine.   # cosmetic, see note
[20:13:36] Container started
{"outcome":"success","containerId":"0a18a8258acf...","remoteUser":"vscode",
 "remoteWorkspaceFolder":"/workspaces/morbstack/integrations/fixtures/devcontainer"}
# wall: 34 s including the base-image pull
```

- **Workspace bind mount**: the CLI auto-mounted the git root
  (`/Users/allie/Develop/morbstack` → `/workspaces/morbstack`,
  `consistency=cached`). Verified **two-way**: a file written inside the
  container appeared on the Mac with matching content, then was removed.
- **postCreateCommand**: ran; `devcontainer exec ... cat
  /tmp/morbstack-devcontainer-sentinel` returned `ready`, user `vscode`,
  workdir `/workspaces/morbstack/integrations/fixtures/devcontainer`.
- **Features / derived image build**: second (scratch) workspace with
  `mcr.microsoft.com/devcontainers/base:debian` +
  `ghcr.io/devcontainers/features/go:1`. The CLI built the derived
  `vsc-...-features` image through Morbstack's buildkit and started it:
  `up` outcome success in 3 m 35 s (feature download + image build + pull);
  `go version` inside → `go1.23.12 linux/arm64`, feature sentinel written.
- The "No manifest found" line is the CLI's pre-pull `docker buildx
  imagetools inspect` of a not-yet-pulled tag; it is non-fatal and appears
  against Docker Desktop too. Cosmetic.

Two documentation bugs found in `docs/ecosystem-acceptance.md` (fixed in this
pass):

1. `devcontainer exec` without repeating the `--id-label` from `up` fails
   with `Error: Dev container not found.` — `--id-label` *replaces* the
   default `devcontainer.local_folder` identity labels, so every subsequent
   command must pass the same label.
2. `@devcontainers/cli` 0.88.0 has **no `devcontainer down` subcommand**;
   teardown is `docker rm -f` on the labelled container.

Cleanup: both dev containers removed via the candidate CLI; derived
`vsc-dc-feature-*` image and both `mcr.microsoft.com/devcontainers/base`
images deleted; post-check showed 0 labelled containers, 0 devcontainer
images. (`postgres:16-alpine` and the two ryuk tags pre-dated this pass and
are shared with other suites; left in place. The one anonymous volume in
`volume ls` pre-dated this pass — creation timestamp 19:37Z, before any probe
ran.)

## What this means for a user

1. **Works with two env vars, everywhere:**
   `DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock` plus
   `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` gives green,
   fast, fully-reaped Testcontainers runs in Node, Python, and Go — startup
   times indistinguishable from Docker Desktop (a Postgres test round-trips
   in under 4 s warm). `integrations/env/morbstack-env.sh` emits exactly
   these.
2. **Zero-config is the gap, and it is dangerous, not just inconvenient.**
   Only Python (context) and the Dev Containers CLI (context) find Morbstack
   without `DOCKER_HOST`. Node and Go silently run the whole suite against a
   Docker Desktop socket if one exists — green tests, wrong engine. The
   single biggest ecosystem lever remains: register/point the conventional
   discovery paths (the `/var/run/docker.sock` symlink surfaced by
   `morb context status`, plus automatic context registration).
3. **Java works on current versions, silently breaks on older ones.**
   testcontainers-java 1.21.x (docker-java ≥3.4.2) is a full PASS with the
   same two env vars. Anyone pinned to ≤1.20.x — a large installed base —
   gets a silent wrong-daemon run against *any* engine-29 daemon (or, with
   no other daemon, a confusing "no Docker environment" failure), and no
   user-side setting rescues them. The `DOCKER_MIN_API_VERSION=1.24`
   guest-side mitigation would make Morbstack the engine-29 distribution
   that old testcontainers-java *does* work with.
4. **Dev Containers work end-to-end today** — lifecycle, bind-mounted
   workspace (two-way), postCreateCommand, exec, and features (including a
   real derived-image build) — with nothing but a docker context.

## Zero-config rerun (2026-08-04, after ECO-1 / ECO-2)

What changed since the table above:

1. **ECO-2 (engine):** `DockerBindMountPreflight` now rewrites a bind source
   that is — by exact, symlink-resolved identity — the daemon's own Mac-side
   socket into `/var/run/docker.sock`, the guest's spelling of the same
   resource. Ryuk's socket mount therefore works with **no**
   `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`, from every discovery flavour.
   `scripts/ecosystem-acceptance.sh` no longer sets the override.
2. **ECO-1 (install):** `morb install-cli` already created the per-user
   conventional socket link `~/.docker/run/docker.sock -> ~/.morbstack/run/docker.sock`
   (only when that path is free) and registered/selected the `morbstack`
   context (only when the current context is Docker's plain default). That
   link is exactly the rootless path Testcontainers Node, Go, and Java probe.
   On this dev machine it is occupied by Docker Desktop's live socket, so the
   original run above never saw it; on the target machine — no Docker at all —
   it is what makes Morbstack discoverable with zero configuration.

Method: the same locked probes as above (real Postgres round trip + Ryuk
verification), run with `env -i` — **no `DOCKER_*`, no `TESTCONTAINERS_*`,
nothing** — and `HOME=/tmp/mb-zcfg`, a scratch home containing only what
`morb install-cli` produces on a free machine: the discovery symlink (Node,
Go, Java) and the selected `morbstack` context written by the real
`morb context create` + `docker context use morbstack` (Python). The engine
under test is the rebuilt dev daemon (server **29.7.1**); Docker Desktop
27.4.0 remained installed and untouched throughout, which is the
wrong-daemon tripwire: any 27.4.0 in the output is an instant FAIL.

| Suite | Discovery input (filesystem only) | Result |
| --- | --- | --- |
| Node 12.1.0 | `~/.docker/run/docker.sock` link | **PASS** — `serverVersion=29.7.1 os=Alpine Linux v3.24`, ryuk 0.14.0 running, `NODE PROBE PASS`, 2.1 s |
| Go v0.43.0 | `~/.docker/run/docker.sock` link | **PASS** — `server_version=29.7.1 platform=Docker Engine - Community`, ryuk found, `GO PROBE PASS`, 1.5 s |
| Java 1.21.4 | `~/.docker/run/docker.sock` link (`Found Docker environment with Docker accessed via Unix socket (/tmp/mb-zcfg/.docker/run/docker.sock)`) | **PASS** — `Docker server version: 29.7.1 (API 1.55)`, ryuk 0.12.0, `JAVA PROBE PASS`, 4.4 s |
| Python 4.15.0 | selected `morbstack` context | **PASS** — `version=29.7.1`, ryuk 0.8.1, `PYTHON PROBE PASS`, 1.8 s |

Bind-rewrite proof as dockerd recorded it (both the discovery-link spelling
and the direct `DOCKER_HOST` socket path):

```
$ docker create -v /tmp/mb-zcfg/.docker/run/docker.sock:/var/run/docker.sock:ro alpine:3.20 true
$ docker inspect --format '{{json .HostConfig.Binds}}' <id>
["/var/run/docker.sock:/var/run/docker.sock:ro"]
```

The explicit-config harness suites (Node/Go/Java through
`scripts/ecosystem-acceptance.sh` with `DOCKER_HOST` set and
`testcontainers-socket=<not set>`) also pass post-change, so the override's
removal from the harness is load-bearing, not cosmetic.

Caveats that remain true:

- On a machine where Docker Desktop's socket is live at
  `~/.docker/run/docker.sock`, context-blind clients still find Docker
  Desktop first. That is deliberate deferral, now loud instead of silent:
  `morb install-cli` ends with an explicit `[!!] ... NOT what Docker tools
  will discover` block, and `morb doctor`'s `docker-discovery` check warns
  about competing conventional sockets.
- testcontainers-java ≤1.20.x still fails against any engine-29 daemon (API
  floor, documented above); zero-config discovery does not change that.

  > **No longer true of Morbstack, 2026-08-05 (UX-21).** It remains true of
  > *any other* stock engine-29 daemon, which is the point. PROTO-7 (`cfde3b7`,
  > 2026-08-04) sets `DOCKER_MIN_API_VERSION=1.24` in the guest
  > (`guest/morbinit/src/supervisor.rs:192`) and the `/v1.32/info` probe that
  > docker-java ≤3.4.0 uses for discovery now returns 200. That inverts the
  > finding into an advantage: Morbstack is the engine-29 distribution the
  > ≤1.20.x installed base works against, while Docker Desktop is insulated
  > only until it moves off engine 27. Not re-run through this file's Java
  > probe, so it is the commit's live evidence, not this document's.
