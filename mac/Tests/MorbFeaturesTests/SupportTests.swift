// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbFeatures

/// The shared helpers every feature module prints and parses through.
final class FeatureSupportTests: XCTestCase {

    func testBytesUsesDecimalUnitsLikeDockerSystemDf() {
        XCTAssertEqual(Format.bytes(0), "0 B")
        XCTAssertEqual(Format.bytes(999), "999 B")
        XCTAssertEqual(Format.bytes(1000), "1.0 kB")
        XCTAssertEqual(Format.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(Format.bytes(2_400_000_000), "2.4 GB")
    }

    func testDurationSwitchesUnitsByMagnitude() {
        XCTAssertEqual(Format.duration(0.812), "812ms")
        XCTAssertEqual(Format.duration(1.2345), "1.234s")
        XCTAssertEqual(Format.duration(75), "1m 15.0s")
        XCTAssertEqual(Format.duration(.nan), "-")
    }

    func testTableSizesColumnsToTheWidestCellNotTheHeader() {
        var table = TextTable(headers: ["NAME", "N"], rightAligned: [1])
        table.add(["a-very-long-container-name", "3"])
        let rendered = table.render()
        let lines = rendered.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        // Header row is padded out to the width of the long cell below it.
        XCTAssertTrue(lines[0].hasPrefix("  NAME                      "), lines[0])
        XCTAssertFalse(lines.contains { $0.hasSuffix(" ") }, "no trailing whitespace")
    }

    func testEnginePathPrefixesTheVersionAndEncodesQuery() {
        let path = EngineClient.path("/containers/json", query: [("filters", "{\"status\":[\"running\"]}")])
        XCTAssertTrue(path.hasPrefix("/v1.43/containers/json?filters="))
        XCTAssertFalse(path.contains("{"), "the JSON filter must be percent-encoded: \(path)")
    }

    func testDemuxSplitsStdoutAndStderrFrames() {
        var data = Data([1, 0, 0, 0, 0, 0, 0, 5])
        data.append(contentsOf: Array("hello".utf8))
        data.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 3])
        data.append(contentsOf: Array("err".utf8))
        let output = DockerStreamDemux.split(data)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "hello")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "err")
    }

    func testDemuxPassesUnframedTTYOutputThroughUntouched() {
        // A TTY-attached container's output has no framing. Treating the first byte as
        // a stream id would eat eight characters of the user's log line.
        let raw = Data("plain tty output with no framing at all".utf8)
        XCTAssertFalse(DockerStreamDemux.looksFramed(raw))
        XCTAssertEqual(String(decoding: DockerStreamDemux.split(raw).stdout, as: UTF8.self),
                       "plain tty output with no framing at all")
    }

    func testWhichFindsAToolThatIsCertainlyPresent() {
        XCTAssertNotNil(Subprocess.which("sh"))
        XCTAssertNil(Subprocess.which("morb-definitely-not-a-real-binary"))
    }

    func testRunCapturesBothStreamsAndTheExitCode() throws {
        let result = try Subprocess.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        XCTAssertFalse(result.timedOut)
    }

    func testRunKillsAProcessThatOverrunsItsDeadline() throws {
        let result = try Subprocess.run("/bin/sh", ["-c", "sleep 30"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.duration, 10)
    }

    func testRunDoesNotDeadlockOnMoreOutputThanOnePipeBuffer() throws {
        // 512 KiB on each stream, well past the 64 KiB pipe buffer. Draining the two
        // pipes serially hangs here forever.
        let result = try Subprocess.run(
            "/bin/sh",
            ["-c", "yes morbstack | head -c 524288; yes morbstack | head -c 524288 1>&2"],
            timeout: 30)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 524_288)
        XCTAssertEqual(result.stderr.count, 524_288)
    }
}

/// `EngineClient` against a real engine.
///
/// Skipped rather than failed when nothing is listening: `swift test` runs on
/// machines with no VM booted, and a suite that turns red because the developer
/// happened not to have started their daemon trains people to ignore it. The same
/// rule the repository already applies to `MorbLive`.
final class EngineClientLiveTests: XCTestCase {

    private func liveClient() throws -> EngineClient {
        let client = EngineClient()
        guard FileManager.default.fileExists(atPath: client.socketPath), client.ping() else {
            throw XCTSkip("no engine answering at \(client.socketPath)")
        }
        return client
    }

    func testPingAndVersion() throws {
        let client = try liveClient()
        let version = try XCTUnwrap(client.version())
        XCTAssertFalse((version["Version"] as? String ?? "").isEmpty)
        XCTAssertEqual(version["Os"] as? String, "linux")
    }

