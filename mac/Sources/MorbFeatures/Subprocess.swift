// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Running an external program, with a deadline and captured output.
//
// Several of these features shell out — `morb migrate` pipes a tar between two
// engines, `morb scan` runs syft/grype, `morb bench` times `git status` and
// `npm install`. Foundation's `Process` does all of it, but every call site
// otherwise reinvents the same three things: reading both pipes without
// deadlocking on a full pipe buffer, enforcing a timeout, and not leaving an
// orphan behind when the timeout fires.

import Darwin
import Foundation

/// The result of running a program to completion.
public struct CommandResult: Sendable {
    public var executable: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// Wall-clock duration of the run.
    public var duration: TimeInterval
    /// `true` when the deadline fired and the process was killed.
    public var timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// A one-line description suitable for an error message.
    public var failureSummary: String {
        if timedOut { return "`\(commandLine)` timed out" }
        let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.split(separator: "\n").suffix(3).joined(separator: "; ")
        return "`\(commandLine)` exited \(exitCode)\(tail.isEmpty ? "" : ": \(tail)")"
    }

    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public enum CommandError: Error, CustomStringConvertible {
    case notFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notFound(let name): return "`\(name)` was not found on PATH"
        case .launchFailed(let m): return "could not launch: \(m)"
        }
    }
}

public enum Subprocess {

    /// Runs `executable` with `arguments` and returns once it exits.
    ///
    /// Both pipes are drained on background queues. Reading them serially — stdout to
    /// EOF, then stderr — deadlocks the moment a program writes more than a pipe
    /// buffer (64 KiB) to the stream that is not being read, which `grype` does
    /// routinely on its progress output.
    ///
    /// - Parameter timeout: `nil` waits forever. Otherwise the process is sent
    ///   `SIGTERM` at the deadline and `SIGKILL` two seconds later.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> CommandResult {
        let resolved = executable.contains("/") ? executable : (which(executable) ?? "")
        guard !resolved.isEmpty, FileManager.default.isExecutableFile(atPath: resolved) else {
            throw CommandError.notFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let collector = OutputCollector()
        let queue = DispatchQueue(label: "morb.subprocess.drain", attributes: .concurrent)
        let group = DispatchGroup()

        queue.async(group: group) {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            collector.appendStdout(data)
        }
        queue.async(group: group) {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            collector.appendStderr(data)
        }

        let started = Date()
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed("\(resolved): \(error.localizedDescription)")
        }

        if let stdin {
            queue.async {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if let timeout {
            let deadline = started.addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                timedOut = true
                kill(process.processIdentifier, SIGTERM)
                let hardDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < hardDeadline { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.waitUntilExit()
        group.wait()

        return CommandResult(
            executable: resolved,
            arguments: arguments,
            exitCode: process.terminationStatus,
            stdout: collector.stdout,
            stderr: collector.stderr,
            duration: Date().timeIntervalSince(started),
            timedOut: timedOut)
    }

    /// Locates `name` on `PATH`, plus the usual Homebrew prefixes.
    ///
    /// `PATH` for a process launched from an app bundle or a launchd job is not the
    /// `PATH` in the user's shell, and "command not found" for a tool the user can
    /// plainly run in their terminal is one of the least helpful errors a program can
    /// produce.
    public static func which(_ name: String) -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ])
        for directory in directories where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// A lock-guarded pair of buffers for the two drain queues to write into.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return outBuffer }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return errBuffer }

    func appendStdout(_ data: Data) { lock.lock(); outBuffer.append(data); lock.unlock() }
    func appendStderr(_ data: Data) { lock.lock(); errBuffer.append(data); lock.unlock() }
}
