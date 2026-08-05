// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Regression tests for the input-validation review of the MCP server
// (docs/audit/INPUT-VALIDATION-REVIEW.md, part 2).

import Foundation
import XCTest

@testable import MorbFeatures
@testable import MorbMCP

final class MCPInputValidationTests: XCTestCase {

    // MARK: - MCP-1: identifiers cannot escape the Engine API request line

    func testEnginePathEncodesEverythingThatCouldEndTheRequestLine() {
        // A container id carrying CRLF used to splice a second, pipelined request
        // into the connection — reachable from `container_inspect`, which needs no
        // grant at all.
        let smuggled = EngineClient.path(
            "/containers/a\r\nX-Injected: 1\r\n\r\nPOST /v1.43/containers/b/kill HTTP/1.1\r\n\r\n/json")
        XCTAssertFalse(smuggled.contains("\r"), "a CR must never reach the request line")
        XCTAssertFalse(smuggled.contains("\n"), "an LF must never reach the request line")
        XCTAssertFalse(smuggled.contains(" "), "a space would terminate the request target")
        XCTAssertTrue(smuggled.contains("%0D%0A"))

        // A `?` in the path used to start a query string ahead of the parameters
        // this call was asked to send. Go returns the *first* value for a repeated
        // parameter, so `container_remove` with `force=0` could be turned into
        // `force=1` — the exact thing the container_remove:force guard gates.
        let injectedQuery = EngineClient.path("/containers/abc?force=1&", query: [("force", "0"), ("v", "0")])
        XCTAssertEqual(injectedQuery, "/v1.43/containers/abc%3Fforce%3D1%26?force=0&v=0")
        XCTAssertEqual(injectedQuery.filter { $0 == "?" }.count, 1, "exactly one query string may be present")
        XCTAssertTrue(injectedQuery.hasSuffix("?force=0&v=0"), "the caller's parameters must be the only ones")
    }

