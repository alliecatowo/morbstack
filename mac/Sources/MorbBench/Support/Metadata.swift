// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Every benchmark number this harness prints is meaningless without the
// machine it was measured on. A "1.8s cold boot" means nothing without
// knowing whether it came from an M1 laptop on battery or an M4 Max plugged
// in; a "resume" number means nothing without knowing whether restore is
// even supported on this host. This is the one place that gathers all of it,
// so every run record carries the same fixed set of facts.

import Darwin
import Foundation
import MorbFeatures
import MorbstackKit

/// The full set of host/guest/config facts recorded with every run.
public struct RunMetadata: Codable, Equatable, Sendable {
    // Host hardware.
    public var macModel: String
    public var chip: String
    public var physicalCores: Int
    public var logicalCores: Int
    public var physicalMemoryBytes: Int64

    // Host software.
    public var macOSVersion: String
    public var macOSBuild: String
    public var morbstackVersion: String

    // Power. `nil` when `pmset` could not be read (e.g. a Mac with no battery
    // and unusual phrasing); never fabricated as `true`.
    public var onACPower: Bool?
    public var powerDetail: String

    // Guest facts. All `nil` until a caller with a running engine fills them
    // in with ``withGuestFacts(_:kernelVersion:dockerVersion:cpus:memoryMiB:rosettaConfigured:)``;
    // a metadata record produced before any benchmark reached a live engine
    // (e.g. every benchmark SKIPPED) legitimately has none of these.
    public var guestKernelVersion: String?
    public var guestDockerVersion: String?
    public var vmCPUs: Int?
    public var vmMemoryMiB: Int?
    public var rosettaConfigured: Bool?
    public var k8sEnabled: Bool?

    // Where this run's engine lives, and whether that is the default,
    // possibly-shared home — the fact ``StackGuard`` bases its refusals on,
    // recorded here so a reader of the JSON file does not have to trust the
    // benchmark's own SKIPPED text.
    public var morbstackHome: String
    public var isDefaultHome: Bool

    /// Collects everything that does not require a live engine.
    public static func collectHost() -> RunMetadata {
        let power = readACPower()
        return RunMetadata(
            macModel: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown (Apple silicon)",
            physicalCores: sysctlInt("hw.physicalcpu") ?? 0,
            logicalCores: sysctlInt("hw.logicalcpu") ?? 0,
            physicalMemoryBytes: sysctlInt64("hw.memsize") ?? 0,
            macOSVersion: {
                let v = ProcessInfo.processInfo.operatingSystemVersion
                return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            }(),
            macOSBuild: sysctlString("kern.osversion") ?? "unknown",
            morbstackVersion: MorbVersion.string,
            onACPower: power.onAC,
            powerDetail: power.detail,
            guestKernelVersion: nil,
            guestDockerVersion: nil,
            vmCPUs: nil,
            vmMemoryMiB: nil,
            rosettaConfigured: nil,
            k8sEnabled: nil,
            morbstackHome: MorbPaths.root.path,
            isDefaultHome: StackGuard.isDefaultHome())
    }

    /// Fills in the fields only a live engine can answer.
    public func withGuestFacts(
        kernelVersion: String?, dockerVersion: String?, cpus: Int?, memoryMiB: Int?,
        rosettaConfigured: Bool?, k8sEnabled: Bool?
    ) -> RunMetadata {
        var copy = self
        if let kernelVersion { copy.guestKernelVersion = kernelVersion }
        if let dockerVersion { copy.guestDockerVersion = dockerVersion }
        if let cpus { copy.vmCPUs = cpus }
        if let memoryMiB { copy.vmMemoryMiB = memoryMiB }
        if let rosettaConfigured { copy.rosettaConfigured = rosettaConfigured }
        if let k8sEnabled { copy.k8sEnabled = k8sEnabled }
        return copy
    }

    /// Rows for the human-readable header printed above every table.
    public func summaryRows() -> [(String, String)] {
        var rows: [(String, String)] = [
            ("model", macModel),
            ("chip", chip),
            ("cores", "\(physicalCores) physical / \(logicalCores) logical"),
            ("memory", Format.bytes(physicalMemoryBytes)),
            ("macOS", "\(macOSVersion) (\(macOSBuild))"),
            ("morbstack", morbstackVersion),
            ("power", powerDetail),
            ("MORBSTACK_HOME", "\(morbstackHome)\(isDefaultHome ? " (default — shared-stack protections apply)" : " (private)")"),
        ]
        if let guestKernelVersion { rows.append(("guest kernel", guestKernelVersion)) }
        if let guestDockerVersion { rows.append(("guest docker", guestDockerVersion)) }
        if let vmCPUs, let vmMemoryMiB { rows.append(("vm config", "\(vmCPUs) cpus, \(vmMemoryMiB) MiB")) }
        if let rosettaConfigured { rows.append(("rosetta", rosettaConfigured ? "enabled" : "disabled")) }
        if let k8sEnabled { rows.append(("k8s", k8sEnabled ? "enabled" : "disabled")) }
        return rows
    }

    // MARK: - Collection primitives

    private static func readACPower() -> (onAC: Bool?, detail: String) {
        guard let pmset = Subprocess.which("pmset") else {
            return (nil, "pmset not found — power source unknown")
        }
        guard let result = try? Subprocess.run(pmset, ["-g", "batt"], timeout: 5), result.succeeded else {
            return (nil, "pmset -g batt failed — power source unknown")
        }
        let text = result.stdoutText
        if text.contains("AC Power") { return (true, "AC power") }
        if text.contains("Battery Power") { return (false, "battery power") }
        // A desktop Mac, or a laptop `pmset` phrased unexpectedly. Neither is a
        // reason to guess; the raw first line is more useful than a fabricated verdict.
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return (nil, "power source undetermined (\(firstLine.trimmingCharacters(in: .whitespaces)))")
    }
}

// MARK: - sysctl helpers

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

private func sysctlInt64(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}
