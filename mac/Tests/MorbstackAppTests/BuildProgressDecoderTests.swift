// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackAppCore

/// Pure Buildx-stream coverage. Nothing here starts Docker, Buildx, an engine, or a
/// process; it only keeps the UI from inventing a percent or losing an actual failure.
final class BuildProgressDecoderTests: XCTestCase {

    func testUsesObservedBuildxDetailInsteadOfInventingProgress() throws {
        let event = try XCTUnwrap(BuildProgressDecoder.event(
            line: #"{"id":"load","status":"START","detail":"load build definition"}"#,
            sequence: 4))
        XCTAssertEqual(event.sequence, 4)
        XCTAssertEqual(event.identifier, "load")
        XCTAssertEqual(event.message, "load build definition")
        XCTAssertFalse(event.isError)
    }

    func testPreservesARealBuildxErrorForRecovery() throws {
        let event = try XCTUnwrap(BuildProgressDecoder.event(
            line: #"{"id":"compile","error":"executor failed running [/bin/sh -c make]: exit code: 2"}"#,
            sequence: 9))
        XCTAssertEqual(event.identifier, "compile")
        XCTAssertTrue(event.isError)
        XCTAssertEqual(event.message, "executor failed running [/bin/sh -c make]: exit code: 2")
    }

    func testKeepsAPlainDiagnosticLineWhenBuildxCannotEncodeIt() throws {
        let event = try XCTUnwrap(BuildProgressDecoder.event(
            line: "failed to resolve build context",
            sequence: 2))
        XCTAssertNil(event.identifier)
        XCTAssertEqual(event.message, "failed to resolve build context")
    }
}
