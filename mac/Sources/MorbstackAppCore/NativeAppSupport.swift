// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Small nonvisual facts and services shared by the app.
//
// This file intentionally contains no view, color, typography, spacing, animation, or
// component policy. SwiftUI and AppKit own those decisions at the call site. Keeping
// operational facts here lets a menu, table, inspector, and accessibility label agree
// on what the engine says without introducing a parallel design system.

import AppKit
import Foundation
import MorbstackKit

// MARK: - Operational state

/// A concise classification of an operational resource.
///
/// The state carries words and SF Symbols, never a color. A native surface may choose
/// to render the information in the way appropriate for that control, while the state
/// remains equally useful for accessibility labels, menus, tables, and inspectors.
enum OperationalState: Sendable, Hashable {
    case running
    case stopped
    case changing
    case paused
    case failed

    var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .changing: return "Changing"
        case .paused: return "Paused"
        case .failed: return "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .stopped: return "circle"
        case .changing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    /// Classifies the Docker Engine state for a container.
    static func container(state: String, unhealthy: Bool = false) -> Self {
        switch state {
        case "running": return unhealthy ? .failed : .running
        case "restarting": return .changing
        case "paused": return .paused
        case "dead": return .failed
        case "created", "exited", "removing": return .stopped
        default: return .stopped
        }
    }

    /// Classifies the state reported by the local engine.
    static func engine(_ status: EngineStatus) -> Self {
        guard status.reachable else { return .stopped }
        switch status.state {
        case "running": return .running
        case "starting", "stopping", "pausing": return .changing
        case "suspended": return .paused
        case "error": return .failed
        default: return .stopped
        }
    }
}

// MARK: - Native services

/// The app's one explicit pasteboard interaction.
enum MorbPasteboard {
    @MainActor
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// A user-facing error sentence that keeps the useful descriptions supplied by the
/// app's clients and avoids Foundation's generic fallback where possible.
enum MorbErrorMessage {
    static func text(for error: Error) -> String {
        if let morb = error as? MorbError { return morb.description }
        if let localized = error as? LocalizedError,
           let text = localized.errorDescription,
           !text.isEmpty {
            return text
        }
        return error.localizedDescription
    }
}

// MARK: - Sort semantics

/// Domain sort helpers for the native `Table` columns.
enum MorbSort {
    static func string(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    static func optionalInt64(_ lhs: Int64?, _ rhs: Int64?) -> ComparisonResult {
        let left = lhs ?? -1
        let right = rhs ?? -1
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    static func int(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    static func date(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
