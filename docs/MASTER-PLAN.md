# Morbstack master plan

**Status:** live document. Supersedes `docs/roadmap.md`, `docs/drop-in-delivery-plan.md` and
`docs/competitive-capability-roadmap.md` as the single ordered source of truth. Those remain for
their detail; where they disagree with this file, this file wins.

**Rule of order:** operational integrity → parity hardening → differentiation. Nothing moves down
the list until the thing above it is *proven at runtime*, not merely written. That rule exists
because ignoring it is exactly how this project accumulated three headline features that had never
been executed by anything. See [audit/MASTER-AUDIT.md](audit/MASTER-AUDIT.md).

**Evidence vocabulary** — every status in this repo must use one of these three words. The old word
"implemented" is banned, because it silently merged the first two:

| Word | Means |
| --- | --- |
| `source-only` | the code exists and compiles. Nothing has run it. |
| `runs-here` | executed on a developer machine against the current build, with recorded output. |
| `accepted` | passed the clean-profile matrix on a machine that never had Docker. |

---

## Phase 0 — Operational integrity

The foundation. Everything here is about making it impossible to *not know* something is broken.

| # | Item | State |
| --- | --- | --- |
| 0.1 | Both suites compile and pass (739 Swift, 217 Rust) | **done** |
| 0.2 | Guest cross-compiles for aarch64-unknown-linux-musl | **done** |
| 0.3 | Moby patch compiles and its wire format matches the Rust/Swift ends | **done** |
| 0.4 | `mise run check` gates compile + tests + the guest's real target | **done** |
| 0.5 | Git remote exists | **done** — private, `alliecatowo/morbstack` |
| 0.6 | CI actually runs, on every push, and is red when it should be | push and confirm |
| 0.7 | Pre-commit hook installed and documented (`mise run install-hooks`) | **done**, not yet installed locally |
| 0.8 | Guest image rebuild is part of the loop | **done** — and the loop is `guest-image` → `app` → restart, because the daemon boots `runtime/current` staged from the bundle, not `data/kernel/`. A self-referential manifest check also froze the staged image permanently; fixed in `9f81cf4`. |
| 0.9 | **Remove the Docker-to-build-Docker bootstrap.** `build-patched-dockerd` needs `docker buildx`. Publish the built engine as a pinned, SHA-verified release artifact so a contributor with no Docker can build Morbstack. | **open** |
| 0.10 | A `mise run doctor` that reports staleness: is the initrd older than `guest/`? is the running daemon's inode the one on disk? is the patched dockerd in the image? | **open** |
| 0.11 | Complete the security review of the untrusted-input surfaces: vsock 1024/2375/2376/2377/2378/2379/2380/2381 and the MCP server | **open — treat as unreviewed** |

**0.10 is not optional polish.** Every serious error in the last two days came from trusting a name
over its contents: a daemon at the right path with an old inode mapped, an initrd predating its own
source, a `grep` that matched nothing because the directory had a different name. A staleness check
is the mechanical answer.

---

## Phase 1 — Parity hardening

Table stakes. If any of this is wrong, no differentiator matters, because the user's existing
workflow breaks on day one.

### 1.0 — WAS THE BLOCKER: the Docker API preflight was fail-open for real CLI traffic — **`runs-here`, closed**

Full writeup and evidence: **`docs/audit/PROXY-FRAMING.md`**.

**The defect.** `DockerProxy.preflightThenRelay` inspected **only the first HTTP request per
connection**, then spliced the socket raw. The `docker` CLI opens a connection, pings, and
*reuses* it — so `POST /containers/create` was essentially never inspected. Proven with one
identical body: **HTTP 400 on a fresh connection, HTTP 201 as the second request on a
keep-alive connection.** Every preflight guard in the codebase was correct, unit-tested, and
not actually running: `-v /etc/hosts:/x` served the **guest's** file, `/var/log` and `/Library`
silently became guest directories, and container writes to them silently vanished. The same
bypass disabled the create-time port-publication preflight.

