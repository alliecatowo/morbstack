// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The read-only service boundary for a future distroless-container debug
// toolbox. This deliberately does not use Docker's exec or container-create
// APIs: neither is an honest substitute for a verified toolbox and a
// bidirectional terminal session.

import Foundation
import MorbFeatures

/// A prerequisite that must be present before Morbstack can offer a toolbox
/// session. The stable identifiers make the unavailable state useful to the
/// native app and other callers without exposing a pretend execution API.
public enum DebugToolboxRequirement: String, CaseIterable, Sendable {
    /// A toolbox must be local, immutable, and cryptographically attributable
    /// before it can join a user's target namespaces.
    case verifiedPinnedToolboxAsset = "verified_pinned_toolbox_asset"
    /// Fetching or refreshing a debug image is network activity, and its consent,
    /// expiry, and update rules must be explicit rather than hidden in `debug`.
    case consentedAcquisitionPolicy = "consented_toolbox_acquisition_policy"
    /// Namespace sharing is a security boundary, not an implementation detail.
    case isolatedSessionPolicy = "isolated_session_policy"
    /// A complete captured exec response cannot power an interactive shell.
    case interactiveTerminalBridge = "interactive_terminal_bridge"

    public var description: String {
        switch self {
        case .verifiedPinnedToolboxAsset:
            return "a local immutable toolbox image with verified provenance"
        case .consentedAcquisitionPolicy:
            return "an explicit user-consented toolbox fetch, update, and expiry policy"
        case .isolatedSessionPolicy:
            return "a documented namespace, filesystem, network, capability, and cleanup policy"
        case .interactiveTerminalBridge:
            return "a full-duplex, cancellation-safe interactive terminal bridge"
        }
    }
}

/// What Morbstack can establish without contacting Docker or a registry.
public struct DebugToolboxReadiness: Sendable, Equatable {
    public let available: Bool
    public let missingRequirements: [DebugToolboxRequirement]
    public let networkAccess: String
    public let engineAccess: String
    /// A local manifest assessment. This can describe an expected pinned asset, but
    /// never says that the image or its provenance has been cryptographically verified.
    public let assetAssessment: DebugToolboxAssetAssessment

    public init(
        available: Bool,
        missingRequirements: [DebugToolboxRequirement],
        networkAccess: String,
        engineAccess: String,
        assetAssessment: DebugToolboxAssetAssessment
    ) {
        self.available = available
        self.missingRequirements = missingRequirements
        self.networkAccess = networkAccess
        self.engineAccess = engineAccess
        self.assetAssessment = assetAssessment
    }
}

/// A deliberately small, redacted summary of a Docker container inspect result.
/// It excludes environment variables, labels, mounts, process arguments, and
/// credentials, none of which are needed to decide whether a toolbox can run.
public struct DebugToolboxTarget: Sendable, Equatable {
    public let requestedReference: String
    public let id: String
    public let name: String?
    public let imageReference: String?
    public let imageID: String?
    public let state: String?
    public let isRunning: Bool?

    public init(
        requestedReference: String,
        id: String,
        name: String?,
        imageReference: String?,
        imageID: String?,
        state: String?,
        isRunning: Bool?
    ) {
        self.requestedReference = requestedReference
        self.id = id
        self.name = name
        self.imageReference = imageReference
        self.imageID = imageID
        self.state = state
        self.isRunning = isRunning
    }
}

/// The result of a target inspection. `engineRequests` records exactly what this
/// planner did; `nonActions` records the consequential things it intentionally
/// did not do. This makes the result safe to present before a future run command
/// exists.
public struct DebugToolboxPlan: Sendable, Equatable {
    public let readiness: DebugToolboxReadiness
    public let target: DebugToolboxTarget
    public let engineRequests: [String]
    public let nonActions: [String]

    public init(
        readiness: DebugToolboxReadiness,
        target: DebugToolboxTarget,
        engineRequests: [String],
        nonActions: [String]
    ) {
        self.readiness = readiness
        self.target = target
        self.engineRequests = engineRequests
        self.nonActions = nonActions
    }
}

/// Errors that can happen before a read-only inspect request is issued.
public enum DebugToolboxPlanError: Error, CustomStringConvertible {
    case invalidContainerReference
    case malformedInspectDocument

    public var description: String {
        switch self {
        case .invalidContainerReference:
            return "container name or ID contains characters Docker does not permit"
        case .malformedInspectDocument:
            return "Docker returned a container inspect document without a container ID"
        }
    }
}

/// Builds evidence for the unavailable state of the debug toolbox.
///
/// The only Engine operation this type performs is `GET /containers/{id}/json`.
/// It never starts the daemon, creates a helper, executes in the target, pulls an
/// image, or contacts a registry. A future executor must be a separate, explicit
/// capability; adding it here would make callers too likely to mistake planning
/// for permission to mutate a target.
public enum DebugToolboxPlanner {

    public static func readiness(
        manifestURL: URL = MorbPaths.debugToolboxManifest
    ) -> DebugToolboxReadiness {
        DebugToolboxReadiness(
            available: false,
            missingRequirements: DebugToolboxRequirement.allCases,
            networkAccess: "not used",
            engineAccess: "not contacted",
            assetAssessment: DebugToolboxAsset.assess(manifestURL: manifestURL))
    }

    public static func inspect(
        containerReference: String,
        engine: EngineClient = EngineClient()
    ) throws -> DebugToolboxPlan {
        guard Self.isDockerContainerReference(containerReference) else {
            throw DebugToolboxPlanError.invalidContainerReference
        }

        // This is purposefully the only EngineClient call in this feature. It is
        // a GET without `size`, which does not start, modify, or execute anything.
        let document = try engine.jsonObject(
            "GET", "/containers/\(containerReference)/json", timeout: 10)
        guard let id = JSONRead.string(document, "Id"), !id.isEmpty else {
            throw DebugToolboxPlanError.malformedInspectDocument
        }

        let configuration = JSONRead.dictionary(document, "Config")
        let state = JSONRead.dictionary(document, "State")
        let name = JSONRead.string(document, "Name")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let target = DebugToolboxTarget(
            requestedReference: containerReference,
            id: id,
            name: name?.isEmpty == false ? name : nil,
            imageReference: JSONRead.string(configuration, "Image"),
            imageID: JSONRead.string(document, "Image"),
            state: JSONRead.string(state, "Status"),
            isRunning: JSONRead.bool(state, "Running"))

        return DebugToolboxPlan(
            readiness: readiness(),
            target: target,
            engineRequests: ["GET /containers/\(containerReference)/json"],
            nonActions: [
                "did not create or start a toolbox container",
                "did not start, stop, pause, restart, or exec in the target container",
                "did not pull an image or contact a registry",
                "did not attach a terminal",
            ])
    }

    /// Docker's valid container names and IDs have no path separators, whitespace,
    /// or HTTP delimiters. Validate the reference before interpolating it into an
    /// Engine API path rather than relying on a generic client to infer a component.
    private static func isDockerContainerReference(_ reference: String) -> Bool {
        guard !reference.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_.-"))
        return reference.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
