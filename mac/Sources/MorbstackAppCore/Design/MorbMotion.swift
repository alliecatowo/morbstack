// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Motion, and the single place Reduce Motion is honoured.
//
// The rule this file exists to enforce: **no feature file reads
// `\.accessibilityReduceMotion` and branches by hand.** Every animation in the app is
// named by a ``MorbMotion`` token and resolved through ``Theme/animation(_:reduceMotion:)``
// or through ``SwiftUI/View/morbAnimation(_:value:)``, which reads the environment for
// you. The moment two screens implement their own Reduce Motion fallback, one of them is
// wrong and nobody notices for a year.
//
// See `docs/design/IDENTITY.md` §6 for what animates, what does not, and why the springs
// are damped at 0.86/0.90 rather than the SwiftUI-tutorial 0.8.

import SwiftUI

// MARK: - Tokens

/// The four curves the app is allowed to use, plus the one repeating effect.
///
/// Replaces reaching for `Theme.springSubtle` / `Theme.springSnappy` / `Theme.fade`
/// directly: those constants still exist for the handful of places with no environment
/// to read, but a view that can see the environment should name a token instead so that
/// Reduce Motion is handled for it.
enum MorbMotion: Sendable, Hashable {

    /// A direct response to a click: a disclosure, a tab change, a button's own state.
    case snappy
    /// Layout that changes size: a row appearing, a section expanding.
    case subtle
    /// State that changed without the user asking — a poll result, a status flip.
    case fade
    /// A `glassEffectID` / `glassEffectUnion` morph. Nothing else.
    case glassMorph
    /// The repeating breath on a transitional status dot.
    case pulse

    /// The curve, ignoring accessibility. Prefer ``Theme/animation(_:reduceMotion:)``.
    var animation: Animation {
        switch self {
        case .snappy: return Theme.springSnappy
        case .subtle: return Theme.springSubtle
        case .fade: return Theme.fade
        case .glassMorph: return Theme.glassMorph
        case .pulse: return Theme.pulse
        }
    }

    /// What this token becomes when the user has asked for less motion.
    ///
    /// Springs collapse to the 180 ms cross-fade — the change still reads, it just does
    /// not travel. The two that are *purely* decoration, the repeating pulse and the
    /// glass morph, become `nil`: no animation at all, because a slower version of an
    /// ornament is still an ornament.
    var reducedAnimation: Animation? {
        switch self {
        case .snappy, .subtle, .fade: return Theme.fade
        case .glassMorph, .pulse: return nil
        }
    }
}

extension Theme {

    /// Resolves a motion token against the user's Reduce Motion setting.
    ///
    /// The one function every animation in the app goes through.
    ///
    /// ```swift
    /// @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// …
    /// .animation(Theme.animation(.subtle, reduceMotion: reduceMotion), value: rows)
    /// ```
    static func animation(_ motion: MorbMotion, reduceMotion: Bool) -> Animation? {
        reduceMotion ? motion.reducedAnimation : motion.animation
    }
}

// MARK: - View sugar

private struct MorbAnimationModifier<V: Equatable>: ViewModifier {

    let motion: MorbMotion
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Theme.animation(motion, reduceMotion: reduceMotion), value: value)
    }
}

extension View {

    /// `.animation(_:value:)` with the Reduce Motion branch already taken.
    ///
    /// Replaces `.animation(Theme.springSubtle, value:)` at every call site that has an
    /// environment to read — which is all of them inside a `View`.
    func morbAnimation<V: Equatable>(_ motion: MorbMotion, value: V) -> some View {
        modifier(MorbAnimationModifier(motion: motion, value: value))
    }
}

// MARK: - Repeating effects

/// A view modifier for the one repeating animation the design system permits: the
/// breath on a transitional status indicator.
///
/// Suppressed entirely under Reduce Motion — see ``MorbMotion/pulse``.
struct MorbPulse: ViewModifier {

    /// Whether the pulse should be running at all.
    var isActive: Bool
    /// The trough of the breath. 0.35 is the value the engine pill has always used.
    var minimumOpacity: Double = 0.35

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDown = false

    func body(content: Content) -> some View {
        let running = isActive && !reduceMotion
        content
            .opacity(running && isDown ? minimumOpacity : 1)
            .animation(running ? Theme.pulse : nil, value: isDown)
            .onAppear { if running { isDown = true } }
            .onChange(of: running) { _, nowRunning in isDown = nowRunning }
    }
}

extension View {

    /// The system's only repeating animation. See ``MorbPulse``.
    func morbPulse(_ isActive: Bool, minimumOpacity: Double = 0.35) -> some View {
        modifier(MorbPulse(isActive: isActive, minimumOpacity: minimumOpacity))
    }
}
