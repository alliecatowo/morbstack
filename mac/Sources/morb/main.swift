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
      suspend      Save the VM to disk and free its memory
      resume       Restore a suspended VM
      shares       List the shared host paths and whether the guest has them
      rosetta      Show Rosetta status; `rosetta install` sets it up
      k8s          Run a local Kubernetes cluster (off by default)
      version      Print CLI and daemon versions
      doctor       Diagnose the host; works without the daemon
      reset-disk   Delete the Docker data disk and start over (destructive)

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

    OPTIONS:
      --json     Emit raw JSON instead of human-readable output
      --force    Skip Morbstack's confirmation prompt (reset-disk), or stop
                 the VM without asking the guest first (stop). Deliberately
                 refused by `rosetta install`: that installs system software
                 under Apple's licence, so it always asks the person at the
                 keyboard. Use --print-plan, or run
                 `softwareupdate --install-rosetta` yourself.
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
                var config = try MorbConfig.load()
                config.rosetta = true
                try config.save()
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
    // Deliberately does not go through `callDaemon`: this command must never be the
    // reason a daemon exists (see MorbCommandPolicy.selfServedCommands), and "nothing
    // is running" is the state in which it is *safe* to proceed rather than a reason
    // to bail out.
    let daemonState: String? = {
        guard let response = try? UnixSocketClient.roundTrip(
            path: MorbPaths.controlSocket.path,
            request: DaemonRequest(cmd: "status"),
            timeout: 5),
            response.ok
        else { return nil }
        return response.data?["state"]?.displayString
    }()

    // Only a stack that is demonstrably not using the disk may have it removed. An
    // `error` state counts: that is precisely the wedged case this command exists for.
    if let daemonState, daemonState != "stopped", daemonState != "error" {
        fail(
            "the VM is \(daemonState); refusing to delete the disk out from under it.\n"
                + "       Run `morb stop` first, then retry.",
            code: 2)
    }

    let disk = MorbPaths.diskImage
    guard FileManager.default.fileExists(atPath: disk.path) else {
        finish(.success([
            "deleted": .bool(false),
            "disk": .string(disk.path),
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

    // A saved-state blob describes a guest whose disk is about to disappear. It is not
    // ours to delete here, but restoring it afterwards would be incoherent, so say so.
    let hasSavedState = FileManager.default.fileExists(atPath: MorbPaths.vmState.path)

    do {
        try FileManager.default.removeItem(at: disk)
    } catch {
        fail("could not delete \(disk.path): \(error.localizedDescription)", code: 2)
    }

    finish(.success([
        "deleted": .bool(true),
        "disk": .string(disk.path),
        "saved_state_present": .bool(hasSavedState),
    ])) { _ in
        out("[ok] deleted \(disk.path)")
        out("")
        out("  On the next `morb start` Morbstack will:")
        out("    1. create a fresh sparse disk image of the configured size")
        out("    2. hand it to the guest, which finds no filesystem and formats it")
        out("    3. bring dockerd up on an empty /var/lib/docker")
        out("")
        out("  All previous images, containers and volumes are gone.")
        if hasSavedState {
            out("")
            out("  Note: \(MorbPaths.vmState.path) still exists and describes the guest that")
            out("        was using the deleted disk. It was left alone, but it will be")
            out("        discarded on the next bring-up rather than restored.")
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
