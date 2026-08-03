// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackAppCore

/// Coverage for the Images / Volumes / Networks list logic: what a search matches, what
/// order a column sorts in, which section a row lands in, and how the pull log collapses.
final class TrackCResourceListTests: XCTestCase {

    // MARK: - Fixtures

    private func image(
        id: String,
        tags: [String],
        size: Int64 = 1_000,
        used: Int = 0,
        ageSeconds: TimeInterval = 0
    ) -> ImageSummary {
        ImageSummary(
            id: id, repoTags: tags, size: size,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - ageSeconds),
            containersUsing: used)
    }

    private func volume(_ name: String, size: Int64? = nil, refCount: Int? = 0) -> VolumeSummary {
        VolumeSummary(
            name: name, driver: "local", mountpoint: "/var/lib/docker/volumes/\(name)/_data",
            size: size, refCount: refCount)
    }

    private func network(_ name: String, driver: String = "bridge", containers: Int = 0) -> NetworkSummary {
        NetworkSummary(id: "net-\(name)", name: name, driver: driver, scope: "local", containers: containers)
    }

    private let anonymousName = String(repeating: "0f1e2d3c", count: 8)

    // MARK: - Image search

    func testAnEmptyQueryMatchesEverything() {
        let subject = image(id: "sha256:aa", tags: ["nginx:latest"])
        XCTAssertTrue(TrackCImageList.matches(subject, query: ""))
        XCTAssertTrue(TrackCImageList.matches(subject, query: "   "))
    }

    func testSearchMatchesTagsShortIDsAndFullIDs() {
        let subject = image(id: "sha256:deadbeefcafe0123", tags: ["ghcr.io/acme/api:v2"])

        XCTAssertTrue(TrackCImageList.matches(subject, query: "acme"))
        XCTAssertTrue(TrackCImageList.matches(subject, query: "V2"), "search is case-insensitive")
        XCTAssertTrue(TrackCImageList.matches(subject, query: "deadbeef"))
        XCTAssertTrue(TrackCImageList.matches(subject, query: "sha256:deadbeefcafe0123"))
        XCTAssertFalse(TrackCImageList.matches(subject, query: "postgres"))
    }

    func testSearchMatchesAnyTagNotJustTheFirst() {
        let subject = image(id: "sha256:aa", tags: ["nginx:latest", "nginx:1.25"])
        XCTAssertTrue(TrackCImageList.matches(subject, query: "1.25"))
    }

    // MARK: - Image sorting

    func testSizeSortsAscendingAndDescending() {
        let images = [
            image(id: "sha256:a", tags: ["a:1"], size: 300),
            image(id: "sha256:b", tags: ["b:1"], size: 100),
            image(id: "sha256:c", tags: ["c:1"], size: 200),
        ]

        XCTAssertEqual(
            TrackCImageList.sorted(images, by: .size, ascending: true).map(\.size), [100, 200, 300])
        XCTAssertEqual(
            TrackCImageList.sorted(images, by: .size, ascending: false).map(\.size), [300, 200, 100])
    }

    func testRepositorySortIsNaturalNotLexicographic() {
        let images = [
            image(id: "sha256:a", tags: ["app10:latest"]),
            image(id: "sha256:b", tags: ["app9:latest"]),
            image(id: "sha256:c", tags: ["app2:latest"]),
        ]

        XCTAssertEqual(
            TrackCImageList.sorted(images, by: .repository, ascending: true).map(\.repository),
            ["app2", "app9", "app10"],
            "a plain string sort would put app10 before app2")
    }

    func testEqualSizesTieBreakOnRepositorySoTheTableDoesNotReshuffle() {
        let images = [
            image(id: "sha256:a", tags: ["zebra:1"], size: 500),
            image(id: "sha256:b", tags: ["alpha:1"], size: 500),
        ]

        XCTAssertEqual(
            TrackCImageList.sorted(images, by: .size, ascending: true).map(\.repository),
            ["alpha", "zebra"])
    }

    func testCreatedSortUsesTheTimestampNotTheString() {
        let images = [
            image(id: "sha256:old", tags: ["old:1"], ageSeconds: 90_000),
            image(id: "sha256:new", tags: ["new:1"], ageSeconds: 0),
        ]

        XCTAssertEqual(
            TrackCImageList.sorted(images, by: .created, ascending: false).map(\.repository),
            ["new", "old"])
    }

    // MARK: - Image sections

    func testDanglingLayersAreSplitOutAndOrderedLargestFirst() {
        let images = [
            image(id: "sha256:tagged", tags: ["nginx:latest"], size: 10),
            image(id: "sha256:d1", tags: [], size: 100),
            image(id: "sha256:d2", tags: ["<none>:<none>"], size: 900),
        ]

        let split = TrackCImageList.sections(
            images: images, query: "", sortKey: .repository, ascending: true)

        XCTAssertEqual(split.tagged.map(\.id), ["sha256:tagged"])
        XCTAssertEqual(
            split.dangling.map(\.id), ["sha256:d2", "sha256:d1"],
            "the dangling pile is ordered by what it costs, never alphabetically")
    }

    func testTheSearchFilterAppliesToBothSections() {
        let images = [
            image(id: "sha256:aaa111", tags: ["nginx:latest"]),
            image(id: "sha256:bbb222", tags: []),
        ]

        let split = TrackCImageList.sections(
            images: images, query: "bbb", sortKey: .repository, ascending: true)

        XCTAssertTrue(split.tagged.isEmpty)
        XCTAssertEqual(split.dangling.map(\.id), ["sha256:bbb222"])
    }

    func testTotalSizeIgnoresNegativeSizes() {
        let images = [
            image(id: "sha256:a", tags: ["a:1"], size: 400),
            image(id: "sha256:b", tags: ["b:1"], size: -100),
        ]
        XCTAssertEqual(TrackCImageList.totalSize(images), 400)
    }

    // MARK: - Pull log

    func testLayerKeyRecognisesALayerIDAndNothingElse() {
        XCTAssertEqual(TrackCPullLog.layerKey("a1b2c3d4e5f6: Downloading  4.2MB/91MB"), "a1b2c3d4e5f6")
        XCTAssertEqual(
            TrackCPullLog.layerKey(String(repeating: "ab", count: 32) + ": Pull complete"),
            String(repeating: "ab", count: 32),
            "some registries send the full 64-character digest as the id")

        XCTAssertNil(TrackCPullLog.layerKey("Pulling from library/nginx"))
        XCTAssertNil(
            TrackCPullLog.layerKey("Status: Downloaded newer image for nginx:latest"),
            "a status sentence is not a layer id, even though it contains a colon")
        XCTAssertNil(TrackCPullLog.layerKey("Digest: sha256:abcdef"))
        XCTAssertNil(
            TrackCPullLog.layerKey("latest: Pulling from library/nginx"),
            "the engine puts the tag in the id slot for this one line")
        XCTAssertNil(TrackCPullLog.layerKey("a1b2: too short to be a layer"))
        XCTAssertNil(TrackCPullLog.layerKey(": orphaned colon"))
    }

    func testConsecutiveUpdatesForOneLayerRewriteTheSameLine() {
        var lines: [String] = []
        lines = TrackCPullLog.appending("a1b2c3d4e5f6: Downloading  1MB/91MB", to: lines)
        lines = TrackCPullLog.appending("a1b2c3d4e5f6: Downloading  40MB/91MB", to: lines)
        lines = TrackCPullLog.appending("a1b2c3d4e5f6: Download complete", to: lines)

        XCTAssertEqual(lines, ["a1b2c3d4e5f6: Download complete"])
    }

    func testADifferentLayerStartsANewLine() {
        var lines: [String] = []
        lines = TrackCPullLog.appending("a1b2c3d4e5f6: Downloading  1MB/91MB", to: lines)
        lines = TrackCPullLog.appending("c3d4e5f6a1b2: Downloading  2MB/40MB", to: lines)
        lines = TrackCPullLog.appending("a1b2c3d4e5f6: Download complete", to: lines)

        XCTAssertEqual(
            lines,
            [
                "a1b2c3d4e5f6: Downloading  1MB/91MB",
                "c3d4e5f6a1b2: Downloading  2MB/40MB",
                "a1b2c3d4e5f6: Download complete",
            ],
            "collapsing only applies to the line immediately above, so interleaved layers all survive")
    }

    func testStatusLinesAreNeverCollapsedIntoEachOther() {
        // The bug this guards: `Status:` and `Digest:` both parse as a "prefix before a
        // colon", and a naive layer key would overwrite one with the other.
        var lines: [String] = []
        lines = TrackCPullLog.appending("Pulling from library/nginx", to: lines)
        lines = TrackCPullLog.appending("Pulling fs layer", to: lines)
        lines = TrackCPullLog.appending("Digest: sha256:aaaa", to: lines)
        lines = TrackCPullLog.appending("Status: Downloaded newer image for nginx:latest", to: lines)

        XCTAssertEqual(lines.count, 4)
    }

    func testBlankLinesAreDroppedAndWhitespaceIsTrimmed() {
        var lines = TrackCPullLog.appending("   ", to: [])
        XCTAssertTrue(lines.isEmpty)

        lines = TrackCPullLog.appending("  Pull complete\n", to: lines)
        XCTAssertEqual(lines, ["Pull complete"])
    }

    func testTheLogIsCappedAtTheLimitKeepingTheTail() {
        var lines: [String] = []
        for index in 0..<30 {
            lines = TrackCPullLog.appending("line \(index)", to: lines, limit: 10)
        }

        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.first, "line 20")
        XCTAssertEqual(lines.last, "line 29")
    }

    func testBatchAppendMatchesLineByLineAppend() {
        let batch = [
            "aaaabbbbcccc: Downloading 1MB",
            "aaaabbbbcccc: Downloading 2MB",
            "ddddeeeeffff: Waiting",
            "Status: Downloaded",
        ]

        let batched = TrackCPullLog.appending(contentsOf: batch, to: [])
        let oneByOne = batch.reduce([String]()) { TrackCPullLog.appending($1, to: $0) }

        XCTAssertEqual(batched, oneByOne)
        XCTAssertEqual(
            batched,
            ["aaaabbbbcccc: Downloading 2MB", "ddddeeeeffff: Waiting", "Status: Downloaded"])
    }

    // MARK: - Pull buffer

    func testDrainReturnsEverythingBufferedThenEmpties() {
        let buffer = TrackCPullBuffer()
        buffer.append("one")
        buffer.append("two")

        XCTAssertEqual(buffer.drain(), ["one", "two"])
        XCTAssertEqual(buffer.drain(), [], "a second drain must not replay the same lines")
    }

    func testTheBufferPreservesOrderUnderConcurrentAppends() {
        // The reason the buffer exists: `DockerClient.pull` calls its progress closure
        // from a reader thread while the UI drains on the main actor.
        let buffer = TrackCPullBuffer()
        let finished = expectation(description: "appends complete")
        finished.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for index in 0..<500 { buffer.append("a\(index)") }
            finished.fulfill()
        }
        DispatchQueue.global().async {
            for index in 0..<500 { buffer.append("b\(index)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        let drained = buffer.drain()
        XCTAssertEqual(drained.count, 1_000)
        XCTAssertEqual(drained.filter { $0.hasPrefix("a") }, (0..<500).map { "a\($0)" })
        XCTAssertEqual(drained.filter { $0.hasPrefix("b") }, (0..<500).map { "b\($0)" })
    }

    // MARK: - Volumes

    func testUnusedPlanTakesOnlyUnusedVolumesBiggestFirst() {
        let volumes = [
            volume("attached", size: 9_000, refCount: 1),
            volume("small_orphan", size: 100, refCount: 0),
            volume("big_orphan", size: 5_000, refCount: 0),
        ]

        let plan = TrackCVolumeList.unusedPlan(volumes)

        XCTAssertEqual(plan.items.map(\.id), ["big_orphan", "small_orphan"])
        XCTAssertEqual(plan.knownBytes, 5_100)
        XCTAssertFalse(plan.hasUnknownSizes)
    }

    func testUnusedPlanLabelsAnonymousAndNamedVolumesDifferently() {
        let plan = TrackCVolumeList.unusedPlan([volume(anonymousName, size: 1), volume("db_data", size: 2)])

        let byID = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.detail) })
        XCTAssertEqual(byID["db_data"], "named · local")
        XCTAssertEqual(byID[anonymousName], "anonymous · local")
    }

    func testUnusedPlanFlagsAnUnreportedSize() {
        let plan = TrackCVolumeList.unusedPlan([volume("mystery", size: nil)])

        XCTAssertTrue(plan.hasUnknownSizes)
        XCTAssertEqual(plan.knownBytes, 0)
        XCTAssertNil(plan.items.first?.bytes)
    }

    func testAVolumeWithAnUnreportedRefCountIsNeverOfferedForPruning() {
        // The Engine omits usage data unless it was asked for, so a nil refCount
        // means "unknown", not "zero". Offering an unknown-usage volume for deletion
        // would be offering to delete data that may well be in use — so it stays out
        // of the plan, and the row says "Usage unreported" rather than showing an
        // unused dot. The two must keep agreeing.
        let mystery = volume("no_usage_data", size: 10, refCount: nil)
        XCTAssertFalse(mystery.isUnused)
        XCTAssertEqual(mystery.usageStatus, "Usage unreported")
        XCTAssertEqual(TrackCVolumeList.unusedPlan([mystery]).items.map(\.id), [])
    }

    func testVolumeSearchCoversNameDriverAndMountpoint() {
        let subject = volume("postgres_data", size: 1)
        XCTAssertTrue(TrackCVolumeList.matches(subject, query: "POSTGRES"))
        XCTAssertTrue(TrackCVolumeList.matches(subject, query: "local"))
        XCTAssertTrue(TrackCVolumeList.matches(subject, query: "/var/lib/docker"))
        XCTAssertFalse(TrackCVolumeList.matches(subject, query: "redis"))
    }

    func testVolumesWithUnknownSizesSortAlongsideZero() {
        let volumes = [volume("known", size: 50), volume("unknown", size: nil)]

        XCTAssertEqual(
            TrackCVolumeList.sorted(volumes, by: .size, ascending: true).map(\.name),
            ["unknown", "known"])
    }

    // MARK: - Networks

    func testNetworkNameSortIncludesBuiltInAndUserDefinedRecords() {
        let networks = [
            network("none"),
            network("my_app_default", driver: "bridge", containers: 3),
            network("host", driver: "host"),
            network("bridge"),
        ]

        let visible = TrackCNetworkList.visible(
            networks: networks, query: "", sortKey: .name, ascending: true)

        XCTAssertEqual(
            visible.map(\.name),
            ["bridge", "host", "my_app_default", "none"])
    }

    func testNetworkKindSortIncludesBuiltInAndUserDefinedRecords() {
        let networks = [
            network("none"),
            network("app_default"),
            network("bridge"),
            network("host", driver: "host"),
        ]

        let visible = TrackCNetworkList.visible(
            networks: networks, query: "", sortKey: .kind, ascending: true)

        XCTAssertEqual(visible.map(\.name), ["bridge", "host", "none", "app_default"])
        XCTAssertEqual(
            visible.map(TrackCNetworkList.kindLabel(for:)),
            ["Built-in", "Built-in", "Built-in", "User-defined"])
    }

    func testUnusedNetworksNeverIncludeTheBuiltInsEvenWhenEmpty() {
        let networks = [
            network("bridge"),
            network("host", driver: "host"),
            network("none"),
            network("orphan_net"),
            network("busy_net", containers: 2),
        ]

        XCTAssertEqual(TrackCNetworkList.unused(networks).map(\.name), ["orphan_net"])
    }

    func testNetworkSortByContainerCountTieBreaksOnName() {
        let networks = [network("zeta", containers: 1), network("alpha", containers: 1)]

        XCTAssertEqual(
            TrackCNetworkList.sorted(networks, by: .containers, ascending: true).map(\.name),
            ["alpha", "zeta"])
    }

    func testNetworkSearchCoversNameDriverAndID() {
        let subject = network("my_app_default", driver: "bridge")
        XCTAssertTrue(TrackCNetworkList.matches(subject, query: "app"))
        XCTAssertTrue(TrackCNetworkList.matches(subject, query: "BRIDGE"))
        XCTAssertTrue(TrackCNetworkList.matches(subject, query: "net-my_app"))
        XCTAssertFalse(TrackCNetworkList.matches(subject, query: "overlay"))
    }
}
