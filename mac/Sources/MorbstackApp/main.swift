// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app executable: three lines, on purpose.
//
// Everything Morbstack.app actually is lives in `MorbstackAppCore`, a library target.
// The split exists because a `.app` is not the only consumer of those views: the
// screenshot harness (`MorbShots`) renders the very same production SwiftUI code
// offscreen with `ImageRenderer`, and SwiftPM cannot link one executable target into
// another. A library both can depend on is the only arrangement that keeps the
// screenshots honest — they are pictures of the shipping views, not of a parallel
// re-implementation that drifts.
//
// The bundle's `CFBundleExecutable` is `MorbstackApp`, which is this target's name, so
// `make app` is unaffected by the split.

import MorbstackAppCore

MorbstackMainApp.main()
