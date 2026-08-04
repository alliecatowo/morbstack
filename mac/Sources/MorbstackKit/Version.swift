// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The single source of truth for the Morbstack version string.
///
/// Every component of the stack — the `morbstackd` daemon, the `morb` CLI and the
/// in-guest `morbinit` — reports the same version for a given milestone build.
public enum MorbVersion {
    /// Semantic version plus milestone suffix, e.g. `0.1.0-m0`.
    public static let string = "0.1.0-m0"

    /// The oldest guest `morbinit` this daemon knows how to talk to.
    ///
    /// `docs/protocol.md` nominates the `info` reply's `morbinit_version` field as
    /// *the* compatibility probe for the control channel; this constant is the
    /// host's side of that contract. The boot probe compares the reported version
    /// against it once per boot and surfaces an older guest in the daemon log,
    /// `morb status` and `morb doctor` (see `VMManager.beginControlProbe`).
    ///
    /// Raise this when a control-channel change stops being additive — that is the
    /// entire mechanism; there is deliberately no negotiation.
    public static let minimumCompatibleMorbinit = "0.1.0-m0"

    /// Whether `candidate` is strictly older than `reference`.
    ///
    /// Both are Morbstack version strings: a dotted numeric core with an optional
    /// `-m<N>` milestone suffix (`0.1.0-m0`, `0.2.1`). Ordering follows the
    /// semver convention that a suffixed version precedes its bare core
    /// (`0.1.0-m1` < `0.1.0`), and milestones order numerically.
    ///
    /// A string that does not parse is never "older": an unrecognised format is a
    /// different failure from an out-of-date guest, and refusing to guess keeps a
    /// future version scheme from tripping the compatibility gate by accident.
    public static func isOlder(_ candidate: String, than reference: String) -> Bool {
        guard let lhs = parse(candidate), let rhs = parse(reference) else { return false }
        // Compare the dotted cores component-wise, padding the shorter with zeros
        // so `0.1` and `0.1.0` are the same version.
        let width = max(lhs.core.count, rhs.core.count)
        for index in 0..<width {
            let l = index < lhs.core.count ? lhs.core[index] : 0
            let r = index < rhs.core.count ? rhs.core[index] : 0
            if l != r { return l < r }
        }
        switch (lhs.milestone, rhs.milestone) {
        case (nil, nil): return false
        case (.some, nil): return true  // 0.1.0-m1 < 0.1.0
        case (nil, .some): return false
        case (.some(let l), .some(let r)): return l < r
        }
    }

    /// Splits `0.1.0-m2` into `([0, 1, 0], 2)`; `nil` when the shape is foreign.
    private static func parse(_ version: String) -> (core: [Int], milestone: Int?)? {
        let halves = version.split(separator: "-", maxSplits: 1)
        guard let first = halves.first else { return nil }
        var core: [Int] = []
        for component in first.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(component), value >= 0 else { return nil }
            core.append(value)
        }
        guard !core.isEmpty else { return nil }
        guard halves.count == 2 else { return (core, nil) }
        let suffix = halves[1]
        guard suffix.hasPrefix("m"), let milestone = Int(suffix.dropFirst()), milestone >= 0
        else { return nil }
        return (core, milestone)
    }
}
