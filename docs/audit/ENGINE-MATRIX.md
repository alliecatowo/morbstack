# Engine matrix — first full runtime run against the rebuilt guest

Date: 2026-08-03. Host: macOS 26.4 (Darwin 25.4.0), Apple Silicon, 8 vCPU / 8192 MiB VM.

This is the first time most of this surface has ever been **executed**. Until today the
guest side had never been compiled or run. Every row below records the exact command, the
exact output, and a verdict. The final section separates what is now **proven at runtime**
from what remains **source-only**.

Test harness used for every Docker row:

```sh
export DOCKER_CONFIG=<scratch>/dockercfg          # never ~/.docker (credsStore hangs the CLI)
export DOCKER_HOST=unix:///Users/allie/.morbstack/run/docker.sock
PATH=dist/Morbstack.app/Contents/Resources/host-bin:$PATH
```

`docker compose` / `docker buildx` were symlinked into `$DOCKER_CONFIG/cli-plugins` from
`dist/Morbstack.app/Contents/Resources/host-bin/cli-plugins/`.

---

## 0. Why nothing guest-side had been taking effect (root cause of the `-P` failure)

`docker run -P` failed with `vsock connect to port 2379 failed: Connection reset by peer`.
The guest console log showed only three listeners (1024, 2375, 2376) and no
`publish-all allocator listening` line and no `FATAL` line.

**Settled first:** `spawn_publish_all_allocator` *does* log on success —
`guest/morbinit/src/publish_all.rs:57-60` — and logs `FATAL` on error
(`guest/morbinit/src/main.rs:406`). The same is true of the datagram dialer, listener probe
and live-share receiver. Their silence was therefore **not** expected behaviour: it meant the
code was not present in the running guest at all.

It was not. Two independent defects, both now fixed:

### 0a. `mise run guest-image` has no runtime effect on its own

- `scripts/mkinitramfs.sh:38-40` writes `~/.morbstack/data/kernel/initrd.img`.
- `MorbPaths.initrd` (`mac/Sources/MorbstackKit/Paths.swift:183-190`) **prefers**
  `~/.morbstack/data/runtime/current/kernel/initrd.img` whenever it is readable, and only
  falls back to `data/kernel` otherwise.
- `runtime/current` is populated by `Daemon.swift:184` →
  `RuntimeArtifactStore.installBundledRuntimeIfPresent()`, which stages the runtime **from the
  signed app bundle** (`dist/Morbstack.app/Contents/Resources/runtime/<version>/`), which is
  itself written by `mise run app` → `scripts/package-runtime-artifacts.sh`.

So the real dev loop is `guest-image` **then** `app` **then** restart. Running `guest-image`
alone changes nothing the VM boots, silently. The app bundle in `dist/` was assembled at 14:54,
before the 15:46 guest rebuild, so the VM was booting an initrd from 04:18 that predated the
publish-all feature entirely.

Note the task headers actively mislead here: `mise-tasks/app` says "This task does NOT rebuild
the guest image. Guest-side changes need `mise run guest-image`", which implies `guest-image`
is sufficient. It is not.

### 0b. The runtime installer could never replace a payload under an unchanged version

Even after rebuilding the bundle, the daemon still booted the stale initrd. `install(_:)` in
`mac/Sources/MorbstackKit/RuntimeArtifacts.swift` short-circuited on
`fileManager.fileExists(atPath: destination.path)` and then called
`verifyInstalledRelease(at: destination, ...)`, which loads the **installed** `manifest.json`
and checks the installed files against it. That is self-referential: it proves internal
consistency, never agreement with the signed bundle. A self-consistent stale (or tampered)
release therefore passes forever.

Consequences, in ascending severity:

1. In development the runtime version never changes, so the guest image was **frozen
   permanently** after the first stage — every subsequent rebuild silently ignored.
2. A release respin under the same version string would never reach users.
3. `~/.morbstack/data/runtime` is user-writable. An attacker who rewrites both a payload and
   its `manifest.json` keeps a self-consistent-but-wrong runtime that the signed bundle will
   never correct.

**Fix applied** (`RuntimeArtifacts.swift`): when the version directory already exists, verify
it against the **bundle's** manifest digests, not its own. On mismatch, stage the correct bytes
and supersede the old directory with a single atomic `renamex_np(..., RENAME_SWAP)` so
`current` never observes a missing version directory. `Daemon.swift` now logs the event
explicitly rather than silently:

```
runtime 0.1.0-m0 replaced (the installed payload did not match this bundle) at …/runtime/0.1.0-m0
```

