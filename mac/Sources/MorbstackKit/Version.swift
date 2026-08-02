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
}
