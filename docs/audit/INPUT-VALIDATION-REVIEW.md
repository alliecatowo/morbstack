# Input-Validation Review: guest/morbinit wire parsers

Scope: parsing and bounds-checking correctness for everything in
`guest/morbinit/src/` that reads framed messages off a socket. Questions asked
per file: is every length bounded before it is used to allocate or index; can
an integer overflow/underflow or a cast truncate a length; on a truncated read
mid-message, is the result a clean error or partially-applied state; is any
work done on message content before its authenticity is checked; can a path
derived from a message escape its declared root; are error paths free of leaks
(descriptors, allocations, held locks, staged files).

Reviewed 2026-08-04 at branch `swarm/continuation` (base `8f969ba`). Method:
full line-by-line source read of every file in the coverage table, cross-checked
against the host-side senders in `mac/Sources/MorbstackKit` where the wire
format is defined on both ends, plus `docs/protocol.md`. Fixes verified by the
full `mise run check` gate (both test suites, clippy for host and
`aarch64-unknown-linux-musl`, fmt, shellcheck, task validation).

## Coverage

| File | Status | Notes |
| --- | --- | --- |
| `live_share_receiver.rs` | **Fully reviewed** | Whole file, incl. the Linux-gated `imp` module; CLOSE verification cross-checked against `MorbLiveShareTransport.swift` |
| `live_share.rs` | **Fully reviewed** | Whole file; new malformed-input tests added |
| `wire.rs` | **Fully reviewed** | SEC-1 confirmed and fixed here |
| `jsonlite.rs` | **Fully reviewed** | |
| `control.rs` | **Fully reviewed** | MRB0 framing + dispatch; shutdown handshake read for error-path behavior only |
| `k8s.rs` | **Fully reviewed** (install channel + parsers) | The k3s service-spec/monitor plumbing was read but is not input-parsing; the install channel, `parse_install_request`, `receive_payload`, and both table parsers were reviewed in full |
| `dial.rs` | **Fully reviewed** | |
| `datagram.rs` | **Fully reviewed** | |
| `proxy.rs` | **Fully reviewed** | Dumb pipe by design; `copy_stream` and `busy_response` are the only parsing-adjacent code |
| `sha256.rs` | **Fully reviewed** | Implementation checked against FIPS 180-4; test vectors verified to be the published values |

Not in scope and not reviewed: `binfmt.rs`, `disk.rs`, `dns.rs`, `mounts.rs`,
`net.rs`, `netaddr.rs`, `proxy_wrapper.rs`, `shares.rs`, `supervisor.rs`,
`sys.rs`, `main.rs`, `log.rs`. Of these, `dns.rs` and `netaddr.rs` also parse
untrusted-ish input (DNS packets, address strings) and would be the natural
next slice.

## Findings

### Fixed in this review

**SEC-1 (medium) — unbounded read on bare `\r` in the install preamble.**
`wire.rs`: `read_install_preamble_line` drops every `\r` as it is read, and
dropped bytes counted toward *no* cap — only kept bytes were checked against
`max`. A peer streaming bare `\r` without ever completing a line was read
forever by that function alone (`read_preamble_raw` checked only `buf.len()`).
Reachable from vsock port 2377 pre-authentication. **Fix:** `read_preamble_raw`
now bounds total bytes consumed at `2 * max + 2` independently of the line
cap; the flood errors after ≤514 bytes at the 256-byte install cap. Legitimate
CRLF traffic is unaffected (at most one `\r` per real line), pinned by a
regression test; `read_preamble_line`'s behavior is provably unchanged because
its kept-byte cap always trips first (also pinned by test). 3 new tests.