    func testContainerListDecodesAsAnArrayOfObjects() throws {
        let client = try liveClient()
        let containers = try client.jsonArray("GET", "/containers/json", query: [("all", "1")])
        for container in containers {
            XCTAssertNotNil(container["Id"] as? String)
        }
    }

    func testNonExistentContainerRaisesAnEngineErrorNotATransportError() throws {
        // The distinction callers depend on: a 404 is the engine answering, and the
        // message it carries is the one worth showing the user.
        let client = try liveClient()
        do {
            _ = try client.jsonObject("GET", "/containers/morb-no-such-container-xyz/json")
            XCTFail("expected a 404")
        } catch let error as EngineError {
            guard case .engine(let status, let message) = error else {
                return XCTFail("expected .engine, got \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testChunkedStreamingTerminatesWhenTheCallerSaysStop() throws {
        // `/events` never ends on its own. If `stream` only stopped at EOF this would
        // hang the suite, which is exactly the bug the return value exists to prevent.
        let client = try liveClient()
        var sawHead = false
        let started = Date()
        try client.stream(
            "GET", "/events", query: [("since", "0"), ("until", "1")], timeout: 15,
            onChunk: { _, _ in false },
            onHead: { head in
                sawHead = true
                XCTAssertEqual(head.statusCode, 200)
            })
        XCTAssertTrue(sawHead)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }
}

/// Streaming an image tar in and out of a live engine without buffering it in memory.
final class EngineTransferLiveTests: XCTestCase {

    private func liveClient() throws -> EngineClient {
        let client = EngineClient()
        guard FileManager.default.fileExists(atPath: client.socketPath), client.ping() else {
            throw XCTSkip("no engine answering at \(client.socketPath)")
        }
        return client
    }

    /// The smallest image already present, so the test never pulls.
    private func smallestLocalImage(_ client: EngineClient) throws -> String {
        let images = try client.jsonArray("GET", "/images/json")
        let candidates: [(String, Int)] = images.compactMap { image in
            guard let tags = image["RepoTags"] as? [String],
                  let tag = tags.first(where: { $0 != "<none>:<none>" }),
                  let size = JSONRead.int(image, "Size")
            else { return nil }
            return (tag, size)
        }
        guard let smallest = candidates.min(by: { $0.1 < $1.1 })?.0 else {
            throw XCTSkip("no tagged images present to export")
        }
        return smallest
    }

    func testDownloadWritesAnImageTarToDiskAndReportsProgress() throws {
        let client = try liveClient()
        let image = try smallestLocalImage(client)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("morb-engineclient-test-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: destination) }

        var progressCalls = 0
        let result = try client.download(
            "GET", "/images/\(image)/get", to: destination, timeout: 300,
            onProgress: { _ in progressCalls += 1; return true })

        XCTAssertEqual(result.head.statusCode, 200)
        XCTAssertGreaterThan(result.bytes, 1024)
        XCTAssertGreaterThan(progressCalls, 0)
        let onDisk = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
        XCTAssertEqual(onDisk?.int64Value, result.bytes, "the file must hold exactly what was reported")

        // A docker-save tar is a tar: the ustar magic sits at offset 257 of the first
        // header block. This is what distinguishes a real export from a JSON error
        // body that happened to be written to the file.
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 512)
        XCTAssertEqual(String(decoding: header[257..<262], as: UTF8.self), "ustar")
    }

    func testDownloadOfAMissingImageDeletesThePartialFileAndReportsTheEngineError() throws {
        let client = try liveClient()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("morb-engineclient-missing-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertThrowsError(
            try client.download("GET", "/images/morb-no-such-image-xyz:latest/get", to: destination)
        ) { error in
            guard case EngineError.engine(let status, _)? = error as? EngineError else {
                return XCTFail("expected .engine, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a failed export must not leave a file that looks like a successful one")
    }

    func testUploadRoundTripsAnImageBackIntoTheEngine() throws {
        let client = try liveClient()
        let image = try smallestLocalImage(client)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("morb-engineclient-load-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }

        try client.download("GET", "/images/\(image)/get", to: archive, timeout: 300)

        var sentHigh: Int64 = 0
        let response = try client.upload(
            "POST", "/images/load", query: [("quiet", "0")], from: archive, timeout: 600,
            onProgress: { sentHigh = $0 })

        XCTAssertTrue(response.isSuccess, "load failed: \(response.engineMessage)")
        XCTAssertGreaterThan(sentHigh, 0)
        // `docker load` reports what it loaded; the image name must appear in it.
        let shortName = image.split(separator: ":").first.map(String.init) ?? image
        XCTAssertTrue(
            response.text.contains(shortName),
            "load response did not mention \(shortName): \(Format.truncate(response.text, 300))")
    }
}
