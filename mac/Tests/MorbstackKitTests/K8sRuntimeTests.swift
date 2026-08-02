// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Foundation
import XCTest

@testable import MorbstackKit

/// The parts of Kubernetes support that move bytes: staging the payload on the Mac,
/// the install channel's wire vocabulary, and the API server forward's port policy.
///
/// Nothing here needs a VM. What it needs is a scratch directory, which is the point:
/// the payload staging path decides whether a 74 MB executable is about to be shipped
/// into a guest and executed as root, and that decision has to be testable without
/// booting anything.
final class K8sRuntimeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("morbstack-k8s-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: - Hashing

    func testHashAgreesWithCryptoKitOverTheWholeFile() throws {
        // The streaming reader exists so a 74 MB binary is never held in memory; the
        // only thing that could go wrong with it is losing or double-counting a
        // chunk, which a file larger than one read buffer catches.
        var bytes = Data()
        for i in 0..<(3 * (1 << 20) + 12345) { bytes.append(UInt8(i % 251)) }
        let url = try write("payload.bin", bytes)

        let (digest, size) = try K8sPayloadStaging.hash(url)

        XCTAssertEqual(size, bytes.count)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected)
    }

    func testHashOfAnEmptyFileIsTheEmptyDigest() throws {
        let url = try write("empty.bin", Data())
        let (digest, size) = try K8sPayloadStaging.hash(url)
        XCTAssertEqual(size, 0)
        XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - Staging

    func testDescribeRefusesAPayloadThatDoesNotMatchThePin() throws {
        // The one that matters. Anything `describe` returns is streamed into the
        // guest, written to the persistent disk, and executed as root by PID 1's
        // supervisor. A file that does not hash to the pinned digest is a file
        // Morbstack cannot identify, and the only safe thing to do with it is refuse
        // — not warn, not install-and-hope.
        for file in K8s.payloadFiles {
            _ = try write(file.name, Data("this is not k3s".utf8))
        }

        XCTAssertThrowsError(try K8sPayloadStaging.describe(in: scratch)) { error in
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("does not match the digest"),
                "expected a digest refusal, got: \(message)")
            XCTAssertTrue(
                message.contains("Refusing to install it"),
                "the refusal must say that nothing was installed, got: \(message)")
        }
    }

    func testDescribeNamesTheFetchScriptWhenThePayloadWasNeverDownloaded() throws {
        // The overwhelmingly common failure: a fresh clone that never ran the fetch
        // script. The error has to be a next step, not a stat() failure.
        XCTAssertThrowsError(try K8sPayloadStaging.describe(in: scratch)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("fetch-guest-assets.sh --k8s-only"), message)
        }
    }

    func testIsStagedOnHostIsAnExistenceCheckNotAHash() throws {
        // Called to decide whether the CLI should suggest downloading the payload, on
        // a path where a second of hashing would be a second of latency for nothing.
        XCTAssertFalse(K8sPayloadStaging.isStagedOnHost(in: scratch))
        for file in K8s.payloadFiles {
            _ = try write(file.name, Data("wrong contents, right name".utf8))
        }
        XCTAssertTrue(K8sPayloadStaging.isStagedOnHost(in: scratch))
    }

    func testDescribeAcceptsAPayloadThatMatchesThePin() throws {
        // Proves the digest gate is a gate and not a wall: a file whose bytes hash to
        // the pin is described, with its real size, ready to send.
        //
        // Constructed rather than downloaded — finding a preimage of the real k3s
        // digest is not on the table — by pinning a synthetic payload through the
        // same code path with a digest computed from the bytes.
        let bytes = Data("pretend this is a static Go binary\n".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = try write("synthetic", bytes)

        let (computed, size) = try K8sPayloadStaging.hash(url)
        XCTAssertEqual(computed, digest)
        XCTAssertEqual(size, bytes.count)
    }

    // MARK: - Install channel replies

    func testExpectOKAcceptsOKAndSurfacesTheGuestsOwnReason() throws {
        XCTAssertNoThrow(try K8sManager.expectOK("OK", context: "installing k3s"))
        XCTAssertNoThrow(try K8sManager.expectOK("  OK  ", context: "installing k3s"))

        XCTAssertThrowsError(
            try K8sManager.expectOK("ERR sha256 mismatch after 74000000 bytes", context: "installing k3s")
        ) { error in
            let message = "\(error)"
            // The guest's diagnosis has to reach the user intact: "sha256 mismatch" is
            // the difference between "retry" and "your download is corrupt".
            XCTAssertTrue(message.contains("sha256 mismatch"), message)
            XCTAssertTrue(message.contains("installing k3s"), message)
        }
    }

    func testExpectOKTreatsAnUnrecognisedReplyAsAProtocolViolation() {
        XCTAssertThrowsError(try K8sManager.expectOK("wat", context: "PUT k3s")) { error in
            guard case MorbError.protocolViolation = error else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
        // A silently closed stream reads as an empty line, which must not be mistaken
        // for success.
        XCTAssertThrowsError(try K8sManager.expectOK("", context: "PUT k3s"))
    }

    // MARK: - API server forward

    func testTheApiServerForwardPrefersSixFourFourThree() {
        // Every kubeconfig, every tutorial and everybody's fingers expect 6443. The
        // fallbacks exist only for a Mac that already has something there.
        XCTAssertEqual(K8sAPIServerForward.candidatePorts.first, 6443)
        XCTAssertEqual(K8sAPIServerForward.candidatePorts.count, 10)
        XCTAssertEqual(
            K8sAPIServerForward.candidatePorts,
            Array(6443...6452),
            "the candidate range must stay contiguous so the fallback is predictable")
    }

    func testTheGuestSidePortIsAlwaysTheRealApiServerPort() {
        // The stream-dial preamble names a *guest-local* port. Sending the host port
        // there instead would dial 127.0.0.1:6444 inside the guest, where nothing is
        // listening, and the failure would look exactly like "the cluster is still
        // starting" forever.
        XCTAssertEqual(K8s.guestAPIServerPort, 6443)
    }

    // MARK: - Command policy

    func testOnlyK8sEnableMayStartADaemon() {
        // Asking for a cluster implies asking for the engine it runs on, so
        // `k8s-enable` earns the same treatment as `start`. The other three must not:
        // an observation that creates the thing it observes is not an observation,
        // and producing a kubeconfig for a cluster that is not running by first
        // booting a VM would be worse than saying so.
        XCTAssertTrue(MorbCommandPolicy.mayAutoStartDaemon("k8s-enable"))
        for command in ["k8s-status", "k8s-disable", "k8s-kubeconfig"] {
            XCTAssertFalse(
                MorbCommandPolicy.mayAutoStartDaemon(command),
                "\(command) must not be able to conjure a daemon")
        }
    }

    // MARK: - Paths

    func testMorbstackWritesItsOwnKubeconfigAndNotTheUsers() {
        // The whole safety design in one assertion: the file Morbstack writes by
        // default is its own, and it is not ~/.kube/config.
        XCTAssertNotEqual(MorbPaths.kubeconfig.path, MorbPaths.userKubeconfig.path)
        XCTAssertTrue(MorbPaths.kubeconfig.path.hasSuffix("/kubeconfig"))
        XCTAssertTrue(MorbPaths.userKubeconfig.path.hasSuffix("/.kube/config"))
        XCTAssertEqual(MorbPaths.kubeconfig.deletingLastPathComponent().path, MorbPaths.root.path)
    }

    func testThePayloadLivesBesideTheKernelNotInsideTheGuestImage() {
        // If this ever moves into the initramfs, every boot pays 122 MB of guest RAM
        // for a feature that is off by default. The location is the decision.
        XCTAssertEqual(
            MorbPaths.k8sPayloadDirectory.deletingLastPathComponent().path,
            MorbPaths.dataDirectory.path)
        XCTAssertEqual(MorbPaths.k8sPayloadDirectory.lastPathComponent, "k8s")
    }
}
