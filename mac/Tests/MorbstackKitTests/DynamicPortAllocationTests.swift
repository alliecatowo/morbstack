// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackKit

/// Offline coverage for the bounded Phase 1 create rewrite. These tests deliberately
/// contain no VM, Docker Engine, or real listener assertions; the live allocation
/// contract remains a separately opted-in integration check.
final class DynamicPortAllocationTests: XCTestCase {

    func testExplicitEmptyTCPHostPortBecomesTheHeldConcretePort() throws {
        let body = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":""}]}}}"#.utf8)

        guard case .supported(let plan) = DockerPortPublicationPreflight.dynamicTCPCreatePlan(in: body) else {
            return XCTFail("an explicit empty TCP HostPort must enter the bounded transaction")
        }
        XCTAssertEqual(
            plan.requestedPublications,
            [DockerExplicitTCPPortBinding(hostIP: "127.0.0.1", hostPort: 0, containerPort: 80)])

        let rewritten = try plan.rewrittenBody(with: [
            DockerExplicitTCPPortBinding(hostIP: "127.0.0.1", hostPort: 49152, containerPort: 80)
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let bindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        let tcp = try XCTUnwrap(bindings["80/tcp"] as? [[String: Any]])
        XCTAssertEqual(tcp.first?["HostPort"] as? String, "49152")
    }

    func testDynamicAllocatorRejectsPublishAllPortsAndNonTCP() {
        let publishAll = Data(#"{"HostConfig":{"PublishAllPorts":true}}"#.utf8)
        guard case .rejected(let publishAllMessage) =
            DockerPortPublicationPreflight.dynamicTCPCreatePlan(in: publishAll)
        else {
            return XCTFail("-P must not silently enter the empty-TCP transaction")
        }
        XCTAssertTrue(publishAllMessage.contains("PublishAllPorts"))

        let udp = Data(#"{"HostConfig":{"PortBindings":{"53/udp":[{"HostPort":""}]}}}"#.utf8)
        guard case .rejected(let udpMessage) = DockerPortPublicationPreflight.dynamicTCPCreatePlan(in: udp) else {
            return XCTFail("dynamic UDP needs its own held datagram lease")
        }
        XCTAssertTrue(udpMessage.contains("UDP"))
    }

    func testDynamicAllocatorRejectsRangesAndLeavesOrdinaryFixedRequestsAlone() {
        let range = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":""}],"81/tcp":[{"HostPort":"4000-4001"}]}}}"#.utf8)
        guard case .rejected(let rangeMessage) = DockerPortPublicationPreflight.dynamicTCPCreatePlan(in: range) else {
            return XCTFail("a dynamic request with a range sibling is not bounded")
        }
        XCTAssertTrue(rangeMessage.contains("not a single port"))

        let fixed = Data(#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#.utf8)
        guard case .notDynamic = DockerPortPublicationPreflight.dynamicTCPCreatePlan(in: fixed) else {
            return XCTFail("fixed TCP must keep the existing passive lease path")
        }
    }

    func testContentLengthRewritePreservesTheOtherHeadBytes() throws {
        let original = Data(
            "POST /v1.47/containers/create HTTP/1.1\r\nX-Test: original\r\ncontent-length: 12\r\n\r\n".utf8)
        let rewritten = try XCTUnwrap(
            DockerDynamicCreateTransaction.rewritingContentLength(in: original, bodyLength: 345))
        XCTAssertEqual(
            String(decoding: rewritten, as: UTF8.self),
            "POST /v1.47/containers/create HTTP/1.1\r\nX-Test: original\r\nContent-Length: 345\r\n\r\n")
    }

    func testContentLengthRewriteRefusesDuplicateOrAbsentHeaders() {
        let duplicate = Data("POST / HTTP/1.1\nContent-Length: 1\nContent-Length: 1\n\n".utf8)
        let absent = Data("POST / HTTP/1.1\n\n".utf8)
        XCTAssertNil(DockerDynamicCreateTransaction.rewritingContentLength(in: duplicate, bodyLength: 1))
        XCTAssertNil(DockerDynamicCreateTransaction.rewritingContentLength(in: absent, bodyLength: 1))
    }
}
