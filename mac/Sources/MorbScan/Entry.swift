// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The `morb scan` subcommand — local SBOM and vulnerability scanning.
public enum MorbScanCommand {

    /// Runs `morb scan <args>`.
    /// - Returns: the process exit code.
    public static func run(_ arguments: [String], json: Bool) -> Int32 {
        ScanCLI.run(arguments, json: json)
    }
}

/// The `morb debug` subcommand — read-only toolbox readiness and target planning.
public enum MorbDebugCommand {

    /// Runs `morb debug <args>`.
    /// - Returns: the process exit code.
    public static func run(_ arguments: [String], json: Bool) -> Int32 {
        DebugCLI.run(arguments, json: json)
    }
}
