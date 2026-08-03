// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Foundation

/// The sealed, source-bearing declaration that a future machine image acquirer
/// must admit before it opens a network connection or creates a private file.
///
/// ``MachineImageManifest`` deliberately remains an M0 inventory declaration: it
/// identifies the boot contract but has no source locations, signer identity, or
/// storage authority. This complementary manifest supplies those *requirements*
/// without implementing acquisition. It neither reads a manifest from disk nor
/// creates a staging directory, downloads a byte, validates a signature, clones a
/// disk, or constructs a virtual machine.
///
/// A syntactically valid acquisition manifest is not a bootable image. The only
/// successful assessment from this file is still ``MachineImageAdmissionAssessment/unavailable(_:reason:)``
/// because M1 has no downloader, verifier, private store, seed builder, or machine
/// supervisor yet.
public struct MachineImageAcquisitionManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumDocumentBytes = 128 * 1_024

    public let schemaVersion: Int
    /// The immutable M0 boot/provisioning declaration this policy admits.
    public let imageManifest: MachineImageManifest
    /// One direct, digest-pinned source for each required boot artifact. v1 does
    /// not accept archives which fan out into multiple roles: that would make the
    /// future byte-verification and recovery contract ambiguous.
    public let artifactSources: [MachineImageArtifactSource]
    /// The publisher and Sigstore identity policy which the future verifier must
    /// prove against its own trusted verifier implementation.
    public let provenancePolicy: MachineImageProvenancePolicy

    public init(
        schemaVersion: Int = MachineImageAcquisitionManifest.currentSchemaVersion,
        imageManifest: MachineImageManifest,
        artifactSources: [MachineImageArtifactSource],
        provenancePolicy: MachineImageProvenancePolicy
    ) {
        self.schemaVersion = schemaVersion
        self.imageManifest = imageManifest
        self.artifactSources = artifactSources
        self.provenancePolicy = provenancePolicy
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case imageManifest = "image_manifest"
        case artifactSources = "artifact_sources"
        case provenancePolicy = "provenance_policy"
    }

    /// A content address for the complete source and verifier policy, distinct from
    /// the immutable boot-image identity. A later policy update therefore cannot
    /// accidentally reuse a verification receipt written for a different signer or
    /// source declaration.
    public var admissionDigest: MachineSHA256Digest {
        var data = Data("morbstack-machine-image-admission-v1\\0".utf8)
        Self.appendLengthPrefixed(imageManifest.imageDigest.rawValue, to: &data)
        for source in artifactSources.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
            Self.appendLengthPrefixed(source.role.rawValue, to: &data)
            Self.appendLengthPrefixed(source.sourceURL, to: &data)
            Self.appendLengthPrefixed(String(source.expectedByteCount), to: &data)
            Self.appendLengthPrefixed(source.sha256.rawValue, to: &data)
        }
        for field in [
            provenancePolicy.publisherURL,
            provenancePolicy.publisherRelease,
            provenancePolicy.verificationMethod.rawValue,
            provenancePolicy.issuerURL,
            provenancePolicy.signerIdentity,
            provenancePolicy.bundleURL,
            provenancePolicy.bundleDigest.rawValue,
            provenancePolicy.validThrough,
        ] {
            Self.appendLengthPrefixed(field, to: &data)
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return MachineSHA256Digest("sha256:\(hex)")
    }

    /// Validates self-consistency only. This does not establish that any source is
    /// reachable, that bytes exist locally, that the source still serves those bytes,
    /// or that the declared Sigstore policy verifies.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MachineImageAdmissionError.unsupportedSchema
        }
        try imageManifest.validate()
        try provenancePolicy.validate()
        guard imageManifest.provenance.verification.method == .sigstore,
              imageManifest.provenance.verification.result == .verified,
              imageManifest.provenance.publisherURL == provenancePolicy.publisherURL,
              imageManifest.provenance.publisherRelease == provenancePolicy.publisherRelease,
              imageManifest.provenance.verificationMaterialDigest == provenancePolicy.bundleDigest,
              imageManifest.validThrough == provenancePolicy.validThrough
        else {
            throw MachineImageAdmissionError.policyDoesNotMatchImageManifest
        }
        guard artifactSources.count == MachineImageArtifact.Role.allCases.count else {
            throw MachineImageAdmissionError.incompleteArtifactSources
        }
        let declaredRoles = Set(artifactSources.map(\.role))
        guard declaredRoles.count == artifactSources.count,
              declaredRoles == Set(MachineImageArtifact.Role.allCases),
              Set(artifactSources.map(\.sourceURL)).count == artifactSources.count
        else {
            throw MachineImageAdmissionError.incompleteArtifactSources
        }
        let manifestArtifacts = Dictionary(uniqueKeysWithValues: imageManifest.artifacts.map { ($0.role, $0) })
        for source in artifactSources {
            try source.validate()
            guard manifestArtifacts[source.role]?.sha256 == source.sha256 else {
                throw MachineImageAdmissionError.artifactDigestDoesNotMatchImageManifest
            }
        }
    }

    /// Decodes one sealed acquisition declaration after rejecting unknown keys at
    /// every level. This method only processes supplied bytes; callers choose how a
    /// future signed app release obtains those bytes.
    public static func decode(_ data: Data) throws -> MachineImageAcquisitionManifest {
        guard data.count <= maximumDocumentBytes else {
            throw MachineImageAdmissionError.oversizedDocument
        }
        do {
            try MachineImageAdmissionJSONSchema.validate(data)
            let manifest = try JSONDecoder().decode(MachineImageAcquisitionManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as MachineImageAdmissionError {
            throw error
        } catch {
            throw MachineImageAdmissionError.malformedDocument
        }
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let valueData = Data(value.utf8)
        data.append(Data("\(valueData.count):".utf8))
        data.append(valueData)
    }
}

/// A single direct artifact source. Its digest and length make a future partial or
/// substituted download distinguishable from the curated declaration before it can
/// enter the immutable base store.
public struct MachineImageArtifactSource: Codable, Equatable, Sendable {
    public static let maximumArtifactBytes: UInt64 = 1 << 40 // 1 TiB hard safety cap.

    public let role: MachineImageArtifact.Role
    /// A credential-free, immutable HTTPS location. The policy binds the expected
    /// bytes; this URL is never treated as a mutable release label.
    public let sourceURL: String
    public let expectedByteCount: UInt64
    public let sha256: MachineSHA256Digest

    public init(
        role: MachineImageArtifact.Role,
        sourceURL: String,
        expectedByteCount: UInt64,
        sha256: MachineSHA256Digest
    ) {
        self.role = role
        self.sourceURL = sourceURL
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case role
        case sourceURL = "source_url"
        case expectedByteCount = "expected_byte_count"
        case sha256
    }

    public func validate() throws {
        guard MachineImageAdmissionValidation.isStrictHTTPSURL(sourceURL),
              (1...Self.maximumArtifactBytes).contains(expectedByteCount)
        else {
            throw MachineImageAdmissionError.invalidArtifactSource
        }
        try sha256.validate()
    }
}

/// Exact verifier policy for a curated image. It is intentionally much narrower
/// than M0's descriptive provenance declaration: M1 needs one explicit verifier
/// family and identity rather than a string that merely sounds attributable.
public struct MachineImageProvenancePolicy: Codable, Equatable, Sendable {
    public enum VerificationMethod: String, Codable, Equatable, Sendable {
        case sigstore
    }

    public let publisherURL: String
    public let publisherRelease: String
    public let verificationMethod: VerificationMethod
    public let issuerURL: String
    public let signerIdentity: String
    public let bundleURL: String
    public let bundleDigest: MachineSHA256Digest
    /// This must exactly equal ``MachineImageManifest/validThrough`` so an old
    /// signer policy cannot be paired with a current-looking boot declaration.
    public let validThrough: String

    public init(
        publisherURL: String,
        publisherRelease: String,
        verificationMethod: VerificationMethod = .sigstore,
        issuerURL: String,
        signerIdentity: String,
        bundleURL: String,
        bundleDigest: MachineSHA256Digest,
        validThrough: String
    ) {
        self.publisherURL = publisherURL
        self.publisherRelease = publisherRelease
        self.verificationMethod = verificationMethod
        self.issuerURL = issuerURL
        self.signerIdentity = signerIdentity
        self.bundleURL = bundleURL
        self.bundleDigest = bundleDigest
        self.validThrough = validThrough
    }

    enum CodingKeys: String, CodingKey {
        case publisherURL = "publisher_url"
        case publisherRelease = "publisher_release"
        case verificationMethod = "verification_method"
        case issuerURL = "issuer_url"
        case signerIdentity = "signer_identity"
        case bundleURL = "bundle_url"
        case bundleDigest = "bundle_digest"
        case validThrough = "valid_through"
    }

    public var expiryDate: Date? { MachineImageAdmissionValidation.date(from: validThrough) }

    public func validate() throws {
        guard MachineImageAdmissionValidation.isStrictHTTPSURL(publisherURL),
              MachineImageAdmissionValidation.isStrictHTTPSURL(issuerURL),
              MachineImageAdmissionValidation.isStrictHTTPSURL(bundleURL),
              verificationMethod == .sigstore,
              MachineImageAdmissionValidation.isSafePolicyText(publisherRelease),
              MachineImageAdmissionValidation.isSafePolicyText(signerIdentity),
              validThrough.hasSuffix("Z"), expiryDate != nil
        else {
            throw MachineImageAdmissionError.invalidProvenancePolicy
        }
        try bundleDigest.validate()
    }
}

/// The architecture fact a future supervisor must obtain from the actual host, not
/// from an image label or the Docker guest. No implicit process-architecture probe
/// is provided here: translated processes can report the wrong architecture for a
/// Virtualization.framework admission decision.
public enum MachineHostArchitecture: String, Codable, Equatable, Sendable {
    case arm64
    case amd64
    case unavailable
}

/// The only truthful results before M1. A valid declaration is deliberately still
/// unavailable, which keeps a caller from accidentally wiring it to a Create button
/// or treating a planned directory layout as a local base image.
public enum MachineImageAdmissionAssessment: Equatable, Sendable {
    case rejected(MachineImageAdmissionError)
    case unavailable(MachineImageAdmissionPlan, reason: MachineImageAdmissionUnavailableReason)

    public var status: String {
        switch self {
        case .rejected: return "rejected"
        case .unavailable: return "unavailable"
        }
    }
}

public enum MachineImageAdmissionUnavailableReason: String, Equatable, Sendable {
    case policyExpired = "policy_expired"
    case hostArchitectureUnavailable = "host_architecture_unavailable"
    case hostArchitectureDoesNotMatchImage = "host_architecture_does_not_match_image"
    case acquisitionAndVerificationNotImplemented = "acquisition_and_verification_not_implemented"

    public var detail: String {
        switch self {
        case .policyExpired:
            return "The machine image provenance policy is expired; it cannot be acquired or used for a new machine."
        case .hostArchitectureUnavailable:
            return "The host architecture has not been established, so a machine image cannot be admitted."
        case .hostArchitectureDoesNotMatchImage:
            return "The declared machine image architecture does not match this host."
        case .acquisitionAndVerificationNotImplemented:
            return "The machine image declaration is structurally valid, but Morbstack has not acquired or verified its boot artifacts and cannot create a machine."
        }
    }
}

/// An immutable, no-I/O handoff for the future acquisition transaction. Its paths
/// are a private *plan*, not evidence that those files or directories exist.
public struct MachineImageAdmissionPlan: Equatable, Sendable {
    public let imageDigest: MachineSHA256Digest
    public let admissionDigest: MachineSHA256Digest
    public let platform: MachinePlatform
    public let artifactSources: [MachineImageArtifactSource]
    public let storageLayout: MachineImageStorageLayout

    public init(manifest: MachineImageAcquisitionManifest, storageLayout: MachineImageStorageLayout) {
        imageDigest = manifest.imageManifest.imageDigest
        admissionDigest = manifest.admissionDigest
        platform = manifest.imageManifest.platform
        artifactSources = manifest.artifactSources.sorted { $0.role.rawValue < $1.role.rawValue }
        self.storageLayout = storageLayout
    }
}

/// Computes the private image-store names that M1 may later create under a registry
/// lock. It intentionally performs no filesystem inspection or mutation; an M1
/// executor must additionally reject symlinks, verify owner-only permissions, and
/// open/create each component safely before relying on this lexical plan.
public struct MachineImageStorageLayout: Equatable, Sendable {
    public static let directoryPOSIXPermissions = 0o700
    public static let filePOSIXPermissions = 0o600

    public let machinesRoot: URL
    public let imagesRoot: URL
    public let stagingRoot: URL
    public let imageDirectory: URL
    public let stagingDirectory: URL
    public let immutableManifestURL: URL
    public let provenanceReceiptURL: URL
    public let stagedArtifactURLs: [MachineImageArtifact.Role: URL]
    public let verifiedArtifactURLs: [MachineImageArtifact.Role: URL]

    public init(
        dataDirectory: URL = MorbPaths.dataDirectory,
        imageDigest: MachineSHA256Digest,
        admissionDigest: MachineSHA256Digest
    ) throws {
        try imageDigest.validate()
        try admissionDigest.validate()
        let dataRoot = dataDirectory.standardizedFileURL
        guard dataRoot.isFileURL,
              dataRoot.path.hasPrefix("/"),
              dataRoot.path != "/",
              !dataRoot.path.contains("/../")
        else {
            throw MachineImageAdmissionError.invalidStorageRoot
        }
        let imageComponent = Self.pathComponent(for: imageDigest)
        let admissionComponent = Self.pathComponent(for: admissionDigest)
        machinesRoot = dataRoot.appendingPathComponent("machines", isDirectory: true)
        imagesRoot = machinesRoot.appendingPathComponent("images", isDirectory: true)
        stagingRoot = machinesRoot.appendingPathComponent("staging", isDirectory: true)
        imageDirectory = imagesRoot.appendingPathComponent(imageComponent, isDirectory: true)
        stagingDirectory = stagingRoot
            .appendingPathComponent(imageComponent, isDirectory: true)
            .appendingPathComponent(admissionComponent, isDirectory: true)
        immutableManifestURL = imageDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        provenanceReceiptURL = imageDirectory
            .appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent("\(admissionComponent).json", isDirectory: false)

        var staged: [MachineImageArtifact.Role: URL] = [:]
        var verified: [MachineImageArtifact.Role: URL] = [:]
        for role in MachineImageArtifact.Role.allCases {
            let fileName = Self.fileName(for: role)
            staged[role] = stagingDirectory
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false)
            verified[role] = imageDirectory
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false)
        }
        stagedArtifactURLs = staged
        verifiedArtifactURLs = verified
    }

    private static func pathComponent(for digest: MachineSHA256Digest) -> String {
        digest.rawValue.replacingOccurrences(of: ":", with: "-")
    }

    private static func fileName(for role: MachineImageArtifact.Role) -> String {
        switch role {
        case .kernel: return "kernel"
        case .initramfs: return "initramfs"
        case .rootDisk: return "root-disk.raw"
        case .guestAgent: return "guest-agent"
        case .seedImageInput: return "seed-image-input"
        }
    }
}

