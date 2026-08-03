// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Foundation

/// M0's declarative inventory for future isolated Linux machines.
///
/// This file deliberately does *not* create a disk, download an image, inspect a
/// local artifact, construct a virtual machine, or expose a command. It gives the
/// future M1 supervisor one strict, content-addressed source of truth without
/// pretending that an inventory entry is bootable today.
///
/// The model has no field for cloud-init, passwords, private keys, terminal
/// transcripts, Docker credentials, or security-scoped bookmark bytes. Unknown
/// JSON fields are rejected by ``MachineRegistry/decode(_:)`` rather than silently
/// preserved beside this secret-free schema.
public enum MachineRegistryModelError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchema
    case invalidDigest
    case invalidIdentifier
    case invalidPlatform
    case invalidManifest
    case manifestIdentityMismatch
    case invalidProvenance
    case invalidExpiry
    case invalidTimestamp
    case invalidMachineRecord
    case duplicateImageDigest
    case duplicateMachineID
    case unknownBaseImage
    case platformDoesNotMatchImage
    case malformedDocument
    case unknownDocumentField

    public var description: String {
        switch self {
        case .unsupportedSchema: return "unsupported machine registry schema"
        case .invalidDigest: return "machine registry contains an invalid SHA-256 digest"
        case .invalidIdentifier: return "machine registry contains an unsafe identifier"
        case .invalidPlatform: return "machine registry contains an unsupported machine platform"
        case .invalidManifest: return "machine image manifest is incomplete or inconsistent"
        case .manifestIdentityMismatch: return "machine image manifest identity does not match its declared content"
        case .invalidProvenance: return "machine image manifest has an invalid provenance declaration"
        case .invalidExpiry: return "machine image manifest has an invalid expiry"
        case .invalidTimestamp: return "machine registry contains an invalid UTC timestamp"
        case .invalidMachineRecord: return "machine registry contains an invalid machine record"
        case .duplicateImageDigest: return "machine registry contains a duplicate image digest"
        case .duplicateMachineID: return "machine registry contains a duplicate machine identifier"
        case .unknownBaseImage: return "machine record refers to an image absent from the local registry"
        case .platformDoesNotMatchImage: return "machine record platform does not match its base image"
        case .malformedDocument: return "machine registry document is malformed"
        case .unknownDocumentField: return "machine registry document contains an unsupported field"
        }
    }
}

/// A lower-case, `sha256:<hex>` content identifier.
///
/// The prefix is carried in the stored value so a future multi-algorithm migration
/// cannot accidentally compare a bare SHA-256 digest with a different algorithm.
public struct MachineSHA256Digest: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    /// This initializer is useful when decoding fixture or external manifest input;
    /// call ``validate()`` before trusting it. ``init(validating:)`` is preferred by
    /// code constructing a new model.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        self.rawValue = rawValue
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func validate() throws {
        let components = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "sha256",
              components[1].utf8.count == 64,
              components[1].utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
              })
        else {
            throw MachineRegistryModelError.invalidDigest
        }
    }

    fileprivate static func hash(_ data: Data) -> MachineSHA256Digest {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return MachineSHA256Digest("sha256:\(hex)")
    }
}

/// An architecture-specific Linux platform. Virtualization.framework machines do
/// not emulate another CPU architecture, so a registry entry must never erase it.
public struct MachinePlatform: Codable, Equatable, Hashable, Sendable {
    public let os: String
    public let architecture: String

    public init(os: String, architecture: String) {
        self.os = os
        self.architecture = architecture
    }

    enum CodingKeys: String, CodingKey {
        case os
        case architecture
    }

    public var identifier: String { "\(os)/\(architecture)" }

    public func validate() throws {
        guard os == "linux", architecture == "arm64" || architecture == "amd64" else {
            throw MachineRegistryModelError.invalidPlatform
        }
    }
}

/// One immutable artifact declared by a curated machine image. M0 records digests
/// only; it intentionally has no local filename because M0 cannot claim a payload
/// has been acquired or made attachable.
public struct MachineImageArtifact: Codable, Equatable, Sendable {
    public enum Role: String, Codable, CaseIterable, Hashable, Sendable {
        case kernel
        case initramfs
        case rootDisk = "root_disk"
        case guestAgent = "guest_agent"
        case seedImageInput = "seed_image_input"
    }

