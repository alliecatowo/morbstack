// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Declarative provenance and compatibility evidence for a future debug toolbox.
//
// This file intentionally does not inspect Docker images, retrieve attestations, run
// a verifier, create a directory, or contact a network. A local JSON descriptor can
// explain *what* a future verifier must prove, but it cannot by itself prove that the
// descriptor, image bytes, or signature bundle are trustworthy. Keeping that boundary
// explicit prevents a planning command from accidentally becoming an executor gate.

import Foundation
import MorbstackKit

/// Schema for the one immutable toolbox asset a future executor may consider.
///
/// The image reference and digest are redundant on purpose: an accidental tag-only
/// reference, or a digest that does not agree with its reference, is an immediate
/// configuration error rather than an ambiguous update instruction. The provenance
/// fields describe the required Sigstore verification material; validating their shape
/// does not verify a signature bundle.
public struct DebugToolboxAssetManifest: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1
    public static let maximumManifestBytes = 64 * 1_024
    public static let requiredPlatform = Platform(os: "linux", architecture: "arm64")

    public struct Platform: Codable, Equatable, Hashable, Sendable {
        public let os: String
        public let architecture: String

        public init(os: String, architecture: String) {
            self.os = os
            self.architecture = architecture
        }

        public var identifier: String { "\(os)/\(architecture)" }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        /// The verifier family the future acquisition flow must use. v1 accepts only
        /// `sigstore`; accepting an arbitrary string would make a manifest look
        /// cryptographically attributable without saying how to establish that fact.
        public let method: String
        /// HTTPS OIDC issuer expected by the signer policy.
        public let issuer: String
        /// Exact signer identity expected by the policy (for example, a repository
        /// workflow identity). It is an identifier, never a credential.
        public let identity: String
        /// SHA-256 of the detached Sigstore bundle the future verifier must read.
        public let bundleDigest: String

        public init(method: String, issuer: String, identity: String, bundleDigest: String) {
            self.method = method
            self.issuer = issuer
            self.identity = identity
            self.bundleDigest = bundleDigest
        }

        enum CodingKeys: String, CodingKey {
            case method
            case issuer
            case identity
            case bundleDigest = "bundle_digest"
        }
    }

    public let schemaVersion: Int
    /// A stable product-owned identifier, not a mutable registry tag.
    public let assetID: String
    /// Fully digest-pinned OCI image reference, e.g. `ghcr.io/org/toolbox@sha256:…`.
    public let imageReference: String
    /// The same `sha256:<hex>` digest embedded in `imageReference`.
    public let imageDigest: String
    /// Platforms declared by the immutable image/index. A v1 toolbox must include the
    /// native Morbstack guest platform (`linux/arm64`) rather than silently depend on
    /// optional emulation to make an emergency diagnostic shell work.
    public let platforms: [Platform]
    public let provenance: Provenance
    /// UTC ISO-8601 expiry for the signed provenance policy. A future acquisition
    /// policy decides refresh/rollback; this read-only layer only refuses to call an
    /// expired descriptor current.
    public let validThrough: String

    public init(
        schemaVersion: Int,
        assetID: String,
        imageReference: String,
        imageDigest: String,
        platforms: [Platform],
        provenance: Provenance,
        validThrough: String
    ) {
        self.schemaVersion = schemaVersion
        self.assetID = assetID
        self.imageReference = imageReference
        self.imageDigest = imageDigest
        self.platforms = platforms
        self.provenance = provenance
        self.validThrough = validThrough
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case assetID = "asset_id"
        case imageReference = "image_reference"
        case imageDigest = "image_digest"
        case platforms
        case provenance
        case validThrough = "valid_through"
    }

    /// Validates the descriptor's self-consistency and the compatibility declaration.
    /// No image, signature, certificate, or network resource is opened here.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DebugToolboxAssetError.unsupportedSchema
        }
        guard Self.isSafeIdentifier(assetID) else {
            throw DebugToolboxAssetError.invalidAssetID
        }
        guard Self.isPinnedDigest(imageDigest) else {
            throw DebugToolboxAssetError.invalidImageDigest
        }
        guard Self.isPinnedImageReference(imageReference, digest: imageDigest) else {
            throw DebugToolboxAssetError.imageReferenceDoesNotMatchDigest
        }
        guard !platforms.isEmpty, platforms.count <= 8 else {
            throw DebugToolboxAssetError.invalidPlatforms
        }
        guard Set(platforms).count == platforms.count,
              platforms.allSatisfy(Self.isSupportedPlatform),
              platforms.contains(Self.requiredPlatform)
        else {
            throw DebugToolboxAssetError.invalidPlatforms
        }
        guard provenance.method == "sigstore",
              Self.isHTTPSURL(provenance.issuer),
              Self.isSafePolicyString(provenance.identity),
              Self.isPinnedDigest(provenance.bundleDigest)
        else {
            throw DebugToolboxAssetError.invalidProvenance
        }
        guard validThrough.hasSuffix("Z"), Self.iso8601.date(from: validThrough) != nil else {
            throw DebugToolboxAssetError.invalidExpiry
        }
    }

    public var expiryDate: Date? { Self.iso8601.date(from: validThrough) }

    private static let iso8601 = ISO8601DateFormatter()

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F:
                return true
            default:
                return false
            }
        }
    }

    private static func isSafePolicyString(_ value: String) -> Bool {
        guard (1...512).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { !$0.properties.isControl && $0 != "\n" && $0 != "\r" }
    }

    private static func isPinnedDigest(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "sha256", parts[1].utf8.count == 64 else { return false }
        return parts[1].utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func isPinnedImageReference(_ value: String, digest: String) -> Bool {
        guard value.utf8.count <= 1_024,
              value.utf8.allSatisfy(Self.isSafeOCIReferenceByte),
              let at = value.lastIndex(of: "@"), at != value.startIndex
        else { return false }
        let referenceDigest = String(value[value.index(after: at)...])
        let repository = value[..<at]
        return referenceDigest == digest &&
            !repository.isEmpty &&
            !repository.contains("@") &&
            repository.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// This is deliberately narrower than the OCI distribution grammar. The manifest
    /// is diagnostic input that can appear in a terminal, so v1 accepts only the ASCII
    /// bytes needed for familiar registry/repository/tag syntax and rejects all
    /// controls, bidirectional marks, and terminal escape sequences before output.
    private static func isSafeOCIReferenceByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2D, 0x2E, 0x2F, 0x3A, 0x40, 0x5F:
            return true
        default:
            return false
        }
    }

    private static func isSupportedPlatform(_ platform: Platform) -> Bool {
        guard platform.os == "linux" else { return false }
        return platform.architecture == "arm64" || platform.architecture == "amd64"
    }

    private static func isHTTPSURL(_ raw: String) -> Bool {
        guard raw.utf8.count <= 1_024,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return false }
        return true
    }
}

