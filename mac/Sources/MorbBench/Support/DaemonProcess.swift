// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Finding morbstackd's own pid for the current `MORBSTACK_HOME`, for the
// idle-* benchmarks that sample it with `top`. `FileLock` already writes the
// owning pid into `morbstackd.lock` "so a human staring at the file can tell
// who has it" (see FileLock.swift) — this reads that same file rather than
// inventing a second place the pid is recorded.
//
// There is deliberately no separate "VM process" to find here: `VMManager`
// creates its `VZVirtualMachine` in-process (see VMManager.swift — no
// `Process()` spawn anywhere in it), so on this architecture morbstackd *is*
// the VM process. `host-rss` and `idle-cpu` report that plainly instead of
// inventing a second PID to sample.

import Darwin
import Foundation
import MorbstackKit

public enum DaemonProcess {

    /// The pid of the `morbstackd` currently holding the lock at the active
    /// `MORBSTACK_HOME`, or `nil` when the lock file is absent or stale (a
    /// crashed daemon's lock file is never deleted — see `FileLock`'s own
    /// doc comment — so a leftover pid that no longer answers `kill(pid, 0)`
    /// is the expected shape of "nothing is running", not an error).
    public static func morbstackdPID() -> Int32? {
        guard let text = try? String(contentsOf: MorbPaths.lockFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(trimmed), value > 0, kill(value, 0) == 0 else { return nil }
        return value
    }
}