    public let role: Role
    public let sha256: MachineSHA256Digest

    public init(role: Role, sha256: MachineSHA256Digest) {
        self.role = role
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case role
        case sha256
    }

    public func validate() throws {
        try sha256.validate()
    }
}

/// The guest family and bootstrap compatibility declared by a curated image.
public struct MachineImageDistribution: Codable, Equatable, Sendable {
    public let family: String
    public let release: String
    public let cloudInitVersion: String

    public init(family: String, release: String, cloudInitVersion: String) {
        self.family = family
        self.release = release
        self.cloudInitVersion = cloudInitVersion
    }

    enum CodingKeys: String, CodingKey {
        case family
        case release
        case cloudInitVersion = "cloud_init_version"
    }

    public func validate() throws {
        guard MachineRegistryValidation.isSafeIdentifier(family),
              MachineRegistryValidation.isSafeIdentifier(release),
              MachineRegistryValidation.isSafeIdentifier(cloudInitVersion)
        else {
            throw MachineRegistryModelError.invalidManifest
        }
    }
}

/// A separately-versioned control contract for a non-Docker machine guest.
public struct MachineGuestAgent: Codable, Equatable, Sendable {
    public let identifier: String
    public let protocolVersion: Int

    public init(identifier: String, protocolVersion: Int) {
        self.identifier = identifier
        self.protocolVersion = protocolVersion
    }

    enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case protocolVersion = "protocol_version"
    }

    public func validate() throws {
        guard MachineRegistryValidation.isSafeIdentifier(identifier),
              (1...65_535).contains(protocolVersion)
        else {
            throw MachineRegistryModelError.invalidManifest
        }
    }
}

/// Required guest properties. These are declarations to be verified by M1; they
/// never make an M0 image attachable.
public struct MachineGuestRequirements: Codable, Equatable, Sendable {
    public enum CloudInitDatasource: String, Codable, Sendable {
        case noCloud = "nocloud"
    }

    public let cloudInitDatasource: CloudInitDatasource
    public let supportsSSH: Bool
    public let supportsVirtioFS: Bool

    public init(cloudInitDatasource: CloudInitDatasource, supportsSSH: Bool, supportsVirtioFS: Bool) {
        self.cloudInitDatasource = cloudInitDatasource
        self.supportsSSH = supportsSSH
        self.supportsVirtioFS = supportsVirtioFS
    }

    enum CodingKeys: String, CodingKey {
        case cloudInitDatasource = "cloud_init_datasource"
        case supportsSSH = "ssh"
        case supportsVirtioFS = "virtiofs"
    }

    public func validate() throws {
        guard cloudInitDatasource == .noCloud, supportsSSH, supportsVirtioFS else {
            throw MachineRegistryModelError.invalidManifest
        }
    }
}

/// Declared publisher verification evidence. The declaration is intentionally not
/// proof: M0 has no downloader or verifier, and even `.verified` stays unavailable
/// until M1 verifies acquired artifact bytes and the machine-agent handshake.
public struct MachineImageProvenance: Codable, Equatable, Sendable {
    public enum VerificationMethod: String, Codable, Sendable {
        case publisherMetadata = "publisher_metadata"
        case detachedSignature = "detached_signature"
        case sigstore
    }

    public enum VerificationResult: String, Codable, Sendable {
        case unverified
        case verified
    }

    public struct Verification: Codable, Equatable, Sendable {
        public let method: VerificationMethod
        public let result: VerificationResult

        public init(method: VerificationMethod, result: VerificationResult) {
            self.method = method
            self.result = result
        }
    }

    /// An immutable HTTPS URL supplied by the upstream publisher.
    public let publisherURL: String
    public let publisherRelease: String
    public let verification: Verification
    /// SHA-256 of the detached publisher metadata or verification material.
    public let verificationMaterialDigest: MachineSHA256Digest

    public init(
        publisherURL: String,
        publisherRelease: String,
        verification: Verification,
        verificationMaterialDigest: MachineSHA256Digest
    ) {
        self.publisherURL = publisherURL
        self.publisherRelease = publisherRelease
        self.verification = verification
        self.verificationMaterialDigest = verificationMaterialDigest
    }

    enum CodingKeys: String, CodingKey {
        case publisherURL = "publisher_url"
        case publisherRelease = "publisher_release"
        case verification = "verification"
        case verificationMaterialDigest = "verification_material_digest"
    }

