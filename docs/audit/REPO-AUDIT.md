# Repository / meta audit — 2026-08-03

> **Staleness note (2026-08-04):** the `PublishAllPortAllocator.swift` /
> `publish_all.rs` findings below describe a subsystem deleted under TECH-1
> (replaced by a userland-proxy wrapper through dockerd's stock
> `--userland-proxy-path` hook, host port-lease listener in
> `GuestPortLease.swift`). Findings left unchanged as dated evidence; see
> `docs/design/PATCH-FREE-PUBLISH-ALL.md`.
>
> **Extended 2026-08-05:** the same deletion moots §"CI/CD" item 4 below, the hard
> `docker buildx` preflight in the guest-image job. There is no patched engine to build,
> so `mise run guest-image` needs neither Docker nor buildx — it fetches the pinned,
> hash-verified upstream `dockerd` like every other third-party guest asset. That
> preflight and `build-engine.yml` are deleted; today's `.github/workflows/ci.yml`
> runs `mise run guest-image` directly on a hosted macOS runner. Finding left unchanged
> as dated evidence.

Scope: architecture, code health, test reality, CI/CD, packaging, and the agent
harness. Branch `code/native-content-continuation`, 273 commits, ~500 tracked
files, ~186 Swift files and 22 Rust files written over roughly two days.

This is a blunt audit. A flattering one would be worthless.

---

## 0. The headline finding

**There is no git remote. CI has never executed — not once, in 273 commits.**

```
$ git remote -v
$ (no output)
```

`.github/workflows/ci.yml` is 200 lines of carefully-reasoned, well-commented,
entirely **unexecuted** YAML. This is the mechanical root cause of an entire
class of defect, and it explains everything below it:

- Four test files were committed in a state where they **could never compile**.
  Nobody noticed, because the only check anyone ran was `swift build` — which
  does not compile the test target.
- The Rust test target did not compile either (`impl std::error::Error` on a type
  with no `Debug`), so `cargo test` had been returning exit 101 rather than
  running 217 tests. Note that `cargo build` succeeds — only the test
  configuration instantiates the failing bound. A "the build is green" claim was
  therefore true and useless at the same time.
- Sixteen test failures had accumulated silently, including two that no machine
  running mDNSResponder could ever have passed.

Everything else in this document is downstream of that.

### Would ci.yml have caught it, had it run?

**Yes — the workflow is sound.** `mise run test` invokes `swift test`, which
compiles the test target, and mise aborts a multi-line task body on the first
failing command (verified experimentally). A non-compiling test file fails the
job. The workflow is not the problem; the absence of a remote is.

Two real gaps in it did exist, and are now fixed (§6).

---

## 1. What was FIXED in this pass

Test-suite state, measured with exit codes captured properly (`mise run test | tail`
masks the exit status — a pipeline reports its last command):

| | before | after |
| --- | --- | --- |
| `swift build --build-tests` | **fails**, 4 errors in 2 files | passes |
| `swift test` | 739 executed, **16 failures** | 739 executed, **0 failures** |
| `cargo test` | **exit 101 — did not compile** | **217 passed, 0 failed** |
| `mise run test` | exit 1 | **exit 0** |

### Compile breaks

| File | Defect |
| --- | --- |
| `mac/Tests/MorbstackKitTests/DockerContextTests.swift` | wrong selector label (`atPath:` vs `ofItemAtPath:`); optional-chaining precedence bug `(...)?.intValue & 0o777` |
| `mac/Tests/MorbstackAppTests/ComposeProjectSourceInspectionTests.swift` | three `XCTAssertEqual` calls on arrays of **tuples** — tuples cannot conform to `Equatable`. Rewritten as per-column assertions; the arrays are ordered and equal-length, so assertion strength is unchanged. |
| `guest/morbinit/src/live_share.rs:172` | `impl std::error::Error for ValidationError` with no `Debug` conformance. One-line `derive` fix; unblocked the entire Rust suite. |

### One real product defect, caught by a test that was failing for the "wrong" reason

