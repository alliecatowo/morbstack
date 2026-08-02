// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation
import Virtualization

/// A single diagnostic line in a ``DoctorReport``.
public struct DoctorCheck: Codable, Equatable, Sendable {

    /// The severity of a check's outcome.
    public enum Status: String, Codable, Sendable {
        /// Everything is as it should be.
        case pass
        /// Usable, but something is missing or degraded.
        case warn
        /// Morbstack cannot work until this is addressed.
        case fail
        /// Informational only.
        case info
    }

    /// Short label, e.g. `architecture`.
    public var name: String
    /// Outcome.
    public var status: Status
    /// Human-readable detail.
    public var detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// The full result of `morb doctor`.
public struct DoctorReport: Codable, Equatable, Sendable {
    /// Version of the CLI that produced the report.
    public var version: String
    /// Individual checks, in display order.
    public var checks: [DoctorCheck]

    /// `true` when no check failed, which is what `morb doctor` reports through its
    /// exit status.
    ///
    /// Only checks that describe a host which *cannot* run Morbstack at all use
    /// `.fail` — wrong architecture, too old a macOS, no Virtualization.framework, a
    /// config file that will not parse. Setup steps the user simply has not done yet
    /// (kernel not fetched, disk image not created, daemon not started) are reported
    /// as `.warn`/`.info` with the exact remedy in their detail text. They are the
    /// expected state immediately after cloning, so letting them fail the whole
    /// report would make a non-zero exit the norm and drain it of any signal.
    public var healthy: Bool { !checks.contains { $0.status == .fail } }
}

/// Host diagnostics that work without a running daemon.
///
/// `morb doctor` is the first thing a user runs when something is wrong, so every
/// check here is standalone: it inspects the host and the filesystem directly.
public enum Doctor {

