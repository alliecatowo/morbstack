# Docker proxy request framing — closing the fail-open preflight

Every admission check Morbstack owns used to be skipped for essentially all real
traffic. This document records the defect, the design that replaced it, and the
verification that the replacement holds — including the streaming paths it would have
been easy to break while fixing it.

Status: **PASS (PROVABLE NOW)**. Every request on every connection is inspected; the
bind-mount and port matrices were re-run live against the rebuilt daemon; no streaming
path regressed; `mise run check` is green at 764 Swift / 217 Rust.

---

## 1. The defect

`DockerProxy.preflightThenRelay(clientFD:)` performed one bounded `MSG_PEEK` at the
head of a newly accepted connection, classified whatever it found, and then handed
both descriptors to `FDRelay`, which splices bytes opaquely for the rest of the
connection's life.

That is correct for exactly one request. The `docker` CLI opens a connection, issues
`GET /_ping`, and then **reuses that same connection** for the work. So the request
that gets inspected is the ping, and `POST /containers/create` — the only request the
proxy actually needs to see — is spliced through unread.

`DockerProxy.swift:24` already described the peek as "best-effort" for large or
chunked bodies. What nobody caught is that keep-alive turns "best-effort" into "never",
and a fail-open admission check is not a best-effort admission check. It is an absent
one.

### Reproduction, before the fix

One identical create body sent two ways over `~/.morbstack/run/docker.sock`
(`scratchpad/keepalive_probe.py`; the body is
`{"Image":"alpine:3.20","Cmd":["true"],"HostConfig":{"Binds":["/etc/hosts:/x"]}}`):

```
SAME create body, two framings:
  [fresh   ] create   : HTTP/1.1 400 Bad Request
  [fresh   ] body     : {"message":"invalid mount config for type 'bind': bind source path uses
                        the macOS /etc alias, but /etc is a guest system path; use the explicit
                        /private/etc source path after sharing it"}
  [keepalive] preface  : HTTP/1.1 200 OK
  [keepalive] create   : HTTP/1.1 201 Created
  [keepalive] body     : {"Id":"9e8457c0fd4a4f33891e9f4eb1aab8e982d1325a872d8526691234cc21618f56",
                        "Warnings":[]}

VERDICTS DIFFER  <-- preflight bypass
```

The second form is what the CLI does. The container was created, and its `/x` was the
**guest's** `/etc/hosts`, not the Mac's.

### What that cost

* `DockerBindMountPreflight` never ran, so `-v /etc/hosts:/x` served guest content,
  `/var/log` and `/Library` silently became guest directories, and **container writes
  to them vanished** — silent data substitution and silent data loss, the worst pair of
  failure modes available.
* `DockerPortPublicationPreflight` never ran either, including the
  `-p 8080:80 -p 8080:81` ambiguity check that had just been fixed.

Both guards were correct and unit-tested the whole time. Nothing tested that they were
*reached*, which is exactly why this shipped.

---

## 2. The design

The fix is a real HTTP/1.1 framing layer in front of the splice, in two new files:

| File | Role |
| --- | --- |
| `mac/Sources/MorbstackKit/DockerRequestFraming.swift` | `DockerRequestFramer` — pure, descriptor-free framing; hijack classification; head rewriting; the Engine-shaped error document |
| `mac/Sources/MorbstackKit/DockerFramedRelay.swift` | `DockerFramedRelay` — the two-worker connection, and the `DockerRequestAdmissionPolicy` protocol `DockerProxy` implements |

`DockerProxy` keeps the policy and loses the plumbing. `DockerDynamicCreateTransaction`
was retired: its bounded-create hold-back now happens inside the relay, so it applies
to a dynamic-port create anywhere on a connection rather than only as request #1.

### 2.1 Framing the request direction only

The response direction stays a raw, backpressured splice. Nothing is decided there and
a great deal depends on it (`logs -f`, `events`, `docker cp` out, build output), so it
is left alone.

The **request** direction is framed request by request. HTTP/1.1 requests are
self-delimiting without any knowledge of responses, so this needs no response parsing
in the common case:

