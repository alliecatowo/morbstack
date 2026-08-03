// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Architecture badging for the Images list.
//
// `hostArch` is a parameter on every call rather than read from the running machine, and
// that is the point of the design: a test that asserts "amd64 is translated" must not
// pass or fail depending on which Mac ran it.

import Foundation
import XCTest

@testable import MorbstackAppCore

final class TrackCImageArchTests: XCTestCase {

    private func image(_ architecture: ImageArchitecture?) -> ImageSummary {
        ImageSummary(
            id: "sha256:abc",
            repoTags: ["nginx:latest"],
            size: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            containersUsing: 0,
            architecture: architecture)
    }

    // MARK: - Platform normalisation

    /// Registries, buildx and `uname` say `x86_64`; the engine says `amd64`. Two
    /// spellings of one architecture would badge the same image differently depending on
    /// which endpoint answered.
    func testArchitectureSpellingsAreCanonicalised() {
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "x86_64").arch, "amd64")
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "aarch64").arch, "arm64")
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "i386").arch, "386")
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "AMD64").arch, "amd64")
    }

    func testUnknownArchitecturesAreLowercasedAndKept() {
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "S390X").arch, "s390x")
    }

    func testEmptyVariantIsTreatedAsAbsent() {
        XCTAssertNil(ImageArchitecture(os: "linux", arch: "arm64", variant: "").variant)
    }

    func testShortNameOmitsTheOSAndIncludesTheVariant() {
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "arm64").shortName, "arm64")
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "arm", variant: "v7").shortName, "arm/v7")
    }

    /// The full form is what somebody pastes into `--platform`.
    func testPlatformStringIsTheDockerPlatformSpelling() {
        XCTAssertEqual(
            ImageArchitecture(os: "linux", arch: "arm64", variant: "v8").platformString,
            "linux/arm64/v8")
        XCTAssertEqual(ImageArchitecture(os: "linux", arch: "amd64").platformString, "linux/amd64")
    }

    // MARK: - Badging

    func testNativeImageIsNotNoteworthy() {
        let badge = TrackCImageArch.badge(
            for: ImageArchitecture(os: "linux", arch: "arm64"), hostArch: "arm64")
        XCTAssertEqual(badge, .native("arm64"))
        XCTAssertFalse(badge?.isNoteworthy ?? true)
        XCTAssertNil(badge?.consequenceLabel)
    }

    func testAmd64OnAppleSiliconIsBadgedAsTranslated() {
        let badge = TrackCImageArch.badge(
            for: ImageArchitecture(os: "linux", arch: "amd64"), hostArch: "arm64")
        XCTAssertEqual(badge, .translated("amd64"))
        XCTAssertTrue(badge?.isNoteworthy ?? false)
        XCTAssertEqual(badge?.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(badge?.consequenceLabel, "translated")
    }

    /// Rosetta translates x86-64 and nothing else. `arm/v7` and `s390x` do not run at all
    /// and must not be given the softer "translated" wording.
    func testOtherForeignArchitecturesAreBadgedAsUnsupported() {
        for arch in ["arm", "386", "s390x", "ppc64le", "riscv64"] {
            let badge = TrackCImageArch.badge(
                for: ImageArchitecture(os: "linux", arch: arch), hostArch: "arm64")
            XCTAssertEqual(badge, .foreign(arch), "\(arch) must not read as merely slow")
            XCTAssertEqual(badge?.symbol, "exclamationmark.triangle.fill")
            XCTAssertEqual(badge?.consequenceLabel, "unsupported")
        }
    }

    /// On an Intel Mac the polarity flips, which is why `hostArch` is a parameter.
    func testBadgingIsRelativeToTheHost() {
        XCTAssertEqual(
            TrackCImageArch.badge(for: ImageArchitecture(os: "linux", arch: "amd64"), hostArch: "amd64"),
            .native("amd64"))
        XCTAssertEqual(
            TrackCImageArch.badge(for: ImageArchitecture(os: "linux", arch: "arm64"), hostArch: "amd64"),
            .foreign("arm64"))
    }

    func testHostArchIsCanonicalisedToo() {
        XCTAssertEqual(
            TrackCImageArch.badge(for: ImageArchitecture(os: "linux", arch: "arm64"), hostArch: "aarch64"),
            .native("arm64"))
    }

    /// A variant mismatch inside the same architecture is not a problem — `arm64/v8` and
    /// bare `arm64` are the same thing to the kernel — but the badge still shows it.
    func testVariantDoesNotMakeAnImageForeign() {
        let badge = TrackCImageArch.badge(
            for: ImageArchitecture(os: "linux", arch: "arm64", variant: "v8"), hostArch: "arm64")
        XCTAssertEqual(badge, .native("arm64/v8"))
    }

    /// The single most important case. `nil` in must produce `nil` out: an image whose
    /// platform has not been fetched yet renders as blank, never as "native". Assuming
    /// the common case would put a reassuring blank exactly where the amd64 warning
    /// belongs, on the rows slowest to resolve.
    func testUnknownArchitectureProducesNoBadge() {
        XCTAssertNil(TrackCImageArch.badge(for: nil, hostArch: "arm64"))
        XCTAssertNil(
            TrackCImageArch.badge(for: ImageArchitecture(os: "linux", arch: ""), hostArch: "arm64"))
    }

    // MARK: - Advice

    func testNativeAndUnknownImagesGetNoAdvice() {
        XCTAssertNil(TrackCImageArch.advice(for: .native("arm64"), rosettaAvailable: true))
        XCTAssertNil(TrackCImageArch.advice(for: nil, rosettaAvailable: true))
    }

    /// With Rosetta the advice is a nudge; without it, the container will not start at
    /// all, and the two must not read the same.
    func testTranslatedAdviceDependsOnRosetta() {
        let withRosetta = TrackCImageArch.advice(for: .translated("amd64"), rosettaAvailable: true)
        XCTAssertTrue(withRosetta?.contains("arm64") ?? false, "should nudge towards arm64")
        XCTAssertFalse(withRosetta?.contains("exec format error") ?? true)

        let withoutRosetta = TrackCImageArch.advice(for: .translated("amd64"), rosettaAvailable: false)
        XCTAssertTrue(withoutRosetta?.contains("exec format error") ?? false)
        XCTAssertTrue(withoutRosetta?.contains("morb rosetta install") ?? false)
    }

    /// Rosetta cannot help an `arm/v7` image, so its advice must not mention installing it.
    func testForeignAdviceNeverSuggestsRosetta() {
        let advice = TrackCImageArch.advice(for: .foreign("s390x"), rosettaAvailable: false)
        XCTAssertNotNil(advice)
        XCTAssertFalse(advice?.lowercased().contains("rosetta install") ?? true)
    }

    // MARK: - Counting

    func testNonNativeCountIgnoresUnresolvedImages() {
        let images = [
            image(ImageArchitecture(os: "linux", arch: "arm64")),
            image(ImageArchitecture(os: "linux", arch: "amd64")),
            image(nil),
            image(nil),
        ]
        // Two unknowns are not counted: a total that climbs as lazily-fetched rows
        // resolve would look like the situation is deteriorating while the user watches.
        XCTAssertEqual(TrackCImageArch.nonNativeCount(images, hostArch: "arm64"), 1)
    }

    func testNonNativeCountIsZeroForAnAllNativeList() {
        let images = [image(ImageArchitecture(os: "linux", arch: "arm64"))]
        XCTAssertEqual(TrackCImageArch.nonNativeCount(images, hostArch: "arm64"), 0)
    }

    // MARK: - Wire decoding

    func testDecodesTheDescriptorPlatformFromTheImageList() {
        let wire = Wire.Image(
            Id: "sha256:abc", RepoTags: ["nginx:latest"], Size: 10, Created: 0, Containers: 0,
            Descriptor: Wire.Image.Descriptor(
                platform: Wire.Platform(architecture: "amd64", os: "linux", variant: nil)))
        XCTAssertEqual(ImageSummary(wire).architecture?.arch, "amd64")
    }

    /// Locally built images and older engines carry no descriptor. That must arrive as
    /// `nil` so the lazy inspect fills it in, rather than as a default.
    func testAbsentDescriptorLeavesArchitectureUnknown() {
        let wire = Wire.Image(
            Id: "sha256:abc", RepoTags: [], Size: 10, Created: 0, Containers: 0, Descriptor: nil)
        XCTAssertNil(ImageSummary(wire).architecture)
    }

    func testDecodesTheInspectDocument() {
        let inspect = Wire.ImageInspect(Architecture: "arm64", Os: "linux", Variant: "v8")
        XCTAssertEqual(ImageArchitecture(inspect)?.platformString, "linux/arm64/v8")
    }

    func testInspectWithoutAnArchitectureIsNil() {
        XCTAssertNil(ImageArchitecture(Wire.ImageInspect(Architecture: nil, Os: "linux", Variant: nil)))
        XCTAssertNil(ImageArchitecture(Wire.ImageInspect(Architecture: "", Os: "linux", Variant: nil)))
    }
}
