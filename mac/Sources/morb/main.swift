// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// morb — the Morbstack command line interface.
//
// Exit codes:
//   0  success
//   1  the daemon could not be reached
//   2  the command ran but failed

import Darwin
import Foundation
import MorbBench
import MorbMCP
import MorbMigrate
import MorbScan
import MorbstackKit

// MARK: - Output helpers

let usage = """
    morb \(MorbVersion.string) — control the Morbstack VM

    USAGE:
      morb <command> [--json]

    COMMANDS:
      status       Show daemon and VM state
      start        Boot the VM
      stop         Shut the VM down
      suspend      Release VM memory; a host that cannot restore state stops cleanly
      resume       Start a suspended VM; cold-boots when state cannot be restored
      shares       List the shared host paths and whether the guest has them
      rosetta      Show Rosetta status; `rosetta install` sets it up
      k8s          Run a local Kubernetes cluster (off by default)
      version      Print CLI and daemon versions
      doctor       Diagnose the host; works without the daemon
      diagnose     Create a redacted, reviewable support bundle; never starts the daemon
      disk         Inspect VM disk capacity and safe resize status; never changes it
      ports        Check loopback port availability; never reserves or starts the daemon
      reset-disk   Delete the Docker data disk and start over (destructive)
      mcp          Model Context Protocol server; read-only unless granted
      migrate      Import images, volumes and config from another runtime
      bench        Run the open benchmark suite and report the numbers
      scan         SBOM and CVE scan an image, entirely on this machine
      debug        Open a toolbox shell in a container, even a distroless one
      context      Inspect the `morbstack` Docker context and discovery socket
      service      Manage Morbstack's explicit per-user background service
      install-cli  Install bundled docker, compose, and buildx for this user
      uninstall-cli Remove only the CLI links/socket/context/profile block Morbstack owns
      install-cli-plugins
                   Legacy: install only compose/buildx plugins (prefer install-cli)

    SUBCOMMANDS:
      rosetta install        Install Rosetta and enable it. Always asks first.
      rosetta install --print-plan
                             Print exactly what that would do, and stop.
      k8s status             Show whether the cluster is installed, on, and Ready
      k8s enable             Install the payload if needed, then start the cluster
      k8s disable            Stop the cluster; the payload and its state are kept
      k8s kubeconfig         Write ~/.morbstack/kubeconfig and say how to use it
      k8s kubeconfig --merge Merge the `morbstack` context into ~/.kube/config,
                             after asking, and after taking a timestamped backup
      context status         Show the context and per-user discovery socket state
      context create         Register the `morbstack` docker context. Asks first.
      context use            Make it the default context. Always asks; refuses
                             to replace another explicit default without --force
                             (never stomps — see docs/compat.md).
      service status         Show background-service registration and approval state
      service enable         Register the signed app's per-user LaunchAgent
      service disable        Unregister it; does not stop a manually started daemon
      service settings       Open System Settings > Login Items explicitly
      disk status            Show VM disk capacity and whether a configured change is safe
      ports check --tcp <port>
      ports check --udp <port>
                             Check one or more loopback endpoints before a Docker
                             publish. Results are snapshots, not reservations.
      install-cli --make-default
                             Put Morbstack's docker before an existing docker on PATH.

    OPTIONS:
      --json     Emit raw JSON instead of human-readable output
      --force    Skip Morbstack's confirmation prompt (reset-disk, context
                 create, install-cli, uninstall-cli, install-cli-plugins), replace another explicit
                 default context (context use), or stop the VM without asking
                 the guest first (stop). Deliberately refused by
                 `rosetta install`: that installs system software under
                 Apple's licence, so it always asks the person at the
                 keyboard. Use --print-plan, or run
                 `softwareupdate --install-rosetta` yourself.
      --print-plan
                 Print what a command would do and exit without doing it
                 (rosetta install, install-cli, uninstall-cli, install-cli-plugins).
      --output <directory>
                 Write `morb diagnose` output below this absolute or ~/ directory.
      --make-default
                 Let install-cli add ~/.morbstack/bin before an existing docker on PATH.
      --help     Print this help
    """

func out(_ message: String) {
    print(message)
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("morb: " + message + "\n").utf8))
    exit(code)
}

/// Prints `key   value` pairs with the keys padded to a common width.
func printAligned(_ rows: [(String, String)]) {
    let width = rows.map(\.0.count).max() ?? 0
    for (key, value) in rows {
        let padding = String(repeating: " ", count: max(0, width - key.count))
        out("  \(key)\(padding)   \(value)")
    }
}

/// A small status glyph for a VM state token.
func glyph(forState token: String) -> String {
    switch token {
    case "running": return "[ok]"
    case "suspended": return "[zz]"
    case "stopped": return "[--]"
    case "error": return "[!!]"
    default: return "[..]"
    }
}

/// The distinct outcome vocabulary used by the post-setup read-back report.
func glyph(forVerification status: MorbSetupVerification.Status) -> String {
    switch status {
    case .pass: return "[ok]"
    case .info: return "[..]"
    case .warning: return "[--]"
    case .failure: return "[!!]"
    }
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
var wantsJSON = false
arguments.removeAll { argument in
    if argument == "--json" {
        wantsJSON = true
        return true
    }
    return false
}

if arguments.contains("--help") || arguments.contains("-h") {
    out(usage)
    exit(0)
}

guard let command = arguments.first else {
    out(usage)
    exit(0)
}
let extraArguments = Array(arguments.dropFirst())

// MARK: - Daemon discovery

/// Why an auto-spawn attempt did not happen.
enum SpawnFailure: Error {
    /// No `morbstackd` next to this `morb`.
    case notFound
    /// Found, but unsigned: spawning it would only produce a SIGKILL.
    case notEntitled(String)
    /// `posix_spawn` itself failed.
    case launchFailed(String)
}

/// Launches a sibling `morbstackd` detached from this process.
///
/// Refuses to spawn a daemon that is not signed for virtualization. Without the
/// check the daemon starts, gets SIGKILLed by the kernel the instant it creates a
/// VM, and `morb` reports nothing more useful than "could not reach morbstackd" —
/// with the actual cause, a missing signature, never mentioned anywhere.
func spawnDaemon(forCommand command: String = "") -> Result<Void, SpawnFailure> {
    guard let daemonURL = MorbExecutable.siblingDaemonURL() else {
        return .failure(.notFound)
    }
    guard MorbEntitlements.binaryHasVirtualization(at: daemonURL.path) else {
        return .failure(.notEntitled(daemonURL.path))
    }

    let process = Process()
    process.executableURL = daemonURL
    // `--started-by` is provenance only: it makes the daemon log say which CLI
    // invocation conjured it. A daemon nobody remembers launching is
    // indistinguishable from one somebody else launched, and telling those two
    // apart by hand costs far more than carrying one string.
    process.arguments = ["--foreground", "--quiet"]
    if !command.isEmpty {
        process.arguments?.append(contentsOf: ["--started-by", "morb \(command)"])
    }
    // Detach: the daemon must outlive this CLI invocation.
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        return .success(())
    } catch {
        return .failure(.launchFailed("\(error)"))
    }
}

/// Sends `request`, auto-starting the daemon once if the socket is not
/// answering *and* this command is one that may do so
/// (see ``MorbCommandPolicy``).
func callDaemon(
    _ request: DaemonRequest, timeout: TimeInterval = Daemon.clientTimeout
) -> DaemonResponse {
    let socketPath = MorbPaths.controlSocket.path
    if let response = try? UnixSocketClient.roundTrip(path: socketPath, request: request, timeout: timeout) {
        return response
    }

    guard MorbCommandPolicy.mayAutoStartDaemon(request.cmd) else {
        // Not an error: "nothing is running" is a complete and correct answer to
        // `stop`, `status` and `suspend`. Exit 0 so scripts that stop things
        // unconditionally (including our own teardown paths) stay clean.
        finish(
            .success([
                "state": .string("stopped"),
                "vm_state": .string("stopped"),
                "daemon_running": .bool(false),
            ])
        ) { _ in
            out("[--] morbstack stopped (morbstackd is not running)")
        }
    }

    if case .failure(let reason) = spawnDaemon(forCommand: request.cmd) {
        switch reason {
        case .notFound:
            fail(
                "morbstackd is not running and no sibling binary was found.\n"
                    + "       Start it with `make run-daemon` (or run morbstackd directly).",
                code: 1)
        case .notEntitled(let path):
            fail(
                "morbstackd is not running, and \(path) is not signed with\n"
                    + "       \(MorbEntitlements.virtualization) — starting it would only get it killed.\n"
                    + "       Fix it with `make sign`, then retry.",
                code: 1)
        case .launchFailed(let message):
            fail("morbstackd is not running and could not be started: \(message)", code: 1)
        }
    }

    // Poll for up to three seconds while the daemon binds its socket.
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if let response = try? UnixSocketClient.roundTrip(path: socketPath, request: request, timeout: timeout) {
            return response
        }
        usleep(100_000)
    }
    fail(
        "could not reach morbstackd at \(socketPath) after starting it.\n"
            + "       Check \(MorbPaths.daemonLog.path), or run `make run-daemon` in the foreground.",
        code: 1)
}