**SEC-2 (low severity, real interop bug) — live-share `CLOSE` HMAC verified
over the wrong string.** `live_share_receiver.rs:253` (pre-fix) verified the
CLOSE HMAC over `fields[1]` — the bare sequence digits — while the host signs
`"CLOSE <sequence>"` (`MorbLiveShareTransport.swift:547`:
`let body = "CLOSE \(nextSequence)"`). Two consequences: every authentic host
close failed verification (benign only because the host fires the line and
shuts the socket without awaiting `STOPPED`), and the verb was outside the
authenticated bytes (no domain separation — the tag was an HMAC of an
unqualified decimal string). **Fix:** new `close_is_authentic` verifies over
`fields[..2].join(" ")`, i.e. exactly the string the host signs; test pins the
host wire format and rejects the old bare-digits coverage. Guest-side only.

**Staged-file cleanup on k8s install error paths (low).** `k8s.rs`
`receive_payload` removed its `.{name}.incoming` staging file on truncation
and digest mismatch, but not on write/flush/`sync_all`/rename errors — a
failed transfer could leave up to 512 MB squatting on the persistent disk
until the next attempt. **Fix:** the streaming body is now
`stream_verify_rename`, path-parameterized (so it unit tests on macOS), and
every error path removes the staging file. 3 new tests cover success,
truncation, and digest mismatch, all asserting the staging file is gone and no
partial binary is reachable at the final path.

### Filed, not fixed (structural)

**SEC-3 (low) — live-share receiver has no post-handshake read deadline.**
After the hello, `serve_connection` reads event lines with no timeout, and
`MAX_CONNECTIONS` is 4. Idle handshaken connections pin all four slots until
the peer closes. Only the paired host daemon can reach the port (vsock), so
this is hygiene, not exposure. Same family as the pre-existing **PROTO-4**
(k8s install channel has a 10 s preamble poll but no bound on the body
transfer, and the listener is serial — one stalled `PUT` wedges all later
installs). Both filed in `TASKS.md`; one idle-read discipline fixes both.

### Notes — reviewed, judged acceptable

- `live_share_receiver.rs` `percent_decode` allows escapes to decode to any
  byte, including control characters. Downstream `validate_relative_path` /
  `validate_absolute_path` reject NUL, and `%2F` decodes to `/` *before*
  component validation runs, so it cannot smuggle a separator past the
  containment checks — it just becomes one. Control characters other than NUL
  are legal Linux filename bytes and the receiver only ever does
  descriptor-confined no-follow metadata nudges with them.
- `percent_decode` bounds input at `3 * MAX_PATH_BYTES` before its single
  allocation, and its truncated-escape check (`index + 2 >= len`) is exact —
  `%ab` at end-of-string decodes, `%a` errors.
- `control.rs` `read_frame` checks the u32 length against the 1 MiB cap
  *before* `vec![0u8; len]`; a claimed 4 GiB frame errors without allocating.
  Truncation inside magic/length/payload all surface as clean `read_exact`
  errors; no partial state.
- `jsonlite.rs` is iterative (nesting is rejected, so there is no recursion
  and no stack risk), allocation is bounded by input length (which the caller
  caps at 1 MiB), `\u` escapes that are not valid scalars (including
  unpaired/paired surrogates — pairs are unsupported) fail closed, and
  oversized integers error via `i64::parse` rather than wrapping. Duplicate
  keys are last-wins, which is fine for a flat protocol whose emitter never
  produces duplicates.
- `datagram.rs` `read_frame` distinguishes clean EOF-before-header from
  EOF-mid-frame, checks the length against `MAX_DATAGRAM_BYTES` (65,507)
  before allocating, and retries `Interrupted` in both loops.
- `dial.rs`/`datagram.rs` preambles: strict grammar, `u16` parse with explicit
  digit check first (so `+80`/`-1`/`0x50` are rejected before `parse` could
  accept them), port 0 rejected.
- `sha256.rs` is a correct FIPS 180-4 implementation: padding loop handles the
  55/56/57 and 63/64/65 boundaries (tested), streaming is chunk-invariant
  (tested), and the four published vectors in the tests are the genuine NIST
  values. The `u64` byte counter caps honest input at 2^61 bytes, irrelevant
  at 512 MB scale. Digest comparison in `k8s.rs` is non-constant-time, which
  is fine — digests are public values, not secrets. (HMAC comparison in the
  live-share receiver *is* constant-time, correctly, because there the tag is
  keyed.)
