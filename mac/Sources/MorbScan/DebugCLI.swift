// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command surface for the future debug toolbox. It has a useful, read-only
// planning surface now, but deliberately has no execution action until every
// safety primitive documented in docs/debug.md is available.

import Foundation
import MorbFeatures

enum DebugCLI {

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        switch parse(arguments) {
        case .failure(let error):
            return usageError(error, json: json)
        case .success(.help):
            printUsage()
            return 0
        case .success(.check):
            return check(json: json)
        case .success(.plan(let container)):
            return plan(container: container, json: json)
        }
    }

    // MARK: - Read-only availability

    /// Reports the static contract without accessing the Docker socket or network.
    private static func check(json: Bool) -> Int32 {
        let readiness = DebugToolboxPlanner.readiness()
        if json {
            emitJSON(readinessJSON(readiness, mode: "check"))
        } else {
            out("Debug toolbox readiness (no engine or network access)")
            out("  status     unavailable")
            out("  engine     \(readiness.engineAccess)")
            out("  network    \(readiness.networkAccess)")
            renderMissingRequirements(readiness)
        }
        return 2
    }

    /// Inspects a target with one Docker GET request, then reports why a toolbox
    /// session cannot be created yet. It does not provide an execution escape hatch.
    private static func plan(container: String, json: Bool) -> Int32 {
        do {
            let plan = try DebugToolboxPlanner.inspect(containerReference: container)
            if json {
                emitJSON(planJSON(plan))
            } else {
                renderPlan(plan)
            }
        } catch {
            commandError(describe(error), container: container, json: json)
        }
        return 2
    }

    // MARK: - Parsing

    private enum Command {
        case help
        case check
        case plan(String)
    }

    private static func parse(_ arguments: [String]) -> Result<Command, String> {
        if arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .success(.help)
        }
        if arguments == ["check"] || arguments == ["--check"] {
            return .success(.check)
        }
        if arguments.count == 2, arguments.first == "plan", let container = arguments.last,
           !container.hasPrefix("-") {
            return .success(.plan(container))
        }
        if arguments.count == 2, arguments.first == "--plan", let container = arguments.last,
           !container.hasPrefix("-") {
            return .success(.plan(container))
        }
        if arguments.count == 1, let container = arguments.first, !container.hasPrefix("-") {
            // Preserve `morb debug <container>` while making its read-only nature
            // explicit in both the human and JSON result.
            return .success(.plan(container))
        }
        if arguments.isEmpty {
            return .failure("a container name or ID is required (or pass check)")
        }
        return .failure("expected `check` or one container name/ID")
    }

    // MARK: - Presentation

    private static func renderPlan(_ plan: DebugToolboxPlan) {
        out("Debug toolbox plan (read-only; unavailable)")
        out("  target ID       \(plan.target.id)")
        out("  target name     \(plan.target.name ?? "-")")
        out("  image reference \(plan.target.imageReference ?? "-")")
        out("  image ID        \(plan.target.imageID ?? "-")")
        out("  state           \(plan.target.state ?? "-")")
        out("  running         \(plan.target.isRunning.map { $0 ? "yes" : "no" } ?? "-")")
        out()
        out("Read-only engine request:")
        for request in plan.engineRequests { out("  \(request)") }
        out()
        out("No operation was performed:")
        for nonAction in plan.nonActions { out("  - \(nonAction)") }
        renderMissingRequirements(plan.readiness)
    }

    private static func renderMissingRequirements(_ readiness: DebugToolboxReadiness) {
        out()
        out("Unavailable until Morbstack provides:")
        for requirement in readiness.missingRequirements {
            out("  - \(requirement.description)")
        }
        out()
        out("A regular Docker exec is not presented as a distroless-container toolbox.")
    }

    private static func usageError(_ message: String, json: Bool) -> Int32 {
        if json {
            emitJSON(["error": message, "usage": "morb debug check | morb debug [plan] <container>"])
        } else {
            FileHandle.standardError.write(Data(("morb debug: \(message)\n\n").utf8))
            printUsage(to: .standardError)
        }
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let text = """
        Usage: morb debug check
               morb debug [plan] <container>

        Inspect whether Morbstack can safely offer a toolbox session for a container.
        `check` only reports local capability state: it does not contact Docker or a
        network. The default and `plan` forms issue one read-only Docker container
        inspect request, then list the exact actions they did not perform.

        A toolbox shell for a distroless container is not implemented. Morbstack does
        not equate a regular `docker exec` with a toolbox: no pinned and verified
        toolbox asset, network-consent/update policy, isolated-session policy, or
        full-duplex interactive terminal bridge exists yet. See docs/debug.md.
        """
        output.write(Data((text + "\n").utf8))
    }

    private static func readinessJSON(_ readiness: DebugToolboxReadiness, mode: String) -> [String: Any] {
        [
            "available": readiness.available,
            "mode": mode,
            "engine": readiness.engineAccess,
            "network": readiness.networkAccess,
            "missing_requirements": readiness.missingRequirements.map { $0.rawValue },
            "non_actions": [
                "did not create or start a toolbox container",
                "did not start, stop, pause, restart, or exec in a target container",
                "did not pull an image or contact a registry",
                "did not attach a terminal",
            ],
        ]
    }

    private static func planJSON(_ plan: DebugToolboxPlan) -> [String: Any] {
        var output = readinessJSON(plan.readiness, mode: "plan")
        output["engine"] = "read-only GET request completed"
        output["engine_requests"] = plan.engineRequests
        output["non_actions"] = plan.nonActions
        output["target"] = [
            "requested_reference": plan.target.requestedReference,
            "id": plan.target.id,
            "name": plan.target.name ?? NSNull(),
            "image_reference": plan.target.imageReference ?? NSNull(),
            "image_id": plan.target.imageID ?? NSNull(),
            "state": plan.target.state ?? NSNull(),
            "running": plan.target.isRunning.map { $0 as Any } ?? NSNull(),
        ]
        return output
    }

    private static func commandError(_ message: String, container: String, json: Bool) {
        if json {
            emitJSON([
                "available": false,
                "mode": "plan",
                "container": container,
                "target_inspected": false,
                "error": message,
                "network": "not used",
                "non_actions": [
                    "did not create or start a toolbox container",
                    "did not start, stop, pause, restart, or exec in the target container",
                    "did not pull an image or contact a registry",
                    "did not attach a terminal",
                ],
            ])
        } else {
            FileHandle.standardError.write(Data(("morb debug: \(message)\n").utf8))
            FileHandle.standardError.write(Data("No toolbox, exec, image pull, network request, or target change was performed.\n".utf8))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? DebugToolboxPlanError { return error.description }
        if let error = error as? EngineError { return error.description }
        return error.localizedDescription
    }

    private static func out(_ message: String = "") { print(message) }

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
