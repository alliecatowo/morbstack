// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The screenshot harness's entry point.
//
// Deliberately three lines: everything it does lives in `MorbstackAppCore/Shots`,
// next to the views it photographs, because the harness needs internal access to the
// app's own view types and model. Exposing all of those publicly just to drive them
// from here would be a much larger change than moving one `main` across a target
// boundary.
//
//     swift run MorbShots --out ../dist/shots

import Foundation
import MorbstackAppCore

// Top-level code in a Swift 5 language-mode target is not main-actor isolated, but it
// does run on the main thread, which is what `assumeIsolated` asserts. The harness is
// main-actor throughout because SwiftUI rendering is.
MainActor.assumeIsolated {
    MorbShotsCLI.main()
}