- Casts and arithmetic: no length ever flows from wire to allocation without
  a prior cap check in any reviewed file; the only wire-to-`usize` casts are
  `u32 as usize` (lossless on the 64-bit targets this builds for) after the
  cap comparison is done in the wire type's own width.
- Error-path resources: every listener uses the shared RAII `ConnGuard` (drop
  runs on panic too — tested in `wire.rs`), file descriptors are owned `File`s
  dropped on every early return, `nudge_tree` holds at most ~2 fds per
  recursion level with depth capped at 64, and the k8s `install_lock`
  poisoned-mutex path is handled explicitly.

## What is done well

- **Bounded lines everywhere, before this review.** Every line-oriented
  listener reads byte-at-a-time under an explicit cap
  (`read_preamble_line`), so no peer can force unbounded buffering by
  withholding a newline — SEC-1 was the single exception, in the one flavor
  that dropped bytes instead of keeping them.
- **The live-share capability handshake is genuinely careful.** The
  capability is fresh per connection; the guest proves it parsed the entire
  immutable claim transcript before the key is trusted (`COMMIT` covers every
  HELLO/ROOT byte including newlines); event HMACs are verified before any
  percent-decoding of the path or any filesystem access; HMAC comparison is
  constant-time; sequence numbers are strictly monotonic with
  `checked_add` exhaustion; and rejected records do not advance the cursor.
- **Descriptor-confined, no-follow filesystem delivery.** Validated relative
  paths are walked component-by-component with `openat` + `O_NOFOLLOW` from a
  root descriptor; symlinks (`ELOOP`) are skipped, `read_dir` results are
  re-verified through the descriptor open (rename races acknowledged in a
  comment), and tree rescans are budgeted (65,536 nudges, depth 64) with
  budget exhaustion reported as `rescan-required` rather than a partial scan
  reported as complete.
- **Lexical path validation is strict and layered.** `validate_relative_path`
  and `validate_absolute_path` reject empty/dot/parent components, NUL,
  trailing slashes, oversized components (>255 bytes) and oversized paths
  (>4,096 bytes); `is_strict_descendant` does the `/`-boundary check that
  prevents `/Users/me-evil` matching `/Users/me` (now pinned by test); and
  `RelativePath`'s private field means an unvalidated string cannot reach the
  filesystem applier by construction.
- **The k8s install channel's allow-list-first design.** The payload name is
  checked against a two-entry allow-list at parse time (a traversal name
  never reaches path construction), the length is capped before a byte is
  written, and write-verify-rename means a binary that fails its digest is
  never reachable at an exec-able path.
- **Caps before allocation as a habit.** MRB0's 1 MiB check before `vec!`,
  the datagram codec's 65,507 check before `vec!`, percent-decode's
  3×PATH_MAX check before its buffer — the pattern is consistent.
- **Uniform, panic-safe accept-loop plumbing** (`ConnGuard`, bounded
  best-effort busy replies with `poll(2)` so a wedged peer cannot stall the
  accept thread).

## Test delta

11 new tests (248 → 259 running on the host, plus one Linux-gated test that
is compile-checked by the musl clippy/check passes):

- `wire.rs`: bare-`\r` flood is bounded (SEC-1 regression); moderate CR noise
  still parses; the total bound is unobservable for `read_preamble_line`.
- `live_share_receiver.rs` (Linux-gated): CLOSE is verified over exactly the
  string the host signs; bare-digits coverage, missing tag, foreign key, and
  a resequenced line all fail closed.
- `live_share.rs`: every lexical escape shape for relative paths; absolute
  path rejection matrix; the shared-name-prefix containment boundary;
  structural hello limits (version, zero session id, 0 and 9 roots, duplicate
  root ids, unknown backing tag, malformed root ids); wrong
  session/boot/epoch/root records are rejected without advancing the cursor.
- `k8s.rs`: `stream_verify_rename` success (mode 0755, staging file gone),
  truncated stream (clean `UnexpectedEof`, nothing reachable, staging file
  removed), digest mismatch (nothing reachable, staging file removed).

