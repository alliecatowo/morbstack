// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the Compose-aggregated log document's pure parts: the merge ordering,
// the per-service colour assignment, and the scope the store applies when a service is
// hidden.
//
// Ordering is the reason this file is long. A merged log that shows two services'
// output in the order the sockets happened to answer is not a cosmetic problem — it
// inverts cause and effect, and it does so most reliably in exactly the situation
// someone opens the view for. None of it is visible in a screenshot.

import XCTest

@testable import MorbstackAppCore

// MARK: - Merge ordering

final class ComposeLogMergeTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_772_000_000)

    private func source(_ name: String, index: Int = 0) -> TrackBLogSource {
        TrackBLogSource(containerID: "container-\(name)", service: name, colorIndex: index)
    }

    private func line(_ text: String, at offset: TimeInterval?, id: Int = 0) -> LogLine {
        LogLine(
            id: id,
            text: text,
            stream: .stdout,
            timestamp: offset.map { origin.addingTimeInterval($0) })
    }

    /// Registers both services and marks them ready, so a test that is not about
    /// priming does not have to wait out the prime deadline.
    private func primedMerge(
        _ sources: [TrackBLogSource],
        holdInterval: TimeInterval = 0.25
    ) -> ComposeLogMerge {
        var merge = ComposeLogMerge(holdInterval: holdInterval, primeTimeout: 2.0)
        for source in sources {
            merge.register(source, at: origin)
            merge.markReady(source.id)
        }
        return merge
    }

    /// The whole point: the daemon's timestamps decide the order, not the order the
    /// sockets answered in.
    func testTimestampOrderBeatsArrivalOrder() {
        let web = source("web")
        let api = source("api")
        var merge = primedMerge([web, api])

        merge.ingest(line("later", at: 10), from: web, at: origin)
        merge.ingest(line("earlier", at: 9), from: api, at: origin.addingTimeInterval(0.1))

        let released = merge.drain(now: origin.addingTimeInterval(0.4))
        XCTAssertEqual(released.map(\.line.text), ["earlier", "later"])
    }

    /// The subtle half of the same rule. Releasing every *ripe* line — the obvious
    /// implementation — would emit "later" while "earlier" was still in the hold
    /// window, and the transcript would be wrong with no way to tell.
    func testNothingIsReleasedAheadOfAnEarlierLineStillHeld() {
        let web = source("web")
        let api = source("api")
        var merge = primedMerge([web, api])

        merge.ingest(line("later", at: 10), from: web, at: origin)
        merge.ingest(line("earlier", at: 9), from: api, at: origin.addingTimeInterval(0.2))

        // "later" has ripened; "earlier" has not, and it sorts in front of it.
        XCTAssertEqual(merge.drain(now: origin.addingTimeInterval(0.3)).count, 0)
        XCTAssertEqual(merge.pendingCount, 2)

        let released = merge.drain(now: origin.addingTimeInterval(0.5))
        XCTAssertEqual(released.map(\.line.text), ["earlier", "later"])
    }

    /// The slow-stream case, which is the one that actually happens: every service
    /// answers `tail` with a burst of history, and one of them answers a second late.
    /// Without priming, the fast service's whole backlog would render first and the
    /// merged history would read as "all of web, then all of api".
    func testSlowServiceHistoryStillInterleaves() {
        let web = source("web")
        let api = source("api")
        var merge = ComposeLogMerge(holdInterval: 0.25, primeTimeout: 2.0)
        merge.register(web, at: origin)
        merge.register(api, at: origin)

        for (index, offset) in [1.0, 3.0, 5.0].enumerated() {
            merge.ingest(line("web-\(offset)", at: offset, id: index), from: web, at: origin)
        }
        // Nothing may be shown yet: api has not answered, and it holds the lines that
        // belong between web's.
        XCTAssertEqual(merge.drain(now: origin.addingTimeInterval(0.5)).count, 0)

        let apiArrival = origin.addingTimeInterval(1.0)
        for (index, offset) in [2.0, 4.0, 6.0].enumerated() {
            merge.ingest(line("api-\(offset)", at: offset, id: index), from: api, at: apiArrival)
        }

        let released = merge.drain(now: apiArrival.addingTimeInterval(0.3))
        XCTAssertEqual(
            released.map(\.line.text),
            ["web-1.0", "api-2.0", "web-3.0", "api-4.0", "web-5.0", "api-6.0"])
    }

    /// A service that never answers must not hold the document blank forever.
    func testPrimingGivesUpOnASilentService() {
        let web = source("web")
        let api = source("api")
        var merge = ComposeLogMerge(holdInterval: 0.25, primeTimeout: 2.0)
        merge.register(web, at: origin)
        merge.register(api, at: origin)
        merge.ingest(line("hello", at: 1), from: web, at: origin)

        XCTAssertTrue(merge.isPriming(at: origin.addingTimeInterval(1.0)))
        XCTAssertEqual(merge.drain(now: origin.addingTimeInterval(1.0)).count, 0)

        XCTAssertFalse(merge.isPriming(at: origin.addingTimeInterval(2.1)))
        XCTAssertEqual(merge.drain(now: origin.addingTimeInterval(2.1)).map(\.line.text), ["hello"])
    }

    /// A stream that ends (an exited container) counts as answered, so its silence
    /// does not cost the document the whole prime timeout.
    func testAFinishedStreamCountsAsAnswered() {
        let web = source("web")
        let api = source("api")
        var merge = ComposeLogMerge(holdInterval: 0.1, primeTimeout: 5.0)
        merge.register(web, at: origin)
        merge.register(api, at: origin)
        merge.ingest(line("hello", at: 1), from: web, at: origin)
        merge.markReady(api.id)

        XCTAssertFalse(merge.isPriming(at: origin.addingTimeInterval(0.2)))
        XCTAssertEqual(merge.drain(now: origin.addingTimeInterval(0.2)).map(\.line.text), ["hello"])
    }

    /// A continuation line with no Docker timestamp — a TTY stream, or a prefix the
    /// engine did not write — stays attached to the line it continues rather than
    /// floating to the end of the document.
    func testUntimestampedLineInheritsItsOwnServicesLastTimestamp() {
        let web = source("web")
        let api = source("api")
        var merge = primedMerge([web, api])

        merge.ingest(line("traceback:", at: 10, id: 0), from: web, at: origin)
        merge.ingest(line("  at frame 1", at: nil, id: 1), from: web, at: origin)
        merge.ingest(line("api line", at: 10.5, id: 0), from: api, at: origin)

        let released = merge.drain(now: origin.addingTimeInterval(0.3))
        XCTAssertEqual(released.map(\.line.text), ["traceback:", "  at frame 1", "api line"])
        XCTAssertNil(released[1].line.timestamp, "an inherited sort key is not an invented reading")
    }

    /// A service whose lines never carry a timestamp can only be ordered by arrival.
    /// That is the honest answer, and the row shows "—" so a reader can see it.
    func testServiceWithNoTimestampsFallsBackToArrival() {
        let tty = source("tty")
        let api = source("api")
        var merge = primedMerge([tty, api])

        merge.ingest(line("tty-1", at: nil, id: 0), from: tty, at: origin)
        merge.ingest(line("api-1", at: 20, id: 0), from: api, at: origin.addingTimeInterval(0.01))
        merge.ingest(line("tty-2", at: nil, id: 1), from: tty, at: origin.addingTimeInterval(0.02))

        let released = merge.drain(now: origin.addingTimeInterval(0.4))
        // The api line's engine timestamp is far in the future relative to the arrival
        // stamps the tty lines get, so both tty lines land first — by arrival, which is
        // the only clock they have.
        XCTAssertEqual(released.map(\.line.text), ["tty-1", "tty-2", "api-1"])
    }

    /// The documented failure mode: a line delayed past the reorder window is appended
    /// where it arrived rather than being inserted into history. It must never be
    /// dropped, and its real timestamp must survive so the jump is visible.
    func testALineDelayedPastTheWindowIsAppendedNotDropped() {
        let web = source("web")
        let api = source("api")
        var merge = primedMerge([web, api])

        merge.ingest(line("first", at: 10), from: web, at: origin)
        XCTAssertEqual(merge.drain(now: origin.addingTimeInterval(0.3)).map(\.line.text), ["first"])

        merge.ingest(line("stale", at: 9), from: api, at: origin.addingTimeInterval(1.0))
        let late = merge.drain(now: origin.addingTimeInterval(1.3))
        XCTAssertEqual(late.map(\.line.text), ["stale"])
        XCTAssertEqual(late[0].line.timestamp, origin.addingTimeInterval(9))
    }

    func testFlushReleasesEverythingInOrderWithoutWaiting() {
        let web = source("web")
        var merge = primedMerge([web])
        merge.ingest(line("b", at: 2, id: 1), from: web, at: origin)
        merge.ingest(line("a", at: 1, id: 0), from: web, at: origin)

        XCTAssertEqual(merge.flush().map(\.line.text), ["a", "b"])
        XCTAssertEqual(merge.pendingCount, 0)
        XCTAssertEqual(merge.flush().count, 0)
    }

    /// A firehose must bound memory even if that costs ordering accuracy.
    func testPendingBufferIsBounded() {
        let web = source("web")
        var merge = ComposeLogMerge(holdInterval: 60, primeTimeout: 0, pendingLimit: 50)
        merge.register(web, at: origin)
        merge.markReady(web.id)
        for index in 0..<500 {
            merge.ingest(line("line-\(index)", at: Double(index), id: index), from: web, at: origin)
        }

        let released = merge.drain(now: origin)
        XCTAssertEqual(released.count, 450, "everything above the bound is forced out")
        XCTAssertEqual(released.first?.line.text, "line-0", "and the oldest go first")
        XCTAssertEqual(merge.pendingCount, 50)
    }

    func testEqualTimestampsKeepIngestOrder() {
        let web = source("web")
        let api = source("api")
        var merge = primedMerge([web, api])
        merge.ingest(line("web", at: 5), from: web, at: origin)
        merge.ingest(line("api", at: 5), from: api, at: origin)

        XCTAssertEqual(
            merge.drain(now: origin.addingTimeInterval(0.3)).map(\.line.text), ["web", "api"])
    }
}

