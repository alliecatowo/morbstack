// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Mount classification, and the one warning the Mounts table exists to produce.
//
// The behaviour worth defending here is negative: a bind mount pointing outside every
// shared root must be flagged, and *nothing else* must be. A false positive on this
// warning is expensive — it tells somebody their working setup is broken — so most of
// these tests are about the cases that must stay silent.

import Foundation
import MorbstackKit
import XCTest

@testable import MorbstackAppCore

final class TrackBMountModelTests: XCTestCase {

    // MARK: - Fixtures

    private func mount(
        kind: String,
        source: String = "",
        destination: String = "/app",
        name: String? = nil,
        readOnly: Bool = false
    ) -> TrackBInspectDetails.Mount {
        TrackBInspectDetails.Mount(
            id: destination,
            kind: kind,
            name: name,
            source: source,
            destination: destination,
            readOnly: readOnly)
    }

    private func share(
        _ path: String,
        mounted: Bool = true,
        readOnly: Bool = false,
        error: String? = nil
    ) -> MorbShareState {
        MorbShareState(
            path: path,
            tag: "morbshare0",
            readOnly: readOnly,
            configured: true,
            mounted: mounted,
            error: error)
    }

    // MARK: - Kind classification

    func testRecognisesTheThreeCommonKinds() {
        XCTAssertEqual(TrackBMountKind(rawKind: "bind"), .bind)
        XCTAssertEqual(TrackBMountKind(rawKind: "volume"), .volume)
        XCTAssertEqual(TrackBMountKind(rawKind: "tmpfs"), .tmpfs)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(TrackBMountKind(rawKind: "Bind"), .bind)
        XCTAssertEqual(TrackBMountKind(rawKind: "VOLUME"), .volume)
    }

    /// The old rendering defaulted an unknown type to `bind`. That is the one wrong
    /// answer available: `bind` is the only kind that offers a Finder button and the only
    /// one whose source is treated as a host path.
    func testUnknownKindIsNotCoercedToBind() {
        XCTAssertEqual(TrackBMountKind(rawKind: "something-new"), .unknown)
        XCTAssertEqual(TrackBMountKind(rawKind: ""), .unknown)
        XCTAssertFalse(TrackBMountKind.unknown.sourceIsHostPath)
    }

    func testOnlyBindMountsClaimAHostPath() {
        XCTAssertTrue(TrackBMountKind.bind.sourceIsHostPath)
        for kind in TrackBMountKind.allCases where kind != .bind {
            XCTAssertFalse(kind.sourceIsHostPath, "\(kind) must not claim a host path")
        }
    }

    /// An unrecognised type still shows the engine's own word, so it can be looked up.
    func testUnknownKindKeepsTheEnginesWordAsItsLabel() {
        let row = TrackBMountModel.row(
            for: mount(kind: "cluster-of-the-future", source: "x"),
            shares: [],
            sharesAreKnown: true)
        XCTAssertEqual(row.kind, .unknown)
        XCTAssertEqual(row.kindLabel, "cluster-of-the-future")
    }

    // MARK: - Path containment

    func testPathIsWithinItsOwnRoot() {
        XCTAssertTrue(TrackBMountModel.path("/Users/al", isWithin: "/Users/al"))
    }

    func testPathIsWithinAnAncestor() {
        XCTAssertTrue(TrackBMountModel.path("/Users/al/proj/src", isWithin: "/Users/al"))
    }

    /// The bug every naive `hasPrefix` has. `/Users/al/Dev` is not inside `/Users/al/De`,
    /// and treating it as though it were would report a genuinely broken mount as fine.
    func testContainmentComparesWholePathComponents() {
        XCTAssertFalse(TrackBMountModel.path("/Users/al/Development", isWithin: "/Users/al/Dev"))
        XCTAssertFalse(TrackBMountModel.path("/Usersfoo", isWithin: "/Users"))
    }

    func testEverythingIsWithinRoot() {
        XCTAssertTrue(TrackBMountModel.path("/Users/al", isWithin: "/"))
    }

    func testTrailingSlashesDoNotChangeContainment() {
        XCTAssertTrue(TrackBMountModel.path("/Users/al/", isWithin: "/Users/"))
    }