/// Asks the daemon a question, and settles for silence.
///
/// The counterpart to ``callDaemon`` for commands that have a real answer without a
/// daemon: `shares` reads `config.toml`, `rosetta` inspects the host. Both are pure
/// observations, so both fall under the same rule as `status` — an observation that
/// creates the thing it observes is not an observation — and neither may spawn.
///
/// Enforced here rather than trusted to the caller: this function *cannot* spawn, so a
/// future edit that adds one of these commands to
/// ``MorbCommandPolicy/autoStartingCommands`` still cannot make `morb shares` boot a VM.
/// The `precondition` is there to make that edit fail loudly instead of silently.
func probeDaemon(_ request: DaemonRequest, timeout: TimeInterval = 5) -> DaemonResponse? {
    precondition(
        !MorbCommandPolicy.mayAutoStartDaemon(request.cmd),
        "`\(request.cmd)` is a read-only observation and must not be an auto-starting command")
    guard FileManager.default.fileExists(atPath: MorbPaths.controlSocket.path) else { return nil }
    guard let response = try? UnixSocketClient.roundTrip(
        path: MorbPaths.controlSocket.path, request: request, timeout: timeout)
    else { return nil }
    return response
}

/// Prints a response and exits with the right code.
func finish(_ response: DaemonResponse, render: (([String: AnyCodableValue]) -> Void)? = nil) -> Never {
    if wantsJSON {
        if let json = try? IPCCodec.prettyJSON(response) {
            out(json)
        }
        exit(response.ok ? 0 : 2)
    }
    guard response.ok else {
        fail(response.error ?? "command failed", code: 2)
    }
    if let render {
        render(response.data ?? [:])
    } else if let data = response.data, !data.isEmpty {
        printAligned(data.keys.sorted().map { ($0, data[$0]?.displayString ?? "-") })
    } else {
        out("ok")
    }
    exit(0)
}

// MARK: - Commands