    /// Runs every check and returns the report.
    public static func run(config: MorbConfig? = nil) -> DoctorReport {
        var checks: [DoctorCheck] = []
        let fm = FileManager.default

        // 1. Architecture — Virtualization.framework Linux VMs need Apple silicon.
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafeBytes(of: &machine.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        checks.append(
            DoctorCheck(
                name: "architecture",
                status: architecture == "arm64" ? .pass : .fail,
                detail: architecture == "arm64"
                    ? "arm64"
                    : "\(architecture) — Morbstack requires Apple silicon"))

        // 2. Host OS.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(
            DoctorCheck(
                name: "macos",
                status: os.majorVersion >= 15 ? .pass : .fail,
                detail: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))

        // 3. Virtualization.framework usability. Linking succeeded (we are running),
        //    so this reduces to the runtime support flag plus the entitlement.
        checks.append(
            DoctorCheck(
                name: "virtualization",
                status: VZVirtualMachine.isSupported ? .pass : .fail,
                detail: VZVirtualMachine.isSupported
                    ? "Virtualization.framework available"
                    : "Virtualization.framework reports the host as unsupported"))

        // 3b. The virtualization entitlement, checked twice: once for the process
        //     running this report and once for the daemon binary that will actually
        //     open the VM. Only the daemon's answer can fail the report — `morb`
        //     itself never creates a VZVirtualMachine, so its own signature is
        //     interesting but harmless either way.
        checks.append(
            DoctorCheck(
                name: "entitlement",
                status: .info,
                detail: MorbEntitlements.currentProcessHasVirtualization()
                    ? "\(MorbEntitlements.virtualization) present on this process"
                    : "\(MorbEntitlements.virtualization) absent from this process "
                        + "(not required for the CLI)"))

        if let daemonURL = MorbExecutable.siblingDaemonURL() {
            let signed = MorbEntitlements.binaryHasVirtualization(at: daemonURL.path)
            checks.append(
                DoctorCheck(
                    name: "daemon-entitlement",
                    status: signed ? .pass : .fail,
                    detail: signed
                        ? "\(daemonURL.path) is signed for virtualization"
                        : "\(daemonURL.path) lacks \(MorbEntitlements.virtualization) — it would be "
                            + "killed on its first VM; \(MorbEntitlements.signHint)"))
        } else {
            checks.append(
                DoctorCheck(
                    name: "daemon-entitlement",
                    status: .info,
                    detail: "no morbstackd next to \(MorbExecutable.currentPath())"))
        }

        // 4. Configuration.
        let loadedConfig: MorbConfig
        if let config {
            loadedConfig = config
            checks.append(DoctorCheck(name: "config", status: .pass, detail: "supplied by caller"))
        } else {
            do {
                loadedConfig = try MorbConfig.load()
                let exists = fm.fileExists(atPath: MorbPaths.configFile.path)
                checks.append(
                    DoctorCheck(
                        name: "config",
                        status: .pass,
                        detail: exists ? MorbPaths.configFile.path : "using built-in defaults (no config.toml)"))
            } catch {
                loadedConfig = MorbConfig()
                checks.append(DoctorCheck(name: "config", status: .fail, detail: "\(error)"))
            }
        }

        // 5. Guest kernel.
        let kernelURL = loadedConfig.resolvedKernelURL
        if fm.fileExists(atPath: kernelURL.path) {
            let size = (try? fm.attributesOfItem(atPath: kernelURL.path)[.size] as? NSNumber)??.int64Value ?? 0
            checks.append(
                DoctorCheck(
                    name: "kernel",
                    status: .pass,
                    detail: "\(kernelURL.path) (\(formatBytes(size)))"))
        } else {
            // Warn, not fail: an un-fetched kernel is the expected state on a fresh
            // checkout, and it is a setup step with a one-line remedy rather than a
            // host that cannot run Morbstack. See `DoctorReport.healthy`.
            checks.append(
                DoctorCheck(
                    name: "kernel",
                    status: .warn,
                    detail: "missing at \(kernelURL.path) — run scripts/fetch-kernel.sh"))
        }

        // 5b. Guest initramfs. Its presence is what selects the boot mode, so report
        //     which command line the daemon will actually use.
        let initrdURL = loadedConfig.resolvedInitrdURL
        if fm.fileExists(atPath: initrdURL.path) {
            let size = (try? fm.attributesOfItem(atPath: initrdURL.path)[.size] as? NSNumber)??.int64Value ?? 0
            checks.append(
                DoctorCheck(
                    name: "initrd",
                    status: .pass,
                    detail: "\(initrdURL.path) (\(formatBytes(size)))"))
        } else {
            // Warn, not fail: like the kernel, this is a build step with a one-line
            // remedy rather than a host that cannot run Morbstack.
            checks.append(
                DoctorCheck(
                    name: "initrd",
                    status: .warn,
                    detail: "missing at \(initrdURL.path) — run `make guest-image` to build it"))
        }

        // 5c. Directory sharing, which is what makes `docker run -v` work at all.
        //
        // Planned rather than merely listed: the plan is the same pure function the
        // daemon boots with, so what this reports is what the VM will actually be
        // configured with, down to the tags.
        let sharePlan: MorbShares.Plan
        do {
            sharePlan = try loadedConfig.sharePlan()
        } catch {
            sharePlan = MorbShares.Plan()
            checks.append(DoctorCheck(name: "shares", status: .fail, detail: "\(error)"))
        }
        appendShareChecks(&checks, plan: sharePlan, config: loadedConfig)

        checks.append(
            DoctorCheck(
                name: "boot-cmdline",
                status: .info,
                detail: "\(loadedConfig.detectedBootMode.rawValue): "
                    + "\"\(bootCmdlineDescription(loadedConfig, shares: sharePlan.shares))\""
                    + (loadedConfig.kernelCmdline == nil ? "" : " (overridden in config.toml)")))

        // 6. Root disk: apparent vs. actually allocated size.
        let diskPath = MorbPaths.diskImage.path
        if fm.fileExists(atPath: diskPath) {
            var info = stat()
            if stat(diskPath, &info) == 0 {
                // st_blocks counts 512-byte units regardless of the filesystem block size.
                let allocated = Int64(info.st_blocks) * 512
                checks.append(
                    DoctorCheck(
                        name: "disk-image",
                        status: .pass,
                        detail: "\(diskPath): \(formatBytes(Int64(info.st_size))) apparent, "
                            + "\(formatBytes(allocated)) on disk"))
            } else {
                checks.append(DoctorCheck(name: "disk-image", status: .warn, detail: "stat(\(diskPath)) failed"))
            }
        } else {
            checks.append(
                DoctorCheck(
                    name: "disk-image",
                    status: .info,
                    detail: "not created yet (will be made on first boot, \(loadedConfig.diskSizeGiB) GiB sparse)"))
        }

        // 7. Saved VM state.
        checks.append(
            DoctorCheck(
                name: "vm-state",
                status: .info,
                detail: fm.fileExists(atPath: MorbPaths.vmState.path)
                    ? "suspended image present at \(MorbPaths.vmState.path)"
                    : "none"))

        // 7b. Suspend-to-disk availability. Virtualization.framework will happily
        //     write a state blob for a direct-kernel guest and then refuse to restore
        //     it, so Morbstack learns the answer by trying once and records it here.
        if fm.fileExists(atPath: MorbPaths.saveRestoreUnsupported.path) {
            checks.append(
                DoctorCheck(
                    name: "suspend-to-disk",
                    status: .warn,
                    detail: "unavailable on this host — the VM is stopped instead of suspended "
                        + "(delete \(MorbPaths.saveRestoreUnsupported.path) to retry)"))
        } else {
            checks.append(
                DoctorCheck(name: "suspend-to-disk", status: .info, detail: "not yet ruled out"))
        }

        // 8. Rosetta. The state-to-text mapping lives in RosettaSupport so this
        // check, the VM configuration, and `morb rosetta` cannot disagree about
        // what the host can do.
        let rosetta = RosettaSupport.state
        checks.append(
            DoctorCheck(name: "rosetta", status: rosetta.doctorStatus, detail: rosetta.detail))

        // 9. Docker CLI.
        if let dockerPath = which("docker") {
            checks.append(DoctorCheck(name: "docker-cli", status: .pass, detail: dockerPath))
        } else {
            checks.append(
                DoctorCheck(
                    name: "docker-cli",
                    status: .warn,
                    detail: "`docker` is not on PATH — install the Docker CLI (brew install docker)"))
        }

        // 10. Docker contexts directory (where `docker context create` writes).
        let contextsDirectory = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker/contexts", isDirectory: true)
        checks.append(
            DoctorCheck(
                name: "docker-contexts",
                status: .info,
                detail: fm.fileExists(atPath: contextsDirectory.path)
                    ? contextsDirectory.path
                    : "no ~/.docker/contexts yet"))

        // 10b. Docker CLI credential helper.
        //
        // Docker Desktop writes `"credsStore": "desktop"` into ~/.docker/config.json.
        // That helper talks to Docker Desktop's own backend, so with Desktop not
        // running (the whole point of Morbstack) the CLI blocks on it *before* it
        // ever reaches our socket: `docker pull` hangs with no output and no
        // timeout, which looks exactly like a broken daemon. Worth naming
        // explicitly — every Docker Desktop refugee starts out in this state.
        let dockerConfig = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker/config.json", isDirectory: false)
        if let data = try? Data(contentsOf: dockerConfig),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let credsStore = json["credsStore"] as? String,
            !credsStore.isEmpty
        {
            let helper = "docker-credential-\(credsStore)"
            if credsStore == "desktop", which(helper) == nil || !isDockerDesktopRunning() {
                checks.append(
                    DoctorCheck(
                        name: "docker-credentials",
                        status: .warn,
                        detail: "~/.docker/config.json sets credsStore \"\(credsStore)\"; that helper "
                            + "needs Docker Desktop running and will hang `docker pull` without it. "
                            + "Remove the credsStore line, or run with "
                            + "DOCKER_CONFIG pointed at a config that omits it."))
            } else {
                checks.append(
                    DoctorCheck(name: "docker-credentials", status: .info, detail: "credsStore \(credsStore)"))
            }
        } else {
            checks.append(
                DoctorCheck(name: "docker-credentials", status: .pass, detail: "no credential helper configured"))
        }

        // 11. Daemon liveness.
        let controlPath = MorbPaths.controlSocket.path
        if UnixSocketClient.isAlive(path: controlPath) {
            checks.append(DoctorCheck(name: "daemon", status: .pass, detail: "responding on \(controlPath)"))
        } else {
            checks.append(
                DoctorCheck(
                    name: "daemon",
                    status: .warn,
                    detail: fm.fileExists(atPath: controlPath)
                        ? "stale socket at \(controlPath) — morbstackd is not running"
                        : "not running (start it with `make run-daemon`)"))
        }

        // 12. Docker socket.
        checks.append(
            DoctorCheck(
                name: "docker-socket",
                status: fm.fileExists(atPath: MorbPaths.dockerSocket.path) ? .pass : .info,
                detail: fm.fileExists(atPath: MorbPaths.dockerSocket.path)
                    ? MorbPaths.dockerSocket.path
                    : "not published (daemon not running)"))

        return DoctorReport(version: MorbVersion.string, checks: checks)
    }

