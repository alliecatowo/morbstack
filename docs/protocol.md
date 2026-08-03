# Protocol specification

Status: M0. This document is authoritative for the wire formats Morbstack
speaks in milestone M0. The eventual gRPC contract for the guest control
plane is sketched in `proto/morbstack/v1/control.proto`, but M0 does not
implement it — everything described below is what actually ships.

There are three distinct protocols in play, over three distinct transports:

1. **MRB0 framed JSON**, host morbstackd <-> guest morbinit, over vsock
   port 1024.
2. **Stream-dial**, host morbstackd <-> guest morbinit, over vsock port
   2376 — a one-line handshake followed by a raw byte splice, used to reach
   published container ports from the Mac.
3. **Daemon control IPC**, CLI `morb` <-> host `morbstackd`, over a Unix
   domain socket, newline-delimited JSON.

They are unrelated to each other and must not be confused: MRB0 and
stream-dial both cross the host/guest boundary over vsock, on different
ports and with different framing; daemon control IPC never leaves the
host.

---

## 1. MRB0 framing (guest control channel)

Transport: vsock, port 1024 (see §3, port registry). Either side may
initiate a frame; the channel is full-duplex, but in M0 morbstackd is
always the party that sends requests and morbinit is always the party that
replies — morbinit never sends an unsolicited frame in M0.

### Frame layout

```
+----------------+----------------------+----------------------------+
| magic (4 bytes)| length (4 bytes, BE) | payload (length bytes)    |
| "MRB0"         | u32, big-endian      | UTF-8 JSON                |
+----------------+----------------------+----------------------------+
```

- **magic**: exactly the four ASCII bytes `M`, `R`, `B`, `0` (0x4D 0x52 0x42
  0x30). A reader that sees any other four bytes where a frame header is
  expected must treat the connection as desynchronized and close it —
  never attempt to resynchronize by scanning forward.
- **length**: unsigned 32-bit integer, big-endian, byte count of the
  payload that follows. Does not include the 8-byte header itself.
- **max frame size**: 1 MiB (1,048,576 bytes), payload only. A `length`
  greater than this is a protocol violation; the receiver must close the
  connection rather than attempt to allocate or read it.
- **payload**: UTF-8 encoded JSON. Exactly one JSON value per frame, with
  a top-level `"type"` string field that selects the message shape. No
  trailing bytes, no newline terminator — the length prefix is the only
  delimiter.

### Message table

All messages below are the complete set for M0. Requests are host ->
guest; replies are guest -> host.

| Direction | `type`       | Payload fields                              | Notes |
|-----------|--------------|----------------------------------------------|-------|
| host->guest | `ping`     | *(none)*                                     | Liveness check |
| guest->host | `pong`     | `uptime_ms: int`                             | Reply to `ping` |
| host->guest | `info`     | *(none)*                                     | Request static guest facts |
| guest->host | `info`     | `morbinit_version: string`, `kernel: string`, `docker_ready: bool`, `docker_data_on_disk: bool`, `userland_proxy: bool`, `shares: string` | Reply to `info` request |
| host->guest | `clock_sync` | `unix_nanos: int`                          | Push host wall-clock time |
| guest->host | `ok`       | *(none)*                                     | Generic success reply (used for `clock_sync`, `shutdown`) |
| host->guest | `shutdown` | *(none)*                                     | Request orderly guest shutdown |
| guest->host | `error`    | `message: string`                            | Generic failure reply, any request |

Note the reply to `info` reuses `"type": "info"` (distinguished from the
request by direction and by carrying fields) rather than a separate
`"info_reply"` type; the same holds for `ping`/`pong` being asymmetric by
design (the reply type differs) while `clock_sync`/`shutdown` share the
generic `ok` reply because they have no data to return on success.

`docker_ready` reports whether dockerd's Unix socket
(`/var/run/docker.sock`) has accepted a connection yet, so a caller polling
`info` right after boot can tell "guest control is up" apart from "the
Docker API behind the vsock 2375 relay is actually usable" without scraping
`console.log`. It is set once, monotonically false -> true, by a readiness
monitor thread inside morbinit (`proxy::spawn_ready_monitor`) and never
reverts to false for the life of the guest, even if dockerd later crashes
and restarts.