* `Content-Length` → forward exactly that many bytes;
* `Transfer-Encoding: chunked` → walk the chunk framing, forwarding raw bytes as they
  are consumed;
* neither header → no body.

Only `POST /containers/create` has its body read into memory. Everything else — a
build context, a `docker cp` archive, an image push — is **streamed straight from the
64 KiB read buffer to the guest**, never accumulated. Per-connection memory is
therefore what it was before the change, and independent connections never touch each
other (24 concurrent `docker ps` complete in 0.16 s; §3.6).

### 2.2 Ambiguous framing is refused, not guessed

The framer refuses, rather than resolves, every framing it cannot determine uniquely:

* `Content-Length` **and** `Transfer-Encoding` together;
* a repeated `Content-Length` (which `MinimalHTTP` surfaces as `"5, 6"`);
* any `Transfer-Encoding` that is not exactly `chunked`;
* a head over 64 KiB, or a malformed head.

RFC 9112 §6.1 permits a recipient to pick one of the two length headers. Picking is how
request smuggling works, and a proxy that makes admission decisions must not be able to
disagree with the server behind it about where one request ends. Refusing is the only
answer that cannot desynchronise. Docker's own clients never emit these shapes.

### 2.3 The too-large-body policy: refuse

**A `containers/create` body larger than 4 MiB is refused with a Docker-shaped
`400`.** It is not relayed unchecked.

This is the decision the old code got wrong in miniature: its 256 KiB peek limit, and
its inability to handle a chunked body, both fell back to "relay it unread". That
fallback is a security-relevant fail-open, so the new limit fails the other way.

Justification for refusing rather than raising the limit further:

* the limit is a *refusal* threshold, not a relay limit — bodies the proxy does not
  need to inspect stream through untouched at any size, so builds and `cp` are
  unaffected;
* a create document is JSON describing one container. 4 MiB is already two orders of
  magnitude above a Compose service with a generous environment;
* an unbounded inspection buffer would be a trivial memory-exhaustion vector on a
  socket that any local process can reach;
* a refusal is loud, carries a corrective message, and cannot silently substitute a
  guest path for a host one. "Too big to check" must never mean "not checked".

The head limit (64 KiB) and the chunk-line limit (8 KiB) follow the same rule.

### 2.4 The hijack boundary — nominate on the request, confirm on the response

`attach`, `exec` start with a TTY, BuildKit's `session`, and anything carrying
`Upgrade` stop being HTTP part-way through: after the Engine's reply, the client's
bytes are raw stdin. Framing those would destroy them.

Detection is deliberately **two-sided**:

1. **The request side nominates a candidate** — an `Upgrade` header, `Connection:
   upgrade`, or a path ending in `/attach`, `/attach/ws`, `/exec/{id}/start`,
   `/session`, `/grpc`. The request is forwarded, and the request worker then *pauses*.
2. **The response side confirms it** — the response worker (which is forwarding bytes
   verbatim regardless) parses the head of the reply. `101 Switching Protocols`, or a
   `2xx` carrying `application/vnd.docker.raw-stream` or
   `…multiplexed-stream`, means the connection is no longer HTTP. Both directions then
   splice raw for the rest of its life, and anything the framer had already read is
   flushed to the guest first so early stdin is not lost.

Anything else resumes framing.

Why two-sided rather than a request-side allowlist: it makes the two error directions
cost different amounts. A *missed* hijack breaks `docker exec`, which the brief
correctly calls a bad trade. An *over*-nomination, under this design, costs nothing at
all — the candidate simply goes back to being framed when the Engine answers like
ordinary HTTP. So the candidate set can be generous without paying for it, and the
functional risk of the fix is close to zero. `1xx` interim responses are skipped rather
than treated as verdicts, except `101`, which is the hijack itself.

Pausing the request worker while a candidate is outstanding is not a compromise: a
client that has just asked to be upgraded has nothing to say until it is told whether
it was.

Streaming endpoints (`logs -f`, `events`, `stats`, `cp`) are deliberately **not**
candidates. They are ordinary HTTP with long responses; the connection stays framable.

### 2.5 Preserved relay semantics

