// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Fixture diagnostics entry point.
//
// The diagnostics and fixture data live in `MorbstackAppCore/Shots` so this small
// compatibility target can validate the deterministic `--tour-fixtures` world without
// reproducing an AppKit window or producing misleading screenshots.

import Foundation
import MorbstackAppCore

// Top-level code in a Swift 5 language-mode target is not main-actor isolated, but it
// does run on the main thread, which is what `assumeIsolated` asserts. The harness is
// main-actor throughout because SwiftUI rendering is.
MainActor.assumeIsolated {
    MorbShotsCLI.main()
}
