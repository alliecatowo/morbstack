# `morb bench` — the open benchmark harness

`morb bench` measures Morbstack against the public performance target table in
[`docs/roadmap.md`](roadmap.md#public-performance-target-table) and reports
PASS/MISS/N/A/SKIPPED for each row — never a fabricated number for a
benchmark that could not honestly run. See
`mac/Sources/MorbBench/Benchmarks/Benchmark.swift` for the `Benchmark`
protocol every entry implements, and `mac/Sources/MorbBench/Support/` for the
statistics, target table, and safety-guard code referenced below.

## Setup: a private `MORBSTACK_HOME`

`morb bench` follows the same `MORBSTACK_HOME` convention as every other
`morb` subcommand — it measures whatever engine that variable points to. Four
of the eight benchmarks (`cold-boot`, `resume`, `idle-cpu`, `idle-wakeups`,
`host-rss`) stop, start, suspend, resume, or otherwise treat the VM as idle,
and running them against your normal `~/.morbstack` would disrupt or lie
about whatever else is using it. `StackGuard` (`Support/StackGuard.swift`)
refuses outright to cycle the VM at the default home, and refuses to call an
engine "idle" while containers are visibly running on it.

Point `MORBSTACK_HOME` at a short-named scratch directory before running the
full suite — short, because every Morbstack socket lives under it and
`sockaddr_un.sun_path` is 104 bytes on Darwin (see `CLAUDE.md` §1.3):

```sh
export MORBSTACK_HOME=/tmp/mb-bench
morb start
morb bench run
```

`git-status-bindmount` and `npm-install-bindmount-vs-volume` only *observe*
the engine (create and remove their own throwaway containers/volumes) — they
do not cycle the VM — but they still refuse to run over other visibly-running
containers, for the same "the number would be fiction" reason `idle-cpu` and
friends do.

## Running it

```sh
morb bench list                    # the full target table; unimplemented rows say so, not PASS
morb bench run                     # measure every implemented benchmark; never implicit
morb bench run --only cold-boot,resume
morb bench run --dry-run           # print each benchmark's exact steps; no side effects
morb bench run --runs 10           # repetitions for the timing benchmarks (default 5)
morb bench compare latest previous # classify regression/improvement/noise between two stored runs
```

Every run is written to `~/.morbstack/bench/<timestamp>-<id>.json`
(`Support/RunRecord.swift`) so `compare` has something to read back. `compare`
classifies a delta as noise below 5%, not 2% — see `Support/Targets.swift`'s
`RegressionPolicy` doc comment for why cold-boot's own run-to-run spread on a
real Mac already exceeds a tighter threshold.

## The eight benchmarks

| Benchmark | Target | What it measures |
| --- | --- | --- |
| `cold-boot` | ≤ 2.0 s | Stopped VM to a usable Docker API (`GET /_ping` answering), median of `--runs` repetitions. |
| `resume` | ≤ 500 ms | `suspend` to a usable Docker API after `resume`; reports honestly when the host cannot restore saved VM state. |
| `idle-cpu` | ≤ 0.1 % | Host CPU used by `morbstackd` with nothing running in the guest. |
| `idle-wakeups` | < 20/s | Idle wakeups/second for `morbstackd`. |
| `host-rss` | ≤ 120 MB | Resident set size of `morbstackd` at idle. |
| `guest-memory-floor` | ≤ 256 MB | Memory in use inside the guest with no containers running (`MemTotal - MemAvailable`, read via a throwaway container). |
| `git-status-bindmount` | ≤ 2x native | `git status` on a VirtioFS bind mount vs. the same repo on a Docker named volume (guest-native storage). |
| `npm-install-bindmount-vs-volume` | ≤ 1.5x native | `npm install` writing into a bind mount vs. the same install writing into a named volume. |

The current measured numbers for the first six are in
[`docs/audit/ENGINE-MATRIX.md`](audit/ENGINE-MATRIX.md) §10 — 1.79 s cold
boot, 0.0% idle CPU, 23 MB idle RSS on the machine that produced that audit.
Reproduce them yourself with `morb bench run`; nothing about that command is
specific to the machine that first ran it.

### `git-status-bindmount` and `npm-install-bindmount-vs-volume` methodology

Both benchmarks answer the same question two different I/O shapes need
answered separately — reads for `git status`, many small writes for
`node_modules` — and both use the identical comparison: the *same* content on
two storage backends inside the *same* guest kernel, so the only variable is
VirtioFS vs. the guest's own filesystem.

1. A scratch project (a small synthetic git repo, or a pinned three-dependency
   `package.json`) is written once under `/private/tmp` — VirtioFS-shared by
   default (`MorbShares.defaultSharedPaths`) — and copied byte-for-byte into a
   scratch Docker named volume.
2. `git-status-bindmount` builds a one-off `git`-capable image (no upstream
   image ships both `git` and this harness's other assumptions); `npm-install
   -bindmount-vs-volume` warms a persistent npm-cache volume with one real,
   online `npm install` so every timed sample afterward runs `--offline` —
   otherwise the measurement would be "how fast is the npm registry today,"
   not "how much does the bind mount cost."
3. Each timed sample is one full throwaway container
   (create → start → wait → remove) running the operation once against
   whichever leg is being measured. Per-container overhead is identical on
   both legs, so it cancels out of the reported bind-mount/volume *ratio*
   even though it is not removed from either leg's absolute number (both are
   published in the result's notes).
4. Everything scratch — the host directory, the volumes, and (for
   `git-status-bindmount`) the built image — is removed at the end, success
   or failure.

## Live-share watcher conformance matrix

Morbstack's hot-reload bridge (`MorbLiveShareTransport` on the host,
`guest/morbinit/src/live_share_receiver.rs` + `sys::nudge_metadata` in the
guest) nudges a changed file with a same-mode `fchmod(2)` rather than
delivering real file content into the guest. Native VirtioFS/FUSE has no
inotify passthrough at all (the 2021 RFC, LWN 874000, never merged), so this
is the accelerant every VM-based Docker Desktop alternative in this market
ends up faking, syncing, or shipping without — see
[`docs/audit/TECHNOLOGY-AUDIT.md`](audit/TECHNOLOGY-AUDIT.md) "Bet 4" and
[`docs/audit/PRODUCT-AUDIT.md`](audit/PRODUCT-AUDIT.md) for the full writeup
this table summarizes.

`fchmod(2)` emits `IN_ATTRIB`, not `IN_MODIFY` or `IN_CLOSE_WRITE`. Whether a
given watcher reacts to that depends entirely on whether its inotify backend
treats `IN_ATTRIB` as a change worth reacting to:

| Watcher backend | Ecosystem | Treats `IN_ATTRIB` as a change | Reloads on a Morbstack bind-mount edit | Representative tools |
| --- | --- | --- | --- | --- |
| libuv `fs.watch` / chokidar | Node.js | Yes | Yes | nodemon, Vite, webpack-dev-server |
| `watchdog` | Python | Yes | Yes | Flask/Django autoreload (watchdog backend), pytest-watch |
| `fsnotify` | Go | No — maps it to a distinct `Chmod` op that consumers routinely filter out | No (typically) | `air`, CompileDaemon, most Go live-reload tools |
| `notify-rs` | Rust | No — same distinct-op treatment as `fsnotify` | No (typically) | `cargo-watch`, `watchexec` |

Two caveats that apply even to a "Yes" row:

- **New files, not just edits.** A created file is signalled by nudging its
  *parent directory* with `IN_ATTRIB`, not the child with `IN_CREATE`.
  Whether a watcher rescans the directory on a bare attribute change is
  watcher-specific even among the "Yes" backends above.
- **This exact failure mode has already happened in production once.**
  colima/colima#1244 — "All inotify filesystem events are chmod/attribute
  events" — is the same `fchmod`-only mechanism silently breaking Go
  watchers for another VM-based Docker Desktop alternative. Treat the two
  "No" rows as a known, not hypothetical, gap.

The correctness-mode fix for the two "No" rows is tracked as DIF-1a in
`TASKS.md`: content-bearing messages on the same authenticated vsock
transport, written atomically into a real guest-local filesystem, so Go and
Rust watchers get genuine `IN_MODIFY`/`IN_CREATE` events instead of a nudge.
It needs a guest-image change and a live engine to prove, so it is not yet
built; this table exists so the gap it closes is published rather than
discovered by a user whose watcher went quiet.
