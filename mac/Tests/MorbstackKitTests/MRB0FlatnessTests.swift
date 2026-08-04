// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// Enforces, as a test, the "flat objects only" contract of MRB0 framing.
///
/// The guest's hand-rolled parser (`guest/morbinit/src/jsonlite.rs`, see especially
/// `parse_value` around lines 123-140) hard-errors on any nested object or array:
///
/// ```rust
/// Some('{') | Some('[') => Err(ParseError(
///     "nested objects/arrays are not supported by jsonlite".to_string(),
/// )),
/// ```
///
/// and a `ParseError` there poisons the whole incoming frame in the guest (see
/// `control.rs`) — the host gets back a generic `{"type":"error","message":"..."}`
/// with no indication of which field was the problem.
///
/// Nothing on the host enforces this at compile time. Every request type the host
/// sends across the MRB0 channel (``GuestRequest`` in `GuestControl.swift`, and the
/// private `Request` in `K8s.swift`) is encoded with Foundation's fully general
/// `JSONEncoder`, which is perfectly happy to serialize a struct, array, or
/// dictionary-valued field. Add one nested field to either type, and it compiles,
/// round-trips in an ordinary Swift `Codable` unit test, and then fails 100% of the
/// time at runtime against a real guest. This file is the guardrail that catches that
/// mistake at `swift test` time instead.
///
/// **Only host-encoded *requests* are covered here.** Two other families of type
/// deliberately do NOT belong in this test:
///
/// 1. Guest *replies* the host only *decodes* (``GuestReply``, ``GuestDiskResizeProof``,
///    ``K8s/Status``, ``K8s/KubeconfigReply``). The guest can only ever produce a flat
///    reply in the first place — it builds every reply with `jsonlite::emit`, whose
///    `Value` enum (`jsonlite.rs` lines 21-25) has exactly three flat variants
///    (`Str`, `Int`, `Bool`) and no way to represent nesting at all. A real guest is
///    therefore flat by construction on the reply side; nothing would ever exercise a
///    "guest sent nested JSON" path, so there is no useful nesting assertion to write
///    against those types. (Whether a *future* host decoder might ever want to accept
///    nested reply data is a protocol-version question, not something this ticket's
///    scope covers — see the report for the agent that filed this.)
/// 2. Types that never cross MRB0 at all: ``K8s/ResourceDescription`` and friends
///    travel over the local mTLS Kubernetes API forward and the daemon's own IPC
///    protocol (`AnyCodableValue`), not vsock port 1024; ``MorbLiveShareBridge/Event``
///    /`Root`/`Plan` travel over the dedicated live-share receiver's line-based
///    `HELLO`/`ROOT`/`COMMIT`/`READY` protocol; `GuestPortLease` speaks a bounded ASCII
///    `LEASE`/`OK`/`ERR` line protocol. None of those go through `jsonlite`.
///
/// If you add a new field to ``GuestRequest`` or to `K8s.Request`, make it a
/// `String`, a fixed-width integer, or a `Bool` (optional or not) — never a struct,
/// array, or dictionary. If you add an entirely new host-encoded MRB0 request type,
/// add it to this file too.
final class MRB0FlatnessTests: XCTestCase {

    // MARK: - The enforcement

    /// Every host-encoded MRB0 request type, fully populated, must encode to a JSON
    /// object whose top-level values are all scalars (or `null`) — never a nested
    /// object or array.
    ///
    /// "Fully populated" matters: a `Codable` struct with `nil` optionals encodes
    /// those fields as *absent*, not as `null`, so a nesting bug hiding behind an
    /// optional field that is usually nil would sail through a sparsely-populated
    /// fixture. Every optional field below is deliberately given a value, even
    /// combinations ``GuestRequest`` never actually sends together in production
    /// (e.g. `unixNanos` and `targetBytes` both set) — this test is about the wire
    /// *shape* the encoder is capable of producing, not about which fields a given
    /// message type happens to use.
    func testEveryHostEncodedMRB0RequestTypeIsFlat() throws {
        var failures = 0

        // 1. GuestRequest (GuestControl.swift) — sent for ping/info/clock_sync/
        //    shutdown/disk_resize. Encoded with a plain `JSONEncoder()`, exactly as
        //    `GuestControl.send(_:timeout:)` and `GuestControl.diskResize` do.
        let guestRequest = GuestRequest(
            type: "disk_resize",
            unixNanos: 1_785_600_000_000_000_000,
            targetBytes: 137_438_953_472)
        let guestRequestPayload = try JSONEncoder().encode(guestRequest)
        assertFlatJSONObject(
            guestRequestPayload, typeName: "GuestRequest (GuestControl.swift)", failureCount: &failures)

        // 2. K8s's private `Request` (K8s.swift) — sent for every `k8s` control
        //    action (`status`, `enable`, `disable`, `kubeconfig`). It is `private`,
        //    so rather than widening its access (K8s.swift is being edited
        //    concurrently by another agent right now) this test captures the actual
        //    bytes ``K8s`` writes onto a real MRB0 frame over a `socketpair(2)`
        //    stand-in for the vsock connection — the same harness
        //    `GuestControlTests.swift` uses. That is strictly stronger than decoding
        //    a local copy of the struct: it is the literal production wire payload,
        //    encoded by the literal production code path.
        let k8sRequestPayload = try captureK8sRequestPayload()
        assertFlatJSONObject(
            k8sRequestPayload, typeName: "K8s.Request (K8s.swift, captured off the wire)",
            failureCount: &failures)

        XCTAssertEqual(
            failures, 0,
            "one or more host-encoded MRB0 request types produced nested JSON; "
                + "see the failures above for exactly which type and field. "
                + "guest/morbinit/src/jsonlite.rs rejects nesting outright and poisons the frame.")
    }

