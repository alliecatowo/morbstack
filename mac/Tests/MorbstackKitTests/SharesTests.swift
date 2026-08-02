// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Coverage for VirtioFS directory sharing: config parsing, the planner, and the
/// kernel-command-line encoding that carries the plan to the guest.
///
/// The encoding tests are deliberately paranoid. The command line is the *only*
/// channel between the host's plan and morbinit's mounts, it is parsed twice by
/// two implementations in two languages, and a mistake in it does not produce an
/// error — it produces a container with an empty directory where the user's source
/// tree should be. `guest/morbinit/src/shares.rs` holds the mirror-image suite.
final class SharesTests: XCTestCase {

    /// A probe that says "readable directory" for a fixed set and "missing" otherwise.
    private func probe(existing: Set<String>) -> (String) -> MorbShares.RootStatus {
        { existing.contains($0) ? .ok : .missing }
    }

    // MARK: - Config

    func testSharedPathsDefaultToTheDockerDesktopSet() {
        XCTAssertEqual(MorbConfig().sharedPaths, ["/Users", "/Volumes", "/private/tmp"])
    }

    func testSharedPathsParseFromASingleLineArray() throws {
        let config = try MorbConfig.parse(
            """
            shared_paths = ["/Users", "/Volumes/Work", "/private/tmp"]
            """)
        XCTAssertEqual(config.sharedPaths, ["/Users", "/Volumes/Work", "/private/tmp"])
    }

    func testAnExplicitEmptyArrayDisablesSharing() throws {
        // Distinct from an absent key, which keeps the defaults. Somebody who writes
        // `shared_paths = []` means it.
        let config = try MorbConfig.parse("shared_paths = []")
        XCTAssertEqual(config.sharedPaths, [])
        XCTAssertNotEqual(config.sharedPaths, MorbShares.defaultSharedPaths)
    }

    func testAnAbsentKeyKeepsTheDefaults() throws {
        let config = try MorbConfig.parse("cpus = 4")
        XCTAssertEqual(config.sharedPaths, MorbShares.defaultSharedPaths)
    }

    func testArrayElementsMayContainCommasSpacesAndComments() throws {
        let config = try MorbConfig.parse(
            """
            shared_paths = ["/Volumes/My Disk", "/Volumes/a,b"]  # trailing comment
            """)
        XCTAssertEqual(config.sharedPaths, ["/Volumes/My Disk", "/Volumes/a,b"])
    }

    func testATrailingCommaIsAccepted() throws {
        let config = try MorbConfig.parse("shared_paths = [\"/Users\",]")
        XCTAssertEqual(config.sharedPaths, ["/Users"])
    }

    func testAnUnterminatedArrayIsAnError() {
        XCTAssertThrowsError(try MorbConfig.parse("shared_paths = [\"/Users\""))
    }

    func testNonStringArrayElementsAreAnError() {
        XCTAssertThrowsError(try MorbConfig.parse("shared_paths = [1, 2]"))
    }

    func testASharedPathsScalarIsAnError() {
        // Silently ignoring `shared_paths = "/Users"` would leave the user staring at
        // an empty bind mount with a config file that looks right.
        XCTAssertThrowsError(try MorbConfig.parse("shared_paths = \"/Users\""))
    }

    func testSharedPathsRoundTripThroughTheCanonicalWriter() throws {
        var config = MorbConfig()
        config.sharedPaths = ["/Users", "/Volumes/My Disk", "/private/tmp"]
        XCTAssertEqual(try MorbConfig.parse(config.toTOML()), config)
    }

    func testAnEmptySharedPathsListRoundTrips() throws {
        var config = MorbConfig()
        config.sharedPaths = []
        XCTAssertEqual(try MorbConfig.parse(config.toTOML()).sharedPaths, [])
    }

    // MARK: - Planning

