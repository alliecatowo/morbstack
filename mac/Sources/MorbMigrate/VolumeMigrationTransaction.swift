// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A selected, additive named-volume transfer. This is intentionally not a general
// volume synchronizer: it copies only source `local` volumes that a fresh read-only
// plan found absent from Morbstack. Existing destination contents are never read,
// merged, replaced, or deleted by this transaction.

import Foundation
import MorbFeatures

/// How a caller selects local named volumes from a fresh eligibility plan.
public enum VolumeMigrationSelection: Sendable, Equatable {
    case names([String])
    case allEligible
}

/// One prepared, selected named-volume transfer. Preparation reads inventories only;
/// execution additionally requires a matching confirmation capability.
public struct PreparedVolumeMigration: Sendable, Equatable, Codable {
    public let transactionID: UUID
    public let preparedAt: String
    public let source: MigrationPlanEndpoint
    public let destination: MigrationPlanEndpoint
    public let items: [MigrationVolumePlanItem]
    public let selectionDescription: String
    /// `true` only when the preparation-time inventory found no usable helper image
    /// on at least one engine. A caller must obtain ``networkConsent()`` after an
    /// explicit disclosure before execution may pull `alpine:3.20` there.
    public let helperImageNetworkConsentRequired: Bool
    public let sourceHasHelperImage: Bool
    public let destinationHasHelperImage: Bool
    public let safetyLimits: [String]

    public init(
        transactionID: UUID,
        preparedAt: String,
        source: MigrationPlanEndpoint,
        destination: MigrationPlanEndpoint,
        items: [MigrationVolumePlanItem],
        selectionDescription: String,
        helperImageNetworkConsentRequired: Bool,
        sourceHasHelperImage: Bool,
        destinationHasHelperImage: Bool,
        safetyLimits: [String]
    ) {
        self.transactionID = transactionID
        self.preparedAt = preparedAt
        self.source = source
        self.destination = destination
        self.items = items
        self.selectionDescription = selectionDescription
        self.helperImageNetworkConsentRequired = helperImageNetworkConsentRequired
        self.sourceHasHelperImage = sourceHasHelperImage
        self.destinationHasHelperImage = destinationHasHelperImage
        self.safetyLimits = safetyLimits
    }

    /// The capability a UI creates after its review sheet or a CLI creates after its
    /// terminal confirmation. It is bound to exactly this prepared selection.
    public func confirmation() -> VolumeMigrationConfirmation {
        VolumeMigrationConfirmation(transactionID: transactionID)
    }

    /// The separate capability required before execution may pull a missing helper
    /// image. Calling this does not pull anything; callers must only call it after a
    /// clear network disclosure for the source and Morbstack destinations.
    public func networkConsent() -> VolumeMigrationNetworkConsent {
        VolumeMigrationNetworkConsent(transactionID: transactionID)
    }
}

/// Proof that the caller completed its explicit selected-volume confirmation.
public struct VolumeMigrationConfirmation: Sendable, Equatable {
    fileprivate let transactionID: UUID
}

/// Proof that the caller separately approved a helper-image pull if one is needed.
public struct VolumeMigrationNetworkConsent: Sendable, Equatable {
    fileprivate let transactionID: UUID
}

/// Structured transfer progress for a selected named volume. Byte totals are actual
/// archive bytes; Docker does not provide a reliable total before the source archive
/// is read, so callers must not derive a percentage from this value.
public enum VolumeMigrationProgressPhase: String, Sendable, Equatable, Codable {
    case prepared
    case checkingPreconditions = "checking_preconditions"
    case pullingHelperImage = "pulling_helper_image"
    case exporting
    case creatingDestination = "creating_destination"
    case importing
    case completedVolume = "completed_volume"
    case writingReport = "writing_report"
    case completed
}

public struct VolumeMigrationProgress: Sendable, Equatable, Codable {
    public let transactionID: UUID
    public let phase: VolumeMigrationProgressPhase
    public let completedVolumeCount: Int
    public let totalVolumeCount: Int
    public let volumeName: String?
    public let bytesTransferred: Int64?
    public let detail: String?