`mac/Sources/MorbstackKit/DockerPortPublicationPreflight.swift` — the dedup key
for already-examined port declarations was
`"\(protocolName)|\(hostIP)|\(hostPort)"`, which **omits the container port**.
Two different container ports published to one host endpoint
(`-p 8080:80 -p 8080:81`) therefore looked like a repeat of the same declaration
and was skipped **before** reaching the `containerTargetByEndpoint` ambiguity
check — the check that exists precisely to reject that shape. The ambiguity
rejection was unreachable in the one case it was written for, and such a create
was admitted to the Engine. Fixed by including the container port in the key.

`testPreflightRejectsOneHostEndpointWithMultipleContainerTargets` had been
failing all along and was, on its face, indistinguishable from the other
"stale test" failures. It was the only one that was right.

### Flaky-by-construction tests (the test was wrong, the code was fine)

- `DockerPortPublicationPreflight.inspectContainerCreate` performs a **real
  bind** to check host-endpoint availability. Tests naming concrete ports were
  therefore asserting against whatever happens to be listening on the developer's
  Mac — and 5353/udp is mDNSResponder on every normal Mac. Added an injectable
  `HostPortAvailabilityProbe` seam (default = the real probe, so production
  behaviour is untouched) and switched the parsing/policy tests to a hermetic
  stub.
- `LifecycleTests.testAConflictingPortIsRecordedAndBackedOff` had the squatter
  holding `127.0.0.1:P` while the forward published `0.0.0.0:P`. On Darwin a
  wildcard bind is *permitted* alongside a specific-address bind, so the test was
  asserting the opposite of its own failure message. Both sides now name the same
  address.
- `K8sRuntimeTests.testThePayloadLivesBesideTheKernelNotInsideTheGuestImage`
  read the developer's real `~/.morbstack`. `MorbPaths.k8sPayloadDirectory`
  consults the filesystem to choose between the managed release layout and the
  legacy fetch-script layout, so the answer depended on what happened to be
  installed. Now runs under a scratch `MORBSTACK_HOME` and pins **both** branches
  instead of whichever one the ambient filesystem produced.
- `SharesTests` Doctor checks round-tripped to a **live daemon** over the control
  socket, so they passed or failed depending on whether an engine happened to be
  running. `Doctor.run` already had an `includeLiveShares:` seam; the tests now
  use it.

### Genuinely stale tests (the code changed deliberately, the test did not)

- `NavTests` — a ninth nav route (`migration`) was added correctly and wired into
  every consumer (`allCases`-driven shortcuts, sidebar, help, command palette,
  and a `default`-less `switch` that would have failed to compile if missed).
  The test simply pinned 8. Verified, not assumed.
- `CommandPolicyTests` — `disk-grow` was deliberately added to
  `autoStartingCommands` and routes through the same `awaitVMOperation` path as
  `start`, so it genuinely asks for an engine. Test updated with the rationale.
- `DynamicPortAllocationTests` — asserted that a host-port **range** sibling is
  rejected ("not a single port"). The host-first range allocator landed later and
  supports ranges; the test pinned the superseded refusal. Rewritten to pin the
  current contract.
- `PortForwardingTests` range ordering — the plan walks
  `PortBindings.keys.sorted()`, so `"53/udp"` precedes `"80/tcp"`. The test
  expected JSON *textual* order. The code's determinism is load-bearing (the
  rewriter matches allocator answers positionally); the expectation was wrong.
- `TrackCResourceListTests` — asserted that a volume with an **unreported**
  refCount counts as unused and is offered for pruning. `isUnused` is
  `refCount == 0`, and `nil == 0` is false, so it is excluded. The code is right
  and safer: "unknown usage" is not "unused", and offering to delete a volume
  whose usage was never reported is offering to delete live data. Test rewritten
  to pin the safe contract and its agreement with the row's `usageStatus`.

### Harness and tooling created

See §7 for the full file list.

---

## 2. Architecture

**Verdict: coherent. This is not sprawl.** The module graph is a clean layered
DAG with no cycles and no upward dependencies:

```
MorbstackKit (leaf, no deps)
  └─ MorbFeatures
       ├─ MorbMCP / MorbMigrate / MorbBench / MorbScan / MorbExport  (no sibling deps)
       └─ MorbstackAppCore (Kit, Features, MorbMigrate)
morbstackd (Kit)     morb (Kit + all five feature libs)
MorbstackApp / MorbShots / MorbLive (AppCore)
```