switch command {

case "doctor":
    let report = Doctor.run()
    if wantsJSON {
        out((try? Doctor.renderJSON(report)) ?? "{}")
    } else {
        out(Doctor.renderText(report))
    }
    exit(report.healthy ? 0 : 2)

case "disk":
    let action = extraArguments.first ?? "status"
    guard extraArguments.count == 1 || extraArguments.isEmpty else {
        fail("disk accepts one action: status", code: 2)
    }
    guard action == "status" else {
        fail("unknown disk action `\(action)`; expected status", code: 2)
    }

    let config: MorbConfig
    do {
        config = try MorbConfig.load()
    } catch {
        fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
    }
    let capacity = MorbDiskCapacity.inspect(configuredGiB: config.diskSizeGiB)
    let fields: [String: AnyCodableValue] = [
        "path": .string(capacity.imagePath),
        "configured_gib": .int(capacity.configuredGiB),
        "configured_bytes": .int(Int(capacity.configuredBytes)),
        "current_bytes": capacity.currentBytes.map { .int(Int($0)) } ?? .null,
        "state": .string(capacity.state.rawValue),
        "message": .string(capacity.summary),
        "inspection_error": capacity.inspectionError.map(AnyCodableValue.string) ?? .null,
    ]
    finish(.success(fields)) { _ in
        printAligned([
            ("disk image", capacity.imagePath),
            ("configured", "\(capacity.configuredGiB) GiB"),
            ("current", capacity.currentBytes.map { "\($0) bytes" } ?? "not created"),
            ("resize", capacity.state.rawValue),
        ])
        out("\n  \(capacity.summary)")
        if let inspectionError = capacity.inspectionError {
            out("  \(inspectionError)")
        }
    }

case "ports":
    // A local bind snapshot is useful before `docker run -p`, but it deliberately
    // never goes through callDaemon/probeDaemon and never claims to reserve a port.
    let portSubcommand: String
    let portArguments: [String]
    if let first = extraArguments.first, !first.hasPrefix("-") {
        portSubcommand = first
        portArguments = Array(extraArguments.dropFirst())
    } else {
        portSubcommand = "check"
        portArguments = extraArguments
    }
    guard portSubcommand == "check" else {
        fail("unknown ports subcommand `\(portSubcommand)` (expected `check`)", code: 2)
    }

    var requests: [(HostPortPreflight.Transport, Int)] = []
    var portIndex = 0
    while portIndex < portArguments.count {
        let argument = portArguments[portIndex]
        let transport: HostPortPreflight.Transport
        let rawPort: String
        switch argument {
        case "--tcp", "--udp":
            guard portIndex + 1 < portArguments.count else {
                fail("ports check \(argument) needs a port", code: 2)
            }
            transport = argument == "--tcp" ? .tcp : .udp
            rawPort = portArguments[portIndex + 1]
            portIndex += 2
        default:
            if argument.hasPrefix("--tcp=") {
                transport = .tcp
                rawPort = String(argument.dropFirst("--tcp=".count))
                portIndex += 1
            } else if argument.hasPrefix("--udp=") {
                transport = .udp
                rawPort = String(argument.dropFirst("--udp=".count))
                portIndex += 1
            } else {
                fail("unknown ports check option `\(argument)` (expected --tcp <port> or --udp <port>)", code: 2)
            }
        }
        guard let port = Int(rawPort) else {
            fail("ports check needs an integer port, got `\(rawPort)`", code: 2)
        }
        requests.append((transport, port))
    }
    guard !requests.isEmpty else {
        fail("ports check needs at least one --tcp <port> or --udp <port>", code: 2)
    }

    let results = requests.map { HostPortPreflight.check(port: $0.1, transport: $0.0) }
    let hasUnavailable = results.contains { $0.availability != .available }
    if wantsJSON {
        out((try? IPCCodec.prettyJSON(results)) ?? "[]")
    } else {
        for result in results {
            let marker: String
            switch result.availability {
            case .available: marker = result.publication == .loopbackOnly ? "[ok]" : "[--]"
            case .inUse, .invalid, .unavailable: marker = "[!!]"
            }
            out("\(marker) \(result.transport.rawValue) \(result.bindAddress):\(result.port) — \(result.detail)")
        }
        out("")
        out("TCP publishes on 127.0.0.1 only; Morbstack never exposes a container port to the LAN.")
        out("A free result is a point-in-time check, not a reservation. UDP is checked but not forwarded yet.")
    }
    exit(hasUnavailable ? 2 : 0)

case "diagnose":
    // A support bundle is intentionally local-only. Do not route this through
    // `probeDaemon` either: the collector's declared inputs are host metadata,
    // sanitized Doctor checks, and bounded tails of Morbstack-owned text logs.
    var requestedOutput: String?
    var argumentIndex = 0
    while argumentIndex < extraArguments.count {
        let argument = extraArguments[argumentIndex]
        if argument == "--output" {
            guard argumentIndex + 1 < extraArguments.count else {
                fail("diagnose --output needs a directory", code: 2)
            }
            guard requestedOutput == nil else {
                fail("diagnose accepts only one --output directory", code: 2)
            }
            requestedOutput = extraArguments[argumentIndex + 1]
            argumentIndex += 2
        } else if argument.hasPrefix("--output=") {
            guard requestedOutput == nil else {
                fail("diagnose accepts only one --output directory", code: 2)
            }
            let value = String(argument.dropFirst("--output=".count))
            guard !value.isEmpty else { fail("diagnose --output needs a directory", code: 2) }
            requestedOutput = value
            argumentIndex += 1
        } else {
            fail("unknown diagnose option `\(argument)` (expected --output <directory>)", code: 2)
        }
    }

    let outputDirectory: URL
    if let requestedOutput {
        let expanded = (requestedOutput as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            fail("diagnose --output must be an absolute path or begin with ~/", code: 2)
        }
        outputDirectory = URL(fileURLWithPath: expanded, isDirectory: true)
    } else {
        outputDirectory = MorbDiagnostics.defaultOutputDirectory
    }
    do {
        let result = try MorbDiagnostics.collect(outputDirectory: outputDirectory)
        if wantsJSON {
            let payload: [String: AnyCodableValue] = [
                "directory": .string(result.directory),
                "created_at": .string(result.createdAt),
                "files": .array(result.files.map(AnyCodableValue.string)),
                "warnings": .array(result.warnings.map(AnyCodableValue.string)),
            ]
            out((try? IPCCodec.prettyJSON(DaemonResponse.success(payload))) ?? "{}")
        } else {
            out("[ok] created redacted diagnostics bundle")
            out("     \(result.directory)")
            if !result.warnings.isEmpty {
                for warning in result.warnings {
                    out("[--] \(warning)")
                }
            }
            out("Review README.txt and report.json before sharing the directory.")
        }
    } catch {
        fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
    }

case "version":
    // The local version always prints; the daemon's is best-effort so `morb version`
    // never fails just because nothing is running.
    let socketPath = MorbPaths.controlSocket.path
    let daemonVersion: String? = {
        guard let response = try? UnixSocketClient.roundTrip(
            path: socketPath, request: DaemonRequest(cmd: "version"), timeout: 5),
            response.ok
        else { return nil }
        if case .string(let value)? = response.data?["version"] { return value }
        return nil
    }()

    if wantsJSON {
        var payload: [String: AnyCodableValue] = ["morb": .string(MorbVersion.string)]
        payload["morbstackd"] = daemonVersion.map { AnyCodableValue.string($0) } ?? .null
        out((try? IPCCodec.prettyJSON(DaemonResponse.success(payload))) ?? "{}")
    } else {
        printAligned([
            ("morb", MorbVersion.string),
            ("morbstackd", daemonVersion ?? "not running"),
        ])
    }
    exit(0)

case "service":
    let action = extraArguments.first ?? "status"
    guard extraArguments.count == 1 || extraArguments.isEmpty else {
        fail("service accepts one action: status, enable, disable, or settings", code: 2)
    }

    func renderService(_ status: MorbBackgroundService.Status) -> Never {
        finish(.success(status.ipcFields)) { data in
            let glyph: String
            switch status.registration {
            case .enabled: glyph = "[ok]"
            case .requiresApproval: glyph = "[..]"
            case .notRegistered, .unavailable, .notFound, .unknown: glyph = "[--]"
            }
            out("\(glyph) Morbstack background service \(status.registration.rawValue)")
            printAligned([
                ("launch agent", status.plistPath ?? "not available from this executable"),
                ("control socket", status.controlSocketPath),
                ("socket present", status.controlSocketPresent ? "yes" : "no"),
                ("diagnostic", status.diagnostic),
            ])
        }
    }

    switch action {
    case "status":
        renderService(MorbBackgroundService.status())
    case "enable":
        do {
            renderService(try MorbBackgroundService.enable())
        } catch {
            fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
        }
    case "disable":
        do {
            renderService(try MorbBackgroundService.disable())
        } catch {
            fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
        }
    case "settings":
        // Opening Login Items is a direct, user-requested action. No service is
        // registered as a side effect; people retain control over the switch there.
        MorbBackgroundService.openLoginItemsSettings()
        finish(.success(["settings": .string("Login Items")])) { _ in
            out("opened System Settings > Login Items")
        }
    default:
        fail("unknown service action `\(action)`; expected status, enable, disable, or settings", code: 2)
    }

case "status":
    let response = callDaemon(DaemonRequest(cmd: "status"), timeout: 15)
    finish(response) { data in
        let token = data["state"]?.displayString ?? "unknown"
        out("\(glyph(forState: token)) morbstack \(token)")

        // Absent means "the guest never told us", which is not the same as "no".
        let storage: String
        switch data["docker_data_on_disk"] {
        case .bool(true): storage = "disk (persists across restarts)"
        case .bool(false): storage = "tmpfs (lost on stop)"
        default: storage = "unknown"
        }

        printAligned([
            ("vm", data["vm_state"]?.displayString ?? "-"),
            ("guest control", data["guest_control"]?.displayString ?? "-"),
            ("docker", data["docker_ready"]?.displayString == "true" ? "ready" : "not ready"),
            ("docker data", storage),
            ("connections", data["active_connections"]?.displayString ?? "0"),
            ("docker socket", data["docker_socket"]?.displayString ?? MorbPaths.dockerSocket.path),
            ("cpus", data["cpus"]?.displayString ?? "-"),
            ("memory", (data["memory_mib"]?.displayString).map { "\($0) MiB" } ?? "-"),
            ("auto-suspend", (data["auto_suspend_minutes"]?.displayString).map { $0 == "0" ? "off" : "\($0)m" } ?? "-"),
            ("daemon", data["version"]?.displayString ?? "-"),
        ])

        // Published ports are the thing a user is most likely to be checking for, so
        // they get their own block rather than a comma-joined value in the table.
        if case .array(let forwards)? = data["port_forwards"], !forwards.isEmpty {
            let live = data["forwarded_connections"]?.displayString ?? "0"
            out("")
            out("  published ports (\(forwards.count), \(live) live connection(s))")
            for forward in forwards {
                out("    127.0.0.1:\(forward.displayString)")
            }
        }

        // A port Docker published that the Mac side could not bind is invisible
        // everywhere else — `docker ps` reports it as published regardless — so this
        // block is the only place a user can find out why nothing answers.
        if case .array(let failed)? = data["failed_port_forwards"], !failed.isEmpty {
            out("")
            out("  unavailable ports (\(failed.count))")
            for failure in failed {
                out("    \(failure.displayString)")
            }
        }
    }

case "shares":
    // Answerable without a daemon, and usefully so: "these three roots are configured
    // and none of them is mounted because nothing is running" is the exact state a user
    // is in when they are wondering why their bind mount is empty. So the config is read
    // first and the daemon, if there is one, is layered over the top.
    let sharesReply = probeDaemon(DaemonRequest(cmd: "shares"), timeout: 10)
    let sharesReport = MorbShareSurface.report(
        configured: MorbShareSurface.configuredShares(fromFile: MorbPaths.configFile),
        live: (sharesReply?.ok == true) ? MorbShareSurface.decodeShares(sharesReply?.data) : nil)
    let shares = sharesReport.shares
    let sharesAreLive = sharesReport.source == .daemon

    finish(.success([
        "shares": MorbShareSurface.encode(shares),
        "degraded": .int(sharesReport.degradedCount),
        // Which of the two answers this is. A script that cares whether "not mounted"
        // means "the guest says so" or "there is no guest to ask" needs this, and it is
        // not recoverable from the share entries alone.
        "source": .string(sharesReport.source.rawValue),
        "daemon_running": .bool(sharesAreLive),
        "config_error": sharesReport.configError.map { AnyCodableValue.string($0) } ?? .null,
    ])) { _ in
        if let configError = sharesReport.configError {
            out("[!!] \(configError)")
            out("")
        }

        guard !shares.isEmpty else {
            out("[--] no shared paths configured")
            out("    Every bind mount will be empty inside the container. Add paths with")
            out("    `shared_paths = [\"/Users\"]` in \(MorbPaths.configFile.path).")
            return
        }

        if !sharesAreLive {
            out("[--] \(shares.count) shared path(s) configured (morbstackd is not running)")
        } else if sharesReport.degradedCount > 0 {
            out("[!!] \(shares.count) shared path(s), \(sharesReport.mountedCount) mounted, "
                + "\(sharesReport.degradedCount) missing")
        } else {
            out("[ok] \(shares.count) shared path(s), all mounted")
        }
        out("")

        let pathWidth = max(4, shares.map(\.path.count).max() ?? 4)
        func pad(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }
        let indent = "  " + pad("", pathWidth) + "   "

        out("  \(pad("PATH", pathWidth))   STATE")
        for share in shares {
            // Without a daemon the mount state is not `false`, it is unknown, and
            // printing "not mounted" for a stopped VM would be an invented failure. A
            // host-side skip is knowable either way, so it still shows.
            let state = sharesAreLive
                ? share.stateDescription
                : (share.skippedReason != nil ? "skipped" : "unknown")
            var row = "  \(pad(share.path, pathWidth))   \(state)"
            if !share.configured { row += "   (not in shared_paths)" }
            out(row)
            if let explanation = share.explanation, sharesAreLive || share.skippedReason != nil {
                out(indent + explanation)
            }
            // The invariant is that these are equal. Printing the guest path only when it
            // is not keeps ordinary output clean and makes a violation impossible to miss
            // rather than impossible to see.
            if !share.isSamePath {
                out(indent + "in guest: \(share.guestPath)")
            }
        }

        out("")
        // The sentence that prevents the most common misunderstanding: people expect a
        // Docker Desktop-style "file sharing" list to be a translation table.
        out("  Shared paths are mounted at the same absolute path inside the guest, so")
        out("  `-v /Users/you/project:/app` needs no translation. A bind mount whose host")
        out("  path is not under one of these roots will be empty in the container.")
        if !sharesAreLive {
            out("")
            out("  Run `morb start` to find out which of them the guest actually has.")
        }
    }

case "context":
    // Docker connection setup is host-only: nothing here spawns the daemon. Context
    // metadata follows $DOCKER_CONFIG, while the conventional discovery socket is the
    // user-owned ~/.docker/run/docker.sock location used by Docker-aware tools.
    let contextSubcommand = extraArguments.first { !$0.hasPrefix("-") } ?? "status"

    func renderContextStatus(_ status: MorbDockerContext.Status) {
        if status.registered && status.matchesSocket {
            out("[ok] context \"\(MorbDockerContext.name)\" is registered and points at the right socket")
        } else if status.registered {
            out("[!!] context \"\(MorbDockerContext.name)\" is registered but points elsewhere")
            out("     registered: \(status.registeredHost ?? "-")")
            out("     expected:   unix://\(status.socketPath)")
            out("     Run `morb context create` to fix it.")
        } else {
            out("[--] context \"\(MorbDockerContext.name)\" is not registered")
            out("     Run `morb context create` to add it.")
        }
        out("")
        out("  current context: \(status.currentContext)"
            + (status.isCurrent ? " (morbstack)" : ""))
        if !status.isCurrent {
            if status.wouldRefuseUse {
                out("  `morb context use` will refuse to switch: \"\(status.currentContext)\" is an")
                out("  explicit non-default context, and Morbstack never stomps one. Pass --force")
                out("  to switch anyway, or run `docker context use \(MorbDockerContext.name)` yourself.")
            } else {
                out("  Run `morb context use` to make \"\(MorbDockerContext.name)\" the default —")
                out("  it always asks first.")
            }
        }
        out("")
        out("  docker config directory: \(status.dockerConfigDirectory)")
        out("")
        let directSocket = MorbDockerContext.directSocketStatus()
        switch directSocket.state {
        case .correct:
            out("[ok] conventional Docker discovery socket points at Morbstack")
            out("     \(directSocket.path) -> \(directSocket.expectedDestination)")
        case .missing:
            out("[--] conventional Docker discovery socket is not linked")
            out("     `morb install-cli` can create the user-owned link:")
            out("     \(directSocket.path) -> \(directSocket.expectedDestination)")
        case .pointsElsewhere(let destination):
            out("[--] conventional Docker discovery socket belongs to another target; preserved")
            out("     \(directSocket.path) -> \(destination)")
        case .occupied(let kind):
            out("[--] conventional Docker discovery socket is occupied by an existing \(kind); preserved")
            out("     \(directSocket.path)")
        case .unavailable(let reason):
            out("[--] conventional Docker discovery socket is not safe for Morbstack to manage")
            out("     \(reason)")
        }
        out("")
        out("  Optional: some tools (older scripts, some IDE defaults) still look for the")
        out("  conventional \(MorbDockerContext.systemSocketPath) before trying a context or")
        out("  DOCKER_HOST. Morbstack never creates that symlink itself — it is a system")
        out("  path outside \(MorbPaths.root.path) — but if you want it, run:")
        out("      \(MorbDockerContext.suggestedSymlinkCommand())")
        out("  (only if nothing else already owns that path).")
    }

    switch contextSubcommand {
    case "status":
        let status = MorbDockerContext.status()
        let directSocket = MorbDockerContext.directSocketStatus()
        let directSocketState: String
        let directSocketExistingDestination: AnyCodableValue
        switch directSocket.state {
        case .missing:
            directSocketState = "missing"
            directSocketExistingDestination = .null
        case .correct:
            directSocketState = "correct"
            directSocketExistingDestination = .string(directSocket.expectedDestination)
        case .pointsElsewhere(let destination):
            directSocketState = "points_elsewhere"
            directSocketExistingDestination = .string(destination)
        case .occupied(let kind):
            directSocketState = "occupied_\(kind)"
            directSocketExistingDestination = .null
        case .unavailable(let reason):
            directSocketState = "unavailable"
            directSocketExistingDestination = .string(reason)
        }
        finish(.success([
            "name": .string(MorbDockerContext.name),
            "registered": .bool(status.registered),
            "registered_host": status.registeredHost.map { AnyCodableValue.string($0) } ?? .null,
            "matches_socket": .bool(status.matchesSocket),
            "current_context": .string(status.currentContext),
            "is_current": .bool(status.isCurrent),
            "docker_config_directory": .string(status.dockerConfigDirectory),
            "socket_path": .string(status.socketPath),
            "direct_socket_path": .string(directSocket.path),
            "direct_socket_expected_destination": .string(directSocket.expectedDestination),
            "direct_socket_state": .string(directSocketState),
            "direct_socket_existing_destination": directSocketExistingDestination,
            "system_socket_symlink_command": .string(MorbDockerContext.suggestedSymlinkCommand()),
        ])) { _ in renderContextStatus(status) }

    case "create":
        let before = MorbDockerContext.status()
        if before.registered && before.matchesSocket {
            finish(.success([
                "created": .bool(false),
                "already_correct": .bool(true),
            ])) { _ in
                out("[ok] context \"\(MorbDockerContext.name)\" already exists and is correct; nothing to do")
            }
        }
        if !extraArguments.contains("--force") {
            out("`morb context create` will write:")
            out("  \(MorbDockerContext.metaFile(dockerConfigDirectory: MorbDockerContext.dockerConfigDirectory()).path)")
            out("registering a docker context named \"\(MorbDockerContext.name)\" that points at")
            out("\(MorbPaths.dockerSocket.path).")
            out("It will NOT change your current/default context — run `morb context use`")
            out("separately for that, which asks again.")
            out("")
            guard isatty(STDIN_FILENO) == 1 else {
                fail(
                    "context create needs confirmation and stdin is not a terminal.\n"
                        + "       Re-run with --force if you really mean it.", code: 2)
            }
            FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
            let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
            guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
                fail("cancelled; nothing was changed", code: 2)
            }
        }
        do {
            let wrote = try MorbDockerContext.create()
            finish(.success(["created": .bool(wrote)])) { _ in
                out("[ok] context \"\(MorbDockerContext.name)\" \(wrote ? "created" : "already correct")")
                out("     Run `morb context use` to make it the default, or point a single")
                out("     command at it with `DOCKER_CONTEXT=\(MorbDockerContext.name) docker ...`.")
            }
        } catch {
            fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
        }

    case "use":
        let force = extraArguments.contains("--force")
        let status = MorbDockerContext.status()
        if status.isCurrent {
            finish(.success(["switched": .bool(false), "already_current": .bool(true)])) { _ in
                out("[ok] \"\(MorbDockerContext.name)\" is already the current context")
            }
        }
        if !status.registered || !status.matchesSocket {
            fail(
                "context \"\(MorbDockerContext.name)\" is not registered (or is stale).\n"
                    + "       Run `morb context create` first.", code: 2)
        }
        if status.wouldRefuseUse && !force {
            out("Current context is \"\(status.currentContext)\", an explicit non-default context.")
            out("Morbstack never stomps that without being told to (docs/compat.md).")
            fail(
                "refusing to change the default context without --force.\n"
                    + "       Re-run with --force, or switch it yourself with\n"
                    + "       `docker context use \(MorbDockerContext.name)`.", code: 2)
        }
        out("`morb context use\(force ? " --force" : "")` will set the current docker context")
        out("to \"\(MorbDockerContext.name)\" in "
            + "\(MorbDockerContext.configFile(dockerConfigDirectory: MorbDockerContext.dockerConfigDirectory()).path),")
        out("preserving every other key in that file (credsStore, credHelpers, etc).")
        if status.wouldRefuseUse {
            out("This REPLACES the current explicit context (\"\(status.currentContext)\") — that is")
            out("what --force means here.")
        }
        out("")
        guard isatty(STDIN_FILENO) == 1 else {
            fail(
                "context use needs confirmation and stdin is not a terminal.\n"
                    + "       This command has no non-interactive form: switching the default\n"
                    + "       context is exactly the kind of change docs/compat.md promises never\n"
                    + "       happens silently. Run `docker context use \(MorbDockerContext.name)`\n"
                    + "       yourself for a scriptable equivalent.", code: 2)
        }
        FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            fail("cancelled; nothing was changed", code: 2)
        }
        do {
            let result = try MorbDockerContext.use(force: force)
            switch result {
            case .current:
                finish(.success(["switched": .bool(true)])) { _ in
                    out("[ok] current context is now \"\(MorbDockerContext.name)\"")
                }
            case .refused(let current):
                // Only reachable if something changed `currentContext` between the check
                // above and now; still handled rather than asserted impossible.
                fail("current context changed to \"\(current)\" concurrently; re-run to retry", code: 2)
            }
        } catch {
            fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
        }

    default:
        fail(
            "unknown context subcommand `\(contextSubcommand)` (expected `status`, `create`, or `use`)",
            code: 2)
    }