---

# Part 2: the MCP server, and everything that shells out

Scope: `mac/Sources/MorbMCP/**` (the MCP server an AI agent drives), every
process-spawning site under `mac/Sources/**`, and the four guest files Part 1
listed as out of scope. Questions asked per file: is the permission check on the
single path every call must cross or is it per-tool and therefore skippable; is
the audit log complete (including failures and rejected calls), unforgeable, and
free of secrets; does JSON-RPC parsing bound before it allocates; is any
model-supplied string interpolated into a command line, an HTTP request, or a
path without validation; is `PATH`/environment handling controlled.

Reviewed 2026-08-05 at branch `swarm/continuation` (base `2b0ab46`). Method:
full line-by-line source read of every file in the coverage table, plus the
Engine API client and the subprocess helper the MCP tools call into, because a
review that stops at the module boundary would have missed the highest-severity
finding here — which lives one call below it.

## Coverage

| File | Status | Notes |
| --- | --- | --- |
| `MorbMCP/Server.swift` | **Fully reviewed** | Dispatch, permission placement, stdio line reader, response bounding |
| `MorbMCP/Permissions.swift` | **Fully reviewed** | Resolver, precedence, `mcp.toml` parser, `--allow` parser |
| `MorbMCP/ToolRegistry.swift` | **Fully reviewed** | |
| `MorbMCP/ToolSpec.swift` | **Fully reviewed** | Incl. `ToolContext.shellOutEnvironment()` |
| `MorbMCP/ReadOnlyTools.swift` | **Fully reviewed** | All 9 tools |
| `MorbMCP/MutatingTools.swift` | **Fully reviewed** | All 13 tools |
| `MorbMCP/Audit.swift` | **Fully reviewed** | Redactor, append/fsync, record builders, reader |
| `MorbMCP/JSONRPC.swift` | **Fully reviewed** | |
| `MorbMCP/ArgHelpers.swift` | **Fully reviewed** | |
| `MorbMCP/Utilities.swift` | **Fully reviewed** | Path validation, compose resolution, redactors |
| `MorbMCP/MCPCLI.swift`, `Entry.swift` | **Fully reviewed** | |
| `MorbFeatures/EngineClient.swift` | **Reviewed for request construction** | `path`/`writeRequest`/`upload` read in full — this is where MCP-1 lives. The chunked/streaming body decode and `download`/`upload` progress plumbing were read but are not agent-reachable input paths |
| `MorbFeatures/Subprocess.swift` | **Fully reviewed** | Argument arrays, `PATH` resolution, pipe draining, timeout kill |

Not reviewed: the four guest files this review's Part 1 deferred
(`binfmt.rs`, `disk.rs`, `dns.rs`, `mounts.rs`) — see "Not reached" at the end.
`MorbstackAppCore/DockerClient.swift` was read only far enough to establish that
it shares MCP-1's shape with a different (non-agent) input source; it is owned by
other work in flight and was not modified here.

## Findings

### Fixed in this review

**MCP-1 (high) — a model-supplied container id could rewrite the Docker Engine
API request line, from a tool that needs no grant.**
`EngineClient.path` percent-encoded query *values* only; the path was
interpolated raw (`/containers/\(id)/json`) and spliced straight into
`"\(method) \(target) HTTP/1.1\r\n"` (`EngineClient.writeRequest`). Two
consequences, both reachable from the MCP server:

- **Request smuggling.** A `container_inspect` or `container_logs` call — both
  read-only, both available with an empty `mcp.toml` and no `--allow` at all —
  with `id` containing `CRLF` ends the request line early. Our own headers
  (including `Connection: close`) then land on whatever the attacker wrote after
  the blank line, so the engine reads the connection as two pipelined requests
  and serves both. The second one can be any method and any route: `POST
  /containers/x/kill`, `DELETE /containers/x`, `POST /volumes/prune`. That is the
  entire mutating surface, reached without a grant and audited as a read-only
  inspect. (Reasoned from Go's `net/http` pipelining and our own header order,
  not demonstrated against a live engine — this review does not run the daemon.)