    public func validate() throws {
        guard MachineRegistryValidation.isHTTPSURL(publisherURL),
              MachineRegistryValidation.isSafePolicyText(publisherRelease)
        else {
            throw MachineRegistryModelError.invalidProvenance
        }
        try verificationMaterialDigest.validate()
    }
}

/// A curated, immutable machine-image declaration.
///
/// ``imageDigest`` is calculated from every immutable declaration below with the
/// specified v1 length-prefixed encoding. It is therefore a content address for the
/// full boot/provisioning contract rather than a mutable release label or merely the
/// root-disk digest.
public struct MachineImageManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Stable, product-owned label. Machine records never use this as an identity.
    public let imageID: String
    /// The immutable local-registry key for this exact declaration.
    public let imageDigest: MachineSHA256Digest
    public let platform: MachinePlatform
    public let distribution: MachineImageDistribution
    public let guestAgent: MachineGuestAgent
    public let requirements: MachineGuestRequirements
    public let artifacts: [MachineImageArtifact]
    public let provenance: MachineImageProvenance
    /// UTC ISO-8601 expiry for the image's provenance declaration.
    public let validThrough: String

    /// Supplying `nil` produces the content address for this declaration. Passing a
    /// non-nil digest is useful when decoding an external declaration: ``validate()``
    /// rejects it unless it exactly matches ``computedImageDigest``.
    public init(
        schemaVersion: Int = MachineImageManifest.currentSchemaVersion,
        imageID: String,
        imageDigest: MachineSHA256Digest? = nil,
        platform: MachinePlatform,
        distribution: MachineImageDistribution,
        guestAgent: MachineGuestAgent,
        requirements: MachineGuestRequirements,
        artifacts: [MachineImageArtifact],
        provenance: MachineImageProvenance,
        validThrough: String
    ) {
        self.schemaVersion = schemaVersion
        self.imageID = imageID
        self.platform = platform
        self.distribution = distribution
        self.guestAgent = guestAgent
        self.requirements = requirements
        self.artifacts = artifacts
        self.provenance = provenance
        self.validThrough = validThrough
        self.imageDigest = imageDigest ?? Self.calculateImageDigest(
            schemaVersion: schemaVersion,
            imageID: imageID,
            platform: platform,
            distribution: distribution,
            guestAgent: guestAgent,
            requirements: requirements,
            artifacts: artifacts,
            provenance: provenance,
            validThrough: validThrough)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case imageID = "image_id"
        case imageDigest = "image_digest"
        case platform
        case distribution
        case guestAgent = "guest_agent"
        case requirements
        case artifacts
        case provenance
        case validThrough = "valid_through"
    }

    public var expiryDate: Date? { MachineRegistryValidation.date(from: validThrough) }

    public var computedImageDigest: MachineSHA256Digest {
        Self.calculateImageDigest(
            schemaVersion: schemaVersion,
            imageID: imageID,
            platform: platform,
            distribution: distribution,
            guestAgent: guestAgent,
            requirements: requirements,
            artifacts: artifacts,
            provenance: provenance,
            validThrough: validThrough)
    }

    /// Validates schema, content address, platform declaration, artifact roles, and
    /// provenance shape. It does not read a kernel, initramfs, root disk, seed input,
    /// agent package, network resource, or signature bundle.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MachineRegistryModelError.unsupportedSchema
        }
        guard MachineRegistryValidation.isSafeIdentifier(imageID) else {
            throw MachineRegistryModelError.invalidIdentifier
        }
        try imageDigest.validate()
        try platform.validate()
        try distribution.validate()
        try guestAgent.validate()
        try requirements.validate()
        try provenance.validate()
        guard validThrough.hasSuffix("Z"), expiryDate != nil else {
            throw MachineRegistryModelError.invalidExpiry
        }
        guard artifacts.count == MachineImageArtifact.Role.allCases.count else {
            throw MachineRegistryModelError.invalidManifest
        }
        let roles = Set(artifacts.map(\.role))
        guard roles.count == artifacts.count, roles == Set(MachineImageArtifact.Role.allCases) else {
            throw MachineRegistryModelError.invalidManifest
        }
        try artifacts.forEach { try $0.validate() }
        guard imageDigest == computedImageDigest else {
            throw MachineRegistryModelError.manifestIdentityMismatch
        }
    }

    /// M0 is a declaration and registry schema only. A syntactically valid, current
    /// manifest remains unavailable until M1 supplies verified bytes, a NoCloud seed
    /// builder, and the separately-versioned guest agent.
    public func runtimeAvailability(at now: Date = Date()) -> MachineRuntimeAvailability {
        if let expiryDate, expiryDate <= now {
            return .unavailable(.manifestExpired)
        }
        if provenance.verification.result != .verified {
            return .unavailable(.provenanceNotVerified)
        }
        return .unavailable(.m1ArtifactsAndAgentUnavailable)
    }

    /// Decodes one standalone manifest after rejecting unknown fields. M0 accepts
    /// declarations only; it does not retrieve or inspect their referenced bytes.
    public static func decode(_ data: Data) throws -> MachineImageManifest {
        do {
            try MachineRegistryJSONSchema.validateManifest(data)
            let manifest = try JSONDecoder().decode(MachineImageManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as MachineRegistryModelError {
            throw error
        } catch {
            throw MachineRegistryModelError.malformedDocument
        }
    }

    private static func calculateImageDigest(
        schemaVersion: Int,
        imageID: String,
        platform: MachinePlatform,
        distribution: MachineImageDistribution,
        guestAgent: MachineGuestAgent,
        requirements: MachineGuestRequirements,
        artifacts: [MachineImageArtifact],
        provenance: MachineImageProvenance,
        validThrough: String
    ) -> MachineSHA256Digest {
        var bytes = Data("morbstack-machine-image-manifest-v1\\0".utf8)
        // Do not use `Dictionary(uniqueKeysWithValues:)`: a malformed external
        // manifest with duplicate roles must become a validation error, never a
        // process trap while its provisional identity is being calculated.
        var artifactByRole: [MachineImageArtifact.Role: MachineImageArtifact] = [:]
        for artifact in artifacts where artifactByRole[artifact.role] == nil {
            artifactByRole[artifact.role] = artifact
        }
        let fields = [
            String(schemaVersion),
            imageID,
            platform.os,
            platform.architecture,
            distribution.family,
            distribution.release,
            distribution.cloudInitVersion,
            guestAgent.identifier,
            String(guestAgent.protocolVersion),
            requirements.cloudInitDatasource.rawValue,
            requirements.supportsSSH ? "true" : "false",
            requirements.supportsVirtioFS ? "true" : "false",
        ]
        for field in fields { appendLengthPrefixed(field, to: &bytes) }
        for role in MachineImageArtifact.Role.allCases {
            appendLengthPrefixed(role.rawValue, to: &bytes)
            appendLengthPrefixed(artifactByRole[role]?.sha256.rawValue ?? "", to: &bytes)
        }
        for field in [
            provenance.publisherURL,
            provenance.publisherRelease,
            provenance.verification.method.rawValue,
            provenance.verification.result.rawValue,
            provenance.verificationMaterialDigest.rawValue,
            validThrough,
        ] {
            appendLengthPrefixed(field, to: &bytes)
        }
        return MachineSHA256Digest.hash(bytes)
    }

    /// Each UTF-8 field is encoded as its decimal byte length, a colon, then bytes.
    /// The fixed field order above makes the preimage unambiguous and independent of
    /// JSON key formatting or artifact array order.
    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let valueData = Data(value.utf8)
        data.append(Data("\(valueData.count):".utf8))
        data.append(valueData)
    }
}

