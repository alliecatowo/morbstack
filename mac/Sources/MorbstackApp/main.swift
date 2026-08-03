// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app executable: three lines, on purpose.
//
// Everything Morbstack.app actually is lives in `MorbstackAppCore`, a library target.
// The split gives this bundle entry point, deterministic tour fixtures, and fixture
// diagnostics one shared app implementation while keeping the executable minimal.
//
// The bundle's `CFBundleExecutable` is `MorbstackApp`, which is this target's name, so
// `make app` is unaffected by the split.

import MorbstackAppCore

MorbstackMainApp.main()