Verified: staged initrd digest moved from `e82ff437…` to `0994c8f0…` (matching the rebuilt
`data/kernel/initrd.img`), and the guest then announced all seven listeners:

```
[  170ms] control server listening on vsock port 1024
[  170ms] docker proxy listening on vsock port 2375 -> /var/run/docker.sock
[  170ms] stream dialer listening on vsock port 2376
[  170ms] datagram dialer listening on vsock port 2378
[  171ms] listener probe listening on vsock port 2380
[  171ms] live-share receiver listening on vsock port 2381 for 3 mounted share(s)
[  171ms] publish-all allocator listening on vsock port 2379 and /run/morbstack/publish-all.sock
```

**Both of these are silent-staleness bugs. That silence is what cost the previous round of
results, and 0b is the one that would have kept costing them.**

---

## 1. `docker run -P` — PARTIAL

### First run — PASS

```
$ docker run -d --name ptest -P nginx:alpine
20f1c341d72e…
$ docker port ptest
80/tcp -> 0.0.0.0:32768
80/tcp -> [::]:32768
$ docker inspect ptest --format '{{json .NetworkSettings.Ports}}'
{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"32768"},{"HostIp":"::","HostPort":"32768"}]}
$ docker inspect nginx:alpine --format '{{json .Config.ExposedPorts}}'
{"80/tcp":{}}
$ curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://127.0.0.1:32768/
HTTP 200 in 0.003008s
```

Effective EXPOSE set, `docker port`, and `docker inspect` all agree, and the port genuinely
answers from the Mac in 3 ms.

### Several EXPOSEd ports — PASS

Image with `EXPOSE 80`, `EXPOSE 443`, `EXPOSE 8125/udp`:

```
80/tcp   -> 0.0.0.0:32768
443/tcp  -> 0.0.0.0:32769
8125/udp -> 0.0.0.0:32768
```

Allocated as one transaction; `inspect` agrees exactly. UDP 8125 reusing 32768 is correct —
TCP and UDP are separate port namespaces.

### No EXPOSEd ports — PASS

`docker run -d -P alpine sleep 60` → `docker port` empty, container `running`. Correct.

### stop/start and restart — FAIL

```
$ docker stop ptest && docker start ptest
Error response from daemon: failed to set up container networking:
  Morbstack host port allocator: host allocator disconnected

$ docker restart ptest
Error response from daemon: Cannot restart container ptest: failed to set up container
  networking: Morbstack host port allocator: host allocator is not registered
```

The mapping does **not** survive stop/start. Addressing the container by **full 64-hex ID**
rather than name fails identically:

```
$ docker stop <full-id> && docker start <full-id>
Error response from daemon: … Morbstack host port allocator: host allocator disconnected
```

This refutes the hypothesis that the gap is a name-vs-ID resolution problem in
`DockerProxy.preflightThenRelay`'s `isFullContainerID` gating — the full-ID path is broken too.

The observable cause is that the durable host session dies immediately after the *successful*
first allocation. Daemon log, 6 ms after the forward is added:

```
16:00:06.079 INFO  port forward added: 32768 -> ptest:80/tcp on 0.0.0.0:32768
16:00:06.085 WARN  publish-all allocator for 20f1c341d72e failed: could not read the guest publish-all allocator
```

`could not read the guest publish-all allocator` is thrown where `read == 1` fails in
`PublishAllPortAllocator.readLine` — i.e. EOF on a session that is supposed to stay live for
the container's lifetime (`remainsAvailableForRestartPolicy: true`, 86400 s read timeout).
The guest keeps that now-dead fd in its `sessions` map, so the next start finds it and reports
`host allocator disconnected`; the guest then evicts the entry
(`guest/morbinit/src/publish_all.rs:199-201`), so the start after that waits out
`HOST_REGISTRATION_WAIT` (45 s) and reports `host allocator is not registered`. The two
different messages in sequence are fully explained by this.

**The exact trigger that closes the socket is not yet proven** and needs an instrumented repro;
static reading did not settle it. A confirmed secondary defect regardless of trigger:
`Session.complete(succeeded: false)` unconditionally calls `forwarder.abandon(lease, …)`, which
tears down a listener for a container whose allocation dockerd had *already* accepted.

---

## 2. Explicit `-p`, every form — PASS

| Form | Result |
|---|---|
| `-p 8080:80` | `80/tcp -> 0.0.0.0:8080` + `[::]:8080`; `curl` HTTP 200 |
| `-p 127.0.0.1:8081:80` | `80/tcp -> 127.0.0.1:8081` only (correctly loopback-scoped); `curl` HTTP 200 |
| `-p 8090-8092:80` | allocated `8090` — correct Docker range semantics |
| `-p 9999:9999/udp` | see §3 |