| Module | Files | LOC |
| --- | --- | --- |
| MorbstackAppCore | 62 | 29,994 |
| MorbstackKit | 53 | 28,509 |
| MorbMigrate | 19 | 4,090 |
| MorbMCP | 12 | 2,826 |
| morb (single file) | 1 | 2,137 |
| MorbScan | 9 | 2,130 |
| MorbBench | 16 | 2,015 |
| MorbFeatures | 5 | 1,737 |
| MorbLive | 4 | 1,066 |
| MorbExport | 2 | 362 |
| morbstackd | 1 | 108 |

Two modules are 78% of the codebase. `MorbstackKit` is called a "kit" but *is*
the product — VM lifecycle, port forwarding, the vsock relay, k8s runtime, share
sync, Engine API framing. That is a naming complaint, not a structural one.

`mac/Sources/morb/main.swift` at 2,137 lines in one file is the one place worth
splitting; every other module is reasonably shaped.

Scope note, not a defect: `MorbstackAppCore` imports only `MorbMigrate` of the
five feature libraries. Scan, bench, export and MCP are CLI-only with no GUI
surface at all.

**No duplicated or parallel implementations were found.** This was actively
hunted for — no duplicate type names anywhere in 186 Swift files, no `V2`/`Old`/
`Legacy` naming, no superseded-but-still-compiled files. What looks like five
Docker clients is five call sites of one shared `MinimalHTTP` parser, and the
one deliberate second implementation (`MorbLive/RawEngine.swift`) documents in
its own header that it exists to be an independent ground truth to check
`DockerClient` against. For a codebase written this fast, the absence is
remarkable and deserves saying plainly.

---

## 3. Code health

### Dead code — ~1,750 LOC of complete, inert subsystems

This is the real "coming soon" violation in the repository. Not stub screens —
**finished features that ship in the binary and are wired to nothing**, where no
user or reviewer can tell without reading the source.

| File | LOC | State |
| --- | --- | --- |
| `mac/Sources/MorbstackKit/MorbShareSyncProtocol.swift` | 1,002 | entire file has zero external callers. A complete authenticated wire protocol with a 331-line `HostSession` state machine. Its own header says it "starts no watcher, opens no connection." |
| `mac/Sources/MorbstackKit/MachineImageAdmission.swift` | 581 | entire file has zero external callers, **and `assess()` has no success path at all** — it is hard-wired to return `.unavailable`, as its own comment admits. |
| `mac/Sources/MorbstackKit/MorbLocalDomain.swift:224` | ~100 | `LocalDomainClaimReconciler` has zero callers. The rest of the file is live — do not delete the whole file. |
| `mac/Sources/MorbMigrate/TarLite.swift` | 63 | zero callers, plus a stale comment claiming it feeds a report path that no longer uses it. |
| `mac/Sources/MorbstackAppCore/Views/Containers/ContainerOverviewTab.swift:371,380` | ~18 | `TrackBQuietNote`, `TrackBInlineError` — never instantiated. |

Carrying an unexercised authentication/wire-protocol implementation
(`MorbShareSyncProtocol`) in the shipped binary is the item on this list with an
actual risk attached, not just tidiness.

### Honest "not yet" surfaces — not violations

`morb debug` says "does not open a shell yet" in its own top-level usage;
`morb bench list` marks unimplemented targets `"status": "not implemented"` with
`"cost": "unavailable — this command will not invent a measurement"`. No
`--help` text was found promising behaviour the implementation does not deliver.
That is the opposite failure mode from the one being hunted, and it is the right
one to have.

One cosmetic nit: the top-level summary `scan  SBOM and CVE scan an image,
entirely on this machine` slightly overstates locality — `ScanEngine.ensureDatabase`
fetches the vulnerability DB from `grype.anchore.io` unless `--offline`. It is
disclosed at the subcommand level; only the one-line summary is loose.

### Build warnings

A clean build (`swift build --build-tests` into a fresh scratch path) emits
exactly **three distinct warnings** — 27 instances, 26 of them the same generic
pointer conversion reported at each instantiation. They fall into two kinds:

