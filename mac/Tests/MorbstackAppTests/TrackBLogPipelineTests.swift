// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the pure types behind the Containers screen: the ANSI parser, the log
// scrollback's ring buffer, the follow/stick-to-bottom rule, the filter, the export
// formatter, and the inspect-document reader.
//
// These are tested rather than the views because they are where the real edge cases
// live. A ring that evicts the wrong end, a follow mode that fights the scroll wheel, or
// a colour parser that leaves `[0;32m` littered through the output are all bugs a
// screenshot would not catch and a user would notice immediately.

import XCTest

@testable import MorbstackAppCore

// MARK: - ANSI

final class TrackBAnsiTests: XCTestCase {

    func testPlainTextIsASingleSpan() {
        XCTAssertEqual(TrackBAnsi.spans("hello"), [TrackBAnsiSpan("hello")])
        XCTAssertEqual(TrackBAnsi.spans(""), [])
    }

    func testEscapeDetectionShortCircuits() {
        XCTAssertFalse(TrackBAnsi.containsEscape("plain text"))
        XCTAssertTrue(TrackBAnsi.containsEscape("a\u{1B}[0mb"))
        // A multi-byte character must not be mistaken for an escape byte.
        XCTAssertFalse(TrackBAnsi.containsEscape("ünïcödé 🎉"))
    }

