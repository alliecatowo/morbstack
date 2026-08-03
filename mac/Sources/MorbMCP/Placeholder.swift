// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// SCAFFOLD — DELETE THIS FILE when the real MCPCLI lands.
//
// It exists only so the package keeps compiling between the moment the target was
// declared and the moment its implementation was written. Several agents build this
// tree concurrently; a target that references a type nobody has written yet breaks
// everyone's build, not just its author's.

import Foundation

enum MCPCLI {
    static func run(_ arguments: [String], json: Bool) -> Int32 {
        FileHandle.standardError.write(Data("morb: mcp is not implemented in this build\n".utf8))
        return 2
    }
}