/// Pure assessment boundary for a future explicitly initiated M1 acquisition.
/// It has no ready/attachable case by design.
public enum MachineImageAdmission {
    public static func assess(
        manifest: MachineImageAcquisitionManifest,
        hostArchitecture: MachineHostArchitecture,
        dataDirectory: URL = MorbPaths.dataDirectory,
        now: Date = Date()
    ) -> MachineImageAdmissionAssessment {
        do {
            try manifest.validate()
            let storageLayout = try MachineImageStorageLayout(
                dataDirectory: dataDirectory,
                imageDigest: manifest.imageManifest.imageDigest,
                admissionDigest: manifest.admissionDigest)
            let plan = MachineImageAdmissionPlan(manifest: manifest, storageLayout: storageLayout)
            guard let expiry = manifest.provenancePolicy.expiryDate, expiry > now else {
                return .unavailable(plan, reason: .policyExpired)
            }
            switch hostArchitecture {
            case .unavailable:
                return .unavailable(plan, reason: .hostArchitectureUnavailable)
            case .arm64, .amd64:
                guard manifest.imageManifest.platform.architecture == hostArchitecture.rawValue else {
                    return .unavailable(plan, reason: .hostArchitectureDoesNotMatchImage)
                }
            }
            return .unavailable(plan, reason: .acquisitionAndVerificationNotImplemented)
        } catch let error as MachineImageAdmissionError {
            return .rejected(error)
        } catch {
            return .rejected(.invalidAcquisitionManifest)
        }
    }
}