    /// Renders the report as aligned, glyph-prefixed text.
    public static func renderText(_ report: DoctorReport) -> String {
        let width = report.checks.map(\.name.count).max() ?? 0
        var out = "morbstack doctor (\(report.version))\n\n"
        for check in report.checks {
            let padding = String(repeating: " ", count: max(0, width - check.name.count))
            out += "\(glyph(for: check.status))  \(check.name)\(padding)   \(check.detail)\n"
        }
        out += "\n"
        out += report.healthy
            ? "No blocking problems found.\n"
            : "One or more checks failed; Morbstack will not run until they are fixed.\n"
        return out
    }

    /// Renders the report as pretty-printed JSON.
    public static func renderJSON(_ report: DoctorReport) throws -> String {
        try IPCCodec.prettyJSON(report)
    }

    /// The glyph shown in text output for a status.
    public static func glyph(for status: DoctorCheck.Status) -> String {
        switch status {
        case .pass: return "[ok]"
        case .warn: return "[--]"
        case .fail: return "[!!]"
        case .info: return "[..]"
        }
    }

    // MARK: - Shares

    /// The kernel command line the daemon will actually use, share arguments and all.
    ///
    /// Falls back to the base line if the shares push it over the kernel's limit —
    /// the `shares` check above has already failed the report in that case, and
    /// showing the truncated-but-legal line is more useful here than an error.
    private static func bootCmdlineDescription(
        _ config: MorbConfig, shares: [MorbDirectoryShare]
    ) -> String {
        let mode = config.detectedBootMode
        return (try? config.resolvedKernelCmdline(for: mode, shares: shares))
            ?? config.resolvedKernelCmdline(for: mode)
    }