- **Real defect, worth fixing:** `MorbstackKit/DockerAPI.swift:65` and
  `MorbstackKit/UDPListener.swift:101` — *"forming `UnsafeRawPointer` to a
  variable of type 'T'; this is likely incorrect because 'T' may contain an
  object reference."* This is the compiler saying a generic pointer conversion is
  unsound, in socket-option code. Not cosmetic.
- **Deprecation, cosmetic:** `LiveShareBridgeTests.swift:99` calls the deprecated
  `diagnose(paths:shares:guestShareStates:guestCapability:)`; the replacement
  takes a `GuestAdvertisement` so the guest schema version is validated. The test
  should move to the non-deprecated overload — the deprecation exists because the
  old form skips a version check.

---

## 4. Test coverage — the honest version

739 Swift tests + 217 Rust tests, all green. But *where* they are matters more
than how many there are.

**The tests that exist are unusually good.** Real `socketpair(2)` fixtures, an
actual 50-iteration race reproduction for a rebind bug, cross-language
constant-ladder invariants that check Swift shutdown budgets against Rust
constants, careful `nil`-vs-`false` decode distinctions. No tautological tests
(`XCTAssertTrue(true)`-shaped) were found. This is not padding.

**But coverage is concentrated on pure decision logic and nearly absent from the
stateful, IO-heavy, crash-safety-critical code** — which in a two-day AI-authored
codebase is exactly backwards from where the risk is.

| Subsystem | Reality |
| --- | --- |
| VM lifecycle | `VMManager.swift` is **2,097 lines with zero tests that boot, stop, save or restore a real `VZVirtualMachine`.** `LifecycleTests` covers stop-idempotence and timeout arithmetic well; the framework interaction itself is untested. |
| Live-share bridge | Decision layer tested. `MorbLiveShareTransport.swift` (676 LOC) and `MorbShareSyncProtocol.swift`: **no tests**. Guest side `live_share.rs` (578) and `live_share_receiver.rs` (595) — which their own comments call "the authority boundary" — have **zero `#[test]`s**. Unverified end-to-end, in both languages. |
| Disk-grow journal | The tested half is the wrong half. `MorbDiskResize.diagnose` (a pure policy function) is covered; `MorbDiskGrowth.swift` (337 LOC — the journal, atomic replace, fsync ordering, restart recovery) has **zero tests**. |
| Publish-all (`-P`) | `PublishAllPortAllocator.swift` (199 LOC, live): **zero tests**. Guest `publish_all.rs` (369 LOC): **zero tests**. Both sides of one protocol, untested. |
| Port forwarding (rest) | Strong. Real decode/plan/diff coverage, IPv6 normalization matched against Moby's own behaviour. `HostPortPreflight.swift` is the one live-but-untested file. |
| vsock relay | Strong for `Relay`/`GuestControl`/`StreamDial`/`DatagramDial`. `UnixSocketClient.swift` has none. |
| Guest Rust | 217 tests across 15 of 21 modules, genuinely good. Zero in `main.rs`, `mounts.rs`, `net.rs`, `publish_all.rs`, `live_share.rs`, `live_share_receiver.rs`. |

Also relevant: on macOS, `cargo build`/`cargo test` compile only the portable
subset of `morbinit` — ~85 `#[cfg(target_os = "linux")]` gates across 19 of 22
files. The Linux paths are type-checked **only** by `mise run cross-build-guest`,
which CI runs solely in the path-gated `guest-image` job.

Tests that skip rather than run in CI (correctly, with `XCTSkip`):
`MorbFeaturesTests/SupportTests.swift` live Engine tests, `RosettaTests.swift:125`,
`K8sTests.swift:412`.

---

## 5. Security posture — **NOT COMPLETED**

Stated plainly rather than papered over: two attempts to run a systematic
input-handling review over the vsock protocols, the MCP server, and the shell-out
surfaces were terminated by model-side safeguards before producing findings. This
audit therefore contains **no security verdict**, and the absence of findings must
not be read as an absence of problems.

What is known from adjacent work and stands up:

- Every third-party guest asset is SHA-256 pinned and verified (§6).
- The Moby fork is pinned to `docker-v29.7.1` **and** its peeled commit
  `c5b8ce9274b5c00cb1f8287c8e258edc1f01176d`, with the patch applied via
  `git apply --check` first.
- No secrets are tracked. The only credential-shaped literals are self-documented
  synthetic fixtures used to exercise log redaction.

