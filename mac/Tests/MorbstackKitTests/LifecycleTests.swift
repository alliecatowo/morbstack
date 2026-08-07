// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// Lifecycle coverage for the pieces that own descriptors, counters and the VM.
///
/// Everything here runs against a throwaway `MORBSTACK_HOME`. That is not tidiness:
/// `VMManager.init` deletes a stale `vmstate.bin` when it finds the
/// `save-restore-unsupported` marker, and on a developer's machine both of those are
/// real files describing a real suspended VM. The isolation is verified before any
/// object is constructed, and the test skips rather than proceed if it did not take.
final class LifecycleTests: XCTestCase {

    private var home: URL?
    /// Whatever `MORBSTACK_HOME` was before this test hijacked it.
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["MORBSTACK_HOME"]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("MORBSTACK_HOME", directory.path, 1)

        // Refuse to touch anything until the override is demonstrably in effect.
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
        // Put back whatever the developer had set, rather than clearing it: the next
        // test in this process may be relying on their override too.
        if let previousHome {
            setenv("MORBSTACK_HOME", previousHome, 1)
        } else {
            unsetenv("MORBSTACK_HOME")
        }
        previousHome = nil
    }

    /// A logger that writes nowhere, so the suite stays quiet.
    private func makeLog() -> MorbLog {
        MorbLog(fileURL: nil, echoToStderr: false)
    }

    private func makeVM() -> VMManager {
        VMManager(config: MorbConfig(), log: makeLog())
    }

    private func binding(
        _ port: Int, container: String = "web", hostIP: String = "0.0.0.0"
    ) -> DockerPortBinding {
        DockerPortBinding(
            hostIP: hostIP, hostPort: port, containerPort: 80, networkProtocol: "tcp",
            containerID: "id-\(port)", containerName: container)
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

    // MARK: - Forwarded connection accounting

    /// A relay cancelled by `stop()` completes asynchronously, often after the next
    /// `start()` has begun counting new connections. With one flat counter those late
    /// completions were debited against the *live* generation, and the daemon reads
    /// that counter to decide whether the stack is idle — so the visible failure was
    /// an auto-suspend fired while connections were open.
    func testStaleCompletionsDoNotDebitTheLiveGeneration() {
        let forwarder = PortForwarder(vm: makeVM(), log: makeLog())
        forwarder.start()
        let old = forwarder.currentGeneration
        forwarder.connectionStarted(old)
        forwarder.connectionStarted(old)
        XCTAssertEqual(forwarder.activeConnections, 2)

        forwarder.stop()
        forwarder.start()
        let live = forwarder.currentGeneration
        XCTAssertNotEqual(old, live, "each start/stop must mint a fresh generation")
        XCTAssertEqual(forwarder.activeConnections, 0, "a restart starts from zero")

        forwarder.connectionStarted(live)
        XCTAssertEqual(forwarder.activeConnections, 1)

        // The two relays from the previous generation finally tear down.
        forwarder.connectionFinished(old)
        forwarder.connectionFinished(old)
        XCTAssertEqual(
            forwarder.activeConnections, 1,
            "completions from a dead generation must not retire a live connection")

        forwarder.connectionFinished(live)
        XCTAssertEqual(forwarder.activeConnections, 0)
        forwarder.stop()
    }

    /// While stopped, nothing is being forwarded no matter what is still unwinding.
    func testActiveConnectionsAreZeroWhileStopped() {
        let forwarder = PortForwarder(vm: makeVM(), log: makeLog())
        forwarder.start()
        let generation = forwarder.currentGeneration
        forwarder.connectionStarted(generation)
        XCTAssertEqual(forwarder.activeConnections, 1)
        forwarder.stop()
        XCTAssertEqual(forwarder.activeConnections, 0)
    }

    // MARK: - Dial concurrency

    /// Each stream-dial parks a GCD worker for as long as the vsock connect and the
    /// 2376 preamble take. Unbounded, a burst of accepted connections becomes a burst
    /// of blocked threads and starves the VM manager's probe queue — the very thing
    /// that would have noticed the guest was unhealthy.
    func testDialSlotsAreBoundedAndSheddingIsLoggedOncePerBurst() {
        let forwarder = PortForwarder(vm: makeVM(), log: makeLog())
        let ceiling = PortForwarder.maxConcurrentDials + PortForwarder.dialBacklogAllowance

        for slot in 1...ceiling {
            XCTAssertEqual(forwarder.claimDialSlot(), .granted, "slot \(slot) should be available")
        }

        // Past the ceiling the client is refused outright, and only the first refusal
        // of the burst is worth a log line.
        XCTAssertEqual(forwarder.claimDialSlot(), .refused(worthLogging: true))
        XCTAssertEqual(forwarder.claimDialSlot(), .refused(worthLogging: false))
        XCTAssertEqual(forwarder.claimDialSlot(), .refused(worthLogging: false))

        for _ in 1...ceiling { forwarder.releaseDialSlot() }

        // Drained: the next burst gets its own log line.
        XCTAssertEqual(forwarder.claimDialSlot(), .granted)
        forwarder.releaseDialSlot()
    }

    func testTheDialCeilingStaysBelowTheGuestLimit() {
        // The guest's stream-dial server accepts 128 concurrent dials. The host must
        // be the side that pushes back, so that shedding is a decision we log rather
        // than a refusal the guest hands us.
        XCTAssertLessThan(
            PortForwarder.maxConcurrentDials + PortForwarder.dialBacklogAllowance, 128)
    }

    // MARK: - Bind conflicts

    /// A host port some other process owns must be remembered, reported, and left
    /// alone until its backoff expires — not re-attempted on every container event.
    func testAConflictingPortIsRecordedAndBackedOff() throws {
        let queue = DispatchQueue(label: "test.squatter", attributes: .concurrent)
        let port = try findFreePort()
        let squatter = TCPListener(port: port, queue: queue)
        try squatter.start()
        defer { squatter.stop() }

        let forwarder = PortForwarder(vm: makeVM(), log: makeLog())
        forwarder.start()
        defer { forwarder.stop() }
        let generation = forwarder.currentGeneration

        // Same address on both sides, deliberately. The squatter's `TCPListener`
        // convenience initializer binds loopback, and on Darwin a wildcard bind of
        // 0.0.0.0:P is *permitted* while another socket holds 127.0.0.1:P — so a
        // binding published on 0.0.0.0 would succeed here and this test would be
        // asserting the opposite of what its own failure message says.
        forwarder.openForward(
            binding(port, hostIP: "127.0.0.1"), generation: generation)
        XCTAssertTrue(forwarder.activeForwards.isEmpty, "the bind cannot have succeeded")
        XCTAssertEqual(forwarder.failedForwards.count, 1)
        let reported = try XCTUnwrap(forwarder.failedForwards.first)
        XCTAssertTrue(
            reported.contains("another process holds 127.0.0.1:\(port)"),
            "the message must name the conflict in the user's terms: \(reported)")
        XCTAssertTrue(reported.contains("will retry"), reported)

        // Free the port and ask again straight away: the backoff, not the state of
        // the port, is what decides whether we try.
        squatter.stop()
        // Same endpoint again: the backoff is keyed by host endpoint, so retrying a
        // *different* address would be a new forward rather than the retry this test
        // is about.
        forwarder.openForward(binding(port, hostIP: "127.0.0.1"), generation: generation)
        XCTAssertTrue(
            forwarder.activeForwards.isEmpty,
            "a retry inside the backoff window must be skipped, not attempted")
        XCTAssertEqual(forwarder.failedForwards.count, 1, "and must not stack up more entries")
    }

    /// A port that binds cleanly leaves no failure behind to be reported or retried.
    func testASuccessfulBindClearsAnyRecordedFailure() throws {
        let port = try findFreePort()
        let forwarder = PortForwarder(vm: makeVM(), log: makeLog())
        forwarder.start()
        defer { forwarder.stop() }

        forwarder.openForward(binding(port), generation: forwarder.currentGeneration)
        XCTAssertEqual(forwarder.activeForwards.count, 1)
        XCTAssertTrue(forwarder.failedForwards.isEmpty)
    }

    /// `stop()` releases the listeners it holds, so the ports are immediately usable
    /// again — including by the next `start()`.
    func testStopReleasesEveryListener() throws {
        let port = try findFreePort()
        let forwarder = PortForwarder(vm: makeVM(), log: makeLog())
        forwarder.start()
        forwarder.openForward(binding(port), generation: forwarder.currentGeneration)
        XCTAssertEqual(forwarder.activeForwards.count, 1)

        forwarder.stop(reason: "vm suspended")
        XCTAssertTrue(forwarder.activeForwards.isEmpty)

        let rebound = TCPListener(port: port, queue: DispatchQueue(label: "test.rebound"))
        XCTAssertNoThrow(try rebound.start(), "the forwarder must not still hold the port")
        rebound.stop()
    }

    // MARK: - Overlapping stops

    /// Two `morb stop`s that overlap must both be answered by the one shutdown.
    ///
    /// The second used to start a shutdown of its own, immediately fall down a path
    /// that answers nothing, and let its `CompletionOnce` deallocate unfired — which
    /// the deinit reports as "the VM operation was abandoned before it completed".
    /// Pressing Ctrl-C twice should not produce that.
    func testConcurrentStopsAreAllAnsweredExactlyOnce() {
        let vm = makeVM()
        let callers = 8
        let lock = NSLock()
        var results: [Result<Void, Error>] = []
        let allAnswered = expectation(description: "every stop answered")
        allAnswered.expectedFulfillmentCount = callers

        let starter = DispatchQueue(label: "test.stop.starter", attributes: .concurrent)
        let gate = DispatchSemaphore(value: 0)
        for _ in 0..<callers {
            starter.async {
                gate.wait()
                vm.stop(force: false) { result in
                    lock.lock()
                    results.append(result)
                    lock.unlock()
                    allAnswered.fulfill()
                }
            }
        }
        for _ in 0..<callers { gate.signal() }

        wait(for: [allAnswered], timeout: 20)

        lock.lock()
        let collected = results
        lock.unlock()
        XCTAssertEqual(collected.count, callers, "each caller is answered exactly once")
        for result in collected {
            if case .failure(let error) = result {
                XCTFail("stopping an already-stopped VM should succeed, got \(error)")
            }
        }
        XCTAssertEqual(vm.state, .stopped)
    }

    /// Sequential stops stay idempotent; joining must not have made the second one a
    /// no-op that never answers.
    func testRepeatedStopsEachGetAnAnswer() {
        let vm = makeVM()
        for attempt in 1...3 {
            let answered = expectation(description: "stop \(attempt) answered")
            vm.stop(force: false) { result in
                if case .failure(let error) = result {
                    XCTFail("stop \(attempt) failed: \(error)")
                }
                answered.fulfill()
            }
            wait(for: [answered], timeout: 10)
        }
        XCTAssertEqual(vm.state, .stopped)
    }

    // MARK: - Shutdown budget nesting

    /// The guest's shutdown reply cap, `control::SHUTDOWN_REPLY_TIMEOUT` in
    /// `guest/morbinit/src/control.rs`. Derived there, not chosen:
    /// `SUPERVISED_SERVICE_COUNT * (STOP_GRACE + KILL_GRACE) + GATED_PHASE_ALLOWANCE
    /// + disk::TRIM_SHUTDOWN_DEADLINE + FLUSH_ALLOWANCE`
    /// = 2 * (10 + 2) + 5 + 15 + 30 = 74.
    ///
    /// This constant previously hardcoded a stale pre-Kubernetes value (54, missing
    /// `GATED_PHASE_ALLOWANCE`) that happened to still satisfy every `<` assertion
    /// below without actually proving the nesting held for the real guest constant —
    /// found and fixed alongside the disk-trim shutdown budget addition (TECH-3/UX-16
    /// §8, `docs/design/DISK-RECLAIM-DECISION.md`). Keep this equal to the guest's
    /// `control::SHUTDOWN_REPLY_TIMEOUT` exactly, not merely below the host timeouts —
    /// a value that is merely "low enough to pass" stops policing drift the moment the
    /// guest side grows another line item.
    private static let guestReplyCap: TimeInterval = 74

    /// `REPLY_FLUSH_TIMEOUT` in `guest/morbinit/src/main.rs`: what the guest spends
    /// getting the `ok` onto the socket *after* the reply cap has already expired.
    private static let guestReplyFlush: TimeInterval = 5

    /// The clean-shutdown budgets must nest, strictly, at every level.
    ///
    /// This is the host end of a chain whose guest end is pinned by
    /// `the_reply_budget_leaves_room_for_the_host_ack_timeout_above_it` in
    /// `control.rs` — which hardcodes `shutdownAckTimeout`'s value as its
    /// `HOST_ACK_TIMEOUT`. Two suites, two languages, one ladder: change a number in
    /// either repo half without the other and one of these fails.
    ///
    /// It matters because the failure it guards against is silent and destructive. If
    /// an outer budget expires first it stops *waiting* and tears the VM down while
    /// the guest is still flushing the Docker data disk, which loses images and
    /// volumes rather than merely reporting an error.
    func testShutdownBudgetsNestFromTheGuestOutwards() {
        let guestCap = Self.guestReplyCap
        let ack = VMManager.shutdownAckTimeout
        let stop = Daemon.stopBudget
        let client = Daemon.clientTimeout

        XCTAssertLessThan(guestCap, ack, "guest reply cap must fit inside the host ack timeout")
        XCTAssertLessThan(ack, stop, "host ack must fit inside the daemon's stop budget")
        XCTAssertLessThan(stop, client, "daemon stop budget must fit inside the CLI's timeout")

        // Strict ordering is necessary but not sufficient: the host must also outlast
        // the guest's *whole* worst case, which is the cap plus the flush that puts
        // the reply on the wire. An ack of 75 would satisfy 74 < 75 and still walk
        // away from an `ok` that was about to arrive.
        XCTAssertGreaterThanOrEqual(
            ack, guestCap + Self.guestReplyFlush,
            "the ack timeout must outlast the guest's reply cap plus its reply flush")

        // Likewise the stop budget has to cover the ack *and* the power-off wait that
        // follows it, not just the ack alone.
        XCTAssertGreaterThan(
            stop, ack + VMManager.guestPowerOffTimeout,
            "the stop budget must cover the ack plus the wait for the guest to halt")
    }

    /// `suspend` degrades to a graceful stop on every host Morbstack has met, so the
    /// same ladder has to fit inside it — plus the container query that runs first.
    func testSuspendBudgetContainsTheStopLadderAndItsPreflightQuery() {
        XCTAssertGreaterThan(
            Daemon.suspendBudget,
            VMManager.shutdownAckTimeout + VMManager.guestPowerOffTimeout,
            "a suspend that degrades to a stop must still fit")
        XCTAssertLessThan(
            Daemon.suspendBudget + Daemon.idleContainerQueryTimeout, Daemon.clientTimeout,
            "the pre-suspend query plus the suspend must beat the CLI's timeout")
    }
}
