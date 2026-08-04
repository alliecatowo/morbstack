// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// Focused coverage for the `docker run -P` lease boundary.
///
/// These tests use only kernel-selected loopback ports. They never start a VM or
/// contact Docker, but they do prove the listener ledger's all-or-nothing reuse
/// and release behavior that the guest's durable allocation session relies on.
final class PublishAllPortAllocatorTests: XCTestCase {

    private var home: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["MORBSTACK_HOME"]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-publish-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("MORBSTACK_HOME", directory.path, 1)
        guard MorbPaths.root.path == directory.path else {
            try? FileManager.default.removeItem(at: directory)
            throw XCTSkip("MORBSTACK_HOME override did not take; refusing to touch the real home")
        }
        home = directory
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        if let previousHome {
            setenv("MORBSTACK_HOME", previousHome, 1)
        } else {
            unsetenv("MORBSTACK_HOME")
        }
        previousHome = nil
    }

    private func makeForwarder() -> PortForwarder {
        PortForwarder(
            vm: VMManager(config: MorbConfig(), log: MorbLog(fileURL: nil, echoToStderr: false)),
            log: MorbLog(fileURL: nil, echoToStderr: false))
    }

    private func request(
        _ transport: DockerDynamicPortTransport,
        containerPort: Int,
        hostPort: Int = 0
    ) -> DockerPublishAllPortRequest {
        DockerPublishAllPortRequest(
            transport: transport,
            hostIP: "127.0.0.1",
            requestedHostPort: hostPort,
            containerPort: containerPort)
    }

    private func containerID(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func makeSession(
        containerID: String,
        remainsAvailableForRestartPolicy: Bool
    ) throws -> (session: PublishAllPortAllocator.Session, peerFD: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw XCTSkip("socketpair() failed")
        }
        return (
            PublishAllPortAllocator.Session(
                fd: descriptors[0],
                containerID: containerID,
                forwarder: makeForwarder(),
                log: MorbLog(fileURL: nil, echoToStderr: false),
                remainsAvailableForRestartPolicy: remainsAvailableForRestartPolicy),
            descriptors[1])
    }

    func testPublishAllAllocationReturnsPortsInRequestOrderAndRequiresFreshRestartAllocation() throws {
        let containerID = containerID("a")
        let forwarder = makeForwarder()
        defer { forwarder.releaseLease(forContainerID: containerID, reason: "test cleanup") }

        let ports = try forwarder.reservePublishAllPorts(
            containerID: containerID,
            requests: [
                request(.tcp, containerPort: 80),
                request(.udp, containerPort: 53),
            ])

        XCTAssertEqual(ports.count, 2)
        XCTAssertTrue(ports.allSatisfy { (1...65_535).contains($0) })
        XCTAssertTrue(
            forwarder.requiresPublishAllAllocator(containerIdentifier: containerID),
            "a -P lease must be retired and reallocated for the next Engine start")
    }

    func testPublishAllAllocationReleasesThePreviousWholeLeaseBeforeReusingItsEndpoints() throws {
        let containerID = containerID("b")
        let forwarder = makeForwarder()
        defer { forwarder.releaseLease(forContainerID: containerID, reason: "test cleanup") }

        let first = try forwarder.reservePublishAllPorts(
            containerID: containerID,
            requests: [
                request(.tcp, containerPort: 80),
                request(.udp, containerPort: 53),
            ])

        // Reusing the exact returned TCP and UDP ports would fail if the prior
        // aggregate lease were not fully released before Moby's next -P start.
        let second = try forwarder.reservePublishAllPorts(
            containerID: containerID,
            requests: [
                request(.tcp, containerPort: 80, hostPort: first[0]),
                request(.udp, containerPort: 53, hostPort: first[1]),
            ])

        XCTAssertEqual(second, first)
        XCTAssertNotNil(
            forwarder.claimStartLease(containerIdentifier: containerID),
            "the replacement allocation must remain associated with the immutable container ID")
    }

    func testReleasingPublishAllLeaseMakesItsTCPPortImmediatelyReusable() throws {
        let containerID = containerID("c")
        let forwarder = makeForwarder()
        let port = try forwarder.reservePublishAllPorts(
            containerID: containerID,
            requests: [request(.tcp, containerPort: 80)]).first!

        forwarder.releaseLease(forContainerID: containerID, reason: "container stopped")

        let rebound = TCPListener(
            port: port,
            queue: DispatchQueue(label: "test.publish-all.rebound"),
            hostAddress: .ipv4("127.0.0.1"))
        XCTAssertNoThrow(try rebound.start(), "a stopped -P container must not retain its host port")
        rebound.stop()
    }

    func testDirectPublishAllSessionEndsAfterItsObservedStart() throws {
        let pair = try makeSession(
            containerID: containerID("d"),
            remainsAvailableForRestartPolicy: false)
        defer { close(pair.peerFD) }

        XCTAssertTrue(pair.session.isLive)
        pair.session.complete(succeeded: true)
        XCTAssertFalse(
            pair.session.isLive,
            "a direct DockerProxy start must not survive into restart-policy reconciliation")
    }

    func testOnlyRecoveryCreatedPublishAllSessionRemainsDurableAfterStart() throws {
        let pair = try makeSession(
            containerID: containerID("e"),
            remainsAvailableForRestartPolicy: true)
        defer {
            pair.session.invalidate(reason: "test cleanup")
            close(pair.peerFD)
        }

        pair.session.complete(succeeded: true)
        XCTAssertTrue(
            pair.session.isLive,
            "restart-policy recovery owns the sole durable publish-all session type")
    }

    func testRegistrationGrammarRetainsLegacyFormAndAddsOnlyTheTraceExtension() {
        let containerID = containerID("f")
        let traceID = String(repeating: "e", count: 32)

        XCTAssertEqual(
            PublishAllPortAllocator.Session.registrationLine(containerID: containerID, traceID: nil),
            "REGISTER \(containerID)\n")
        XCTAssertEqual(
            PublishAllPortAllocator.Session.registrationLine(containerID: containerID, traceID: traceID),
            "REGISTER \(containerID) TRACE \(traceID)\n")
    }
}
