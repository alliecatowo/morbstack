// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// morbstackd — the Morbstack daemon. Owns the VM, publishes the Docker socket and
// answers the `morb` CLI on the control socket.

import Dispatch
import Foundation
import MorbstackKit

let usage = """
    morbstackd \(MorbVersion.string) — the Morbstack daemon

    USAGE:
      morbstackd [options]

    OPTIONS:
      --foreground     Run in the foreground (default, and the only mode in M0)
      --quiet          Do not echo the log to stderr
      --started-by S   Record S as what launched this daemon (provenance only)
      --version        Print the version and exit
      --help           Print this help and exit

    PATHS:
      config      \(MorbPaths.configFile.path)
      control     \(MorbPaths.controlSocket.path)
      docker      \(MorbPaths.dockerSocket.path)
      logs        \(MorbPaths.logsDirectory.path)
    """

/// Writes a line to standard error without going through the logger.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Run in our own session and ignore SIGHUP: a daemon auto-spawned from a terminal
// must not die (unsuspended, mid-write) when that terminal closes. `setsid` fails
// harmlessly with EPERM when launchd already made us a group leader.
_ = setsid()
signal(SIGHUP, SIG_IGN)

var quiet = false

/// Who launched this daemon, when it was not launched by hand.
///
/// `morb` auto-starts a sibling daemon when the control socket does not answer,
/// which is convenient right up until you are staring at a process nobody
/// remembers starting and cannot tell your own tooling from someone else's.
/// Carrying the reason into the log makes that question answerable from the log
/// alone.
var startedBy: String?

// Hand-rolled flag parsing: morbstackd has no dependencies, by design.
var pendingArguments = Array(CommandLine.arguments.dropFirst())
while !pendingArguments.isEmpty {
    let argument = pendingArguments.removeFirst()
    switch argument {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--version", "-v":
        print(MorbVersion.string)
        exit(0)
    case "--foreground":
        // M0 always runs in the foreground; launchd owns backgrounding later.
        break
    case "--quiet", "-q":
        quiet = true
    case "--started-by":
        guard !pendingArguments.isEmpty else {
            printError("morbstackd: --started-by needs a value\n")
            printError(usage)
            exit(2)
        }
        startedBy = pendingArguments.removeFirst()
    default:
        printError("morbstackd: unknown option `\(argument)`\n")
        printError(usage)
        exit(2)
    }
}

// Held for the process lifetime. `Daemon` owns the socket listeners, whose deinit
// unlinks the socket files — letting it fall out of scope before `dispatchMain()`
// would leave a running process with nothing bound.
var daemon: Daemon?

do {
    try MorbPaths.ensureDirectories()
    let log = MorbLog(fileURL: MorbPaths.daemonLog, echoToStderr: !quiet)

    if !quiet {
        print("morbstack daemon \(MorbVersion.string)")
        print("  control  \(MorbPaths.controlSocket.path)")
        print("  docker   \(MorbPaths.dockerSocket.path)")
        print("  log      \(MorbPaths.daemonLog.path)")
        print("")
    }

    if let startedBy {
        log.info("auto-started by \(startedBy) (pid \(getpid()))")
    }

    let instance = try Daemon(log: log)
    try instance.run()
    daemon = instance
} catch {
    printError("morbstackd: \(error)")
    exit(1)
}

// Everything from here on is driven by dispatch sources: the control listener, the
// Docker listener, the idle timer and the signal sources.
dispatchMain()
