// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the log stream's demultiplexer.
//
// This is the piece most worth testing in the whole app. It is the only place that
// parses a binary framing by hand, it runs against bytes the app does not control, and
// when it is wrong the symptom is not a crash but *subtly corrupted logs* — which is the
// one failure a debugging tool must never have, because the user will believe them.

import Foundation
import XCTest

@testable import MorbstackAppCore

final class StdcopyTests: XCTestCase {

    // MARK: - Helpers

    /// Builds one stdcopy frame: `[stream:1][pad:3][length:4 big-endian][payload]`.
    private func frame(_ stream: UInt8, _ text: String) -> Data {
        let payload = Data(text.utf8)
        var data = Data([stream, 0, 0, 0])
        let length = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ])
        data.append(payload)
        return data
    }

    private func text(_ frames: [StdcopyDemuxer.Frame]) -> [String] {
        frames.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    // MARK: - Multiplexed

    func testDecodesASingleStdoutFrame() {
        var demuxer = StdcopyDemuxer()
        let frames = demuxer.feed(frame(1, "hello\n"))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.stream, .stdout)
        XCTAssertEqual(text(frames), ["hello\n"])
        XCTAssertEqual(demuxer.resolvedMode, .multiplexed)
    }

    func testSeparatesStdoutFromStderr() {
        var demuxer = StdcopyDemuxer()
        var data = frame(1, "out")
        data.append(frame(2, "err"))
        let frames = demuxer.feed(data)

        XCTAssertEqual(frames.map(\.stream), [.stdout, .stderr])
        XCTAssertEqual(text(frames), ["out", "err"])
    }

    /// Stream byte 0 is stdin, which the engine does use for an attached stream; it is
    /// output the user typed, so it belongs on stdout rather than being dropped.
    func testTreatsStreamZeroAsStdout() {
        var demuxer = StdcopyDemuxer()
        XCTAssertEqual(demuxer.feed(frame(0, "typed")).first?.stream, .stdout)
    }

    func testDecodesSeveralFramesFromOneRead() {
        var demuxer = StdcopyDemuxer()
        var data = Data()
        for index in 0..<5 { data.append(frame(1, "line \(index)\n")) }

        XCTAssertEqual(
            text(demuxer.feed(data)),
            ["line 0\n", "line 1\n", "line 2\n", "line 3\n", "line 4\n"])
    }

    /// The case that actually happens on a busy socket: a frame straddles two reads.
    func testReassemblesAPayloadSplitAcrossReads() {
        var demuxer = StdcopyDemuxer()
        let whole = frame(1, "a longer line of output\n")
        let split = whole.count / 2

        XCTAssertEqual(demuxer.feed(whole.prefix(split)), [])
        XCTAssertEqual(text(demuxer.feed(whole.suffix(from: split))), ["a longer line of output\n"])
    }

    /// The nastier version: the 8-byte header itself is split, so the mode cannot even
    /// be decided on the first read.
    func testReassemblesAHeaderSplitAcrossReads() {
        var demuxer = StdcopyDemuxer()
        let whole = frame(2, "boom")

        XCTAssertEqual(demuxer.feed(whole.prefix(3)), [])
        XCTAssertEqual(demuxer.feed(whole.subdata(in: 3..<6)), [])
        let frames = demuxer.feed(whole.suffix(from: 6))
        XCTAssertEqual(text(frames), ["boom"])
        XCTAssertEqual(frames.first?.stream, .stderr)
    }

    /// A keepalive frame carries no payload and must not produce an empty log line.
    func testDropsZeroLengthFrames() {
        var demuxer = StdcopyDemuxer()
        var data = frame(1, "")
        data.append(frame(1, "real"))

        XCTAssertEqual(text(demuxer.feed(data)), ["real"])
    }

    func testHandlesAPayloadLargerThanOneRead() {
        var demuxer = StdcopyDemuxer()
        let big = String(repeating: "x", count: 200_000)
        let whole = frame(1, big)

        var collected: [StdcopyDemuxer.Frame] = []
        var cursor = 0
        while cursor < whole.count {
            let end = min(cursor + 16_384, whole.count)
            collected += demuxer.feed(whole.subdata(in: cursor..<end))
            cursor = end
        }
        XCTAssertEqual(collected.map(\.bytes).reduce(Data(), +).count, big.utf8.count)
    }

    // MARK: - Raw (TTY)

    func testFallsBackToRawForTTYOutput() {
        var demuxer = StdcopyDemuxer()
        let frames = demuxer.feed(Data("plain tty output\n".utf8))

        XCTAssertEqual(demuxer.resolvedMode, .raw)
        XCTAssertEqual(frames.first?.stream, .stdout)
        XCTAssertEqual(text(frames), ["plain tty output\n"])
    }

    /// A short first read whose bytes already disagree with the header shape must not
    /// hold the output hostage waiting for a header that will never come — an
    /// interactive shell's prompt arrives as a handful of bytes with no newline.
    func testCommitsToRawOnAShortNonHeaderPrefix() {
        var demuxer = StdcopyDemuxer()
        let frames = demuxer.feed(Data("$ ".utf8))

        XCTAssertEqual(demuxer.resolvedMode, .raw)
        XCTAssertEqual(text(frames), ["$ "])
    }

    /// Once raw, always raw: a later run of bytes that happens to look like a header
    /// must not flip the mode and start eating eight bytes out of the output.
    func testDoesNotSwitchModesMidStream() {
        var demuxer = StdcopyDemuxer()
        _ = demuxer.feed(Data("tty\n".utf8))
        let frames = demuxer.feed(frame(1, "not a frame"))

        XCTAssertEqual(demuxer.resolvedMode, .raw)
        // The header bytes come through as literal output, which is the correct
        // behaviour for a raw stream — nothing is silently swallowed.
        XCTAssertEqual(frames.first?.bytes.count, 8 + "not a frame".utf8.count)
    }

    func testFinishFlushesATrailingRawPartial() {
        var demuxer = StdcopyDemuxer()
        _ = demuxer.feed(Data("no trailing newline".utf8))
        // Raw output is emitted as it arrives, so nothing is held back.
        XCTAssertEqual(demuxer.finish(), [])
    }

    /// A truncated multiplexed frame is genuinely unusable — half a payload is not half
    /// a line, it is corrupt — so it is dropped rather than emitted as garbage.
    func testFinishDiscardsATruncatedMultiplexedFrame() {
        var demuxer = StdcopyDemuxer()
        let whole = frame(1, "incomplete payload")
        _ = demuxer.feed(whole.prefix(12))

        XCTAssertEqual(demuxer.finish(), [])
    }

    // MARK: - Header sniffing

    func testHeaderRecognition() {
        XCTAssertTrue(StdcopyDemuxer.looksLikeHeader([1, 0, 0, 0, 0, 0, 0, 5]))
        XCTAssertTrue(StdcopyDemuxer.looksLikeHeader([2, 0, 0, 0, 0, 0, 1, 0]))
        // Stream byte out of range.
        XCTAssertFalse(StdcopyDemuxer.looksLikeHeader([3, 0, 0, 0, 0, 0, 0, 5]))
        // Padding not zero — this is what ordinary text looks like.
        XCTAssertFalse(StdcopyDemuxer.looksLikeHeader(Array("hello wo".utf8)))
        // Too short to decide.
        XCTAssertFalse(StdcopyDemuxer.looksLikeHeader([1, 0, 0, 0]))
    }
}

