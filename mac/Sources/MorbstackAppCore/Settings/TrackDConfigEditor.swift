// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Settings screen's model: everything about `~/.morbstack/config.toml` that is not
// a view.
//
// Split out from `MorbSettingsView` because it is the testable half. Two things here
// are worth getting right and neither is visual:
//
//   * the slider ↔ config mapping, including the `cpus = 0` sentinel that means "every
//     host core" — a slider cannot show zero cores, and writing a literal core count
//     over the sentinel silently opts the user out of ever tracking their machine again;
//   * the round trip. Morbstack's config file is hand-editable and full of explanatory
//     comments, and the app must never turn a considered file into a lossy rewrite of
//     the six keys it happens to know about.

import Foundation
import MorbstackKit
import Observation

// MARK: - Host limits

/// What this Mac can actually offer the VM.
struct TrackDResourceLimits: Equatable, Sendable {

    var hostCores: Int
    var hostMemoryGiB: Int

    static var current: TrackDResourceLimits {
        let info = ProcessInfo.processInfo
        let gigabytes = Int(info.physicalMemory / (1024 * 1024 * 1024))
        return TrackDResourceLimits(
            hostCores: max(1, info.activeProcessorCount),
            hostMemoryGiB: max(1, gigabytes))
    }
}

// MARK: - Pure edits

/// Slider ↔ `MorbConfig` conversions, and the clamping that keeps a config the daemon
/// will accept.
enum TrackDConfigEditor {

    /// Morbstack's own floor for guest RAM, in GiB. Below this `dockerd` starts and
    /// then dies pulling anything interesting, which looks like a Morbstack bug.
    static let minimumMemoryGiB = 1

    // MARK: CPU

    /// The slider position for `config`, resolving the `cpus = 0` sentinel to the host's
    /// core count.
    static func cpuSliderValue(_ config: MorbConfig, limits: TrackDResourceLimits) -> Double {
        let resolved = config.cpus > 0 ? config.cpus : limits.hostCores
        return Double(min(max(1, resolved), limits.hostCores))
    }

    /// Writes a slider position back as an explicit core count.
    ///
    /// Explicit even when it lands on the host's core count: the user just dragged a
    /// slider to a number, and having the file say something else would be a surprise.
    /// ``matchHostCores(_:)`` is how somebody asks for the sentinel back.
    static func applyCPU(_ value: Double, to config: inout MorbConfig, limits: TrackDResourceLimits) {
        let cores = Int(value.rounded())
        config.cpus = min(max(1, cores), limits.hostCores)
    }

    /// Restores the "every host core" sentinel.
    static func matchHostCores(_ config: inout MorbConfig) {
        config.cpus = 0
    }

    /// Whether `config` is currently tracking the host rather than pinning a number.
    static func isTrackingHostCores(_ config: MorbConfig) -> Bool { config.cpus == 0 }

    // MARK: Memory

    /// The memory slider position, in GiB.
    static func memorySliderGiB(_ config: MorbConfig, limits: TrackDResourceLimits) -> Double {
        let gibibytes = Double(config.memoryMiB) / 1024
        return min(max(Double(minimumMemoryGiB), gibibytes), Double(limits.hostMemoryGiB))
    }

    /// Writes a memory slider position back as mebibytes.
    static func applyMemoryGiB(_ value: Double, to config: inout MorbConfig, limits: TrackDResourceLimits) {
        let gibibytes = Int(value.rounded())
        let clamped = min(max(minimumMemoryGiB, gibibytes), limits.hostMemoryGiB)
        config.memoryMiB = clamped * 1024
    }

    // MARK: Auto-suspend

    /// Idle minutes before Morbstack reclaims VM memory. `0` disables it.
    static let autoSuspendRange = 0...120

    static func applyAutoSuspend(_ minutes: Int, to config: inout MorbConfig) {
        config.autoSuspendMinutes = min(max(autoSuspendRange.lowerBound, minutes), autoSuspendRange.upperBound)
    }

    // MARK: Validation

    /// Brings a config back inside the range this host and this app support.
    ///
    /// Applied on load as well as on save, because a file hand-edited on a 64 GB Mac
    /// and then opened on a 16 GB one should not present a slider pinned past its own
    /// maximum.
    static func clamped(_ config: MorbConfig, limits: TrackDResourceLimits) -> MorbConfig {
        var out = config
        if out.cpus != 0 { out.cpus = min(max(1, out.cpus), limits.hostCores) }
        let gibibytes = max(minimumMemoryGiB, min(limits.hostMemoryGiB, out.memoryMiB / 1024))
        out.memoryMiB = gibibytes * 1024
        out.autoSuspendMinutes = min(
            max(autoSuspendRange.lowerBound, out.autoSuspendMinutes), autoSuspendRange.upperBound)
        return out
    }

    // MARK: Restart detection

    /// The fields the running VM baked in at boot.
    ///
    /// `diskSizeGiB` is absent on purpose: it is only honoured when the sparse image is
    /// first created, so telling somebody to restart the engine to apply it would be a
    /// lie. Settings says so in the caption instead.
    static func requiresEngineRestart(from applied: MorbConfig, to pending: MorbConfig) -> Bool {
        applied.cpus != pending.cpus
            || applied.memoryMiB != pending.memoryMiB
            || applied.rosetta != pending.rosetta
            || applied.kernelPath != pending.kernelPath
            || applied.initrdPath != pending.initrdPath
            || applied.kernelCmdline != pending.kernelCmdline
            || applied.autoSuspendMinutes != pending.autoSuspendMinutes
    }