// MARK: - Per-service colour

final class ComposeServicePaletteTests: XCTestCase {

    /// The engine does not promise a container listing order, so the assignment must
    /// not depend on one.
    func testAssignmentIsIndependentOfInputOrder() {
        let forward = ComposeServicePalette.assign(services: ["api", "redis", "web", "worker"])
        let backward = ComposeServicePalette.assign(services: ["worker", "web", "redis", "api"])
        XCTAssertEqual(forward, backward)
    }

    /// Stability across restarts is the requirement, and the trap is `Hasher`: Swift
    /// seeds it per process, so a `hashValue`-based assignment would hand every service
    /// a new colour on every launch. These literals are the FNV-1a values; if the hash
    /// is ever swapped for a seeded one, this test fails immediately.
    func testHashIsStableAcrossProcessesNotSeeded() {
        XCTAssertEqual(ComposeServicePalette.fnv1a("web"), 6_818_697_334_544_801_521)
        XCTAssertEqual(ComposeServicePalette.fnv1a("api"), 16_667_751_959_619_087_879)
        XCTAssertEqual(ComposeServicePalette.fnv1a(""), 0xcbf2_9ce4_8422_2325)
    }

    func testKnownProjectAssignmentIsExact() {
        let assignment = ComposeServicePalette.assign(services: ["web", "api", "worker", "redis"])
        // api hashes to 9, redis to 0, web to 1; worker also hashes to 9 and probes
        // forward past the taken slots to 2.
        XCTAssertEqual(assignment, ["api": 9, "redis": 0, "web": 1, "worker": 2])
    }

