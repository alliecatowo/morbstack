// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command surface for the future debug toolbox. It has a useful, read-only
// planning surface now, but deliberately has no execution action until every
// safety primitive documented in docs/debug.md is available.

import Foundation
import MorbFeatures
import MorbstackKit

enum DebugCLI {

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        switch parse(arguments) {
        case .failure(let error):
            return usageError(error.message, json: json)
        case .success(.help):
            printUsage()
            return 0
        case .success(.check(let manifestURL)):
            return check(manifestURL: manifestURL, json: json)
        case .success(.plan(let container)):
            return plan(container: container, json: json)
        }
    }

    // MARK: - Read-only availability

    /// Reports the static contract without accessing the Docker socket or network.
    /// The optional descriptor is untrusted local input and can only establish a
    /// declaration, never a verified, executable toolbox asset.
    private static func check(manifestURL: URL?, json: Bool) -> Int32 {
        let readiness = DebugToolboxPlanner.readiness(
            manifestURL: manifestURL ?? MorbPaths.debugToolboxManifest)
        if json {
            emitJSON(readinessJSON(readiness, mode: "check"))
        } else {
            out("Debug toolbox readiness (no engine or network access)")
            out("  status     unavailable")
            out("  engine     \(readiness.engineAccess)")
            out("  network    \(readiness.networkAccess)")
            renderAssetAssessment(readiness.assetAssessment)
            renderAcquisitionPlan(readiness.acquisitionPlan)
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
        case check(manifestURL: URL?)
        case plan(String)
    }

    private struct ArgumentError: Error {
        var message: String
    }

    private static func parse(_ arguments: [String]) -> Result<Command, ArgumentError> {
        if arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .success(.help)
        }
        if arguments == ["check"] || arguments == ["--check"] {
            return .success(.check(manifestURL: nil))
        }
        if arguments.count == 3,
           (arguments[0] == "check" || arguments[0] == "--check"),
           arguments[1] == "--manifest",
           !arguments[2].isEmpty {
            let path = (arguments[2] as NSString).expandingTildeInPath
            return .success(.check(manifestURL: URL(fileURLWithPath: path)))
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
            return .failure(ArgumentError(message: "a container name or ID is required (or pass check)"))
        }
        return .failure(ArgumentError(message: "expected `check [--manifest <path>]` or one container name/ID"))
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
        renderAssetAssessment(plan.readiness.assetAssessment)
        renderAcquisitionPlan(plan.readiness.acquisitionPlan)
        out()
        out("Read-only engine request:")
        for request in plan.engineRequests { out("  \(request)") }
        out()
        out("No operation was performed:")
        for nonAction in plan.nonActions { out("  - \(nonAction)") }
        renderMissingRequirements(plan.readiness)
    }

    private static func renderAssetAssessment(_ assessment: DebugToolboxAssetAssessment) {
        out()
        out("Toolbox asset descriptor (local declaration only):")
        out("  status          \(assessment.status)")
        out("  manifest path   \(terminalSafe(assessment.path))")
        out("  assessment      \(assessment.detail)")
        guard let manifest = assessment.manifest else { return }
        out("  asset ID        \(manifest.assetID)")
        out("  image reference \(manifest.imageReference)")
        out("  image digest    \(manifest.imageDigest)")
        out("  platforms       \(manifest.platforms.map(\.identifier).joined(separator: ", "))")
        out("  provenance      \(manifest.provenance.method) from \(manifest.provenance.issuer)")
        out("  valid through   \(manifest.validThrough)")
        out("  verification    not performed; this descriptor does not make a toolbox available")
    }

    private static func renderAcquisitionPlan(_ plan: DebugToolboxAcquisitionPlan) {
        out()
        out("Future acquisition and rollback contract (not executed):")
        out("  status          unavailable")
        out("  next disposition \(plan.disposition.rawValue)")
        out("  network         \(plan.networkAccess)")
        out("  engine          \(plan.engineAccess)")
        out("  required stages:")
        for stage in plan.stages {
            out("    - \(stage.rawValue): \(stage.description)")
        }
        out("  rollback guarantees:")
        for guarantee in plan.rollback.guarantees {
            out("    - \(guarantee)")
        }
        out("  prohibited fallbacks:")
        for fallback in plan.rollback.prohibitedFallbacks {
            out("    - \(fallback)")
        }
        out("  no operation was performed:")
        for nonAction in plan.nonActions {
            out("    - \(nonAction)")
        }
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
            emitJSON(["error": message, "usage": "morb debug check [--manifest <path>] | morb debug [plan] <container>"])
        } else {
            FileHandle.standardError.write(Data(("morb debug: \(message)\n\n").utf8))
            printUsage(to: .standardError)
        }
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let text = """
        Usage: morb debug check [--manifest <path>]
               morb debug [plan] <container>

        Inspect whether Morbstack can safely offer a toolbox session for a container.
        `check` only reads one local toolbox descriptor (if present): it does not
        contact Docker or a network. A descriptor is untrusted declarative policy,
        not image or signature verification, and cannot make a toolbox available.
        `morb debug [plan] <container>` issues one read-only Docker container
        inspect request, then lists the exact actions it did not perform.

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
            "asset": assetJSON(readiness.assetAssessment),
            "acquisition": acquisitionJSON(readiness.acquisitionPlan),
            "missing_requirements": readiness.missingRequirements.map { $0.rawValue },
            "non_actions": [
                "did not create or start a toolbox container",
                "did not start, stop, pause, restart, or exec in a target container",
                "did not pull an image or contact a registry",
                "did not attach a terminal",
            ],
        ]
    }

    private static func assetJSON(_ assessment: DebugToolboxAssetAssessment) -> [String: Any] {
        var output: [String: Any] = [
            "status": assessment.status,
            "manifest_path": assessment.path,
            "detail": assessment.detail,
        ]
        guard let manifest = assessment.manifest else { return output }
        output["asset_id"] = manifest.assetID
        output["image_reference"] = manifest.imageReference
        output["image_digest"] = manifest.imageDigest
        output["platforms"] = manifest.platforms.map(\.identifier)
        output["provenance"] = [
            "method": manifest.provenance.method,
            "issuer": manifest.provenance.issuer,
            "identity": manifest.provenance.identity,
            "bundle_digest": manifest.provenance.bundleDigest,
        ]
        output["valid_through"] = manifest.validThrough
        output["verified"] = false
        return output
    }

    private static func acquisitionJSON(_ plan: DebugToolboxAcquisitionPlan) -> [String: Any] {
        [
            "available": plan.available,
            "disposition": plan.disposition.rawValue,
            "network": plan.networkAccess,
            "engine": plan.engineAccess,
            "stages": plan.stages.map {
                ["id": $0.rawValue, "description": $0.description]
            },
            "rollback": [
                "guarantees": plan.rollback.guarantees,
                "prohibited_fallbacks": plan.rollback.prohibitedFallbacks,
            ],
            "non_actions": plan.nonActions,
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
            "name": jsonValue(plan.target.name),
            "image_reference": jsonValue(plan.target.imageReference),
            "image_id": jsonValue(plan.target.imageID),
            "state": jsonValue(plan.target.state),
            "running": jsonValue(plan.target.isRunning),
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

    private static func jsonValue(_ value: Any?) -> Any { value ?? NSNull() }

    /// A caller may explicitly pass any readable manifest path. JSON output receives
    /// the original path (and escapes it correctly); human output must not allow a
    /// control character in that path to alter the terminal.
    private static func terminalSafe(_ value: String) -> String {
        value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? "�" : String($0)
        }.joined()
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
