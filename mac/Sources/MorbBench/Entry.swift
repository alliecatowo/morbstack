// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The `morb bench` subcommand.
public enum MorbBenchCommand {

    /// Runs `morb bench <args>`.
    /// - Returns: the process exit code.
    public static func run(_ arguments: [String], json: Bool) -> Int32 {
        BenchCLI.run(arguments, json: json)
    }
}
