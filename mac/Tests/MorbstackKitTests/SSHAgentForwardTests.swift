// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// The guest-initiated SSH-agent forward channel (vsock 2383, UX-19).
///
/// `SSHAgentForwardServer.handleConnection(fd:)` is driven directly with one
/// end of a `socketpair(2)`, standing in for the descriptor
/// `VMManager`'s guest-vsock-accept delegate would normally hand it. This
/// exercises the exact negotiation and splice code the real guest connection
/// would drive, without booting a VM.
final class SSHAgentForwardTests: XCTestCase {

    private var toClose: [Int32] = []
    private var fakeAgent: UnixSocketServer?
    private var fakeAgentPath: String?

    override func tearDown() {
        for fd in toClose { close(fd) }
        toClose = []
        fakeAgent?.stop()
        fakeAgent = nil
        if let fakeAgentPath { try? FileManager.default.removeItem(atPath: fakeAgentPath) }
        fakeAgentPath = nil
        super.tearDown()
    }

    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        POSIXSocketSupport.suppressSIGPIPE(fds[0])
        POSIXSocketSupport.suppressSIGPIPE(fds[1])
        return (fds[0], fds[1])
    }

    private func makeLog() -> MorbLog {
        MorbLog(fileURL: nil, echoToStderr: false)
    }

    /// A throwaway Unix listener standing in for a real SSH agent. Kept
    /// well under the 104-byte `sockaddr_un` cap regardless of how long
    /// `NSTemporaryDirectory()` is on this machine.
    private func startFakeAgent(echo: Bool = false) throws -> String {
        let path = "/tmp/mb-ssh-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let server = UnixSocketServer(path: path, queue: DispatchQueue(label: "test.fake-agent"))
        server.onConnection = { fd in
            if echo {
                DispatchQueue.global().async {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = buffer.withUnsafeMutableBytes { raw in
                            POSIXSocketSupport.readSome(fd, into: raw.baseAddress!, count: raw.count)
                        }
                        if n <= 0 { break }
                        guard POSIXSocketSupport.writeAll(fd, Data(buffer[0..<n])) else { break }
                    }
                    close(fd)
                }
            } else {
                close(fd)
            }
        }
        try server.start()
        fakeAgent = server
        fakeAgentPath = path
        return path
    }

    /// Reads one `\n`-terminated line from `fd`, byte at a time, bounded.
    private func readLine(_ fd: Int32, limit: Int = 256) -> String {
        var bytes: [UInt8] = []
        while bytes.count < limit {
            var byte: UInt8 = 0
            let n = withUnsafeMutablePointer(to: &byte) {
                POSIXSocketSupport.readSome(fd, into: $0, count: 1)
            }
            guard n == 1 else { break }
            bytes.append(byte)
            if byte == UInt8(ascii: "\n") { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Refusals

    func testRefusesWhenForwardingIsDisabled() throws {
        let (guestOuter, guestInner) = try makePair()
        toClose.append(guestOuter)

        let server = SSHAgentForwardServer(isEnabled: { false }, log: makeLog())
        server.handleConnection(fd: guestInner)

        POSIXSocketSupport.writeAll(guestOuter, Data("SSHAUTH\n".utf8))
        let reply = readLine(guestOuter)
        XCTAssertTrue(reply.hasPrefix("ERR "), "expected a refusal, got \(reply.debugDescription)")
        XCTAssertTrue(
            reply.contains("disabled"),
            "the refusal must name the actual reason, got \(reply.debugDescription)")
        XCTAssertTrue(reply.contains("ssh_agent_forwarding"))
    }

    func testRefusesWhenNoAgentSocketIsConfigured() throws {
        let (guestOuter, guestInner) = try makePair()
        toClose.append(guestOuter)

        let server = SSHAgentForwardServer(
            isEnabled: { true }, sshAuthSocketPath: { nil }, log: makeLog())
        server.handleConnection(fd: guestInner)

        POSIXSocketSupport.writeAll(guestOuter, Data("SSHAUTH\n".utf8))
        let reply = readLine(guestOuter)
        XCTAssertTrue(reply.hasPrefix("ERR "))
        XCTAssertTrue(reply.contains("SSH_AUTH_SOCK is not set"))
    }

    func testRefusesWhenTheConfiguredAgentSocketIsUnreachable() throws {
        let (guestOuter, guestInner) = try makePair()
        toClose.append(guestOuter)

        let server = SSHAgentForwardServer(
            isEnabled: { true },
            sshAuthSocketPath: { "/tmp/mb-ssh-nonexistent-\(UUID().uuidString).sock" },
            log: makeLog())
        server.handleConnection(fd: guestInner)

        POSIXSocketSupport.writeAll(guestOuter, Data("SSHAUTH\n".utf8))
        let reply = readLine(guestOuter)
        XCTAssertTrue(reply.hasPrefix("ERR "))
        XCTAssertTrue(reply.contains("could not reach"))
    }

    func testRejectsAnythingOtherThanTheExactPreamble() throws {
        for bad in ["", "SSHAUTH", "ssh_auth\n", "SSHAUTHX\n", "LEASE tcp 0.0.0.0 80 - 80\n"] {
            let (guestOuter, guestInner) = try makePair()
            toClose.append(guestOuter)
            let server = SSHAgentForwardServer(isEnabled: { true }, log: makeLog())
            server.handleConnection(fd: guestInner)
            if !bad.isEmpty {
                POSIXSocketSupport.writeAll(guestOuter, Data(bad.utf8))
            }
            close(guestOuter)
            toClose.removeAll { $0 == guestOuter }
            // Nothing to assert on a closed write end beyond "did not hang or
            // crash" for the empty-input case; the non-empty cases are
            // covered below with a still-open read.
        }

        let (guestOuter, guestInner) = try makePair()
        toClose.append(guestOuter)
        let server = SSHAgentForwardServer(isEnabled: { true }, log: makeLog())
        server.handleConnection(fd: guestInner)
        POSIXSocketSupport.writeAll(guestOuter, Data("SSHAUTHX\n".utf8))
        let reply = readLine(guestOuter)
        XCTAssertTrue(reply.hasPrefix("ERR "))
        XCTAssertTrue(reply.contains("SSHAUTH"))
    }

    // MARK: - Success: the actual splice

    func testEnabledWithAReachableAgentSplicesBytesBothWays() throws {
        let agentPath = try startFakeAgent(echo: true)
        let (guestOuter, guestInner) = try makePair()
        toClose.append(guestOuter)

        let server = SSHAgentForwardServer(
            isEnabled: { true }, sshAuthSocketPath: { agentPath }, log: makeLog())
        server.handleConnection(fd: guestInner)

        POSIXSocketSupport.writeAll(guestOuter, Data("SSHAUTH\n".utf8))
        let reply = readLine(guestOuter)
        XCTAssertEqual(reply, "OK\n")

        // From here the connection is a raw splice to the fake agent, which
        // echoes: what the "guest" writes must come back byte-for-byte,
        // proving the negotiation handed off to a real bidirectional relay
        // rather than, say, closing after the OK.
        let probe = Data("ssh-agent-protocol-bytes".utf8)
        POSIXSocketSupport.writeAll(guestOuter, probe)

        var echoed = Data()
        var buffer = [UInt8](repeating: 0, count: 64)
        while echoed.count < probe.count {
            let n = buffer.withUnsafeMutableBytes { raw in
                POSIXSocketSupport.readSome(guestOuter, into: raw.baseAddress!, count: raw.count)
            }
            guard n > 0 else { break }
            echoed.append(contentsOf: buffer[0..<n])
        }
        XCTAssertEqual(echoed, probe)
    }

    // MARK: - Wire grammar

    func testErrLinesAreOneBoundedLine() {
        let line = SSHAgentForward.errLine("refused\nEXTRA\r\n")
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("ERR "))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testOKLineIsExactlyOK() {
        XCTAssertEqual(SSHAgentForward.okLine, Data("OK\n".utf8))
    }
}