Ambiguity case, and the host-port conflict case:

```
$ docker run -d -p 9100:80 -p 9100:81 nginx:alpine
docker: Error response from daemon: failed to set up container networking: driver failed
programming external connectivity on endpoint pamb (…): Bind for 0.0.0.0:9100 failed:
port is already allocated

$ docker run -d -p 8080:80 nginx:alpine     # 8080 already held by another container
docker: Error response from daemon: driver failed programming external connectivity:
Bind for local loopback port 8080/tcp failed: port is already allocated
```

Both are correct and explained. The second is Morbstack's own preflight message, confirming
the recently fixed preflight path reports the right thing.

---

## 3. UDP publishing — PASS (first execution ever)

```
$ docker run -d --name udptest -p 9999:9999/udp alpine sh -c 'nc -u -l -p 9999'
$ docker port udptest
9999/udp -> 0.0.0.0:9999
9999/udp -> [::]:9999
$ echo "hello-from-mac" | nc -u -w 2 127.0.0.1 9999
$ docker logs udptest
hello-from-mac
```

A datagram genuinely round-trips from the Mac into the container. `inspect` agrees.

---

## 4. Bind mounts — **FAIL (critical): silent data substitution and silent data loss**

### What works — PASS

| Bind | Result |
|---|---|
| `-v /private/tmp/morbbind:/x` | reads real host file `HOST-PRIVATE-TMP-MARKER` |
| `-v /tmp/morbbind:/x` (bare `/tmp`) | reads the same real host file — the `/tmp` → `/private/tmp` alias works |
| `-v $HOME/morbbind-home:/x` | reads real host file `HOST-HOME-MARKER` |
| write-through to `/private/tmp` | container writes `written.txt`; host reads `WROTE-FROM-CONTAINER` |

### What is broken — FAIL

`/etc`, `/var`, and every other unshared root are **silently served from the guest filesystem**,
with no error and no warning:

```
$ shasum -a 256 /etc/hosts                                  # the Mac's file
c7dd0e2ed261ce76d76f852596c5b54026b9a894fa481381ffd399b556c0e2da
$ docker run --rm -v /etc/hosts:/x alpine sha256sum /x       # what the container gets
e3998dbe02b51dada33de87ae43d18a93ab6915b9e34f5a751bf2b9b25a55492  /x
```

```
$ ls /var/log | head -3            $ docker run --rm -v /var/log:/x alpine ls -a /x
CoreDuet                           .
DiagnosticMessages                 ..
Native Instruments
```

```
$ docker run --rm -v /etc:/x alpine ls /x
ssl1.1  sysctl.conf  sysctl.d  udhcpc          # alpine/busybox artifacts — the GUEST's /etc
```

`-v /Library:/x` and `-v /Applications:/x` behave the same way: an empty guest-local directory,
silently created, no rejection.

**Writes to these paths are silently lost.** A container writing `/x/ghost.txt` under
`-v /var/log:/x` succeeds and can read it back, but the Mac never receives it — and a *later,
unrelated* container mounting `/var/log` still sees `ghost.txt`, proving containers are
mutating the guest's own `/var/log` while believing they are on the host.

Symlink traversal from a shared root to an unshared target (`/private/tmp/escape -> /etc`)
also resolves to the **guest's** `/etc`. There is no host escape, but the substitution is
silent.

### Root cause — the entire preflight layer is bypassed on keep-alive connections

`DockerBindMountPreflight` is **correct**. Sent as the first request on a fresh connection, it
rejects exactly as designed:

```
$ curl --unix-socket …/docker.sock -X POST '…/containers/create?name=rawbind1' \
    -d '{"Image":"alpine","HostConfig":{"Binds":["/etc/hosts:/x"]}}'
{"message":"invalid mount config for type 'bind': bind source path uses the macOS /etc alias,
 but /etc is a guest system path; use the explicit /private/etc source path after sharing it"}
HTTP=400
```

The identical body, sent as the **second** request on the same keep-alive connection, is
accepted:

```
$ curl --unix-socket …/docker.sock '…/_ping' --next --unix-socket …/docker.sock \
    -X POST '…/containers/create?name=rawbind3' \
    -d '{"Image":"alpine","HostConfig":{"Binds":["/etc/hosts:/x"]}}'
{"Id":"b6483895da50…","Warnings":[…]}
HTTP=201
```

