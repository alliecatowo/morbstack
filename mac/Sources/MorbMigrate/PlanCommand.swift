// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate plan` — a structured, side-effect-free readiness plus image and
// named-volume eligibility comparison. Unlike the transfer commands, this never
// writes a migration report, creates a helper container, pulls an image, or contacts
// a credential helper.

import Foundation
import MorbFeatures

enum PlanCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let args = parseArgs(arguments, valueFlags: ["from", "filter"])
        let plan = MigrationReadOnlyPlanner.inspect(
            from: args.option("from"),
            filter: args.option("filter"),
            includeDanglingImages: args.flag("all"))

        if json {
            emit(json: true, data: jsonObject(for: plan)) {}
        } else {
            printPlan(plan)
        }
        // An unavailable endpoint is an inspection result, not a partially executed
        // migration. Reserve nonzero exits for invalid command syntax.
        return 0
    }

    private static func jsonObject(for plan: MigrationReadOnlyPlan) -> [String: Any] {
        var result: [String: Any] = [
            "read_only": true,
            "would_import": false,
            "source": endpointJSON(plan.source),
            "destination": endpointJSON(plan.destination),
            "unavailable_reason": plan.unavailableReason ?? NSNull(),
        ]
        if let imagePlan = plan.imagePlan {
            result["images"] = [
                "would_copy": imagePlan.wouldCopy.count,
                "would_copy_bytes": imagePlan.wouldCopyBytes,
                "already_present": imagePlan.alreadyPresent.count,
                "items": imagePlan.items.map { item in
                    [
                        "reference": item.reference,
                        "id": item.imageID,
                        "size_bytes": item.sizeBytes,
                        "disposition": item.disposition.rawValue,
                    ] as [String: Any]
                },
            ]
        } else {
            result["images"] = NSNull()
        }
        if let volumePlan = plan.volumePlan {
            result["volumes"] = [
                "eligible": volumePlan.eligible.count,
                "destination_existing": volumePlan.destinationExisting.count,
                "unsupported": volumePlan.unsupported.count,
                "items": volumePlan.items.map { item in
                    [
                        "name": item.name,
                        "driver": item.driver,
                        "disposition": item.disposition.rawValue,
                        "reason": item.reason,
                    ] as [String: Any]
                },
            ]
        } else {
            result["volumes"] = NSNull()
        }
        result["volume_unavailable_reason"] = plan.volumeUnavailableReason ?? NSNull()
        return result
    }

    private static func endpointJSON(_ endpoint: MigrationPlanEndpoint) -> [String: Any] {
        [
            "name": endpoint.name,
            "socket_path": endpoint.socketPath ?? NSNull(),
            "readiness": endpoint.readiness.rawValue,
            "detail": endpoint.detail ?? NSNull(),
        ]
    }

    private static func printPlan(_ plan: MigrationReadOnlyPlan) {
        out("Migration plan (read-only — nothing was changed):")
        printEndpoint("Source", plan.source)
        printEndpoint("Destination", plan.destination)

        if let imagePlan = plan.imagePlan {
            out("")
            var table = TextTable(headers: ["IMAGE", "SIZE", "PLAN"], rightAligned: [1])
            for item in imagePlan.items {
                table.add([
                    item.reference,
                    Format.bytes(item.sizeBytes),
                    item.disposition == .wouldCopy ? "would copy" : "already present",
                ])
            }
            out("Images:")
            out(imagePlan.items.isEmpty ? "  (no tagged images matched)" : table.render())
            out("")
            out("Would copy: \(imagePlan.wouldCopy.count) image(s), \(Format.bytes(imagePlan.wouldCopyBytes))")
            out("Already present: \(imagePlan.alreadyPresent.count) image(s)")
        } else {
            out("")
            out("Image comparison was not derived: \(plan.unavailableReason ?? "unavailable")")
        }

        out("")
        if let volumePlan = plan.volumePlan {
            var table = TextTable(headers: ["VOLUME", "DRIVER", "PLAN"])
            for item in volumePlan.items {
                table.add([item.name, item.driver, volumePlanText(item.disposition)])
            }
            out("Named volumes:")
            out(volumePlan.items.isEmpty ? "  (no named source volumes)" : table.render())
            out("")
            out("Eligible for a later explicit transfer: \(volumePlan.eligible.count) volume(s)")
            out("Destination already exists: \(volumePlan.destinationExisting.count) volume(s)")
            out("Unsupported driver: \(volumePlan.unsupported.count) volume(s)")
            out("No helper container was created and no volume contents were inspected.")
        } else {
            out("Named-volume eligibility was not derived: \(plan.volumeUnavailableReason ?? "unavailable")")
        }
        out("")
        out("Run an explicit transfer command only after reviewing this plan.")
    }

    private static func volumePlanText(_ disposition: MigrationVolumePlanDisposition) -> String {
        switch disposition {
        case .eligible: return "eligible"
        case .destinationExists: return "destination exists"
        case .unsupportedDriver: return "unsupported driver"
        }
    }

    private static func printEndpoint(_ label: String, _ endpoint: MigrationPlanEndpoint) {
        out("\(label): \(endpoint.name) (\(endpoint.readiness.rawValue.replacingOccurrences(of: "_", with: " ")))")
        if let detail = endpoint.detail { out("  \(detail)") }
        if let socketPath = endpoint.socketPath { out("  socket: \(socketPath)") }
    }
}
