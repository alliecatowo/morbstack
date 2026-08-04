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
  gateway; dockerd gives containers that resolver only after it has bound and
  started successfully, and uses the same gateway for `host-gateway`.
  Non-special queries forward to the configured IPv4 resolver (normally the
  DHCP resolver, rather than assuming the route gateway also provides DNS).
  [Docker Desktop documents](https://docs.docker.com/desktop/features/networking/networking-how-tos/)
  the names separately—host-internal address versus Docker-VM gateway—but the
  VZNAT topology exposes the reachable Mac host at its VM gateway, so both
  resolve to that one address here. A fresh live run must still prove both
  lookup forms, [`--add-host=…:host-gateway`](https://docs.docker.com/reference/cli/dockerd/#configure-host-gateway-ip),
  and a real Mac-side connection.

These changes have focused unit coverage, but this document must not claim a
new live PASS until the exact #9/#18/#19 commands are run against a freshly
built guest. Until then, the historical FAIL rows and tally remain the
audit record rather than a statement about the current implementation.

### Live re-run 2026-08-03 against the rebuilt guest

Those commands have now been run against a freshly built and freshly
**staged** guest. Full evidence in [`audit/ENGINE-MATRIX.md`](audit/ENGINE-MATRIX.md).
Two staging defects had to be fixed first: `mise run guest-image` alone never
reaches the booted VM (the daemon boots `runtime/current`, staged from the app
bundle), and the runtime installer could not replace a payload under an
unchanged version because it verified an installed release against its own
manifest rather than the signed bundle's. Any earlier "rebuilt guest" result
should be treated as suspect for that reason.

- **#9 `/tmp` bind sources — now PASS.** `-v /tmp/morbbind:/x` and
  `-v /private/tmp/morbbind:/x` return the identical host file
  (`HOST-PRIVATE-TMP-MARKER`), and `-v $HOME/...` reads and writes real host
  content. The alias works.
- **#18/#19 host aliases — PARTIAL, not PASS.** The bare name still does not
  resolve: `docker run --rm alpine getent hosts host.docker.internal` exits 2
  and `wget` reports `bad address`. With
  `--add-host host.docker.internal:host-gateway` it resolves to `192.168.64.1`
  and a real Mac-side service answers. So the gateway plumbing is proven, but
  the automatic Docker-Desktop-compatible alias is still absent. The #18/#19
  rows stay **FAIL** for the documented behaviour they test.

**A new and more serious finding superseded part of #9's reasoning — and has
since been fixed.** The `/etc` and `/var` bind guards existed and were correct,
but they never ran for ordinary CLI traffic: `DockerProxy` inspected only the
*first* HTTP request on each client connection and then spliced the connection
raw, so the Docker CLI's keep-alive reuse meant `POST /containers/create` was
almost always un-inspected. Proven by sending one identical create body two
ways — HTTP 400 (rejected) as the first request on a fresh connection, HTTP 201
(accepted) as the second request on a keep-alive connection. Consequently
`-v /etc/hosts:/x` silently served the **guest's** file
(`e3998dbe…` vs the Mac's `c7dd0e2e…`), `-v /var/log:/x` silently served the
guest's directory, container writes to those paths were silently lost, and the
same bypass disabled the create-time port-publication preflight. This was
fail-open and was the top open item.

**Fixed and verified live.** The proxy now frames every HTTP/1.1 request on a
connection — `Content-Length`, chunked, pipelined, bodyless — and only splices
raw once the Engine has actually hijacked the connection (`101`, or a `2xx`
carrying Docker's raw/multiplexed stream type). A body too large to inspect is
refused with a Docker-shaped `400` rather than relayed unchecked, as are the
ambiguous framings that would let a request smuggle past admission. The
original experiment now returns **identical 400s on both framings**, and the
full bind-mount and port matrices were re-run through the real CLI with no
streaming regression (`logs -f`, `exec -it`, `attach`, `cp`, `events`,
BuildKit, the 3-service compose fixture). Design, evidence and residual risk:
**`docs/audit/PROXY-FRAMING.md`**; status rows in `docs/MASTER-PLAN.md` §1.0
and §1.3.

### Current delivery state (not a replacement for this audit)

The current checkout also packages Buildx and implements a consented
per-user Docker context/direct-discovery path. Those changes address the
historical #13 and #17 root causes in source, but have not passed the
new-account release evidence in
[`clean-profile-acceptance.md`](clean-profile-acceptance.md). They are therefore
**implemented pending clean-profile verification**, not retrospective PASS
results. See [`drop-in-delivery-plan.md`](drop-in-delivery-plan.md) for the
ordered release blockers and explicit non-claims.

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
| 20 | Ecosystem | `--network host` | `docker run --network host nginx:alpine`; repeat with `-p 8080:80` and `-P`; verify guest reachability, `docker inspect`, CLI warning, and that no Mac listener was created | **GUEST-ONLY (source corrected; runtime re-verification pending guest rebuild)** | `--network host` shares the Linux VM's host namespace, never macOS's. Morbstack intentionally creates no Mac listener for host-network containers, including declared `EXPOSE` ports; the proxy leaves `-p` and `-P` untouched so Moby discards them with Docker's standard warning. This prevents a started container from implying a fabricated Mac-host mapping. The prior opt-in bridge and listener-probe protocol were removed; execute the matrix against the rebuilt guest before calling the behavior verified. |
| 21 | Ecosystem | Docker-in-Docker via `-v /var/run/docker.sock:/var/run/docker.sock` | `docker run -v /var/run/docker.sock:/var/run/docker.sock docker:cli docker ps` | **PASS** | Worked perfectly — `docker:cli` inside the container talked straight to the guest's real dockerd through the bind-mounted socket, `docker version --format '{{.Server.Version}}'` printed `29.7.1`. |
| 22 | Ecosystem | Container-to-host connections | HTTP server bound on the Mac; curl from inside a container at various candidate addresses | **PARTIAL** | The container's own bridge gateway (`172.17.0.1`, from `ip route`) is a dead end. But the **guest VM's own gateway IP** (`192.168.64.1`, the address in `/etc/resolv.conf`'s `nameserver` line) *does* reach a Mac-side listener. So container→host connectivity is technically possible today, just not through any documented or stable hostname — a user would have to know to try the VM gateway IP, which isn't exposed as `host.docker.internal` or anything else discoverable. |
| 23 | Ecosystem | `docker context` integration | `docker context create morbstack --docker host=unix://...`, `docker context use morbstack`, `docker ps`/`docker info` with no `DOCKER_HOST` | **PASS** | Context creation, switching, and use all worked exactly like any other Docker host context. This is the correct workaround for #17. |
| 24 | Restart/persistence | Restart policy (`unless-stopped`) survives `morb stop` + `morb start` | container running with `--restart unless-stopped`, `marker.txt` written to a named volume, then `morb stop && morb start` | **PASS** | `morb stop` (10.7s) then `morb start` (VM up instantly, docker engine ready ~1-2s later) — the container came back `Up` on its own, no manual restart needed. |
| 25 | Restart/persistence | Images and named-volume data survive the same cycle | `docker images`, `docker run --rm -v paritydata:/data alpine cat /data/marker.txt` after the restart | **PASS** | Both `alpine:3.20` and `hello-world` images were still present; the volume still contained `persisted-data` written before the stop. |
| 26 | Failure modes | Disk full | Fresh 2 GiB disk (via `mkdisk.sh 2`), filled with `dd` from inside a container | **PASS** | Correct, standard Linux `dd: error writing '/fillfile': No space left on device`. The daemon stayed fully responsive afterward — a new `--rm` container ran fine (its writable layer's removal freed the space), a `docker pull` of a small image succeeded, `docker info` kept answering. No hang, no corruption. |
| 27 | Failure modes | Port already bound on the Mac | Python `http.server` holding `127.0.0.1:19999`, then `docker run -p 19999:80 nginx` | **Historical PARTIAL; source correction requires current-runtime acceptance** | The audit observed a successful create/start with an unavailable Mac forward. The recognized fixed TCP/UDP path now first preflights and then retains the real host listener before Docker sees the create request. Either an occupied endpoint or a race at the actual reservation returns the Docker-shaped `Bind for 0.0.0.0:19999/tcp failed: port is already allocated` failure instead of allowing a misleading successful create/start. Dynamic allocation, UDP, and restart keep their existing atomic lease paths. This lane did not run the current guest image, so do not promote it to a runtime PASS without that acceptance. |
| 28 | Failure modes | Image that does not exist | `docker pull nonexistent-image-abc123xyz`, `docker run this-image-does-not-exist-anywhere:v1` | **PASS** | Byte-identical to real Docker Hub errors (`pull access denied ... repository does not exist or may require 'docker login'`) — this is literally hitting the real registry, so it can't help but match. |
| 29 | Failure modes | OOM | `docker run --memory=16m --memory-swap=16m alpine` allocating >16MB | **PASS** | `OOMKilled=true`, `ExitCode=137`, `Status=exited` — exactly the standard Docker contract. The `WARNING: Your kernel does not support swap limit capabilities` message also matches what real Docker Desktop's own Linux VM prints (no swap accounting there either) — not a Morbstack-specific defect. |
| 30 | Core CLI | Attached non-TTY `docker exec`, including final status | `POST /containers/{id}/exec` → attached `POST /exec/{id}/start` → `GET /exec/{id}/json` | **SOURCE-COVERED; live acceptance pending** | The proxy keeps create and inspect as ordinary HTTP/1.1 requests on a reusable connection. It nominates only `exec/{id}/start` for a response-led hijack; a `101` or Docker raw/multiplexed `2xx` then splices the stream untouched. Focused socket-pair coverage proves non-TTY stdout/stderr frames arrive byte-for-byte and that half-closing stdin does not truncate final output before the caller reads `ExitCode`. Run the real CLI matrix against the rebuilt guest before promoting this to PASS. |
| 31 | Core CLI | `docker cp` archive upload and download | chunked `PUT /containers/{id}/archive` → `GET /containers/{id}/archive` → next keep-alive request | **SOURCE-COVERED; live acceptance pending** | The proxy does not inspect, decode, re-chunk, or mutate archive requests or responses. Focused socket-pair coverage proves a chunked tar upload, `application/x-tar` chunked download, `X-Docker-Container-Path-Stat`, and a following request all traverse byte-for-byte on one reusable connection. Run copy-in and copy-out with file, directory, ownership/mode, symlink, compressed-tar, path-error, and cancellation fixtures against the rebuilt guest before promoting this to PASS. |
| 32 | Core CLI | Attach, resize, and follow logs transport | attached `POST /containers/{id}/attach`, `POST /containers/{id}/resize`, `GET /containers/{id}/logs?follow=1` | **SOURCE-COVERED; live acceptance pending** | Only the documented POST attach route (and GET websocket sibling) can enter response-confirmed raw mode. Focused socket-pair coverage proves a non-TTY attach drains final multiplexed stdout/stderr after stdin half-close; resize returns as ordinary framed HTTP and preserves the next request; `logs --follow` remains an unfinished ordinary HTTP response with no synthetic upgrade or Content-Type. Run real TTY/non-TTY attach, resize during an attached session, log follow/cancellation, websocket attach, and error/reuse fixtures against the rebuilt guest before promoting this to PASS. |
| 33 | Core CLI | Docker events stream | `GET /events` with `since`/`until`/filters; cancellation and reconnect | **SOURCE-COVERED; live acceptance pending** | Events remain ordinary `application/json` HTTP responses, never hijack candidates. Focused socket-pair coverage proves chunked JSON reaches the client byte-for-byte, a terminal `until` stream leaves the keep-alive request loop usable, and client cancellation half-closes the Engine side without parsing or buffering event data. Run real filtered live events, historical `since`, bounded `until`, daemon restart/disconnect, Ctrl-C cancellation, and reconnect fixtures against the rebuilt guest before promoting this to PASS. |
| 34 | Core CLI | Docker image pull stream | `POST /images/create?fromImage=…&tag=…`; progress/error stream and cancellation | **SOURCE-COVERED; live acceptance pending** | Image pull remains an ordinary HTTP stream, never a hijack candidate. Focused socket-pair coverage proves percent-escaped repository query values, `X-Registry-Auth`, chunked progress JSON, and a terminal in-stream error record reach the correct peer byte-for-byte; terminal completion preserves keep-alive reuse and cancelling the pull half-closes the Engine side. Run real public/private pull, digest/tag/reference edge cases, auth helper, cancellation, daemon disconnect, and import (`fromSrc=-`) fixtures against the rebuilt guest before promoting this to PASS. |

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

**#27 — fixed and bounded dynamic TCP/UDP host-port admission are synchronous on the
recognized path.**
For an ordinary fixed or bounded dynamic, loopback-supported TCP/IPv4-UDP create,
the host retains a real listener/socket before forwarding create, associates it from
a bounded normal create response, and activates that same endpoint before an exact
start `204` reaches the client. This removes the prior success-with-no-listener race
without changing ordinary fixed Docker request/response bytes. The claim is
intentionally narrower than complete Docker Desktop parity: a bounded Phase 1
transforms a recognized omitted, empty, or exact-zero TCP/UDP `HostPort` into a held
Mac endpoint before the guest sees it, but it still needs a live VM run before it can
count as verified parity. Raw dynamic host-port range allocation, opaque/chunked
framing, name-based/nonstandard start handoff, and lease survival across VM/daemon
shutdown still need their own allocation or lifecycle contract. `-P` has a separate
source-level, version-pinned Moby/guest/host allocator path that still requires guest
image inclusion and live acceptance; it is not counted as verified parity. The exact
dynamic transaction and unsupported boundary are in
[`dynamic-port-allocation.md`](dynamic-port-allocation.md); no event-derived endpoint
is counted as synchronous support.

*Update (proxy framing).* Two of the caveats above have moved. This admission path was
one of the guards silently defeated by the keep-alive bypass described earlier in this
document, so its "recognized path" only ever applied to a create that happened to be
the first request on its connection — which, for the `docker` CLI, it never is. It now
applies to every create. The **chunked framing** exclusion is also gone: a chunked
create body is decoded for inspection and relayed byte-for-byte, and the bounded
dynamic hold-back runs inside the connection relay rather than only at connection
setup. The **live VM run** has now happened: fixed (`-p 8099:80`), bounded dynamic
(`-p 80` → `0.0.0.0:53119`), `-P` (`0.0.0.0:32768`), and the
`-p 8080:80 -p 8080:81` ambiguity refusal were all exercised through the real CLI —
see `docs/audit/PROXY-FRAMING.md` §3.3. Lease survival across VM/daemon shutdown and
raw host-port range allocation remain open.

## Historical priority list — what the original audit identified

1. **Re-run #9, #18 and #19 against the current guest.** The old failures
   have targeted implementations now; a real VM run is the only evidence
   strong enough to upgrade their results.
2. **Ship the `docker-buildx` CLI plugin.** This was the highest-leverage
   source gap at the audit revision: the guest-side BuildKit was already fully
   functional (#14), but a stock client had no plugin. The current bundle and
   installer now carry it; clean-profile CP-01/02/04 evidence remains required.
3. **Zero-config daemon discovery.** This was the old discovery gap. The
   current installer has a conflict-preserving context and per-user discovery
   socket path; CP-02/03/05 plus normal Testcontainers/IDE discovery must prove
   it before it is called zero-config parity.
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