    public init(
        transactionID: UUID,
        phase: VolumeMigrationProgressPhase,
        completedVolumeCount: Int,
        totalVolumeCount: Int,
        volumeName: String?,
        bytesTransferred: Int64?,
        detail: String?
    ) {
        self.transactionID = transactionID
        self.phase = phase
        self.completedVolumeCount = completedVolumeCount
        self.totalVolumeCount = totalVolumeCount
        self.volumeName = volumeName
        self.bytesTransferred = bytesTransferred
        self.detail = detail
    }
}

/// The known destination state after one archive-copy attempt. These are effects,
/// not an assertion about the volume's contents.
public enum VolumeMigrationDestinationState: String, Sendable, Equatable, Codable {
    case notCreated = "not_created"
    case created = "created"
    case archiveUploaded = "archive_uploaded"
    case requiresReview = "requires_review"
}

public enum VolumeMigrationItemOutcome: String, Sendable, Equatable, Codable {
    case copied
    case failed
    case requiresReview = "requires_review"
}

/// Durable evidence for one selected volume. `archiveUploaded` means Docker accepted
/// the archive upload; it is not an independent checksum or file-by-file verification.
public struct VolumeMigrationItemReport: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let driver: String
    public var archiveBytes: Int64
    /// Regular-file entries counted in the exported archive by walking its ustar
    /// headers on disk. `nil` when the transfer failed before a complete export (or
    /// for reports written before this field existed); `0` can also mean the archive
    /// did not parse as ustar — this is a progress-report fact, not a verification.
    public var archiveFileCount: Int?
    public var sourceHelperCreated: Bool
    public var destinationHelperCreated: Bool
    public var outcome: VolumeMigrationItemOutcome
    public var destinationState: VolumeMigrationDestinationState
    public var detail: String?

    public var id: String { name }

    public init(
        name: String,
        driver: String,
        archiveBytes: Int64,
        archiveFileCount: Int? = nil,
        sourceHelperCreated: Bool,
        destinationHelperCreated: Bool,
        outcome: VolumeMigrationItemOutcome,
        destinationState: VolumeMigrationDestinationState,
        detail: String?
    ) {
        self.name = name
        self.driver = driver
        self.archiveBytes = archiveBytes
        self.archiveFileCount = archiveFileCount
        self.sourceHelperCreated = sourceHelperCreated
        self.destinationHelperCreated = destinationHelperCreated
        self.outcome = outcome
        self.destinationState = destinationState
        self.detail = detail
    }
}

/// The durable report for one selected, additive named-volume transaction.
public struct VolumeMigrationTransactionReport: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let preparedAt: String
    public let startedAt: String
    public var completedAt: String?
    public let source: MigrationPlanEndpoint
    public let destination: MigrationPlanEndpoint
    public let scope: String
    public let helperImageNetworkConsentProvided: Bool
    public let safetyLimits: [String]
    public var items: [VolumeMigrationItemReport]
    public var reportPath: String?
    public var reportWriteError: String?
    public let rollbackGuidance: [String]

    public init(
        transactionID: UUID,
        preparedAt: String,
        startedAt: String,
        source: MigrationPlanEndpoint,
        destination: MigrationPlanEndpoint,
        helperImageNetworkConsentProvided: Bool
    ) {
        schemaVersion = 1
        self.transactionID = transactionID
        self.preparedAt = preparedAt
        self.startedAt = startedAt
        completedAt = nil
        self.source = source
        self.destination = destination
        scope = "selected_missing_local_named_volumes_only"
        self.helperImageNetworkConsentProvided = helperImageNetworkConsentProvided
        safetyLimits = VolumeMigrationTransaction.safetyLimits
        items = []
        reportPath = nil
        reportWriteError = nil
        rollbackGuidance = VolumeMigrationTransaction.rollbackGuidance
    }

    public var isFullyCopied: Bool {
        !items.isEmpty && items.allSatisfy { $0.outcome == .copied }
    }

    /// Writes an atomically replaced report under Morbstack-owned state. No volume
    /// contents, labels, credentials, paths, or helper container IDs enter the report.
    public func write() throws -> URL {
        let directory = MorbFeaturePaths.migrateDirectory
            .appendingPathComponent("volume-transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = startedAt.replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(
            "volumes-\(timestamp)-\(transactionID.uuidString.lowercased()).json", isDirectory: false)
        var persisted = self
        persisted.reportPath = url.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persisted).write(to: url, options: .atomic)
        return url
    }
}

