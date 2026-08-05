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