`DockerFramedRelay` reproduces `FDRelay`'s contract rather than reinventing it,
because those behaviours were paid for with bugs:

* one blocking worker per direction with a fixed 64 KiB buffer, so the kernel supplies
  backpressure instead of an unbounded userspace queue;
* directional EOF → `shutdown(fd, SHUT_WR)` on the *other* descriptor only, so a client
  closing stdin still reads its exec output (test: §3.3, `testClientHalfCloseStillDrainsTheResponse`);
* `cancel()` shuts descriptors down rather than closing them under a blocked syscall;
  the last worker out performs the single close;
* completion fires exactly once, on the caller's queue;
* the passive response observer is still notified immediately before the write and
  still cannot alter or suppress a byte.

### 2.6 Admission semantics preserved, with two deliberate changes

The checks and their precedence are unchanged: publication shape → dynamic allocation
plan → fixed-port reservation → bind sources (which is why a bind rejection still hands
back a lease it may already have taken). Rejections still close the connection, and
still carry the same status codes (`500` for publication, `400` for bind sources).

Two differences, stated rather than smuggled:

1. **`Expect: 100-continue` on a create now works instead of being refused.** The proxy
   answers the expectation itself so it can read the body it must inspect, then removes
   the `Expect` header from the head it forwards so the Engine does not answer it a
   second time. The old code refused these on the dynamic path and (via peek timeout)
   silently waved them through elsewhere.
2. **The VM now boots before admission rather than after.** Every check needs either
   the running VM's share list or a host listener that only exists while the stack is
   up, so admission moved behind `ensureRunning`. In practice this changes nothing: the
   client's first request is a `/_ping` that boots the VM anyway.

### 2.7 Residual risk

* **Pipelining.** Two of the four response modes — hijack confirmation and the held
  dynamic create — assume the reply they are looking at belongs to the request that
  armed them. A client that pipelines a second request before reading the first
  response could mis-correlate. No Docker client does this (Go `net/http`, curl,
  Compose, buildx all wait), and the previous code made the same assumption at
  connection granularity. The held create fails *closed* if mis-correlated: it
  validates a bounded `201` with a JSON `Id` and abandons the lease otherwise. Hijack
  mis-correlation would tear the connection down, not admit anything unchecked.
* **Non-HTTP first bytes are refused, not spliced.** A client that opens the Docker
  socket and speaks something other than HTTP now gets a `400` instead of a raw splice.
  This is intentional — garbage-then-HTTP would otherwise be a bypass — but it is a
  behaviour change for any exotic client. None is known.
* **An unparseable *response* head on a connection that already asked to be upgraded
  causes a splice.** The Engine, not the client, writes that head, so it is not
  attacker-controlled from the socket side.
* **Guest-side alias handling is a separate gap.** `docs/audit/FUNCTIONAL-AUDIT.md`
  §12 tracks the guard's own logic. This document is about whether the guard *runs*.

---

## 3. Verification

All of the following ran against daemon PID 40494, started 16:51:42 on 2026-08-03 from
`dist/Morbstack.app/Contents/MacOS/morbstackd`. Verified by **content, not name**: the
running image is inode `62890539`, which is the on-disk binary built at 16:50, and that
binary contains the new code's strings.

```
$ lsof -p 40494 | awk '$4=="txt"' | head -1
morbstack 40494 allie txt REG 1,13 5373232 62890539 …/Contents/MacOS/morbstackd
$ ls -lai dist/Morbstack.app/Contents/MacOS/morbstackd
62890539 -rwxr-xr-x@ 1 allie staff 5373232 Aug  3 16:50 …/morbstackd
$ strings -a …/morbstackd | grep -c "could not be admission-checked"
1
$ codesign -d --entitlements - …/morbstackd | grep virtualization
	[Key] com.apple.security.virtualization
```

All Docker CLI work used `DOCKER_CONFIG` pointed at a scratch directory with the
bundled `docker-compose`/`docker-buildx` symlinked in; `~/.docker` was never touched.

### 3.1 The original experiment, after the fix

Same script, same body, same two framings:

