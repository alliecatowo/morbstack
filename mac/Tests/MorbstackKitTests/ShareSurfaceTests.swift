// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the surface layer `morb shares`, `morb rosetta` and the app all read.
//
// The theme running through these tests is a single distinction that is easy to lose and
// expensive to lose: **"not mounted" and "we have not been told" are different answers.**
// Collapsing them produces a UI that reports three broken shares on a perfectly healthy
// Mac with the engine stopped, which is the failure mode this layer exists to prevent.
//
// Nothing here touches the filesystem, a daemon, or `~/.morbstack`: the planner's probe
// and the writability check are both injected.

import Foundation
import XCTest

@testable import MorbstackKit

final class ShareSurfaceTests: XCTestCase {

    // MARK: - Fixtures

    /// A probe that calls every path in `present` a readable directory and everything
    /// else missing.
    private func probe(present: Set<String>) -> (String) -> MorbShares.RootStatus {
        { path in present.contains(path) ? .ok : .missing }
    }

    private func config(_ paths: [String]) -> MorbConfig {
        var config = MorbConfig()
        config.sharedPaths = paths
        return config
    }

    // MARK: - Configured shares

    func testConfiguredSharesCarryThePlansTags() {
        let report = MorbShareSurface.configuredShares(
            config: config(["/Users", "/Volumes"]),
            probe: probe(present: ["/Users", "/Volumes"]),
            writable: { _ in true })

        XCTAssertEqual(report.source, .config)
        XCTAssertNil(report.configError)
        XCTAssertEqual(report.shares.map(\.path), ["/Users", "/Volumes"])
        // The tags must be the ones the guest would actually be told, not a second
        // numbering invented here.
        XCTAssertEqual(report.shares.map(\.tag), [MorbShares.tag(at: 0), MorbShares.tag(at: 1)])
    }