What remains unreviewed, and should be reviewed by a human or a differently-run
pass: frame-size bounds and integer-conversion traps on the five vsock ports
(1024/2375/2376/2377/2381), path-escape handling in the file-events and bulk
transfer paths, connection caps and read timeouts, and the MCP server's tool
surface. Given that `MorbShareSyncProtocol.swift` and both guest live-share
modules have **no tests at all** (§4), this is the highest-value unreviewed
region in the repository.

---

## 6. CI/CD and packaging

### The workflow

`ci.yml` is well-reasoned and well-commented — the change-detection gate on the
slow guest-image job, the `mise trust && mise install` step written as literal
commands *because* `mise run setup` cannot bootstrap itself on an untrusted
config, the explicit note that no Swift lint job exists because no
`.swift-format`/SwiftLint config does. Somebody thought about this properly.

Fixed in this pass:

1. **Added an explicit `swift build --build-tests` step.** `mise run build` runs
   `swift build`, which does not compile `mac/Tests`. A separate step makes a
   compile break read as a compile break rather than as a mysterious test failure.
2. **`mise run test` now runs both suites and fails if either did.** Previously a
   Swift failure short-circuited the Rust suite entirely.
3. **`mise-tasks/` validation in the lint job** (executable, self-describing,
   parses) plus shellcheck over the task files and the pre-commit hook — now
   possible at all, because the recipes are files rather than TOML strings.
4. **A hard preflight in the guest-image job requiring `docker buildx`.**
   `build-patched-dockerd` needs it to build the pinned Moby engine, and GitHub's
   hosted macOS runners ship no Docker. That job would have failed 40 minutes in
   with an error message written for a developer's laptop. It now fails in
   seconds, with the two real options spelled out.
5. `timeout-minutes` on all three jobs.

Still open (recommendations): the `app` task's supply-chain verification —
manifest pinning, SHA-256 checks, inside-out signing, the entitlement
post-check — is never exercised by CI at all, so the most safety-critical shell
in the repository is entirely unverified by automation.

### Packaging: real up to the DMG, aspirational past it

`scripts/make-dmg.sh` (276 lines) builds a real drag-to-Applications DMG using
only base-system tools, and says honestly in its own output that the result is
unsigned and unpublishable.

Everything past that point is **scaffolding referencing files that do not
exist**:

| Referenced as the source of truth | Exists? |
| --- | --- |
| `scripts/release.sh` (signing + notarization) | **no** |
| `docs/RELEASING.md` | **no** |
| `docs/sparkle.md` (auto-update decision) | **no** |
| `.github/workflows/release.yml` | **no** |
| Homebrew cask/formula (any `.rb`) | **no** |

`grep -rn "notarytool"` across the whole tree hits two lines, both in
`docs/roadmap.md`, both describing a script that does not exist. There is no
notarization implementation anywhere. This is the single biggest gap between what
the docs imply and what the repository contains.

### Asset provenance: genuinely excellent

Every third-party guest and host asset is SHA-256 pinned and verified, several
with two independent hashes (archive + extracted member) and several
cross-checked against upstream sidecar files: kata 3.28.0 kernel 6.18.15, Alpine
3.24.1 minirootfs, Docker engine 29.7.1, 15 individually-pinned Alpine fsutils
packages, docker CLI 29.7.1, compose v5.3.1, buildx v0.36.0, kubectl v1.36.2,
k3s v1.36.2+k3s1, cri-dockerd v0.4.4. **No asset was found that is fetched
without verification.** `NOTICE` carries a full per-asset licence/source table
including the GPL-2.0 kernel's redistribution obligations.

### Repo hygiene

`.gitignore` is correct and well-explained. The 7 tracked `dist/` files are
`CROSS_COMPILE.md`, five `PROVENANCE.txt`, and `TOOLCHAIN.plist` — text manifests
only, deliberately carved out of an otherwise-ignored `dist/*`. **Tracking them
is correct**: they are the only durable record of what was downloaded and with
which hash. No build artifacts, no binaries, no secrets tracked. Largest tracked
files are ~1.4 MB PNGs.

One stale doc: `docs/PUBLISHING.md:266` claims `.git` is "22M" with "5 commits";
it is 75 MB and 273 commits.