```
SAME create body, two framings:
  [fresh   ] create   : HTTP/1.1 400 Bad Request
  [fresh   ] body     : {"message":"invalid mount config for type 'bind': bind source path uses
                        the macOS /etc alias, but /etc is a guest system path; use the explicit
                        /private/etc source path after sharing it"}
  [keepalive] preface  : HTTP/1.1 200 OK
  [keepalive] create   : HTTP/1.1 400 Bad Request
  [keepalive] body     : {"message":"invalid mount config for type 'bind': bind source path uses
                        the macOS /etc alias, but /etc is a guest system path; use the explicit
                        /private/etc source path after sharing it"}

VERDICTS MATCH
```

Byte-identical verdicts. The bypass is closed.

### 3.2 Bind-mount matrix — through the real CLI

Run with `docker run --rm -v <src>:/x` on the actual `docker` binary, i.e. over the
keep-alive connection the old code never inspected.

| Case | Source | Result |
| --- | --- | --- |
| macOS `/etc` alias file | `/etc/hosts` | **REFUSED** — "uses the macOS /etc alias, but /etc is a guest system path; use the explicit /private/etc source path after sharing it" |
| guest system path | `/var/log` | **REFUSED** — same corrective shape for `/var` → `/private/var` |
| unshared root | `/Library` | **REFUSED** — "not shared with the Morbstack VM: /Library (add a shared_paths root that contains it, then restart Morbstack)" |
| `/tmp` alias | `/tmp/morb-bindmatrix/probe.txt` | **ALLOWED**, served the Mac's file (`mac-content-1785801146`) |
| explicit share | `/private/tmp/morb-bindmatrix/probe.txt` | **ALLOWED**, served the Mac's file |
| `$HOME` under `/Users` | `/Users/allie/morb-bindmatrix/probe.txt` | **ALLOWED**, served the Mac's file |
| symlink traversal | `/private/tmp/…/link-to-etc/hosts` | **REFUSED** — "resolves outside directories shared with the Morbstack VM: … -> /private/etc/hosts" |

Every refusal carries a corrective instruction. Nothing silently served guest content.

**Writes are not swallowed:**

```
$ docker run --rm -v /private/tmp/morb-bindmatrix:/w alpine:3.20 \
      sh -c 'echo written-by-container > /w/from-container.txt'
$ cat /private/tmp/morb-bindmatrix/from-container.txt
written-by-container
```

### 3.3 Port matrix

| Case | Result |
| --- | --- |
| `-p 8080:80 -p 8080:81` (ambiguity) | **REFUSED**: `published TCP endpoint 0.0.0.0:8080 maps to more than one container port` |
| `-p 8099:80` fixed | published; `curl http://127.0.0.1:8099` → `200` |
| `-p 80` dynamic (the held-create path) | `80/tcp -> 0.0.0.0:53119`; `curl` → `200` |
| `-P` publish-all | `80/tcp -> 0.0.0.0:32768` |

The dynamic case is the important one for this change: it exercises the bounded create
transaction now living inside the relay, which rewrites the request, holds the entire
`201` back until the lease is associated, and then resumes framing the same connection.

### 3.4 Streaming and hijack paths — no regression

| Path | Evidence |
| --- | --- |
| `docker logs -f` | 200/200 lines from a chatty container during a 5 s follow |
| `docker exec -it` (real TTY via `script`) | `TTY=yes`, `id -u` → `0` |
| `docker exec -i` (piped stdin) | `hello-from-stdin` round-tripped |
| `docker attach` | `attached-output-marker` received live |
| `docker run -it` | interactive session ran, `uname -m` → `aarch64` |
| `docker cp` host → container | 12 MiB, sha256 `81659fbc…` identical inside |
| `docker cp` container → host | round-trip sha256 `81659fbc…`, `cmp` clean |
| `docker events` | live event stream during a container create/start/die |
| BuildKit `docker build` | 3 MB context, image built and ran (`built-by-buildkit`, `3000000`) |
| classic `DOCKER_BUILDKIT=0` build | built and ran; streams a chunked tar context |
| 3-service compose fixture | §3.5 |

