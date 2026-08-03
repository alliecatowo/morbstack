// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbMCP

final class MCPProtocolTests: XCTestCase {

    func testJSONRPCRejectsBooleanAndObjectIDsWithoutEchoingThem() {
        let boolean = JSONRPCCodec.parseLine(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)
        guard case .invalidRequest(_, let booleanID, let booleanHasID) = boolean else {
            return XCTFail("a Boolean is not a valid JSON-RPC id")
        }
        XCTAssertTrue(booleanHasID)
        XCTAssertTrue(booleanID is NSNull, "invalid ids must be replaced with JSON null in errors")

        let object = JSONRPCCodec.parseLine(#"{"jsonrpc":"2.0","id":{"bad":"id"},"method":"ping"}"#)
        guard case .invalidRequest(_, let objectID, let objectHasID) = object else {
            return XCTFail("an object is not a valid JSON-RPC id")
        }
        XCTAssertTrue(objectHasID)
        XCTAssertTrue(objectID is NSNull)
    }

    func testPermissionProfileStaysReadOnlyUntilAnExplicitGrant() throws {
        let config = try MCPConfigFile.parse("""
        allow = ["containers:write"]
        deny = ["container_remove"]
        """)
        let profile = PermissionProfile.build(
            configAllow: config.allow, configDeny: config.deny, cliAllow: [],
            knownKeys: ["containers:write", "container_remove", "containers_list", "all"])

        let readOnly = PermissionSubject(name: "containers_list", group: nil)
        XCTAssertTrue(profile.decide(readOnly).allowed)

        let start = PermissionSubject(name: "container_start", group: .containersWrite)
        XCTAssertTrue(profile.decide(start).allowed)

        let remove = PermissionSubject(name: "container_remove", group: .containersWrite)
        XCTAssertFalse(profile.decide(remove).allowed, "an explicit deny must override a group grant")
    }
}
