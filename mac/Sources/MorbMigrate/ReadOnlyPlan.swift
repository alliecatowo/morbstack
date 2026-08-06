// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deliberately narrow migration planning API for the native app and `morb`
// command line. It is a comparison only: no runtime start, Docker configuration
// mutation, credential lookup, helper-container creation, image pull, import, or
// report write is reachable from this file.

import Foundation
import MorbFeatures
import MorbstackKit

/// The observed state of an endpoint in a read-only migration plan.
public enum MigrationPlanReadiness: String, Sendable, Equatable, Codable {
    case ready
    case notInstalled = "not_installed"
    case notRunning = "not_running"
    case unavailable
}

/// A source or destination used by ``MigrationReadOnlyPlan``.
///
/// `detail` is diagnostic text only. It never contains configuration values or
/// registry credentials.
public struct MigrationPlanEndpoint: Sendable, Equatable, Codable {
    public let name: String
    public let socketPath: String?
    public let readiness: MigrationPlanReadiness
    public let detail: String?

    public init(name: String, socketPath: String?, readiness: MigrationPlanReadiness, detail: String?) {
        self.name = name
        self.socketPath = socketPath
        self.readiness = readiness
        self.detail = detail
    }
}

/// One image observed in a derived, read-only comparison.
public struct MigrationImagePlanItem: Sendable, Equatable, Codable, Identifiable {
    public enum Disposition: String, Sendable, Equatable, Codable {
        /// The source has this image and the running Morbstack engine does not.
        case wouldCopy = "would_copy"
        /// The running Morbstack engine already has the identical image ID.
        case alreadyPresent = "already_present"
    }

    public let reference: String
    public let imageID: String
    public let sizeBytes: Int64
    public let disposition: Disposition

    public var id: String { "\(reference)|\(imageID)" }

    public init(reference: String, imageID: String, sizeBytes: Int64, disposition: Disposition) {
        self.reference = reference
        self.imageID = imageID
        self.sizeBytes = sizeBytes
        self.disposition = disposition
    }
}

/// The image portion of a migration plan. It is present only after the planner
/// successfully reads both Docker image inventories.
public struct MigrationImagePlan: Sendable, Equatable, Codable {
    public let items: [MigrationImagePlanItem]

    public init(items: [MigrationImagePlanItem]) {
        self.items = items
    }

    public var wouldCopy: [MigrationImagePlanItem] {
        items.filter { $0.disposition == .wouldCopy }
    }

    public var alreadyPresent: [MigrationImagePlanItem] {
        items.filter { $0.disposition == .alreadyPresent }
    }

