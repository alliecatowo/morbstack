// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// SCAFFOLD — DELETE THIS FILE when the real ScanCLI/DebugCLI land.

import Foundation

enum ScanCLI {
    static func run(_ arguments: [String], json: Bool) -> Int32 {
        FileHandle.standardError.write(Data("morb: scan is not implemented in this build\n".utf8))
        return 2
    }
}

enum DebugCLI {
    static func run(_ arguments: [String], json: Bool) -> Int32 {
        FileHandle.standardError.write(Data("morb: debug is not implemented in this build\n".utf8))
        return 2
    }
}
