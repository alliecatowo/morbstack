// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The one thing this whole harness must never do is take down the engine
// somebody else is using. `morb bench` follows the same `MORBSTACK_HOME`
// convention as every other `morb` subcommand — it measures whatever engine
// that variable points to — which means the harness itself, not the person
// running it, is the only thing standing between "cold-boot benchmark" and
// "cold-booted someone else's Docker Desktop replacement out from under
// them". This file is that guard, checked before any benchmark is allowed to
// stop, start, suspend or resume the VM.

import Foundation
import MorbFeatures
import MorbstackKit

public enum StackGuard {

    /// `true` when the engine this process would talk to is the default,
    /// potentially-shared `~/.morbstack` — either because `MORBSTACK_HOME` is
    /// unset, or because it was set to that same path explicitly.
    public static func isDefaultHome() -> Bool {
        let env = ProcessInfo.processInfo.environment["MORBSTACK_HOME"]
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".morbstack", isDirectory: true).path
        guard let env, !env.isEmpty else { return true }
        let expanded = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true).path
        return expanded == defaultPath
    }

    /// What a quick probe of the target engine found.
    public struct DaemonAvailability {
        public var reachable: Bool
        public var vmState: String?
        /// `nil` when the VM is not running (there is nothing to count) or the
        /// engine could not be reached; `Optional` rather than `0` so "unknown"
        /// and "definitely zero" never collapse into the same value.
        public var runningContainers: Int?
        public var reason: String?
    }

    /// Asks the daemon at the current `MORBSTACK_HOME` what state it is in.
    public static func probe(timeout: TimeInterval = 3) -> DaemonAvailability {
        let controlPath = MorbPaths.controlSocket.path
        guard UnixSocketClient.isAlive(path: controlPath, timeout: timeout) else {
            return DaemonAvailability(
                reachable: false, vmState: nil, runningContainers: nil,
                reason: "no daemon listening on \(controlPath)")
        }
        guard
            let response = try? UnixSocketClient.roundTrip(
                path: controlPath, request: DaemonRequest(cmd: "status"), timeout: timeout),
            response.ok
        else {
            return DaemonAvailability(
                reachable: false, vmState: nil, runningContainers: nil,
                reason: "daemon at \(controlPath) did not answer `status`")
        }
        let vmState = response.data?["state"]?.displayString
        var running: Int?
        if vmState == "running" {
            let engine = EngineClient(socketPath: MorbPaths.dockerSocket.path)
            running = (try? engine.jsonArray("GET", "/containers/json"))?.count
        }
        return DaemonAvailability(reachable: true, vmState: vmState, runningContainers: running, reason: nil)
    }

    /// The reason a benchmark that stops/starts/suspends/resumes the VM must
    /// refuse to run, or `nil` when it is safe to proceed.
    public static func disruptiveOperationBlockReason(_ availability: DaemonAvailability) -> String? {
        if isDefaultHome() {
            return "refusing to cycle the VM at the default MORBSTACK_HOME (\(MorbPaths.root.path)) "
                + "— it may be shared with other work. Point MORBSTACK_HOME at a private stack and "
                + "rerun; see docs/benchmarks.md for the setup."
        }
        if let running = availability.runningContainers, running > 0 {
            return "\(running) container(s) are running at \(MorbPaths.root.path) — cycling the VM "
                + "would kill them without warning. Stop them first."
        }
        return nil
    }

    /// The reason a benchmark that only *observes* the engine (idle CPU,
    /// idle wakeups, host RSS, guest memory floor) must refuse to treat it as
    /// idle, or `nil` when it is safe to proceed. Unlike
    /// ``disruptiveOperationBlockReason(_:)`` this does not forbid the
    /// default home outright — observing costs the shared engine nothing —
    /// but it does refuse to report an "idle" number while other work is
    /// visibly running, because that number would be fiction.
    public static func idleMeasurementBlockReason(_ availability: DaemonAvailability) -> String? {
        if !availability.reachable {
            return availability.reason ?? "no daemon reachable"
        }
        guard availability.vmState == "running" else {
            return "VM is \(availability.vmState ?? "not running") — start it first (`morb start`)"
        }
        if let running = availability.runningContainers, running > 0 {
            return "\(running) container(s) are running — an idle measurement taken now would be "
                + "measuring their activity, not the engine's floor. Stop them first."
        }
        return nil
    }
}