    func testConfiguredSharesAreNeverReportedAsMounted() {
        let report = MorbShareSurface.configuredShares(
            config: config(["/Users"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in true })

        XCTAssertFalse(report.shares[0].mounted)
        // Degraded by the raw predicate — but not a warning, because nothing was asked.
        XCTAssertTrue(report.shares[0].isDegraded)
        XCTAssertFalse(report.hasWarning, "a config-only report must never raise a warning")
    }

    func testSkippedRootsKeepTheirReasonAndGetNoTag() {
        let report = MorbShareSurface.configuredShares(
            config: config(["/Users", "/nope"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in true })

        let missing = report.shares.first { $0.path == "/nope" }
        XCTAssertEqual(missing?.skippedReason, "does not exist on this Mac")
        XCTAssertEqual(missing?.tag, "", "a root that was never shared was never given a tag")
        XCTAssertEqual(missing?.stateDescription, "skipped")
    }

    func testANestedRootIsReportedAsCoveredRatherThanDropped() {
        let report = MorbShareSurface.configuredShares(
            config: config(["/Users", "/Users/me/src"]),
            probe: probe(present: ["/Users", "/Users/me/src"]),
            writable: { _ in true })

        XCTAssertEqual(report.shares.count, 2, "a covered root still deserves a row")
        let nested = report.shares.first { $0.path == "/Users/me/src" }
        XCTAssertEqual(nested?.skippedReason, "already covered by the /Users share")
    }

    func testDuplicatePathsCollapseToOneRow() {
        let report = MorbShareSurface.configuredShares(
            config: config(["/Users", "/Users/"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in true })
        XCTAssertEqual(report.shares.map(\.path), ["/Users"])
    }

    func testRootWritabilityIsRecordedButIsNotAnAccessMode() {
        let report = MorbShareSurface.configuredShares(
            config: config(["/Users"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in false })

        XCTAssertEqual(report.shares[0].rootWritable, false)
        // The distinction this whole field exists for: /Users is unwritable on every
        // stock Mac and its bind mounts are emphatically not read-only.
        XCTAssertFalse(
            report.shares[0].readOnly,
            "host root permissions must not be presented as the share's mount access")
    }

    func testAnUnplannableConfigStillProducesRows() {
        // A relative path makes `MorbShares.plan` throw outright.
        let report = MorbShareSurface.configuredShares(
            config: config(["relative/path", "/Users"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in true })

        XCTAssertNotNil(report.configError, "the reason must reach the user")
        XCTAssertFalse(
            report.shares.isEmpty,
            "a surface must never answer a broken config with an empty list")
    }

    // MARK: - Decoding the daemon's reply

    func testDecodeReturnsNilWhenTheDaemonSaysNothingAboutShares() {
        XCTAssertNil(MorbShareSurface.decodeShares(nil))
        XCTAssertNil(
            MorbShareSurface.decodeShares(["state": .string("running")]),
            "a daemon that does not implement `shares` is not a daemon reporting zero shares")
    }

    func testDecodeDistinguishesAnEmptyAnswerFromNoAnswer() {
        XCTAssertEqual(MorbShareSurface.decodeShares(["shares": .array([])])?.count, 0)
    }

    func testDecodeReadsEveryField() {
        let payload: [String: AnyCodableValue] = [
            "shares": .array([
                .object([
                    "path": .string("/Users"),
                    "tag": .string("morbshare0"),
                    "read_only": .bool(true),
                    "configured": .bool(true),
                    "mounted": .bool(true),
                    "guest_path": .string("/Users"),
                    "root_writable": .bool(false),
                    "error": .null,
                ])
            ])
        ]
        let shares = MorbShareSurface.decodeShares(payload)
        XCTAssertEqual(shares?.count, 1)
        let share = shares?[0]
        XCTAssertEqual(share?.path, "/Users")
        XCTAssertEqual(share?.tag, "morbshare0")
        XCTAssertEqual(share?.readOnly, true)
        XCTAssertEqual(share?.mounted, true)
        XCTAssertEqual(share?.rootWritable, false)
        XCTAssertNil(share?.error)
        XCTAssertEqual(share?.stateDescription, "mounted (read-only)")
    }

    func testGuestPathDefaultsToTheHostPath() {
        let shares = MorbShareSurface.decodeShares([
            "shares": .array([.object(["path": .string("/Users")])])
        ])
        // The same-path invariant, asserted at the boundary rather than assumed.
        XCTAssertEqual(shares?[0].guestPath, "/Users")
        XCTAssertTrue(shares?[0].isSamePath ?? false)
    }

    func testATranslatedGuestPathIsPreservedRatherThanFlattened() {
        let shares = MorbShareSurface.decodeShares([
            "shares": .array([
                .object(["path": .string("/Users"), "guest_path": .string("/mnt/users")])
            ])
        ])
        XCTAssertFalse(
            shares?[0].isSamePath ?? true,
            "a surface must be able to notice the invariant breaking")
    }

    func testAnEntryWithoutAPathIsDropped() {
        let shares = MorbShareSurface.decodeShares([
            "shares": .array([.object(["tag": .string("morbshare0")]), .string("nonsense")])
        ])
        XCTAssertEqual(shares?.count, 0)
    }

    func testEncodeRoundTripsThroughDecode() {
        let original = [
            MorbShareState(
                path: "/Users", tag: "morbshare0", readOnly: true, configured: true,
                mounted: true, rootWritable: false, skippedReason: nil, error: nil),
            MorbShareState(
                path: "/nope", tag: "", configured: true, mounted: false,
                skippedReason: "does not exist on this Mac"),
        ]
        let decoded = MorbShareSurface.decodeShares(["shares": MorbShareSurface.encode(original)])
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Merging

    func testMergeKeepsAConfiguredRootTheGuestNeverMentioned() {
        let configured = [MorbShareState(path: "/Users", tag: "morbshare0")]
        let merged = MorbShareSurface.merge(configured: configured, live: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(
            merged[0].isDegraded,
            "the whole point of the warning is the root the guest failed to mount")
    }

    func testMergeTakesMountStateFromTheGuest() {
        let merged = MorbShareSurface.merge(
            configured: [MorbShareState(path: "/Users", tag: "morbshare0")],
            live: [MorbShareState(path: "/Users", tag: "morbshare0", mounted: true)])

        XCTAssertTrue(merged[0].mounted)
        XCTAssertFalse(merged[0].isDegraded)
    }

    func testMergePrefersTheDaemonsTagAndKeepsTheHostsSkipReason() {
        let configured = [
            MorbShareState(path: "/Users", tag: "morbshare0", skippedReason: "host said so")
        ]
        let live = [MorbShareState(path: "/Users", tag: "morbshare3", mounted: true)]
        let merged = MorbShareSurface.merge(configured: configured, live: live)

        XCTAssertEqual(merged[0].tag, "morbshare3", "the guest was told the daemon's tag")
        XCTAssertEqual(
            merged[0].skippedReason, "host said so",
            "the guest has no way to know why the host skipped something")
    }

    func testMergeAppendsAShareTheConfigNoLongerAsksFor() {
        let merged = MorbShareSurface.merge(
            configured: [MorbShareState(path: "/Users", tag: "morbshare0")],
            live: [
                MorbShareState(path: "/Users", tag: "morbshare0", mounted: true),
                MorbShareState(path: "/Volumes", tag: "morbshare1", configured: false, mounted: true),
            ])

        XCTAssertEqual(merged.count, 2)
        let extra = merged.first { $0.path == "/Volumes" }
        XCTAssertEqual(extra?.configured, false)
        XCTAssertFalse(extra?.isDegraded ?? true, "an unconfigured mount is not a missing one")
    }

    // MARK: - Reports

    func testAReportWithoutADaemonNeverWarns() {
        let configured = MorbShareSurface.configuredShares(
            config: config(["/Users"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in true })
        let report = MorbShareSurface.report(configured: configured, live: nil)

        XCTAssertEqual(report.source, .config)
        XCTAssertEqual(report.degradedCount, 1, "the raw count is still true")
        XCTAssertFalse(report.hasWarning, "but a stopped engine is not a degraded engine")
    }

    func testALiveReportWarnsOnlyForRootsTheGuestIsMissing() {
        let configured = MorbShareSurface.configuredShares(
            config: config(["/Users", "/Volumes"]),
            probe: probe(present: ["/Users", "/Volumes"]),
            writable: { _ in true })
        let report = MorbShareSurface.report(
            configured: configured,
            live: [
                MorbShareState(path: "/Users", tag: "morbshare0", mounted: true),
                MorbShareState(path: "/Volumes", tag: "morbshare1", mounted: false),
            ])

        XCTAssertEqual(report.source, .daemon)
        XCTAssertEqual(report.mountedCount, 1)
        XCTAssertEqual(report.degradedCount, 1)
        XCTAssertTrue(report.hasWarning)
    }

    func testConfigErrorSurvivesTheLiveOverlay() {
        var configured = MorbShareSurface.configuredShares(
            config: config(["/Users"]),
            probe: probe(present: ["/Users"]),
            writable: { _ in true })
        configured.configError = "boom"
        let report = MorbShareSurface.report(configured: configured, live: [])
        XCTAssertEqual(report.configError, "boom")
    }

    // MARK: - The status shortcut

    func testDegradedCountInStatusDistinguishesZeroFromSilence() {
        XCTAssertNil(MorbShareSurface.degradedCount(inStatus: nil))
        XCTAssertNil(
            MorbShareSurface.degradedCount(inStatus: ["state": .string("running")]),
            "an older daemon saying nothing is not a daemon saying zero")
        XCTAssertEqual(MorbShareSurface.degradedCount(inStatus: ["shares_degraded": .int(0)]), 0)
        XCTAssertEqual(MorbShareSurface.degradedCount(inStatus: ["shares_degraded": .int(2)]), 2)
        // JSON numbers occasionally arrive as doubles depending on the encoder.
        XCTAssertEqual(MorbShareSurface.degradedCount(inStatus: ["shares_degraded": .double(3)]), 3)
    }

    // MARK: - Rosetta

    func testRosettaAvailabilityMatrix() {
        func availability(
            host: RosettaState, enabled: Bool, active: Bool? = nil, binfmt: Bool? = nil
        ) -> MorbRosettaState.Availability {
            MorbShareSurface.rosetta(
                host: host,
                enabledInConfig: enabled,
                live: MorbRosettaState(activeInGuest: active, binfmtRegistered: binfmt)
            ).availability
        }

        XCTAssertEqual(availability(host: .notSupported, enabled: true), .unsupported)
        XCTAssertEqual(availability(host: .notInstalled, enabled: true), .notInstalled)
        XCTAssertEqual(availability(host: .installed, enabled: false), .disabled)
        XCTAssertEqual(availability(host: .installed, enabled: true), .ready)
        XCTAssertEqual(
            availability(host: .installed, enabled: true, active: true, binfmt: true), .active)
        // The share mounted but binfmt never registered: not "active", and emphatically
        // not "install it" either — the remedy is a restart or a bug report.
        XCTAssertEqual(
            availability(host: .installed, enabled: true, active: true, binfmt: false), .ready)
    }

    func testAnUnansweredGuestIsNotABrokenGuest() {
        let quiet = MorbShareSurface.rosetta(host: .installed, enabledInConfig: true, live: nil)
        XCTAssertFalse(quiet.guestAnswered)
        XCTAssertFalse(quiet.isBrokenInGuest)
        XCTAssertEqual(quiet.remedy, "Start the engine — Rosetta is attached when the VM boots.")

        let broken = MorbShareSurface.rosetta(
            host: .installed,
            enabledInConfig: true,
            live: MorbRosettaState(activeInGuest: true, binfmtRegistered: false))
        XCTAssertTrue(broken.guestAnswered)
        XCTAssertTrue(broken.isBrokenInGuest)
        // The distinction that matters: never send somebody to install what they have.
        XCTAssertEqual(broken.availability, .ready)
        XCTAssertFalse(broken.remedy?.contains("rosetta install") ?? true)
        XCTAssertTrue(broken.remedy?.contains("Restart") ?? false)
    }

    func testNullGuestFieldsDecodeAsUnknownRatherThanFalse() {
        // The daemon sends `null` for these when the guest has not answered. Reading it
        // as `false` would turn "the VM is not running" into "Rosetta is broken".
        let state = MorbShareSurface.decodeRosetta([
            "installed": .bool(true),
            "enabled_in_config": .bool(true),
            "active_in_guest": .null,
            "binfmt_registered": .null,
        ])
        XCTAssertNil(state?.activeInGuest)
        XCTAssertNil(state?.binfmtRegistered)
        XCTAssertEqual(state?.guestAnswered, false)
        XCTAssertEqual(state?.isBrokenInGuest, false)
    }

    func testAnUnknownHostStateIsTreatedAsUnsupportedRatherThanInstallable() {
        let state = MorbShareSurface.rosetta(host: .unknown, enabledInConfig: true, live: nil)
        XCTAssertFalse(state.supported)
        XCTAssertEqual(state.availability, .unsupported)
        XCTAssertFalse(
            state.installed,
            "offering an install for an availability we do not understand offers a no-op")
    }

    func testTheHostOutranksAStaleDaemonOnInstallation() {
        // Immediately after `morb rosetta install`: the host has it, the still-running
        // daemon booted without it. The install must not be offered again.
        let state = MorbShareSurface.rosetta(
            host: .installed,
            enabledInConfig: true,
            live: MorbRosettaState(installed: false, activeInGuest: false, binfmtRegistered: false))

        XCTAssertTrue(state.installed)
        XCTAssertEqual(state.availability, .ready)
    }

    func testTheGuestOutranksTheHostOnActivation() {
        // The two facts only the guest has are the two it contributes.
        let state = MorbShareSurface.rosetta(
            host: .installed,
            enabledInConfig: true,
            live: MorbRosettaState(activeInGuest: true, binfmtRegistered: true))
        XCTAssertEqual(state.activeInGuest, true)
        XCTAssertEqual(state.binfmtRegistered, true)
        XCTAssertEqual(state.availability, .active)
    }

    func testHostDetailBecomesTheNoteWhenRosettaIsNotInstalled() {
        let state = MorbShareSurface.rosetta(host: .notInstalled, enabledInConfig: true, live: nil)
        XCTAssertEqual(state.note, RosettaState.notInstalled.detail)

        let installed = MorbShareSurface.rosetta(host: .installed, enabledInConfig: true, live: nil)
        XCTAssertNil(installed.note, "there is nothing to explain about a working host")
    }

    func testDecodeRosettaNeedsAtLeastOneKnownKey() {
        XCTAssertNil(MorbShareSurface.decodeRosetta(nil))
        XCTAssertNil(
            MorbShareSurface.decodeRosetta(["note": .string("hello")]),
            "a reply with only a note is a daemon that does not implement the command")
        XCTAssertNotNil(MorbShareSurface.decodeRosetta(["installed": .bool(false)]))
    }

    func testDecodeRosettaCarriesTheHostsSupportVerdict() {
        let state = MorbShareSurface.decodeRosetta(["installed": .bool(false)], supported: false)
        XCTAssertEqual(state?.supported, false)
        XCTAssertEqual(state?.availability, .unsupported)
    }

    func testEverySummaryIsNonEmptyAndDistinct() {
        // The summary is the whole message in `morb rosetta`'s headline and in Settings'
        // Rosetta row; a duplicate would make two different states indistinguishable.
        var seen = Set<String>()
        for availability in [
            MorbRosettaState.Availability.active, .ready, .disabled, .notInstalled, .unsupported,
        ] {
            let state: MorbRosettaState
            switch availability {
            case .active:
                state = MorbRosettaState(installed: true, activeInGuest: true, binfmtRegistered: true)
            case .ready:
                state = MorbRosettaState(installed: true, activeInGuest: nil)
            case .disabled:
                state = MorbRosettaState(installed: true, enabledInConfig: false)
            case .notInstalled:
                state = MorbRosettaState(installed: false)
            case .unsupported:
                state = MorbRosettaState(supported: false)
            }
            XCTAssertEqual(state.availability, availability)
            XCTAssertFalse(state.summary.isEmpty)
            XCTAssertTrue(seen.insert(state.summary).inserted, "duplicate summary: \(state.summary)")
        }
    }
}

// MARK: - Command policy

/// The read-only observations must never be the reason a VM exists.
///
/// Separate from `CommandPolicyTests` so the two files can be edited independently; the
/// rule is the same one, applied to the two commands this milestone added.
final class ShareCommandPolicyTests: XCTestCase {

    func testSharesNeverAutoStartsADaemon() {
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("shares"))
        XCTAssertTrue(MorbCommandPolicy.selfServedCommands.contains("shares"))
    }

    func testRosettaNeverAutoStartsADaemon() {
        // Stronger than the `status` case: `morb rosetta install` puts a system
        // software-installation dialog on screen, and a daemon spawned behind the user's
        // back must never be what causes that.
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("rosetta"))
        XCTAssertTrue(MorbCommandPolicy.selfServedCommands.contains("rosetta"))
    }

    func testSelfServedAndAutoStartingStayDisjoint() {
        XCTAssertTrue(
            MorbCommandPolicy.selfServedCommands
                .isDisjoint(with: MorbCommandPolicy.autoStartingCommands))
    }

    func testOnlyLifecycleCommandsMaySpawn() {
        // Guards the direction of drift that matters: something new becoming
        // auto-starting by accident.
        for command in ["shares", "rosetta", "rosetta_install", "status", "stop", "suspend"] {
            XCTAssertFalse(
                MorbCommandPolicy.mayAutoStartDaemon(command),
                "`\(command)` must not be able to conjure a daemon")
        }
        XCTAssertTrue(MorbCommandPolicy.mayAutoStartDaemon("start"))
        XCTAssertTrue(MorbCommandPolicy.mayAutoStartDaemon("resume"))
    }
}