// MARK: - Line assembly

final class LogLineAssemblerTests: XCTestCase {

    private func frame(_ text: String, _ stream: StdStream = .stdout) -> StdcopyDemuxer.Frame {
        StdcopyDemuxer.Frame(stream: stream, bytes: Data(text.utf8))
    }

    func testSplitsOnNewlinesAndHoldsThePartialTail() {
        var assembler = LogLineAssembler(parseTimestamps: false)

        let first = assembler.consume(frame("one\ntwo\nthr"))
        XCTAssertEqual(first.map(\.text), ["one", "two"])

        let second = assembler.consume(frame("ee\n"))
        XCTAssertEqual(second.map(\.text), ["three"])
    }

    /// Blank lines are printed on purpose — dropping them makes a stack trace unreadable.
    func testKeepsBlankLines() {
        var assembler = LogLineAssembler(parseTimestamps: false)
        XCTAssertEqual(assembler.consume(frame("a\n\nb\n")).map(\.text), ["a", "", "b"])
    }

    /// stdout and stderr each need their own partial tail, or an interleaved write
    /// splices two half-lines into one wrong line.
    func testKeepsPartialsPerStream() {
        var assembler = LogLineAssembler(parseTimestamps: false)

        XCTAssertEqual(assembler.consume(frame("out-par", .stdout)).count, 0)
        XCTAssertEqual(assembler.consume(frame("err-par", .stderr)).count, 0)

        XCTAssertEqual(assembler.consume(frame("t\n", .stdout)).map(\.text), ["out-part"])
        XCTAssertEqual(assembler.consume(frame("t\n", .stderr)).map(\.text), ["err-part"])
    }

    func testIDsAreUniqueAndMonotonic() {
        var assembler = LogLineAssembler(parseTimestamps: false)
        let lines = assembler.consume(frame("a\nb\nc\n")) + assembler.consume(frame("d\n"))
        XCTAssertEqual(lines.map(\.id), [0, 1, 2, 3])
    }

    func testFlushEmitsAnUnterminatedFinalLine() {
        var assembler = LogLineAssembler(parseTimestamps: false)
        _ = assembler.consume(frame("dangling"))

        XCTAssertEqual(assembler.flush().map(\.text), ["dangling"])
        XCTAssertEqual(assembler.flush(), [])
    }

    func testStripsCarriageReturns() {
        var assembler = LogLineAssembler(parseTimestamps: false)
        XCTAssertEqual(assembler.consume(frame("windows\r\n")).map(\.text), ["windows"])
    }

    // MARK: Timestamps

    func testParsesDockersNanosecondTimestamps() {
        let (date, remainder) = LogLineAssembler.splitTimestamp(
            "2026-03-12T09:41:22.418913274Z hello world")

        XCTAssertEqual(remainder, "hello world")
        XCTAssertNotNil(date)
        // Nine fractional digits truncated to three: .418, not .418913274.
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_773_308_482.418, accuracy: 0.002)
    }

    func testParsesATimestampWithoutAFraction() {
        let (date, remainder) = LogLineAssembler.splitTimestamp("2026-03-12T09:41:22Z msg")
        XCTAssertNotNil(date)
        XCTAssertEqual(remainder, "msg")
    }

    /// A line that is not timestamped must come through unchanged rather than losing
    /// its first word.
    func testLeavesAnUntimestampedLineAlone() {
        let (date, remainder) = LogLineAssembler.splitTimestamp("INFO starting up")
        XCTAssertNil(date)
        XCTAssertEqual(remainder, "INFO starting up")
    }

    func testLeavesALineWithNoSpaceAlone() {
        let (date, remainder) = LogLineAssembler.splitTimestamp("solid")
        XCTAssertNil(date)
        XCTAssertEqual(remainder, "solid")
    }
}