    public var wouldCopyBytes: Int64 {
        wouldCopy.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// A side-effect-free migration inspection result.
///
/// The image and volume portions are intentionally independent. An image-list failure
/// must not turn a successfully derived volume inventory into an empty list, and vice
/// versa. Neither optional plan is a transfer authorization.
public struct MigrationReadOnlyPlan: Sendable, Equatable, Codable {
    public let source: MigrationPlanEndpoint
    public let destination: MigrationPlanEndpoint
    public let imagePlan: MigrationImagePlan?
    public let volumePlan: MigrationVolumePlan?
    /// Why the image comparison was not derived. Kept as the existing image-facing
    /// field so image callers do not accidentally display a volume inventory failure.
    public let unavailableReason: String?
    /// Why the read-only source/destination volume inventory was not derived.
    public let volumeUnavailableReason: String?

    public init(
        source: MigrationPlanEndpoint,
        destination: MigrationPlanEndpoint,
        imagePlan: MigrationImagePlan?,
        unavailableReason: String?,
        volumePlan: MigrationVolumePlan? = nil,
        volumeUnavailableReason: String? = nil
    ) {
        self.source = source
        self.destination = destination
        self.imagePlan = imagePlan
        self.volumePlan = volumePlan
        self.unavailableReason = unavailableReason
        self.volumeUnavailableReason = volumeUnavailableReason
    }
}

/// Produces truthful migration readiness plus image and named-volume eligibility data
/// without changing either engine. This is the only public migration planning entry
/// point intended for UI use; transfer commands remain explicit CLI operations.
public enum MigrationReadOnlyPlanner {

    /// Inspects a named source (`docker-desktop`, `colima`, `orbstack`) or a live Unix
    /// socket. With no source, it uses the existing safe auto-selection rule: exactly
    /// one non-Morbstack runtime must be running. The method never starts an engine.
    public static func inspect(
        from sourceToken: String? = nil,
        filter: String? = nil,
        includeDanglingImages: Bool = false
    ) -> MigrationReadOnlyPlan {
        let destination = endpoint(for: RuntimeDetect.detectMorbstack())
        var source = requestedSourceEndpoint(for: sourceToken)

        let resolvedSource: MigrationSource
        do {
            resolvedSource = try SourceResolver.resolve(from: sourceToken)
        } catch {
            let reason = "Source is unavailable: \(error)"
            source = MigrationPlanEndpoint(
                name: source.name,
                socketPath: source.socketPath,
                readiness: source.readiness == .ready ? .unavailable : source.readiness,
                detail: reason)
            return MigrationReadOnlyPlan(
                source: source,
                destination: destination,
                imagePlan: nil,
                unavailableReason: reason,
                volumePlan: nil,
                volumeUnavailableReason: reason)
        }

        // `morbstack` is a destination, not a legitimate source for a migration plan.
        // Rejecting it prevents a self-comparison from being presented as a transfer.
        if sourceToken?.lowercased() == "morbstack" || sameSocket(resolvedSource.socketPath, MorbPaths.dockerSocket.path) {
            source = MigrationPlanEndpoint(
                name: "Morbstack",
                socketPath: resolvedSource.socketPath,
                readiness: .unavailable,
                detail: "Morbstack is the migration destination, not a source.")
            return MigrationReadOnlyPlan(
                source: source,
                destination: destination,
                imagePlan: nil,
                unavailableReason: source.detail,
                volumePlan: nil,
                volumeUnavailableReason: source.detail)
        }

        source = MigrationPlanEndpoint(
            name: resolvedSource.label,
            socketPath: resolvedSource.socketPath,
            readiness: .ready,
            detail: nil)

        guard destination.readiness == .ready else {
            let reason = destination.detail ?? "Morbstack's Docker engine is not running."
            return MigrationReadOnlyPlan(
                source: source,
                destination: destination,
                imagePlan: nil,
                unavailableReason: reason,
                volumePlan: nil,
                volumeUnavailableReason: reason)
        }

        let destinationClient = EngineClient()
        let (items, planError) = ImagesCommand.plan(
            source: resolvedSource,
            destination: destinationClient,
            filter: filter,
            includeAll: includeDanglingImages)
        let imagePlan: MigrationImagePlan?
        if planError == nil {
            imagePlan = MigrationImagePlan(items: items.map { item in
                MigrationImagePlanItem(
                    reference: item.reference,
                    imageID: item.id,
                    sizeBytes: item.size,
                    disposition: item.status == "planned" ? .wouldCopy : .alreadyPresent)
            })
        } else {
            imagePlan = nil
        }
        let (derivedVolumePlan, volumePlanError) = deriveVolumePlan(
            source: resolvedSource,
            destination: destinationClient)
        return MigrationReadOnlyPlan(
            source: source,
            destination: destination,
            imagePlan: imagePlan,
            unavailableReason: planError,
            volumePlan: derivedVolumePlan,
            volumeUnavailableReason: volumePlanError)
    }

    /// The outbound mirror of ``inspect(from:filter:includeDanglingImages:)``: Morbstack
    /// is the fixed *source* and `destinationToken` (a named runtime or a socket path,
    /// resolved exactly like `--from` is) is the target being migrated *to*. This is
    /// the read-only comparison behind `morb migrate --to`.
    ///
    /// It deliberately shares every planning primitive with the inbound planner —
    /// ``ImagesCommand/plan(source:destination:filter:includeAll:)``,
    /// ``deriveVolumePlan(source:destination:)``, ``endpoint(for:)`` — so an outbound
    /// plan carries the exact same guarantees (GET-only reads, no engine mutation) as
    /// an inbound one.
    public static func inspectOutbound(
        to destinationToken: String,
        filter: String? = nil,
        includeDanglingImages: Bool = false
    ) -> MigrationReadOnlyPlan {
        let sourceEndpoint = endpoint(for: RuntimeDetect.detectMorbstack())

        let resolvedDestination: MigrationSource
        do {
            resolvedDestination = try SourceResolver.resolve(from: destinationToken)
        } catch {
            let reason = "Destination is unavailable: \(error)"
            let destination = MigrationPlanEndpoint(
                name: destinationToken, socketPath: nil, readiness: .unavailable, detail: reason)
            return MigrationReadOnlyPlan(
                source: sourceEndpoint, destination: destination, imagePlan: nil,
                unavailableReason: reason, volumePlan: nil, volumeUnavailableReason: reason)
        }

        // Morbstack cannot be its own outbound destination — the same self-comparison
        // guard `inspect(from:)` applies to a source, applied to a destination instead.
        if destinationToken.lowercased() == "morbstack"
            || sameSocket(resolvedDestination.socketPath, MorbPaths.dockerSocket.path)
        {
            let destination = MigrationPlanEndpoint(
                name: "Morbstack", socketPath: resolvedDestination.socketPath, readiness: .unavailable,
                detail: "Morbstack is the migration source for an outbound transfer, not a destination. Pass another runtime or socket with --to.")
            return MigrationReadOnlyPlan(
                source: sourceEndpoint, destination: destination, imagePlan: nil,
                unavailableReason: destination.detail, volumePlan: nil, volumeUnavailableReason: destination.detail)
        }

        guard sourceEndpoint.readiness == .ready else {
            let reason = sourceEndpoint.detail ?? "Morbstack's Docker engine is not running."
            let destination = MigrationPlanEndpoint(
                name: resolvedDestination.label, socketPath: resolvedDestination.socketPath, readiness: .ready, detail: nil)
            return MigrationReadOnlyPlan(
                source: sourceEndpoint, destination: destination, imagePlan: nil,
                unavailableReason: reason, volumePlan: nil, volumeUnavailableReason: reason)
        }

        let destination = MigrationPlanEndpoint(
            name: resolvedDestination.label, socketPath: resolvedDestination.socketPath, readiness: .ready, detail: nil)
        let morbstackAsSource = MigrationSource(
            label: sourceEndpoint.name, client: EngineClient(), socketPath: sourceEndpoint.socketPath ?? MorbPaths.dockerSocket.path)

        let (items, planError) = ImagesCommand.plan(
            source: morbstackAsSource, destination: resolvedDestination.client,
            filter: filter, includeAll: includeDanglingImages)
        let imagePlan: MigrationImagePlan?
        if planError == nil {
            imagePlan = MigrationImagePlan(items: items.map { item in
                MigrationImagePlanItem(
                    reference: item.reference, imageID: item.id, sizeBytes: item.size,
                    disposition: item.status == "planned" ? .wouldCopy : .alreadyPresent)
            })
        } else {
            imagePlan = nil
        }
        let (derivedVolumePlan, volumePlanError) = deriveVolumePlan(
            source: morbstackAsSource, destination: resolvedDestination.client)
        return MigrationReadOnlyPlan(
            source: sourceEndpoint, destination: destination, imagePlan: imagePlan,
            unavailableReason: planError, volumePlan: derivedVolumePlan,
            volumeUnavailableReason: volumePlanError)
    }

    /// Reads the two Docker volume inventories only. In particular, it does not use
    /// `VolumesCommand.isDestinationVolumeEmpty`: that path creates a helper
    /// container and is appropriate only after a user has opted into transfer review.
    private static func deriveVolumePlan(
        source: MigrationSource,
        destination: EngineClient
    ) -> (MigrationVolumePlan?, String?) {
        let sourceVolumes: [MigrationVolumeInventoryItem]
        do {
            sourceVolumes = try volumeInventory(on: source.client)
        } catch {
            return (nil, "Could not list named volumes on \(source.label): \(error)")
        }
        do {
            let destinationVolumes = try volumeInventory(on: destination)
            return (MigrationVolumePlanner.plan(source: sourceVolumes, destination: destinationVolumes), nil)
        } catch {
            return (nil, "Could not list named volumes on Morbstack: \(error)")
        }
    }

    private static func volumeInventory(on client: EngineClient) throws -> [MigrationVolumeInventoryItem] {
        let response = try client.jsonObject("GET", "/volumes", timeout: 30)
        let volumes = JSONRead.array(response, "Volumes") as? [[String: Any]] ?? []
        return volumes.compactMap { volume in
            guard let name = JSONRead.string(volume, "Name"), !name.isEmpty else { return nil }
            // Docker requires Driver, but a malformed/incomplete response must not be
            // upgraded to `local` eligibility by a default value.
            return MigrationVolumeInventoryItem(
                name: name,
                driver: JSONRead.string(volume, "Driver") ?? "unknown")
        }
    }

    private static func endpoint(for report: RuntimeReport) -> MigrationPlanEndpoint {
        if !report.installed {
            return MigrationPlanEndpoint(
                name: report.name,
                socketPath: nil,
                readiness: .notInstalled,
                detail: "\(report.name) is not installed.")
        }
        if !report.running {
            return MigrationPlanEndpoint(
                name: report.name,
                socketPath: report.socketPath,
                readiness: .notRunning,
                detail: report.notes.first ?? "\(report.name) is not running.")
        }
        return MigrationPlanEndpoint(
            name: report.name,
            socketPath: report.socketPath,
            readiness: .ready,
            detail: nil)
    }

    private static func requestedSourceEndpoint(for sourceToken: String?) -> MigrationPlanEndpoint {
        guard let sourceToken else {
            return MigrationPlanEndpoint(
                name: "Automatic source selection",
                socketPath: nil,
                readiness: .unavailable,
                detail: "Select exactly one running Docker Desktop, Colima, or OrbStack runtime.")
        }

        let normalized = sourceToken.lowercased()
        let knownRuntime: RuntimeReport?
        switch normalized {
        case "docker-desktop", "desktop", "docker":
            knownRuntime = RuntimeDetect.detectDockerDesktop()
        case "colima":
            knownRuntime = RuntimeDetect.detectColima()
        case "orbstack", "orb":
            knownRuntime = RuntimeDetect.detectOrbStack()
        case "morbstack":
            knownRuntime = RuntimeDetect.detectMorbstack()
        default:
            knownRuntime = nil
        }
        if let knownRuntime {
            return endpoint(for: knownRuntime)
        }

        var path = sourceToken
        if path.hasPrefix("unix://") {
            path = String(path.dropFirst("unix://".count))
        }
        path = (path as NSString).expandingTildeInPath
        return MigrationPlanEndpoint(
            name: path,
            socketPath: path,
            readiness: .unavailable,
            detail: "The socket must exist and answer a Docker ping before a plan can be derived.")
    }

    private static func sameSocket(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
