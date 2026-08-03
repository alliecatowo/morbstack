# Drop-in parity pass

Status: one-time audit, run against git HEAD `081aa29`. Not CI-enforced (see
`docs/compat.md` for the CI-gated ecosystem matrix, which is separate from
and narrower than what's covered here). This document exists to answer one
question honestly: for the claim "same docker CLI, same Engine API, same
Compose files, same everything," where is that true today, and where does
it actually break?

## Implementation follow-up

The results below are preserved as the evidence from that live audit; they
are not silently rewritten as later code lands. Since the audited revision,
the guest has implemented the two highest-impact guest-parity fixes:

- **#9 `/tmp` bind sources:** once the live `/private/tmp` VirtioFS share is
  mounted, `morbinit` bind-mounts it over the guest's `/tmp`. A literal
  `-v /tmp/file:/container/file` therefore sees the same Mac file as
  `/private/tmp/file`, matching macOS's own alias. If the share is omitted
  or fails to mount, the guest keeps its private tmpfs and `morb doctor`
  now warns explicitly.
- **#18/#19 host aliases:** a guest split-DNS service answers IPv4 A queries
  for `host.docker.internal` and `gateway.docker.internal` with the VM NAT
  gateway; dockerd gives containers that resolver and uses the same gateway
  for `host-gateway`. Non-special queries continue to the DHCP resolver.

These changes have focused unit coverage, but this document must not claim a
new live PASS until the exact #9/#18/#19 commands are run against a freshly
built guest. Until then, the historical FAIL rows and tally remain the
audit record rather than a statement about the current implementation.

## Method

Built once (`mise run build && mise run sign`), then copied `morbstackd`/`morb` out
to a private directory (`/tmp/morbparity/bin`) so a concurrent `swift
build` from another session couldn't strip the daemon's virtualization
entitlement mid-run. Ran against an isolated `MORBSTACK_HOME` (short path,
under the 104-byte `sun_path` limit for the unix socket) with the
already-built kernel/initramfs copied in (not rebuilt), and an isolated
`DOCKER_CONFIG` (never touched `~/.docker`, which has a live
`credsStore: "desktop"` that hangs the CLI when Docker Desktop isn't
running). Everything below is a real command against a real cold-booted
VM — nothing simulated, nothing asserted from reading source. All test
containers, volumes, images, and the scratch home/config directories were
removed at the end of the run; `~/.morbstack` and `~/.docker` are
unmodified.

## Results

| # | Area | Test | Command | Result | Evidence / notes |
|---|------|------|---------|--------|-------------------|
| 1 | Core CLI | `docker version` | `docker version` | **PASS** | Client 27.4.0 talks to Server 29.7.1 (unmodified upstream) over the relay. Cold VM boot to a usable API: 2.16s wall clock. |
| 2 | Core CLI | `docker info` | `docker info` | **PASS** | Full, plausible output — overlay2/extfs, cgroup v2, all standard network/log drivers listed, `Insecure Registries: ::1/128, 127.0.0.0/8`. `WARNING: No swap limit support` appears, same as any Docker-Desktop-style Linux VM without swap accounting compiled in — not a defect. |
| 3 | Core CLI | ps/images/pull/run/exec/logs/inspect/cp/stats/events/rm/rmi | (sequence, see below) | **PASS** | `docker pull alpine:3.20`, `docker run -d`, `docker exec ... uname -a`, `docker logs`, `docker inspect --format`, `docker cp` both directions, `docker stats --no-stream`, `docker events` (full, correctly-ordered event stream with real timestamps), `docker rm -f`, `docker rmi` — every one produced the same shape of output real Docker would. |
| 4 | Core CLI | `docker system df` / `docker system prune -f` | `docker system df`, `docker system prune -af` | **PASS** | Correct reclaimable accounting; a `-af` after the whole run reclaimed 2.134GB cleanly. |
| 5 | Compose | web+api+postgres+redis: `depends_on: condition: service_healthy`, named volume, custom bridge networks, healthchecks | `docker compose up -d` | **PASS** | All 4 services became healthy in dependency order (redis/db healthy → api healthy → web healthy). `curl http://127.0.0.1:18080/` from the Mac returned real Flask JSON that itself round-tripped through Redis (`INCR`) and Postgres (`SELECT 1`) inside the guest. Service-name DNS resolved (`api` → `172.19.0.2`, `db`/`redis` → `172.18.0.x`). `docker compose down -v` cleaned up containers, networks, and the named volume. |
| 6 | Compose | WordPress + MySQL (classic env-var config, persistent volumes) | `docker compose up -d` | **PASS** | `db` healthy, `wordpress` healthy in ~24s total. `curl http://127.0.0.1:18081/wp-login.php` returned a real `302` to `/wp-admin/install.php`; the install wizard page rendered (`<title>WordPress › Installation</title>`), proving Apache+PHP+MySQL were genuinely wired together, not just "containers running." |
| 7 | Compose | build-from-Dockerfile service (`docker compose build`) | `docker compose build` | **PASS** | Multi-stage build (`base`→`deps`→`runtime`), `COPY --from=deps`, ran to completion. Note: used the **classic (non-BuildKit) builder** by default (`com.docker.compose.image.builder=classic` label) — see #13. |
| 8 | Bind mounts | Fresh content on re-read after a host-side edit | `docker run -v $HOST:/app ... cat` before/after editing the file on the Mac | **PASS** | Every re-read reflected the new content immediately — no staleness, matches the "VirtioFS is always fresh, just not notified" design. |
| 9 | Bind mounts | Single-file mount via an **unresolved `/tmp/...` path** | `docker run -v /tmp/foo/api.py:/app/api.py ...` (cwd given as `/tmp/...`, not `/private/tmp/...`) | **FAIL** | On macOS `/tmp` is a symlink to `/private/tmp`, and the default `shared_paths` list is `/Users`, `/Volumes`, `/private/tmp` — not `/tmp`. Passing the unresolved path to a bind mount doesn't error; it silently makes Docker create the mount target as an **empty directory** in the guest instead of binding the file, because the literal `/tmp/...` path doesn't exist there. Reproduced directly: `docker run --rm -v /tmp/x/api.py:/app/api.py alpine cat /app/api.py` → `cat: read error: Is a directory`; the identical command with `/private/tmp/x/api.py` works. This broke an entire Compose stack (`python: can't find '__main__' module in '/app/api.py'`) before the cause was found. **`morb doctor` already flags this exact gotcha** (`shares-tmp: the guest's /tmp is its own tmpfs...use /private/tmp/x`), but it isn't called out in the README's bind-mount section, and the failure mode is a silent empty directory rather than an error — the worst combination for something this common on macOS (lots of tooling, editors, and shell configs write to bare `/tmp`). |
| 10 | Bind mounts | inotify across a VirtioFS mount (hot reload) | `nodemon server.js` watching a bind-mounted dir, edited on the Mac | **FAIL (documented)** | Confirmed exactly as `README.md`/`docs/sharing.md` state: nodemon started, watched the path, and a host-side edit produced **zero** restart after an 8s wait — no inotify event crossed the mount. This is a real, and currently unavoidable, break in anything that expects live-reload (`nodemon`, `vite`, `webpack --watch`, `create-react-app`'s dev server, etc.). |
| 11 | Bind mounts | Workaround: polling-based watch | `nodemon --legacy-watch server.js`, same edit | **PASS** | Polling picked up the change and restarted correctly (`[nodemon] restarting due to changes...`). This is the correct, working mitigation to document prominently for anyone hitting #10. |
| 12 | Build | Multi-stage Dockerfile, `ARG`/`ENV`, `COPY --from`, cache reuse on rebuild | `docker build` (classic builder, no cache-busting change) | **PASS** | Every step showed `CACHED` on rebuild; final image built from cache in 0.44s. |
| 13 | Build | `docker build` / `docker buildx build --platform linux/amd64` out of the box | `DOCKER_BUILDKIT=1 docker build ...`, `docker buildx build ...` | **FAIL (out of the box)** | `docker: 'buildx' is not a docker command` — no `docker-buildx` CLI plugin is installed or shipped anywhere in the repo (`dist/host-bin/` only has `docker-compose`). `docs/compat.md` itself says this plainly: "`buildx` is not fetched or tested yet at any milestone so far" — so this isn't a regression, it's an acknowledged gap, but it means **the modern default `docker build` path (BuildKit-by-default since Docker 23+) is broken today with a stock Docker CLI and no manual plugin install.** |
| 14 | Build | BuildKit itself: multi-platform build, cache mounts, once a stock `docker-buildx` binary is manually placed in `cli-plugins/` | `docker buildx build --platform linux/amd64 --load .`; `RUN --mount=type=cache,target=/cache` across repeated builds | **PASS** | Once the client-side plugin exists, everything works perfectly: `docker buildx ls` shows a live `docker` driver, BuildKit v0.32.0, `linux/arm64` native. A `--platform linux/amd64` build ran the full multi-stage Dockerfile through Rosetta-backed emulation and produced a real `amd64/linux` image (`docker run` on it printed `x86_64`, with the expected "platform mismatch" warning). Cache mounts persist correctly across builds when tested properly (with `--build-arg` cache-busting rather than `--no-cache`, which also clears cache-mount contents — that's standard BuildKit behavior, not a Morbstack bug). **This is the single best finding of the whole pass: the guest's upstream dockerd/BuildKit is fully functional: the only gap is that Morbstack doesn't ship the client-side plugin.** |
| 15 | AMD64 | `mysql:5.7` (genuinely single-arch, amd64-only) end to end | `docker run --platform linux/amd64 mysql:5.7`, then `SELECT SHA2('morbstack',256)` inside vs `shasum -a 256` on the Mac | **PASS** | Server boots, accepts connections, and the SHA-256 hash computed inside the emulated amd64 container (`5e4abe8591...`) is bit-identical to the Mac's own `shasum -a 256` output. Confirms Rosetta translation is correct, not just "the process starts." |
| 16 | AMD64 | Compute-heavy slowdown ratio | `openssl speed sha256` and `openssl speed rsa2048`, native `linux/arm64` vs `--platform linux/amd64` | **PASS (matches documented range)** | SHA-256 at 16KB blocks: 2,214,112 KB/s native vs 432,494 KB/s amd64-via-Rosetta → **~5.1x slower**, matching the doc's "up to ~5x for SHA/AES-leaning code." RSA-2048 sign: 1,643/s native vs 435/s amd64 → **~3.8x**; verify: 64,156/s vs 28,087/s → **~2.3x** — inside the documented "1.8-2x general purpose" to "~5x crypto-extension-heavy" spread. |
| 17 | Ecosystem | Socket reachable at conventional Testcontainers/docker-py auto-discovery paths | check `/var/run/docker.sock`, `~/.docker/run/docker.sock`, `~/.docker/desktop/docker.sock`; `docker ps` with no `DOCKER_HOST`/context set | **FAIL** | None of the three conventional paths point at Morbstack. `/var/run/docker.sock` doesn't exist (correct — Morbstack must not clobber a real Docker install there). `~/.docker/run/docker.sock` exists but is a **stale leftover from a real Docker Desktop install**, not Morbstack's socket. With no `DOCKER_HOST` and no context configured, `docker ps` fails with `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`. Zero-config auto-discovery (what Testcontainers, most IDE Docker integrations, and `docker-py`'s default client all try first) will not find Morbstack; the user must export `DOCKER_HOST` or run `docker context create`/`use` by hand. The app does have a "copy docker context command" affordance, but it's a manual step, not automatic like a real Desktop install. |
| 18 | Ecosystem | `host.docker.internal` resolves inside a container | `docker run alpine getent hosts host.docker.internal` / `ping host.docker.internal` | **FAIL** | No `/etc/hosts` entry, no DNS answer: `ping: bad address 'host.docker.internal'`. This is a real Docker Desktop feature Morbstack does not provide at all — not degraded, just absent. |
| 19 | Ecosystem | `gateway.docker.internal` resolves inside a container | same, for `gateway.docker.internal` | **FAIL** | Same as #18 — no resolution. |
| 20 | Ecosystem | `--network host` | `docker run --network host nginx:alpine`; curl from the Mac and from inside the container | **PARTIAL (matches Docker Desktop's own behavior)** | Inside the guest, host networking works as expected (nginx binds the guest's port 80 directly, reachable from other guest processes). From the Mac it is **not** reachable (`curl` → connection failure), because `--network host` only ever gets you the *VM's* host network, never the Mac's — which is also true of real Docker Desktop for Mac (a well-known, long-standing Desktop gotcha, not a new Morbstack-specific regression). |
| 21 | Ecosystem | Docker-in-Docker via `-v /var/run/docker.sock:/var/run/docker.sock` | `docker run -v /var/run/docker.sock:/var/run/docker.sock docker:cli docker ps` | **PASS** | Worked perfectly — `docker:cli` inside the container talked straight to the guest's real dockerd through the bind-mounted socket, `docker version --format '{{.Server.Version}}'` printed `29.7.1`. |
| 22 | Ecosystem | Container-to-host connections | HTTP server bound on the Mac; curl from inside a container at various candidate addresses | **PARTIAL** | The container's own bridge gateway (`172.17.0.1`, from `ip route`) is a dead end. But the **guest VM's own gateway IP** (`192.168.64.1`, the address in `/etc/resolv.conf`'s `nameserver` line) *does* reach a Mac-side listener. So container→host connectivity is technically possible today, just not through any documented or stable hostname — a user would have to know to try the VM gateway IP, which isn't exposed as `host.docker.internal` or anything else discoverable. |
| 23 | Ecosystem | `docker context` integration | `docker context create morbstack --docker host=unix://...`, `docker context use morbstack`, `docker ps`/`docker info` with no `DOCKER_HOST` | **PASS** | Context creation, switching, and use all worked exactly like any other Docker host context. This is the correct workaround for #17. |
| 24 | Restart/persistence | Restart policy (`unless-stopped`) survives `morb stop` + `morb start` | container running with `--restart unless-stopped`, `marker.txt` written to a named volume, then `morb stop && morb start` | **PASS** | `morb stop` (10.7s) then `morb start` (VM up instantly, docker engine ready ~1-2s later) — the container came back `Up` on its own, no manual restart needed. |
| 25 | Restart/persistence | Images and named-volume data survive the same cycle | `docker images`, `docker run --rm -v paritydata:/data alpine cat /data/marker.txt` after the restart | **PASS** | Both `alpine:3.20` and `hello-world` images were still present; the volume still contained `persisted-data` written before the stop. |
| 26 | Failure modes | Disk full | Fresh 2 GiB disk (via `mkdisk.sh 2`), filled with `dd` from inside a container | **PASS** | Correct, standard Linux `dd: error writing '/fillfile': No space left on device`. The daemon stayed fully responsive afterward — a new `--rm` container ran fine (its writable layer's removal freed the space), a `docker pull` of a small image succeeded, `docker info` kept answering. No hang, no corruption. |
| 27 | Failure modes | Port already bound on the Mac | Python `http.server` holding `127.0.0.1:19999`, then `docker run -p 19999:80 nginx` | **PARTIAL (behavioral difference from Docker)** | Matches the documented design exactly: `docker run` **succeeds** (container starts, exit code 0), `docker ps`/`docker compose ps` **misleadingly show** `0.0.0.0:19999->80/tcp` as if published, and only `morb status` reveals the truth (`unavailable ports: 19999 -> ...: another process holds 127.0.0.1:19999; will retry`). Real Docker Desktop, by contrast, fails the `docker run` **synchronously** with `Bind for 0.0.0.0:19999 failed: port is already allocated` — a different exit code and a different script-observable outcome for the exact same situation. Anything that checks `docker run`'s exit status to detect a port conflict will behave differently under Morbstack. |
| 28 | Failure modes | Image that does not exist | `docker pull nonexistent-image-abc123xyz`, `docker run this-image-does-not-exist-anywhere:v1` | **PASS** | Byte-identical to real Docker Hub errors (`pull access denied ... repository does not exist or may require 'docker login'`) — this is literally hitting the real registry, so it can't help but match. |
| 29 | Failure modes | OOM | `docker run --memory=16m --memory-swap=16m alpine` allocating >16MB | **PASS** | `OOMKilled=true`, `ExitCode=137`, `Status=exited` — exactly the standard Docker contract. The `WARNING: Your kernel does not support swap limit capabilities` message also matches what real Docker Desktop's own Linux VM prints (no swap accounting there either) — not a Morbstack-specific defect. |

### Tally

29 checks: **20 PASS**, **3 PARTIAL** (#20, #22, #27 — documented-but-undersold behavioral differences), **6 FAIL** (#9, #10, #13, #17, #18, #19 — 2 of which, #10 inotify and #13 buildx-not-shipped, are already openly acknowledged as gaps in `README.md`/`docs/compat.md`; the other 4 — #9 the `/tmp` symlink bind-mount corruption, #18 `host.docker.internal`, #19 `gateway.docker.internal`, and #17 zero-config socket discovery — are not called out anywhere as prominently as their real-world impact deserves).

## Root-cause hypotheses and suggested fixes

**#9 — `/tmp` vs `/private/tmp` silently corrupts single-file bind mounts (fixed after this audit; live revalidation pending).**
Root cause: `shared_paths` defaults to `/private/tmp`, and nothing resolves
host-side symlinks before matching a `-v` source against the shared-root
list or before asking the guest to bind-mount it — so a `/tmp/...` path
that a Mac user typed naturally just doesn't exist in the guest, and
dockerd's own default behavior for "bind-mounting a path that doesn't
exist yet" is to create it as a directory. Suggested fix: resolve
symlinks on the host side before matching against `shared_paths` (so
`/tmp/x` is recognized as `/private/tmp/x` and mounted correctly), or at
minimum special-case `/tmp` as an always-included alias for
`/private/tmp` the same way macOS itself treats it. Failing that, the
Engine API relay could refuse (rather than silently succeed) a bind mount
whose resolved host path falls outside every `shared_paths` entry.

**#13 — `docker build`/`docker buildx` broken out of the box.**
Root cause: purely that no `docker-buildx` binary is fetched, verified, or
installed anywhere — `docs/compat.md` already says this is unscoped until
M1. Given that #14 proves the guest-side BuildKit is completely solid,
this is the cheapest, highest-leverage fix in this whole report: add
`docker-buildx` to `scripts/fetch-guest-assets.sh` and the README's
one-time-plugin-install step exactly the way `docker-compose` already
works today (`dist/host-bin/docker-compose` → `~/.docker/cli-plugins/`).

**#17 — no zero-config discovery.**
This remains separate from guest networking: the install flow should write a
`desktop-linux`-equivalent context and set it current rather than requiring
the user to run `docker context create` by hand. #18/#19's DNS/host-gateway
implementation is described in the follow-up above and needs a fresh live
run, not more design work.

**#27 — fixed-TCP host-port admission is now synchronous on the recognized path.**
For an ordinary fixed, loopback-supported TCP create, the host retains a real
listener before forwarding create, associates it from a bounded normal create
response, and activates that same descriptor before an exact start `204` reaches
the client. This removes the prior success-with-no-listener race without changing
Docker request/response bytes. The claim is intentionally narrower than complete
Docker Desktop parity: dynamic/ranged allocation, UDP, opaque or chunked response
framing, name-based/nonstandard start handoff, and lease survival across VM/daemon
shutdown still need their own data-plane or lifecycle contract.

## Priority list — what to fix first for a credible "drop-in" claim

1. **Re-run #9, #18 and #19 against the current guest.** The old failures
   have targeted implementations now; a real VM run is the only evidence
   strong enough to upgrade their results.
2. **Ship the `docker-buildx` CLI plugin.** Extremely high value for
   extremely low cost — the engine-side BuildKit is already fully
   functional (#14), multi-platform builds and cache mounts work
   perfectly once the client binary exists. This is the single best
   ROI item in the whole report.
3. **Zero-config daemon discovery.** Until there's a host app that
   registers a context automatically (or writes to a conventional socket
   path), every ecosystem tool that doesn't respect `DOCKER_HOST` will
   fail to find Morbstack at all. Testcontainers, most IDE integrations,
   and `docker-py`'s default client all fall into this bucket.
4. **Document the port-conflict and `docker ps` "0.0.0.0" behavioral
   differences explicitly**, since they're the kind of thing that passes
   every manual test and then breaks exactly one person's CI script that
   greps `docker run`'s exit code or trusts `docker ps`'s port column.
   Cheap to fix in documentation now; consider the harder synchronous-ACK
   fix later.

Lower priority, since they're already openly documented and have working
mitigations: the inotify gap (#10) already has a working documented
workaround (`--legacy-watch`/polling watchers, confirmed in this pass),
and `--network host`'s Mac-unreachability (#20) matches real Docker
Desktop's own long-standing limitation rather than being a new gap to
close.

## What surprised me

- **How solid the core engine is.** Every single core-CLI, Compose,
  restart/persistence, and most failure-mode test passed on the first or
  second try, with output indistinguishable from real Docker in every
  case I could check byte-for-byte (the Docker Hub error strings, the
  amd64 SHA-256 hash, the OOM exit code contract). The unmodified-dockerd
  bet the project is built on is paying off exactly as advertised.
- **BuildKit "not working" turned out to be a five-minute-fix, not an
  engine problem.** My first read of `docker buildx build` failing looked
  like a potentially deep gap (no BuildKit support at all would undercut
  a huge fraction of modern Docker workflows). It turned out the guest
  engine's embedded BuildKit is completely correct — cache mounts,
  multi-stage builds, and `--platform linux/amd64` cross-builds all work
  — and the only thing missing is a client-side binary nobody's fetched
  yet. That's a very different, much better, situation than "BuildKit
  doesn't work here."
- **The `/tmp` bind-mount bug's failure mode is unusually nasty.** It
  doesn't error. It doesn't warn. It just quietly gives you an empty
  directory where your file should be, and the resulting error message
  (from whatever process tried to read the "file") points nowhere near
  the real cause. This is exactly the kind of bug that costs someone an
  hour on their first day trying Morbstack.
- **`morb doctor` is already ahead of the README on some of this** — it
  flags the `/tmp` sharing gotcha and the `credsStore` hang precisely,
  which is good design, but that detail doesn't make it into the
  higher-traffic bind-mount documentation in `README.md`/`docs/sharing.md`.
- **Container-to-host connectivity technically already works** (#22) via
  the VM gateway IP — I expected it to be flatly impossible given the
  README's framing of "outbound NAT and nothing else." It's not
  impossible, it's just undiscoverable without knowing to look for it.
