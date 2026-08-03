// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Coverage for the MRB0 guest-control framing and the control-socket JSON codec.
final class FramingTests: XCTestCase {

    // MARK: - MRB0

    func testEncodeProducesMagicAndBigEndianLength() throws {
        let payload = Data("{\"type\":\"ping\"}".utf8)
        let frame = try MRB0.encode(payload: payload)

        XCTAssertEqual(frame.count, MRB0.headerSize + payload.count)
        XCTAssertEqual(Array(frame.prefix(4)), Array("MRB0".utf8))

        let lengthBytes = Array(frame[4..<8])
        let length =
            (UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16)
            | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3])
        XCTAssertEqual(Int(length), payload.count)
        XCTAssertEqual(Data(frame.dropFirst(MRB0.headerSize)), payload)
    }

    func testRoundTrip() throws {
        for payload in [Data(), Data("{}".utf8), Data(repeating: 0x41, count: 100_000)] {
            let frame = try MRB0.encode(payload: payload)
            let decoded = try MRB0.decode(from: frame)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.payload, payload)
            XCTAssertEqual(decoded?.consumed, frame.count)
        }
    }

    func testDecodeReturnsNilForPartialFrames() throws {
        let frame = try MRB0.encode(payload: Data("{\"type\":\"info\"}".utf8))
        XCTAssertNil(try MRB0.decode(from: Data()))
        XCTAssertNil(try MRB0.decode(from: frame.prefix(3)))
        XCTAssertNil(try MRB0.decode(from: frame.prefix(MRB0.headerSize)))
        XCTAssertNil(try MRB0.decode(from: frame.dropLast()))
        XCTAssertNotNil(try MRB0.decode(from: frame))
    }

    func testDecodeStopsAtFrameBoundary() throws {
        let first = try MRB0.encode(payload: Data("{\"type\":\"ok\"}".utf8))
        let second = try MRB0.encode(payload: Data("{\"type\":\"pong\",\"uptime_ms\":1}".utf8))
        var buffer = first
        buffer.append(second)

        guard let decoded = try MRB0.decode(from: buffer) else {
            return XCTFail("expected a complete first frame")
        }
        XCTAssertEqual(decoded.consumed, first.count)
        XCTAssertEqual(decoded.payload, Data("{\"type\":\"ok\"}".utf8))

        let rest = Data(buffer.dropFirst(decoded.consumed))
        XCTAssertEqual(try MRB0.decode(from: rest)?.payload, Data(second.dropFirst(MRB0.headerSize)))
    }

    func testBadMagicIsRejected() {
        var frame = Data("XXXX".utf8)
        frame.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try MRB0.decodeHeader(frame)) { error in
            XCTAssertTrue("\(error)".contains("magic"), "\(error)")
        }
    }

    func testShortHeaderIsRejected() {
        XCTAssertThrowsError(try MRB0.decodeHeader(Data("MRB0".utf8)))
    }

    func testEncodingAnOversizePayloadIsRejected() {
        let payload = Data(repeating: 0, count: MRB0.maxPayloadSize + 1)
        XCTAssertThrowsError(try MRB0.encode(payload: payload)) { error in
            XCTAssertTrue("\(error)".contains("cap"), "\(error)")
        }
    }

    func testExactlyMaximumPayloadIsAccepted() throws {
        let payload = Data(repeating: 0x7A, count: MRB0.maxPayloadSize)
        let frame = try MRB0.encode(payload: payload)
        XCTAssertEqual(try MRB0.decodeHeader(frame.prefix(MRB0.headerSize)), MRB0.maxPayloadSize)
    }

    func testHeaderAnnouncingAnOversizePayloadIsRejected() {
        // A hostile or broken guest claims 2 GiB; we must not try to allocate it.
        var header = Data("MRB0".utf8)
        header.append(contentsOf: [0x80, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try MRB0.decodeHeader(header)) { error in
            XCTAssertTrue("\(error)".contains("cap"), "\(error)")
        }
        XCTAssertThrowsError(try MRB0.decode(from: header))
    }

    func testGuestReplyDecoding() throws {
        let pong = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"pong","uptime_ms":4321}"#.utf8))
        XCTAssertEqual(pong.type, "pong")
        XCTAssertEqual(pong.uptimeMilliseconds, 4321)

        let info = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","morbinit_version":"0.1.0-m0","kernel":"Linux 6.12"}"#.utf8))
        XCTAssertEqual(info.morbinitVersion, "0.1.0-m0")
        XCTAssertEqual(info.kernel, "Linux 6.12")

        let ok = try JSONDecoder().decode(GuestReply.self, from: Data(#"{"type":"ok"}"#.utf8))
        XCTAssertEqual(ok.type, "ok")
        XCTAssertNil(ok.message)

        let failure = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"error","message":"nope"}"#.utf8))
        XCTAssertEqual(failure.message, "nope")
    }

    func testGuestRequestEncodingUsesSnakeCaseWireNames() throws {
        let data = try JSONEncoder().encode(GuestRequest(type: "clock_sync", unixNanos: 1_700_000_000_000_000_000))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"unix_nanos\""), text)
        XCTAssertTrue(text.contains("\"clock_sync\""), text)

        let ping = String(decoding: try JSONEncoder().encode(GuestRequest(type: "ping")), as: UTF8.self)
        XCTAssertFalse(ping.contains("unix_nanos"), ping)
    }

    // MARK: - Control socket codec

    func testDaemonRequestLineRoundTrip() throws {
        let request = DaemonRequest(cmd: "stop", args: ["force": "true"])
        let line = try IPCCodec.encodeLine(request)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(try IPCCodec.decodeLine(DaemonRequest.self, from: line), request)
    }

    func testDaemonResponseLineRoundTrip() throws {
        let response = DaemonResponse.success([
            "state": .string("running"),
            "active_connections": .int(3),
            "auto_suspend_minutes": .int(0),
        ])
        let decoded = try IPCCodec.decodeLine(DaemonResponse.self, from: try IPCCodec.encodeLine(response))
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
    }

    func testDaemonFailureRoundTrip() throws {
        let response = DaemonResponse.failure("kernel not found")
        let decoded = try IPCCodec.decodeLine(DaemonResponse.self, from: try IPCCodec.encodeLine(response))
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "kernel not found")
        XCTAssertNil(decoded.errorCode)
    }

    func testStructuredDaemonFailureUsesSnakeCaseErrorCode() throws {
        let response = DaemonResponse.failure("unknown command `future-command`", code: .unknownCommand)
        let decoded = try IPCCodec.decodeLine(DaemonResponse.self, from: try IPCCodec.encodeLine(response))
        XCTAssertEqual(decoded.errorCode, DaemonResponse.ErrorCode.unknownCommand.rawValue)

        let encoded = String(decoding: try IPCCodec.encodeLine(response), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"error_code\""), encoded)
        XCTAssertFalse(encoded.contains("errorCode"), encoded)
    }

    func testDaemonResponseAcceptsLegacyFailureWithoutErrorCode() throws {
        let legacy = try IPCCodec.decodeLine(
            DaemonResponse.self,
            from: Data(#"{"ok":false,"error":"unknown command `k8s-diagnose`"}"#.utf8))
        XCTAssertFalse(legacy.ok)
        XCTAssertNil(legacy.errorCode)
    }

    func testAnyCodableValuePreservesTypes() throws {
        let value = AnyCodableValue.object([
            "b": .bool(true),
            "i": .int(7),
            "d": .double(1.5),
            "s": .string("x"),
            "n": .null,
            "a": .array([.int(1), .bool(false)]),
        ])
        let data = try IPCCodec.makeEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(AnyCodableValue.self, from: data), value)
    }

    func testEmptyControlLineIsRejected() {
        XCTAssertThrowsError(try IPCCodec.decodeLine(DaemonRequest.self, from: Data("\n".utf8)))
        XCTAssertThrowsError(try IPCCodec.decodeLine(DaemonRequest.self, from: Data()))
        XCTAssertThrowsError(try IPCCodec.decodeLine(DaemonRequest.self, from: Data("{nope}\n".utf8)))
    }
}