/// Validation failures deliberately have short, non-echoing messages. A manifest is
/// untrusted local input and the diagnostic must not reflect arbitrary control text to
/// a terminal or future GUI.
public enum DebugToolboxAssetError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchema
    case invalidAssetID
    case invalidImageDigest
    case imageReferenceDoesNotMatchDigest
    case invalidPlatforms
    case invalidProvenance
    case invalidExpiry
    case oversizedManifest
    case unreadableManifest
    case malformedManifest

    public var description: String {
        switch self {
        case .unsupportedSchema: return "unsupported toolbox asset manifest schema"
        case .invalidAssetID: return "toolbox asset manifest has an unsafe asset identifier"
        case .invalidImageDigest: return "toolbox asset manifest has an invalid immutable image digest"
        case .imageReferenceDoesNotMatchDigest:
            return "toolbox image reference is not pinned to its declared digest"
        case .invalidPlatforms:
            return "toolbox asset manifest does not declare a supported linux/arm64 platform"
        case .invalidProvenance: return "toolbox asset manifest has an invalid Sigstore provenance policy"
        case .invalidExpiry: return "toolbox asset manifest has an invalid policy expiry"
        case .oversizedManifest: return "toolbox asset manifest exceeds the 64 KiB safety limit"
        case .unreadableManifest: return "toolbox asset manifest could not be read"
        case .malformedManifest: return "toolbox asset manifest is not valid JSON for this schema"
        }
    }
}

