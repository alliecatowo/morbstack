// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// Coverage for turning Docker Engine API documents into Mac-side listeners.
final class PortForwardingTests: XCTestCase {

    /// A realistic two-container `GET /containers/json` body.
    ///
    /// `web` publishes 8080->80 on both address families the way dockerd really does;
    /// `sleeper` publishes nothing and merely exposes 9000.
    private let containersJSON = Data(
        """
        [
          {
            "Id": "aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddddddddddd",
            "Names": ["/web"],
            "Image": "nginx",
            "Ports": [
              {"IP": "0.0.0.0", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"},
              {"IP": "::", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"}
            ]
          },
          {
            "Id": "1111111111112222222222223333333333334444444444",
            "Names": ["/sleeper"],
            "Image": "alpine",
            "Ports": [
              {"PrivatePort": 9000, "Type": "tcp"}
            ]
          }
        ]
        """.utf8)

    // MARK: - containers/json -> port set

    func testExtractsPublishedPortsAndIgnoresMerelyExposedOnes() throws {
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: containersJSON)
        XCTAssertEqual(bindings.count, 2, "both address-family entries for 8080 are reported")
        XCTAssertTrue(bindings.allSatisfy { $0.hostPort == 8080 && $0.containerPort == 80 })
        XCTAssertEqual(bindings.first?.containerName, "web", "the leading slash is stripped")
        // 9000 has no PublicPort, so it is EXPOSEd rather than published.
        XCTAssertFalse(bindings.contains { $0.containerPort == 9000 })
    }

    /// The duplicate IPv4/IPv6 entries dockerd emits must collapse to one listener,
    /// and the recorded address should be the IPv4 one the user actually asked for.
    func testDuplicateAddressFamiliesCollapseToASingleListener() throws {
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: containersJSON)
        let desired = PortForwardPlan.desiredListeners(bindings)
        XCTAssertEqual(Array(desired.keys), [8080])
        XCTAssertEqual(desired[8080]?.hostIP, "0.0.0.0")
    }

    /// A binding to a specific guest interface address means nothing on the Mac.
    func testOnlyLoopbackAndWildcardBindingsAreForwarded() {
        func binding(ip: String, proto: String = "tcp") -> DockerPortBinding {
            DockerPortBinding(
                hostIP: ip, hostPort: 8080, containerPort: 80, networkProtocol: proto,
                containerID: "abc", containerName: "web")
        }
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "0.0.0.0")))
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "127.0.0.1")))
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "")))
        XCTAssertFalse(PortForwardPlan.isForwardable(binding(ip: "192.168.65.3")))
        XCTAssertFalse(PortForwardPlan.isForwardable(binding(ip: "0.0.0.0", proto: "udp")))
    }

    func testUDPPortsAreReportedSeparatelyRatherThanForwarded() throws {
        let json = Data(
            """
            [{"Id":"d","Names":["/dns"],"Ports":[
              {"IP":"0.0.0.0","PrivatePort":53,"PublicPort":5353,"Type":"udp"}]}]
            """.utf8)
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: json)
        XCTAssertTrue(PortForwardPlan.desiredListeners(bindings).isEmpty)
        XCTAssertEqual(PortForwardPlan.udpHostPorts(bindings).map(\.hostPort), [5353])
    }

    func testRejectsANonArrayContainersDocument() {
        XCTAssertThrowsError(
            try DockerAPIDecoding.publishedPorts(containersJSON: Data(#"{"message":"nope"}"#.utf8)))
    }

    func testAnEmptyContainerListYieldsNoForwards() throws {
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: Data("[]".utf8))
        XCTAssertTrue(PortForwardPlan.desiredListeners(bindings).isEmpty)
    }

    // MARK: - Fixed TCP create leases

    func testExplicitTCPCreateBindingsCollapseAddressFamiliesForOneMacLease() {
        let create = Data(
            """
            {"HostConfig":{"PortBindings":{
              "80/tcp":[
                {"HostIp":"0.0.0.0","HostPort":"8080"},
                {"HostIp":"::","HostPort":"8080"}
              ]
            }}}
            """.utf8)

        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: create), .allowed)
        XCTAssertEqual(
            DockerPortPublicationPreflight.explicitTCPBindings(in: create),
            [DockerExplicitTCPPortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80)])
    }

    func testExplicitTCPCreateBindingsDoNotGuessDynamicOrAmbiguousTargets() {
        let dynamic = Data(#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":""}]}}}"#.utf8)
        let ambiguous = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}],"81/tcp":[{"HostPort":"8080"}]}}}"#.utf8)

        XCTAssertTrue(DockerPortPublicationPreflight.explicitTCPBindings(in: dynamic).isEmpty)
        XCTAssertTrue(DockerPortPublicationPreflight.explicitTCPBindings(in: ambiguous).isEmpty)
    }

    // MARK: - Running containers (the auto-suspend interlock)

    /// The idle timer asks the engine this question before it is allowed to tear the
    /// guest down, so the filter has to be the one dockerd actually understands.
    func testRunningContainersPathFiltersServerSide() {
        let path = DockerAPIDecoding.runningContainersPath
        XCTAssertTrue(path.hasPrefix(DockerAPIDecoding.containersPath + "?filters="), path)
        XCTAssertTrue(
            path.hasSuffix(MinimalHTTP.percentEncodeQueryValue(#"{"status":["running"]}"#)), path)
        // Percent-encoded, not raw: dockerd rejects the bare JSON punctuation.
        XCTAssertFalse(path.contains("{"), path)
    }

    func testCountsRunningContainers() throws {
        XCTAssertEqual(try DockerAPIDecoding.containerCount(containersJSON: containersJSON), 2)
        XCTAssertEqual(try DockerAPIDecoding.containerCount(containersJSON: Data("[]".utf8)), 0)
    }

    /// An unparseable answer must throw rather than read as "nothing is running":
    /// the caller treats a failure as "do not suspend", and a zero as "go ahead".
    func testAMalformedContainerListIsAnErrorNotAZero() {
        XCTAssertThrowsError(
            try DockerAPIDecoding.containerCount(containersJSON: Data(#"{"message":"nope"}"#.utf8)))
        XCTAssertThrowsError(
            try DockerAPIDecoding.containerCount(containersJSON: Data("not json".utf8)))
    }

    // MARK: - Diffing

    private func binding(_ port: Int, container: String, id: String = "id") -> DockerPortBinding {
        DockerPortBinding(
            hostIP: "0.0.0.0", hostPort: port, containerPort: 80, networkProtocol: "tcp",
            containerID: id, containerName: container)
    }

    func testDiffOpensNewPortsAndClosesRetiredOnes() {
        let current = [8080: binding(8080, container: "web")]
        let desired = [9090: binding(9090, container: "api")]
        let plan = PortForwardPlan.diff(current: current, desired: desired)
        XCTAssertEqual(plan.close, [8080])
        XCTAssertEqual(plan.open.map(\.hostPort), [9090])
    }

    func testDiffIsEmptyWhenNothingChanged() {
        let same = [8080: binding(8080, container: "web")]
        let plan = PortForwardPlan.diff(current: same, desired: same)
        XCTAssertTrue(plan.close.isEmpty)
        XCTAssertTrue(plan.open.isEmpty)
    }

    /// `docker compose up` after an edit replaces the container behind a port. The
    /// listener has to be rebuilt, and the close must be planned so it can happen
    /// before the open — otherwise the rebind hits EADDRINUSE against ourselves.
    func testAReplacedContainerOnTheSamePortIsClosedAndReopened() {
        let current = [8080: binding(8080, container: "web", id: "old")]
        let desired = [8080: binding(8080, container: "web", id: "new")]
        let plan = PortForwardPlan.diff(current: current, desired: desired)
        XCTAssertEqual(plan.close, [8080])
        XCTAssertEqual(plan.open.map(\.containerID), ["new"])
    }

    // MARK: - Events

    func testDecodesAStartEvent() throws {
        let line = Data(
            """
            {"status":"start","id":"abc123","Type":"container","Action":"start",
             "Actor":{"ID":"abc123","Attributes":{"name":"web","image":"nginx"}},"time":1}
            """.utf8)
        let event = try XCTUnwrap(DockerAPIDecoding.containerEvent(line: line))
        XCTAssertEqual(event.action, "start")
        XCTAssertEqual(event.containerID, "abc123")
        XCTAssertEqual(event.containerName, "web")
        XCTAssertTrue(event.affectsPublishedPorts)
    }

    /// `exec_create: /bin/sh` fires on every `docker exec` and never moves a port;
    /// refreshing on it would make an interactive shell hammer the Engine API.
    func testNoisyEventsDoNotTriggerARefresh() throws {
        let line = Data(
            """
            {"Type":"container","Action":"exec_create: /bin/sh","id":"abc123","time":1}
            """.utf8)
        let event = try XCTUnwrap(DockerAPIDecoding.containerEvent(line: line))
        XCTAssertEqual(event.action, "exec_create")
        XCTAssertFalse(event.affectsPublishedPorts)
    }

    func testIgnoresNonContainerAndMalformedEvents() {
        XCTAssertNil(
            DockerAPIDecoding.containerEvent(
                line: Data(#"{"Type":"image","Action":"pull","id":"nginx"}"#.utf8)))
        XCTAssertNil(DockerAPIDecoding.containerEvent(line: Data("not json".utf8)))
        XCTAssertNil(DockerAPIDecoding.containerEvent(line: Data()))
        // An event with no id is unusable even if it parses.
        XCTAssertNil(
            DockerAPIDecoding.containerEvent(line: Data(#"{"Type":"container","Action":"die"}"#.utf8)))
    }

    /// Pre-1.22 engines only send `status`; the forwarder still has to understand them.
    func testFallsBackToTheLegacyStatusField() throws {
        let event = try XCTUnwrap(
            DockerAPIDecoding.containerEvent(line: Data(#"{"status":"die","id":"abc"}"#.utf8)))
        XCTAssertEqual(event.action, "die")
        XCTAssertTrue(event.affectsPublishedPorts)
    }

    // MARK: - Stream dial

    func testPreambleEncoding() {
        XCTAssertEqual(String(decoding: StreamDial.preamble(hostPort: 8080), as: UTF8.self), "TCP 8080\n")
        XCTAssertEqual(String(decoding: StreamDial.preamble(hostPort: 1), as: UTF8.self), "TCP 1\n")
    }

    func testReplyParsing() {
        XCTAssertNoThrow(try StreamDial.parseReply("OK").get())
        XCTAssertNoThrow(try StreamDial.parseReply("OK\n").get())
        XCTAssertNoThrow(try StreamDial.parseReply("OK\r\n").get())

        XCTAssertThrowsError(try StreamDial.parseReply("ERR connection refused\n").get()) { error in
            XCTAssertTrue("\(error)".contains("connection refused"), "\(error)")
        }
        XCTAssertThrowsError(try StreamDial.parseReply("").get())
        XCTAssertThrowsError(try StreamDial.parseReply("what?\n").get())
    }

    /// The reply reader must stop at the newline: everything after it is the peer's
    /// payload, and swallowing even one byte of it corrupts the spliced stream.
    func testReplyReaderLeavesThePayloadUntouched() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertTrue(POSIXSocketSupport.writeAll(fds[1], Data("OK\nHTTP/1.1 200 OK\r\n".utf8)))

        let line = try StreamDial.readReplyLine(fd: fds[0], deadline: Date().addingTimeInterval(2))
        XCTAssertEqual(line, "OK")

        var buffer = [UInt8](repeating: 0, count: 64)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(fds[0], into: raw.baseAddress!, count: raw.count)
        }
        XCTAssertEqual(String(decoding: buffer[0..<max(0, n)], as: UTF8.self), "HTTP/1.1 200 OK\r\n")
    }

    func testReplyReaderTimesOutRatherThanHanging() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertThrowsError(
            try StreamDial.readReplyLine(fd: fds[0], deadline: Date().addingTimeInterval(0.2))
        ) { error in
            XCTAssertTrue("\(error)".contains("in time"), "\(error)")
        }
    }

    // MARK: - Listener

    func testListenerAcceptsOnLoopbackAndReportsAConflict() throws {
        let queue = DispatchQueue(label: "test.tcplistener", attributes: .concurrent)
        let listener = TCPListener(port: 0, queue: queue)
        // Port 0 would ask the kernel to pick one, which the forwarder never does;
        // find a free port the honest way instead.
        listener.stop()

        let port = try findFreePort()
        let accepted = expectation(description: "connection accepted")
        let first = TCPListener(port: port, queue: queue)
        first.onConnection = { fd in
            close(fd)
            accepted.fulfill()
        }
        try first.start()
        defer { first.stop() }

        // A second listener on the same port must report the conflict rather than
        // silently shadowing the first — SO_REUSEADDR must not paper over this.
        let second = TCPListener(port: port, queue: queue)
        XCTAssertThrowsError(try second.start()) { error in
            guard case TCPListenerError.addressInUse(let reported) = error else {
                return XCTFail("expected addressInUse, got \(error)")
            }
            XCTAssertEqual(reported, port)
        }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(client, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "\(String(cString: strerror(errno)))")
        wait(for: [accepted], timeout: 5)
    }

    /// `stop()` has to free the port *before it returns*.
    ///
    /// The forwarder closes and immediately reopens the same host port every time a
    /// container is recreated, and rebinds the whole set on every suspend/resume.
    /// While the listening descriptor was closed asynchronously by the dispatch
    /// cancel handler, that reopen was a coin flip: often the old listener still held
    /// the port and the rebind failed EADDRINUSE against ourselves, leaving the
    /// published port dark with nothing but a warning to show for it. Fifty rounds
    /// makes the race, if it comes back, essentially certain to show up here.
    func testStopFreesThePortSynchronouslyEnoughToRebindImmediately() throws {
        let queue = DispatchQueue(label: "test.tcplistener.rebind", attributes: .concurrent)
        let port = try findFreePort()

        for round in 1...50 {
            let listener = TCPListener(port: port, queue: queue)
            listener.onConnection = { fd in close(fd) }
            do {
                try listener.start()
            } catch {
                return XCTFail("round \(round) could not bind 127.0.0.1:\(port): \(error)")
            }
            XCTAssertTrue(listener.isRunning)
            listener.stop()
            XCTAssertFalse(listener.isRunning)
        }
    }

    /// `stop()` is called from `deinit`, from the forwarder's work queue and from its
    /// own teardown; none of those may close the descriptor twice.
    func testStopIsIdempotent() throws {
        let queue = DispatchQueue(label: "test.tcplistener.idempotent", attributes: .concurrent)
        let port = try findFreePort()
        let listener = TCPListener(port: port, queue: queue)
        try listener.start()
        listener.stop()
        listener.stop()
        listener.stop()
        XCTAssertFalse(listener.isRunning)

        // If a double close had happened, this bind would be landing on a port some
        // other part of the process had since been handed.
        let rebound = TCPListener(port: port, queue: queue)
        XCTAssertNoThrow(try rebound.start())
        rebound.stop()
    }

    /// Asks the kernel for an unused loopback port and immediately gives it back.
    private func findFreePort() throws -> Int {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(probe, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw XCTSkip("could not bind a probe socket") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(probe, generic, &length)
            }
        }
        guard named == 0 else { throw XCTSkip("getsockname failed") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}