/// Errors intentionally do not echo untrusted URLs, paths, or policy text into a
/// terminal or future app surface.
public enum MachineImageAdmissionError: Error, CustomStringConvertible, Equatable, Sendable {
    case unsupportedSchema
    case invalidAcquisitionManifest
    case incompleteArtifactSources
    case invalidArtifactSource
    case artifactDigestDoesNotMatchImageManifest
    case invalidProvenancePolicy
    case policyDoesNotMatchImageManifest
    case oversizedDocument
    case malformedDocument
    case unknownDocumentField
    case invalidStorageRoot

    public var description: String {
        switch self {
        case .unsupportedSchema: return "unsupported machine image acquisition manifest schema"
        case .invalidAcquisitionManifest: return "machine image acquisition manifest is invalid"
        case .incompleteArtifactSources: return "machine image acquisition manifest does not declare one direct source for every required artifact"
        case .invalidArtifactSource: return "machine image acquisition manifest contains an invalid artifact source"
        case .artifactDigestDoesNotMatchImageManifest: return "machine image acquisition artifact digest does not match the immutable image manifest"
        case .invalidProvenancePolicy: return "machine image acquisition manifest has an invalid provenance policy"
        case .policyDoesNotMatchImageManifest: return "machine image provenance policy does not match the immutable image manifest"
        case .oversizedDocument: return "machine image acquisition manifest exceeds the 128 KiB safety limit"
        case .malformedDocument: return "machine image acquisition manifest is malformed"
        case .unknownDocumentField: return "machine image acquisition manifest contains an unsupported field"
        case .invalidStorageRoot: return "machine image storage root is unsafe"
        }
    }
}

