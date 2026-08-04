// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// The guest-initiated port-lease channel (vsock 2382): the grammar spoken by
/// the `morbstack-docker-proxy` wrapper, and the forwarder ledger semantics
/// behind it — fresh binds, honest refusals, adoption of preflight-held
/// sockets, and EOF-driven release.
///
/// Every listener here is loopback, and the suite runs against a throwaway
/// `MORBSTACK_HOME` for the same reason `LifecycleTests` does.
final class GuestPortLeaseTests: XCTestCase {

    private var home: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["MORBSTACK_HOME"]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-portlease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("MORBSTACK_HOME", directory.path, 1)
        guard MorbPaths.root.path == directory.path else {
            try? FileManager.default.removeItem(at: directory)
            throw XCTSkip("MORBSTACK_HOME override did not take; refusing to touch the real home")
        }
        try MorbPaths.ensureDirectories()
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

    private func makeLog() -> MorbLog {
        MorbLog(fileURL: nil, echoToStderr: false)
    }

    private func makeForwarder() -> PortForwarder {
        PortForwarder(vm: VMManager(config: MorbConfig(), log: makeLog()), log: makeLog())
    }

    /// Asks the kernel for a free loopback port and gives it straight back.
    private func freeLoopbackPort() throws -> Int {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw XCTSkip("could not bind a probe port") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(probe, generic, &length)
            }
        }
        guard named == 0 else { throw XCTSkip("getsockname failed") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    private func request(
        _ transport: GuestPortLease.Transport, port: Int, containerPort: Int = 80
    ) -> GuestPortLease.Request {
        GuestPortLease.Request(
            transport: transport,
            hostIP: "127.0.0.1",
            hostPort: port,
            containerIP: "172.17.0.2",
            containerPort: containerPort)
    }

    // MARK: - Wire grammar

    func testParsesTheExactWrapperRequest() {
        // The line proxy_wrapper.rs sends, verbatim.
        XCTAssertEqual(
            GuestPortLease.parseRequest(line: "LEASE tcp 0.0.0.0 49153 172.17.0.2 80\n"),
            .success(GuestPortLease.Request(
                transport: .tcp,
                hostIP: "0.0.0.0",
                hostPort: 49153,
                containerIP: "172.17.0.2",
                containerPort: 80)))
        XCTAssertEqual(
            GuestPortLease.parseRequest(line: "LEASE udp 127.0.0.1 53 172.17.0.3 53"),
            .success(GuestPortLease.Request(
                transport: .udp,
                hostIP: "127.0.0.1",
                hostPort: 53,
                containerIP: "172.17.0.3",
                containerPort: 53)))
    }

    func testRejectsEverythingButTheExactGrammar() {
        // Untrusted-input surface: the guest may run arbitrary containers.
        for bad in [
            "",
            "LEASE tcp 0.0.0.0 8080 172.17.0.2\n",
            "LEASE tcp 0.0.0.0 8080 172.17.0.2 80 extra\n",
            "RELEASE tcp 0.0.0.0 8080 172.17.0.2 80\n",
            "LEASE sctp 0.0.0.0 8080 172.17.0.2 80\n",
            "LEASE tcp 0.0.0.0 0 172.17.0.2 80\n",
            "LEASE tcp 0.0.0.0 70000 172.17.0.2 80\n",
            "LEASE tcp 0.0.0.0 8080 172.17.0.2 0\n",
            "LEASE tcp evil.example 8080 172.17.0.2 80\n",
            "LEASE tcp 0.0.0.0 8080 172.17.0.2;rm 80\n",
            "LEASE TCP 0.0.0.0 8080 172.17.0.2 80\n",
            "LEASE tcp  8080 172.17.0.2 80\n",
        ] {
            if case .success = GuestPortLease.parseRequest(line: bad) {
                XCTFail("\(bad.debugDescription) should have been rejected")
            }
        }
    }

    func testErrLinesAreOneBoundedLine() {
        let line = GuestPortLease.errLine("refused\nEXTRA\r\n")
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("ERR "))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    // MARK: - Ledger semantics

    func testLeaseBindsTheMacEndpointAndReleaseFreesIt() throws {
        let forwarder = makeForwarder()
        let port = try freeLoopbackPort()

        let token = try forwarder.leaseGuestProxyPort(request(.tcp, port: port))
        XCTAssertTrue(
            forwarder.activeForwards.contains { $0.contains("\(port)") },
            "an owned proxy lease must be visible in morb status")

        // The endpoint is genuinely held: a second lease is refused honestly.
        XCTAssertThrowsError(try forwarder.leaseGuestProxyPort(request(.tcp, port: port))) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                message.contains("port is already allocated"),
                "a busy endpoint must produce Docker's honest wording, got \(message)")
        }

        forwarder.releaseGuestProxyPort(token, reason: "test release")
        // Released means rebindable — the same port leases again cleanly.
        let second = try forwarder.leaseGuestProxyPort(request(.tcp, port: port))
        forwarder.releaseGuestProxyPort(second, reason: "test cleanup")
    }

    func testMacSideCollisionFailsClosed() throws {
        // The core promise: a port another Mac process owns must refuse the
        // lease (dockerd then fails the container start) rather than let the
        // container run with a silently dead publication.
        let forwarder = makeForwarder()
        let port = try freeLoopbackPort()

        let squatter = socket(AF_INET, SOCK_STREAM, 0)
        guard squatter >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(squatter) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(squatter, 1) == 0 else {
            throw XCTSkip("could not squat the probe port")
        }

        XCTAssertThrowsError(try forwarder.leaseGuestProxyPort(request(.tcp, port: port)))
    }

    func testExplicitPublishAdoptsThePreflightLease() throws {
        // Explicit `-p` is preflighted at create (the fixed lease binds the
        // Mac socket) *and* execs the wrapper at start. The wrapper's lease
        // must succeed by adoption — and its release must NOT tear down the
        // socket the fixed lease still owns.
        let forwarder = makeForwarder()
        let port = try freeLoopbackPort()

        let plan = DockerFixedPortLeasePlan(
            tcp: [DockerExplicitTCPPortBinding(
                hostIP: "127.0.0.1", hostPort: port, containerPort: 80)],
            udp: [])
        let fixed = try forwarder.reserveExplicitPorts(plan)

        let token = try forwarder.leaseGuestProxyPort(request(.tcp, port: port))
        forwarder.releaseGuestProxyPort(token, reason: "proxy exited")

        // Still held by the fixed lease: an outside bind must fail.
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertNotEqual(
            bound, 0,
            "releasing an adopted proxy lease must not close the preflight lease's socket")

        forwarder.abandon(fixed, reason: "test cleanup")
    }

    func testUDPLeaseBindsAndReleases() throws {
        let forwarder = makeForwarder()
        let port = try freeLoopbackPort()

        let token = try forwarder.leaseGuestProxyPort(request(.udp, port: port, containerPort: 53))
        XCTAssertThrowsError(
            try forwarder.leaseGuestProxyPort(request(.udp, port: port, containerPort: 53)))
        // Transports are separate socket namespaces: TCP on the same number
        // must still lease.
        let tcpToken = try forwarder.leaseGuestProxyPort(request(.tcp, port: port))
        forwarder.releaseGuestProxyPort(tcpToken, reason: "test cleanup")
        forwarder.releaseGuestProxyPort(token, reason: "test cleanup")
        let again = try forwarder.leaseGuestProxyPort(request(.udp, port: port, containerPort: 53))
        forwarder.releaseGuestProxyPort(again, reason: "test cleanup")
    }

    func testForwarderStopClosesOwnedProxyLeases() throws {
        // Proxy leases die with the VM generation; a stopped forwarder must
        // leave no Mac listener behind.
        let forwarder = makeForwarder()
        let port = try freeLoopbackPort()
        _ = try forwarder.leaseGuestProxyPort(request(.tcp, port: port))
        forwarder.stop(reason: "test stop")

        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "stop() must release every owned proxy-lease listener")
    }
}