`docker_data_on_disk` reports whether `/var/lib/docker` is backed by the
formatted virtio disk (`/dev/vda`) rather than the tmpfs fallback — i.e.
whether anything pulled or built during this boot will still be there
after a stop/start cycle. It is decided once at boot by `disk::provision`
(see §"Guest data root" in `docs/architecture.md`) and does not change for
the life of the guest.

`userland_proxy` reports whether dockerd was started with its userland
proxy left enabled. It is read off the argv morbinit actually built for
dockerd (`supervisor::userland_proxy_enabled`) rather than re-probed from
the filesystem, so it cannot disagree with the running engine. It matters
to anything using the §3.2 stream-dial port: with the proxy on there is a
real `127.0.0.1:<port>` listener inside the guest for `dial.rs` to connect
to, and with it off publishing is DNAT-only, so every stream dial gets
ECONNREFUSED and host port forwarding does not work. morbinit logs a
warning at boot when it is false. The field is *additive* — a host that
predates it ignores it (see §4), and the host's `GuestReply` decoder does
not currently surface it.

The host's `GuestReply` decoder (`mac/Sources/MorbstackKit/GuestControl.swift`)
parses `docker_ready` and `docker_data_on_disk` as `Bool?`, `nil` when
talking to a guest that predates them rather than defaulting to `false` — that distinction matters to boot
probes that must not wait forever on a field an older guest will never
send. Both are exposed to CLI/daemon consumers: `morb doctor`'s
disk-persistence check and the `docker_data_on_disk` field in `morb
status`'s JSON output (see `mac/Sources/MorbstackKit/Daemon.swift`).

### Examples

Ping:

```
host -> guest: MRB0 + length + {"type":"ping"}
guest -> host: MRB0 + length + {"type":"pong","uptime_ms":48213}
```

Info:

```
host -> guest: MRB0 + length + {"type":"info"}
guest -> host: MRB0 + length + {"type":"info","morbinit_version":"0.1.0-m0","kernel":"6.18.15","docker_ready":true,"docker_data_on_disk":true,"userland_proxy":true}
```

Clock sync:

```
host -> guest: MRB0 + length + {"type":"clock_sync","unix_nanos":1785600000000000000}
guest -> host: MRB0 + length + {"type":"ok"}
```

M0 note: `clock_sync` is observe-and-log only. morbinit computes the
host/guest delta in milliseconds and writes one `log::log(...)` line
("clock_sync: observed host-guest delta ~N ms (not applied)") but does not
call `clock_settime(2)` or otherwise step the guest clock — replying `ok`
means "the request was well-formed and logged," not "the clock moved."
Actually stepping the clock needs `CAP_SYS_TIME`, an FFI wrapper around
`clock_settime`, and a policy for who may move guest time backwards; that
is deferred past M0. The comment in
`proto/morbstack/v1/control.proto` describing `ClockSync` as preventing
drift "after suspend/resume" documents the target behavior the RPC exists
for, not what M0's MRB0 subset actually does today.

Shutdown:

```
host -> guest: MRB0 + length + {"type":"shutdown"}
(guest stops services, unmounts and syncs the Docker data disk)
guest -> host: MRB0 + length + {"type":"ok"}
(guest then powers off)
```

**The `ok` is the last frame, and it is sent *after* the flush, not before
it.** That ordering is the entire point of this exchange: it makes the reply
a report about work already done rather than a promise about work still to
come, so a host that has received `ok` knows the images and volumes are on
the virtio device. A client must therefore treat this reply as slow — tens
of seconds after a heavy `docker pull` — and must not shorten its wait to
something that merely covers a round trip.

The budgets that enforce this nest, and each layer must strictly contain the
one inside it; an outer layer that expires first tears the VM down with
dirty pages outstanding, which is data loss rather than a timeout:

| Layer | Budget | Where |
|-------|--------|-------|
| guest reply cap | 54 s | `control::SHUTDOWN_REPLY_TIMEOUT` (`guest/morbinit/src/control.rs`) |
| guest reply flush | +5 s | `REPLY_FLUSH_TIMEOUT` (`guest/morbinit/src/main.rs`) |
| host ack timeout | 65 s | `VMManager.shutdownAckTimeout` |
| daemon stop budget | 90 s | `Daemon.stopBudget` |
| CLI timeout | 120 s | `Daemon.clientTimeout` |