/// The feature never reports an M0 record as launchable. This typed result gives a
/// future native unavailable-state implementation truthful, stable copy without
/// inventing a machine lifecycle API today.
public enum MachineRuntimeAvailability: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case noCuratedManifest = "no_curated_manifest"
        case manifestExpired = "manifest_expired"
        case provenanceNotVerified = "provenance_not_verified"
        case m1ArtifactsAndAgentUnavailable = "m1_artifacts_and_agent_unavailable"

        public var detail: String {
            switch self {
            case .noCuratedManifest:
                return "No curated machine image manifest is registered."
            case .manifestExpired:
                return "The machine image provenance declaration is expired."
            case .provenanceNotVerified:
                return "The machine image provenance declaration is not verified."
            case .m1ArtifactsAndAgentUnavailable:
                return "Machines are unavailable until M1 provides verified boot artifacts, NoCloud provisioning, and the machine guest agent."
            }
        }
    }

    case unavailable(Reason)

    public var isAvailable: Bool { false }

    public var detail: String {
        switch self {
        case .unavailable(let reason): return reason.detail
        }
    }
}

/// Declarative CPU and memory values. M0 validates only stable representational
/// bounds; M1 must validate an exact VZ configuration against the current Mac.
public struct MachineHardwareProfile: Codable, Equatable, Sendable {
    public let cpuCount: Int
    public let memoryMiB: Int