---

## 7. The agent harness

Before this pass: a 22 KB monolithic `mise.toml` with ~18 inline tasks, an
`AGENTS.md` written for Codex, a `.codex/config.toml`, and **no** `mise-tasks/`,
`CLAUDE.md`, `.mcp.json`, `.claude/settings.json` or `.claude/agents/`.

### Created

| Path | What |
| --- | --- |
| `mise-tasks/` (18 files) | every task converted to an executable script with `#MISE description=` / `#MISE depends=` headers |
| `mise-tasks/check` | **new** — the local gate: compile *including tests*, then both suites, then `cargo fmt --check` |
| `mise-tasks/install-hooks` | **new** — sets `core.hooksPath` to the tracked hooks directory |
| `scripts/git-hooks/pre-commit` | **new** — structural guards + compile only what changed |
| `CLAUDE.md` | operational source of truth: the landmines |
| `.mcp.json` | `mise mcp` wiring |
| `.claude/settings.json` | permission allowlist/denylist |
| `.claude/agents/{engine-dev,native-macos-dev,parity-tester}.md` | role definitions |
| `mise.toml` | reduced to tool pins, task discovery, and the authoring rules |

### Why files instead of TOML strings

The `app` recipe alone is 200 lines with two shell functions, two heredocs, and a
supply-chain verification pass. As a TOML string it was unreviewable, needed TOML
escaping *on top of* shell escaping, and — decisively — **shellcheck cannot see
inside a TOML string**. Proof that this mattered: the inline recipe contained
`echo "...does not pin $ID bytes"` where `$ID` was never defined (it should have
been `$TOOL_ID`), sitting undetected in an error path. Corrected during
conversion.

Behaviours preserved verbatim, each one a real bug once:

- **Signing order and the absence of `--deep`.** `swift build` strips
  `com.apple.security.virtualization` from `morbstackd`, so signing is the last
  step; the bundle is signed inside-out; `--deep` would silently re-sign the
  nested daemon with the outer invocation's (empty) entitlements and ship an
  engine that can never boot a VM. Both `mise-tasks/app` and `mise-tasks/sign`
  end with the hard post-check that greps the entitlement back out — and `sign`
  now has that check too, which it did not before.
- **Subshell-wrapped `cd`.** mise runs a multi-line body as one shell.
- **The curated three-binary bundle manifest**, with its warning not to derive it
  from `Package.swift`.
- **The `mise trust && mise install` bootstrap**, including why `setup` cannot
  bootstrap itself.

### Verified

`mise tasks` lists all 18. `bash -n` passes on every file. `mise run build-mac`
and `mise run test` both run correctly through the new files, and `mise run test`
now propagates a failing exit code (verified by observing exit 1 before the
fixes and exit 0 after). `mise mcp` was smoke-tested with a real JSON-RPC
`initialize` — it requires `MISE_EXPERIMENTAL=1` (hence the `env` block in
`.mcp.json`) and correctly writes its banner to stderr, leaving stdout clean.

**Not run, per lane discipline:** `app`, `sign`, `guest-image`, `run-daemon`,
`run-app` — another agent holds the machine lane with the existing bundle. These
five need a human verification pass.

### CLAUDE.md vs AGENTS.md

`CLAUDE.md` is the operational source of truth; `AGENTS.md` stays the design and
workflow agreement and now points at it first. The split is by *kind of
knowledge*, not by tool: "how do I run this without breaking the machine" versus
"what should the UI be". Merging them would bury the landmines in design prose,
and duplicating them guarantees they drift.

---

## 8. What Codex did well

Being specific, because it is genuinely better than the failure modes above
suggest:

1. **The comments explain *why*, and they are correct.** The `--deep` explanation
   in the signing recipe names the exact failure mode and the exact symptom. The
   `mise trust` bootstrap comment explains a chicken-and-egg problem most people
   would have papered over. This is the most valuable artifact in the repo.
2. **Supply-chain discipline is exceptional.** Every asset hash-pinned, several
   doubly; the Moby pin uses the *peeled* commit specifically so a shallow fetch
   verifies the real tree; the app bundle re-verifies the toolchain after copying
   and again after signing, because copying is itself a boundary.