case "install-cli-plugins":
    // Also host-only: symlinking into ~/.docker/cli-plugins never needs the daemon.
    let plan = MorbCliPlugins.plan()
    let force = extraArguments.contains("--force")

    if plan.isEmpty {
        fail(
            "no plugin binaries found next to \(MorbExecutable.currentPath()) or under a\n"
                + "       dist/host-bin checkout. Run `scripts/fetch-guest-assets.sh --compose-only`\n"
                + "       and `--buildx-only` first (see dist/host-bin/PROVENANCE.txt).", code: 2)
    }

    func renderPlan() {
        out("`morb install-cli-plugins` will symlink into \(plan.directory):")
        out("")
        for item in plan.items {
            guard let source = item.source else {
                out("  docker-\(item.plugin): SKIPPED — no source binary found")
                continue
            }
            if item.alreadyCorrect {
                out("  docker-\(item.plugin): already correct (\(item.destination) -> \(source))")
            } else if item.willReplace {
                out("  docker-\(item.plugin): \(item.destination) -> \(source)")
                out("      REPLACES an existing file/symlink at that path")
            } else {
                out("  docker-\(item.plugin): \(item.destination) -> \(source)")
            }
        }
        out("")
        out("Nothing outside \(plan.directory) is touched, and no other key in")
        out("config.json is read or written.")
    }

    if extraArguments.contains("--print-plan") {
        renderPlan()
        out("")
        out("  Nothing was changed. Re-run without --print-plan to go ahead.")
        exit(0)
    }

    if !force {
        renderPlan()
        out("")
        guard isatty(STDIN_FILENO) == 1 else {
            fail(
                "install-cli-plugins needs confirmation and stdin is not a terminal.\n"
                    + "       Re-run with --force if you really mean it, or see the manual\n"
                    + "       one-liner in dist/host-bin/PROVENANCE.txt.", code: 2)
        }
        FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            fail("cancelled; nothing was changed", code: 2)
        }
    }

    let outcomes = MorbCliPlugins.install()
    var jsonOutcomes: [String: AnyCodableValue] = [:]
    var anyFailed = false
    for outcome in outcomes {
        switch outcome {
        case .linked(let name): jsonOutcomes[name] = .string("linked")
        case .alreadyCorrect(let name): jsonOutcomes[name] = .string("already_correct")
        case .sourceMissing(let name): jsonOutcomes[name] = .string("source_missing")
        case .failed(let name, let reason):
            jsonOutcomes[name] = .string("failed: \(reason)")
            anyFailed = true
        }
    }
    finish(anyFailed ? .failure("one or more plugins could not be installed") : .success(jsonOutcomes)) { _ in
        for outcome in outcomes {
            switch outcome {
            case .linked(let name): out("[ok] docker-\(name) linked")
            case .alreadyCorrect(let name): out("[ok] docker-\(name) already correct")
            case .sourceMissing(let name): out("[--] docker-\(name): no source binary found, skipped")
            case .failed(let name, let reason): out("[!!] docker-\(name): \(reason)")
            }
        }
        out("")
        out("Verify with `docker compose version` and `docker buildx version`.")
    }

