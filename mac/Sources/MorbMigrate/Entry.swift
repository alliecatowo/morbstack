// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The `morb migrate` subcommand.
public enum MorbMigrateCommand {

    /// Runs `morb migrate <args>`.
    /// - Returns: the process exit code.
    public static func run(_ arguments: [String], json: Bool) -> Int32 {
        MigrateCLI.run(arguments, json: json)
    }
}