    // MARK: - Assertion helper

    /// Asserts that `payload` decodes to a JSON object whose top-level values are all
    /// scalars or `null` — i.e. exactly what `jsonlite::parse` in the guest is willing
    /// to accept. Failures are reported per offending key via `XCTFail` (rather than
    /// throwing), so one nested field does not hide a second one in the same type, and
    /// `failureCount` is incremented so the caller can assert on the whole set at once.
    private func assertFlatJSONObject(
        _ payload: Data, typeName: String, failureCount: inout Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        } catch {
            failureCount += 1
            XCTFail("\(typeName) did not encode to valid JSON at all: \(error)", file: file, line: line)
            return
        }
        guard let object = decoded as? [String: Any] else {
            failureCount += 1
            XCTFail(
                "\(typeName) did not encode to a top-level JSON object (got \(type(of: decoded))); "
                    + "jsonlite only ever parses `{...}`", file: file, line: line)
            return
        }
        XCTAssertFalse(object.isEmpty, "\(typeName) test fixture encoded no fields at all — fix the fixture, "
            + "not the assertion", file: file, line: line)
        for (key, value) in object {
            switch value {
            case is [String: Any]:
                failureCount += 1
                XCTFail(
                    "\(typeName).\(key) encoded as a nested JSON *object* — jsonlite "
                        + "(guest/morbinit/src/jsonlite.rs) rejects any nested object and poisons the "
                        + "whole MRB0 frame at parse time. Flatten this field (e.g. to an encoded string) "
                        + "before it can ship.", file: file, line: line)
            case is [Any]:
                failureCount += 1
                XCTFail(
                    "\(typeName).\(key) encoded as a JSON *array* — jsonlite "
                        + "(guest/morbinit/src/jsonlite.rs) rejects any nested array and poisons the "
                        + "whole MRB0 frame at parse time. Flatten this field (e.g. to a delimited string, "
                        + "the way GuestReply.shares does) before it can ship.", file: file, line: line)
            default:
                // String / NSNumber (Int or Bool) / NSNull — exactly what jsonlite's
                // `Value` enum (Str/Int/Bool) plus JSON's own `null` can represent.
                break
            }
        }
    }

    // MARK: - K8s.Request wire capture

    /// Drives a real `K8s.requestStatus` call over a `socketpair(2)`-backed
    /// ``GuestControl`` and returns the exact MRB0 payload bytes K8s wrote for the
    /// request half of the exchange — i.e. the private `Request` struct's actual
    /// production encoding, without needing to widen its access or duplicate its
    /// field list in this test.
    private func captureK8sRequestPayload() throws -> Data {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        let hostFD = fds[0]
        let peerFD = fds[1]
        defer { close(peerFD) }
        POSIXSocketSupport.suppressSIGPIPE(peerFD)
        let control = GuestControl(fd: hostFD)
        defer { control.closeOwnedDescriptor() }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Data?
            func set(_ value: Data) {
                lock.lock(); stored = value; lock.unlock()
            }
            func take() -> Data? {
                lock.lock(); defer { lock.unlock() }; return stored
            }
        }
        let box = Box()

        DispatchQueue.global().async {
            guard let requestPayload = try? Self.readFrame(fd: peerFD) else { return }
            box.set(requestPayload)
            let reply = Data(#"""
                {"type":"k8s_status","installed":true,"enabled":true,"persistent":true,
                 "phase":"ready","nodes":1,"nodes_ready":1,"pods":1,"pods_ready":1,
                 "apiserver_port":6443,"message":"node morbstack is Ready"}
                """#.utf8)
            if let frame = try? MRB0.encode(payload: reply) {
                _ = POSIXSocketSupport.writeAll(peerFD, frame)
            }
        }

        // Drives the real `K8s.swift` -> `GuestControl.sendRaw` -> MRB0 encode path.
        // Any of the four `k8s` actions share the same `{type, action}` request
        // shape, so "status" exercises exactly what "enable"/"disable"/"kubeconfig"
        // would too.
        _ = try K8s.requestStatus(control, action: "status", timeout: 5)

        guard let payload = box.take() else {
            throw MorbError.protocolViolation("did not capture the K8s.Request frame off the wire")
        }
        return payload
    }

    /// Reads one complete MRB0 frame's payload off `fd`. Mirrors the read half of
    /// `GuestControl.sendRaw`, reused here to play "the guest" in the test harness.
    private static func readFrame(fd: Int32) throws -> Data {
        let deadline = Date().addingTimeInterval(5)
        let header = try GuestControl.readExactly(fd: fd, count: MRB0.headerSize, deadline: deadline)
        let length = try MRB0.decodeHeader(header)
        return length == 0 ? Data() : try GuestControl.readExactly(fd: fd, count: length, deadline: deadline)
    }
}