- **Guard bypass.** A `?` in an id starts a query string ahead of the parameters
  the call meant to send. Go's `url.Values.Get` returns the *first* value, so
  `container_remove` with `id: "web?force=1&"` sends `force=1` while the tool
  believed it sent `force=0` — defeating `container_remove:force`, the guard
  whose entire job is that `containers:write` must not imply force-killing a
  running container.

**Fix, in two layers.** The load-bearing one is at the choke point every Engine
request crosses: `EngineClient.path` now percent-encodes the path, keeping only
`/` (structure) and the characters Docker's identifier and image-reference
grammars actually use. Encoding rather than rejecting keeps it total and
lossless — the engine percent-decodes before route matching, so an odd but honest
name still reaches the right handler. The second layer is
`MorbMCP/Identifiers.swift`: `id` arguments are checked against Docker's own
container-name grammar and `reference`/image `id` arguments against a reference
grammar, because `/` stays literal in a path and `web/json` would otherwise still
reshape which route the engine matches. 4 new tests pin the encoding, the
grammars, and that error text never echoes a raw control byte back into the
transcript.

**MCP-2 (low) — a `tools/call` that arrived before `initialize` was refused
without being audited.** `Server.handle`'s `guard hasInitialized` returned early,
above every call site that writes a record, so "no record" meant either "never
asked" or "asked out of order" — exactly the ambiguity the log exists to remove.
**Fix:** the pre-handshake rejection now records the attempt like every other
refusal. Test pins it, alongside a test for the already-correct notification
rejection path.

**GUEST-1 (low) — the split-DNS forwarder relayed whatever answered first.**
`dns.rs` `forward` opened an unconnected UDP socket, `send_to`'d the upstream,
then `recv_from`'d and relayed the first datagram that arrived on that ephemeral
port back to the querying container. Nothing checked the sender. Any container
sharing the guest network could race the real upstream with a forged answer for
any name this stub does *not* handle itself (it handles only the two
`*.docker.internal` names locally). The window is one query and 3 s wide and the
source port is random, so this is a race a local attacker has to win, not a
handout — but the check costs one syscall. **Fix:** the socket is `connect`ed to
the upstream before the send, so the kernel drops datagrams from every other
source; send/recv become `send`/`recv`. Linux-gated code — compile-checked by the
`aarch64-unknown-linux-musl` clippy pass, **not** provable by a host unit test,
and not exercised against a running guest in this review.

**GUEST-2 (low) — `/proc/mounts` octal escape decoding could overflow a `u8`.**
`disk.rs` `decode_mount_field` accepted three octal digits (`(b-'0')*64 + …`) in
`u8` arithmetic, so any escape from `\400` to `\777` overflows: silently wrapping
in the shipped release profile (`overflow-checks` off) and aborting in a checked
build — and morbinit is PID 1 with `panic = "abort"`, so an abort there is a
kernel panic. Unreachable from a real `/proc/mounts` (the kernel emits only
`\040`, `\011`, `\012`, `\134`), which is why this is low rather than high.
**Fix:** the arithmetic widens to `u16` and an out-of-range value is a refusal,
which is what every other malformed escape in that function already produces.
1 new test covering the overflow range, the in-range boundaries, and truncation.

### Filed, not fixed (structural)

**SEC-4 (low) — the audit log records up to 500 characters of tool output.**
`AuditLog.recordToolCall`'s `result_summary` is the first 500 characters of the
tool's result text. Arguments are redacted carefully (key substrings, plus `env`
maps wholesale); results are not redacted at all. For `container_inspect` with
the `inspect:env` grant the result is the *deliberately unredacted* document and
its keys are sorted, so `Config.Env` lands well inside 500 characters — the
grant that says "this agent may see secrets" silently also says "and they get
written to a file that outlives the session". `container_logs` and
`container_exec` pass their output through `LogRedactor` first, which is
best-effort by construction. Mitigations already in place: the file is created
0600 and has its mode re-asserted on every open. Not fixed here because the fix
is a decision about what the log is *for* — dropping successful summaries to a
byte count preserves the "which tool, which arguments, which outcome" claim but
loses forensic detail, and picking per-tool would put the judgement back in each
tool, which is the failure mode this review exists to find. Filed in `TASKS.md`.

