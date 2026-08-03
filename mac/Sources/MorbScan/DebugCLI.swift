// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb debug` deliberately has a smaller surface than its name suggests today.
// A regular Docker exec is not a toolbox for a distroless container, and the
// current EngineClient collects a complete exec response rather than safely
// bridging an interactive terminal.  Claiming either is a working debug shell
// would strand a person in the failure case this command is meant to solve.

import Foundation
import MorbstackKit

enum DebugCLI {

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        if arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            printUsage()
            return 0
        }

        guard arguments.count == 1, let container = arguments.first, !container.hasPrefix("--") else {
            return usageError(
                arguments.isEmpty ? "a container name or ID is required" : "debug accepts exactly one container name or ID",
                json: json)
        }

        let reason = "`morb debug` is not available yet: Morbstack has no pinned toolbox-image lifecycle "
            + "or safe interactive terminal bridge. A normal exec would not debug a distroless container. "
            + "The target container was not inspected or changed."
        if json {
            emitJSON([
                "available": false,
                "container": container,
                "reason": reason,
                "missing_primitives": ["pinned toolbox image lifecycle", "interactive stdin/stdout/stderr bridge", "documented namespace and cleanup policy"],
            ])
        } else {
            FileHandle.standardError.write(Data(("morb debug: \(reason)\n").utf8))
            FileHandle.standardError.write(Data(
                "For a container that already has a shell, use `docker --host unix://\(MorbPaths.dockerSocket.path) exec -it \(container) /bin/sh`.\n"
                    .utf8))
        }
        return 2
    }

    private static func usageError(_ message: String, json: Bool) -> Int32 {
        if json {
            emitJSON(["error": message, "usage": "morb debug <container>"])
        } else {
            FileHandle.standardError.write(Data(("morb debug: \(message)\n\n").utf8))
            printUsage(to: .standardError)
        }
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let text = """
        Usage: morb debug <container>

        A toolbox shell for containers without a shell is not implemented yet. Morbstack
        refuses rather than treating a regular exec as an equivalent feature: the current
        client cannot safely bridge an interactive terminal and no pinned toolbox image
        lifecycle exists. This command never changes the target while unavailable.
        """
        output.write(Data((text + "\n").utf8))
    }

    private static func emitJSON(_ value: Any) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            FileHandle.standardError.write(Data("morb debug: could not encode JSON output\n".utf8))
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
