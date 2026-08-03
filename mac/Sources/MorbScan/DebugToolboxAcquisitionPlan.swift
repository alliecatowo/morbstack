// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// A declarative transaction contract for a future debug-toolbox acquisition.
//
// This file has no filesystem, Docker, process, registry, or verifier access.
// It gives callers one exact answer to "what would have to happen next?" while
// preserving the fact that no current debug-toolbox asset is executable.

import Foundation

/// The next safe disposition for a descriptor observed by the read-only checker.
/// None of these dispositions authorizes a network request, image import, or
/// activation. A future acquisition controller must receive a fresh, explicit
/// consent for one chosen source before it can begin any of these steps.
public enum DebugToolboxAcquisitionDisposition: String, Sendable, Equatable {
    case acquireCandidate = "acquire_candidate"
    case replaceInvalidDeclaration = "replace_invalid_declaration"
    case replaceExpiredDeclaration = "replace_expired_declaration"
    case verifyDeclaredCandidate = "verify_declared_candidate"

    public var description: String {
        switch self {
        case .acquireCandidate:
            return "obtain a candidate only after the user selects and consents to a source"
        case .replaceInvalidDeclaration:
            return "discard the untrusted declaration from consideration and obtain a new candidate after consent"
        case .replaceExpiredDeclaration:
            return "obtain a candidate under a current provenance policy after consent"
        case .verifyDeclaredCandidate:
            return "verify the declared candidate's local bytes and provenance before it can be considered"
        }
    }
}

/// A stable, ordered transaction stage for a future toolbox acquisition.
///
/// The stages deliberately separate source transport from verification. A successful
/// pull, import, or copy never establishes that bytes are the selected immutable
/// image, nor that the signer policy permits their use.
public enum DebugToolboxAcquisitionStage: String, CaseIterable, Sendable, Equatable {
    case discloseAndObtainConsent = "disclose_and_obtain_consent"
    case stageCandidatePrivately = "stage_candidate_privately"
    case verifyPinnedImageBytes = "verify_pinned_image_bytes"
    case verifyPlatformAndProvenance = "verify_platform_and_provenance"
    case writeVerificationReceipt = "write_verification_receipt"
    case atomicallyActivateCandidate = "atomically_activate_candidate"
    case retainRollbackCandidate = "retain_rollback_candidate"

    public var description: String {
        switch self {
        case .discloseAndObtainConsent:
            return "disclose the selected source, registry/network effects, exact digest, retention, and update policy; obtain fresh explicit consent"
        case .stageCandidatePrivately:
            return "place candidate bytes and verification material in a private staging location without changing the active toolbox"
        case .verifyPinnedImageBytes:
            return "prove the staged local image/index resolves to the manifest's exact digest"
        case .verifyPlatformAndProvenance:
            return "prove linux/arm64 compatibility and verify the declared Sigstore bundle, issuer, signer identity, and policy expiry"
        case .writeVerificationReceipt:
            return "record the verified digest, platform, policy expiry, verifier version, and acquisition source in a private receipt"
        case .atomicallyActivateCandidate:
            return "publish the receipt and candidate together only after all verification succeeds"
        case .retainRollbackCandidate:
            return "retain the previously active, still-valid verified asset until the replacement is known usable"
        }
    }
}

/// Failure and rollback invariants for a future acquisition transaction.
/// This is intentionally a contract, not a cleanup implementation: there is no
/// active asset manager in the current release to mutate or roll back.
public struct DebugToolboxRollbackContract: Sendable, Equatable {
    public let guarantees: [String]
    public let prohibitedFallbacks: [String]

    public init(guarantees: [String], prohibitedFallbacks: [String]) {
        self.guarantees = guarantees
        self.prohibitedFallbacks = prohibitedFallbacks
    }
}

/// A non-executing preview of the acquisition, activation, and rollback work that
/// remains after a local descriptor check. It always remains unavailable: the
/// preview does not inspect image bytes or verify a signature bundle.
public struct DebugToolboxAcquisitionPlan: Sendable, Equatable {
    public let available: Bool
    public let disposition: DebugToolboxAcquisitionDisposition
    public let networkAccess: String
    public let engineAccess: String
    public let stages: [DebugToolboxAcquisitionStage]
    public let rollback: DebugToolboxRollbackContract
    public let nonActions: [String]

    public init(
        available: Bool,
        disposition: DebugToolboxAcquisitionDisposition,
        networkAccess: String,
        engineAccess: String,
        stages: [DebugToolboxAcquisitionStage],
        rollback: DebugToolboxRollbackContract,
        nonActions: [String]
    ) {
        self.available = available
        self.disposition = disposition
        self.networkAccess = networkAccess
        self.engineAccess = engineAccess
        self.stages = stages
        self.rollback = rollback
        self.nonActions = nonActions
    }

    /// Builds a static contract from a local descriptor assessment. This performs no
    /// I/O beyond the assessment the caller has already made, and intentionally
    /// cannot return an available plan.
    public static func preview(
        assessment: DebugToolboxAssetAssessment
    ) -> DebugToolboxAcquisitionPlan {
        let disposition: DebugToolboxAcquisitionDisposition
        switch assessment {
        case .absent:
            disposition = .acquireCandidate
        case .invalid:
            disposition = .replaceInvalidDeclaration
        case .expired:
            disposition = .replaceExpiredDeclaration
        case .declaredButUnverified:
            disposition = .verifyDeclaredCandidate
        }

        return DebugToolboxAcquisitionPlan(
            available: false,
            disposition: disposition,
            networkAccess: "not requested",
            engineAccess: "not contacted",
            stages: DebugToolboxAcquisitionStage.allCases,
            rollback: DebugToolboxRollbackContract(
                guarantees: [
                    "The active toolbox remains unchanged until a staged candidate has passed byte, platform, and provenance verification.",
                    "An interrupted or failed transaction removes only its staged candidate and records the cleanup result.",
                    "Activation publishes the candidate and its verification receipt atomically with the prior verified asset retained for rollback.",
                    "A requested rollback re-verifies the retained asset's policy expiry and receipt before activation.",
                ],
                prohibitedFallbacks: [
                    "Never activate an expired, unsigned, tag-only, or merely declared asset as a fallback.",
                    "Never replace or delete the prior verified asset before the replacement is completely verified.",
                    "Never treat a completed pull, import, copy, or receipt write as an interactive toolbox session.",
                ]),
            nonActions: [
                "did not request network consent or contact a registry",
                "did not pull, import, inspect, tag, remove, or activate an image",
                "did not write a receipt, transaction journal, or rollback state",
                "did not create a toolbox container or alter a target container",
            ])
    }
}