`DockerProxy.preflightThenRelay` calls `inspectDockerRequest(in: clientFD)` **once per accepted
connection** (`DockerProxy.swift:153-156`) and then splices the connection raw for its entire
lifetime. Every request after the first is relayed to dockerd uninspected.

The Docker CLI pings/negotiates before issuing the real call and reuses the connection, so in
normal use **the security-relevant `POST /containers/create` is essentially always the
un-inspected second request**. This is confirmed in the daemon log: port leases for CLI-created
containers appear as `reserved fixed-port lease 9500/tcp for Docker start` via the
stopped-container recovery path, never as `for Docker create` — the create was never seen.

This single defect disables **both** bind-mount admission and the port-publication preflight
for ordinary CLI traffic. It is fail-open. It is the most serious finding in this run.

Correct fix: the proxy must parse each client connection as a stream of HTTP/1.1 requests and
preflight every one. A smaller interim mitigation is to force one request per connection, but
that interacts with hijacked/streaming endpoints (`logs -f`, `exec`, `attach`, the event
stream) and should not be landed without care. **Not attempted in this session** — the blast
radius is too large to land unreviewed.

Also worth noting: `DockerBindMountPreflight.inspectContainerCreate` returns `.allowed` when the
body fails to parse as JSON (`DockerBindMountPreflight.swift:49-51`) — fail-open in a
fail-closed component.

---

## 5. `host.docker.internal` — PARTIAL

Not provided automatically. A container's `/etc/hosts` contains no such entry and:

```
$ docker run --rm alpine getent hosts host.docker.internal
(exit 2)
$ docker run --rm alpine wget -qO- http://host.docker.internal:8899/
wget: bad address 'host.docker.internal:8899'
```

With the explicit gateway alias it resolves and connects to a real service on the Mac:

```
$ docker run --rm --add-host host.docker.internal:host-gateway alpine \
    sh -c 'getent hosts host.docker.internal; wget -qO- http://host.docker.internal:8899/index.html'
192.168.64.1      host.docker.internal
MAC-HTTP-OK
```

The plumbing works; the Docker-Desktop-compatible automatic alias is missing. This is a real
drop-in parity gap — many Compose files and dev setups rely on the bare name.

---

## 6. `morb disk grow` — FAIL

Refused correctly while the VM is running:

```
$ morb disk grow 72
morb: the VM is running; stop it completely before growing its disk.
```

…but the refusal **still mutated the configured capacity** to 72 GiB, leaving
`resize increase-requires-guest-resize` against an unchanged 64 GiB image. A rejected operation
should not have persisted anything.

Stopped, the grow fails on a host/guest protocol mismatch:

```
$ morb stop && morb disk grow 72
morb: guest did not provide a disk-resize proof within 40s (last error:
DecodingError.keyNotFound: Key 'device' not found in keyed decoding container …)
```

The guest's resize-proof reply does not carry the `device` key the host decoder requires — a
decode contract mismatch, plausibly exposed by the guest rebuild.

The image file **was** nevertheless expanded — `current 77309411328 bytes` (72 GiB), reported as
`matches-configuration` — while the guest filesystem was **not**:

```
$ docker run --rm -v /var/lib/docker:/probe alpine df -h /probe
/dev/vda    62.4G   2.1G   57.2G   3%  /probe        # unchanged, before and after
```

So the feature is non-functional end-to-end: it errors, the image grows anyway, and the guest
never sees the space. It did fail closed in the sense that nothing was corrupted and it never
shrank, but the host image and the reported state now disagree with the guest.

---

## 7. Compose 3-service regression fixture — PASS (no regression)

`docs/audit/FUNCTIONAL-AUDIT.md` fixture, verbatim, at `/private/tmp/morbaudit-stack`.

```
$ docker compose up -d --build
 Container morbaudit-db-1   Healthy
 Container morbaudit-api-1  Starting → Healthy
 Container morbaudit-web-1  Started
### TOTAL: 21s
```

| Assertion | Evidence |
|---|---|
| Healthcheck-chained `depends_on` | `db Healthy` → `api Healthy` → `web Started`, in order |
| All services healthy | `morbaudit-{api,db,web}-1  Up … (healthy)` |
| Bind mount served | `curl :18100` → `<h1>bind-mount-v1</h1>` |
| `environment:` delivered | `curl :18101` → `{"greeting": "hello-from-compose", "db": "db"}` |
| Named volume | `morbaudit_dbdata` created |
| `secrets:` functional | `psql` via `/run/secrets/pg_password` returned `1` |