case "install-cli":
    // The complete L1 setup, intentionally host-only: it never starts a VM or touches
    // Docker data.  The app's first-run sheet can invoke the same MorbstackKit method
    // after its own consent UI; this CLI command is the transparent terminal equivalent.
    let force = extraArguments.contains("--force")
    let makeDefault = extraArguments.contains("--make-default")
    let installPlan = MorbCliInstallation.plan(makeDefault: makeDefault)

    guard installPlan.hasCompleteToolchain else {
        fail(
            "the bundled Docker CLI toolchain is incomplete.\n"
                + "       Expected docker, docker-compose, and docker-buildx next to this Morbstack build.\n"
                + "       A source checkout needs `scripts/fetch-guest-assets.sh --host-cli`;\n"
                + "       a packaged app is incomplete and should not be installed.", code: 2)
    }

    func renderInstallPlan() {
        out("`morb install-cli\(makeDefault ? " --make-default" : "")` will:")
        out("")
        let allLinks = [installPlan.docker] + installPlan.plugins
        for item in allLinks {
            let relation = item.willReplace ? " (REPLACES existing file/symlink)" : ""
            out("  \(item.destination) -> \(item.source ?? "-")\(relation)")
        }
        out("")
        switch installPlan.pathRegistration {
        case .alreadyReachable:
            out("  PATH: ~/.morbstack/bin is already reachable; no shell file changes.")
        case .preservesExistingDocker(let existing):
            out("  PATH: leaves existing docker first: \(existing)")
            out("        Pass --make-default to add Morbstack before it in your login profile.")
        case .addToProfile(let profile):
            out("  PATH: adds one managed Morbstack block to \(profile)")
        case .profileAlreadyManaged(let profile):
            out("  PATH: the existing managed block in \(profile) is already correct.")
        case .skippedForHomeOverride:
            out("  PATH: skipped because MORBSTACK_HOME is overridden (no temporary path is persisted).")
        case .unsupportedShell:
            out("  PATH: not changed; this shell is not one Morbstack can configure safely.")
        case .malformedExistingBlock(let profile):
            out("  PATH: not changed; \(profile) has a hand-edited Morbstack marker block.")
        }
        out("")
        switch installPlan.contextRegistration {
        case .willCreateAndUse, .staleWillReplaceAndUse:
            out("  Docker context: registers `morbstack` and makes it current because no explicit context owns it.")
        case .willCreateWithoutChangingCurrent(let current), .staleWillReplaceWithoutChangingCurrent(let current):
            out("  Docker context: registers `morbstack` but leaves explicit current context `\(current)` unchanged.")
        case .alreadyCurrent:
            out("  Docker context: `morbstack` is already registered and current.")
        case .alreadyRegisteredWithoutChangingCurrent(let current):
            out("  Docker context: already registered; leaves explicit current context `\(current)` unchanged.")
        }
        out("")
        switch installPlan.directSocket.state {
        case .missing:
            out("  Docker discovery: creates the user-owned link \(installPlan.directSocket.path)")
            out("                    -> \(installPlan.directSocket.expectedDestination)")
        case .correct:
            out("  Docker discovery: \(installPlan.directSocket.path) already points at Morbstack.")
        case .pointsElsewhere(let destination):
            out("  Docker discovery: preserves existing link \(installPlan.directSocket.path)")
            out("                    -> \(destination)")
        case .occupied(let kind):
            out("  Docker discovery: preserves existing \(kind) at \(installPlan.directSocket.path)")
        case .unavailable(let reason):
            out("  Docker discovery: not changed; \(reason)")
        }
        out("")
        out("No VM is started. No Docker image, volume, or existing Docker context is removed.")
    }

    if extraArguments.contains("--print-plan") {
        renderInstallPlan()
        out("")
        out("Nothing was changed.")
        exit(0)
    }

    if !force {
        renderInstallPlan()
        out("")
        guard isatty(STDIN_FILENO) == 1 else {
            fail(
                "install-cli needs confirmation and stdin is not a terminal.\n"
                    + "       Re-run with --print-plan to inspect it, or --force to apply this exact plan.", code: 2)
        }
        FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            fail("cancelled; nothing was changed", code: 2)
        }
    }

    do {
        let result = try MorbCliInstallation.install(
            makeDefault: makeDefault, reviewedPlan: installPlan)
        for name in ["docker", "docker-compose", "docker-buildx"] {
            switch result.links[name] {
            case .linked?: out("[ok] \(name) linked")
            case .alreadyCorrect?: out("[ok] \(name) already correct")
            case nil: break
            }
        }
        switch result.pathRegistration {
        case .addToProfile(let profile): out("[ok] added Morbstack's PATH block to \(profile)")
        case .profileAlreadyManaged: out("[ok] Morbstack's PATH block was already present")
        case .alreadyReachable: out("[ok] ~/.morbstack/bin is already on PATH")
        case .preservesExistingDocker(let path): out("[--] left existing docker first on PATH: \(path)")
        case .skippedForHomeOverride: out("[--] PATH not persisted because MORBSTACK_HOME is overridden")
        case .unsupportedShell: out("[--] PATH not changed for this shell")
        case .malformedExistingBlock(let profile): out("[--] PATH not changed; inspect \(profile)")
        }
        switch result.directSocket.state {
        case .correct:
            out("[ok] conventional Docker discovery socket points at Morbstack")
        case .missing:
            out("[--] conventional Docker discovery socket was not created")
        case .pointsElsewhere(let destination):
            out("[--] preserved existing Docker discovery socket -> \(destination)")
        case .occupied(let kind):
            out("[--] preserved existing \(kind) at Docker discovery socket")
        case .unavailable(let reason):
            out("[--] Docker discovery socket not changed: \(reason)")
        }
        if result.contextCreated { out("[ok] registered Docker context `morbstack`") }
        if result.contextBecameCurrent { out("[ok] current Docker context is now `morbstack`") }
        if let contextError = result.contextError {
            out("[!!] CLI links were installed, but Docker context setup failed: \(contextError)")
        }

        // A completion claim without a read-back is not useful to a clean-machine
        // user. This report re-reads the host integrations and observes only an
        // already-running daemon; it never goes through `callDaemon`, so it cannot
        // start morbstackd or a VM as a side effect of verification.
        let verification = MorbSetupVerification.verify(installation: result)
        out("")
        out("Post-setup verification (read-only; it did not start the engine):")
        for check in verification.integrations {
            out("  \(glyph(forVerification: check.status))  \(check.name): \(check.detail)")
        }
        for check in verification.runtime {
            out("  \(glyph(forVerification: check.status))  \(check.name): \(check.detail)")
        }

        if result.contextError != nil {
            fail("fix the Docker config issue above, then run `morb context create` and `morb context use`", code: 2)
        }
        out("")
        out("Open a new terminal, then verify with `docker version`, `docker compose version`, and `docker buildx version`.")
    } catch {
        fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
    }