private enum MachineImageAdmissionValidation {
    private static let internetDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        internetDate.date(from: value) ?? fractionalDate.date(from: value)
    }

    static func isSafePolicyText(_ value: String) -> Bool {
        guard (1...512).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }

    /// v1 deliberately admits a conservative URL grammar. No credentials, query,
    /// fragment, percent-encoding, non-default port, or control/bidirectional text
    /// can enter a progress view, log, or future process argument.
    static func isStrictHTTPSURL(_ value: String) -> Bool {
        guard (1...1_024).contains(value.utf8.count),
              value.utf8.allSatisfy(Self.isSafeURLByte),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil,
              components.path.hasPrefix("/"),
              components.url?.absoluteString == value
        else {
            return false
        }
        return true
    }

    private static func isSafeURLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E, 0x2F, 0x3A:
            return true
        default:
            return false
        }
    }
}

/// Strict shape validation for the source-bearing declaration. Codable normally
/// ignores unfamiliar keys, which would permit an unreviewed credential or a second
/// source to hide beside a document this boundary calls sealed.
private enum MachineImageAdmissionJSONSchema {
    static func validate(_ data: Data) throws {
        let root = try rootObject(data)
        let object = try object(root, keys: [
            "schema_version", "image_manifest", "artifact_sources", "provenance_policy",
        ])
        try imageManifest(object["image_manifest"])
        try array(object["artifact_sources"]).forEach(artifactSource)
        try provenancePolicy(object["provenance_policy"])
    }

    private static func rootObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MachineImageAdmissionError.malformedDocument
        }
    }

    private static func imageManifest(_ value: Any?) throws {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw MachineImageAdmissionError.malformedDocument
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            _ = try MachineImageManifest.decode(data)
        } catch {
            throw MachineImageAdmissionError.invalidAcquisitionManifest
        }
    }

    private static func artifactSource(_ value: Any) throws {
        _ = try object(value, keys: ["role", "source_url", "expected_byte_count", "sha256"])
    }

    private static func provenancePolicy(_ value: Any?) throws {
        _ = try object(value, keys: [
            "publisher_url", "publisher_release", "verification_method", "issuer_url", "signer_identity",
            "bundle_url", "bundle_digest", "valid_through",
        ])
    }

    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let value, let object = value as? [String: Any] else {
            throw MachineImageAdmissionError.malformedDocument
        }
        guard Set(object.keys) == keys else {
            throw MachineImageAdmissionError.unknownDocumentField
        }
        return object
    }

    private static func object(_ value: Any?, keys: [String]) throws -> [String: Any] {
        try object(value, keys: Set(keys))
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let value, let array = value as? [Any] else {
            throw MachineImageAdmissionError.malformedDocument
        }
        return array
    }
}
