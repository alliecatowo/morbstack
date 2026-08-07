// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackAppCore
import MorbstackKit

/// Coverage for the Disk screen's arithmetic: storage attribution, growth-action
/// selection, prune classification, and the sparse-file footprint.
///
/// These are the facts a screenshot cannot check. A table can look native while still
/// attributing 3 GB of images to build cache or offering an unsafe disk action.
final class TrackCDiskMathTests: XCTestCase {

    // MARK: - Fixtures

    private func image(
        id: String = "sha256:abc123def4567890",
        tags: [String] = ["nginx:latest"],
        size: Int64 = 1_000,
        used: Int = 0,
        created: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ImageSummary {
        ImageSummary(id: id, repoTags: tags, size: size, createdAt: created, containersUsing: used)
    }

    private func container(
        id: String = "c1",
        state: String = "running",
        name: String = "web"
    ) -> ContainerSummary {
        ContainerSummary(
            id: id, names: [name], displayName: name, image: "nginx:latest",
            state: state, status: state == "running" ? "Up 2 minutes" : "Exited (0) 3 minutes ago",
            composeProject: nil, composeService: nil, ports: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func volume(
        name: String = "app_data",
        size: Int64? = 500,
        refCount: Int? = 0
    ) -> VolumeSummary {
        VolumeSummary(
            name: name, driver: "local", mountpoint: "/var/lib/docker/volumes/\(name)/_data",
            size: size, refCount: refCount)
    }

    private func capacity(_ state: MorbDiskCapacity.State) -> MorbDiskCapacity.Status {
        MorbDiskCapacity.Status(
            imagePath: "/tmp/disk.img",
            configuredGiB: 128,
            configuredBytes: 128 * MorbDiskCapacity.bytesPerGiB,
            currentBytes: 64 * MorbDiskCapacity.bytesPerGiB,
            state: state)
    }

    private func resizeDiagnostic(_ state: MorbDiskResize.State) -> MorbDiskResize.Diagnostic {
        MorbDiskResize.Diagnostic(
            state: state,
            guestCapability: state == .guestResizeUnavailable ? .unavailable : .ready,
            currentBytes: 64 * MorbDiskCapacity.bytesPerGiB,
            targetBytes: 128 * MorbDiskCapacity.bytesPerGiB,
            summary: "Fixture diagnostic")
    }

    /// 64 lowercase hex characters — the shape Docker gives an anonymous volume.
    private let anonymousName = String(repeating: "a1b2c3d4", count: 8)

    // MARK: - Segment attribution

    func testSegmentsCarryEachCategoryTotalInStableTableOrder() {
        let usage = DiskUsage(
            layersSize: 8_000, imagesTotal: 8_000, volumesTotal: 3_000,
            buildCacheTotal: 2_000, containersTotal: 1_000, reclaimable: 0)

        let segments = TrackCDiskMath.segments(usage: usage, containers: [], images: [], volumes: [])

        XCTAssertEqual(segments.map(\.category), [.images, .containers, .volumes, .buildCache])
        XCTAssertEqual(segments.map(\.bytes), [8_000, 1_000, 3_000, 2_000])
    }

    func testEngineImageReclaimableBecomesTheImagesReclaimableFigure() throws {
        let usage = DiskUsage(
            layersSize: 10_000, imagesTotal: 10_000, volumesTotal: 0,
            buildCacheTotal: 0, containersTotal: 0, reclaimable: 7_000,
            imagesReclaimable: 7_000)

        let segments = TrackCDiskMath.segments(usage: usage, containers: [], images: [], volumes: [])
        let imagesSegment = try XCTUnwrap(segments.first { $0.category == .images })

        XCTAssertEqual(imagesSegment.reclaimableBytes, 7_000)
        XCTAssertFalse(imagesSegment.isEstimate, "the figure uses Docker's own df accounting, so it is exact")
    }

    func testImagesReclaimableNeverExceedsTheCategoryTotal() throws {
        // Defensive clamp: whatever the engine-derived figure claims, the per-category
        // reclaimable value must never exceed the daemon-reported category total.
        let usage = DiskUsage(
            layersSize: 8_000, imagesTotal: 8_000, volumesTotal: 0,
            buildCacheTotal: 0, containersTotal: 0, reclaimable: 20_000,
            imagesReclaimable: 20_000)

        let segments = TrackCDiskMath.segments(usage: usage, containers: [], images: [], volumes: [])
        let imagesSegment = try XCTUnwrap(segments.first { $0.category == .images })

        XCTAssertEqual(imagesSegment.reclaimableBytes, 8_000)
    }

    func testUnusedVolumesWithNoReportedSizeContributeNothing() throws {
        let usage = DiskUsage(
            layersSize: 0, imagesTotal: 0, volumesTotal: 900,
            buildCacheTotal: 0, containersTotal: 0, reclaimable: 900)
        let volumes = [
            volume(name: "used", size: 400, refCount: 2),
            volume(name: "orphan", size: 500, refCount: 0),
            volume(name: "unknown", size: nil, refCount: 0),
        ]

        let segments = TrackCDiskMath.segments(usage: usage, containers: [], images: [], volumes: volumes)
        let volumesSegment = try XCTUnwrap(segments.first { $0.category == .volumes })

        XCTAssertEqual(volumesSegment.reclaimableBytes, 500)
    }

    // MARK: - Container reclaimable

    func testNoStoppedContainersReclaimNothingAndIsNotAGuess() {
        let result = TrackCDiskMath.containerReclaimable(
            total: 5_000, containers: [container(id: "a"), container(id: "b")])

        XCTAssertEqual(result.bytes, 0)
        XCTAssertFalse(result.isEstimate)
    }

    func testAllStoppedContainersReclaimTheWholeTotalExactly() {
        let result = TrackCDiskMath.containerReclaimable(
            total: 5_000,
            containers: [container(id: "a", state: "exited"), container(id: "b", state: "exited")])

        XCTAssertEqual(result.bytes, 5_000)
        XCTAssertFalse(result.isEstimate, "every container going means every byte goes; nothing is inferred")
    }

    func testAMixOfStatesProducesACountWeightedEstimate() {
        let result = TrackCDiskMath.containerReclaimable(
            total: 900,
            containers: [
                container(id: "a", state: "running"),
                container(id: "b", state: "exited"),
                container(id: "c", state: "exited"),
            ])

        XCTAssertEqual(result.bytes, 600)
        XCTAssertTrue(result.isEstimate, "writable-layer sizes are not on /containers/json")
    }

    func testEmptyContainerListReclaimsNothing() {
        let result = TrackCDiskMath.containerReclaimable(total: 5_000, containers: [])
        XCTAssertEqual(result.bytes, 0)
        XCTAssertFalse(result.isEstimate)
    }

    // MARK: - Build cache residual

    func testBuildCacheTakesWhateverTheEngineCountedThatTheOthersDidNot() throws {
        let usage = DiskUsage(
            layersSize: 1_000, imagesTotal: 1_000, volumesTotal: 1_000,
            buildCacheTotal: 4_000, containersTotal: 0, reclaimable: 3_500,
            imagesReclaimable: 1_000)
        let volumes = [volume(name: "orphan", size: 1_000, refCount: 0)]  // 1_000 reclaimable

        let segments = TrackCDiskMath.segments(usage: usage, containers: [], images: [], volumes: volumes)
        let cache = try XCTUnwrap(segments.first { $0.category == .buildCache })

        XCTAssertEqual(cache.reclaimableBytes, 1_500)
        XCTAssertTrue(cache.isEstimate)
    }

    func testBuildCacheResidualIsClampedWhenOurFiguresOvershootTheEngines() throws {
        let usage = DiskUsage(
            layersSize: 5_000, imagesTotal: 5_000, volumesTotal: 0,
            buildCacheTotal: 1_000, containersTotal: 0, reclaimable: 1_000,
            imagesReclaimable: 5_000)

        let segments = TrackCDiskMath.segments(usage: usage, containers: [], images: [], volumes: [])
        let cache = try XCTUnwrap(segments.first { $0.category == .buildCache })

        XCTAssertEqual(cache.reclaimableBytes, 0, "a negative residual must not become negative storage")
        XCTAssertFalse(cache.isEstimate)
    }

    func testReclaimableNeverExceedsItsOwnSegment() {
        // Property-ish sweep across a spread of shapes: whatever the inputs, no
        // reclaimable attribution can exceed the category it describes.
        for imagesTotal in [Int64(0), 1_000, 50_000] {
            for reclaimable in [Int64(0), 10_000, 1_000_000] {
                let usage = DiskUsage(
                    layersSize: imagesTotal, imagesTotal: imagesTotal, volumesTotal: 2_000,
                    buildCacheTotal: 3_000, containersTotal: 4_000, reclaimable: reclaimable,
                    imagesReclaimable: reclaimable)
                let segments = TrackCDiskMath.segments(
                    usage: usage,
                    containers: [container(id: "a", state: "exited")],
                    images: [image(id: "sha256:aa", tags: [], size: 999_999)],
                    volumes: [volume(name: "orphan", size: 999_999, refCount: 0)])

                for segment in segments {
                    XCTAssertLessThanOrEqual(
                        segment.reclaimableBytes, segment.bytes,
                        "\(segment.category) overflowed at imagesTotal=\(imagesTotal) reclaimable=\(reclaimable)")
                    XCTAssertGreaterThanOrEqual(segment.reclaimableBytes, 0)
                }
            }
        }
    }

    // MARK: - Disk growth action

    func testMissingCapacityOnlyOffersAReadOnlyRefresh() {
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: nil,
                diagnostic: nil,
                hasRecoveryJournal: false,
                engineIsRunning: false),
            .refreshReadiness)
    }

    func testAConfiguredIncreaseStopsTheEngineBeforeAnyGrowthReview() {
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: capacity(.increaseRequiresGuestResize),
                diagnostic: resizeDiagnostic(.readyForExplicitTransaction),
                hasRecoveryJournal: false,
                engineIsRunning: true),
            .stopEngine)
    }

    /// The exact pass-2 scenario TASTE-10 fixed: the engine can be running and
    /// needing a guest resize before Morbstack ever gets a readiness diagnostic back
    /// from it. The action must still be `.stopEngine` with `diagnostic: nil`, or the
    /// view has no pure signal to tell it the "has not checked yet" sentence would be
    /// lying about what the Stop Engine button underneath it does.
    func testAConfiguredIncreaseWithNoDiagnosticYetStillOffersStopEngine() {
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: capacity(.increaseRequiresGuestResize),
                diagnostic: nil,
                hasRecoveryJournal: false,
                engineIsRunning: true),
            .stopEngine)
    }

    func testAStoppedGuestWithNoPriorReportCanOnlyReachReviewedGrowth() {
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: capacity(.increaseRequiresGuestResize),
                diagnostic: resizeDiagnostic(.guestCapabilityUnknown),
                hasRecoveryJournal: false,
                engineIsRunning: false),
            .reviewGrowth)
    }

    func testGuestResizeUnavailableOffersNoGrowthAction() {
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: capacity(.increaseRequiresGuestResize),
                diagnostic: resizeDiagnostic(.guestResizeUnavailable),
                hasRecoveryJournal: false,
                engineIsRunning: false),
            .none)
    }

    func testRecoveryAlwaysUsesTheSavedTargetReviewAfterTheEngineStops() {
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: capacity(.matchesConfiguration),
                diagnostic: resizeDiagnostic(.recoveryRequired),
                hasRecoveryJournal: true,
                engineIsRunning: true),
            .stopEngine)
        XCTAssertEqual(
            TrackCDiskGrowthPresentation.action(
                capacity: capacity(.matchesConfiguration),
                diagnostic: resizeDiagnostic(.recoveryRequired),
                hasRecoveryJournal: true,
                engineIsRunning: false),
            .reviewRecovery)
    }

    // MARK: - Capacity row/summary collapse (TASTE-10)

    func testConfiguredCapacityRowIsHiddenWhenItMatchesCurrent() {
        XCTAssertFalse(
            TrackCDiskGrowthPresentation.showsConfiguredCapacityRow(
                currentBytes: 128 * MorbDiskCapacity.bytesPerGiB,
                configuredBytes: 128 * MorbDiskCapacity.bytesPerGiB))
    }

    func testConfiguredCapacityRowShowsWhenItDiffersFromCurrent() {
        XCTAssertTrue(
            TrackCDiskGrowthPresentation.showsConfiguredCapacityRow(
                currentBytes: 64 * MorbDiskCapacity.bytesPerGiB,
                configuredBytes: 128 * MorbDiskCapacity.bytesPerGiB))
    }

    /// No existing image means there is nothing to compare the configured figure
    /// against, so it is the only number on screen and always shows.
    func testConfiguredCapacityRowShowsWhenThereIsNoCurrentImage() {
        XCTAssertTrue(
            TrackCDiskGrowthPresentation.showsConfiguredCapacityRow(
                currentBytes: nil,
                configuredBytes: 128 * MorbDiskCapacity.bytesPerGiB))
    }

    func testCapacitySummaryIsSuppressedOnlyWhenItMatchesConfiguration() {
        XCTAssertFalse(TrackCDiskGrowthPresentation.showsCapacitySummary(for: .matchesConfiguration))
        for state: MorbDiskCapacity.State in [
            .willCreate, .increaseRequiresGuestResize, .decreaseUnsupported, .unavailable,
        ] {
            XCTAssertTrue(
                TrackCDiskGrowthPresentation.showsCapacitySummary(for: state),
                "\(state) should still show its summary")
        }
    }

    // MARK: - Anonymous volume names

    func testAnonymousVolumeNamesAreExactlySixtyFourLowercaseHexCharacters() {
        XCTAssertTrue(TrackCDiskMath.isAnonymousVolumeName(anonymousName))
        XCTAssertFalse(TrackCDiskMath.isAnonymousVolumeName(String(anonymousName.dropLast())))
        XCTAssertFalse(TrackCDiskMath.isAnonymousVolumeName(anonymousName.uppercased()))
        XCTAssertFalse(TrackCDiskMath.isAnonymousVolumeName("postgres_data"))
        XCTAssertFalse(TrackCDiskMath.isAnonymousVolumeName(""))
        // 64 characters, but `g` is not hex.
        XCTAssertFalse(TrackCDiskMath.isAnonymousVolumeName(String(repeating: "g", count: 64)))
    }

    // MARK: - Prune previews

    func testContainerPruneSparesRunningPausedAndRestartingContainers() {
        let containers = [
            container(id: "a", state: "running", name: "web"),
            container(id: "b", state: "paused", name: "worker"),
            container(id: "c", state: "restarting", name: "flaky"),
            container(id: "d", state: "exited", name: "migrate"),
            container(id: "e", state: "created", name: "never-ran"),
            container(id: "f", state: "dead", name: "gone"),
        ]

        let preview = TrackCDiskMath.prunePreview(
            target: .containers, usage: nil, containers: containers, images: [], volumes: [])

        XCTAssertEqual(Set(preview.items.map(\.id)), ["d", "e", "f"])
        XCTAssertTrue(preview.hasUnknownSizes, "writable-layer sizes are not available up front")
        XCTAssertEqual(preview.knownBytes, 0)
    }

    func testContainerPruneOnAnAllRunningHostPreviewsNothing() {
        let preview = TrackCDiskMath.prunePreview(
            target: .containers, usage: nil,
            containers: [container(id: "a"), container(id: "b")], images: [], volumes: [])

        XCTAssertTrue(preview.isEmpty)
        XCTAssertFalse(preview.hasUnknownSizes, "an empty preview has no unknowns to warn about")
    }

    func testImagePruneListsDanglingLayersLargestFirstAndSumsTheirSizes() {
        let images = [
            image(id: "sha256:tagged", tags: ["nginx:latest"], size: 9_000),
            image(id: "sha256:small", tags: [], size: 100),
            image(id: "sha256:big", tags: ["<none>:<none>"], size: 5_000),
        ]

        let preview = TrackCDiskMath.prunePreview(
            target: .images, usage: nil, containers: [], images: images, volumes: [])

        XCTAssertEqual(preview.items.map(\.id), ["sha256:big", "sha256:small"])
        XCTAssertEqual(preview.knownBytes, 5_100)
        XCTAssertFalse(preview.hasUnknownSizes)
    }

    func testADanglingLayerStillHeldByAContainerIsListedAsKeptRatherThanRemoved() {
        let images = [
            image(id: "sha256:held", tags: [], size: 2_000, used: 1),
            image(id: "sha256:free", tags: [], size: 1_000, used: 0),
        ]

        let preview = TrackCDiskMath.prunePreview(
            target: .images, usage: nil, containers: [], images: images, volumes: [])

        XCTAssertEqual(preview.items.map(\.id), ["sha256:free"])
        XCTAssertEqual(preview.kept.map(\.id), ["sha256:held"])
        XCTAssertEqual(preview.knownBytes, 1_000, "kept bytes must not be promised as freed")
    }

    func testVolumePruneRemovesAnonymousVolumesAndSpellsOutTheNamedOnesItKeeps() {
        let volumes = [
            volume(name: anonymousName, size: 700, refCount: 0),
            volume(name: "postgres_data", size: 4_000, refCount: 0),
            volume(name: "in_use", size: 100, refCount: 3),
        ]

        let preview = TrackCDiskMath.prunePreview(
            target: .volumes, usage: nil, containers: [], images: [], volumes: volumes)

        XCTAssertEqual(preview.items.map(\.id), [anonymousName])
        XCTAssertEqual(preview.kept.map(\.id), ["postgres_data"])
        XCTAssertEqual(preview.knownBytes, 700)
        XCTAssertFalse(
            preview.items.contains { $0.id == "in_use" },
            "an attached volume is not a prune candidate at all")
    }

    func testVolumePruneFlagsUnknownSizes() {
        let preview = TrackCDiskMath.prunePreview(
            target: .volumes, usage: nil, containers: [], images: [],
            volumes: [volume(name: anonymousName, size: nil, refCount: 0)])

        XCTAssertEqual(preview.items.count, 1)
        XCTAssertTrue(preview.hasUnknownSizes)
        XCTAssertEqual(preview.knownBytes, 0)
    }

    func testPruneTargetsOnlyIncludeResourcesWithReviewableCandidates() {
        XCTAssertEqual(
            TrackCPruneTarget.allCases.map(\.rawValue),
            ["containers", "images", "volumes"])
    }

    func testCountLabelReadsAsEnglish() {
        let one = TrackCPrunePreview(
            target: .images,
            items: [TrackCPruneItem(id: "a", title: "a", detail: "", bytes: nil)],
            kept: [], knownBytes: 0, hasUnknownSizes: false)
        XCTAssertEqual(one.countLabel, "1 item")

        let many = TrackCPrunePreview(
            target: .images,
            items: [
                TrackCPruneItem(id: "a", title: "a", detail: "", bytes: nil),
                TrackCPruneItem(id: "b", title: "b", detail: "", bytes: nil),
            ],
            kept: [], knownBytes: 0, hasUnknownSizes: false)
        XCTAssertEqual(many.countLabel, "2 items")
    }

    // MARK: - Sparse footprint

    func testFootprintConvertsBlocksToBytesAtFiveTwelve() {
        let result = TrackCDiskMath.footprint(path: "/tmp/disk.img", apparentBytes: 1_024, blocks512: 2)
        XCTAssertEqual(result.actualBytes, 1_024)
        XCTAssertEqual(result.apparentBytes, 1_024)
        XCTAssertEqual(result.savedBytes, 0)
        XCTAssertFalse(result.isSparse)
    }

    func testAMostlyEmptySixtyFourGigabyteImageReportsItsRealCost() {
        let apparent: Int64 = 64 * 1_000_000_000
        let actual: Int64 = 3 * 1_000_000_000
        let result = TrackCDiskMath.footprint(
            path: "/tmp/disk.img", apparentBytes: apparent, blocks512: actual / 512)

        XCTAssertEqual(result.actualBytes, actual)
        XCTAssertEqual(result.savedBytes, apparent - actual)
        XCTAssertEqual(result.occupancy, 0.046875, accuracy: 0.0001)
        XCTAssertTrue(result.isSparse)
    }

    func testANearlyFullImageIsNotAdvertisedAsSparse() {
        // 99 of 100 blocks allocated: technically sparse by one block, but captioning
        // that as a space-saving trick would be silly, so `isSparse` says no.
        let result = TrackCDiskMath.footprint(
            path: "/tmp/disk.img", apparentBytes: 100 * 512, blocks512: 99)

        XCTAssertEqual(result.occupancy, 0.99, accuracy: 0.0001)
        XCTAssertEqual(result.savedBytes, 512)
        XCTAssertFalse(result.isSparse)
    }

    func testAZeroLengthFileDoesNotDivideByZero() {
        let result = TrackCDiskMath.footprint(path: "/tmp/empty", apparentBytes: 0, blocks512: 0)
        XCTAssertEqual(result.occupancy, 1)
        XCTAssertEqual(result.savedBytes, 0)
        XCTAssertFalse(result.isSparse)
    }

    func testNegativeStatValuesAreFloored() {
        let result = TrackCDiskMath.footprint(path: "/tmp/x", apparentBytes: -1, blocks512: -8)
        XCTAssertEqual(result.apparentBytes, 0)
        XCTAssertEqual(result.actualBytes, 0)
    }

    func testReadingAMissingPathReturnsNil() {
        XCTAssertNil(TrackCDiskMath.readFootprint(path: "/nonexistent/morbstack/disk.img"))
    }

    func testReadingARealFileReportsBothFigures() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trackc-footprint-\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 4_096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try XCTUnwrap(TrackCDiskMath.readFootprint(path: url.path))
        XCTAssertEqual(result.apparentBytes, 4_096)
        XCTAssertGreaterThan(result.actualBytes, 0, "a written file must have allocated blocks")
        XCTAssertEqual(result.path, url.path)
    }

    // MARK: - Disk reclaim presentation (TECH-3 / UX-16)

    func testReclaimSentenceNamesNoSweepYetRatherThanAnInternalSentinel() {
        let sentence = TrackCDiskReclaimPresentation.reclaimSentence(lastTrimBytes: nil)
        XCTAssertTrue(sentence.contains("No sweep has completed yet"))
        // The guest's own sentinel is -1; a reader has no use for that number and it
        // must never leak into the sentence.
        XCTAssertFalse(sentence.contains("-1"))
    }

    func testReclaimSentenceReportsAZeroByteSweepAsARealResultNotAMissingOne() {
        // Zero is a legitimate "nothing to reclaim this sweep" answer, distinct from
        // "no sweep has run at all" — see `disk::NO_TRIM_YET` on the guest side.
        let sentence = TrackCDiskReclaimPresentation.reclaimSentence(lastTrimBytes: 0)
        XCTAssertTrue(sentence.contains("found nothing to reclaim"))
        XCTAssertFalse(sentence.contains("No sweep has completed"))
    }

    func testReclaimSentenceNamesTheRealByteCountOfARecentSweep() {
        let sentence = TrackCDiskReclaimPresentation.reclaimSentence(lastTrimBytes: 59_050_795_008)
        XCTAssertTrue(sentence.contains(Formatters.bytesString(59_050_795_008)))
        XCTAssertTrue(sentence.contains("returned"))
    }

    func testFootprintExplanationStatesTheSparseFactAndTheReclaimFactTogether() {
        let footprint = TrackCDiskMath.footprint(
            path: "/tmp/disk.img", apparentBytes: 64 * 1_000_000_000, blocks512: 3 * 1_000_000_000 / 512)
        let explanation = TrackCDiskReclaimPresentation.footprintExplanation(
            footprint: footprint, lastTrimBytes: 4_010_000_000)

        XCTAssertTrue(explanation.contains("reserves"), "the sparse-file fact must still be present")
        XCTAssertTrue(explanation.contains(Formatters.bytesString(4_010_000_000)))
    }

    func testFootprintExplanationOnAFullyAllocatedImageNoLongerClaimsSpaceIsStuck() {
        // Regression: the pre-reclaim wording ("remains allocated ... until the file
        // is trimmed or recreated") became false the moment the periodic sweep shipped
        // and must not survive as dead text a reader could act on incorrectly.
        let footprint = TrackCDiskMath.footprint(path: "/tmp/disk.img", apparentBytes: 100 * 512, blocks512: 99)
        let explanation = TrackCDiskReclaimPresentation.footprintExplanation(
            footprint: footprint, lastTrimBytes: nil)

        XCTAssertFalse(explanation.contains("until the file is trimmed or recreated"))
        XCTAssertTrue(explanation.contains("automatically"))
    }
}