The guest cap is *derived*, not chosen: `SUPERVISED_SERVICE_COUNT *
(STOP_GRACE + KILL_GRACE) + FLUSH_ALLOWANCE` = `2 * (10 s + 2 s) + 30 s`.
Raising any of those guest constants raises the cap and requires raising
every host number above it in the same change. Both ends are pinned by
tests — `the_reply_budget_leaves_room_for_the_host_ack_timeout_above_it` in
`control.rs` and `testShutdownBudgetsNestFromTheGuestOutwards` in
`mac/Tests/MorbstackKitTests/LifecycleTests.swift` — so the ladder cannot
drift out of sync silently.

Unknown request:

```
host -> guest: MRB0 + length + {"type":"reticulate_splines"}
guest -> host: MRB0 + length + {"type":"error","message":"unknown message type: \"reticulate_splines\""}
```

The exact wording and quoting above matter if you're writing a client that
pattern-matches on it (you shouldn't — match on `"type":"error"`, not on
`message` text): `control.rs` builds the string with
`format!("unknown message type: {:?}", other)`, and `{:?}` on a `&str`
in Rust wraps the value in double quotes. So the offending type name is
always visible re-quoted inside the message, not bare.

---

## 2. Daemon control IPC (`morb` <-> `morbstackd`)

