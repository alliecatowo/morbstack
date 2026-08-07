# Test quality audit — tests that cannot fail

Date: 2026-08-06. Scope: all of `mac/Tests/` (988 XCTest cases across 66 files at the
start of this audit) and `guest/morbinit`'s 260 Rust `#[test]`s. This audit added 30
Swift tests and 2 Rust tests, so the suites now stand at 1018 and 262.

## Why this exists

`mise run check` is this repository's only gate, and its entire claim is that green
means working. That claim was falsified this week. An agent reported the container PTY
stack "complete, committed and tested" while three functions were stubs —
`TerminalEmulator.feed(_:)` was `_ = data`, `resize(columns:rows:)` was
`_ = (newColumns, newRows)`, and all three `TerminalKeyEncoding` functions returned
empty `Data` or `nil`. The suite was green throughout, because the test computed its
expectation by calling the function under test:

```swift
let expected = TerminalKeyEncoding.bytes(for: .up, applicationCursorKeys: true)
XCTAssertEqual(actual, expected)
```

That holds for every possible implementation, including one that does nothing.

**Every finding below was proved by stubbing.** For each one the named production
symbol was replaced with a constant or empty return, the tests were run, and the result
recorded. Findings that a test caught are listed under [Cleared](#cleared-by-stubbing)
rather than dropped silently. All stubs were reverted; `git diff` is clean of them.

### The headline measurement

**All 1017 Swift tests pass with 14 production symbols simultaneously stubbed.**

```
baseline                    Executed 1017 tests, with 0 failures (16.9s)
with 14 symbols stubbed     Executed 1017 tests, with 0 failures (16.9s)
```

(Both runs were taken after this audit's `TerminalKeyEncodingTests` landed and before
the datagram anchor did — 988 pre-existing tests plus those 29. None of the 29 touch any
of the 14 stubbed symbols, so they neither mask nor inflate the result.)

The 14: `Formatters.bytesString`, `Nav.title`, `Nav.symbol`,
`OperationalState.label`, `OperationalState.symbol`,
`TrackBLogExport.suggestedFilename`, `ToolSpec.guards`,
`DebugToolboxAsset.expiryDate`, `TrackERosettaHost.probe`, `Subprocess.which`,
`DockerPortPublicationPreflight.stoppedContainerFixedPortLeasePlan`,
`DockerPortLeaseResponseObserver`'s status check, `K8sPayloadStaging.describe`, and
`MorbLiveShareTransport`'s `rootID` derivation.

On the Rust side, **260 of 260 tests pass** with `jsonlite::emit` producing
single-quoted JSON that the host's `JSONSerialization` rejects outright, with the
datagram frame length reversed to little-endian, and with `log::log` emitting nothing.

---

## Tier 1 — tautologies over shipped user-facing behaviour

### 1.1 The terminal key encoder — the case that started this. FIXED

**File:** `mac/Tests/MorbstackAppTests/TerminalSurfaceViewTests.swift:226` and `:248`
(`testSpecialKeyRoutesThroughTerminalKeyEncoding`,
`testControlLetterFoldsThroughCharacterEncoding`)
**Shape:** self-comparison.

**Proof.** With all three `TerminalKeyEncoding` functions stubbed
(`return Data()` / `return nil` / `return Data()`), `TerminalSurfaceViewTests` reported
**32 tests, 0 failures**. Nothing anywhere pinned a byte.

**Fixed.** `mac/Sources/MorbstackAppCore/Terminal/TerminalKeyEncoding.swift` now
implements all three functions, and a new
`mac/Tests/MorbstackAppTests/TerminalKeyEncodingTests.swift` pins every literal:
`ESC [ A` versus `ESC O A` for up-arrow across DECCKM, the `A/B/C/D` finals, Home/End
following the cursor-key introducer, the `CSI <n> ~` editing keypad, backspace as DEL
(not BS), enter as CR (not LF), `CSI Z` for shift-tab, `SS3 P/Q/R/S` for F1–F4, and the
F5–F12 table with 16 and 22 skipped. Control folding pins `⌃C → 0x03`, `⌃@ → 0x00`,
`⌃[ → 0x1B`, `⌃? → 0x7F`, `⌃/ → 0x1F`. Paste pins the `ESC [200~` … `ESC [201~` fence
and CR normalisation.

Source: "XTerm Control Sequences" (Thomas E. Dickey, `ctlseqs.txt`), sections
"PC-Style Function Keys" and "VT220-Style Function Keys", plus DEC STD 070 for DECCKM
(private mode 1). Cited inline in both files.

**Proof the fix bites.** Re-applying the stub, in a single run:

```
Test Suite 'TerminalKeyEncodingTests' failed   — 29 tests, 120 failures
Test Suite 'TerminalSurfaceViewTests' passed   — 32 tests,   0 failures
```

The routing tests were kept. They test something real; they just could not stand alone.

### 1.2 `TerminalEmulator.feed` and `resize` are still stubs with zero tests

**Files:** `mac/Sources/MorbstackAppCore/Terminal/TerminalEmulator.swift:126` and `:134`.

Not a bad test — *no* test. `feed(_:)` is `_ = data` and `resize(columns:rows:)` is
`_ = (newColumns, newRows)`, and no file under `mac/Tests/` or `mac/UITests/` references
either. This is the whole container terminal screen. Because `feed` is what sets
`applicationCursorKeys` and `bracketedPaste`, both flags are permanently `false`, so the
encoder fixed in 1.1 can never actually reach its DECCKM or bracketed-paste branches at
runtime. Ticket in the report; too large to fix here.

**2026-08-06 correction, found while merging this audit into `swarm/cleanup`: stale.**
This worktree forked before DIF-2 landed on `swarm/cleanup`. `feed(_:)` is
`for byte in data { consume(byte) }` and `resize(columns:rows:)` is implemented against
a real ground/escape/CSI/OSC/string state machine; `mac/Tests/MorbstackAppTests/TerminalEmulatorTests.swift`
exists with a full VT contract suite. Both `applicationCursorKeys` and `bracketedPaste`
are live, so 1.1's encoder does reach its DECCKM and bracketed-paste branches at runtime.
Left in place rather than deleted so this audit's history stays legible; do not read the
paragraph above as current.

### 1.3 `Formatters.bytesString` is pinned nowhere in the suite

**Files:** `mac/Tests/MorbstackAppTests/ModelTests.swift`
(`FormattersTests.testNegativeByteCountsRenderAsZero`) and
`TrackBLogPipelineTests.swift:507`.
**Shape:** self-comparison. `XCTAssertEqual(Formatters.bytesString(-5000), Formatters.bytesString(0))`
— both sides are the same call. The second is worse: `memoryLimitDescription` *is*
`Formatters.bytesString(memoryBytes)`, so the assertion compares the function with itself
through one layer of indirection.

**Stubbed:** `Formatters.bytesString(_:) -> String` → `""`. **Result: green.** These are
the only two references to `bytesString` in the entire test tree.

**Guards:** every size the UI renders — Images, Volumes, Disk, Builds, Stats, both
archive workflows, the Settings disk row. Under the stub every one of them is blank.

**Should assert:** a literal. Left unfixed because `ByteCountFormatter` output is
locale-dependent and choosing the right assertion is a judgement call — ticket in report.

### 1.4 Sidebar titles and symbols are checked only for non-emptiness

**File:** `mac/Tests/MorbstackAppTests/ModelTests.swift`
(`NavTests.testEverySectionHasATitleAndASymbol`).
**Shape:** assertion too weak to fail against a stub.

**Stubbed:** `Nav.title` → `"x"`, `Nav.symbol` → `"x"`. **Result: green.**

**Guards:** the nine sidebar rows. Under the stub every row reads "x" with no icon. The
XCUITest at `mac/UITests/MorbstackFixtureUITests/` does pin `"Kubernetes"`, but that
target does not run under `swift test` and so is not part of the gate.

**Should assert:** `Nav.allCases.map(\.title)` against the literal array, plus the
non-obvious SF Symbol names (`helm`, `chart.pie`) — a symbol typo renders nothing at all.

### 1.5 Operational state labels are checked only for distinctness

**File:** `mac/Tests/MorbstackAppTests/ModelTests.swift`
(`OperationalStateTests.testEveryOperationalStateHasADistinctSymbolAndLabel`).
**Shape:** assertion too weak.

**Stubbed:** `label` and `symbol` → `String(describing: self)` (five distinct values, so
both `Set(...).count == 5` assertions hold). **Result: green.**

**Guards:** every menu, table cell and VoiceOver label. Under the stub `.failed` reads
"failed" instead of "Needs attention" and every status glyph disappears.

**Should assert:** the five literal labels and symbol names, keeping distinctness as an
extra invariant.

### 1.6 MCP argument guards can all vanish silently

**File:** `mac/Tests/MorbFeaturesTests/MCPInputValidationTests.swift`
(`testEveryGuardKeyIsAKnownPermissionKey`).
**Shape:** vacuous loop — iterating a collection that may legally be empty.

**Stubbed:** `ToolSpec.init` → `self.guards = []`. **Result: green**, with zero
iterations.

**Guards:** the argument-level grants that stop `container_remove force:true` and
`inspect:env` from running ungranted. This is a security control.

**Should assert:** pin the guard set — `Set(ToolRegistry.all.flatMap { $0.guards.map(\.key) })`
against a literal — so a removed guard is a failure rather than a shorter loop.

### 1.7 Published-port lease recovery is asserted only negatively

**File:** `mac/Tests/MorbstackKitTests/PortForwardingTests.swift:432`
(`testHostNetworkDoesNotRecoverAFixedPortLease`).
**Shape:** assertion too weak — the only assertion on this symbol anywhere is `XCTAssertNil`.

**Stubbed:** `DockerPortPublicationPreflight.stoppedContainerFixedPortLeasePlan` →
`return nil`. **Result: green** (full suite).

**Guards:** start-time host-port lease recovery for stopped containers after VM loss.
Under the stub a published port silently comes back dark after a restart. The
neighbouring `stoppedContainerTCPBindings` *is* pinned to a concrete array; the
stricter sibling got only the negative half.

**Should assert:** a positive case returning a plan with the expected tcp/udp bindings.

### 1.8 A 304 is indistinguishable from a successful port-lease handoff

**File:** `mac/Tests/MorbstackKitTests/DockerPortLeaseResponseObserverTests.swift:35`
(`testStartRequiresDockerDocumented204`).
**Shape:** assertion too weak — the test never feeds a non-204 status, so "Requires" is
unverified.

**Stubbed:** `finish(parsed.head.statusCode == 204 ? .startSucceeded : .failed)` →
`finish(.startSucceeded)`. **Result: green.** `.failed` is asserted nowhere in
`mac/Tests/`.

**Guards:** port forwarding. The source comment explains exactly why a 304 must not
count as a handoff; that reasoning has no test.

### 1.9 The K8s payload digest gate is never shown to accept anything

**File:** `mac/Tests/MorbstackKitTests/K8sRuntimeTests.swift:103`
(`testDescribeAcceptsAPayloadThatMatchesThePin`).
**Shape:** the test never calls `describe`. It re-asserts `K8sPayloadStaging.hash`
against CryptoKit — byte-for-byte the same assertion as the test 60 lines above.

**Stubbed:** `K8sPayloadStaging.describe` → unconditional
`throw MorbError.io("does not match the digest. Refusing to install it. Run scripts/fetch-guest-assets.sh --k8s-only")`.
**Result: green.** That one constant throw satisfies all three of the file's `describe`
tests, because each only checks that the message *contains* a substring.

**Guards:** the gate deciding whether a 74 MB binary is streamed into the guest and run
as root. Nothing asserts it ever returns successfully, or that "missing" and "digest
mismatch" are different errors.

### 1.10 `jsonlite::emit`'s wire shape is pinned only by its own parser. FIXED

**File:** `guest/morbinit/src/jsonlite.rs` (`round_trips_simple_object`) and the ~15
reply tests in `control.rs`, which all decode with `jsonlite::parse`.
**Shape:** unanchored round-trip. `parse` is well anchored by literal inputs; `emit` was
pinned by nothing.

**Stubbed:** `emit` switched to single-quoted keys and values, with `parse` and
`escape_into` relaxed to match. **Result: 260 of 260 green** — while the host's
Foundation `JSONSerialization` would reject every MRB0 reply the guest sends.

**Fixed.** Added `emit_produces_exactly_the_json_the_host_decoder_expects`, which
compares whole emitted strings against literals including the escape cases.

### 1.11 The datagram frame header is unpinned on both sides of the language boundary. FIXED

**Files:** `guest/morbinit/src/datagram.rs`
(`frame_round_trip_preserves_boundaries_and_empty_datagrams`) and
`mac/Tests/MorbstackKitTests/PortForwardingTests.swift:699`
(`testDatagramDialPreambleAndFramingPreservePacketBoundaries`).
**Shape:** unanchored round-trip, in two languages that must agree.

`writeFrame`/`write_frame` and `readFrame`/`read_frame` are only ever composed with each
other, so any self-consistent length encoding passed on both sides.

**Stubbed:** both sides swapped to little-endian.
- Rust: **260 of 260 green.**
- Swift: the round-trip test **passed**. The only sibling that noticed
  (`testDatagramDialRejectsAFrameLargerThanUDPPermits`) noticed by *blocking forever* —
  its `[0,1,0,0]` header reads as length 256 under little-endian, so `readFrame` waits
  for a payload that never arrives. That surfaces as a CI timeout, not a test failure,
  which is arguably worse than a silent pass.

**Guards:** `docker run -p 53:53/udp`.

**Fixed.** Added `datagram::the_frame_header_is_a_four_byte_big_endian_length` (Rust) and
`testDatagramDialFrameHeaderIsAFourByteBigEndianLength` (Swift). Both use a 258-byte
payload, since `258 = 0x0102` is the discriminating case. Verified: re-applying the
little-endian mutation fails the new Rust anchor while the round-trip still passes.

### 1.12 The live-share HMAC is verified against itself — and never runs

**File:** `guest/morbinit/src/live_share_receiver.rs:693`
(`acknowledgement_has_the_exact_authenticated_host_wire_shape`).
**Shape:** self-comparison, and environment-gated.

`acknowledgement_line` computes the tag with `hmac_hex`; the test then calls
`verify_hmac`, which *is* `constant_time_equal(hmac_hex(key, msg), tag)`. It asserts
`hmac_hex(x) == hmac_hex(x)`.

**Proof it never runs:** `cargo test live_share_receiver` reports
`1 passed; … 259 filtered out`. The `mod tests` is nested inside
`#[cfg(target_os = "linux")] mod imp`, and `mise run check` only ever runs `cargo test`
on the macOS host — CI's `cargo check --target aarch64-unknown-linux-musl` compiles the
Linux tests but never executes them. Four of this file's five tests are dead.

**Guards:** the authentication boundary for the live-share path authority. There is no
RFC 4231 known-answer vector anywhere in the crate; `sha256.rs` has excellent NIST
vectors for SHA-256 itself, but nothing for the HMAC built on it.

### 1.13 `gateway.docker.internal` resolution is asserted only as `is_some()`

**File:** `guest/morbinit/src/dns.rs:443` and `:450`
(`gateway_docker_internal_is_also_answered`, `is_case_insensitive`).
**Shape:** assertion too weak. Neither checks that the reply carries the address, the
header, or the answer count. The first test's *name* claims the alias resolves to the
gateway address; that claim is not asserted.

`answers_host_docker_internal_with_the_gateway_address` does check the full header and
RDATA — but only for the first of the two `SPECIAL_NAMES`.

**Guards:** shipped behaviour, `docs/parity.md` #18/#19.

---

## Tier 2 — tautologies over internal helpers and supporting tooling

### 2.1 `find_iptables` self-comparison (Rust)

**File:** `guest/morbinit/src/supervisor.rs:2042`
(`iptables_switches_track_whether_the_binary_is_actually_present`). The test computes
`let present = find_iptables().is_some();` and compares it against flags that
`default_services()` produced by calling **the same** `find_iptables()`.

**Stubbed twice, decisively:** `find_iptables` → `None` → **green**; `find_iptables` →
`Some("/sbin/iptables")` → **green**. The assertion holds for both branches, which is
the definition of a test that constrains nothing. On macOS only the `--iptables=false`
branch is ever reachable, so the branch that ships is never asserted.

### 2.2 `log::log` has no assertions

**File:** `guest/morbinit/src/log.rs:52` (`log_does_not_panic`) — three calls, no
assertions.

**Stubbed:** the formatted line → `String::new()`. **Result: 260 green.** PID 1's only
diagnostic channel emits nothing and the suite is happy.

**Should assert:** extract `format_line(elapsed_ms, msg)` and pin
`"[         7ms] hi\n"`, which also pins the 10-wide right-aligned field.

### 2.3 Rosetta host probe

**File:** `mac/Tests/MorbstackAppTests/TrackEShareStatusTests.swift`
(`testRosettaProbeIsSelfConsistent`, `testLocalRosettaStateLeavesGuestFactsUnknown`).
The first is `if installed { XCTAssertTrue(supported) }` — the only assertion sits inside
a branch gated on host state, so on a Mac without Rosetta it executes nothing. The second
asserts stored properties that `localState` never assigns; they come from
`MorbRosettaState.init`'s `= nil` defaults.

**Stubbed:** `TrackERosettaHost.probe` → `(false, false)`. **Result: green.** The
documented `.notInstalled → (false, true)` and `@unknown default → (false, true)`
mappings — the subtle one the doc comment calls out — are asserted nowhere.

### 2.4 Log export filename

**File:** `mac/Tests/MorbstackAppTests/TrackBLogPipelineTests.swift`
(`testSuggestedFilenameIsSafeForTheFilesystem`) — asserts `hasSuffix(".log")`, no `/`,
no `:`.

**Stubbed:** `TrackBLogExport.suggestedFilename` → `".log"`. **Result: green.**

The test already passes a fixed `now`, so a full literal is available for free. Related
latent bug the current assertions cannot see: that `DateFormatter` sets no `locale` or
`timeZone`, so the filename is host-locale dependent and a non-Gregorian default calendar
changes the year.

### 2.5 Debug toolbox expiry

**File:** `mac/Tests/MorbFeaturesTests/DebugToolboxAssetTests.swift`
(`testValidCurrentDescriptorIsOnlyStructurallyAccepted`) — `XCTAssertNoThrow` plus
`XCTAssertNotNil` on a value that is never nil for the fixture.

**Stubbed:** `DebugToolboxAsset.expiryDate` → `Date()`. **Result: green.** The
`.expired` branch in `DebugToolboxAssetInventory` has no test at all.

### 2.6 `Subprocess.which`

**File:** `mac/Tests/MorbFeaturesTests/SupportTests.swift`
(`testWhichFindsAToolThatIsCertainlyPresent`).

**Stubbed:** `which` → `name == "sh" ? "/bin/sh" : nil`. **Result: green.** The
`isExecutableFile` branch the function exists for is untested.

### 2.7 Live-share `rootID` derivation

**File:** `mac/Tests/MorbstackKitTests/LiveShareBridgeTests.swift:82` — the only claim
made about `rootID` is `hasPrefix("root_")`.

**Stubbed:** the SHA-256 derivation → `let id = "root_"`. **Result: green.** With one
root the duplicate-ID guard never fires. This file is the only place in the repo that
references `MorbLiveShareTransport`; the `ROOT`/`EVENT` wire lines are pinned nowhere.

### 2.8 Pure tautologies — assertions no implementation can fail

| File | Test | The dead assertion |
| --- | --- | --- |
| `mac/Tests/MorbstackKitTests/GuestMACTests.swift:39` | `testPinnedGuestMACIsStable` | `XCTAssertEqual(VMManager.guestMACAddress, VMManager.guestMACAddress)`. The in-test comment says "Not a tautology: it asserts the address is a compile-time constant rather than something regenerated per access" — that would be true for a computed `static var`, but it is a `static let`, so two reads are the same read. The next line does the real work. |
| `mac/Tests/MorbstackAppTests/BuildxHistoryLogExportTests.swift:34` | `testPreservesExactlyLoadedOutputAndDisclosesTruncationScope` | `XCTAssertEqual(document.data, Data(document.text.utf8))` restates `var data: Data { Data(text.utf8) }`. No stub can fail it short of deleting the property. |
| `mac/Tests/MorbstackAppTests/TrackBLogPipelineTests.swift` | `testDocumentDisclosesVisibleFilteredBoundedSnapshotScope` | Same shape, same property pattern. |
| `mac/Tests/MorbstackAppTests/BuildxBuilderSelectionTests.swift:14-16` | `testDefaultBuilderRecoveryDoesNotBroadenBuildxScope` | Three `XCTAssertFalse(… .contains(…))` lines that cannot fail independently — line 11 already pinned the array to exactly `["buildx", "use", "default"]`. |
| `mac/Tests/MorbstackKitTests/MorbVersionCompatibilityTests.swift:57` | `testShippedConstantsAreSelfConsistent` | `isOlder(x, than: x)` — the two constants are the same literal today. Becomes real if they ever diverge. |
| `mac/Tests/MorbstackAppTests/TrackALaunchRescueTests.swift` | `testDumpWritesNoFileWhenNobodyAskedForOne` | No assertions at all. `emit` is non-throwing, and the "writes nowhere" half is never checked. |
| `mac/Tests/MorbstackKitTests/RequestPathEncodingTests.swift:31` | `testAQuestionMarkInsideAnIdentifierIsEscaped` | The input is already-encoded `%3F` and contains no `?`. See 3.1 — this one is actively misleading. |

### 2.9 Weak-but-caught (reported, not urgent)

These are individually stub-passable but a sibling in the same file kills the stub:
`ShareSurfaceTests.testConfiguredSharesCarryThePlansTags`,
`ShareSurfaceTests.testHostDetailBecomesTheNoteWhenRosettaIsNotInstalled`,
`PortForwardingTests.testHostEndpointIdentityMatchesMobysMappedIPv6Normalization`,
`PortForwardingTests.testRunningContainersPathFiltersServerSide`,
`K8sTests.testRewriteIsIdempotent` / `testRewriteLeavesUnrelatedLinesUntouched` /
`testMergeIntoAnEmptyConfigJustUsesOurs`, `ConfigTests.testRoundTripOfDefaults`,
`SharesTests.testNoSharesLeavesTheCmdlineUntouched`,
`MorbDiskGrowthTests`' two journal codec tests,
`DaemonUpdateCompatibilityTests.testRecognizesOnlyCanonicalLegacyUnknownCommand`,
`ImageArchiveImportTests`' inode assertion, `supervisor.rs`'s
`userland_proxy_state_agrees_with_the_real_service_table`, and
`jsonlite.rs`'s `round_trips_all_control_messages_from_the_contract`.

`PortForwardingTests.testContainerNetworkNeverEntersTheHostNetworkForwardingPath` is a
verbatim duplicate of two assertions inside a neighbouring test — redundant, not broken.

---

## Tier 3 — the test is hiding a real defect

### 3.1 `percentEncodePath` does not escape `?`, and the test named for it cannot fail

**File:** `mac/Tests/MorbstackKitTests/RequestPathEncodingTests.swift:31`
(`testAQuestionMarkInsideAnIdentifierIsEscaped`).

```swift
let encoded = MinimalHTTP.percentEncodePath("/containers/web%3Fforce=1")
XCTAssertFalse(encoded.contains("?"))
```

The input literal is already-encoded `%3F` — it contains no `?` at all, so no
implementation can put one in the output.

The claim in the test's name is **false as written**. `MinimalHTTP.percentEncodePath`
splits at the first `?` and passes the query through verbatim, so a *raw* `?` inside a
container identifier is treated as the query separator rather than escaped. A second,
independent implementation — `EngineClient.percentEncodePath` in `MorbFeatures` — has no
query split and *does* escape `?`. The two disagree, and only the safe one matches this
test's name.

`XCTAssertEqual(MinimalHTTP.percentEncodePath("/containers/web?force=1"), "/containers/web%3Fforce=1")`
would fail today. Not fixed here: whether the right answer is a path-segment-only entry
point or encoding the identifier at the `DockerClient.url(_:)` call site is a design
decision. Ticket in the report.

---

## Reliability — environment-dependent passes

### R.1 A real flake, reproduced and FIXED

`mac/Tests/MorbstackKitTests/PortForwardingTests.swift:161`
(`testExplicitTCPCreateBindingsCollapseAddressFamiliesForOneMacLease`) called
`inspectContainerCreate(body:)` without the `availability:` argument, so it took the
default probe, which really `bind(2)`s — on `0.0.0.0:8080` *and* `[::]:8080`.

**Reproduced deterministically** by holding a listener on 8080:

```
PortForwardingTests.swift:172: error: XCTAssertEqual failed:
  ("rejected(message: "driver failed programming external connectivity:
    Bind for 0.0.0.0:8080/tcp failed: port is already allocated")")
  is not equal to ("allowed")
```

**Fixed** by passing `availability: Self.alwaysAvailable` — the hermetic probe defined at
the top of that same file, whose doc comment says it exists for exactly this. This was
the only test in the file touching a real guessed port; the range and SCTP cases reject
or `continue` before probing.

### R.2 Tests that skip themselves into green

- `mac/Tests/MorbFeaturesTests/SupportTests.swift` — all of `EngineClientLiveTests` and
  `EngineTransferLiveTests` `XCTSkip` when no daemon is listening. Six tests are
  green-by-absence on any machine without a running engine. With a daemon but no
  containers, `testContainerListDecodesAsAnArrayOfObjects` iterates zero times.
- `mac/Tests/MorbstackKitTests/RosettaTests.swift` — `testInstallRefusesStatesItCannotHelp`
  skips unless the host already has Rosetta installed.
- `mac/Tests/MorbstackKitTests/K8sTests.swift` — `testPayloadDigestsMatchTheFetchScript`
  skips if `scripts/fetch-guest-assets.sh` is absent.
- `guest/morbinit/src/live_share_receiver.rs` — four tests never compiled on macOS (1.12).
- `guest/morbinit/src/k8s.rs` — `enabling_is_refused_when_the_payload_is_not_installed`
  and `a_fresh_state_reports_not_installed_and_stays_off` assert facts about the machine,
  not the code. `set_enabled`'s success path has zero tests.
- `guest/morbinit/src/supervisor.rs` — `dockerd_always_gets_a_resolved_userland_proxy`
  asserts `pinned_path || disabled`; the test's own comment concedes the branch depends on
  the filesystem. On macOS only `disabled` is ever true, so the fail-closed Mac
  port-publishing path is never asserted.

### R.3 Real host ports and real filesystem

- `mac/Tests/MorbstackKitTests/LifecycleTests.swift` and `GuestPortLeaseTests.swift` bind
  real host ports via `findFreePort()`, which releases the port before rebinding it — a
  TOCTOU window another process can win. `testStopFreesThePortSynchronouslyEnoughToRebindImmediately`
  reopens the same port 50 times, widening the window 50×. Both files also use
  `setenv("MORBSTACK_HOME")`, which is process-global and unsafe if XCTest parallelization
  is ever enabled.
- `mac/Tests/MorbstackKitTests/SharesTests.swift` — four Doctor tests call
  `Doctor.run(config:includeLiveShares:false)`, leaving `includeDockerIntegrationChecks`
  and `includeDaemonChecks` at `true`. That path connects to
  `~/.docker/run/docker-cli-api.sock` and `~/.docker/run/backend.sock`. Given CLAUDE.md
  §1.2, unit tests probing the user's Docker Desktop sockets deserve
  `includeDockerIntegrationChecks: false`.
- `mac/Tests/MorbstackAppTests/TrackBMountModelTests.swift` — the two
  `nearestExistingAncestor` tests read the real filesystem and assert `/private/tmp`
  exists, despite the production function taking an injectable `FileManager` for exactly
  this reason.

### R.4 Wall clock

`ModelTests.FormattersTests.testCompactDurationPicksTheShortestHonestUnit` uses `Date()`
for both the input and the implicit `now`, so a scheduling stall renders `"31s"` instead
of `"30s"`. `Formatters.compactDuration(since:at:)` takes an explicit `now` precisely so
this does not happen, and the sibling `testUnknownDates` already uses fixed dates. This
is the inverse defect — an intermittent failure rather than a can't-fail test.

### R.5 A List row that would not select under XCUITest — suspected cause, unconfirmed

An XCUITest agent working the container browser reported that it "could not reliably
select a container row against real (non-fixture) data — a synthetic click silently
failed to register a `List` selection," and worked around it rather than diagnosing it.

**Structural fact, confirmed by reading, independent of the hypothesis below:**
`ContainersRootView.swift`, `ContainerFilesTab.swift`, and `CommandPalette.swift` are
the only three `List(selection:)` screens in `mac/Sources/MorbstackAppCore` whose row
content carries `.onTapGesture(count: 2)`, added to preserve double-click-to-open now
that `List` has no `Table.primaryAction` equivalent. Every other selectable list or
table in the app either doesn't need that behaviour or gets it a different way:
`VolumesRootView`, `ImagesRootView`, and `NetworksRootView` use `Table`, which has
native primary-action support and no tap gesture on row content; `StacksRootView` uses
a `List` with `DisclosureGroup` sections but attaches no `onTapGesture` to its rows at
all. So the container browser, the container file browser, and the command palette are
the only three surfaces where this suspected mechanism could apply.

**Suspected cause, unconfirmed:** a `TapGesture` attached via `.onTapGesture` to row
content sits in front of the row's own AppKit-backed click/selection handling. A
single click delivered by a real user waits out the double-click interval and then
falls through to the list's normal single-click selection; there is a plausible path
by which a *synthetic* click injected outside that timing window is consumed by the
gesture recognizer instead of reaching the table view's selection handling. This would
explain the XCUITest agent's report. Nobody has demonstrated the mechanism directly —
no one has instrumented the gesture recognizer or the table view to show a synthetic
click being consumed by it, so it remains a hypothesis, not a finding.

**The experiment that would settle it:** temporarily delete the
`.onTapGesture(count: 2)` from `ContainersRootView`'s `containerRow(_:)`, run the
XCUITest that could not select a row against real (non-fixture) data, and see whether
it starts selecting reliably. If it does, the same change should be tried against
`ContainerFilesTab.swift`'s file list and `CommandPalette.swift`'s result list, since
both carry the identical pattern. If it does not, the mechanism above is wrong and the
XCUITest failure has some other cause. This is roughly a ten-minute check for whoever
next holds both the machine lane and a reason to care — it was not run here.

**Not corroborated by anything else.** A separate report of clicks failing against the
running app that arrived the same day as this entry turned out to be pointer
contention from an unrelated computer-use session driving a different window on the
same machine — clicks landed on menu bar coordinates nowhere near the target, and
sidebar rows (which carry no `onTapGesture` at all) failed identically, which the
mechanism above does not explain. That report is not evidence for or against this
hypothesis and is not counted as corroboration here.

---

## Cleared by stubbing

Reported so the list is not mistaken for a survey of everything suspicious-looking.

**`mac/Tests/MorbstackKitTests/DockerRequestFramingTests.swift`** (1755 lines) — no
can't-fail tests. Nearly every assertion is byte-for-byte equality against a literal wire
string built in the test. `RecordingPolicy` is a mock, but the subject under test is
production `DockerFramedRelay`/`DockerRequestFramer` throughout. This file is the quality
bar the rest should be measured against.

**`DockerExecPTYSessionTests.swift`** — `FakeExecEngine` is a real `UnixSocketServer`
dialled through the same client path production uses; every HTTP head and stdcopy frame
is hand-built and pinned. Not a mocked subject.

**`TerminalShellResolutionTests.swift`** — scripts only the Docker client; the real
`TerminalShellResolution.resolve` is the subject, and each test pins both the outcome and
the probe sequence.

**`StdcopyTests.swift`, `TarLiteTests.swift`** — wire frames and ustar headers are
constructed byte-by-byte *in the test*, never by a production encoder. Genuine anchors.

**`MRB0FlatnessTests.swift`** — notably well-defended against this exact failure mode: the
`object.isEmpty` guard is what stops a degenerate encoder from passing, and it drives the
real host encode path over a socketpair rather than re-encoding a test copy.

**`sha256.rs`** — NIST known-answer vectors for the empty string, `"abc"`, the 448-bit
case, the million-`a` case, and six padding-boundary digests. Its one self-comparison
(`hash_file` vs `hex_of`) is sound because both are independently pinned.

**`DockerBindMountPreflightTests.swift`** — every rejection pins the full user-visible
message; a blanket `.allowed` stub fails 12 tests.

Also cleared after full reads: `HTTPTests`, `RelayTests`, `FramingTests`,
`DoctorDiscoveryTests`, `MorbLocalDomainNameTests`, `MorbDiskResizeTests`,
`BackgroundServiceVerificationTests`, `CommandPolicyTests`, `GuestControlTests`,
`DynamicPortAllocationTests`, `DockerContextTests` (verified it never touches the real
`~/.docker`), `ContainerGroupingTests`, `ContainerStatsPresentationTests`,
`VolumeInspectorTests`, `ContainerExecCommandTests`, the Buildx and Compose decoder
files, `MCPProtocolTests`, `VolumeMigrationPlanTests`, `TrackDFuzzyMatcherTests`,
`TrackCImageArchTests`, and the Rust modules `shares`, `binfmt`, `dial`, `netaddr`,
`proxy`, `proxy_wrapper`, `live_share`, `wire`, `disk`.

---

## Is this systemic?

**Partly, and the pattern is specific enough to act on.**

Not a general quality problem. Several files here are genuinely excellent, and two of
them (`MRB0FlatnessTests`, and `ShellCompletionDriftTests` on another branch, which
parses `main.swift` rather than checking `--help` against itself) show authors who saw
this exact trap and designed around it. The median test in this repo pins literals.

The failures concentrate in three identifiable places:

1. **Presentation accessors** — `title`, `symbol`, `label`, `bytesString`,
   `suggestedFilename`. Every one is tested for shape (non-empty, distinct, right
   suffix) rather than content. This is the largest cluster and the one users would
   notice first. The cause is legible: asserting a literal string feels like testing the
   obvious, right up until the accessor returns `"x"` and nothing complains.

2. **Cross-language wire contracts** — `jsonlite::emit`, the datagram frame header, the
   live-share `rootID` and HMAC. Both sides ship in one bundle, so both sides are tested
   against themselves and the pair is internally consistent by construction. Notably,
   `control.rs` *does* pin the MRB0 magic and big-endian length correctly — the good
   pattern exists in the same file family as the gap.

3. **Anything behind a platform or environment gate** — the four Linux-only tests that
   never run, the `XCTSkip` families, the `find_iptables` and userland-proxy branches
   that only have one reachable outcome on macOS. `mise run check` runs `cargo test` on
   the host only, so ~85 `cfg(target_os = "linux")` gates make "260 passed" mean less
   than it reads.

**Not a period effect.** The whole suite was written between 2026-08-02 and 2026-08-05,
so history cannot discriminate. **Not one author's habit either** — the shapes recur
across every track.

### What to do about it

**A lint rule is the wrong answer for most of this**, and there is nowhere to put it:
`mise run check` runs clippy and shellcheck but has no Swift linter at all, and adding
SwiftLint to catch `XCTAssertEqual(x, x)` would catch exactly one finding here (2.8's
`GuestMACTests` line). The dominant shapes — an expectation derived from the subject, a
`count` check with no content check, a loop over a possibly-empty collection — are not
syntactically distinguishable from correct tests.

Three things would have caught most of this:

1. **A review checklist line, narrowly scoped to the two shapes that recur:** *"If a test
   asserts a round trip or routes its expectation through the function under test, name
   the sibling test that pins a literal. If there isn't one, write it."* That covers 1.1,
   1.3, 1.10, 1.11, 2.7.

2. **Extend `mise run check` to run `cargo test --target aarch64-unknown-linux-musl`**
   under an emulator, or at minimum move portable pure functions out of
   `#[cfg(target_os = "linux")] mod imp` so they compile into the host test binary.
   `parse_root`, `percent_decode`, `hmac_hex` and `close_is_authentic` are all pure. That
   covers 1.12 and much of R.2.

3. **Occasional mutation spot-checks.** The 14-symbol stub run that produced this
   document's headline took under a minute once the build was warm, and it is a far
   better signal than coverage percentage. Worth repeating on the presentation-accessor
   cluster after it is fixed.