    func testEmptyPathsAreNeverContained() {
        XCTAssertFalse(TrackBMountModel.path("", isWithin: "/Users"))
        XCTAssertFalse(TrackBMountModel.path("/Users", isWithin: ""))
    }

    /// With nested shares the more specific one governs — it is the one whose read-only
    /// flag and mount state actually apply.
    func testCoveringSharePrefersTheMostSpecificRoot() {
        let shares = [share("/Users"), share("/Users/al/work", readOnly: true)]
        let covering = TrackBMountModel.coveringShare(for: "/Users/al/work/api", in: shares)
        XCTAssertEqual(covering?.path, "/Users/al/work")
    }

    func testCoveringShareIsNilOutsideEveryRoot() {
        XCTAssertNil(TrackBMountModel.coveringShare(for: "/opt/data", in: [share("/Users")]))
    }

    // MARK: - Bind mounts

    func testSharedBindMountIsCleanAndRevealable() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Users/al/proj"),
            shares: [share("/Users")],
            sharesAreKnown: true)

        XCTAssertEqual(row.kind, .bind)
        XCTAssertEqual(row.source, "/Users/al/proj")
        XCTAssertEqual(row.hostPath, "/Users/al/proj")
        XCTAssertEqual(row.isShared, true)
        XCTAssertNil(row.warning)
    }

    /// The failure this whole file exists for: Docker reports no error, the container
    /// starts, and the directory is empty.
    func testUnsharedBindMountIsWarnedAbout() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/opt/secret"),
            shares: [share("/Users")],
            sharesAreKnown: true)

        XCTAssertEqual(row.isShared, false)
        let warning = try? XCTUnwrap(row.warning)
        XCTAssertNotNil(warning)
        XCTAssertTrue(row.warning?.contains("/opt/secret") ?? false)
    }

    /// An app that has not heard from the daemon cannot tell an unshared path from a
    /// share list it does not have. It must say nothing rather than guess.
    func testNoWarningWhenTheShareListIsUnknown() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/opt/secret"),
            shares: [],
            sharesAreKnown: false)

        XCTAssertNil(row.isShared, "unknown must not collapse to `false`")
        XCTAssertNil(row.warning)
        // Still revealable: the folder exists on the Mac whatever the VM thinks.
        XCTAssertEqual(row.hostPath, "/opt/secret")
    }

    /// A read-write mount under a read-only share fails on the first write, at runtime,
    /// with a permission error that names neither the share nor this setting.
    func testReadWriteMountUnderAReadOnlyShareIsWarnedAbout() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Users/al/proj", readOnly: false),
            shares: [share("/Users", readOnly: true)],
            sharesAreKnown: true)

        XCTAssertEqual(row.isShared, true)
        XCTAssertTrue(row.warning?.contains("read-only") ?? false)
    }

    func testReadOnlyMountUnderAReadOnlyShareIsFine() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Users/al/proj", readOnly: true),
            shares: [share("/Users", readOnly: true)],
            sharesAreKnown: true)
        XCTAssertNil(row.warning)
    }

    /// Configured but unmounted: the path is covered on paper and empty in practice.
    func testBindMountUnderAnUnmountedShareIsWarnedAbout() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Volumes/ext/data"),
            shares: [share("/Volumes", mounted: false)],
            sharesAreKnown: true)

        XCTAssertTrue(row.warning?.contains("not mounted") ?? false)
    }

    func testBindMountWithNoSourceIsWarnedAbout() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: ""),
            shares: [share("/Users")],
            sharesAreKnown: true)

        XCTAssertNil(row.hostPath)
        XCTAssertEqual(row.source, "—")
        XCTAssertNotNil(row.warning)
    }

    func testBindMountSourceIsNormalised() {
        let row = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Users/al/proj/"),
            shares: [share("/Users")],
            sharesAreKnown: true)
        XCTAssertEqual(row.source, "/Users/al/proj")
    }

    // MARK: - Volumes and tmpfs

    /// A volume's `Source` is a path inside the VM's disk image. Offering to reveal it
    /// would open Finder on nothing and imply the directory is somewhere reachable.
    func testVolumeShowsItsNameAndOffersNoFinderPath() {
        let row = TrackBMountModel.row(
            for: mount(
                kind: "volume",
                source: "/var/lib/docker/volumes/pgdata/_data",
                destination: "/var/lib/postgresql/data",
                name: "pgdata"),
            shares: [share("/Users")],
            sharesAreKnown: true)

        XCTAssertEqual(row.kind, .volume)
        XCTAssertEqual(row.source, "pgdata")
        XCTAssertNil(row.hostPath)
        XCTAssertNil(row.isShared)
        XCTAssertNil(row.warning)
    }

    func testAnonymousVolumeFallsBackToItsMountpoint() {
        let row = TrackBMountModel.row(
            for: mount(kind: "volume", source: "/var/lib/docker/volumes/abc123/_data"),
            shares: [],
            sharesAreKnown: true)
        XCTAssertEqual(row.source, "/var/lib/docker/volumes/abc123/_data")
        XCTAssertNil(row.hostPath)
    }

    func testTmpfsHasNoSourceAndNoFinderPath() {
        let row = TrackBMountModel.row(
            for: mount(kind: "tmpfs", destination: "/tmp"),
            shares: [],
            sharesAreKnown: true)

        XCTAssertEqual(row.kind, .tmpfs)
        XCTAssertEqual(row.source, "—")
        XCTAssertNil(row.hostPath)
        XCTAssertNil(row.warning)
    }

    /// Only bind mounts are ever judged against the share list; a volume outside every
    /// shared root is entirely normal and must not be flagged.
    func testNonBindKindsAreNeverWarnedAbout() {
        for kind in ["volume", "tmpfs", "npipe", "cluster", "image", "who-knows"] {
            let row = TrackBMountModel.row(
                for: mount(kind: kind, source: "/definitely/not/shared"),
                shares: [share("/Users")],
                sharesAreKnown: true)
            XCTAssertNil(row.warning, "\(kind) must not be warned about")
            XCTAssertNil(row.isShared, "\(kind) has no sharing verdict")
        }
    }

    // MARK: - Rows

    func testRowsPreserveOrderAndCollectWarnings() {
        let rows = TrackBMountModel.rows(
            mounts: [
                mount(kind: "bind", source: "/Users/al/a", destination: "/a"),
                mount(kind: "bind", source: "/opt/b", destination: "/b"),
                mount(kind: "volume", destination: "/c", name: "vol"),
            ],
            shares: [share("/Users")],
            sharesAreKnown: true)

        XCTAssertEqual(rows.map(\.destination), ["/a", "/b", "/c"])
        XCTAssertEqual(TrackBMountModel.warnings(rows).map(\.destination), ["/b"])
    }

    func testAccessDescriptionMatchesTheMountOption() {
        let readOnly = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Users/al/x", readOnly: true),
            shares: [share("/Users")], sharesAreKnown: true)
        XCTAssertEqual(readOnly.accessDescription, "read-only")

        let readWrite = TrackBMountModel.row(
            for: mount(kind: "bind", source: "/Users/al/x"),
            shares: [share("/Users")], sharesAreKnown: true)
        XCTAssertEqual(readWrite.accessDescription, "read-write")
    }

    // MARK: - Finder fallback

    /// `activateFileViewerSelecting` on a missing path does nothing at all — no window,
    /// no error — which reads as a dead button. A bind mount whose source was renamed is
    /// a completely ordinary thing to be looking at, and often the reason for looking.
    func testNearestExistingAncestorWalksUpToARealDirectory() {
        let ancestor = TrackBFinder.nearestExistingAncestor(
            of: "/private/tmp/definitely-not-here-\(UUID().uuidString)/deeper/still")
        XCTAssertEqual(ancestor, "/private/tmp")
    }

    func testNearestExistingAncestorBottomsOutAtRoot() {
        let ancestor = TrackBFinder.nearestExistingAncestor(
            of: "/nope-\(UUID().uuidString)/child")
        XCTAssertEqual(ancestor, "/")
    }
}
