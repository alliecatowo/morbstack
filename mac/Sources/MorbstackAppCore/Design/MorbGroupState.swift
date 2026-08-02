// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// "Up, but not all of it" — the state a *group* can be in and a single container cannot.
//
// A compose project with three of four services running is not `running` and is not
// `bad`; it is degraded, and the current build has no way to say so. The Stacks screen
// invents it locally (an orange glyph and an orange `3/4` on one card, a green glyph and
// a green `5/5` on the next) and the containers list invents it differently again.
//
// This is a separate type rather than a sixth case on ``StatusTone`` on purpose:
// `StatusTone` is switched over exhaustively by `MenuBar/TrackDChrome.swift`, which
// belongs to another track, so a sixth case would break a file this change is not
// allowed to touch. The follow-up that merges the two is specified in
// `docs/design/REWRITE-PLAN.md` §Deferred.

import SwiftUI

// MARK: - Model

/// How much of a group is up.
///
/// Use for a compose project, the engine's whole workload, or any "n of m" summary.
enum MorbGroupState: Sendable, Hashable {

    /// Every member is up.
    case allUp
    /// Some but not all. The state that needs its own colour.
    case degraded
    /// Nothing is up, and nothing is trying to be.
    case allDown
    /// At least one member is mid-transition.
    case transitioning

    /// Classifies a group from its counts.
    ///
    /// The single place this arithmetic happens, so Stacks and Containers cannot
    /// disagree about what `0 of 2` looks like.
    static func from(running: Int, total: Int, transitioning: Int = 0) -> MorbGroupState {
        if transitioning > 0 { return .transitioning }
        if total == 0 || running == 0 { return .allDown }
        return running == total ? .allUp : .degraded
    }

    var color: Color {
        switch self {
        case .allUp: return Theme.statusRunning
        case .degraded: return Theme.statusDegraded
        case .allDown: return .secondary
        case .transitioning: return Theme.statusBusy
        }
    }

    /// The redundant, non-colour half of the signal — same contract as ``StatusTone``.
    var symbol: String {
        switch self {
        case .allUp: return "circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .allDown: return "circle"
        case .transitioning: return "arrow.triangle.2.circlepath"
        }
    }

    var isTransitional: Bool { self == .transitioning }

    /// The equivalent ``StatusTone``, for the surfaces that still take one.
    ///
    /// `degraded` maps to `busy`'s amber, which is the closest the five-case enum can
    /// get. Anything drawing a group should prefer ``MorbGroupHeader`` and keep the
    /// distinction.
    var approximateTone: StatusTone {
        switch self {
        case .allUp: return .running
        case .degraded, .transitioning: return .busy
        case .allDown: return .idle
        }
    }
}

// MARK: - Header

/// The header row above a group of list rows: `▣ shopfront   5/5`.
///
/// Replaces the three different group-header treatments in `ContainersRootView` (an
/// orange layers glyph with an orange count, a green one with a green count, and a
/// dashed square with a grey count) and the card headers in `StacksRootView`.
///
/// Fixed at ``Theme/rowGroupHeader``, like every other row class, so a list of groups has
/// a rhythm you can count.
struct MorbGroupHeader<Trailing: View>: View {

    var title: String
    var state: MorbGroupState
    var running: Int
    var total: Int
    /// A symbol for the *kind* of group — layers for a compose project, a dashed square
    /// for the standalone bucket. Never carries status; the dot does that.
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String,
         state: MorbGroupState,
         running: Int,
         total: Int,
         symbol: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.state = state
        self.running = running
        self.total = total
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.space3) {
            Circle()
                .fill(state.color)
                .frame(width: Theme.dotSize, height: Theme.dotSize)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                .morbPulse(state.isTransitional)

            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }

            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            MorbCountBadge(count: running, of: total,
                           tone: state == .allDown ? nil : state.approximateTone)

            Spacer(minLength: Theme.space3)
            trailing
        }
        .frame(height: Theme.rowGroupHeader)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(running) of \(total) running")
        .accessibilityAddTraits(.isHeader)
    }
}

extension MorbGroupHeader where Trailing == EmptyView {

    init(_ title: String,
         state: MorbGroupState,
         running: Int,
         total: Int,
         symbol: String? = nil) {
        self.init(title, state: state, running: running, total: total, symbol: symbol) {
            EmptyView()
        }
    }
}
