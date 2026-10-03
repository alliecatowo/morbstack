// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Whether "Open Terminal" can do anything right now, and what to say when it cannot.
//
// A stopped container has no process namespace to enter: `POST /containers/{id}/exec`
// against one fails with "Container … is not running", and against a paused one with
// "Container … is paused". Neither is a surprise the person should discover by clicking
// and reading an error. So this is a precondition the affordance carries, and it lives
// here — pure, one input, one output — rather than as a `!container.isRunning` scattered
// across a toolbar item, a context menu, and a menu-bar command that could drift apart.
//
// The copy follows the register TASTE-4 and TASTE-6 set: state the fact once, and say
// what the reader can do rather than naming our internal state. "Start pg-main to open a
// terminal in it" is the sentence; "container not running" is not.

import Foundation

enum ContainerTerminalAvailability {

    /// Why a terminal is or is not available, derived from the one Docker fact that
    /// decides it — the container's state — plus whether this window talks to an engine
    /// at all.
    enum Reason: Equatable, Sendable {
        case ready
        case paused
        case restarting
        /// `created` or `exited`: startable, so the remedy is Start.
        case notStarted
        /// Docker documents `dead` as defunct and unstartable. There is no remedy to
        /// offer, and offering Start would be a lie.
        case dead
        /// `removing`, or a state this build does not recognise. A refresh can turn
        /// either into something actionable; a guess cannot.
        case indeterminate(state: String)
        /// A `--tour-fixtures` window renders Docker-shaped records without an engine
        /// behind them. A terminal opens its own socket outside `DockerClient`, so it is
        /// exactly the kind of work `AppModel.permitsExternalOperations` gates.
        case fixtureWindow
    }

    static func reason(for container: ContainerSummary, permitsExternalOperations: Bool = true) -> Reason {
        guard permitsExternalOperations else { return .fixtureWindow }
        switch container.state {
        case "running": return .ready
        case "paused": return .paused
        case "restarting": return .restarting
        case "created", "exited": return .notStarted
        case "dead": return .dead
        default: return .indeterminate(state: container.state)
        }
    }

    static func isAvailable(for container: ContainerSummary, permitsExternalOperations: Bool = true) -> Bool {
        reason(for: container, permitsExternalOperations: permitsExternalOperations) == .ready
    }

    /// The `.help()` string on every Open Terminal control. One sentence; it either
    /// describes what the command does or names the single next step that would make it
    /// work.
    static func helpText(for container: ContainerSummary, permitsExternalOperations: Bool = true) -> String {
        let name = container.displayName
        switch reason(for: container, permitsExternalOperations: permitsExternalOperations) {
        case .ready:
            return "Open an interactive shell in \(name)"
        case .paused:
            return "Unpause \(name) to open a terminal in it."
        case .restarting:
            return "\(name) is restarting. Open a terminal once it is running."
        case .notStarted:
            return "Start \(name) to open a terminal in it."
        case .dead:
            return "Docker reports \(name) as dead, and a dead container cannot be started again."
        case .indeterminate(let state):
            let described = state.isEmpty ? "in no reported state" : "as “\(state)”"
            return "Docker reports \(name) \(described). Refresh, then open a terminal once it is running."
        case .fixtureWindow:
            return "This window is showing developer fixtures, so there is no engine to open a shell against."
        }
    }
}

/// The one line a terminal window shows once its session has ended.
///
/// Extracted from `ContainerTerminalWindowController` so the wording for each way a
/// session can end is a table a test reads back, rather than a `switch` reachable only
/// by holding a real shell open and killing it from another window.
enum ContainerTerminalStatus {

    /// `nil` means "say nothing": the person closed the window, so it is already going
    /// away and a status line would be addressed to no one.
    static func text(for reason: DockerExecPTYSession.TerminationReason) -> String? {
        switch reason {
        case .exited(.some(0)):
            return "The shell exited."
        case .exited(.some(let status)):
            return "The shell exited with status \(status)."
        case .exited(.none):
            return "The session ended. Docker did not report an exit status."
        case .containerStopped:
            // The scrollback above stays readable; this says why nothing more will
            // arrive in it, and what would produce a working terminal next time.
            return "The container stopped, which ended this session. Start it again to open a new terminal."
        case .transportFailure(let message):
            return message
        case .closedByUser:
            return nil
        }
    }
}