    func testEveryServiceInAProjectOfTenGetsItsOwnSlot() {
        let names = (0..<10).map { "service-\($0)" }
        let assignment = ComposeServicePalette.assign(services: names)
        XCTAssertEqual(assignment.count, 10)
        XCTAssertEqual(Set(assignment.values).count, 10, "no two services share a colour")
        XCTAssertTrue(assignment.values.allSatisfy { (0..<ComposeServicePalette.slots.count).contains($0) })
    }

    func testDuplicateNamesCollapse() {
        XCTAssertEqual(ComposeServicePalette.assign(services: ["web", "web"]).count, 1)
    }

    /// Colour is supplemental to the service name, and the palette deliberately omits
    /// the greys: a service painted the same colour as ordinary log text is not
    /// colour-coded at all.
    func testPaletteExcludesTextColouredSlots() {
        let excluded: Set<TrackBAnsiColor> = [.black, .white, .brightBlack, .brightWhite]
        XCTAssertTrue(ComposeServicePalette.slots.allSatisfy { !excluded.contains($0) })
        XCTAssertEqual(Set(ComposeServicePalette.slots).count, ComposeServicePalette.slots.count)
    }

    /// A restarted service keeps its colour: the assignment is keyed on the service
    /// name, and a live document never re-runs it over lines already on screen.
    func testALaterServiceDoesNotDisturbExistingAssignments() {
        var colors = ComposeServiceColors(services: ["web", "api"])
        let web = colors.index(for: "web")
        let api = colors.index(for: "api")

        let newcomer = colors.index(for: "mailhog")
        XCTAssertEqual(colors.index(for: "web"), web)
        XCTAssertEqual(colors.index(for: "api"), api)
        XCTAssertNotEqual(newcomer, web)
        XCTAssertNotEqual(newcomer, api)
        XCTAssertEqual(colors.index(for: "mailhog"), newcomer, "and it is stable once assigned")
    }
}