    /// Reports one line per configured shared root, plus a summary line.
    ///
    /// Built on ``MorbShareSurface`` rather than on the plan directly, so that `morb
    /// doctor`, `morb shares` and the app answer the same question the same way. The
    /// rows carry three facts that fail independently and have different remedies —
    /// configured, planned by the host, mounted by the guest — and the report keeps
    /// them apart instead of collapsing them into one "broken".
    ///
    /// Nothing here is a `.fail`: a machine with no shares still runs containers, it
    /// just cannot bind-mount host directories. See ``DoctorReport/healthy``.
    private static func appendShareChecks(
        _ checks: inout [DoctorCheck], plan: MorbShares.Plan, config: MorbConfig
    ) {
        guard !config.sharedPaths.isEmpty else {
            checks.append(
                DoctorCheck(
                    name: "shares",
                    status: .warn,
                    detail: "shared_paths is empty — `docker run -v /host/path:/x` will bind an "
                        + "empty guest directory, not your files"))
            return
        }

        let report = MorbShareSurface.report(
            configured: MorbShareSurface.configuredShares(config: config), live: liveShares())
        let live = report.source == .daemon

        let summary: String
        if report.shares.isEmpty {
            summary = "none of the \(config.sharedPaths.count) configured path(s) can be shared"
        } else if live {
            summary = "\(report.mountedCount) of \(report.shares.count) mounted in the guest, "
                + "each at its own host path"
        } else {
            summary = "\(plan.shares.count) of \(report.shares.count) shareable "
                + "(morbstackd is not running, so nothing is mounted yet)"
        }
        checks.append(
            DoctorCheck(
                name: "shares",
                status: report.shares.isEmpty ? .warn : (report.hasWarning ? .warn : .pass),
                detail: summary))

        for share in report.shares {
            var notes: [String] = []
            if !share.tag.isEmpty { notes.append(share.tag) }
            // Only ever a diagnostic for a share that is already in trouble, never a
            // headline. `access("/Users", W_OK)` is false on every stock Mac — nobody
            // creates files directly in `/Users` — while `/Users/you/project`, the
            // directory anyone actually bind-mounts, is perfectly writable. Printing
            // it unconditionally puts a scary clause on the most common share on every
            // machine and says nothing true about bind mounts.
            if share.rootWritable == false, share.isDegraded {
                notes.append("this process cannot write to the root directory itself")
            }
            notes.append(live ? share.stateDescription : "guest state unknown")
            if let explanation = share.explanation, live || share.skippedReason != nil {
                notes.append(explanation)
            }
            checks.append(
                DoctorCheck(
                    name: "share \(share.path)",
                    status: live ? (share.isDegraded ? .warn : .pass) : .info,
                    detail: notes.joined(separator: ", ")))
        }

        if let configError = report.configError {
            checks.append(DoctorCheck(name: "shares-config", status: .fail, detail: configError))
        }
        if report.shares.contains(where: { $0.path == "/private/tmp" }) {
            checks.append(DoctorCheck(name: "shares-tmp", status: .info, detail: MorbShares.tmpAliasWarning))
        }
    }