/// What an offline diagnostic can truthfully establish about a manifest candidate.
///
/// Even `.declaredButUnverified` remains unavailable: it establishes only that a local
/// descriptor says the right kinds of things. It does not prove any image exists in the
/// engine, that its config/index digest matches, or that a Sigstore bundle verifies.
public enum DebugToolboxAssetAssessment: Equatable, Sendable {
    case absent(path: String)
    case invalid(path: String, reason: String)
    case expired(path: String, manifest: DebugToolboxAssetManifest)
    case declaredButUnverified(path: String, manifest: DebugToolboxAssetManifest)

    public var path: String {
        switch self {
        case .absent(let path), .invalid(let path, _), .expired(let path, _), .declaredButUnverified(let path, _):
            return path
        }
    }

    public var status: String {
        switch self {
        case .absent: return "absent"
        case .invalid: return "invalid"
        case .expired: return "expired"
        case .declaredButUnverified: return "declared-but-unverified"
        }
    }

    public var detail: String {
        switch self {
        case .absent:
            return "No toolbox asset manifest is configured; no local image or provenance was inspected."
        case .invalid(_, let reason): return reason
        case .expired:
            return "The descriptor's provenance policy is expired; acquisition and rollback policy are not implemented."
        case .declaredButUnverified:
            return "Descriptor syntax is valid, but the local image digest and Sigstore bundle have not been verified."
        }
    }

    public var manifest: DebugToolboxAssetManifest? {
        switch self {
        case .expired(_, let manifest), .declaredButUnverified(_, let manifest): return manifest
        case .absent, .invalid: return nil
        }
    }
}

/// Reads and validates only a local descriptor. This is the asset half of the debug
/// readiness gate, deliberately separate from Docker inspection and future execution.
public enum DebugToolboxAsset {

    public static func assess(
        manifestURL: URL = MorbPaths.debugToolboxManifest,
        now: Date = Date()
    ) -> DebugToolboxAssetAssessment {
        let path = manifestURL.standardizedFileURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .absent(path: path) }
        do {
            // Read at most one byte beyond the limit. A separate `stat` followed by
            // `Data(contentsOf:)` leaves a time-of-check/time-of-use window where a
            // local untrusted file can grow before this offline diagnostic reads it.
            let handle = try FileHandle(forReadingFrom: manifestURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: DebugToolboxAssetManifest.maximumManifestBytes + 1) ?? Data()
            guard data.count <= DebugToolboxAssetManifest.maximumManifestBytes else {
                return .invalid(path: path, reason: DebugToolboxAssetError.oversizedManifest.description)
            }
            let manifest: DebugToolboxAssetManifest
            do {
                manifest = try JSONDecoder().decode(DebugToolboxAssetManifest.self, from: data)
            } catch {
                return .invalid(path: path, reason: DebugToolboxAssetError.malformedManifest.description)
            }
            do {
                try manifest.validate()
            } catch let error as DebugToolboxAssetError {
                return .invalid(path: path, reason: error.description)
            } catch {
                return .invalid(path: path, reason: DebugToolboxAssetError.malformedManifest.description)
            }
            guard let expiry = manifest.expiryDate else {
                return .invalid(path: path, reason: DebugToolboxAssetError.invalidExpiry.description)
            }
            if expiry <= now { return .expired(path: path, manifest: manifest) }
            return .declaredButUnverified(path: path, manifest: manifest)
        } catch {
            return .invalid(path: path, reason: DebugToolboxAssetError.unreadableManifest.description)
        }
    }
}