public enum VolumeMigrationTransactionError: Error, CustomStringConvertible {
    case unavailable(String)
    case emptySelection
    case unknownNames([String])
    case ineligibleNames([String])
    case missingSourceSocket
    case confirmationDoesNotMatch
    case networkConsentDoesNotMatch
    case helperImageNetworkConsentRequired([String])
    case unsupportedLocalDriverOptions([String])

    public var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .emptySelection: return "the selected named-volume set is empty; select one eligible volume"
        case .unknownNames(let names): return "these volume names are not in the current plan: \(names.joined(separator: ", "))"
        case .ineligibleNames(let names): return "these volumes are not eligible for the additive transaction: \(names.joined(separator: ", "))"
        case .missingSourceSocket: return "the prepared source has no Docker socket path"
        case .confirmationDoesNotMatch: return "confirmation does not belong to this prepared volume migration"
        case .networkConsentDoesNotMatch: return "network consent does not belong to this prepared volume migration"
        case .helperImageNetworkConsentRequired(let labels):
            return "a helper image is unavailable on \(labels.joined(separator: " and ")); explicitly approve the alpine:3.20 pull before transfer"
        case .unsupportedLocalDriverOptions(let names):
            return "these local volumes have custom or unverifiable driver options: \(names.joined(separator: ", ")). The archive migration refuses to silently discard or replay mount/device options on Morbstack."
        }
    }
}

/// Executes an explicit, additive named-volume transfer through a fixed Docker Engine
/// API contract. It is the shared service for future native UI and the `morb migrate
/// volumes` adapter; it does not invoke a shell command or prompt on its own.
public enum VolumeMigrationTransaction {

    public static let safetyLimits = [
        "Only selected source volumes using Docker's local driver are considered.",
        "A selected local volume must report an empty driver-option map; archive migration never silently drops or replays local mount/device options.",
        "Morbstack must not already have a volume with the selected name; existing destination contents are never inspected, merged, or replaced.",
        "The source helper container is created stopped with a read-only volume mount and is removed best-effort after its archive read.",
        "Destination volumes are additive only. The transaction never deletes a volume or performs automatic rollback.",
        "A completed archive upload is not an independent content checksum or file-by-file verification.",
    ]

    public static let rollbackGuidance = [
        "The transaction never deletes source or destination volumes automatically.",
        "If an item requires review after destination creation, inspect that exact Morbstack volume before any manual cleanup.",
        "Do not infer that a failed upload left a newly created destination volume empty.",
    ]