**SEC-5 (low, truthfulness) — `docs/mcp.md` does not exist.** Seven places cite
it, including two strings an *agent* reads at runtime: every `container_logs` and
`container_exec` result carries `"redaction": "best_effort_pattern_match — see
docs/mcp.md; not a guarantee"`, and `container_inspect`'s own description points
at "docs/mcp.md's threat model". The threat model those strings promise is real
and is written down — in source comments — but a public repo whose tool output
cites a missing file is exactly the "promises behaviour the implementation does
not have" this project's standing rule forbids. Same file: `Audit.readAll` is
documented "for `morb mcp audit`", a subcommand `MCPCLI` does not implement (the
usage text lists three, and audit is not one) — so the reader is currently only
reachable from tests. Filed in `TASKS.md`; it gates nothing technical but it is
the kind of thing a first reader of a newly public repo finds in ten minutes.

**SEC-6 (informational) — `MorbstackAppCore/DockerClient.swift` builds Engine
paths the same way MCP-1 did.** ~20 sites interpolate an id straight into a path
that becomes an HTTP request line. The input source is different in kind — names
that came back from the engine, or that the user typed into the app's own UI, not
a string an agent chose — so this is hardening rather than a live hole, and the
file is owned by other work in flight, so it was not touched. The same one-line
defence (route it through the now-encoding path builder, or adopt an equivalent)
belongs there. Filed in `TASKS.md`.

### The two claims, checked against the code

**"Read-only by default" — holds.** Verified rather than assumed:

- `PermissionProfile.decide` returns allowed-without-a-grant for exactly one
  reason: `subject.group == nil`. Every one of the 13 tools in
  `MutatingTools.all` carries a group; all 9 in `ReadOnlyTools.all` carry `nil`.
  A test now pins the ungated set by name, asserts every ungated tool is
  `readOnly && !destructive`, and asserts every non-read-only tool both has a
  group and is denied under an empty profile — so a future tool registered
  without a group fails the suite instead of shipping ungated.
- No config file, environment variable, or flag widens the default silently.
  The only inputs are `~/.morbstack/mcp.toml` (`allow`/`deny` arrays, parsed by
  a purpose-built reader that rejects unquoted or unterminated elements) and
  repeated `--allow` flags, and `parseAllowFlags` *fails* on any argument it does
  not recognise rather than ignoring it. `MORBSTACK_HOME` relocates the profile
  but cannot grant anything. Unknown keys are reported as warnings at startup and
  in `morb mcp permissions`, so a typo'd grant cannot masquerade as security.
- `deny` beats `allow` unconditionally, including over a command-line `--allow`.
- The ungated tools were read for what they can actually do: nine `GET`s plus a
  bounded `/events` window and a `status` round trip to `morbstackd`. None
  writes a file, spawns a process, or reaches a mutating Engine route.
  `container_inspect` redacts `Config.Env` and label values by default and needs
  the `inspect:env` grant for the raw document — the one guard on a tool with no
  group, and the right call: read-only and safe-to-hand-an-agent are different
  properties.

**The permission check is on the single path, not per-tool.** `callTool` is the
only route from `tools/call` to a handler; it resolves the name through
`ToolRegistry`, evaluates `profile.decide` and then every applicable
`ToolGuard` *before* `tool.handler` is called, and no handler re-checks (or can
skip) its own grant. This is the shape the proxy bug (EN-1) did not have.

**"Complete audit log" — holds now; it did not quite before.** Every path out of
`callTool` records: unknown tool name, denied tool, denied guard, and the
successful call, with duration and outcome. Missing/`non-object` `arguments` and
a missing `name` record too, as does a `tools/call` sent as a notification. The
one gap was a `tools/call` arriving before `initialize`, fixed above (MCP-2).
Bookends (`server_start` with the effective grant set and its warnings,
`server_stop`) are written by `MCPCLI.serve`, and `serve` refuses to start at all
if the log cannot be opened.

