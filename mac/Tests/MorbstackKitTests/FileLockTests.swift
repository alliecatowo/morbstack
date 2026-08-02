// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation
import XCTest

@testable import MorbstackKit

/// Coverage for the single-instance lock that guards the daemon's sockets.
final class FileLockTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lockPath() -> String {
        directory.appendingPathComponent("morbstackd.lock").path
    }

    func testFirstAcquirerWinsAndSecondIsRefused() throws {
        let path = lockPath()
        let first = FileLock(path: path)
        let second = FileLock(path: path)

        XCTAssertTrue(try first.acquire())
        XCTAssertTrue(first.isHeld)

        // This is the case that used to be a race: a second daemon must be told no
        // rather than proceed to unlink and re-bind the sockets.
        XCTAssertFalse(try second.acquire())
        XCTAssertFalse(second.isHeld)

        first.release()
        XCTAssertFalse(first.isHeld)
        XCTAssertTrue(try second.acquire())
        second.release()
    }

    func testAcquireIsIdempotentForTheHolder() throws {
        let lock = FileLock(path: lockPath())
        XCTAssertTrue(try lock.acquire())
        XCTAssertTrue(try lock.acquire())
        lock.release()
        lock.release()  // must not trap or close a descriptor twice
        XCTAssertFalse(lock.isHeld)
    }

    func testTheLockFileSurvivesReleaseAndRecordsThePid() throws {
        let path = lockPath()
        let lock = FileLock(path: path)
        XCTAssertTrue(try lock.acquire())

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), "\(getpid())")

        lock.release()
        // Deliberately not unlinked: a stable inode is what makes two racing daemons
        // contend for the same lock rather than for two different files.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testDeallocatingTheLockReleasesIt() throws {
        let path = lockPath()
        do {
            let transient = FileLock(path: path)
            XCTAssertTrue(try transient.acquire())
        }
        let next = FileLock(path: path)
        XCTAssertTrue(try next.acquire())
        next.release()
    }

    func testAcquireIsNonBlocking() throws {
        let path = lockPath()
        let holder = FileLock(path: path)
        XCTAssertTrue(try holder.acquire())
        defer { holder.release() }

        // The daemon calls this on its startup path, so a contended lock must return
        // immediately rather than park the process forever.
        let started = Date()
        XCTAssertFalse(try FileLock(path: path).acquire())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}