**The fix.** A real HTTP/1.1 framing layer — `DockerRequestFraming.swift` and
`DockerFramedRelay.swift` — frames every request on the client-to-guest direction
(`Content-Length`, chunked, pipelining, bodyless) until the Engine actually hijacks the
connection, and only then splices. The response direction stays a raw backpressured splice, so
`logs -f`, `events` and `cp` are untouched. Hijack is **nominated on the request** (`attach`,
`exec` start, `session`, `grpc`, any `Upgrade`) and **confirmed on the response** (`101`, or a
`2xx` carrying Docker's raw/multiplexed stream type), which makes over-nomination free and a
missed hijack unlikely. A body too large to inspect is **refused** with a Docker-shaped `400`,
never waved through; so are the ambiguous framings (`Content-Length` with `Transfer-Encoding`,
repeated `Content-Length`) that would otherwise let a request smuggle past admission.
`DockerDynamicCreateTransaction` was retired — its bounded hold-back now runs inside the relay,
so it applies to a dynamic-port create anywhere on a connection.

**Verified live** against the rebuilt daemon (inode-checked, not name-checked): the original
experiment now yields **identical 400s both ways**; the full bind-mount matrix refuses `/etc`,
`/var`, `/Library` and symlink traversal with corrective messages while shared roots serve real
Mac content and container writes land on the Mac; the port matrix including
`-p 8080:80 -p 8080:81` passes; and `logs -f`, `exec -it`, `attach`, `cp` both directions,
`events`, BuildKit and classic builds, and the 3-service compose fixture all show no regression
(zero framing failures logged). `mise run check` green at 764 Swift / 217 Rust.

Residual risk is recorded in `PROXY-FRAMING.md` §2.7 — principally that hijack confirmation and
the held create assume a non-pipelining client, which no Docker client is, and which the
previous code assumed at connection granularity anyway.

| # | Item | State |
| --- | --- | --- |
| 1.1 | `docker run -P` end to end | first run **PASS**; stop/start/restart **FAIL** — the durable session EOFs 6 ms after its successful first allocation |
| 1.2 | Explicit `-p` in every form incl. UDP, ranges, `127.0.0.1:`, and the ambiguity case | **PASS**, incl. first-ever UDP run. Fixed, dynamic (`-p 80`) and `-P`, plus the `-p 8080:80 -p 8080:81` ambiguity refusal, re-confirmed through the real CLI after 1.0 landed |
| 1.3 | Bind mounts: `/tmp`, `/var`, `/etc`, `$HOME`, symlink-traversing paths | **PASS** — `runs-here`, re-run through the real CLI after 1.0 landed. `/etc`, `/var`, `/Library` and symlink traversal all refused with corrective messages; `/tmp`, `/private/tmp` and `$HOME` serve real Mac content; container writes land on the Mac. See `docs/audit/PROXY-FRAMING.md` §3.2 |
| 1.4 | `host.docker.internal` | **PARTIAL** — needs an explicit `--add-host` |
| 1.5 | Disk grow, fail-closed across crash/retry | **FAIL** — host/guest contract mismatch (`keyNotFound: 'device'`); image grew to 72 GiB while the guest filesystem stayed 62.4 G, and a *refused* grow still mutated configured capacity |
| 1.6 | Live-share / hot reload | `source-only`; first compile was today, listener now binds |
| 1.7 | Compose, BuildKit, buildx | `runs-here` — 3-service fixture, no regression; re-run at 12.9 s after the 1.0 framing change, plus a classic non-BuildKit build |
| 1.8 | `logs -f`, `exec`, `cp`, `stats`, volumes, networks, context | **PASS** post-rebuild; re-run after the 1.0 framing change incl. `attach`, `run -it`, a real-TTY `exec`, and a decisive raw-splice proof (`PROXY-FRAMING.md` §3.4) |
| 1.9 | Testcontainers (Java/Go/Node/Python) | **untested** |
| 1.10 | Dev Containers | **untested** |
| 1.11 | Clean-profile CP-01–CP-07 on a machine that never had Docker | **never run — the release gate** |

### Missing tests, ranked by risk

Coverage runs backwards from risk. These are the untested subsystems in the order their failure
would hurt most:

1. `VMManager.swift` (2,097 LOC) — no test boots or restores a VM.
2. `MorbDiskGrowth` journal — no test; it mutates a 68 GB disk image.
3. Live-share transport + both guest modules (~1,850 LOC, self-described "authority boundary").
4. `PublishAllPortAllocator` + guest `publish_all.rs` — untested on both sides.
5. The vsock relay's half-close, backpressure and cancellation behaviour under load.

---

## Phase 2 — Product truthfulness

Cheap, and it protects everything else.

| # | Item |
| --- | --- |
| 2.1 | Retract or qualify **"unmodified upstream dockerd"** in README, site, comparison, architecture, parity, roadmap. It is false: the Moby patch adds 174 lines and `mkinitramfs.sh` hard-fails without it. |
| 2.2 | Collapse the six overlapping status documents into one generated from a machine-checkable source. |
| 2.3 | Ship `scripts/fetch-scan-tools.sh` or stop referencing it five times — `morb scan` cites a file that does not exist. |
| 2.4 | Resolve `.local` vs `.test`: `domains.md:37` chose `.test`, `MorbLocalDomain.swift:17` hardcodes `morb.local`. |
| 2.5 | Delete or wire the ~1,750 LOC of inert subsystems (`MorbShareSyncProtocol.swift` 1,002 LOC zero callers; `MachineImageAdmission.swift` 581 LOC, `assess()` has no success path). Dead code that ships is worse than a stub screen. |
| 2.6 | Fixture-mode watermark — a `--tour-fixtures` window is indistinguishable from live and its footer claims "Engine running". |

---

## Phase 3 — UI correctness

[audit/UI-AUDIT.md](audit/UI-AUDIT.md) has 32 issues. About half the app was never toured, so treat
that as a floor.

1. The three blockers (fixture indistinguishability, bind-mount substitution as surfaced in the UI, `18,099`).
2. The XCUITest failures: missing Show/Hide Sidebar in the View menu; unmatched search not using `ContentUnavailableView.search`; 8 undescribed elements and 3 contrast failures.
3. The Containers toolbar: ~12 symbol-only items in 6 groups against a cap of 3, including two identical trash cans.
4. Narrow-width behaviour: vanishing toolbar items with no overflow, Images' Repository column, Disk inspector overdraw.
5. Accessibility identifiers — currently **zero** in the codebase, which weakens both VoiceOver and any future automated gate.
6. **Second UI pass** covering what was missed: Stacks, Kubernetes, Networks, Builds, Migration, Settings, ⌘K, menu-bar extra, light mode, prune/pull.

---

## Phase 4 — Distribution

Nobody has ever installed this. Until they have, every other claim is theoretical.

| # | Item |
| --- | --- |
| 4.1 | `scripts/release.sh`, `docs/RELEASING.md`, `.github/workflows/release.yml` — all referenced by name, **none exist** |
| 4.2 | Notarization — there is not one `notarytool` call in the repo. An unnotarized DMG is Gatekeeper-blocked for everyone but the author. |
| 4.3 | Homebrew cask |
| 4.4 | Sparkle or equivalent update channel (`docs/sparkle.md` is referenced and absent) |
| 4.5 | Make the repo public — only after 0.11 |

---

## Phase 5 — Differentiation

Only after Phases 0–1 are `accepted`. Ranked by impact per effort; rationale and the competitive
reality are in [COMPETITIVE-GAPS.md](COMPETITIVE-GAPS.md) and [audit/DIFFERENTIATION.md](audit/DIFFERENTIATION.md).

1. **Hot reload, proven, on by default, with a published watcher conformance matrix.** The mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB` only — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`. Nobody in this market publishes such a matrix. Also: `liveSharePaths` defaults to `[]` with no CLI or GUI writer.
2. **Container `exec` + a real PTY in the app.** There is no `exec` in `DockerClient.swift` and no PTY view. Both competitors put a shell one click away.
3. **Publish the benchmark harness.** `MorbBench` already measures cold boot, idle CPU, wakeups, RSS honestly. Missing the two targets people actually compare: `git-status-bindmount` and `npm-install-bindmount-vs-volume`. "Here is the harness, run it yourself" is something a closed competitor structurally cannot match.
4. **Container domains, sequenced as three products:** router-only first (no DNS, no CA — already beats hand-wiring Traefik + mkcert + dnsmasq), then scoped DNS, then HTTPS. Spike the `NEDNSSettings` entitlement first; it decides whether this is six weeks or impossible.
5. **Distroless debug toolbox** — the one thing OrbStack actually paywalls.

### Not worth building

Docker Desktop's paid tier is almost entirely compliance tooling — Enhanced Container Isolation,
Hardened Desktop, registry access management, SSO, air-gapped installs, Settings Management. That is
an enterprise-procurement market, not a one-maintainer open-source market. Chasing it would consume
the roadmap and win nobody.

---

## Working agreements

- **One serialized lane per resource.** One agent owns the machine (GUI + containers + daemon); one owns builds. Verify `argv` before trusting a process or a window.
- **Foreground only.** No `nohup`, no backgrounded composites with sleeps. This project's dominant failure mode has been agents racing their own leftover processes and reporting them as a hostile other session.
- **Verify contents, not names.** `pgrep` argv and inode size before trusting a process; `git ls-files <path>` before concluding absence; check the initrd's mtime against `guest/` before trusting any guest-side result.
- **A failing test means check the code first.** The `-p 8080:80 -p 8080:81` preflight bug was found because one failing test was right and the others were stale.