    public init(cpuCount: Int, memoryMiB: Int) {
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
    }

    enum CodingKeys: String, CodingKey {
        case cpuCount = "cpu_count"
        case memoryMiB = "memory_mib"
    }

    public func validate() throws {
        guard (1...256).contains(cpuCount), (256...8_388_608).contains(memoryMiB) else {
            throw MachineRegistryModelError.invalidMachineRecord
        }
    }
}

/// Network intent only. No M0 record causes a VZ network device to be created.
public enum MachineNetworkMode: String, Codable, Sendable {
    case isolated
    case nat
}

/// A future scoped VirtioFS intent. This carries no bookmark and grants no access;
/// M3 must separately validate and acquire user-selected filesystem access.
public struct MachineShareDescriptor: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable {
        case readOnly = "read_only"
        case readWrite = "read_write"
    }

    public let id: UUID
    public let hostPath: String
    public let guestMountPath: String
    public let access: Access

    public init(id: UUID, hostPath: String, guestMountPath: String, access: Access) {
        self.id = id
        self.hostPath = hostPath
        self.guestMountPath = guestMountPath
        self.access = access
    }

    enum CodingKeys: String, CodingKey {
        case id
        case hostPath = "host_path"
        case guestMountPath = "guest_mount_path"
        case access
    }

    public func validate() throws {
        guard MachineRegistryValidation.isSafeAbsolutePath(hostPath),
              MachineRegistryValidation.isSafeGuestMountPath(guestMountPath)
        else {
            throw MachineRegistryModelError.invalidMachineRecord
        }
    }
}

/// M0 accepts only a stopped intent. This is not a lifecycle request: it prevents a
/// persisted registry document from implying a running machine before M1 exists.
public enum MachineDesiredPowerState: String, Codable, Sendable {
    case stopped
}

/// Desired, non-secret configuration for one future independent machine.
public struct MachineDesiredRecord: Codable, Equatable, Sendable {
    public let baseImageDigest: MachineSHA256Digest
    public let platform: MachinePlatform
    public let hardware: MachineHardwareProfile
    public let networkMode: MachineNetworkMode
    public let shares: [MachineShareDescriptor]
    public let powerState: MachineDesiredPowerState

    public init(
        baseImageDigest: MachineSHA256Digest,
        platform: MachinePlatform,
        hardware: MachineHardwareProfile,
        networkMode: MachineNetworkMode,
        shares: [MachineShareDescriptor] = [],
        powerState: MachineDesiredPowerState = .stopped
    ) {
        self.baseImageDigest = baseImageDigest
        self.platform = platform
        self.hardware = hardware
        self.networkMode = networkMode
        self.shares = shares
        self.powerState = powerState
    }

    enum CodingKeys: String, CodingKey {
        case baseImageDigest = "base_image_digest"
        case platform
        case hardware
        case networkMode = "network_mode"
        case shares
        case powerState = "desired_power_state"
    }

    public func validate() throws {
        try baseImageDigest.validate()
        try platform.validate()
        try hardware.validate()
        guard shares.count <= 32 else { throw MachineRegistryModelError.invalidMachineRecord }
        let ids = Set(shares.map(\.id))
        guard ids.count == shares.count else { throw MachineRegistryModelError.invalidMachineRecord }
        try shares.forEach { try $0.validate() }
    }
}

/// M0 has no guest probe, so the only truthful observation is unavailable.
public enum MachineObservedState: String, Codable, Sendable {
    case unavailable
}

/// Observed state intentionally omits console output, cloud-init text, and guest
/// credentials. M1 will add only explicitly reviewed, redacted observation data.
public struct MachineObservedRecord: Codable, Equatable, Sendable {
    public let state: MachineObservedState
    public let observedAt: String