    /// Derives a fresh GET-only plan, narrows it to an explicit eligible selection,
    /// and observes whether each engine already has a usable helper image. It never
    /// creates a helper container, pulls an image, creates a volume, or writes a report.
    public static func prepare(
        from sourceToken: String? = nil,
        selection: VolumeMigrationSelection
    ) throws -> PreparedVolumeMigration {
        let plan = MigrationReadOnlyPlanner.inspect(from: sourceToken)
        guard plan.source.readiness == .ready, plan.destination.readiness == .ready,
              let volumePlan = plan.volumePlan
        else {
            throw VolumeMigrationTransactionError.unavailable(
                plan.volumeUnavailableReason ?? plan.source.detail ?? plan.destination.detail
                    ?? "source and destination must both be ready before a volume migration can be prepared")
        }
        guard let sourceSocket = plan.source.socketPath else {
            throw VolumeMigrationTransactionError.missingSourceSocket
        }

        let sourceClient = EngineClient.forUnixSocket(sourceSocket)
        let selected = try selectedItems(selection, from: volumePlan)
        try verifyArchiveTransferVolumeSemantics(selected, on: sourceClient)
        let destinationClient = EngineClient()
        let sourceHasHelper: Bool
        let destinationHasHelper: Bool
        do {
            sourceHasHelper = try HelperImage.existingAny(on: sourceClient) != nil
        } catch {
            throw VolumeMigrationTransactionError.unavailable(
                "could not inspect helper-image availability on \(plan.source.name): \(error)")
        }
        do {
            destinationHasHelper = try HelperImage.existingAny(on: destinationClient) != nil
        } catch {
            throw VolumeMigrationTransactionError.unavailable(
                "could not inspect helper-image availability on Morbstack: \(error)")
        }

        return PreparedVolumeMigration(
            transactionID: UUID(),
            preparedAt: Format.timestamp(),
            source: plan.source,
            destination: plan.destination,
            items: selected,
            selectionDescription: selectionDescription(selection),
            helperImageNetworkConsentRequired: !sourceHasHelper || !destinationHasHelper,
            sourceHasHelperImage: sourceHasHelper,
            destinationHasHelperImage: destinationHasHelper,
            safetyLimits: safetyLimits)
    }

    /// Copies each prepared volume independently. Fresh preflight before every
    /// `POST /volumes/create` refuses a destination volume that appeared after
    /// preparation. A helper image can be pulled only when `networkConsent` is bound
    /// to this prepared transaction; otherwise no helper container or volume is made.
    public static func execute(
        _ prepared: PreparedVolumeMigration,
        confirmation: VolumeMigrationConfirmation,
        networkConsent: VolumeMigrationNetworkConsent? = nil,
        progress: @escaping (VolumeMigrationProgress) -> Void = { _ in }
    ) throws -> VolumeMigrationTransactionReport {
        guard confirmation.transactionID == prepared.transactionID else {
            throw VolumeMigrationTransactionError.confirmationDoesNotMatch
        }
        if let networkConsent, networkConsent.transactionID != prepared.transactionID {
            throw VolumeMigrationTransactionError.networkConsentDoesNotMatch
        }
        guard let sourceSocket = prepared.source.socketPath else {
            throw VolumeMigrationTransactionError.missingSourceSocket
        }

        let source = MigrationSource(
            label: prepared.source.name,
            client: EngineClient.forUnixSocket(sourceSocket),
            socketPath: sourceSocket)
        let destination = EngineClient()
        let allowsNetwork = networkConsent != nil
        let (sourceImage, destinationImage) = try resolveHelperImages(
            source: source, destination: destination, allowsNetwork: allowsNetwork,
            prepared: prepared, progress: progress)

        var report = VolumeMigrationTransactionReport(
            transactionID: prepared.transactionID,
            preparedAt: prepared.preparedAt,
            startedAt: Format.timestamp(),
            source: prepared.source,
            destination: prepared.destination,
            helperImageNetworkConsentProvided: allowsNetwork)
        emit(progress, prepared: prepared, phase: .prepared, completed: 0, volume: nil, bytes: nil,
             detail: "selected volumes confirmed")

        for (index, item) in prepared.items.enumerated() {
            let itemReport = transfer(
                item, itemIndex: index, prepared: prepared, source: source,
                sourceImage: sourceImage, destination: destination, destinationImage: destinationImage,
                progress: progress)
            report.items.append(itemReport)
            emit(progress, prepared: prepared, phase: .completedVolume, completed: index + 1,
                 volume: item.name, bytes: itemReport.archiveBytes, detail: itemReport.outcome.rawValue)
        }

        report.completedAt = Format.timestamp()
        emit(progress, prepared: prepared, phase: .writingReport, completed: report.items.count,
             volume: nil, bytes: nil, detail: nil)
        do {
            report.reportPath = try report.write().path
        } catch {
            report.reportWriteError = "could not write volume migration report: \(error)"
        }
        emit(progress, prepared: prepared, phase: .completed, completed: report.items.count,
             volume: nil, bytes: nil,
             detail: report.reportWriteError ?? (report.isFullyCopied ? "all selected archives uploaded" : "review report items"))
        return report
    }