Transport: Unix domain socket at `~/.morbstack/run/morbstackd.sock`.
Framing: newline-delimited JSON (NDJSON) — exactly one JSON value per line,
terminated by a single `\n`. No length prefix; the newline is the
delimiter, and payloads must not contain a literal unescaped `\n` (standard
JSON string escaping applies, so this is automatic as long as encoders
don't emit raw newlines inside strings).

This is a request/response protocol: the client (`morb`) writes one
request line and reads exactly one response line back. Connections are
short-lived — one request/response pair per connection is the common case,
though morbstackd does not require the client to disconnect immediately
after.

### Request shape

```json
{"cmd": "status", "args": {}}
```

- `cmd`: one of `status`, `start`, `stop`, `suspend`, `resume`, `version`.
- `args`: object mapping string keys to string values (`{String: String}`,
  not arbitrary JSON), command-specific. **Optional at the wire level**:
  `DaemonRequest.args` (`mac/Sources/MorbstackKit/IPC.swift`) is a Swift
  `Optional`, and Foundation's synthesized `Decodable` treats a missing
  optional key as `nil` rather than a decode error, so a request line with
  no `"args"` key at all — `{"cmd":"status"}` — decodes successfully and is
  equivalent to `{"cmd":"status","args":{}}` or `{"cmd":"status","args":null}`.
  Every M0 command works with `args` entirely omitted; only `stop` reads a
  key out of it today (`force`, compared against the literal strings
  `"true"` or `"1"`; anything else, including an absent key, means
  `force: false`). `args` values being plain strings (not nested
  objects/numbers/booleans) is a real constraint, not just a convention —
  see the jsonlite note in §4 for the guest-side channel's version of the
  same "flat values only" rule.

### Response shape

Success:

```json
{"ok": true, "data": {}}
```

Failure:

```json
{"ok": false, "error": "vm not running"}
```

- `ok`: boolean, discriminates the two shapes.
- `data`: present iff `ok == true`. Command-specific; shape is not
  constrained further at the protocol level in M0 (each `cmd` defines its
  own `data` contents, e.g. `status` returns VM lifecycle state).
- `error`: present iff `ok == false`. Human-readable message, safe to print
  directly to the CLI user.
- `error_code`: optional on failures. A daemon that supports it emits a stable,
  lowercase-hyphenated code alongside the human `error`; clients must tolerate it
  being absent because M0 daemons predate the field. Unknown future code strings are
  not a decode error and must still display the associated human `error`.

### Error semantics

- An unrecognized `cmd` produces `{"ok": false, "error": "..."}`; it never
  closes the connection abruptly or crashes morbstackd. Current daemons additionally
  emit the stable `error_code: "unknown-command"`:
  ```json
  {"ok": false, "error": "unknown command `reticulate_splines`", "error_code": "unknown-command"}
  ```
  Clients that understand `error_code` may use it. For an M0 daemon without the
  field, Morbstack's update-continuity adapter recognizes only the canonical legacy
  response for one known additive command (`k8s-diagnose`) and turns it into a
  `restart-required` client-side error. It first may make the existing read-only
  `version` probe for diagnostic context; it never starts, stops, or re-registers a
  service/engine. Every other legacy error remains human-readable prose, not a
  machine-parsed protocol surface.
- A malformed request line (invalid JSON, missing `cmd`) produces a
  `{"ok": false, "error": "..."}` response on that same connection: the
  connection-handling loop in `Daemon.serveControlClient` wraps the
  `IPCCodec.decodeLine` throw in a `catch` and replies with
  `.failure("\(error)")` rather than dropping the connection, so in
  practice morbstackd does *not* exercise the "close the connection
  instead" fallback this paragraph allows for — every malformed line seen
  in M0 gets an in-band `{"ok":false,...}` reply on the same connection.
  That said, this remains a fallback other implementations of this
  protocol may need (e.g. input so corrupt it cannot round-trip through
  `JSONEncoder` for the reply either), so it stays documented as allowed.
- morbstackd must never terminate the daemon process in response to
  malformed or unexpected client input. Malformed input is always a
  per-connection concern.

---

## 3. vsock port registry

| Port | Purpose                                    |
|------|---------------------------------------------|
| 1024 | Guest control (morbinit), MRB0 framing       |
| 2375 | Docker Engine API relay (host morbstackd <-> guest dockerd) |
| 2376 | Stream-dial: host requests a connection to an arbitrary guest-local TCP port (used for published container ports) |
| 2377 | Bulk payload install: host streams large files into the guest (used for the Kubernetes payload) |

Port 2375 is the conventional plaintext Docker Engine API port; it is used
here only on the host<->guest vsock link, which is not reachable from the
network, so this does not expose an unauthenticated Docker socket
externally. Host-side, morbstackd re-exposes the relayed API to local
clients only via the Unix socket at `~/.morbstack/run/docker.sock`.

Port 2376 is likewise not a network listener the guest ever exposes beyond
the vsock link — see §3.2 below. It deliberately does *not* reuse the
conventional TLS-Docker-API port meaning; on this transport it is
Morbstack's own stream-dial protocol, unrelated to Docker's usual port 2376
convention.

Port 2377 is a general bulk-transfer channel, not a Kubernetes-specific one.
Its first user is the k3s + cri-dockerd payload (~122 MB), which is
deliberately *not* baked into the initramfs: `/` in the guest is a
RAM-resident rootfs, so anything in the image is paid for in guest memory on
every boot, including the overwhelming majority of boots where Kubernetes is
off. Streaming it once, on the first `morb k8s enable`, and landing it on the
persistent ext4 disk keeps the cost proportional to the feature's use. See
§3.3.

New ports must be added to this table before use. Do not reuse 1024, 2375,
2376, or 2377 for anything else.

### 3.1 The vsock 2375 <-> `docker.sock` relay, end to end

Unlike MRB0, port 2375 carries no framing of its own — it is plain HTTP/1.1
(the Docker Engine API), relayed as a dumb byte pipe on both sides of the
vsock link. The full path for one `docker` CLI invocation:

```
docker CLI -> ~/.morbstack/run/docker.sock (Unix socket, host)
           -> DockerProxy (mac/Sources/MorbstackKit/DockerProxy.swift)
           -> FDRelay pumps bytes onto a vsock connection to guest port 2375
           -> morbinit's proxy::spawn_docker_proxy() listener (guest/morbinit/src/proxy.rs)
           -> a *fresh* connection to /var/run/docker.sock (dockerd), per vsock connection
           -> dockerd
```

Design points, from the guest-side implementation (`proxy.rs`) and the
host-side one (`Relay.swift`/`DockerProxy.swift`), that a reimplementation
must preserve:

- **One vsock connection maps to exactly one dockerd connection**, opened
  fresh by morbinit for each accepted vsock connection. Nothing parses or
  multiplexes the HTTP stream on either side — the Docker Engine API uses
  HTTP/1.1 hijacked upgrades for `attach`/`exec`/`build`/log-follow, which
  are not safely multiplexable over a shared connection.
- **Half-close aware, both sides.** When one direction hits EOF, the relay
  issues `shutdown(fd, SHUT_WR)` on the *other* descriptor only after
  everything already queued toward it has drained — not on first EOF. This
  is what keeps `docker build -` / `docker run -i` (client closes stdin,
  still wants the response) working; tearing down both halves on the first
  EOF truncates in-flight response bytes on either end.
- **Guest-side connection cap**: `MAX_CONNECTIONS = 64` in `proxy.rs`
  (each proxied connection costs the guest two threads — a copy-in and a
  copy-out — so this bounds morbinit's own thread usage). The host-side
  `DockerProxy` does not impose a separate cap of its own; the guest-side
  64 is the effective ceiling on concurrent Docker API connections.
- **No TCP listener inside the guest, ever.** dockerd is started with
  `--host unix:///var/run/docker.sock` only (see `supervisor.rs`); the
  vsock link is the only path to it, and vsock port 2375 is not reachable
  from the guest's NAT'd network interface, so this does not create an
  unauthenticated Docker API reachable from outside the host.
- **HTTP-level failure surfacing.** If the VM fails to boot, or the vsock
  dial to port 2375 fails, `DockerProxy` does not just close the client's
  socket — it writes a minimal synthetic `502 Bad Gateway` HTTP response
  with a JSON body (`{"message":"morbstack: <error>"}`) before closing, so
  `docker ps` etc. show a real message instead of "connection reset by
  peer".

### 3.2 The vsock 2376 stream-dial protocol (published container ports)

`docker run -d -p 8080:80 nginx` makes dockerd's userland proxy
(`docker-proxy`) listen on `127.0.0.1:8080` *inside the guest*. Nothing on
the host can reach that directly — the guest's only host-facing transport
is vsock, and unlike port 2375 there is no single well-known guest port to
relay, because the guest-local port varies per published container port
and is not known until the container starts. Port 2376 solves this with a
tiny handshake: the host connects, names the guest-local destination port
as one ASCII line, and only then does the splice begin.

Transport: vsock, port 2376 (see §3, port registry). Unlike MRB0, this is
not a framed protocol — after the one-line preamble, the connection is a
raw bidirectional byte splice with no further structure.

```text
host -> guest:  "TCP <port>\n"      port is decimal, guest-local, ASCII
guest -> host:  "OK\n"              connection established; splice begins
           or:  "ERR <reason>\n"    then the guest closes the connection
```

- **`<port>`** is the *guest-local* port — the same number as the
  published host port, because dockerd's own userland proxy listens on
  that number inside the guest too. There is no host-port-to-guest-port
  remapping at this layer; if that's ever needed it happens above this
  protocol, not within it.
- **The preamble is read one byte at a time on both the guest
  implementation (`dial.rs`) and the host implementation
  (`StreamDial.swift`)**, never buffered. Everything after the newline
  belongs to the spliced stream (typically the first bytes of an HTTP
  request), and a buffered read would have nowhere to put bytes it
  over-reads past the delimiter — there is no protocol-level way to push
  them back.
- **`OK\n` is sent only once the guest-local TCP connection is actually
  established** (i.e. after a successful `connect(2)` to
  `127.0.0.1:<port>` inside the guest), not merely once the preamble
  parses. This lets the host tell "no listener yet" apart from "connected,
  no data yet," which the host-side retry loop depends on.
- **`ERR <reason>\n`** is sent when the guest-local `connect(2)` fails (no
  listener on that port is the common case, e.g. a container that hasn't
  finished starting yet, or one that already stopped). `<reason>` has any
  embedded `\n`/`\r` flattened to spaces before sending, since the
  newline is the only framing delimiter this protocol has — an
  unflattened OS error string could otherwise masquerade as two replies.
  ECONNREFUSED gets its own wording — `connection refused on
  127.0.0.1:<port> (userland-proxy disabled?)` — because that is the one
  failure with a standing structural cause rather than a transient one:
  with `--userland-proxy=false` there is no guest-local listener to
  connect to at all, so *every* dial to a published port fails this way
  (see `userland_proxy` in §1). Other errors keep the generic `dial
  127.0.0.1:<port>: <err>` form; blaming the proxy for a timeout would
  misdirect whoever is reading the log.
- **Half-close is propagated in both directions**, exactly as in the port
  2375 relay (§3.1): a client that shuts down its write side must still
  receive the full response before the guest tears down its half.
- **Guest-side connection cap**: `MAX_CONNECTIONS = 128` in `dial.rs`
  (higher than port 2375's 64, since a busy multi-port compose project can
  legitimately have more concurrent inbound connections than the single
  Docker API relay ever does). Past the cap the guest replies
  **`ERR busy\n`** and closes, rather than closing silently — documented
  backpressure has to be distinguishable from a peer that never spoke the
  protocol at all, which the host otherwise reports as a violation.
  `busy` is a stable single-word reason (`BUSY_REASON` in `dial.rs`) that
  a host may match on to tell "morbinit is saturated, retry" apart from a
  failure of the dialed port itself. The reply is best-effort: it is
  written from the accept thread — spawning a thread to announce that
  threads have run out would defeat the cap — under a 250 ms
  `BUSY_REPLY_TIMEOUT_MS` poll for writability, and on timeout or error
  the guest just closes as before. That 250 ms is only ever spent on a
  peer that has already gone away.
- **Preamble timeout**: the guest gives a connection 10 seconds to deliver
  its preamble line before hanging up (`PREAMBLE_TIMEOUT` in `dial.rs`);
  the host gives the guest 3 seconds to answer after sending it
  (`StreamDial.replyTimeout` in `StreamDial.swift`) — short on purpose,
  since answering only requires a loopback `connect(2)`, so a slow reply
  means something is wrong rather than merely busy.
- **The host never listens on `0.0.0.0`.** `PortForwarder`'s Mac-side
  listeners for published ports bind `127.0.0.1` only, matching Docker's
  own default published-port behavior; a container publishing to a
  specific host IP (`-p 127.0.0.1:8081:80`) is honored as that specific
  bind address, never widened.

---

### 3.3 The vsock 2377 payload install protocol

A line-oriented request/reply preamble followed, for a transfer, by a raw
byte body. Text for the control words so a human tailing the guest console
can read an exchange; raw bytes for the body because framing 122 MB into
chunks would buy nothing that the length and the digest do not already give.

Two verbs, each a single `\n`-terminated ASCII line from the host:

```text
HAVE <name> <sha256hex>            -> "YES" | "NO"
PUT  <name> <length> <sha256hex>   -> "OK"  (then the host writes <length> bytes)
                                   -> "OK" | "ERR <reason>"   (after verification)
```

`<name>` is checked against a closed allow-list in the guest (`k3s`,
`cri-dockerd`). This is the security boundary of the channel, and it is an
allow-list rather than a path sanitiser on purpose: the host picks the name
and the guest turns it into a path it will later `exec`, so the set of legal
names has to be decided in the guest and closed, not filtered. There is no
string the host can send that makes the guest write outside its payload
directory.

`HAVE` is what makes a repeat `morb k8s enable` free: the guest re-hashes the
installed file and answers `YES`, and the host skips the transfer entirely.
It is re-hashed rather than read from a sidecar because a sidecar would let
the guest claim to have a file that a crash had truncated.

The transfer itself:

* The guest writes into `.<name>.incoming` beside the destination, never to
  the destination itself.
* It hashes the bytes as they arrive, in one pass, so a 122 MB payload is
  read once rather than written and then re-read.
* On a digest mismatch, a short stream, or a write error, the partial file is
  **deleted** and the reason is returned. An unverified blob is worse than no
  blob: it is one that a later boot might try to run.
* Only after the digest matches is the file `fsync`ed, made executable, and
  `rename(2)`d into place. The rename is atomic within the directory, which is
  what guarantees the "is Kubernetes installed" check can never observe a
  half-written binary.

Because the destination is on the persistent ext4 disk, this happens once per
machine rather than once per boot. The enabled flag lives beside the payload,
so a guest that was enabled comes back enabled.

Progress is *not* reported on this channel. The host knows how many bytes it
has written, and the guest publishes its own received-byte count through the
`k8s status` reply on the control channel (port 1024), which stays answerable
throughout — so a UI can render a progress bar without either side having to
interleave control messages into a bulk stream.

## 4. Versioning and compatibility rules

M0 is unversioned at the protocol level beyond the implicit "MRB0" magic
and the `morbinit_version` field reported by `info`. The following rules
apply and must hold for all future revisions, not just M0:

- **Unknown `type` never crashes.** Both morbstackd and morbinit must
  respond to an unrecognized `type` (or `cmd`, for daemon control IPC)
  with a well-formed `error` reply, and must continue serving subsequent
  requests on the same connection. A parser that cannot recognize a
  message must fail closed on that one message, not on the process.
  Note: for a top-level `type` this means MRB0 conceptually treats every
  request `type` as if part of a oneof-style enumeration and replies with
  `error` on no-match, consistent with an "unrecognized oneof case ->
  error, never crash" rule that will carry forward when this transport is
  replaced by the gRPC contract in `proto/morbstack/v1/control.proto`.
- **Unknown fields are ignored, not rejected.** A future sender may add
  new fields to an existing message; a receiver on an older version must
  ignore fields it does not recognize rather than treating them as a
  parse error. This lets host and guest binaries drift slightly in
  version without hard-failing (e.g. across a suspend that spans an
  upgrade).
- **Exception to "ignore unknown fields": nested values, on the MRB0 side
  only.** The guest's JSON codec (`guest/morbinit/src/jsonlite.rs`) is a
  hand-rolled encoder/decoder that deliberately supports only *flat*
  objects — string, integer, and boolean values, one level deep. This is
  documented as the M0 wire format, not a bug: MRB0 messages today
  (`ping`/`pong`/`info`/`clock_sync`/`ok`/`shutdown`/`error`) never need
  more than that, and a full recursive-descent JSON parser would be
  unnecessary machinery for a guest PID 1 that also has zero external
  crates available to it. The consequence for forward compatibility: if a
  future sender puts a nested object or array anywhere in an MRB0 payload
  — even in a field an older jsonlite-based receiver doesn't otherwise
  care about — `jsonlite::parse` fails the *entire* message with
  `ParseError("nested objects/arrays are not supported by jsonlite")`
  before any field-level "ignore what you don't recognize" logic gets a
  chance to run, because parsing happens before field lookup. `emit`
  mirrors this: it only knows how to serialize `Value::Str`/`Value::Int`/
  `Value::Bool`, so morbinit itself can never accidentally produce a
  nested payload. In practice this means: nested values are a protocol
  error today, full stop, on the guest control channel. A protocol
  revision that needs structured/nested values must either land on the
  gRPC contract in `proto/morbstack/v1/control.proto` (which has no such
  restriction — `Event.payload` is already a `oneof` of message types) or
  replace jsonlite with a parser that supports nesting; it cannot be
  introduced as a soft, ignorable extension to the current MRB0 subset.
  The daemon control IPC side (`morb` <-> `morbstackd`) has no such
  restriction — it uses Foundation's full `JSONEncoder`/`JSONDecoder` via
  `AnyCodableValue`, which already supports arbitrarily nested
  arrays/objects (see `IPC.swift`); this flatness constraint is specific
  to the guest channel's jsonlite codec, not the protocol as a whole.
- **`morbinit_version` and daemon `version` responses are the compat
  probe.** Any future breaking change to either wire format must be
  preceded by a way for the other side to detect the version in use
  (already present via `info`'s `morbinit_version` and daemon control
  IPC's `version` command) before assuming a particular message shape.
- **No implicit protocol negotiation in M0.** There is exactly one MRB0
  message set and one daemon control IPC message set. A future version
  bump that changes message shapes must either remain backward compatible
  under the "ignore unknown fields" rule above, or introduce an explicit
  new `type`/`cmd` rather than silently redefining an existing one.

---

## 5. Host directory shares (VirtioFS)

Bind mounts (`docker run -v /Users/me/app:/app`) need the host directory to
exist *inside the guest*, and to exist there **at the same absolute path**.
That is the whole design, and it is what Docker Desktop and OrbStack do:
the Docker CLI sends the literal string `/Users/me/app`, dockerd resolves it
against the guest's own filesystem with no idea it is inside a VM, and
because the host's `/Users` is mounted at the guest's `/Users` the two land
on the same bytes. There is no path translation anywhere in the stack, no
`/mnt/host/...` prefix, and nothing in dockerd to rewrite.

The transport is VirtioFS: one `VZVirtioFileSystemDeviceConfiguration` per
shared root, each carrying a `VZSingleDirectoryShare`. **Single**, not
`VZMultipleDirectoryShare` — a multiple share exposes its directories *by
name* underneath one tag, so the guest would have to mount a synthetic
parent and every path inside it would gain a prefix, which is exactly the
translation this design exists to avoid.

The guest kernel supports it: `CONFIG_VIRTIO_FS=y`, `CONFIG_FUSE_FS=y` and
`CONFIG_FUSE_DAX=y`, all built in (there is no module tree in the initramfs
to load one from). Verified by extracting `IKCFG` from the shipped
`vmlinux`, and confirmed at runtime by `virtiofs` appearing in the guest's
`/proc/filesystems`.

### 5.1 The kernel command-line share map

The host tells the guest what to mount by appending one argument per share
to the kernel command line:

```
morb.share=<tag>:<percent-encoded-path>[:ro]
```

for example:

```
console=hvc0 rdinit=/init morb.share=morbshare0:/Users morb.share=morbshare1:/private/tmp
```

Tags are generated positionally (`morbshare0`, `morbshare1`, …) and are
internal device identifiers — **never** path components.

**Why the command line** and not a control-channel query or a file baked
into the initramfs. A query inverts the boot order: PID 1 would have to
defer mounting until the vsock listener exists, and the host would have to
answer a question from a guest that has not finished coming up. A baked-in
file makes the share list part of the image, so changing `shared_paths` in
`config.toml` would mean rebuilding the guest image. The command line is
neither: it is set by the host at VM-configuration time, it is readable by
PID 1 from its first instruction via `/proc/cmdline`, and it carries no
state between boots.

**Why the path is percent-encoded.** The kernel command line is
whitespace-separated, so `/Volumes/My Disk` would otherwise arrive as two
unrelated arguments and the share would silently lose its tail. Bytes
outside `[A-Za-z0-9/._+-]` are escaped as `%XX`; `:` is escaped because it
separates the tag from the path, and `%` because it introduces an escape.
Ordinary paths (`/Users`, `/private/tmp`) therefore survive verbatim, which
matters the first time somebody debugs this with `cat /proc/cmdline`.

The `:ro` suffix marks a share read-only. Nothing in `shared_paths`
produces one — a bind mount you cannot write to is not what `-v $PWD:/app`
means — but the flag is carried end to end (planner, command line, guest
mount flags) so that an *internal* share, such as a host payload directory
the guest only ever reads out of, is a call to an existing initialiser
rather than a protocol change.

Both ends implement this independently and are held together only by
matched test suites: `MorbShares` in
`mac/Sources/MorbstackKit/DirectoryShares.swift` and `shares` in
`guest/morbinit/src/shares.rs`. A path that encodes on one side and does
not decode on the other is not an error anyone sees — it is a container
with an empty directory where the user's source tree should be.

### 5.2 Guest-side mounting

`morbinit` reads `/proc/cmdline` immediately after `early_mounts` (it needs
`/proc` and nothing else), creates each mount point, and mounts each tag:

```
mount -t virtiofs <tag> <path>      # MS_NOSUID | MS_NODEV [| MS_RDONLY]
```

Outer paths are mounted before inner ones, so a nested pair cannot bury the
inner mount underneath the outer one. No `data` string is passed: the
virtiofs driver accepts only `dax` and `source`, and DAX needs a shared
memory window Virtualization.framework does not expose, so anything else
would be rejected with `EINVAL`.

A share that fails to mount is logged loudly and skipped; it must never
stop the boot. The loudness is the point, because **the downstream symptom
is mute**: dockerd *creates* a missing bind source rather than refusing, so
an unmounted share presents as an empty directory inside the container with
nothing anywhere saying why.

### 5.3 The `shares` field of `info`

So the host can tell the user which of the directories it configured
actually made it in, the `info` reply carries:

```
shares: "<percent-encoded-path>:<mounted|failed>,..."
```

A flat, comma-joined string because MRB0's jsonlite codec is single-level by
construction (§4). The paths use the same percent encoding as the command
line, so a path containing a comma or a colon cannot be mistaken for a
separator. Additive: a host that predates it ignores it, and a guest that
predates it simply omits it, which the host reports as "the guest did not
report on its shares" rather than as a failure.

The host decodes it with `MorbShares.parseGuestShares`, surfaces it through
the daemon's `shares` command and the `shares_degraded` count in `status`,
and renders it in `morb shares`, `morb doctor` and the app.