    public init(state: MachineObservedState = .unavailable, observedAt: String) {
        self.state = state
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey {
        case state
        case observedAt = "observed_at"
    }

    public func validate() throws {
        guard MachineRegistryValidation.isUTCISO8601(observedAt) else {
            throw MachineRegistryModelError.invalidTimestamp
        }
    }
}

/// One secret-free desired/observed record. The opaque UUID, not the display name,
/// is the future on-disk directory key and VM ownership identity.
public struct MachineRegistryRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let createdAt: String
    public let updatedAt: String
    public let desired: MachineDesiredRecord
    public let observed: MachineObservedRecord

    public init(
        id: UUID,
        displayName: String,
        createdAt: String,
        updatedAt: String,
        desired: MachineDesiredRecord,
        observed: MachineObservedRecord
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.desired = desired
        self.observed = observed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case desired
        case observed
    }

    public func validate() throws {
        guard MachineRegistryValidation.isSafeDisplayName(displayName),
              MachineRegistryValidation.isUTCISO8601(createdAt),
              MachineRegistryValidation.isUTCISO8601(updatedAt),
              let created = MachineRegistryValidation.date(from: createdAt),
              let updated = MachineRegistryValidation.date(from: updatedAt),
              updated >= created
        else {
            throw MachineRegistryModelError.invalidMachineRecord
        }
        try desired.validate()
        try observed.validate()
    }
}

/// The complete local registry document. It is content-addressed by manifest digest:
/// a machine record points to `base_image_digest`, never a tag, release label, path,
/// or Docker image name.
public struct MachineRegistry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let images: [MachineImageManifest]
    public let machines: [MachineRegistryRecord]

    public init(
        schemaVersion: Int = MachineRegistry.currentSchemaVersion,
        images: [MachineImageManifest] = [],
        machines: [MachineRegistryRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.images = images
        self.machines = machines
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case images
        case machines
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MachineRegistryModelError.unsupportedSchema
        }
        guard images.count <= 128, machines.count <= 2_048 else {
            throw MachineRegistryModelError.invalidManifest
        }
        try images.forEach { try $0.validate() }
        let digests = Set(images.map(\.imageDigest))
        guard digests.count == images.count else {
            throw MachineRegistryModelError.duplicateImageDigest
        }
        let machineIDs = Set(machines.map(\.id))
        guard machineIDs.count == machines.count else {
            throw MachineRegistryModelError.duplicateMachineID
        }
        for machine in machines {
            try machine.validate()
            guard let image = images.first(where: { $0.imageDigest == machine.desired.baseImageDigest }) else {
                throw MachineRegistryModelError.unknownBaseImage
            }
            guard image.platform == machine.desired.platform else {
                throw MachineRegistryModelError.platformDoesNotMatchImage
            }
        }
    }

    /// M0 has no image acquisition, VM supervisor, seed builder, or guest agent.
    /// This answer remains unavailable even when the registry is valid and current.
    public func runtimeAvailability(at now: Date = Date()) -> MachineRuntimeAvailability {
        guard !images.isEmpty else { return .unavailable(.noCuratedManifest) }
        for image in images {
            switch image.runtimeAvailability(at: now) {
            case .unavailable(.manifestExpired): return .unavailable(.manifestExpired)
            case .unavailable(.provenanceNotVerified): return .unavailable(.provenanceNotVerified)
            case .unavailable(.noCuratedManifest), .unavailable(.m1ArtifactsAndAgentUnavailable): continue
            }
        }
        return .unavailable(.m1ArtifactsAndAgentUnavailable)
    }

    /// Decodes a registry only after rejecting unknown fields throughout its schema.
    /// That prevents raw seed data or credentials from becoming a tolerated sidecar
    /// in a document this model calls secret-free.
    public static func decode(_ data: Data) throws -> MachineRegistry {
        do {
            try MachineRegistryJSONSchema.validate(data)
            let registry = try JSONDecoder().decode(MachineRegistry.self, from: data)
            try registry.validate()
            return registry
        } catch let error as MachineRegistryModelError {
            throw error
        } catch {
            throw MachineRegistryModelError.malformedDocument
        }
    }

    /// Encodes only this explicit schema after validation. It does not write to disk.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

private enum MachineRegistryValidation {
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