**Decisive hijack proof.** Bytes that *look exactly like an HTTP request* were piped as
`exec` stdin. If the proxy were still framing after the hijack, they would have been
consumed as a request or answered with a `400`:

```
$ printf 'POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: 9\r\n\r\n{"a":"b"}' \
    | docker exec -i morbhij cat | od -c
0000000    P   O   S   T       /   v   1   .   4   7   /   c   o   n   t
0000020    a   i   n   e   r   s   /   c   r   e   a   t   e       H   T
0000040    T   P   /   1   .   1  \r  \n   C   o   n   t   e   n   t   -
0000060    L   e   n   g   t   h   :       9  \r  \n  \r  \n   {   "   a
0000100    "   :   "   b   "   }
```

Byte-for-byte. The connection spliced raw, as it must.

Across the entire matrix the daemon logged **zero** framing failures
(`grep -c "could not be framed" ~/.morbstack/logs/daemon.log` → `0`) and only the
expected refusals.

### 3.5 The 3-service compose fixture

`docs/audit/FUNCTIONAL-AUDIT.md` §10's fixture, verbatim, at
`/private/tmp/morbaudit-stack`:

```
$ docker compose up -d --build
 Container morbaudit-db-1   Healthy
 Container morbaudit-api-1  Starting → Healthy
 Container morbaudit-web-1  Started
TOTAL: 12.9s
```

| Assertion | Evidence |
| --- | --- |
| Healthcheck-chained `depends_on` | `db Healthy` → `api Starting/Healthy` → `web Started`, in order |
| All services healthy | `morbaudit-{api,db,web}-1  Up … (healthy)` |
| Bind mount served | `curl :18100` → `<h1>bind-mount-v1</h1>` |
| `environment:` delivered | `curl :18101` → `{"greeting": "hello-from-compose", "db": "db"}` |
| Named volume | `morbaudit_dbdata` created |
| `secrets:` functional | `psql` authenticated via `/run/secrets/pg_password`, returned `42` |

12.9 s, identical to the pre-change run recorded in FUNCTIONAL-AUDIT §10.

### 3.6 Performance and isolation

```
$ for i in $(seq 1 24); do ( docker ps -q >/dev/null ) & done; wait
24 concurrent docker ps in 0.16s
```

Connections are not serialised, and the framer adds no per-request full-body copy for
anything but `containers/create`.

### 3.7 Tests

`mise run check` → **exit 0**, 764 Swift tests (was 739; +25) and 217 Rust tests.

The new coverage lives in
`mac/Tests/MorbstackKitTests/DockerRequestFramingTests.swift`. The two tests whose
absence let this ship:

* `DockerRequestFramerTests.testEveryRequestOnAReusedConnectionIsFramed` — three
  pipelined requests on one stream; asserts the **second** (the create) is framed with
  its body readable.
* `DockerFramedRelayTests.testSecondRequestOnAReusedConnectionIsInspectedAndCanBeRefused`
  — a real relay over `socketpair(2)`s: ping, then create. Asserts the policy is asked
  about **both**, that the create's body is delivered to it, that a refusal reaches the
  client as a `400`, and that **the refused request never reaches the Engine**.

Plus `testEveryRequestInALongKeepAliveConversationIsInspected` (ten requests, so the
fix is not "inspect two"), byte-at-a-time delivery, chunked decode/relay fidelity,
verbatim large-body streaming, ambiguous-framing refusal, oversized head and body
refusal, truncation vs clean EOF, garbage refusal, pending-byte handoff to the splice,
confirmed and *un*confirmed hijack, endless response streams, half-close drain, the
held create's associate-before-release ordering, and `Expect: 100-continue`.

---

## 4. What this does not fix

* **Phase 1.1** — `-P` across stop/start still shows the durable publish-all session
  EOF (`publish-all allocator for … failed: could not read the guest publish-all
  allocator`). This warning predates the change (it appears at 16:16, before the
  rebuild) and the allocation itself still succeeds. Unrelated to framing.
* **Phase 1.4/1.5** — `host.docker.internal` and disk grow are untouched.
* `~/.morbstack/data/disk.img` is still 72 GiB from the earlier failed grow test; left
  alone deliberately.