    /// A one-line description of what changed, for the restart banner.
    static func restartSummary(from applied: MorbConfig, to pending: MorbConfig) -> String {
        var changes: [String] = []
        if applied.cpus != pending.cpus {
            changes.append("CPUs \(describeCPUs(applied)) → \(describeCPUs(pending))")
        }
        if applied.memoryMiB != pending.memoryMiB {
            changes.append("memory \(applied.memoryMiB / 1024) → \(pending.memoryMiB / 1024) GiB")
        }
        if applied.rosetta != pending.rosetta {
            changes.append("Rosetta \(pending.rosetta ? "on" : "off")")
        }
        if applied.autoSuspendMinutes != pending.autoSuspendMinutes {
            changes.append("auto-suspend \(describeSuspend(pending))")
        }
        if applied.kernelPath != pending.kernelPath
            || applied.initrdPath != pending.initrdPath
            || applied.kernelCmdline != pending.kernelCmdline {
            changes.append("boot configuration")
        }
        return changes.isEmpty ? "Configuration changed" : changes.joined(separator: ", ")
    }

    static func describeCPUs(_ config: MorbConfig) -> String {
        config.cpus == 0 ? "all" : String(config.cpus)
    }

    static func describeSuspend(_ config: MorbConfig) -> String {
        config.autoSuspendMinutes == 0 ? "off" : "\(config.autoSuspendMinutes) min"
    }
}

// MARK: - Store

/// Owns the on-disk config for the Settings screen.
@MainActor
@Observable
final class TrackDSettingsStore {

    /// What is on disk, as of the last load or save.
    private(set) var saved: MorbConfig
    /// The unmodified document values from the last load or successful save.
    ///
    /// `saved` is clamped for the controls, while this remains the exact semantic
    /// baseline for the conflict check in ``MorbConfig/savePreservingFile(to:expected:changing:)``.
    /// Keeping both avoids treating display-range normalization as a user edit.
    private var onDisk: MorbConfig
    /// What the controls are showing.
    var draft: MorbConfig
    /// What the currently running VM booted with, as best we can know it.
    ///
    /// The daemon does not report its effective configuration, so this is the file as
    /// it stood the last time the engine was *not* running (or at launch). That is
    /// exactly the moment the next `start` will re-read it, which makes it the right
    /// baseline for "restart to apply".
    private(set) var applied: MorbConfig

    private(set) var loadError: String?
    private(set) var saveError: String?

    let url: URL
    let limits: TrackDResourceLimits

    init(url: URL = MorbPaths.configFile, limits: TrackDResourceLimits = .current) {
        self.url = url
        self.limits = limits
        var loaded = MorbConfig()
        var failure: String?
        do {
            loaded = try MorbConfig.load(from: url)
        } catch {
            // A malformed file is shown, not overwritten: the user's comments and their
            // typo both deserve to survive until they choose to save.
            failure = MorbErrorMessage.text(for: error)
        }
        let clamped = TrackDConfigEditor.clamped(loaded, limits: limits)
        self.onDisk = loaded
        self.saved = clamped
        self.draft = clamped
        self.applied = clamped
        self.loadError = failure
    }

    var isDirty: Bool { draft != saved }

    /// Whether the engine is running with something other than what is on disk.
    var needsEngineRestart: Bool {
        TrackDConfigEditor.requiresEngineRestart(from: applied, to: saved)
    }

    var restartSummary: String {
        TrackDConfigEditor.restartSummary(from: applied, to: saved)
    }

    /// Writes the draft, keeping `saved` and the error state in step.
    @discardableResult
    func save() -> Bool {
        let candidate = TrackDConfigEditor.clamped(draft, limits: limits)
        do {
            let changed = MorbConfig.changedKeys(from: saved, to: candidate)
            let persisted = try candidate.savePreservingFile(
                to: url, expected: onDisk, changing: changed)
            let visible = TrackDConfigEditor.clamped(persisted, limits: limits)
            onDisk = persisted
            saved = visible
            draft = visible
            saveError = nil
            loadError = nil
            return true
        } catch {
            saveError = MorbErrorMessage.text(for: error)
            return false
        }
    }

    func revert() {
        draft = saved
        saveError = nil
    }

    /// Re-reads the file, discarding the draft. Used when something else edited it.
    func reload() {
        do {
            let loaded = try MorbConfig.load(from: url)
            let visible = TrackDConfigEditor.clamped(loaded, limits: limits)
            onDisk = loaded
            saved = visible
            draft = visible
            loadError = nil
        } catch {
            loadError = MorbErrorMessage.text(for: error)
        }
    }

    /// Call whenever the engine's state changes.
    ///
    /// A stopped engine will read the file on its next start, so at that moment the
    /// saved config *is* the applied one and the restart banner should go away.
    func engineStateChanged(running: Bool) {
        if !running { applied = saved }
    }
}