// MARK: - Aggregated document scope

@MainActor
final class ComposeAggregatedStoreTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_772_000_000)

    private func source(_ name: String, index: Int = 0) -> TrackBLogSource {
        TrackBLogSource(containerID: "container-\(name)", service: name, colorIndex: index)
    }

    /// Builds an aggregated store the way the session does: IDs assigned at release, so
    /// display order and ID order are one sequence.
    private func aggregatedStore() -> (TrackBLogStore, TrackBLogSource, TrackBLogSource) {
        let web = source("web", index: 1)
        let api = source("api", index: 9)
        let store = TrackBLogStore()
        store.beginHostedStream()
        let payloads: [(TrackBLogSource, String)] = [
            (web, "web starting"),
            (api, "api starting"),
            (web, "web ERROR upstream"),
            (api, "api ready"),
        ]
        store.appendHosted(
            payloads.enumerated().map { index, payload in
                TrackBRenderedLine(
                    LogLine(
                        id: index,
                        text: payload.1,
                        stream: .stdout,
                        timestamp: origin.addingTimeInterval(Double(index))),
                    id: index,
                    source: payload.0)
            })
        return (store, web, api)
    }

    func testHostedLinesCarryTheirServiceAndDocumentWideIDs() {
        let (store, web, api) = aggregatedStore()
        XCTAssertEqual(store.visibleLines.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(store.visibleLines.map { $0.source?.service }, ["web", "api", "web", "api"])
        XCTAssertEqual(store.visibleLines[0].source, web)
        XCTAssertEqual(store.visibleLines[1].source, api)
    }

    func testHidingAServiceRemovesItsLinesAndItsMatches() {
        let (store, web, _) = aggregatedStore()
        store.hiddenSources.insert(web.containerID)

        XCTAssertEqual(store.visibleLines.map(\.plain), ["api starting", "api ready"])
        XCTAssertTrue(store.hasHiddenSources)
        // A hidden line is not a match: the count must describe what is on screen.
        store.query = "ERROR"
        XCTAssertEqual(store.matchIDs, [])
        XCTAssertEqual(store.matchPositionText, "No matches")

        store.hiddenSources.remove(web.containerID)
        XCTAssertEqual(store.visibleLines.count, 4)
        XCTAssertEqual(store.matchIDs, [2])
    }

    /// UX-1 must survive aggregation: a find query in the merged document still shows
    /// every line, including lines from services that do not match.
    func testFindKeepsEveryServicesContextInTheMergedDocument() {
        let (store, _, _) = aggregatedStore()
        store.query = "error"
        XCTAssertEqual(store.visibleLines.count, 4, "context is the point of a merged log too")
        XCTAssertEqual(store.matchIDs, [2])
        XCTAssertTrue(store.isFinding)
    }

    func testFilterAndHiddenServicesCompose() {
        let (store, web, _) = aggregatedStore()
        store.mode = .filter
        store.query = "starting"
        XCTAssertEqual(store.visibleLines.map(\.plain), ["web starting", "api starting"])

        store.hiddenSources.insert(web.containerID)
        XCTAssertEqual(store.visibleLines.map(\.plain), ["api starting"])
        XCTAssertEqual(store.matchCount, 1, "the count follows the scope, not the buffer")
    }

    func testAppendingWhileAServiceIsHiddenKeepsTheScope() {
        let (store, web, _) = aggregatedStore()
        store.hiddenSources.insert(web.containerID)
        store.appendHosted([
            TrackBRenderedLine(
                LogLine(id: 4, text: "web later", stream: .stdout, timestamp: origin),
                id: 4,
                source: web)
        ])
        XCTAssertEqual(store.visibleLines.map(\.plain), ["api starting", "api ready"])
        XCTAssertEqual(store.lines.count, 5, "hidden is not discarded — showing it again is instant")
    }

    func testCopiedTranscriptNamesTheServiceOfEveryLine() {
        let (store, _, _) = aggregatedStore()
        let text = store.exportText()
        XCTAssertTrue(text.contains("[web] [stdout] web starting"))
        XCTAssertTrue(text.contains("[api] [stdout] api ready"))
    }

    /// A single-container transcript must keep exactly the format it had: no service
    /// column appears where there is only one source.
    func testSingleContainerTranscriptFormatIsUnchanged() {
        let store = TrackBLogStore()
        store.seed(
            [LogLine(id: 0, text: "hello", stream: .stdout, timestamp: nil)], isStreaming: false)
        XCTAssertEqual(store.exportText(), "[stdout] hello\n")
    }

    func testProjectDocumentDisclosesHiddenAndUnavailableServices() {
        let (store, web, _) = aggregatedStore()
        store.hiddenSources.insert(web.containerID)
        let document = store.exportProjectDocument(
            project: "shopfront",
            includedServices: ["api"],
            hiddenServices: ["web"],
            unavailableServices: ["worker"],
            capturedAt: origin)

        XCTAssertEqual(document.lineCount, 2)
        XCTAssertTrue(document.text.contains("# Project: shopfront"))
        XCTAssertTrue(document.text.contains("# Services included: api"))
        XCTAssertTrue(
            document.text.contains(
                "# Services hidden when captured (their lines are NOT in this file): web"))
        XCTAssertTrue(document.text.contains("# Services Docker could not stream: worker"))
        XCTAssertTrue(document.text.contains("# Ordering: merged on the timestamp dockerd recorded"))
        XCTAssertTrue(document.text.contains("[api] [stdout] api starting"))
        XCTAssertFalse(document.text.contains("web starting"), "a hidden service is not exported")
    }

    /// The scrollback is shared across every service, so the per-service history
    /// request has to shrink as a project grows or the oldest half is evicted unread.
    func testHistoryTailSharesTheScrollbackBudget() {
        XCTAssertEqual(ComposeProjectLogSession.historyTail(serviceCount: 1), TrackBLogStore.initialTail)
        XCTAssertEqual(ComposeProjectLogSession.historyTail(serviceCount: 4), 1_000)
        XCTAssertEqual(ComposeProjectLogSession.historyTail(serviceCount: 20), 250)
        XCTAssertEqual(
            ComposeProjectLogSession.historyTail(serviceCount: 500), 100, "never less than useful")
        XCTAssertEqual(ComposeProjectLogSession.historyTail(serviceCount: 0), TrackBLogStore.initialTail)
    }

    /// Fixture logs must stay deterministic, must keep `shopfront-api-1` byte-identical
    /// (every existing capture and the fixture diagnostics read that container), and
    /// must differ between services — four identical streams would make the aggregated
    /// document look right while proving nothing about merging.
    func testFixtureLogsAreDeterministicPerContainerAndDifferPerService() {
        let corpus = ShotLogs.apiLog(now: Date(timeIntervalSince1970: 1_772_000_000))
        let api = ShotFixtures.container("shopfront-api-1")
        let web = ShotFixtures.container("shopfront-web-1")
        let worker = ShotFixtures.container("shopfront-worker-1")

        XCTAssertEqual(ShotDockerClient.lines(corpus, for: api.id), corpus)
        XCTAssertEqual(
            ShotDockerClient.lines(corpus, for: web.id),
            ShotDockerClient.lines(corpus, for: web.id),
            "two runs of the same fixture must be comparable")
        XCTAssertNotEqual(
            ShotDockerClient.lines(corpus, for: web.id).map(\.text),
            ShotDockerClient.lines(corpus, for: worker.id).map(\.text))
        XCTAssertFalse(ShotDockerClient.lines(corpus, for: web.id).isEmpty)
        XCTAssertTrue(
            ShotDockerClient.lines(corpus, for: web.id).allSatisfy { $0.timestamp != nil },
            "an offset fixture line still carries a timestamp to merge on")
    }

    func testServiceNameFallsBackToTheContainerName() {
        let labelled = ContainerSummary(
            id: "a", names: ["/shopfront-web-1"], displayName: "shopfront-web-1",
            image: "nginx", state: "running", status: "Up", composeProject: "shopfront",
            composeService: "web", ports: [], createdAt: .distantPast)
        let unlabelled = ContainerSummary(
            id: "b", names: ["/loose"], displayName: "loose",
            image: "nginx", state: "running", status: "Up", composeProject: "shopfront",
            composeService: nil, ports: [], createdAt: .distantPast)

        XCTAssertEqual(ComposeProjectLogSession.serviceName(for: labelled), "web")
        XCTAssertEqual(ComposeProjectLogSession.serviceName(for: unlabelled), "loose")
    }
}