    private static func selectedItems(
        _ selection: VolumeMigrationSelection,
        from plan: MigrationVolumePlan
    ) throws -> [MigrationVolumePlanItem] {
        switch selection {
        case .allEligible:
            guard !plan.eligible.isEmpty else { throw VolumeMigrationTransactionError.emptySelection }
            return plan.eligible
        case .names(let names):
            let normalized = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !normalized.isEmpty else { throw VolumeMigrationTransactionError.emptySelection }
            let requested = Set(normalized)
            let byName = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.name, $0) })
            let unknown = requested.filter { byName[$0] == nil }.sorted()
            if !unknown.isEmpty { throw VolumeMigrationTransactionError.unknownNames(unknown) }
            let ineligible = requested.filter { byName[$0]?.isEligible != true }.sorted()
            if !ineligible.isEmpty { throw VolumeMigrationTransactionError.ineligibleNames(ineligible) }
            let selected = plan.items.filter { requested.contains($0.name) && $0.isEligible }
            guard !selected.isEmpty else { throw VolumeMigrationTransactionError.emptySelection }
            return selected
        }
    }

    private static func selectionDescription(_ selection: VolumeMigrationSelection) -> String {
        switch selection {
        case .allEligible: return "all currently eligible missing local volumes"
        case .names: return "explicit volume names"
        }
    }

    /// Re-inspects exact selected source volumes before review. The initial list plan
    /// is necessarily a snapshot; allowing a `local` volume with `type`, `device`,
    /// `o`, or another option through would later create a plain default volume and
    /// silently change the storage contract the user asked to migrate.
    private static func verifyArchiveTransferVolumeSemantics(
        _ items: [MigrationVolumePlanItem],
        on client: EngineClient
    ) throws {
        var unsupported: [String] = []
        for item in items {
            let info: [String: Any]
            do {
                info = try client.jsonObject("GET", "/volumes/\(item.name)", timeout: 30)
            } catch {
                throw VolumeMigrationTransactionError.unavailable(
                    "could not recheck selected volume \(item.name): \(error)")
            }
            if !isOptionFreeLocalVolume(info) { unsupported.append(item.name) }
        }
        if !unsupported.isEmpty {
            throw VolumeMigrationTransactionError.unsupportedLocalDriverOptions(unsupported.sorted())
        }
    }

    /// `Options: null` is an Engine spelling for an option-free volume. A missing,
    /// malformed, non-string, or nonempty map is not assumed safe: the local driver
    /// can receive mount types, devices, and flags through this field.
    private static func isOptionFreeLocalVolume(_ volume: [String: Any]) -> Bool {
        guard JSONRead.string(volume, "Driver") == "local",
              let rawOptions = volume["Options"]
        else { return false }
        if rawOptions is NSNull { return true }
        guard let options = rawOptions as? [String: Any] else { return false }
        return options.isEmpty && options.values.allSatisfy { $0 is String }
    }

    private static func resolveHelperImages(
        source: MigrationSource,
        destination: EngineClient,
        allowsNetwork: Bool,
        prepared: PreparedVolumeMigration,
        progress: @escaping (VolumeMigrationProgress) -> Void
    ) throws -> (String, String) {
        let sourceExisting: String?
        let destinationExisting: String?
        do {
            sourceExisting = try HelperImage.existingAny(on: source.client)
            destinationExisting = try HelperImage.existingAny(on: destination)
        } catch {
            throw VolumeMigrationTransactionError.unavailable("could not recheck helper-image availability: \(error)")
        }
        var unavailable: [String] = []
        if sourceExisting == nil { unavailable.append(source.label) }
        if destinationExisting == nil { unavailable.append("Morbstack") }
        guard unavailable.isEmpty || allowsNetwork else {
            throw VolumeMigrationTransactionError.helperImageNetworkConsentRequired(unavailable)
        }

        let sourceImage: String
        if let sourceExisting {
            sourceImage = sourceExisting
        } else {
            emit(progress, prepared: prepared, phase: .pullingHelperImage, completed: 0, volume: nil,
                 bytes: nil, detail: "pulling alpine:3.20 onto \(source.label) after explicit network consent")
            try HelperImage.pull("alpine:3.20", on: source.client)
            sourceImage = "alpine:3.20"
        }
        let destinationImage: String
        if let destinationExisting {
            destinationImage = destinationExisting
        } else {
            emit(progress, prepared: prepared, phase: .pullingHelperImage, completed: 0, volume: nil,
                 bytes: nil, detail: "pulling alpine:3.20 onto Morbstack after explicit network consent")
            try HelperImage.pull("alpine:3.20", on: destination)
            destinationImage = "alpine:3.20"
        }
        return (sourceImage, destinationImage)
    }

    private static func transfer(
        _ item: MigrationVolumePlanItem,
        itemIndex: Int,
        prepared: PreparedVolumeMigration,
        source: MigrationSource,
        sourceImage: String,
        destination: EngineClient,
        destinationImage: String,
        progress: @escaping (VolumeMigrationProgress) -> Void
    ) -> VolumeMigrationItemReport {
        func event(_ phase: VolumeMigrationProgressPhase, bytes: Int64? = nil, detail: String? = nil) {
            emit(progress, prepared: prepared, phase: phase, completed: itemIndex,
                 volume: item.name, bytes: bytes, detail: detail)
        }

        var archiveBytes: Int64 = 0
        var archiveFileCount: Int?
        var sourceHelperCreated = false
        var destinationHelperCreated = false
        var destinationCreated = false
        var sourceHelperID: String?
        var destinationHelperID: String?
        defer {
            if let destinationHelperID { _ = HelperContainer.remove(on: destination, id: destinationHelperID) }
            if let sourceHelperID { _ = HelperContainer.remove(on: source.client, id: sourceHelperID) }
        }

        guard isSafeVolumeName(item.name) else {
            return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                          destinationHelperCreated: destinationHelperCreated, outcome: .failed,
                          destinationState: .notCreated,
                          detail: "the prepared volume name is not safe for the Docker Engine path contract")
        }

        do {
            event(.checkingPreconditions)
            let sourceInfo = try source.client.jsonObject("GET", "/volumes/\(item.name)", timeout: 30)
            guard JSONRead.string(sourceInfo, "Driver") == "local" else {
                return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                              destinationHelperCreated: destinationHelperCreated, outcome: .failed,
                              destinationState: .notCreated,
                              detail: "source volume is no longer a Docker local-driver volume")
            }
            guard isOptionFreeLocalVolume(sourceInfo) else {
                return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                              destinationHelperCreated: destinationHelperCreated, outcome: .failed,
                              destinationState: .notCreated,
                              detail: "source volume has custom or unverifiable local-driver options; refusing to create a default destination volume that would change its storage contract")
            }
            guard try !volumeExists(item.name, on: destination) else {
                return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                              destinationHelperCreated: destinationHelperCreated, outcome: .failed,
                              destinationState: .notCreated,
                              detail: "Morbstack now has a volume with this name; refusing to merge or overwrite it")
            }
            let labels = JSONRead.dictionary(sourceInfo, "Labels") ?? [:]

            let directory = MorbFeaturePaths.migrateDirectory
                .appendingPathComponent("volume-transactions", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent(
                "volume-\(prepared.transactionID.uuidString.lowercased())-\(itemIndex).tar", isDirectory: false)
            defer { try? FileManager.default.removeItem(at: archive) }

            sourceHelperID = try HelperContainer.createMounted(
                on: source.client, image: sourceImage, volumeName: item.name, readOnly: true)
            sourceHelperCreated = true
            event(.exporting, bytes: 0)
            let exported = try source.client.download(
                "GET", "/containers/\(sourceHelperID!)/archive", query: [("path", "/data")], to: archive,
                timeout: 900,
                onProgress: { bytes in
                    archiveBytes = bytes
                    event(.exporting, bytes: bytes)
                    return true
                })
            archiveBytes = exported.bytes
            archiveFileCount = TarLite.countRegularFiles(at: archive)

            // Check again after the potentially long source read. A race may create
            // the name at Morbstack, but the safe answer is still to leave it alone.
            guard try !volumeExists(item.name, on: destination) else {
                return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                              destinationHelperCreated: destinationHelperCreated, outcome: .failed,
                              destinationState: .notCreated,
                              detail: "Morbstack acquired this volume name while the source archive was read; refusing to merge or overwrite it")
            }

            event(.creatingDestination)
            let create = try destination.request(
                "POST", "/volumes/create",
                body: try JSONSerialization.data(withJSONObject: ["Name": item.name, "Labels": labels], options: []),
                contentType: "application/json", timeout: 30)
            guard create.isSuccess else {
                throw EngineError.engine(status: create.status, message: create.engineMessage)
            }
            destinationCreated = true

            destinationHelperID = try HelperContainer.createMounted(
                on: destination, image: destinationImage, volumeName: item.name, readOnly: false)
            destinationHelperCreated = true
            event(.importing, bytes: 0)
            let uploaded = try destination.upload(
                "PUT", "/containers/\(destinationHelperID!)/archive", query: [("path", "/")], from: archive,
                timeout: 900,
                onProgress: { bytes in event(.importing, bytes: bytes) })
            guard uploaded.isSuccess else {
                throw EngineError.engine(status: uploaded.status, message: uploaded.engineMessage)
            }

            return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                          destinationHelperCreated: destinationHelperCreated, outcome: .copied,
                          destinationState: .archiveUploaded,
                          detail: "Docker accepted the complete archive upload; volume contents were not independently verified")
        } catch {
            let outcome: VolumeMigrationItemOutcome = destinationCreated ? .requiresReview : .failed
            let state: VolumeMigrationDestinationState = destinationCreated ? .requiresReview : .notCreated
            return report(for: item, bytes: archiveBytes, fileCount: archiveFileCount, sourceHelperCreated: sourceHelperCreated,
                          destinationHelperCreated: destinationHelperCreated, outcome: outcome,
                          destinationState: state, detail: "transfer returned an error: \(error)")
        }
    }

    private static func volumeExists(_ name: String, on client: EngineClient) throws -> Bool {
        do {
            _ = try client.jsonObject("GET", "/volumes/\(name)", timeout: 30)
            return true
        } catch let error as EngineError {
            if case .engine(let status, _) = error, status == 404 { return false }
            throw error
        }
    }

    private static func isSafeVolumeName(_ name: String) -> Bool {
        guard (1...255).contains(name.utf8.count), let first = name.utf8.first else { return false }
        guard (0x30...0x39).contains(first) || (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x2E || byte == 0x5F
        }
    }

    private static func report(
        for item: MigrationVolumePlanItem,
        bytes: Int64,
        fileCount: Int?,
        sourceHelperCreated: Bool,
        destinationHelperCreated: Bool,
        outcome: VolumeMigrationItemOutcome,
        destinationState: VolumeMigrationDestinationState,
        detail: String?
    ) -> VolumeMigrationItemReport {
        VolumeMigrationItemReport(
            name: item.name, driver: item.driver, archiveBytes: bytes, archiveFileCount: fileCount,
            sourceHelperCreated: sourceHelperCreated, destinationHelperCreated: destinationHelperCreated,
            outcome: outcome, destinationState: destinationState, detail: detail)
    }

    private static func emit(
        _ progress: (VolumeMigrationProgress) -> Void,
        prepared: PreparedVolumeMigration,
        phase: VolumeMigrationProgressPhase,
        completed: Int,
        volume: String?,
        bytes: Int64?,
        detail: String?
    ) {
        progress(VolumeMigrationProgress(
            transactionID: prepared.transactionID, phase: phase,
            completedVolumeCount: completed, totalVolumeCount: prepared.items.count,
            volumeName: volume, bytesTransferred: bytes, detail: detail))
    }
}
