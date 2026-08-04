# Build Repair — `swarm/continuation`

The 74 Codex commits on this branch were never compiled or tested. This document
records every compile error and test failure found while making `mise run check`
green, the fix applied, and — most importantly — **every place intent had to be
inferred**, so a human can review exactly those decisions.

Fixes 1–5 were applied by the orchestrator before this pass and are recorded in
the code at the fix sites (DockerProxy escaping-closure capture, `Darwin.stat`
name collision, `Optional.flatMap` vs `Sequence.flatMap` binding, a nested
`enum State` shadowing SwiftUI `@State`, and four uses of a nonexistent
`Section(title:content:footer:)` overload). This pass picks up from there.

## Compile errors

### 1. `Views/Disk/DiskRootView.swift:816` — missing return in getter

`diskGrowthAction` had a `guard … else { return .none }` followed by a bare
`TrackCDiskGrowthPresentation.action(…)` expression. Swift's implicit return
only applies to single-expression bodies; the guard makes this multi-statement.

**Fix:** added the explicit `return`. No inference required — the expression was
already there and is the only value-producing statement.

### 2. `Views/Stacks/ComposeSourceValidation.swift:651` — `cannot find 'request' in scope`

`diagnostics(title:detail:output:)` referenced `request.snapshotDescription`
but took no such parameter.

**Fix (intent inferred, low risk):** added a `request:
ComposeSourceValidationRequest` parameter and passed it from the only caller —
the `.running(let request)` phase case, where `request` is in scope. The
sibling `resultView(request:result:)` already follows exactly this shape, and
the displayed value (`snapshotDescription`) is a constant string on the request
type. Flagged because the parameter list was authored, not recovered.

### 3. `Views/Stacks/ComposeSourceDeclarationReview.swift:47–56` — main-actor isolation (5 errors)

`init?(editor: ComposeFileEditor)` read five properties of the `@MainActor
@Observable` editor from a nonisolated init.

**Fix:** marked that convenience init `@MainActor`. Both call sites are inside
SwiftUI view bodies (already main-actor), so this moves the access onto the
main actor rather than weakening isolation — no `nonisolated(unsafe)`, no
`assumeIsolated`. The memberwise init stays nonisolated; it touches no
actor-isolated state.

### 4. Type-check timeout: `Views/Images/LocalImageRunSheet.swift:143` — **masked a real API-shape bug**

Splitting the giant `Form` body into per-section computed properties moved the
timeout rather than curing it, which exposed the actual defect: the
`confirmationDialog` call passed `presenting:` before `titleVisibility:`, an
argument order that matches **no** SwiftUI overload
(`confirmationDialog(_:isPresented:titleVisibility:presenting:actions:message:)`
is the real one). The impossible call is what sent the type checker into an
exponential overload search over the whole body.

**Fix:** swapped the two arguments (same values, same behavior) and kept the
structural split (sections/rows/toolbar extracted verbatim, order preserved).

### 5. Type-check timeouts: `Views/Builds/BuildsRootView.swift:500`, `Views/Networks/NetworksRootView.swift:350`

Both `body` properties were one literal modifier chain (~20 modifiers: sheets,
fileImporter, confirmation dialogs, alerts with inline `Binding(get:set:)`,
onChange/task/onDisappear handlers).

**Fix:** split each chain into staged private helpers
(`withSheetsAndImporter` → `withBuildDialogs` → `withOperationAlerts` →
`withLifecycleHandlers`, and the Networks equivalents) applied in the original
order. No modifier added, removed, or reordered; every closure body is
byte-identical. No behavioral inference involved.

### 6. `Tests/MorbstackAppTests/ModelTests.swift:898–899` — actor isolation in test

`testFixtureLaunchCarriesNonLiveProvenance` constructs `AppModel` (a
`@MainActor` type) from a nonisolated XCTest method.

**Fix:** annotated that one test method `@MainActor`, matching the established
pattern in `TrackDSettingsTests`.

## Test failures (test-means-check-the-code-first rule applied)

### 7. `PortMappingTests.testBrowserAddressUsesURLComponentsForIPv6Loopback` — **real bug in shipped code**

`PortMapping.browserAddress` set `URLComponents.host = "::1"`. Foundation
refuses to render a URL for an unbracketed IPv6 literal — `.url` is `nil`
(verified empirically on this toolchain; bracketed `"[::1]"` renders
`http://[::1]:8080`). So the feature Codex built — a browser link for an
IPv6-loopback-published port — could never have produced a link, and the UI
would instead have shown the misleading reason string "Browser actions require
a literal loopback binding; Docker reported ::1."

**Fix:** `Models.swift` `browserAddress` brackets the one accepted IPv6
loopback: `components.host = hostIP == "::1" ? "[::1]" : hostIP`. The test was
right; the code was wrong.

### 8. `TrackBLogExportTests.testTimestampsCanBeOmitted` — stale test after an intentional contract change (**intent inferred**)

Codex's commit 68a1763 ("Enhance native container observability") deliberately
changed `TrackBLogExport.text` from labeling only stderr lines to labeling
every line `[stdout] `/`[stderr] `, and updated the sibling test
(`testPreservesEveryDockerStreamAndTerminatesEveryLine`) in the same commit to
assert `[stdout] hello`. It did not update `testTimestampsCanBeOmitted`, which
still encoded the old stderr-only labeling.

**Fix:** updated the expected string in `testTimestampsCanBeOmitted` to
`"[stdout] hello\n[stderr] bad\n"`. The test's stated purpose — the timestamp
prefix disappears when `includeTimestamps: false` — is still fully asserted.
Flagged for review: the alternative reading (labels should vanish for stdout
when timestamps are off) contradicts the same commit's own updated sibling
test, so it was rejected, but a human should confirm the every-line labeling is
the wanted export format.

### 9. `DockerFramedRelayTests.testChunkedDynamicPortCreateNormalizesBodyFramingForTheRewrittenJSON`

(Investigated and fixed by a dedicated subagent; see the section appended
below / final report for root cause and whether it was a shipped behavioral
bug in the chunked-body rewrite path of the Docker proxy.)

## Lint gate

### 10. `guest/morbinit/src/publish_all.rs` — clippy `items_after_test_module`

`pub use imp::spawn_publish_all_allocator` (Linux) and the non-Linux stub sat
after `mod tests`. **Fix:** moved both above the test module. Pure reordering.

### 11. `scripts/ecosystem-acceptance.sh:61` — shellcheck SC1007

`CDPATH= cd -- …` is a real POSIX idiom (neutralize `CDPATH` for one `cd`) but
trips SC1007. **Fix:** `CDPATH='' cd -- …` — identical semantics, lint-clean,
with a comment explaining why the quotes are there.

## Places a human should review (summary)

1. **ComposeSourceValidation `diagnostics`** now takes a `request` parameter —
   inferred from the caller and the sibling function's shape (§2).
2. **`testTimestampsCanBeOmitted`** was updated to the new every-line labeling
   contract rather than reverting the export format (§8) — the only fix in this
   pass that changed a test's expected value.
3. The framing-relay fix (§9) — see final report.
