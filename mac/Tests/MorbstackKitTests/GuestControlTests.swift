// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// Coverage for the guest control channel's failure handling.
///
/// A `socketpair(2)` stands in for the vsock connection: one end is handed to
/// ``GuestControl`` and the test plays the part of `morbinit` on the other.
final class GuestControlTests: XCTestCase {

    private var peer: Int32 = -1

    override func tearDown() {
        if peer >= 0 { close(peer) }
        peer = -1
        super.tearDown()
    }

    /// Builds a `GuestControl` whose peer end the test keeps.
    private func makeChannel() throws -> GuestControl {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        peer = fds[1]
        POSIXSocketSupport.suppressSIGPIPE(peer)
        return GuestControl(fd: fds[0])
    }

    /// Reads and discards whatever the channel wrote, so the peer stays in sync.
    private func drainOneRequest() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(peer, into: raw.baseAddress!, count: raw.count)
        }
    }

    /// A timed-out exchange must poison the channel.
    ///
    /// Without this, a guest that answers a moment too late leaves its reply in the
    /// socket buffer and the *next* call reads it as its own answer — every exchange
    /// from then on is off by one, which is far worse than a clean reconnect.
    func testATimeoutPoisonsTheChannel() throws {
        let control = try makeChannel()
        XCTAssertTrue(control.isUsable)

        XCTAssertThrowsError(try control.ping(timeout: 0.2)) { error in
            XCTAssertTrue("\(error)".contains("timed out") || "\(error)".contains("within"), "\(error)")
        }
        XCTAssertFalse(control.isUsable, "a timed-out channel must not be reused")

        // The late reply is now unreachable rather than mistaken for the next answer.
        drainOneRequest()
        let pong = try MRB0.encode(payload: Data(#"{"type":"pong","uptime_ms":1}"#.utf8))
        _ = POSIXSocketSupport.writeAll(peer, pong)

        XCTAssertThrowsError(try control.ping(timeout: 0.2)) { error in
            XCTAssertTrue("\(error)".contains("unusable") || "\(error)".contains("closed"), "\(error)")
        }
    }

    /// A frame with bad magic desynchronises the stream, so it poisons too.
    func testAFramingViolationPoisonsTheChannel() throws {
        let control = try makeChannel()
        let peerFD = peer

        DispatchQueue.global().async { [weak self] in
            self?.drainOneRequest()
            var garbage = Data("XXXX".utf8)
            garbage.append(contentsOf: [0, 0, 0, 2])
            garbage.append(Data("{}".utf8))
            _ = POSIXSocketSupport.writeAll(peerFD, garbage)
        }

        XCTAssertThrowsError(try control.ping(timeout: 2)) { error in
            XCTAssertTrue("\(error)".contains("magic"), "\(error)")
        }
        XCTAssertFalse(control.isUsable)
    }

    /// `info` carries the two booleans the boot probe and `morb status` depend on.
    ///
    /// Both are optional on purpose: a guest too old to send `docker_ready` must
    /// decode as `nil` (treated as ready) rather than as `false` (waited on until the
    /// boot budget expires).
    func testInfoDecodesTheDockerReadinessFields() throws {
        let control = try makeChannel()
        let peerFD = peer

        DispatchQueue.global().async { [weak self] in
            self?.drainOneRequest()
            let payload = #"""
                {"type":"info","morbinit_version":"0.1.0","kernel":"6.18.15",
                 "docker_ready":true,"docker_data_on_disk":true}
                """#
            if let frame = try? MRB0.encode(payload: Data(payload.utf8)) {
                _ = POSIXSocketSupport.writeAll(peerFD, frame)
            }
        }

        let reply = try control.info(timeout: 2)
        XCTAssertEqual(reply.dockerReady, true)
        XCTAssertEqual(reply.dockerDataOnDisk, true)
        XCTAssertEqual(reply.morbinitVersion, "0.1.0")

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.dockerReady, "an absent field must not decode as false")
        XCTAssertNil(legacy.dockerDataOnDisk)
    }

    /// `rosetta` and `binfmt_amd64` decode, and an older guest that sends neither
    /// leaves both `nil` rather than claiming amd64 is unsupported.
    ///
    /// The `nil` case is the one that matters: `nil` means "this guest is too old
    /// to say", while `"none"` means "this guest looked and found nothing". Only
    /// the second is worth telling a user about.
    func testInfoDecodesTheAmd64EmulationFields() throws {
        let rosetta = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(
                #"{"type":"info","rosetta":true,"binfmt_amd64":"rosetta"}"#.utf8))
        XCTAssertEqual(rosetta.rosetta, true)
        XCTAssertEqual(rosetta.binfmtAmd64, "rosetta")

        // The two fields are independent: a qemu fallback is a working amd64
        // setup that must not be reported as a working Rosetta share.
        let qemu = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","rosetta":false,"binfmt_amd64":"qemu"}"#.utf8))
        XCTAssertEqual(qemu.rosetta, false)
        XCTAssertEqual(qemu.binfmtAmd64, "qemu")

        let none = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","rosetta":false,"binfmt_amd64":"none"}"#.utf8))
        XCTAssertEqual(none.binfmtAmd64, "none")

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.rosetta, "an absent field must not decode as false")
        XCTAssertNil(legacy.binfmtAmd64, "an absent field must not decode as \"none\"")
    }

    /// UX-18 / `morb doctor`'s `proxy-live` check: what `apply_proxy_env` actually
    /// launched dockerd with. Empty string ("this proxy kind is unset") must survive
    /// decoding distinctly from `nil` ("an older guest that never reports this at
    /// all") — `proxy-live` cannot tell "guest reported no proxy" from "guest never
    /// reported" if both collapse to the same value.
    func testInfoDecodesTheProxyEnvironmentFields() throws {
        let current = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(
                #"""
                {"type":"info","http_proxy":"http://proxy.example:8080",
                 "https_proxy":"http://proxy.example:8080","no_proxy":"localhost,127.0.0.1"}
                """#.utf8))
        XCTAssertEqual(current.httpProxy, "http://proxy.example:8080")
        XCTAssertEqual(current.httpsProxy, "http://proxy.example:8080")
        XCTAssertEqual(current.noProxy, "localhost,127.0.0.1")

        let unset = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","http_proxy":"","https_proxy":"","no_proxy":""}"#.utf8))
        XCTAssertEqual(unset.httpProxy, "", "empty string means \"configured with no proxy of this kind\"")
        XCTAssertEqual(unset.httpsProxy, "")
        XCTAssertEqual(unset.noProxy, "")

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.httpProxy, "an absent field must not decode as \"\"")
        XCTAssertNil(legacy.httpsProxy)
        XCTAssertNil(legacy.noProxy)
    }

    /// An explicit negative guest capability is different from an older guest that
    /// did not know the field: neither says hot reload works, but the first gives the
    /// bridge diagnostic a precise reason not to create an unconsumed FSEvents watch.
    func testInfoDecodesTheShareEventCapability() throws {
        let current = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","share_event_bridge":"unavailable"}"#.utf8))
        XCTAssertEqual(current.shareEventBridge, "unavailable")

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.shareEventBridge)
    }

    func testInfoDistinguishesTheGuestTmpAliasFromThePrivateTmpShare() throws {
        let current = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","tmp_alias_mounted":true}"#.utf8))
        XCTAssertEqual(current.tmpAliasMounted, true)

        let legacy = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info"}"#.utf8))
        XCTAssertNil(legacy.tmpAliasMounted)
    }

    /// Disk expansion is additive: a current guest can advertise the verified
    /// transaction contract, while an older guest remains unknown.
    func testInfoDecodesTheDiskResizeCapability() throws {
        let current = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","disk_resize":"ready"}"#.utf8))
        XCTAssertEqual(current.diskResize, "ready")

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.diskResize)
    }

    /// UX-17: the balloon policy's only input. A real sample decodes as real
    /// numbers; an older guest, and the guest's own explicit `-1` "unavailable"
    /// sentinel, must both collapse to `nil` — never a value a caller could
    /// mistake for a real reading.
    func testInfoDecodesTheMemorySample() throws {
        let current = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","mem_total_kb":8137368,"mem_available_kb":6234112}"#.utf8))
        XCTAssertEqual(current.memTotalKB, 8_137_368)
        XCTAssertEqual(current.memAvailableKB, 6_234_112)

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.memTotalKB, "an absent field must not decode as 0")
        XCTAssertNil(legacy.memAvailableKB)

        let sentinel = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","mem_total_kb":-1,"mem_available_kb":-1}"#.utf8))
        XCTAssertNil(sentinel.memTotalKB, "the guest's own -1 sentinel must read as no sample")
        XCTAssertNil(sentinel.memAvailableKB)

        // Half a sample (should never happen, but the sentinel logic must not
        // half-trust it) is also "no sample."
        let half = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","mem_total_kb":8137368,"mem_available_kb":-1}"#.utf8))
        XCTAssertNil(half.memTotalKB)
        XCTAssertNil(half.memAvailableKB)
    }

    /// TECH-3 / UX-16: the periodic `fstrim` sweep's only host-visible evidence.
    /// A real sweep result decodes as a real number, including zero (a legitimate
    /// "nothing to reclaim" answer); an older guest and the guest's own `-1`
    /// "no sweep yet" sentinel both collapse to `nil` — same convention as
    /// ``testInfoDecodesTheMemorySample``.
    func testInfoDecodesTheDiskTrimResult() throws {
        let current = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","disk_last_trim_bytes":59050795008}"#.utf8))
        XCTAssertEqual(current.diskLastTrimBytes, 59_050_795_008)

        let zero = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","disk_last_trim_bytes":0}"#.utf8))
        XCTAssertEqual(zero.diskLastTrimBytes, 0, "a real zero-byte sweep must not read as no sweep")

        let legacy = try JSONDecoder().decode(
            GuestReply.self, from: Data(#"{"type":"info","kernel":"6.1"}"#.utf8))
        XCTAssertNil(legacy.diskLastTrimBytes, "an absent field must not decode as 0")

        let sentinel = try JSONDecoder().decode(
            GuestReply.self,
            from: Data(#"{"type":"info","disk_last_trim_bytes":-1}"#.utf8))
        XCTAssertNil(sentinel.diskLastTrimBytes, "the guest's own -1 sentinel must read as no sweep yet")
    }

    func testDiskResizeSuccessReplyUsesTheStrictProofSchema() throws {
        let proof = try GuestControl.decodeDiskResizeReply(Data(#"""
            {"type":"disk_resize","device":"/dev/vda","mount_point":"/var/lib/docker",
             "filesystem":"ext4","device_bytes":137438953472,
             "before_filesystem_bytes":68719476736,"after_filesystem_bytes":137438953472,
             "resized":true,"previously_proved":false}
            """#.utf8))

        XCTAssertEqual(proof.device, "/dev/vda")
        XCTAssertEqual(proof.mountPoint, "/var/lib/docker")
        XCTAssertEqual(proof.deviceBytes, 137_438_953_472)
        XCTAssertTrue(proof.resized)
        XCTAssertFalse(proof.previouslyProved)
    }

    func testDiskResizeErrorReplyIsNotDecodedAsAPartialProof() {
        XCTAssertThrowsError(try GuestControl.decodeDiskResizeReply(
            Data(#"{"type":"error","message":"/var/lib/docker is not mounted"}"#.utf8)
        )) { error in
            XCTAssertTrue("\(error)".contains("guest reported: /var/lib/docker is not mounted"))
            XCTAssertFalse("\(error)".contains("Key 'device'"))
        }
    }

    func testDiskResizeErrorReplyRequiresItsMessage() {
        XCTAssertThrowsError(try GuestControl.decodeDiskResizeReply(
            Data(#"{"type":"error"}"#.utf8)
        )) { error in
            XCTAssertTrue("\(error)".contains("without a message"))
        }
    }

    func testDiskResizeSuccessReplyRejectsMissingProofFields() {
        XCTAssertThrowsError(try GuestControl.decodeDiskResizeReply(
            Data(#"{"type":"disk_resize","device":"/dev/vda"}"#.utf8)
        )) { error in
            XCTAssertTrue("\(error)".contains("malformed disk_resize proof"))
        }
    }

    /// A well-formed exchange leaves the channel usable, and closing is idempotent.
    func testASuccessfulExchangeKeepsTheChannelUsable() throws {
        let control = try makeChannel()
        let peerFD = peer

        DispatchQueue.global().async { [weak self] in
            self?.drainOneRequest()
            let pong = try? MRB0.encode(payload: Data(#"{"type":"pong","uptime_ms":4321}"#.utf8))
            if let pong { _ = POSIXSocketSupport.writeAll(peerFD, pong) }
        }

        XCTAssertEqual(try control.ping(timeout: 2), 4321)
        XCTAssertTrue(control.isUsable)

        control.closeOwnedDescriptor()
        control.closeOwnedDescriptor()  // must not double-close
        XCTAssertFalse(control.isUsable)
        XCTAssertThrowsError(try control.ping(timeout: 0.2))
    }
}
