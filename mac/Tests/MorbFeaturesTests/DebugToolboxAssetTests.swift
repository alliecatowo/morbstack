// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// These are pure schema tests. They never start an engine, inspect images, pull an
// asset, read the default Morbstack directory, or contact a network.

import XCTest

@testable import MorbScan

final class DebugToolboxAssetTests: XCTestCase {

    func testValidCurrentDescriptorIsOnlyStructurallyAccepted() throws {
        let manifest = fixture()

        XCTAssertNoThrow(try manifest.validate())
        XCTAssertNotNil(manifest.expiryDate)
    }

    func testDescriptorRequiresItsReferenceToEmbedTheDeclaredDigest() {
        let manifest = fixture(imageReference: "ghcr.io/morbstack/debug-toolbox@sha256:" + String(repeating: "b", count: 64))

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? DebugToolboxAssetError, .imageReferenceDoesNotMatchDigest)
        }
    }

    func testDescriptorRequiresNativeArm64Compatibility() {
        let manifest = fixture(platforms: [
            .init(os: "linux", architecture: "amd64"),
        ])

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? DebugToolboxAssetError, .invalidPlatforms)
        }
    }

    func testDescriptorRejectsAnUnspecifiedProvenanceMethod() {
        let manifest = fixture(provenance: .init(
            method: "unsigned",
            issuer: "https://token.actions.githubusercontent.com",
            identity: "https://github.com/morbstack/morbstack/.github/workflows/release.yml@refs/heads/main",
            bundleDigest: "sha256:" + String(repeating: "b", count: 64)))

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? DebugToolboxAssetError, .invalidProvenance)
        }
    }

    private func fixture(
        imageReference: String? = nil,
        platforms: [DebugToolboxAssetManifest.Platform] = [.init(os: "linux", architecture: "arm64")],
        provenance: DebugToolboxAssetManifest.Provenance? = nil
    ) -> DebugToolboxAssetManifest {
        let imageDigest = "sha256:" + String(repeating: "a", count: 64)
        return DebugToolboxAssetManifest(
            schemaVersion: DebugToolboxAssetManifest.currentSchemaVersion,
            assetID: "morbstack-debug-toolbox",
            imageReference: imageReference ?? "ghcr.io/morbstack/debug-toolbox@\(imageDigest)",
            imageDigest: imageDigest,
            platforms: platforms,
            provenance: provenance ?? .init(
                method: "sigstore",
                issuer: "https://token.actions.githubusercontent.com",
                identity: "https://github.com/morbstack/morbstack/.github/workflows/release.yml@refs/heads/main",
                bundleDigest: "sha256:" + String(repeating: "b", count: 64)),
            validThrough: "2099-01-01T00:00:00Z")
    }
}
