// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The `morb export` subcommand — explicit local Docker image archives.
public enum MorbExportCommand {

    /// Runs `morb export <args>`.
    /// - Returns: the process exit code.
    public static func run(_ arguments: [String], json: Bool) -> Int32 {
        ExportCLI.run(arguments, json: json)
    }
}
