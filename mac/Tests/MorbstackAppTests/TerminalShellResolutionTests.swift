// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Coverage for shell probing: which candidate a container terminal should start, and
// the honest answers when none exists or the probe itself could not run.

import Foundation
import XCTest

@testable import MorbstackAppCore

/// A `DockerClient` that answers `executeContainerCommand` from a fixed script instead
/// of dialling a socket — the same non-final-class substitution `ShotDockerClient`
/// uses in `Shots/ShotClients.swift`, scoped down to the one method shell resolution
/// calls.
private final class ScriptedShellClient: DockerClient, @unchecked Sendable {

    private enum Scripted {
        case exit(Int?)
        case throwing(Error)
    }

    private let lock = NSLock()
    private var scripts: [String: Scripted] = [:]
    private var _calls: [[String]] = []

    init() {
        super.init(socketPath: "/dev/null/terminal-shell-resolution-fixture.sock")
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func script(_ candidate: String, exitCode: Int?) {
        lock.lock()
        scripts[candidate] = .exit(exitCode)
        lock.unlock()
    }

    func script(_ candidate: String, error: Error) {
        lock.lock()
        scripts[candidate] = .throwing(error)
        lock.unlock()
    }

    override func executeContainerCommand(id: String, command: [String]) async throws -> DockerExecResult {
        lock.lock()
        _calls.append(command)
        let scripted = command.first.flatMap { scripts[$0] }
        lock.unlock()

        switch scripted {
        case .exit(let code):
            return DockerExecResult(
                standardOutput: "", standardError: "", exitCode: code,
                standardOutputWasTruncated: false, standardErrorWasTruncated: false)
        case .throwing(let error):
            throw error
        case nil:
            XCTFail("no script registered for \(command.first ?? "<empty>")")
            return DockerExecResult(
                standardOutput: "", standardError: "", exitCode: nil,
                standardOutputWasTruncated: false, standardErrorWasTruncated: false)
        }
    }
}

final class TerminalShellResolutionTests: XCTestCase {

    func testFirstCandidateThatExitsZeroIsFoundWithoutProbingTheRest() async {
        let client = ScriptedShellClient()
        client.script("/bin/bash", exitCode: 0)
        client.script("/bin/sh", exitCode: 0)

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1")

        XCTAssertEqual(outcome, .found(shell: "/bin/bash"))
        XCTAssertEqual(client.calls.map(\.first), ["/bin/bash"], "a found shell must stop the probe")
    }

    func testMissingFirstCandidateFallsBackToTheNext() async {
        let client = ScriptedShellClient()
        client.script("/bin/bash", exitCode: 127)
        client.script("/bin/sh", exitCode: 0)

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1")

        XCTAssertEqual(outcome, .found(shell: "/bin/sh"))
        XCTAssertEqual(client.calls.map(\.first), ["/bin/bash", "/bin/sh"])
    }

    func testEveryCandidateMissingReportsNoShell() async {
        let client = ScriptedShellClient()
        let candidates = ["/bin/bash", "/bin/sh"]
        client.script("/bin/bash", exitCode: 127)
        client.script("/bin/sh", exitCode: 127)

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1", candidates: candidates)

        XCTAssertEqual(outcome, .noShell(probed: candidates))
    }

    /// 126 — found but not executable — must move on exactly like 127 does.
    func testNotExecutableCandidateAlsoMovesToTheNext() async {
        let client = ScriptedShellClient()
        client.script("/bin/bash", exitCode: 126)
        client.script("/bin/sh", exitCode: 0)

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1")

        XCTAssertEqual(outcome, .found(shell: "/bin/sh"))
    }

    func testEngineUnreachableStopsTheProbeAsFailedRatherThanMovingOn() async {
        let client = ScriptedShellClient()
        client.script("/bin/bash", error: DockerClientError.engineUnreachable("no such socket"))
        client.script("/bin/sh", exitCode: 0)

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1")

        guard case .failed(let message) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("no such socket"), message)
        XCTAssertEqual(client.calls.map(\.first), ["/bin/bash"], "a genuine engine error must not be treated as a missing shell")
    }

    /// The daemon's own "container not running" wording must not be mistaken for one
    /// of the missing-shell shapes and silently skipped.
    func testContainerNotRunningIsReportedAsFailedNotSkipped() async {
        let client = ScriptedShellClient()
        client.script("/bin/bash", error: DockerClientError.http(status: 409, message: "container c1 is not running"))

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1")

        guard case .failed(let message) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("is not running"), message)
        XCTAssertEqual(client.calls.count, 1)
    }

    /// Docker's own wording for a missing executable, carried as an ordinary HTTP
    /// error rather than a distinct status code — this is the shape the probe has to
    /// recognize to move on rather than reporting a false failure.
    func testExecutableNotFoundHTTPMessageMovesToTheNextCandidate() async {
        let client = ScriptedShellClient()
        client.script(
            "/bin/bash",
            error: DockerClientError.http(
                status: 500,
                message: "OCI runtime exec failed: exec failed: unable to start container process: "
                    + "exec: \"/bin/bash\": stat /bin/bash: no such file or directory: unknown"))
        client.script("/bin/sh", exitCode: 0)

        let outcome = await TerminalShellResolution.resolve(client: client, containerID: "c1")

        XCTAssertEqual(outcome, .found(shell: "/bin/sh"))
    }
}
