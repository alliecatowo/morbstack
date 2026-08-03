// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The `morb mcp` subcommand.
///
/// The CLI's only entry point into this module: `mac/Sources/morb/main.swift` calls
/// `run` and exits with what it returns. Keeping the surface to one function is what
/// lets the MCP server grow without the CLI's argument parser growing with it.
public enum MorbMCPCommand {

    /// Runs `morb mcp <args>`.
    /// - Returns: the process exit code.
    public static func run(_ arguments: [String], json: Bool) -> Int32 {
        MCPCLI.run(arguments, json: json)
    }
}