- **Forging:** records are built by `JSONSerialization`, so a tool name or
  argument containing a newline is escaped inside a JSON string and cannot
  fabricate a second record line. A caller controls the *values* in its own
  record, not the record structure or the decision field.
- **Suppression:** no caller-reachable switch. `append` does swallow write and
  serialisation failures — deliberately, and documented in place: a tool call
  that already happened must not be re-reported as broken because logging it
  failed. That leaves a real gap (a full disk loses records silently) which the
  code names honestly; it is not a caller-triggerable one.
- **Sensitive content:** arguments are redacted, results are not — SEC-4 above.

### Notes — reviewed, judged acceptable

- **Shell-outs are argument arrays throughout.** `compose_up`, `compose_down`
  and `image_build` are the only tools that spawn a process, and all three go
  through `Subprocess.run(executable, [args])` → Foundation `Process`, which
  `execve`s directly. No `/bin/sh`, no `-c`, no string interpolation into a
  command line anywhere in `mac/Sources/**` (checked repo-wide, not just in
  MorbMCP). A model-supplied `tag`, `dockerfile` or `build_arg` value that begins
  with `-` is consumed as the value of the preceding flag, not as a new flag,
  because it is its own argv element.
- **`DOCKER_CONFIG` is correct, and this is a correctness question, not
  hygiene.** `ToolContext.shellOutEnvironment()` points `DOCKER_CONFIG` at
  `~/.morbstack/mcp-docker-config` (created with a literal `{}` config),
  overrides `DOCKER_HOST` to Morbstack's socket, and removes `DOCKER_CONTEXT`.
  So a compose/build shell-out cannot read the user's registry credentials, and
  — the failure mode this repo has been bitten by — cannot inherit a `credsStore`
  whose helper hangs the Docker CLI. `resolveComposeBinary` *reads* (never
  writes) `~/.docker/cli-plugins/docker-compose`, which is the documented install
  location, and invokes it as a standalone binary precisely because the plugin
  resolver would look under the redirected `DOCKER_CONFIG` and not find it.
- **A subprocess cannot corrupt the JSON-RPC stream.** Both pipes are captured
  and stdin is `/dev/null`; `serve` writes nothing but JSON-RPC to stdout and
  sends every human-facing message to stderr.
- **`PATH` is inherited.** `Subprocess.which` searches the inherited `PATH`
  first, then appends the standard Homebrew/system directories, so `image_build`
  runs whatever `docker` that `PATH` resolves. That is the same trust the user's
  own shell extends and the MCP server is launched by the user's own client;
  worth knowing rather than worth changing, since pinning to an absolute path
  would break the documented "install Docker's CLI separately" path.
- **JSON-RPC framing bounds before it allocates.** The stdio reader never
  buffers more than 1 MiB + one chunk: an oversize line switches to a discard
  state that drops data as it arrives and resynchronises on the next newline
  (now pinned by test, including that the *following* record still parses).
  Foundation rejects deeply nested JSON rather than recursing — a 200k-deep array
  inside the size cap returns a parse error, tested — so the byte cap is
  sufficient on its own. Unknown methods get `-32601`; malformed notifications
  stay silent, which is what the spec requires; invalid `id` types are replaced
  with `null` rather than echoed. Responses are bounded on the way out too.
- **Argument coercion is total.** `Args.boundedInt` clamps rather than erroring
  (deliberate, and the bounds are what stop `events_subscribe`/`container_logs`
  from pinning the process); missing or wrong-typed fields produce an
  `isError` tool result, never a crash and never a JSON-RPC error.
- `validateProjectDirectory` is TOCTOU by nature (exists-check, then spawn), but
  the spawned CLI has the same filesystem access this process does either way —
  the check is about an agent not being able to point a "project directory" tool
  somewhere other than the path it was told, which it achieves.