    func testThePlanTagsSharesInOrder() throws {
        let plan = try MorbShares.plan(
            paths: ["/Users", "/Volumes", "/private/tmp"],
            probe: probe(existing: ["/Users", "/Volumes", "/private/tmp"]))
        XCTAssertEqual(plan.shares.map(\.tag), ["morbshare0", "morbshare1", "morbshare2"])
        XCTAssertEqual(plan.shares.map(\.path), ["/Users", "/Volumes", "/private/tmp"])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testMissingRootsAreSkippedNotFatal() throws {
        // The state of a Mac with nothing mounted under /Volumes. Refusing to boot
        // over it would be absurd; the numbering must still be dense.
        let plan = try MorbShares.plan(
            paths: ["/Users", "/Volumes", "/private/tmp"],
            probe: probe(existing: ["/Users", "/private/tmp"]))
        XCTAssertEqual(plan.shares.map(\.path), ["/Users", "/private/tmp"])
        XCTAssertEqual(plan.shares.map(\.tag), ["morbshare0", "morbshare1"])
        XCTAssertEqual(plan.skipped.map(\.path), ["/Volumes"])
    }

    func testANonDirectoryIsSkipped() throws {
        let plan = try MorbShares.plan(paths: ["/Users/somefile"]) { _ in .notDirectory }
        XCTAssertTrue(plan.shares.isEmpty)
        XCTAssertEqual(plan.skipped.first?.path, "/Users/somefile")
    }

    func testAnUnreadableRootIsAnError() {
        // Not skipped: the user asked for it, and a silently absent share turns every
        // bind mount under it into an empty directory inside the container.
        XCTAssertThrowsError(try MorbShares.plan(paths: ["/Users"]) { _ in .unreadable })
    }

    func testNestedRootsAreCollapsedToTheOuterOne() throws {
        let plan = try MorbShares.plan(
            paths: ["/Users", "/Users/me/proj"],
            probe: probe(existing: ["/Users", "/Users/me/proj"]))
        XCTAssertEqual(plan.shares.map(\.path), ["/Users"])
        XCTAssertEqual(plan.skipped.first?.reason, "already covered by the /Users share")
    }

    func testASiblingThatMerelySharesAPrefixIsNotNested() throws {
        // "/Users2" starts with "/Users" as a *string* but is a different directory.
        let plan = try MorbShares.plan(
            paths: ["/Users", "/Users2"], probe: probe(existing: ["/Users", "/Users2"]))
        XCTAssertEqual(plan.shares.map(\.path), ["/Users", "/Users2"])
    }

    func testDuplicatesAreCollapsed() throws {
        let plan = try MorbShares.plan(
            paths: ["/Users", "/Users/", "/Users"], probe: probe(existing: ["/Users"]))
        XCTAssertEqual(plan.shares.map(\.path), ["/Users"])
        XCTAssertEqual(plan.skipped.count, 2)
    }

    func testTheRootFilesystemIsRefused() {
        // Mounting the Mac's / at the guest's / would bury the guest's own rootfs,
        // taking dockerd, busybox and PID 1's own binary with it.
        XCTAssertThrowsError(try MorbShares.plan(paths: ["/"]) { _ in .ok })
    }

    func testRelativePathsAreRefused() {
        XCTAssertThrowsError(try MorbShares.plan(paths: ["projects"]) { _ in .ok })
    }

    func testTooManySharesIsAnError() {
        let paths = (0..<(MorbShares.maximumShares + 1)).map { "/root\($0)" }
        XCTAssertThrowsError(try MorbShares.plan(paths: paths) { _ in .ok })
    }

    func testExactlyTheMaximumIsAllowed() throws {
        let paths = (0..<MorbShares.maximumShares).map { "/root\($0)" }
        let plan = try MorbShares.plan(paths: paths) { _ in .ok }
        XCTAssertEqual(plan.shares.count, MorbShares.maximumShares)
    }

    func testNormalisationStripsTrailingSlashesAndExpandsTilde() {
        XCTAssertEqual(MorbShares.normalise("/Users/"), "/Users")
        XCTAssertEqual(MorbShares.normalise("/Users//me/../me"), "/Users/me")
        XCTAssertEqual(MorbShares.normalise("/Users/./me"), "/Users/me")
        XCTAssertEqual(MorbShares.normalise("/.."), "/")
        XCTAssertTrue(MorbShares.normalise("~/code").hasPrefix("/"))
    }

    func testNormalisationDoesNotCollapsePrivate() {
        // Regression. `NSString.standardizingPath` rewrites /private/tmp to /tmp and
        // /private/var to /var, because both are symlinks on macOS. Used here that is
        // destructive rather than tidy: the normalised path becomes a *mount point
        // inside the guest*, so the share would land on top of the guest's own /tmp
        // tmpfs — the exact hazard `tmpAliasWarning` describes — and a
        // `-v /private/tmp/x:/y` bind would then miss the share entirely.
        XCTAssertEqual(MorbShares.normalise("/private/tmp"), "/private/tmp")
        XCTAssertEqual(MorbShares.normalise("/private/var"), "/private/var")
        XCTAssertEqual(MorbShares.normalise("/private/tmp/"), "/private/tmp")
    }

    func testTheDefaultPlanSharesPrivateTmpUnderItsRealName() throws {
        // The end-to-end version of the check above: what the guest is actually told.
        let plan = try MorbShares.plan(paths: MorbShares.defaultSharedPaths) { _ in .ok }
        XCTAssertEqual(plan.shares.map(\.path), ["/Users", "/Volumes", "/private/tmp"])
        let cmdline = try MorbShares.appendToCmdline("console=hvc0", shares: plan.shares)
        XCTAssertTrue(cmdline.contains("morb.share=morbshare2:/private/tmp"), cmdline)
        XCTAssertFalse(cmdline.contains(":/tmp"), "a share must never be mounted over the guest's tmpfs")
    }

    func testTheMacOSPrivateSymlinksAreMappedForwardNotShared() throws {
        // /tmp, /var and /etc are symlinks into /private on macOS. Sharing them under
        // those names would mount the Mac over the guest's tmpfs, its layer store and
        // its configuration respectively, so they are rewritten to the real path.
        let plan = try MorbShares.plan(paths: ["/tmp", "/var", "/etc"]) { _ in .ok }
        XCTAssertEqual(plan.shares.map(\.path), ["/private/tmp", "/private/var", "/private/etc"])
    }

    func testConfiguringTmpAndPrivateTmpYieldsOneShare() throws {
        let plan = try MorbShares.plan(paths: ["/tmp", "/private/tmp"]) { _ in .ok }
        XCTAssertEqual(plan.shares.map(\.path), ["/private/tmp"])
    }

    func testGuestSystemRootsAreRefused() {
        // Mounting the Mac's /usr at the guest's /usr hides dockerd, containerd and
        // busybox: the guest boots and then cannot run anything.
        for reserved in ["/usr", "/bin", "/sbin", "/lib", "/proc", "/sys", "/dev", "/run"] {
            XCTAssertThrowsError(
                try MorbShares.plan(paths: [reserved]) { _ in .ok },
                "sharing \(reserved) must be refused")
        }
    }

    func testASubdirectoryOfAReservedRootIsFine() throws {
        // Only the root itself is dangerous; /usr/local/share-me shadows nothing the
        // guest needs.
        let plan = try MorbShares.plan(paths: ["/usr/local/morbtest"]) { _ in .ok }
        XCTAssertEqual(plan.shares.map(\.path), ["/usr/local/morbtest"])
    }

    // MARK: - Kernel command line

    func testCmdlineArgumentsAreOnePerShare() {
        let shares = [
            MorbDirectoryShare(tag: "morbshare0", path: "/Users"),
            MorbDirectoryShare(tag: "morbshare1", path: "/private/tmp"),
        ]
        XCTAssertEqual(
            MorbShares.cmdlineArguments(for: shares),
            ["morb.share=morbshare0:/Users", "morb.share=morbshare1:/private/tmp"])
    }

    func testSharesAreAppendedToTheBootModeCmdline() throws {
        var config = MorbConfig()
        config.sharedPaths = ["/Users"]
        let shares = [MorbDirectoryShare(tag: "morbshare0", path: "/Users")]
        let cmdline = try config.resolvedKernelCmdline(for: .initramfs, shares: shares)
        XCTAssertEqual(cmdline, MorbConfig.initramfsKernelCmdline + " morb.share=morbshare0:/Users")
    }

    func testSharesSurviveAKernelCmdlineOverride() throws {
        // An override changes how the guest boots; it must not silently delete the
        // share map and with it every bind mount.
        var config = MorbConfig()
        config.kernelCmdline = "console=ttyAMA0 rdinit=/init"
        let shares = [MorbDirectoryShare(tag: "morbshare0", path: "/Users")]
        let cmdline = try config.resolvedKernelCmdline(for: .initramfs, shares: shares)
        XCTAssertTrue(cmdline.hasPrefix("console=ttyAMA0 rdinit=/init"))
        XCTAssertTrue(cmdline.contains("morb.share=morbshare0:/Users"))
    }

    func testNoSharesLeavesTheCmdlineUntouched() throws {
        let config = MorbConfig()
        XCTAssertEqual(
            try config.resolvedKernelCmdline(for: .initramfs, shares: []),
            MorbConfig.initramfsKernelCmdline)
    }

    func testAnOverlongCmdlineIsRefusedRatherThanTruncated() {
        // The kernel truncates silently, and the symptom would be "the last share
        // mysteriously did not mount".
        let shares = (0..<8).map {
            MorbDirectoryShare(tag: "morbshare\($0)", path: "/Users/" + String(repeating: "x", count: 300))
        }
        XCTAssertThrowsError(try MorbShares.appendToCmdline("console=hvc0", shares: shares))
    }

    func testHandWrittenShareArgumentsInTheOverrideAreRefused() {
        // Observed for real: a `morb.share=morbshare2:/private/tmp:ro` left in
        // `kernel_cmdline` while shared_paths still had three entries produced two
        // `morbshare2` arguments naming different devices, and the guest mounted the
        // hand-written one — a read-only /private/tmp nobody had configured.
        var config = MorbConfig()
        config.kernelCmdline = "console=hvc0 rdinit=/init morb.share=morbshare2:/private/tmp:ro"
        let shares = [MorbDirectoryShare(tag: "morbshare0", path: "/Users")]
        XCTAssertThrowsError(try config.resolvedKernelCmdline(for: .initramfs, shares: shares))
    }

    func testAnOverrideMayOwnTheShareMapWhenSharedPathsIsEmpty() throws {
        // The escape hatch stays open, it just cannot be used *and* ignored.
        var config = MorbConfig()
        config.sharedPaths = []
        config.kernelCmdline = "console=hvc0 rdinit=/init morb.share=custom:/Users/me"
        let plan = try config.sharePlan { _ in .ok }
        XCTAssertTrue(plan.shares.isEmpty)
        XCTAssertEqual(
            try config.resolvedKernelCmdline(for: .initramfs, shares: plan.shares),
            config.kernelCmdline)
    }

    func testCmdlineRoundTrip() {
        let shares = [
            MorbDirectoryShare(tag: "morbshare0", path: "/Users"),
            MorbDirectoryShare(tag: "morbshare1", path: "/Volumes/My Disk"),
            MorbDirectoryShare(tag: "morbshare2", path: "/private/tmp"),
        ]
        let cmdline = try! MorbShares.appendToCmdline(
            MorbConfig.initramfsKernelCmdline, shares: shares)
        XCTAssertEqual(MorbShares.parseCmdline(cmdline), shares)
    }

    func testReadOnlySharesRoundTrip() {
        let shares = [
            MorbDirectoryShare(tag: "morbshare0", path: "/Users"),
            MorbDirectoryShare(tag: "payload", path: "/private/tmp/payload", readOnly: true),
        ]
        let cmdline = try! MorbShares.appendToCmdline("console=hvc0", shares: shares)
        XCTAssertTrue(cmdline.hasSuffix(":ro"))
        XCTAssertEqual(MorbShares.parseCmdline(cmdline), shares)
    }

    func testAPathEndingInRoIsNotMistakenForAReadOnlyFlag() {
        // The suffix is `:ro`, and the encoder escapes every colon inside a path, so
        // a directory literally called "ro" cannot be confused for the marker.
        let shares = [MorbDirectoryShare(tag: "t", path: "/Users/me/ro")]
        let parsed = MorbShares.parseCmdline(MorbShares.cmdlineArguments(for: shares).joined())
        XCTAssertEqual(parsed, shares)
        XCTAssertFalse(parsed.first?.readOnly ?? true)
    }

    func testEncodingSurvivesEveryPathShapeWeExpect() {
        for path in [
            "/Users",
            "/private/tmp",
            "/Volumes/My Disk",
            "/Users/someone/proj (copy)",
            "/Users/someone/ünïcode",
            "/Users/someone/100% real",
            "/Volumes/a:b,c",
            "/Users/someone/quote\"and\\slash",
            "/Users/someone/tab\there",
        ] {
            let encoded = MorbShares.encode(path)
            XCTAssertFalse(
                encoded.contains(" "), "a space would split the kernel argument: \(encoded)")
            XCTAssertFalse(encoded.contains(":"), "a colon would look like a separator: \(encoded)")
            XCTAssertEqual(MorbShares.decode(encoded), path)

            let cmdline = "console=hvc0 morb.share=t0:\(encoded) quiet"
            XCTAssertEqual(
                MorbShares.parseCmdline(cmdline), [MorbDirectoryShare(tag: "t0", path: path)])
        }
    }

    func testOrdinaryPathsStayReadableInProcCmdline() {
        // Not cosmetic: the first debugging step is `cat /proc/cmdline`.
        XCTAssertEqual(MorbShares.encode("/Users"), "/Users")
        XCTAssertEqual(MorbShares.encode("/private/tmp"), "/private/tmp")
        XCTAssertEqual(MorbShares.encode("/Users/me/my-app_2.0"), "/Users/me/my-app_2.0")
    }

    func testMalformedCmdlineEntriesAreSkipped() {
        let cmdline = "morb.share=noseparator morb.share=:/Users morb.share=t:%ZZ "
            + "morb.share=t:relative morb.shared=/Users morb.share=good:/Users"
        XCTAssertEqual(
            MorbShares.parseCmdline(cmdline), [MorbDirectoryShare(tag: "good", path: "/Users")])
    }

    func testDecodeRejectsMalformedEscapes() {
        XCTAssertNil(MorbShares.decode("%"))
        XCTAssertNil(MorbShares.decode("%4"))
        XCTAssertNil(MorbShares.decode("%ZZ"))
        XCTAssertNil(MorbShares.decode("%FF"))  // not valid UTF-8 on its own
    }

    // MARK: - Guest report

    func testGuestShareReportRoundTrips() {
        let states: [String: MorbShares.GuestMountState] = [
            "/Users": .mounted,
            "/Volumes/a,b": .failed,
        ]
        let encoded = MorbShares.encodeGuestShares(states)
        XCTAssertEqual(MorbShares.parseGuestShares(encoded), states)
    }

    func testGuestShareReportMatchesTheGuestsWireForm() {
        // The exact string `shares::encode_report` produces for the same input; the
        // guest suite asserts the other half of this pair.
        XCTAssertEqual(
            MorbShares.parseGuestShares("/Users:mounted,/Volumes/a%2Cb:failed"),
            ["/Users": .mounted, "/Volumes/a,b": .failed])
    }

    func testAnEmptyGuestReportDecodesToNothing() {
        XCTAssertTrue(MorbShares.parseGuestShares("").isEmpty)
        XCTAssertEqual(MorbShares.encodeGuestShares([:]), "")
    }

    func testAnUnknownGuestStateIsDroppedNotFatal() {
        // A newer guest inventing a third state must not cost us the two we know.
        XCTAssertEqual(
            MorbShares.parseGuestShares("/Users:mounted,/Volumes:pending"),
            ["/Users": .mounted])
    }

    func testGuestReplyCarriesTheSharesField() throws {
        let json = #"{"type":"info","docker_ready":true,"shares":"/Users:mounted"}"#
        let reply = try JSONDecoder().decode(GuestReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.shares, "/Users:mounted")
        XCTAssertEqual(MorbShares.parseGuestShares(reply.shares ?? ""), ["/Users": .mounted])
    }

    func testAGuestTooOldToReportSharesIsNotAnError() throws {
        let json = #"{"type":"info","docker_ready":true}"#
        let reply = try JSONDecoder().decode(GuestReply.self, from: Data(json.utf8))
        XCTAssertNil(reply.shares)
    }

    // MARK: - Doctor

    func testDoctorReportsEachConfiguredShare() {
        var config = MorbConfig()
        config.sharedPaths = ["/Users", "/private/tmp"]
        let report = Doctor.run(config: config)
        XCTAssertTrue(report.checks.contains { $0.name == "shares" })
        XCTAssertTrue(report.checks.contains { $0.name == "share /Users" })
        XCTAssertTrue(report.checks.contains { $0.name == "share /private/tmp" })
        // Sharing nothing is a warning, never a failure: the engine still runs.
        XCTAssertTrue(report.checks.first { $0.name == "shares" }?.status != .fail)
    }

    func testDoctorWarnsWhenSharingIsTurnedOff() {
        var config = MorbConfig()
        config.sharedPaths = []
        let report = Doctor.run(config: config)
        XCTAssertEqual(report.checks.first { $0.name == "shares" }?.status, .warn)
        XCTAssertTrue(report.healthy, "an empty shared_paths must not fail the report")
    }

    func testDoctorShowsTheShareArgumentsOnTheBootCmdline() {
        var config = MorbConfig()
        config.sharedPaths = ["/Users"]
        let report = Doctor.run(config: config)
        let cmdline = report.checks.first { $0.name == "boot-cmdline" }?.detail ?? ""
        XCTAssertTrue(cmdline.contains("morb.share=morbshare0:/Users"), cmdline)
    }
}
