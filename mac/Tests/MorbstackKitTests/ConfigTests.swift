// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Coverage for the minimal TOML subset parser and the canonical writer.
final class ConfigTests: XCTestCase {

    func testDefaultsWhenFileMissing() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/morbstack/config.toml")
        let config = try MorbConfig.load(from: missing)
        XCTAssertEqual(config, MorbConfig())
        XCTAssertEqual(config.memoryMiB, 8192)
        XCTAssertEqual(config.diskSizeGiB, 64)
        XCTAssertEqual(config.autoSuspendMinutes, 5)
        XCTAssertTrue(config.rosetta)
        XCTAssertNil(config.kernelPath)
        XCTAssertNil(config.initrdPath)
        // Unset means "derive from the boot mode" rather than a hardcoded string.
        XCTAssertNil(config.kernelCmdline)
        XCTAssertEqual(config.resolvedKernelCmdline(for: .disk), MorbConfig.diskKernelCmdline)
        XCTAssertEqual(config.resolvedKernelCmdline(for: .initramfs), MorbConfig.initramfsKernelCmdline)
    }

    // MARK: - Boot mode

    func testCmdlineDefaultFollowsBootMode() {
        let config = MorbConfig()
        XCTAssertEqual(config.resolvedKernelCmdline(for: .initramfs), "console=hvc0 rdinit=/init")
        XCTAssertEqual(
            config.resolvedKernelCmdline(for: .disk), "console=hvc0 root=/dev/vda rw init=/sbin/morbinit")
    }

    func testExplicitCmdlineWinsInEveryBootMode() throws {
        let config = try MorbConfig.parse("kernel_cmdline = \"console=hvc0 custom\"")
        XCTAssertEqual(config.resolvedKernelCmdline(for: .initramfs), "console=hvc0 custom")
        XCTAssertEqual(config.resolvedKernelCmdline(for: .disk), "console=hvc0 custom")
    }

    func testEmptyCmdlineFallsBackToTheBootModeDefault() throws {
        let config = try MorbConfig.parse("kernel_cmdline = \"\"")
        XCTAssertNil(config.kernelCmdline)
        XCTAssertEqual(config.resolvedKernelCmdline(for: .initramfs), MorbConfig.initramfsKernelCmdline)
    }

    func testInitrdPathOverrideIsHonoured() throws {
        let config = try MorbConfig.parse("initrd_path = \"/tmp/custom-initrd.img\"")
        XCTAssertEqual(config.resolvedInitrdURL.path, "/tmp/custom-initrd.img")
        XCTAssertEqual(try MorbConfig.parse("initrd_path = \"\"").resolvedInitrdURL, MorbPaths.initrd)
    }

    func testDetectedBootModeFollowsTheInitrdFileOnDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-initrd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initrd = directory.appendingPathComponent("initrd.img")
        var config = MorbConfig(initrdPath: initrd.path)
        XCTAssertEqual(config.detectedBootMode, .disk)

        XCTAssertTrue(FileManager.default.createFile(atPath: initrd.path, contents: Data("x".utf8)))
        config = MorbConfig(initrdPath: initrd.path)
        XCTAssertEqual(config.detectedBootMode, .initramfs)
        XCTAssertEqual(
            config.resolvedKernelCmdline(for: config.detectedBootMode),
            MorbConfig.initramfsKernelCmdline)
    }

    func testInitrdPathRoundTrips() throws {
        let original = MorbConfig(initrdPath: "/opt/morb/initrd.img")
        XCTAssertEqual(try MorbConfig.parse(original.toTOML()), original)
    }

    func testRoundTripOfDefaults() throws {
        let original = MorbConfig()
        let parsed = try MorbConfig.parse(original.toTOML())
        XCTAssertEqual(parsed, original)
    }

    func testLANPortPublishingIsOffByDefault() throws {
        XCTAssertFalse(MorbConfig().allowLANPortPublishing)
        XCTAssertFalse(try MorbConfig.parse("").allowLANPortPublishing)
    }

    func testLANPortPublishingPreferenceRoundTrips() throws {
        let original = MorbConfig(allowLANPortPublishing: false)
        let parsed = try MorbConfig.parse(original.toTOML())
        XCTAssertFalse(parsed.allowLANPortPublishing)
        XCTAssertTrue(parsed.toTOML().contains("allow_lan_port_publishing = false"))
    }

    func testRoundTripOfCustomConfiguration() throws {
        let original = MorbConfig(
            cpus: 6,
            memoryMiB: 4096,
            diskSizeGiB: 200,
            kernelPath: "/opt/morb/vmlinux",
            kernelCmdline: "console=hvc0 root=/dev/vda rw quiet init=/sbin/morbinit",
            rosetta: false,
            autoSuspendMinutes: 0)
        let parsed = try MorbConfig.parse(original.toTOML())
        XCTAssertEqual(parsed, original)
    }

    func testSaveAndLoadRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.toml")
        let original = MorbConfig(cpus: 2, memoryMiB: 2048, diskSizeGiB: 32, rosetta: true, autoSuspendMinutes: 15)
        try original.save(to: url)
        XCTAssertEqual(try MorbConfig.load(from: url), original)
    }

    func testCommentsSectionsAndBlankLinesAreTolerated() throws {
        let text = """
            # leading comment

            [vm]
            cpus = 4   # inline comment
            memory_mib = 16384

            [experimental]
            some_future_key = "ignored"
            another = 12

            rosetta = false
            """
        let config = try MorbConfig.parse(text)
        XCTAssertEqual(config.cpus, 4)
        XCTAssertEqual(config.memoryMiB, 16384)
        XCTAssertFalse(config.rosetta)
        // Untouched keys keep their defaults.
        XCTAssertEqual(config.diskSizeGiB, 64)
    }

    func testUnknownTOMLValuesDoNotBlockAnOlderBinary() throws {
        let config = try MorbConfig.parse("""
            cpus = 4
            [future]
            advanced = { cache = true, replicas = 2 }
            release = 1.5
            """)

        XCTAssertEqual(config.cpus, 4)
        XCTAssertEqual(config.memoryMiB, MorbConfig().memoryMiB)
    }

    func testStringEscapesRoundTrip() throws {
        let original = MorbConfig(kernelCmdline: #"console=hvc0 tag="a\b" rw"#)
        let parsed = try MorbConfig.parse(original.toTOML())
        XCTAssertEqual(parsed.kernelCmdline, original.kernelCmdline)
    }

    func testHashInsideQuotedStringIsNotAComment() throws {
        let config = try MorbConfig.parse(#"kernel_cmdline = "console=hvc0 morb.tag=#one" # trailing"#)
        XCTAssertEqual(config.kernelCmdline, "console=hvc0 morb.tag=#one")
    }

    func testEmptyKernelPathBecomesNil() throws {
        let config = try MorbConfig.parse("kernel_path = \"\"")
        XCTAssertNil(config.kernelPath)
        XCTAssertEqual(config.resolvedKernelURL, MorbPaths.kernel)
    }

    func testKernelPathOverrideIsHonoured() throws {
        let config = try MorbConfig.parse("kernel_path = \"/tmp/custom-vmlinux\"")
        XCTAssertEqual(config.resolvedKernelURL.path, "/tmp/custom-vmlinux")
    }

    func testZeroCPUsResolvesToHostCoreCount() {
        let config = MorbConfig(cpus: 0)
        XCTAssertEqual(config.resolvedCPUCount, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertEqual(MorbConfig(cpus: 3).resolvedCPUCount, 3)
    }

    func testTypeMismatchIsRejected() {
        XCTAssertThrowsError(try MorbConfig.parse("memory_mib = \"lots\"")) { error in
            XCTAssertTrue("\(error)".contains("must be an integer"), "\(error)")
        }
        XCTAssertThrowsError(try MorbConfig.parse("rosetta = 1"))
        XCTAssertThrowsError(try MorbConfig.parse("kernel_cmdline = 7"))
    }

    func testMalformedLinesAreRejected() {
        XCTAssertThrowsError(try MorbConfig.parse("this is not toml"))
        XCTAssertThrowsError(try MorbConfig.parse("cpus ="))
        XCTAssertThrowsError(try MorbConfig.parse("= 4"))
        XCTAssertThrowsError(try MorbConfig.parse("kernel_cmdline = \"unterminated"))
    }

    func testOutOfRangeValuesAreRejected() {
        XCTAssertThrowsError(try MorbConfig.parse("cpus = -1"))
        XCTAssertThrowsError(try MorbConfig.parse("memory_mib = 0"))
        XCTAssertThrowsError(try MorbConfig.parse("auto_suspend_minutes = -5"))
    }

    func testAutoSuspendZeroIsAllowed() throws {
        XCTAssertEqual(try MorbConfig.parse("auto_suspend_minutes = 0").autoSuspendMinutes, 0)
    }
}