case "uninstall-cli":
    let force = extraArguments.contains("--force")
    func renderUninstallPlan() {
        out("`morb uninstall-cli` removes only Morbstack-owned CLI integration:")
        out("  \(MorbCliInstallation.dockerDestination().path) when it is a Morbstack symlink")
        out("  docker-compose/docker-buildx links in \(MorbCliPlugins.cliPluginsDirectory().path) when they are Morbstack symlinks")
        out("  the exact managed PATH block from the selected shell profile")
        out("  ~/.docker/run/docker.sock only when it is Morbstack's user-owned symlink")
        out("  the `morbstack` Docker context only when it points at Morbstack's socket")
        out("")
        out("It does NOT remove Morbstack.app, ~/.morbstack/data, images, volumes, or another Docker installation.")
    }
    if extraArguments.contains("--print-plan") {
        renderUninstallPlan()
        out("")
        out("Nothing was changed.")
        exit(0)
    }
    if !force {
        renderUninstallPlan()
        out("")
        guard isatty(STDIN_FILENO) == 1 else {
            fail("uninstall-cli needs confirmation and stdin is not a terminal. Re-run with --force if you mean it.", code: 2)
        }
        FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            fail("cancelled; nothing was changed", code: 2)
        }
    }
    do {
        let result = try MorbCliInstallation.uninstall()
        if result.removedLinks.isEmpty { out("[--] no Morbstack CLI links to remove") }
        else { out("[ok] removed: \(result.removedLinks.joined(separator: ", "))") }
        if !result.preservedLinks.isEmpty { out("[--] preserved non-Morbstack links: \(result.preservedLinks.joined(separator: ", "))") }
        if result.removedProfileBlock { out("[ok] removed Morbstack's managed PATH block") }
        switch result.directSocket {
        case .removed: out("[ok] removed Morbstack's Docker discovery socket link")
        case .notPresent: out("[--] no Morbstack Docker discovery socket link to remove")
        case .pointsElsewhere(let destination): out("[--] preserved Docker discovery link -> \(destination)")
        case .occupied(let kind): out("[--] preserved existing \(kind) at Docker discovery socket")
        case .unavailable(let reason): out("[--] Docker discovery socket not changed: \(reason)")
        }
        switch result.context {
        case .removed(let wasCurrent): out("[ok] removed Docker context `morbstack`\(wasCurrent ? " and restored Docker's default context" : "")")
        case .notRegistered: out("[--] no Morbstack Docker context to remove")
        case .pointsElsewhere(let host): out("[--] preserved `morbstack` context pointing at \(host)")
        }
    } catch {
        fail((error as? MorbError)?.description ?? error.localizedDescription, code: 2)
    }

case "rosetta":
    let subcommand = extraArguments.first { !$0.hasPrefix("-") }

    // The host's own answer, from the one place that knows how to ask
    // Virtualization.framework. Not routed through `doctor`: this needs the state, not a
    // sentence about the state, and scraping it back out of a check's detail text would
    // make the CLI's behaviour depend on doctor's prose.
    let hostRosetta = RosettaSupport.state
    let rosettaEnabledInConfig = (try? MorbConfig.load())?.rosetta ?? true

    let rosettaReply = probeDaemon(DaemonRequest(cmd: "rosetta"), timeout: 10)
    let liveRosetta = (rosettaReply?.ok == true)
        ? MorbShareSurface.decodeRosetta(rosettaReply?.data, supported: hostRosetta != .notSupported)
        : nil
    let rosetta = MorbShareSurface.rosetta(
        host: hostRosetta, enabledInConfig: rosettaEnabledInConfig, live: liveRosetta)

    switch subcommand {
    case nil, "status":
        finish(.success([
            "installed": .bool(rosetta.installed),
            "enabled_in_config": .bool(rosetta.enabledInConfig),
            // Null, not false, when the guest has not answered — the same tri-state the
            // daemon uses, preserved rather than flattened on the way through.
            "active_in_guest": rosetta.activeInGuest.map { AnyCodableValue.bool($0) } ?? .null,
            "binfmt_registered": rosetta.binfmtRegistered.map { AnyCodableValue.bool($0) } ?? .null,
            "supported": .bool(rosetta.supported),
            "availability": .string(rosetta.availability.rawValue),
            "host_state": .string(hostRosetta.rawValue),
            "note": rosetta.note.map { AnyCodableValue.string($0) } ?? .null,
            "daemon_running": .bool(liveRosetta != nil),
        ])) { _ in
            let glyph: String
            switch rosetta.availability {
            case .active: glyph = "[ok]"
            case .ready: glyph = rosetta.isBrokenInGuest ? "[!!]" : "[--]"
            case .disabled: glyph = "[--]"
            case .notInstalled, .unsupported: glyph = "[!!]"
            }
            out("\(glyph) rosetta: \(rosetta.summary)")

            /// A guest fact that may simply not have been reported yet.
            func guestFact(_ value: Bool?, yes: String, no: String) -> String {
                guard let value else {
                    return liveRosetta == nil
                        ? "unknown (morbstackd is not running)"
                        : "unknown (the guest has not reported yet)"
                }
                return value ? yes : no
            }

            printAligned([
                ("host", rosetta.supported
                    ? (rosetta.installed ? "installed" : "not installed")
                    : "not supported on this Mac"),
                ("config", "rosetta = \(rosetta.enabledInConfig)"),
                ("guest mount", guestFact(rosetta.activeInGuest, yes: "active", no: "not active")),
                ("binfmt", guestFact(
                    rosetta.binfmtRegistered, yes: "registered", no: "not registered")),
            ])
            if let note = rosetta.note, !note.isEmpty {
                out("")
                out("  \(note)")
            }
            // One remedy, chosen for the exact combination. In particular a guest that
            // reports Rosetta broken is never told to install it: it is already there,
            // and `morb rosetta install` would do nothing but waste the user's afternoon.
            if let remedy = rosetta.remedy {
                out("")
                out("  \(remedy)")
            }
        }

    case "install":
        guard rosetta.supported else {
            fail(
                "this Mac cannot run Rosetta, so there is nothing to install.\n"
                    + "       (\(hostRosetta.detail))",
                code: 2)
        }
        guard !rosetta.installed || !rosetta.enabledInConfig else {
            // Nothing to do, and saying so is better than walking somebody through a
            // confirmation prompt for a no-op.
            finish(.success([
                "installed": .bool(true),
                "enabled_in_config": .bool(true),
                "changed": .bool(false),
            ])) { _ in
                out("[ok] rosetta is already installed and enabled; nothing to do")
                out("     Check what the guest is doing with it using `morb rosetta`.")
            }
        }

        // There is no `--force` here, and there will not be one.
        //
        // `reset-disk` offers one because it destroys *our* data — a file Morbstack
        // created, in a directory Morbstack owns — and a script that has already decided
        // is entitled to skip our confirmation. This is a different kind of act. It
        // installs Apple's system software, and macOS presents Apple's licence to the
        // person sitting at the machine. A flag that skips the prompt is a flag that
        // walks a user past a licence agreement they never saw, on a Mac they may not
        // own, from a process they may not have started.
        //
        // The general rule, which holds for every command in this CLI: Morbstack never
        // accepts a third-party licence, never triggers a system-level install without an
        // interactive confirmation, and never answers a consent prompt on the user's
        // behalf — whatever flags are passed. An unattended pipeline that genuinely needs
        // Rosetta runs `softwareupdate --install-rosetta` itself and owns that decision.
        //
        // Rejected here, before the plan is printed, rather than further down: `fail`
        // writes to stderr while the plan goes to stdout, and refusing after the plan
        // leaves the two interleaved on a terminal with the "nothing happened" line
        // buried in the middle.
        if extraArguments.contains("--force") {
            fail(
                "`rosetta install` does not accept --force, and no flag skips its prompt.\n"
                    + "       It installs system software under Apple's licence, so it always asks\n"
                    + "       the person at the keyboard. Use --print-plan to see what it would do,\n"
                    + "       or run `softwareupdate --install-rosetta` yourself for an unattended\n"
                    + "       install, then `morb rosetta` to confirm.",
                code: 2)
        }

        // Explained before anything is asked, let alone done. Installing Rosetta is a
        // system-level operation with a system-level prompt attached, and it must never
        // be something a user discovers happening.
        let willInstall = hostRosetta.isInstallable
        let willEnable = !rosetta.enabledInConfig
        out("`morb rosetta install` will:")
        out("")
        var step = 0
        if willInstall {
            step += 1
            out("  \(step). ask macOS to download and install the Rosetta for Linux runtime.")
            out("     macOS shows its own confirmation and licence prompt for this;")
            out("     Morbstack cannot and does not answer it for you.")
        }
        if willEnable {
            step += 1
            out("  \(step). set `rosetta = true` in \(MorbPaths.configFile.path),")
            out("     rewriting that file in its canonical form.")
        }
        step += 1
        out("  \(step). on the next VM start, expose Rosetta to the guest, which registers")
        out("     it as the interpreter for x86_64 binaries so amd64 images run.")
        out("")
        out("  The last step needs a restart of the VM to take effect. Nothing outside")
        out("  \(MorbPaths.root.path) is modified, and no container is touched.")
        out("")
        if !willInstall {
            out("  Rosetta is already installed on this Mac; only the config changes.")
            out("")
        }

        // `--print-plan` stops here. Everything above this line is the plan, so a script
        // or a curious user can read exactly what the command would do without being
        // one keystroke away from doing it.
        if extraArguments.contains("--print-plan") {
            out("  Nothing was changed. Re-run without --print-plan to go ahead.")
            exit(0)
        }

        guard isatty(STDIN_FILENO) == 1 else {
            fail(
                "rosetta install always asks for confirmation, and stdin is not a terminal.\n"
                    + "       Run it from a terminal. For an unattended install, run\n"
                    + "       `softwareupdate --install-rosetta` yourself and then `morb rosetta`.\n"
                    + "       `morb rosetta install --print-plan` prints what it would do and exits.",
                code: 2)
        }
        FileHandle.standardOutput.write(Data("Continue? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            fail("cancelled; nothing was changed", code: 2)
        }

        // Run here, in the foreground of a command the user typed — never handed to the
        // daemon. `RosettaSupport.install` puts a system software-installation dialog on
        // screen; morbstackd can start at login, so a daemon-side install would surface
        // an unexplained system prompt with no visible application behind it, on a
        // machine whose owner never asked for amd64 support.
        if willInstall {
            out("Asking macOS to install Rosetta. This can take a few minutes…")
            do {
                try RosettaSupport.install()
            } catch RosettaSupport.InstallError.alreadyInstalled {
                // Raced with another install, or with the user doing it by hand. Fine.
                out("Rosetta was already installed.")
            } catch {
                fail(
                    "\((error as? RosettaSupport.InstallError)?.description ?? error.localizedDescription)\n"
                        + "       Nothing was changed. You can also run\n"
                        + "       `softwareupdate --install-rosetta` yourself and retry.",
                    code: 2)
            }
        }

        if willEnable {
            do {
                let loaded = try MorbConfig.load()
                var config = loaded
                config.rosetta = true
                try config.savePreservingFile(
                    expected: loaded,
                    changing: MorbConfig.changedKeys(from: loaded, to: config))
            } catch {
                fail(
                    "Rosetta is installed, but \(MorbPaths.configFile.path) could not be updated:\n"
                        + "       \((error as? MorbError)?.description ?? error.localizedDescription)\n"
                        + "       Set `rosetta = true` there by hand to finish.",
                    code: 2)
            }
        }

        finish(.success([
            "installed": .bool(true),
            "enabled_in_config": .bool(true),
            "changed": .bool(true),
            "host_state": .string(RosettaSupport.state.rawValue),
        ])) { _ in
            out("")
            out("[ok] rosetta installed and enabled")
            out("")
            out("  Restart the VM with `morb stop && morb start` to pick it up, then check")
            out("  with `morb rosetta`. Once it is active, `docker run --platform")
            out("  linux/amd64 …` runs x86_64 images through Rosetta.")
        }

    default:
        fail(
            "unknown rosetta subcommand `\(subcommand ?? "")` (expected `status` or `install`)",
            code: 2)
    }

case "reset-disk":
    let disk = MorbPaths.diskImage
    let hasDisk = FileManager.default.fileExists(atPath: disk.path)
    let hasSavedState = FileManager.default.fileExists(atPath: MorbPaths.vmState.path)
    guard hasDisk || hasSavedState else {
        finish(.success([
            "deleted": .bool(false),
            "disk": .string(disk.path),
            "saved_state_deleted": .bool(false),
        ])) { _ in
            out("[--] nothing to do: \(disk.path) does not exist")
            out("    The next boot will create a fresh one and the guest will format it.")
        }
    }
    let sizeOnDisk: String = {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: disk.path),
              let allocated = attributes[.size] as? NSNumber
        else { return "unknown size" }
        return String(format: "%.1f GiB apparent", Double(truncating: allocated) / 1_073_741_824)
    }()

    let force = extraArguments.contains("--force")
    if !force {
        guard isatty(STDIN_FILENO) == 1 else {
            fail(
                "reset-disk needs confirmation and stdin is not a terminal.\n"
                    + "       Re-run with --force if you really mean it.",
                code: 2)
        }
        out("This deletes \(disk.path) (\(sizeOnDisk)).")
        out("Every image, container and volume in the Morbstack VM goes with it.")
        // Named separately because it is the reassuring half: nothing outside this
        // one file is touched, so config, logs and the kernel all survive.
        out("Nothing else under \(MorbPaths.root.path) is touched.")
        FileHandle.standardOutput.write(Data("Delete the disk? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
            fail("cancelled; nothing was deleted", code: 2)
        }
    }

    // A live daemon must delete through its VM-owning queue. A lifecycle state token
    // alone is not enough evidence: a failed pause can report `error` while retaining
    // a VZVirtualMachine that still has this disk attached.
    let liveReset = probeDaemon(DaemonRequest(cmd: "reset-disk"), timeout: 20)
    let response: DaemonResponse
    if let liveReset {
        response = liveReset
    } else {
        // With no answering daemon, take its singleton lock for the entire delete.
        // This closes the race where a daemon starts between an observation and the
        // unlink: it either already owns the lock (we refuse) or cannot attach the
        // disk until this reset has completed.
        do {
            try MorbPaths.ensureDirectories()
            let resetLock = FileLock(path: MorbPaths.lockFile.path)
            guard try resetLock.acquire() else {
                fail(
                    "morbstackd may still own the VM disk; refusing to delete it.\n"
                        + "       Wait for the daemon to respond, then run `morb stop --force` and retry.",
                    code: 2)
            }
            defer { resetLock.release() }

            let hadDisk = FileManager.default.fileExists(atPath: disk.path)
            let hadSavedState = FileManager.default.fileExists(atPath: MorbPaths.vmState.path)
            // Keep a failed offline reset cold-bootable. Removing a saved state first
            // means a later disk-delete failure cannot leave state that describes a
            // disk the caller has begun replacing.
            if hadSavedState { try FileManager.default.removeItem(at: MorbPaths.vmState) }
            if hadDisk { try FileManager.default.removeItem(at: disk) }
            response = .success([
                "deleted": .bool(hadDisk),
                "disk": .string(disk.path),
                "saved_state_deleted": .bool(hadSavedState),
            ])
        } catch {
            fail("could not reset \(disk.path): \(error.localizedDescription)", code: 2)
        }
    }

    finish(response) { data in
        let deleted = data["deleted"] == .bool(true)
        if deleted {
            out("[ok] deleted \(disk.path)")
        } else {
            out("[--] nothing to do: \(disk.path) does not exist")
        }
        out("")
        out("  On the next `morb start` Morbstack will:")
        out("    1. create a fresh sparse disk image of the configured size")
        out("    2. hand it to the guest, which finds no filesystem and formats it")
        out("    3. bring dockerd up on an empty /var/lib/docker")
        out("")
        out("  All previous images, containers and volumes are gone.")
        if data["saved_state_deleted"] == .bool(true) {
            out("")
            out("  Removed the saved VM state with the disk; it cannot describe a fresh disk.")
        }
    }


case "k8s":
    // Kubernetes is off by default and each verb is its own daemon command, so
    // that `MorbCommandPolicy` can let `enable` start a daemon while `status`
    // stays an observation that does not change what it observes.
    let action = extraArguments.first(where: { !$0.hasPrefix("-") }) ?? "status"
    let known = ["status", "enable", "disable", "kubeconfig"]
    guard known.contains(action) else {
        fail("unknown k8s subcommand `\(action)`; expected one of \(known.joined(separator: ", "))", code: 2)
    }

    /// Render a status bag the same way for every verb that returns one.
    func renderK8sStatus(_ data: [String: AnyCodableValue], verb: String) {
        let phase = data["phase"]?.displayString ?? "unknown"
        let symbol: String
        switch phase {
        case "ready": symbol = "[ok]"
        case "starting": symbol = "[..]"
        case "not-installed": symbol = "[--]"
        default: symbol = "[--]"
        }
        out("\(symbol) kubernetes \(phase.replacingOccurrences(of: "-", with: " "))")

        var rows: [(String, String)] = [
            ("enabled", data["enabled"]?.displayString ?? "-"),
            ("installed in guest", data["installed"]?.displayString ?? "-"),
            ("nodes", "\(data["nodes_ready"]?.displayString ?? "0")/\(data["nodes"]?.displayString ?? "0") ready"),
            ("pods", "\(data["pods_ready"]?.displayString ?? "0")/\(data["pods"]?.displayString ?? "0") ready"),
        ]
        // Only worth a line when it is bad news: a persistent data root is the
        // normal case and does not need announcing.
        if data["persistent"] == .bool(false) {
            rows.append(("persistence", "none — the guest data root is RAM-backed, so this is lost on stop"))
        }
        printAligned(rows)

        if let message = data["message"]?.displayString, !message.isEmpty, data["message"] != .null {
            out("     \(message)")
        }
        if phase == "ready" {
            out("")
            out("  kubectl --kubeconfig \(MorbPaths.kubeconfig.path) get nodes")
            out("  (run `morb k8s kubeconfig` first if that file is missing or stale)")
        } else if verb == "enable" {
            out("")
            out("  The control plane is starting. Watch it with `morb k8s status`.")
        }
    }

    switch action {
    case "status", "enable", "disable":
        let response = callDaemon(DaemonRequest(cmd: "k8s-\(action)"), timeout: 300)
        finish(response) { data in renderK8sStatus(data, verb: action) }

    default:  // kubeconfig
        let merge = extraArguments.contains("--merge")
        let switchContext = extraArguments.contains("--switch-context")
        let force = extraArguments.contains("--force")

        if merge && !force {
            // ~/.kube/config is not Morbstack's file. It routinely holds production
            // clusters, so the one command that writes to it always asks — and says
            // exactly what it will and will not change before it does.
            guard isatty(STDIN_FILENO) == 1 else {
                fail(
                    "`k8s kubeconfig --merge` edits \(MorbPaths.userKubeconfig.path) and stdin is not a\n"
                        + "       terminal. Re-run with --force if you really mean it.",
                    code: 2)
            }
            out("This adds a `morbstack` cluster, user and context to \(MorbPaths.userKubeconfig.path).")
            out("A timestamped backup of the current file is written alongside it first.")
            out("Every other cluster in that file is left exactly as it is.")
            if switchContext {
                out("current-context WILL be switched to `morbstack`.")
            } else {
                out("current-context is NOT changed (pass --switch-context if you want that).")
            }
            FileHandle.standardOutput.write(Data("Merge? [y/N] ".utf8))
            let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
            guard answer.lowercased() == "y" || answer.lowercased() == "yes" else {
                fail("cancelled; \(MorbPaths.userKubeconfig.path) was not touched", code: 2)
            }
        }

        var args: [String: String] = [:]
        if merge { args["merge"] = "true" }
        if switchContext { args["switch_context"] = "true" }
        let response = callDaemon(
            DaemonRequest(cmd: "k8s-kubeconfig", args: args.isEmpty ? nil : args), timeout: 120)
        finish(response) { data in
            let path = data["path"]?.displayString ?? "-"
            if data["merged"] == .bool(true) {
                out("[ok] merged the `\(data["context"]?.displayString ?? "morbstack")` context into \(path)")
                if let backup = data["backup"]?.displayString, data["backup"] != .null {
                    out("     backup: \(backup)")
                }
                if data["switched_context"] == .bool(true) {
                    out("     current-context is now `morbstack`")
                } else {
                    out("     current-context is unchanged; select it with:")
                    out("       kubectl config use-context morbstack")
                }
            } else {
                out("[ok] wrote \(path)")
                out("")
                out("  Use it directly:")
                out("    export KUBECONFIG=\(path)")
                out("    kubectl get nodes")
                out("")
                out("  Or merge it into ~/.kube/config (asks first, always backs up):")
                out("    morb k8s kubeconfig --merge")
            }
        }
    }

// The feature modules own their own argument parsing, output and exit codes. Each
// gets the residual arguments and the global `--json` flag and nothing else: the
// alternative is this switch growing a nested parser per feature, which is how a CLI
// ends up with five subtly different ideas of what `--force` means.
case "mcp":
    exit(MorbMCPCommand.run(extraArguments, json: wantsJSON))

case "migrate":
    exit(MorbMigrateCommand.run(extraArguments, json: wantsJSON))

case "bench":
    exit(MorbBenchCommand.run(extraArguments, json: wantsJSON))

case "scan":
    exit(MorbScanCommand.run(extraArguments, json: wantsJSON))

case "debug":
    exit(MorbDebugCommand.run(extraArguments, json: wantsJSON))

case "start", "stop", "suspend", "resume":
    var args: [String: String] = [:]
    if command == "stop", extraArguments.contains("--force") {
        args["force"] = "true"
    }
    let response = callDaemon(DaemonRequest(cmd: command, args: args.isEmpty ? nil : args))
    finish(response) { data in
        // Report the state the daemon actually ended up in rather than asserting
        // success: `suspend` on an already-stopped VM is accepted but is not a boot.
        let token = data["state"]?.displayString ?? "unknown"
        out("\(glyph(forState: token)) \(command): \(data["vm_state"]?.displayString ?? token)")
        // `suspend` reports what it cost. On a host where save/restore does not work
        // it is a stop in all but name, and the containers do not survive it.
        if let note = data["note"]?.displayString, !note.isEmpty, data["note"] != .null {
            out("     \(note)")
        }
    }

default:
    FileHandle.standardError.write(Data("morb: unknown command `\(command)`\n\n".utf8))
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