- `prune` validates its targets against a five-entry allow-list before any
  request, and per-target failures are collected rather than aborting the rest.
- `binfmt.rs` and `mounts.rs` (guest) parse no untrusted input at all: every
  registration field is a compile-time constant, `is_valid` refuses a `:` or
  newline in any field before the write, `decode_escaped` is strict about
  malformed escapes, and the mount table comes from the host's own kernel command
  line. `decode_escaped`'s bounds check (`i + 3 >= len`) is exact. No findings.
- `disk.rs` beyond GUEST-2: `probe_is_blank` resolves every failure *away* from
  formatting, the format-intent marker requires the full magic plus a nonzero
  version byte (so a torn write reads as "not a marker"), `parse_df_capacity_bytes`
  uses `checked_mul`, and `store_grow_receipt` writes a `create_new` 0600 temp
  under a PID-specific name and renames — an attacker-pre-created temp makes it
  fail closed rather than follow a link. The grow receipt does live inside
  `/var/lib/docker`, so a forged receipt could make a retry report
  `previously_proved` — but writing there already requires guest root, which is
  strictly more capability than the receipt confers.

### Test delta

12 new Swift tests (`mac/Tests/MorbFeaturesTests/MCPInputValidationTests.swift`)
and 1 new Rust test (`disk.rs`): 914 → 926 Swift, 259 → 260 Rust.

- Engine path encoding: a CRLF-bearing id produces no `CR`, `LF` or space in the
  request line; a `?`-bearing id produces exactly one query string and the
  caller's parameters are the only ones in it; real ids, image references with
  registry ports and digests, and query encoding are all unchanged.
- Identifier grammars: accept/reject matrices for container ids and image
  references, and that a control byte is named (`U+0007`) rather than echoed.
- The ungated tool surface: the set by name, read-only/non-destructive for
  everything in it, a group plus a denial for everything outside it, no duplicate
  tool names, every guard key grantable.
- Audit: a `tools/call` before `initialize` is recorded; a `tools/call`
  notification is recorded and answered with silence; a denied `container_exec`
  is recorded with its `env` values redacted.
- Framing: 200k-deep nesting is a parse error; an oversize line is discarded and
  the reader resynchronises on the next record.
- Guest: `/proc/mounts` escapes above `\377` are refused, boundaries decode.

### Not reached

- **No live engine, no daemon, no GUI.** Every claim here is from source plus
  unit tests. MCP-1's smuggling consequence in particular is reasoned from Go's
  HTTP pipelining and our own header order; what is *tested* is that the bytes
  which enabled it can no longer reach the request line.
- **Linux-gated guest code is compile-checked only.** GUEST-1's fix is covered by
  the musl clippy/check pass, not by an executed test.
- **`MorbstackAppCore/DockerClient.swift`** (SEC-6) and the app's own exec/PTY
  paths were not reviewed — owned by other work in flight.
- **Not re-reviewed here:** the vsock ports OPS-8 also names (1024/2375/2376/
  2378/2381/2382). Part 1 covered 2377 and the live-share port in full;
  `GuestPortLease.parseRequest` (host) and `proxy_wrapper.rs`'s `parse_reply`/
  `parse_invocation` (guest), added by TECH-1, remain unreviewed.

### Gate status at the end of part 2

`mise run check` exits 1, and not because of anything in this review. Every step
is green — `cargo test` 260/260, clippy for the host *and*
`aarch64-unknown-linux-musl` with `-D warnings`, `cargo fmt`, shellcheck, task
validation — and the Swift suite passes 965/965 with one suite skipped:
`MorbstackAppTests/DockerExecPTYSessionTests`, an untracked file belonging to the
terminal/exec work in flight, whose 8 socket-fixture cases time out
(`the start request never arrived`). Its failures predate and are independent of
this review's changes; none of the files it exercises were touched here. The
`doctor` step also reports drift (a running app older than the just-rebuilt
binary) — advisory by design, and left alone rather than restarting a daemon this
session did not start.