21 s vs the 12.9 s pre-rebuild baseline; both included a BuildKit build, so this is slower but
the workload was not identical (cold layer state). No functional regression.

---

## 8. BuildKit / buildx — PASS

```
$ docker build -t morbtest:1 .
#8 writing image sha256:8d0d28301d36… done
#8 naming to docker.io/library/morbtest:1 done
$ docker run --rm morbtest:1
built-by-buildkit
COPY-WORKS
```

`RUN` and `COPY` both correct. `docker buildx ls` shows two working builders (`default`,
`morbstack`), BuildKit **v0.32.0**, `linux/arm64`.

Wart: the build prints `View build details: docker-desktop://dashboard/build/…`, pointing users
at Docker Desktop from a product that replaces it.

---

## 9. Core parity sweep — PASS

| Command | Result |
|---|---|
| `docker exec` | `EXEC-OK`, correct hostname |
| `docker logs --tail` | correct nginx access line |
| `docker logs -f` | streams |
| `docker cp` host→container | `CP-TO-CONTAINER` readable inside |
| `docker cp` container→host | round-trips identically |
| `docker stats --no-stream` | live CPU/mem for all containers |
| volumes | named volume write + readback across two containers |
| networks + DNS | user network; `wget http://netA/` resolves and returns HTML |
| `docker context ls` | `morbstack` context present, endpoint correct |

`docker context` emits the standard warning that `DOCKER_HOST` overrides the active context —
expected, since the harness sets `DOCKER_HOST` deliberately.

---

## 10. Boot time and idle cost — PASS (improved)

```
### cold boot to first successful docker call: 1.79s
16:20:46.575 vm state -> starting
16:20:48.263 guest ready 1.69s after bring-up (guest uptime 509ms, docker data on disk)
```

Better than the 3.0 s claim, measured to a *successful Docker API call*, not just VM state.

Idle after 20 s quiescence: **0.0 % CPU, 23 MB RSS** for `morbstackd`. Low idle survived the
rebuild. (VM guest memory is not attributed to host RSS under Virtualization.framework, so
23 MB is the host-side footprint only.)

---

## Proven at runtime vs. source-only

### Proven to work at runtime

- Guest boots the rebuilt initramfs and brings up **all seven** vsock listeners.
- `docker run -P` first start: full EXPOSE expansion, single-transaction allocation across
  multiple TCP+UDP ports, `port`/`inspect` agreement, real traffic from the Mac.
- Explicit `-p` in all tested forms, including loopback scoping and ranges.
- **UDP publishing**, end to end, for the first time.
- Bind mounts **under the shared roots** (`/Users`, `/private/tmp`, and bare `/tmp` via the
  alias), read and write.
- Compose: build + healthcheck-chained `depends_on` + named volume + bind mount +
  `environment:` + `secrets:`.
- BuildKit builds and buildx availability.
- exec / logs / logs -f / cp both ways / stats / volumes / networks + DNS / context.
- 1.79 s cold boot, 0 % idle CPU.
- `host.docker.internal` **via `--add-host …:host-gateway`**.

### Source-only — implemented but NOT effective at runtime

- **`DockerBindMountPreflight` in its entirety.** The logic is correct and unit-tested, and it
  works on a fresh connection, but the Docker CLI's keep-alive reuse means it is bypassed in
  practice. Do not treat the `/etc` and `/var` guards as shipped protection.
- **`DockerPortPublicationPreflight` on the create path**, for the same reason — CLI-created
  containers are recovered at start, never inspected at create.
- **Publish-all across restarts.** The durable-session design exists but no restart path
  succeeds.
- **`morb disk grow` guest-side resize proof** — the host decoder and guest reply disagree.

### Not tested this run

- Engine restart-policy driven restarts of a `-P` container (blocked by §1).
- Compose against the app's Stacks route (backend-only session).
- inotify/file-watch propagation into containers.
- LAN (non-loopback) port publishing.

---

## Blunt summary

The guest is real now and most of the surface genuinely works — including several things that
had never once executed. But two findings are serious and neither is cosmetic:

1. **The Docker API preflight layer is bypassed for ordinary CLI traffic** because only the
   first request on each connection is inspected. This silently disables bind-mount admission,
   so `-v /etc/hosts:/x` still serves the guest's file and writes to unshared paths still
   vanish. The highest-severity open item is **not** fixed in practice, even though the code
   that would fix it is present and correct.
2. **`docker run -P` cannot survive a restart.** First run is solid; every subsequent start
   fails.

Plus `morb disk grow` is broken end to end, and `host.docker.internal` is not automatic.