    static func isUTCISO8601(_ value: String) -> Bool {
        value.hasSuffix("Z") && date(from: value) != nil
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
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

    static func isSafePolicyText(_ value: String) -> Bool {
        guard (1...512).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isHTTPSURL(_ value: String) -> Bool {
        guard value.utf8.count <= 1_024,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else {
            return false
        }
        return true
    }

    static func isSafeDisplayName(_ value: String) -> Bool {
        guard (1...120).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar.value != 0x2F
        }
    }

    static func isSafeAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains(where: { $0 == "." || $0 == ".." })
    }

    static func isSafeGuestMountPath(_ value: String) -> Bool {
        guard isSafeAbsolutePath(value), value.hasPrefix("/mnt/morbstack/") else { return false }
        return value != "/mnt/morbstack/"
    }
}

/// Strict shape validation for persisted documents. Codable's default behavior
/// ignores unfamiliar keys, which is inappropriate for a record that promises not
/// to contain raw cloud-init or credential data.
private enum MachineRegistryJSONSchema {
    static func validateManifest(_ data: Data) throws {
        let object = try rootObject(data)
        try image(object)
    }

    static func validate(_ data: Data) throws {
        let object = try rootObject(data)
        try registry(object)
    }

    private static func rootObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MachineRegistryModelError.malformedDocument
        }
    }

    private static func registry(_ value: Any) throws {
        let object = try object(value, keys: ["schema_version", "images", "machines"])
        try array(object["images"]).forEach(image)
        try array(object["machines"]).forEach(machine)
    }

    private static func image(_ value: Any) throws {
        let object = try object(value, keys: [
            "schema_version", "image_id", "image_digest", "platform", "distribution", "guest_agent",
            "requirements", "artifacts", "provenance", "valid_through",
        ])
        try platform(object["platform"])
        try distribution(object["distribution"])
        try guestAgent(object["guest_agent"])
        try requirements(object["requirements"])
        try array(object["artifacts"]).forEach(artifact)
        try provenance(object["provenance"])
    }

    private static func platform(_ value: Any?) throws {
        _ = try object(value, keys: ["os", "architecture"])
    }

    private static func distribution(_ value: Any?) throws {
        _ = try object(value, keys: ["family", "release", "cloud_init_version"])
    }

    private static func guestAgent(_ value: Any?) throws {
        _ = try object(value, keys: ["id", "protocol_version"])
    }

    private static func requirements(_ value: Any?) throws {
        _ = try object(value, keys: ["cloud_init_datasource", "ssh", "virtiofs"])
    }

    private static func artifact(_ value: Any) throws {
        _ = try object(value, keys: ["role", "sha256"])
    }

    private static func provenance(_ value: Any?) throws {
        let object = try object(value, keys: [
            "publisher_url", "publisher_release", "verification", "verification_material_digest",
        ])
        _ = try self.object(object["verification"], keys: ["method", "result"])
    }

    private static func machine(_ value: Any) throws {
        let object = try object(value, keys: ["id", "display_name", "created_at", "updated_at", "desired", "observed"])
        try desired(object["desired"])
        try observed(object["observed"])
    }

    private static func desired(_ value: Any?) throws {
        let object = try object(value, keys: [
            "base_image_digest", "platform", "hardware", "network_mode", "shares", "desired_power_state",
        ])
        try platform(object["platform"])
        try hardware(object["hardware"])
        try array(object["shares"]).forEach(share)
    }

    private static func hardware(_ value: Any?) throws {
        _ = try object(value, keys: ["cpu_count", "memory_mib"])
    }

    private static func share(_ value: Any) throws {
        _ = try object(value, keys: ["id", "host_path", "guest_mount_path", "access"])
    }

    private static func observed(_ value: Any?) throws {
        _ = try object(value, keys: ["state", "observed_at"])
    }

    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let value, let object = value as? [String: Any] else {
            throw MachineRegistryModelError.malformedDocument
        }
        guard Set(object.keys) == keys else {
            throw MachineRegistryModelError.unknownDocumentField
        }
        return object
    }

    private static func object(_ value: Any?, keys: [String]) throws -> [String: Any] {
        try object(value, keys: Set(keys))
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let value, let array = value as? [Any] else {
            throw MachineRegistryModelError.malformedDocument
        }
        return array
    }
}
