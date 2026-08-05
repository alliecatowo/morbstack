// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Which program a container terminal should start — and the honest answer when there
// isn't one.
//
// This is deliberately a separate, typed decision rather than a string default inside
// the window controller, because it is the seam DIF-8 grows through: a distroless
// image with no `/bin/bash` and no `/bin/sh` is exactly the case `morb debug`'s
// toolbox exists to solve (docs/debug.md). Today that case resolves to `.noShell` and
// the terminal says so plainly; the toolbox, once it can be acquired and verified,
// becomes a new outcome here — not a rewrite of the terminal.

import Foundation

enum TerminalShellResolution {

    /// Shells worth trying, in order of usefulness.
    static let defaultCandidates = ["/bin/bash", "/bin/sh"]

    enum Outcome: Equatable, Sendable {
        /// This shell exists and executes in the container.
        case found(shell: String)
        /// None of the probed candidates exist — a distroless or scratch image.
        case noShell(probed: [String])
        /// The probes themselves could not run (engine or container trouble).
        case failed(message: String)
    }

    /// Probes candidates with a bounded, noninteractive `exec` per candidate
    /// (`<shell> -c "exit 0"`) and returns the first that runs. Exit 126/127 —
    /// missing or non-executable — moves to the next candidate.
    static func resolve(
        client: DockerClient,
        containerID: String,
        candidates: [String] = defaultCandidates
    ) async -> Outcome {
        for candidate in candidates {
            do {
                let result = try await client.executeContainerCommand(
                    id: containerID, command: [candidate, "-c", "exit 0"])
                if result.exitCode == 0 { return .found(shell: candidate) }
                // 126 (found but not executable) and 127 (not found) are the two exit
                // codes a POSIX shell uses to report "could not run that", which is
                // exactly the "this candidate does not exist here" case this loop
                // exists to move past. Anything else — including no reported exit code
                // at all — is not evidence of absence and is reported honestly rather
                // than silently treated as one more missing shell.
                guard result.exitCode == 126 || result.exitCode == 127 else {
                    return .failed(message: Self.unexpectedExitMessage(candidate: candidate, exitCode: result.exitCode))
                }
            } catch let error as DockerClientError {
                if case .http(_, let message) = error, Self.looksLikeMissingShell(message) {
                    continue
                }
                return .failed(message: error.errorDescription ?? "\(error)")
            } catch {
                return .failed(message: "\(error)")
            }
        }
        return .noShell(probed: candidates)
    }

    private static func unexpectedExitMessage(candidate: String, exitCode: Int?) -> String {
        let described = exitCode.map(String.init) ?? "no exit code"
        return "probing \(candidate) exited with \(described), which is neither success nor a missing-shell signal"
    }

    /// The engine reports a missing or non-executable candidate as an ordinary HTTP
    /// error carrying dockerd's own wording, not as a distinct status code — so the
    /// message itself is the only signal that this is "no such shell" rather than some
    /// other failure (an unreachable engine, a container that stopped mid-probe) that
    /// deserves `.failed` instead of quietly moving to the next candidate.
    private static func looksLikeMissingShell(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("executable file not found")
            || lower.contains("no such file or directory")
            || lower.contains("permission denied")
    }
}
