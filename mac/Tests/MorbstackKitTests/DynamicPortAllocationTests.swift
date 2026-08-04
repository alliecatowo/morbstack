// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackKit

/// Offline coverage for the bounded Phase 1 TCP/UDP create rewrite. These tests deliberately
/// contain no VM, Docker Engine, or real listener assertions; the live allocation
/// contract remains a separately opted-in integration check.
final class DynamicPortAllocationTests: XCTestCase {

    func testExplicitEmptyTCPHostPortBecomesTheHeldConcretePort() throws {
        let body = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":""}]}}}"#.utf8)

        guard case .supported(let plan) = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: body) else {
            return XCTFail("an explicit empty TCP HostPort must enter the bounded transaction")
        }
        XCTAssertEqual(
            plan.requestedPublications,
            [DockerDynamicPortPublication(
                transport: .tcp, hostIP: "127.0.0.1", hostPort: 0, containerPort: 80)])

        let rewritten = try plan.rewrittenBody(with: [
            DockerDynamicPortPublication(
                transport: .tcp, hostIP: "127.0.0.1", hostPort: 49152, containerPort: 80)
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let bindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        let tcp = try XCTUnwrap(bindings["80/tcp"] as? [[String: Any]])
        XCTAssertEqual(tcp.first?["HostPort"] as? String, "49152")
    }

    func testDynamicAllocatorDefersPublishAllPortsAndAdmitsDynamicUDP() throws {
        let publishAll = Data(#"{"HostConfig":{"PublishAllPorts":true}}"#.utf8)
        guard case .notDynamic = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: publishAll)
        else {
            return XCTFail("-P must bypass the create-time rewrite and reach patched Moby")
        }

        let udp = Data(#"{"HostConfig":{"PortBindings":{"53/udp":[{"HostPort":""}]}}}"#.utf8)
        guard case .supported(let udpPlan) = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: udp) else {
            return XCTFail("dynamic UDP must enter the held datagram lease transaction")
        }
        XCTAssertEqual(
            udpPlan.requestedPublications,
            [DockerDynamicPortPublication(
                transport: .udp, hostIP: "", hostPort: 0, containerPort: 53)])
        let rewritten = try udpPlan.rewrittenBody(with: [
            DockerDynamicPortPublication(
                transport: .udp, hostIP: "", hostPort: 49153, containerPort: 53)
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let bindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        let dynamicUDP = try XCTUnwrap(bindings["53/udp"] as? [[String: Any]])
        XCTAssertEqual(dynamicUDP.first?["HostPort"] as? String, "49153")
    }

    func testDynamicAllocatorKeepsFixedUDPSiblingsInTheSameLease() {
        let body = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}],"53/udp":[{"HostPort":""}]}}}"#.utf8)
        guard case .supported(let plan) = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: body) else {
            return XCTFail("mixed fixed TCP plus dynamic UDP must remain one held lease")
        }
        XCTAssertEqual(
            plan.fixedPlan,
            DockerFixedPortLeasePlan(
                tcp: [DockerExplicitTCPPortBinding(hostIP: "", hostPort: 8080, containerPort: 80)],
                udp: []))
        XCTAssertEqual(
            plan.requestedPublications,
            [DockerDynamicPortPublication(
                transport: .udp, hostIP: "", hostPort: 0, containerPort: 53)])
    }

    func testDynamicAllocatorTakesARangeSiblingAndLeavesOrdinaryFixedRequestsAlone() {
        // A range sibling used to be rejected outright ("not a single port"). The
        // host-first allocator that landed later takes it instead: the range keeps
        // its exact spelling in the plan and is rewritten to whichever port the host
        // atomically held. Pinning the current contract, deliberately, rather than
        // the superseded refusal.
        let range = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":""}],"81/tcp":[{"HostPort":"4000-4001"}]}}}"#.utf8)
        guard case .supported(let plan) = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: range) else {
            return XCTFail("a dynamic request with a range sibling belongs to the host-first allocator")
        }
        XCTAssertEqual(plan.fixedPlan, DockerFixedPortLeasePlan(tcp: [], udp: []))
        XCTAssertEqual(plan.requestedPublications.map(\.containerPort), [80, 81])
        XCTAssertEqual(
            plan.requestedPublications.map(\.requestedHostPortRange?.stringValue),
            [nil, "4000-4001"])

        let fixed = Data(#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#.utf8)
        guard case .notDynamic = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: fixed) else {
            return XCTFail("fixed TCP must keep the existing passive lease path")
        }
    }

    func testContentLengthRewritePreservesTheOtherHeadBytes() throws {
        let original = Data(
            "POST /v1.47/containers/create HTTP/1.1\r\nX-Test: original\r\ncontent-length: 12\r\n\r\n".utf8)
        let rewritten = try XCTUnwrap(
            HTTPRequestHeadRewriting.replacingContentLength(in: original, bodyLength: 345))
        XCTAssertEqual(
            String(decoding: rewritten, as: UTF8.self),
            "POST /v1.47/containers/create HTTP/1.1\r\nX-Test: original\r\nContent-Length: 345\r\n\r\n")
    }

    func testContentLengthRewriteRefusesDuplicateOrAbsentHeaders() {
        let duplicate = Data("POST / HTTP/1.1\nContent-Length: 1\nContent-Length: 1\n\n".utf8)
        let absent = Data("POST / HTTP/1.1\n\n".utf8)
        XCTAssertNil(HTTPRequestHeadRewriting.replacingContentLength(in: duplicate, bodyLength: 1))
        XCTAssertNil(HTTPRequestHeadRewriting.replacingContentLength(in: absent, bodyLength: 1))
    }
}