3. **No parallel implementations.** In 273 fast commits, with five modules that
   all talk to the Docker Engine API, there is exactly one HTTP parser — and the
   one deliberate duplicate documents in its header why it must be independent.
4. **The tests that exist are real.** Socketpair fixtures, a 50-iteration race
   reproduction, cross-language constant invariants. Whoever wrote
   `RelayTests.swift` and `LifecycleTests.swift` was testing for real bugs.
5. **Honest unavailable states.** `"this command will not invent a measurement"`
   is the right instinct, expressed in a machine-readable field.
6. **`.gitignore` reasoning.** Ignoring 220 MB of vendored payloads while
   deliberately tracking the provenance records that let you re-fetch them is the
   correct call, and the comment says why.

---

## 9. Ranked fixes

Effort: S = under an hour, M = half a day, L = multi-day.

| # | Fix | Effort | Why it ranks here |
| --- | --- | --- | --- |
| 1 | **Push to a remote and let CI run.** Everything else is a symptom. | S | 273 commits with no gate produced four non-compiling files and 16 silent failures. |
| 2 | `mise run install-hooks` on every clone; `mise run check` in the PR checklist. | S | Done and documented; needs to actually be adopted. |
| 3 | Write `scripts/release.sh` + `docs/RELEASING.md`, or delete every reference to them. | M | Docs currently promise notarization that does not exist anywhere. Either is fine; the current state is not. |
| 4 | Test the disk-grow journal (`MorbDiskGrowth.swift`). | M | 337 LOC of atomic-write/fsync/restart-recovery with zero tests. Corruption here loses user data. |
| 5 | Test the live-share authority boundary — `live_share.rs`, `live_share_receiver.rs`, `MorbLiveShareTransport.swift`. | L | ~1,850 LOC across two languages, self-described as the authority boundary, zero tests either side, and unreviewed for input handling (§5). |
| 6 | Complete the security pass over the vsock surfaces and MCP tools. | M | §5 is a hole, not a clean bill of health. |
| 7 | Delete or wire up the dead subsystems (`MorbShareSyncProtocol` 1,002 LOC, `MachineImageAdmission` 581, `LocalDomainClaimReconciler`, `TarLite`). | S | Shipping inert protocol code in the binary is the actual "coming soon" violation. |
| 8 | Fix the two `UnsafeRawPointer` warnings (`DockerAPI.swift:65`, `UDPListener.swift:101`). | S | The compiler is reporting a possibly-unsound generic pointer conversion in socket code. |
| 9 | Cover `PublishAllPortAllocator` + guest `publish_all.rs`. | M | `-P` is a headline Docker feature, untested on both sides of the vsock boundary. |
| 10 | Exercise the `app` bundle assembly in CI. | M | The most safety-critical shell in the repo (entitlements, hash verification) has no automated coverage. |
| 11 | Split `mac/Sources/morb/main.swift` (2,137 lines). | S | The only genuinely unwieldy file. |
| 12 | Move `LiveShareBridgeTests.swift:99` off the deprecated `diagnose` overload. | S | The deprecation exists because the old form skips a guest schema-version check. |

---

## 10. Verdict: maintainable, or AI-slop-shaped?

**Maintainable.** This is not slop, and saying otherwise would be lazy.

The evidence for maintainability is structural: no duplicate implementations, a
clean acyclic module graph, no dead-naming (`V2`/`Old`/`Legacy`), essentially no
`TODO`/`FIXME` debris, honest unavailable states instead of fake ones, and
comments that explain causal mechanisms rather than restating the code. A human
maintainer can read `mise-tasks/app` and understand not just what it does but
which bug each line prevents. That is rare in human-written repositories.

The AI-authored provenance shows up in exactly one shape, and it is consistent:
**nothing was ever executed end-to-end.** Four files that could not compile.
Tests binding ports that no Mac has free. Tests reading the developer's real home
directory. A CI workflow written with real care and never once run. Docs
referencing four files that do not exist. ~1,750 lines of finished subsystems
wired to nothing. Every one of these is invisible to a reviewer reading the diff
and obvious the moment something runs.

So the risk is not that the code is bad. It is that the *confidence* in it was
manufactured by review rather than execution. The fix is mechanical and mostly
already in place: a remote, a green pipeline, and a habit of running the thing.
