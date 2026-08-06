// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Deterministic fixture coverage for live-window and future UI tests.
//
// This is deliberately Foundation-only.  It does not construct a SwiftUI view, imitate
// a title bar, render a bitmap, or make any visual claim.  `--tour-fixtures` uses this
// same data to open the real app window; Computer Use is the current full-window review
// surface and an XCUITest host is the planned automated one.

import Foundation

enum FixtureDiagnostics {

    struct Check {
        let name: String
        let detail: String
        let passed: Bool
    }

    static func run() -> [Check] {
        let containers = ShotFixtures.containers
        let images = ShotFixtures.images
        let volumes = ShotFixtures.volumes
        let networks = ShotFixtures.networks
        let buildCache = ShotFixtures.buildCache
        let disk = ShotFixtures.disk
        let stats = ShotFixtures.statsByContainer
        let logLines = ShotLogs.apiLog()

        let requiredStates: Set<String> = ["running", "exited", "restarting", "paused"]
        let observedStates = Set(containers.map(\.state))
        let referencedImages = Set(containers.map(\.image))
        let taggedImages = Set(images.flatMap(\.repoTags).filter { $0 != "<none>:<none>" })
        let runningContainerNames = Set(containers.filter(\.isRunning).map(\.displayName))

        /// A cumulative counter that goes backwards inside one fixture series would be
        /// a restart the fixture never modelled, and the rate derivation would
        /// correctly drop the interval — silently thinning a chart nobody meant to thin.
        let countersAreMonotonic = stats.allSatisfy { entry in
            zip(entry.samples, entry.samples.dropFirst()).allSatisfy { previous, current in
                func rises(_ old: Int64?, _ new: Int64?) -> Bool {
                    guard let old, let new else { return old == nil && new == nil }
                    return new >= old
                }
                return rises(previous.networkReceivedBytes, current.networkReceivedBytes)
                    && rises(previous.networkTransmittedBytes, current.networkTransmittedBytes)
                    && rises(previous.blockReadBytes, current.blockReadBytes)
                    && rises(previous.blockWrittenBytes, current.blockWrittenBytes)
            }
        }

        let imageBytes = images.reduce(Int64.zero) { $0 + $1.size }
        let volumeBytes = volumes.reduce(Int64.zero) { $0 + ($1.size ?? 0) }
        let firstInspectIsJSON: Bool
        if let firstContainer = containers.first,
           let data = ShotFixtures.inspectJSON(for: firstContainer).data(using: .utf8) {
            firstInspectIsJSON = (try? JSONSerialization.jsonObject(with: data)) != nil
        } else {
            firstInspectIsJSON = false
        }

        return [
            Check(
                name: "container identities",
                detail: "\(containers.count) records with unique Docker identifiers",
                passed: !containers.isEmpty && Set(containers.map(\.id)).count == containers.count),
            Check(
                name: "container state coverage",
                detail: "states: \(observedStates.sorted().joined(separator: ", "))",
                passed: requiredStates.isSubset(of: observedStates)),
            Check(
                name: "image references",
                detail: "every fixture container image has a tagged image record",
                passed: referencedImages.isSubset(of: taggedImages)),
            Check(
                name: "image variants",
                detail: "tagged and dangling images are both represented",
                passed: images.contains(where: \.isDangling) && images.contains(where: { !$0.isDangling })),
            Check(
                name: "volume variants",
                detail: "attached and unused volumes are both represented",
                passed: volumes.contains(where: \.isUnused) && volumes.contains(where: { !$0.isUnused })),
            Check(
                name: "network variants",
                detail: "built-in and user-defined networks are both represented",
                passed: networks.contains(where: \.isBuiltIn) && networks.contains(where: { !$0.isBuiltIn })),
            Check(
                name: "build-cache variants",
                detail: "in-use and reclaimable cache records are both represented",
                passed: buildCache.contains(where: \.inUse) && buildCache.contains(where: { !$0.inUse })),
            Check(
                name: "disk accounting",
                detail: "image and volume totals match their fixture records",
                passed: disk.imagesTotal == imageBytes && disk.volumesTotal == volumeBytes && disk.total >= 0),
            Check(
                name: "inspect JSON",
                detail: "a representative fixture inspect response parses as JSON",
                passed: firstInspectIsJSON),
            Check(
                name: "logs",
                detail: "\(logLines.count) lines include stdout and stderr",
                passed: !logLines.isEmpty
                    && logLines.contains(where: { $0.stream == .stdout })
                    && logLines.contains(where: { $0.stream == .stderr })),
            Check(
                name: "statistics",
                detail: "every running fixture container has a nonempty nonnegative time series",
                passed: !stats.isEmpty
                    && Set(stats.map(\.name)) == runningContainerNames
                    && stats.allSatisfy { entry in
                        runningContainerNames.contains(entry.name)
                            && !entry.samples.isEmpty
                            && entry.samples.allSatisfy { $0.cpuPercent >= 0 && $0.memBytes >= 0 && $0.memLimit > 0 }
                    }),
            // Docker reports network and block I/O as cumulative counters, and reports
            // *no* counter at all for a container with no interfaces or no block
            // device it has touched. Both facts have to exist in the fixtures, because
            // "unreported" and "zero" are different states of the Statistics tab and a
            // fixture set that only ever produces one of them cannot show the other.
            Check(
                name: "counter coverage",
                detail: "cumulative counters are monotonic, and both reported and unreported cases exist",
                passed: countersAreMonotonic
                    && stats.contains { $0.samples.contains { $0.networkReceivedBytes != nil } }
                    && stats.contains { $0.samples.allSatisfy { $0.networkReceivedBytes == nil } }
                    && stats.contains { $0.samples.contains { $0.blockReadBytes != nil } }
                    && stats.contains { $0.samples.allSatisfy { $0.blockReadBytes == nil } }),
        ]
    }
}