    func testBasicForegroundColours() {
        let spans = TrackBAnsi.spans("\u{1B}[31mred\u{1B}[0m done")
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].text, "red")
        XCTAssertEqual(spans[0].style.color, .red)
        XCTAssertEqual(spans[1].text, " done")
        XCTAssertEqual(spans[1].style, .plain)
    }

    func testBrightForegroundColours() {
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[92mgo")[0].style.color, .brightGreen)
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[37mx")[0].style.color, .white)
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[90mx")[0].style.color, .brightBlack)
    }

    func testBoldDimAndIntensityReset() {
        let spans = TrackBAnsi.spans("\u{1B}[1;34mB\u{1B}[22mN")
        XCTAssertEqual(spans.count, 2)
        XCTAssertTrue(spans[0].style.bold)
        XCTAssertEqual(spans[0].style.color, .blue)
        XCTAssertFalse(spans[1].style.bold)
        // 22 resets intensity only — the colour is a separate attribute and must survive.
        XCTAssertEqual(spans[1].style.color, .blue)

        XCTAssertTrue(TrackBAnsi.spans("\u{1B}[2mx")[0].style.dim)
    }

    func testDefaultForegroundKeepsIntensity() {
        let spans = TrackBAnsi.spans("\u{1B}[1;31ma\u{1B}[39mb")
        XCTAssertNil(spans[1].style.color)
        XCTAssertTrue(spans[1].style.bold)
    }

    func testBareSGRIsAReset() {
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[31ma\u{1B}[mb")[1].style, .plain)
    }

    func testExtendedColourParametersAreConsumed() {
        // Low sixteen have a named equivalent.
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[38;5;1mx")[0].style.color, .red)
        // Higher indices and truecolour do not, and must not be mis-read as other codes.
        XCTAssertNil(TrackBAnsi.spans("\u{1B}[38;5;200mx")[0].style.color)
        XCTAssertNil(TrackBAnsi.spans("\u{1B}[38;2;255;0;0mx")[0].style.color)
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[38;2;255;0;0mx")[0].text, "x")
        // The regression this guards: a parameter after truecolour still has to apply.
        XCTAssertTrue(TrackBAnsi.spans("\u{1B}[38;2;255;0;0;1mx")[0].style.bold)
    }

    func testColonSubParameterSyntax() {
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[38:5:2mx")[0].style.color, .green)
    }

    func testUnsupportedCodesAreStrippedWithoutResidue() {
        // Background, underline, inverse — understood well enough to be skipped.
        let background = TrackBAnsi.spans("\u{1B}[41mx")
        XCTAssertEqual(background[0].style, .plain)
        XCTAssertEqual(background[0].text, "x")

        XCTAssertEqual(TrackBAnsi.strip("\u{1B}[2J\u{1B}[1;1Hhome"), "home")
        XCTAssertEqual(TrackBAnsi.strip("\u{1B}[?25lhidden\u{1B}[?25h"), "hidden")
    }

    func testPrivateModeSequenceIsNotTreatedAsSGR() {
        XCTAssertEqual(TrackBAnsi.spans("\u{1B}[?1mx")[0].style, .plain)
    }

    func testOperatingSystemCommandsAreStripped() {
        XCTAssertEqual(TrackBAnsi.strip("\u{1B}]0;my title\u{07}text"), "text")
        XCTAssertEqual(TrackBAnsi.strip("\u{1B}]0;t\u{1B}\\text"), "text")
    }

    func testTruncatedSequencesLeaveNothingBehind() {
        XCTAssertEqual(TrackBAnsi.strip("text\u{1B}"), "text")
        XCTAssertEqual(TrackBAnsi.strip("text\u{1B}["), "text")
        XCTAssertEqual(TrackBAnsi.strip("text\u{1B}[31"), "text")
    }

    func testAdjacentIdenticalStylesAreMerged() {
        let spans = TrackBAnsi.spans("\u{1B}[31ma\u{1B}[31mb")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "ab")
    }

    /// The invariant search, copy and export all depend on.
    func testStripEqualsJoinedSpans() {
        let samples = [
            "\u{1B}[31mred\u{1B}[0m plain \u{1B}[1;92mbright\u{1B}[0m",
            "no escapes at all",
            "\u{1B}[2J\u{1B}]0;x\u{07}\u{1B}[38;2;1;2;3mrgb",
            "unicode 🎉 \u{1B}[36mcyan\u{1B}[0m ünïcödé",
            "",
        ]
        for sample in samples {
            XCTAssertEqual(
                TrackBAnsi.strip(sample),
                TrackBAnsi.spans(sample).map(\.text).joined(),
                "mismatch for \(sample.debugDescription)")
        }
    }

    func testUnicodeSurvivesIntact() {
        XCTAssertEqual(
            TrackBAnsi.strip("unicode 🎉 \u{1B}[36mcyan\u{1B}[0m ünïcödé"),
            "unicode 🎉 cyan ünïcödé")
    }
}

// MARK: - Ring buffer

final class TrackBRingBufferTests: XCTestCase {

    func testHoldsUpToCapacityWithoutDropping() {
        var ring = TrackBRingBuffer<Int>(capacity: 10)
        XCTAssertTrue(ring.isEmpty)
        for value in 0..<10 { ring.append(value) }
        XCTAssertEqual(ring.count, 10)
        XCTAssertFalse(ring.hasDropped)
        XCTAssertEqual(Array(ring), Array(0..<10))
    }

    func testEvictsOldestAndStaysBounded() {
        var ring = TrackBRingBuffer<Int>(capacity: 10)
        for value in 0..<200 { ring.append(value) }

        XCTAssertGreaterThanOrEqual(ring.count, 10, "never falls below capacity")
        XCTAssertLessThanOrEqual(ring.count, 10 + ring.slack, "never exceeds capacity + slack")
        XCTAssertEqual(ring.last, 199, "newest is retained")
        XCTAssertTrue(ring.hasDropped)
        XCTAssertEqual(ring.droppedCount + ring.count, 200, "every line is either held or counted")
        XCTAssertEqual(Array(ring), Array((200 - ring.count)..<200), "retained window is contiguous")
    }

    func testBulkAppendLargerThanTheBuffer() {
        var ring = TrackBRingBuffer<Int>(capacity: 5)
        ring.append(contentsOf: 0..<1000)
        XCTAssertLessThanOrEqual(ring.count, 5 + ring.slack)
        XCTAssertEqual(ring.last, 999)
    }

    func testRemoveAllResetsTheDropCount() {
        var ring = TrackBRingBuffer<Int>(capacity: 4)
        ring.append(contentsOf: 0..<100)
        ring.removeAll()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.droppedCount, 0)
        XCTAssertFalse(ring.hasDropped)
    }

    func testDegenerateCapacityIsClamped() {
        var ring = TrackBRingBuffer<Int>(capacity: 0)
        ring.append(contentsOf: 0..<50)
        XCTAssertGreaterThanOrEqual(ring.count, 1)
        XCTAssertEqual(ring.last, 49)
    }

    func testBehavesAsARandomAccessCollection() {
        var ring = TrackBRingBuffer<String>(capacity: 4)
        ring.append(contentsOf: ["a", "b", "c"])
        XCTAssertEqual(ring[1], "b")
        XCTAssertEqual(ring.map { $0.uppercased() }, ["A", "B", "C"])
        XCTAssertEqual(ring.first, "a")
    }
}

// MARK: - Follow / stick-to-bottom

final class TrackBTailTrackerTests: XCTestCase {

    func testFollowsByDefault() {
        let tail = TrackBTailTracker()
        XCTAssertTrue(tail.shouldAutoScroll)
        XCTAssertFalse(tail.showsJumpToBottom)
    }

    func testScrollingUpPausesWithoutChangingTheToggle() {
        var tail = TrackBTailTracker()
        tail.observe(distanceFromBottom: 400)
        XCTAssertFalse(tail.shouldAutoScroll)
        XCTAssertTrue(tail.showsJumpToBottom)
        XCTAssertTrue(tail.followEnabled, "scrolling is not the same as switching follow off")
    }

    func testScrollingBackToTheBottomResumes() {
        var tail = TrackBTailTracker()
        tail.observe(distanceFromBottom: 400)
        tail.observe(distanceFromBottom: 2)
        XCTAssertTrue(tail.shouldAutoScroll)
    }

    func testSmallOffsetsStillCountAsTheBottom() {
        var tail = TrackBTailTracker()
        tail.observe(distanceFromBottom: 5)
        XCTAssertTrue(tail.shouldAutoScroll)
        tail.observe(distanceFromBottom: tail.stickThreshold + 1)
        XCTAssertFalse(tail.shouldAutoScroll)
    }

    func testJumpToBottomRepins() {
        var tail = TrackBTailTracker()
        tail.observe(distanceFromBottom: 999)
        tail.jumpToBottom()
        XCTAssertTrue(tail.shouldAutoScroll)
    }

    func testTogglingFollowOffStopsAutoScrollEvenAtTheBottom() {
        var tail = TrackBTailTracker()
        tail.setFollow(false)
        tail.observe(distanceFromBottom: 0)
        XCTAssertFalse(tail.shouldAutoScroll)
    }

    func testTurningFollowOnRepinsFromHistory() {
        var tail = TrackBTailTracker()
        tail.observe(distanceFromBottom: 800)
        tail.setFollow(true)
        XCTAssertTrue(tail.shouldAutoScroll, "asking to follow and seeing nothing happen is a bug")
    }

    func testGarbageOffsetsDoNotUnpin() {
        var tail = TrackBTailTracker()
        tail.observe(distanceFromBottom: .nan)
        XCTAssertTrue(tail.shouldAutoScroll)
        // Elastic overscroll reports a negative distance; that is still the bottom.
        tail.observe(distanceFromBottom: -12)
        XCTAssertTrue(tail.shouldAutoScroll)
    }
}

// MARK: - Filtering

final class TrackBLogFilterTests: XCTestCase {

    private let lines = ["Starting server", "ERROR: boom", "error again", "done"]
        .map { $0.lowercased() }

    func testNormalisation() {
        XCTAssertEqual(TrackBLogFilter.normalize("  ERROR "), "error")
        XCTAssertEqual(TrackBLogFilter.normalize("   "), "", "whitespace alone is not a filter")
    }

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(TrackBLogFilter.filter(lines, needle: "error", lowered: { $0 }).count, 2)
    }

    func testEmptyNeedlePassesEverythingButCountsNothing() {
        XCTAssertEqual(TrackBLogFilter.filter(lines, needle: "", lowered: { $0 }).count, 4)
        XCTAssertEqual(TrackBLogFilter.matchCount(lines, needle: "", lowered: { $0 }), 0)
    }

    /// The toolbar shows a count next to rows produced by `filter`; if these two ever
    /// disagree the UI is lying about its own contents.
    func testCountAndFilterAlwaysAgree() {
        for needle in ["e", "error", "z", "server"] {
            XCTAssertEqual(
                TrackBLogFilter.filter(lines, needle: needle, lowered: { $0 }).count,
                TrackBLogFilter.matchCount(lines, needle: needle, lowered: { $0 }),
                "disagreement for '\(needle)'")
        }
    }
}

// MARK: - Transcript source semantics

final class TrackBLogTranscriptSemanticsTests: XCTestCase {

    func testDockerStreamLabelsDescribeSourceWithoutInventingSeverity() {
        XCTAssertEqual(StdStream.stdout.logTranscriptLabel, "stdout")
        XCTAssertEqual(StdStream.stderr.logTranscriptLabel, "stderr")
        XCTAssertEqual(StdStream.stdout.logTranscriptAccessibilityLabel, "Standard output")
        XCTAssertEqual(StdStream.stderr.logTranscriptAccessibilityLabel, "Standard error")
    }
}

// MARK: - Export

final class TrackBLogExportTests: XCTestCase {

    private struct Line {
        var ts: Date?
        var stream: StdStream
        var text: String
    }

    private let now = Date(timeIntervalSince1970: 1_772_000_000)

    private var lines: [Line] {
        [
            Line(ts: now, stream: .stdout, text: "hello"),
            Line(ts: nil, stream: .stderr, text: "bad"),
        ]
    }

    func testMarksStderrAndTerminatesEveryLine() {
        let text = TrackBLogExport.text(
            lines, timestamp: \.ts, stream: \.stream, body: \.text, includeTimestamps: true)
        XCTAssertTrue(text.contains("[stderr] bad"))
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testTimestampsCanBeOmitted() {
        let text = TrackBLogExport.text(
            lines, timestamp: \.ts, stream: \.stream, body: \.text, includeTimestamps: false)
        XCTAssertEqual(text, "hello\n[stderr] bad\n")
    }

    func testSuggestedFilenameIsSafeForTheFilesystem() {
        let name = TrackBLogExport.suggestedFilename(container: "web/api:1", now: now)
        XCTAssertTrue(name.hasSuffix(".log"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }
}

// MARK: - Inspect document

final class TrackBInspectDetailsTests: XCTestCase {

    private let json = """
    {
      "Id": "abc123",
      "Name": "/web",
      "Created": "2026-03-12T09:41:22.418913274Z",
      "Path": "nginx",
      "Args": ["-g", "daemon off;"],
      "Image": "sha256:deadbeef",
      "Platform": "linux",
      "RestartCount": 2,
      "State": {
        "Status": "running",
        "Running": true,
        "StartedAt": "2026-03-12T09:41:23.000000000Z",
        "FinishedAt": "0001-01-01T00:00:00Z",
        "ExitCode": 0,
        "Health": { "Status": "healthy" }
      },
      "Config": {
        "Env": ["PATH=/usr/bin", "DB_PASSWORD=hunter2", "EMPTY"],
        "Labels": { "com.docker.compose.service": "web", "a.label": "1" },
        "Entrypoint": ["/docker-entrypoint.sh"],
        "WorkingDir": "",
        "User": "root",
        "Image": "nginx:latest"
      },
      "Mounts": [
        { "Type": "volume", "Name": "data", "Source": "/var/lib/docker/volumes/data/_data",
          "Destination": "/data", "RW": false }
      ],
      "HostConfig": {
        "RestartPolicy": { "Name": "unless-stopped" },
        "Memory": 536870912,
        "NanoCpus": 1500000000,
        "CpuShares": 512,
        "PidsLimit": 128,
        "ReadonlyRootfs": true,
        "NetworkMode": "app_default"
      },
      "NetworkSettings": {
        "Networks": {
          "bridge": {},
          "app_default": {
            "NetworkID": "network-app",
            "EndpointID": "endpoint-app",
            "Gateway": "172.20.0.1",
            "IPAddress": "172.20.0.4",
            "IPv6Gateway": "fd00::1",
            "GlobalIPv6Address": "fd00::4",
            "MacAddress": "02:42:ac:14:00:04",
            "Aliases": ["web", "project-web"]
          }
        }
      }
    }
    """

    func testDecodesTheFieldsTheOverviewTabShows() throws {
        let details = try XCTUnwrap(TrackBInspectDetails(json: json))
        XCTAssertEqual(details.name, "web", "the leading slash is Docker's, not the user's")
        XCTAssertEqual(details.imageRef, "nginx:latest")
        XCTAssertEqual(details.imageID, "sha256:deadbeef")
        XCTAssertEqual(details.command, "nginx -g 'daemon off;'")
        XCTAssertEqual(details.entrypoint, "/docker-entrypoint.sh")
        XCTAssertNil(details.workingDir, "an empty string is not a working directory")
        XCTAssertEqual(details.user, "root")
        XCTAssertEqual(details.restartCount, 2)
        XCTAssertEqual(details.restartPolicy, "unless-stopped")
        XCTAssertEqual(details.health, "healthy")
        XCTAssertEqual(details.status, "running")
        XCTAssertEqual(details.resourceLimits.memoryBytes, 536870912)
        XCTAssertEqual(details.resourceLimits.nanoCPUs, 1500000000)
        XCTAssertEqual(details.resourceLimits.cpuShares, 512)
        XCTAssertEqual(details.resourceLimits.pidsLimit, 128)
        XCTAssertEqual(details.resourceLimits.readOnlyRootFilesystem, true)
    }

    func testParsesNineDigitFractionalTimestamps() throws {
        let details = try XCTUnwrap(TrackBInspectDetails(json: json))
        XCTAssertNotNil(details.created)
        XCTAssertNotNil(details.startedAt)
        XCTAssertNil(details.finishedAt, "Docker's zero date means 'never', not year one")
    }

    func testEnvironmentSplitting() throws {
        let details = try XCTUnwrap(TrackBInspectDetails(json: json))
        XCTAssertEqual(details.env.count, 3)
        XCTAssertEqual(details.env[1].key, "DB_PASSWORD")
        XCTAssertEqual(details.env[1].value, "hunter2")
        XCTAssertEqual(details.env[2].key, "EMPTY", "an entry with no '=' is still a variable")
        XCTAssertEqual(details.env[2].value, "")
        XCTAssertTrue(details.env[1].lowered.contains("hunter2"), "search covers values too")
    }

    /// The `Type` key cannot be a Swift property name, so it is mapped through
    /// `CodingKeys`; this is the test that the mapping is actually wired up.
    func testMountTypeIsMappedThroughCodingKeys() throws {
        let details = try XCTUnwrap(TrackBInspectDetails(json: json))
        XCTAssertEqual(details.mounts.count, 1)
        XCTAssertEqual(details.mounts[0].kind, "volume")
        XCTAssertEqual(details.mounts[0].name, "data")
        XCTAssertEqual(details.mounts[0].destination, "/data")
        XCTAssertTrue(details.mounts[0].readOnly, "RW:false means read-only")
    }

    func testLabelsAndNetworksAreSorted() throws {
        let details = try XCTUnwrap(TrackBInspectDetails(json: json))
        XCTAssertEqual(details.labels.map(\.key), ["a.label", "com.docker.compose.service"])
        XCTAssertEqual(details.networks, ["app_default", "bridge"])
        XCTAssertEqual(details.networkMode, "app_default")
        XCTAssertEqual(details.networkEndpoints[0].ipAddress, "172.20.0.4")
        XCTAssertEqual(details.networkEndpoints[0].globalIPv6Address, "fd00::4")
        XCTAssertEqual(details.networkEndpoints[0].aliases, ["project-web", "web"])
        XCTAssertNil(details.networkEndpoints[1].endpointID)
    }

    func testResourceLimitDescriptionsKeepUnreportedAndUnlimitedStatesDistinct() {
        let configured = TrackBInspectDetails.ResourceLimits(
            memoryBytes: 536870912,
            nanoCPUs: 1_500_000_000,
            cpuShares: 512,
            pidsLimit: 128,
            readOnlyRootFilesystem: true)
        XCTAssertEqual(configured.memoryLimitDescription, Formatters.bytesString(536870912))
        XCTAssertTrue(configured.cpuLimitDescription.hasSuffix("CPUs"))
        XCTAssertEqual(configured.cpuSharesDescription, "512 shares")
        XCTAssertEqual(configured.pidsLimitDescription, "128 processes")

        let unlimited = TrackBInspectDetails.ResourceLimits(
            memoryBytes: 0,
            nanoCPUs: 0,
            cpuShares: 0,
            pidsLimit: -1,
            readOnlyRootFilesystem: false)
        XCTAssertEqual(unlimited.memoryLimitDescription, "No limit")
        XCTAssertEqual(unlimited.cpuLimitDescription, "No limit")
        XCTAssertEqual(unlimited.cpuSharesDescription, "Default")
        XCTAssertEqual(unlimited.pidsLimitDescription, "No limit")

        let unknown = TrackBInspectDetails.ResourceLimits(
            memoryBytes: nil,
            nanoCPUs: nil,
            cpuShares: nil,
            pidsLimit: nil,
            readOnlyRootFilesystem: nil)
        XCTAssertEqual(unknown.memoryLimitDescription, "Not reported")
        XCTAssertEqual(unknown.cpuLimitDescription, "Not reported")
        XCTAssertEqual(unknown.cpuSharesDescription, "Not reported")
        XCTAssertEqual(unknown.pidsLimitDescription, "Not reported")
    }

    func testTimelineForARunningContainer() throws {
        let details = try XCTUnwrap(TrackBInspectDetails(json: json))
        let labels = details.timeline.map(\.label)
        XCTAssertTrue(labels.contains("Created"))
        XCTAssertTrue(labels.contains("Started"))
        XCTAssertFalse(labels.contains("Exited"), "a running container has not exited")
        XCTAssertTrue(labels.contains("Restarts"))
        XCTAssertNotNil(details.uptime)
    }

    func testTimelineForAnExitedContainer() throws {
        let exited = """
        {"Name":"/old","State":{"Status":"exited","StartedAt":"2026-03-01T00:00:00Z",
         "FinishedAt":"2026-03-02T00:00:00Z","ExitCode":137}}
        """
        let details = try XCTUnwrap(TrackBInspectDetails(json: exited))
        XCTAssertEqual(details.exitCode, 137)
        XCTAssertNil(details.uptime)
        XCTAssertTrue(
            details.timeline.contains { $0.label == "Exited" && $0.detail.contains("exit 137") })
    }

    func testSurvivesSparseAndMalformedDocuments() {
        XCTAssertNil(TrackBInspectDetails(json: "not json"))
        let bare = TrackBInspectDetails(json: "{}")
        XCTAssertNotNil(bare, "an empty object is a valid, if uninformative, document")
        XCTAssertEqual(bare?.command, "")
        XCTAssertEqual(bare?.env.count, 0)
    }

    func testShellQuotingOnlyQuotesWhatNeedsIt() {
        XCTAssertEqual(TrackBInspectDetails.shellQuote("simple"), "simple")
        XCTAssertEqual(TrackBInspectDetails.shellQuote("/usr/bin/env"), "/usr/bin/env")
        XCTAssertEqual(TrackBInspectDetails.shellQuote("has space"), "'has space'")
        XCTAssertEqual(TrackBInspectDetails.shellQuote(""), "''", "an empty argument must be visible")
        XCTAssertTrue(TrackBInspectDetails.shellQuote("it's").contains(#"'\''"#))
    }

    func testSecretHeuristicFlagsTheObviousCases() {
        XCTAssertTrue(TrackBSecretHeuristic.looksSensitive(key: "DB_PASSWORD"))
        XCTAssertTrue(TrackBSecretHeuristic.looksSensitive(key: "aws_access_key"))
        XCTAssertTrue(TrackBSecretHeuristic.looksSensitive(key: "GITHUB_TOKEN"))
        XCTAssertFalse(TrackBSecretHeuristic.looksSensitive(key: "PATH"))
    }
}

// MARK: - Rendered line

@MainActor
final class TrackBRenderedLineTests: XCTestCase {

    func testStripsEscapesFromThePlainText() {
        let line = LogLine(id: 7, text: "\u{1B}[31mboom\u{1B}[0m", stream: .stderr, timestamp: nil)
        let rendered = TrackBRenderedLine(line)
        XCTAssertEqual(rendered.id, 7)
        XCTAssertEqual(rendered.plain, "boom", "copy and export must not carry escapes")
        XCTAssertEqual(rendered.lowered, "boom")
        XCTAssertEqual(rendered.stream, .stderr)
        XCTAssertEqual(String(rendered.attributed.characters), "boom")
    }

    func testCachesALowercasedCopyForTheFilter() {
        let rendered = TrackBRenderedLine(
            LogLine(id: 0, text: "MiXeD Case", stream: .stdout, timestamp: nil))
        XCTAssertEqual(rendered.lowered, "mixed case")
    }

    func testIdentityIsTheOnlyThingComparedForDiffing() {
        let a = TrackBRenderedLine(LogLine(id: 1, text: "a", stream: .stdout, timestamp: nil))
        let b = TrackBRenderedLine(LogLine(id: 1, text: "b", stream: .stderr, timestamp: nil))
        let c = TrackBRenderedLine(LogLine(id: 2, text: "a", stream: .stdout, timestamp: nil))
        XCTAssertEqual(a, b, "rendered lines are immutable, so the id settles it")
        XCTAssertNotEqual(a, c)
    }

    func testEmptyLineIsPreserved() {
        let rendered = TrackBRenderedLine(
            LogLine(id: 3, text: "", stream: .stdout, timestamp: nil))
        XCTAssertEqual(rendered.plain, "", "blank lines are printed on purpose")
    }
}