    func testEnginePathLeavesRealDockerIdentifiersIntact() {
        XCTAssertEqual(EngineClient.path("/containers/json"), "/v1.43/containers/json")
        XCTAssertEqual(
            EngineClient.path("/containers/9f2c1ab34dd0/logs"), "/v1.43/containers/9f2c1ab34dd0/logs")
        XCTAssertEqual(
            EngineClient.path("/images/ghcr.io/org/app:1.2.3-rc.1/json"),
            "/v1.43/images/ghcr.io/org/app:1.2.3-rc.1/json")
        XCTAssertEqual(
            EngineClient.path("/images/app@sha256:abc123/json"), "/v1.43/images/app@sha256:abc123/json")
        XCTAssertEqual(
            EngineClient.path("/volumes/my_project_db-data"), "/v1.43/volumes/my_project_db-data")
        // Query encoding is unchanged by the path fix.
        XCTAssertEqual(
            EngineClient.path("/containers/json", query: [("filters", #"{"status":["running"]}"#)]),
            "/v1.43/containers/json?filters=%7B%22status%22%3A%5B%22running%22%5D%7D")
    }

    // MARK: - MCP-1 second layer: identifier grammar

    func testContainerIdentifierRejectsAnythingThatIsNotOne() throws {
        XCTAssertEqual(try Identifier.container("9f2c1ab34dd0", field: "id"), "9f2c1ab34dd0")
        XCTAssertEqual(try Identifier.container("web-1", field: "id"), "web-1")
        XCTAssertEqual(try Identifier.container("/web_1.a", field: "id"), "/web_1.a")

        for bad in [
            "", "a b", "a\r\nb", "a?force=1", "web/json", "a#b", "a%2f", "-leading", "..",
            String(repeating: "a", count: 256),
        ] {
            XCTAssertThrowsError(try Identifier.container(bad, field: "id"), "accepted `\(bad)`")
        }
    }

    func testImageReferenceAllowsRealReferencesAndNothingElse() throws {
        for good in ["nginx", "nginx:latest", "ghcr.io/org/app:1.2.3", "app@sha256:0123abcd", "host:5000/a/b"] {
            XCTAssertEqual(try Identifier.imageReference(good, field: "reference"), good)
        }
        for bad in ["", "/leading", "a b", "a\r\nb", "nginx?x=1", "nginx#tag", "a%0d", String(repeating: "a", count: 513)] {
            XCTAssertThrowsError(try Identifier.imageReference(bad, field: "reference"), "accepted `\(bad)`")
        }
    }

    func testIdentifierErrorsNeverEchoARawControlByte() {
        do {
            _ = try Identifier.container("web\u{07}1", field: "id")
            XCTFail("a BEL is not a container id character")
        } catch let error as ArgError {
            XCTAssertTrue(error.description.contains("U+0007"), error.description)
            XCTAssertFalse(error.description.contains("\u{07}"), "the raw byte must not reach the transcript")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - The ungated tool surface

    func testOnlyReadOnlyToolsAreReachableWithoutAGrant() {
        // `PermissionProfile.decide` returns "allowed" for any tool whose group is
        // nil. That is what makes the zero-config case useful, and it is also the
        // one way a future mutating tool could become reachable with no grant: by
        // being registered without a group. Pin both halves.
        let emptyProfile = PermissionProfile(allow: [], deny: [])
        let ungated = ToolRegistry.all.filter { emptyProfile.decide($0.permissionSubject).allowed }

        XCTAssertEqual(
            Set(ungated.map(\.name)),
            [
                "containers_list", "container_inspect", "container_logs", "images_list",
                "volumes_list", "networks_list", "disk_usage", "engine_status", "events_subscribe",
            ],
            "the set of tools reachable with an empty profile changed")

        for tool in ungated {
            XCTAssertTrue(tool.readOnly, "\(tool.name) is reachable without a grant but is not read-only")
            XCTAssertFalse(tool.destructive, "\(tool.name) is reachable without a grant but is destructive")
        }
        for tool in ToolRegistry.all where !tool.readOnly {
            XCTAssertNotNil(tool.group, "\(tool.name) mutates but has no permission group, so nothing gates it")
            XCTAssertFalse(
                emptyProfile.decide(tool.permissionSubject).allowed, "\(tool.name) runs with no grant")
        }
        XCTAssertEqual(
            ToolRegistry.all.count, ToolRegistry.byName.count, "two tools share a name")
    }

    func testEveryGuardKeyIsAKnownPermissionKey() {
        // A guard whose key is not in `knownKeys` can never be granted without
        // `morb mcp permissions` calling the grant a typo.
        let known = ToolRegistry.knownKeys
        for tool in ToolRegistry.all {
            for guardSpec in tool.guards {
                XCTAssertTrue(known.contains(guardSpec.key), "\(guardSpec.key) is not a grantable key")
            }
        }
    }

    // MARK: - Audit completeness

    func testToolCallRejectedBeforeInitializeIsStillAudited() throws {
        let (server, audit) = try makeServer()
        let response = server.handle(request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"container_remove","arguments":{"id":"web","force":true}}}"#))
        XCTAssertTrue(response?.contains("-32600") == true, "the call must still be refused")

        let records = audit.readAll()
        XCTAssertEqual(records.count, 1, "a refused tool call must leave a record")
        XCTAssertEqual(records[0]["tool"] as? String, "container_remove")
        XCTAssertEqual(records[0]["decision"] as? String, "denied")
    }

    func testToolCallSentAsANotificationIsAudited() throws {
        let (server, audit) = try makeServer()
        XCTAssertNil(server.handle(request(#"{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)))
        XCTAssertNil(
            server.handle(request(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"prune","arguments":{"targets":["volumes"]}}}"#)),
            "a notification must not produce a response")

        let records = audit.readAll()
        XCTAssertEqual(records.map { $0["tool"] as? String }, ["prune"])
        XCTAssertEqual(records[0]["decision"] as? String, "denied")
    }

    func testDeniedMutatingCallIsAuditedWithItsArgumentsRedacted() throws {
        let (server, audit) = try makeServer()
        _ = server.handle(request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let response = server.handle(request(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"container_exec","arguments":{"id":"web","cmd":["env"],"env":{"AWS_SECRET_ACCESS_KEY":"hunter2"}}}}"#))
        XCTAssertTrue(response?.contains("is not allowed") == true, response ?? "<nil>")

        let records = audit.readAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["decision"] as? String, "denied")
        let rendered = JSONRead.compact(records[0])
        XCTAssertFalse(rendered.contains("hunter2"), "an env value must never reach the audit log")
        XCTAssertTrue(rendered.contains("[redacted]"))
    }

    // MARK: - JSON-RPC framing

    func testDeeplyNestedJSONIsRejectedRatherThanParsed() {
        // 200k open brackets fits inside the 1 MiB line cap. Foundation rejects it
        // instead of recursing, which is what keeps the cap sufficient on its own.
        let line = String(repeating: "[", count: 200_000)
        guard case .parseError = JSONRPCCodec.parseLine(line) else {
            return XCTFail("a 200k-deep array must be a parse error")
        }
    }

    func testOversizeLineIsDiscardedWithoutBufferingTheWholeThing() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("input")
        var payload = Data(repeating: 0x41, count: MCPServer.maximumMessageBytes + 4_096)
        payload.append(0x0A)
        payload.append(contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        payload.append(0x0A)
        try payload.write(to: file)

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let reader = MCPStdioLineReader(input: handle)

        guard case .tooLong = reader.next() else { return XCTFail("the oversize line must be refused") }
        guard case .line(let recovered) = reader.next() else {
            return XCTFail("the reader must resynchronise on the next newline")
        }
        XCTAssertEqual(recovered, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        guard case .endOfFile = reader.next() else { return XCTFail("expected EOF") }
    }

    // MARK: - Helpers

    private func request(_ line: String) -> JSONRPCRequest {
        guard case .request(let parsed) = JSONRPCCodec.parseLine(line) else {
            fatalError("test fixture is not a valid JSON-RPC request: \(line)")
        }
        return parsed
    }

    /// A server with an empty (fully read-only) profile and a throwaway audit log.
    /// No tool that reaches the engine is invoked by these tests.
    private func makeServer() throws -> (MCPServer, AuditLog) {
        let directory = try temporaryDirectory()
        let audit = try AuditLog(url: directory.appendingPathComponent("mcp-audit.jsonl"))
        let context = ToolContext(engine: EngineClient(socketPath: directory.appendingPathComponent("nonexistent.sock").path))
        return (MCPServer(profile: PermissionProfile(allow: [], deny: []), context: context, audit: audit), audit)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-input-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