    /// Asks a running daemon what the guest did with each share, or `nil` when there
    /// is no daemon to ask — which is not a failure, since `morb doctor` exists to
    /// diagnose hosts on which the daemon is the broken thing.
    private static func liveShares() -> [MorbShareState]? {
        guard FileManager.default.fileExists(atPath: MorbPaths.controlSocket.path),
            let response = try? UnixSocketClient.roundTrip(
                path: MorbPaths.controlSocket.path, request: DaemonRequest(cmd: "shares"), timeout: 5),
            response.ok
        else { return nil }
        return MorbShareSurface.decodeShares(response.data)
    }

    // MARK: - Helpers

    /// Locates an executable on `PATH` using `/usr/bin/which`.
    /// Whether Docker Desktop's backend is up, i.e. whether its credential
    /// helper would actually answer. Checked by socket rather than by process
    /// name: the helper talks to `~/.docker/run/docker-cli-api.sock`, and a
    /// Desktop that is launched but not yet ready hangs just the same.
    private static func isDockerDesktopRunning() -> Bool {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".docker/run/docker-cli-api.sock").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".docker/run/backend.sock").path,
        ]
        return candidates.contains { UnixSocketClient.isAlive(path: $0) }
    }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Formats a byte count with binary units.
    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[index])
    }
}
