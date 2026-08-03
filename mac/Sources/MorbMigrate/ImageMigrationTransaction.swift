// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The smallest executable migration transaction: selected local images only.
//
// A Docker image save/load is a narrow operation with an unusually good safety
// boundary: the source API calls are GETs, the destination is fixed to Morbstack,
// and the image config ID gives us an identity to re-check before and after a
// transfer. Volumes, containers, Docker CLI configuration, registry credentials,
// and registry/network activity all have materially different contracts, so they
// are intentionally not reachable through this service.

import Foundation
import MorbFeatures

/// How a caller selects images from a read-only migration comparison.
///
/// `allPlanned` is explicit: it means every *tagged* image whose source config ID
/// was absent from Morbstack when the plan was derived. Callers that need a narrower
/// operation use `references`, which must name plan entries exactly.
public enum ImageMigrationSelection: Sendable, Equatable {
    case references([String])
    case allPlanned
}

/// One prepared images-only migration. Preparing is read-only; execution requires a
/// matching ``ImageMigrationConfirmation`` and performs fresh preflight checks before
/// every destination write.
public struct PreparedImageMigration: Sendable, Equatable, Codable {
    public let transactionID: UUID
    public let preparedAt: String
    public let source: MigrationPlanEndpoint
    public let destination: MigrationPlanEndpoint
    public let items: [MigrationImagePlanItem]
    public let selectionDescription: String
    public let sourceUntouched: Bool
    public let excludedScopes: [String]

    public init(
        transactionID: UUID,
        preparedAt: String,
        source: MigrationPlanEndpoint,
        destination: MigrationPlanEndpoint,
        items: [MigrationImagePlanItem],
        selectionDescription: String,
        sourceUntouched: Bool,
        excludedScopes: [String]
    ) {
        self.transactionID = transactionID
        self.preparedAt = preparedAt
        self.source = source
        self.destination = destination
        self.items = items
        self.selectionDescription = selectionDescription
        self.sourceUntouched = sourceUntouched
        self.excludedScopes = excludedScopes
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    /// Produces the capability required by `execute`. UI code should call this only
    /// after its own confirmation dialog; CLI code only after its terminal prompt or
    /// explicit `--yes` opt-in. The value is bound to this exact prepared selection.
    public func confirmation() -> ImageMigrationConfirmation {
        ImageMigrationConfirmation(transactionID: transactionID)
    }
}

/// Proof that the caller completed its explicit confirmation step for one prepared
/// transaction. It is intentionally constructible only by ``PreparedImageMigration``.
public struct ImageMigrationConfirmation: Sendable, Equatable {
    fileprivate let transactionID: UUID
}

/// A phase emitted by the transaction service. The callback is structured rather than
/// terminal text so the native app can use system progress and error presentation.
public enum ImageMigrationProgressPhase: String, Sendable, Equatable, Codable {
    case prepared
    case checkingPreconditions = "checking_preconditions"
    case exporting
    case importing
    case verifying
    case cancelled
    case completedImage = "completed_image"
    case writingReport = "writing_report"
    case completed
}

/// Progress for one selected image. Byte counts are emitted while the source archive
/// is written and while it is loaded into Morbstack; they are never estimates.
public struct ImageMigrationProgress: Sendable, Equatable, Codable {
    public let transactionID: UUID
    public let phase: ImageMigrationProgressPhase
    public let completedImageCount: Int
    public let totalImageCount: Int
    public let imageReference: String?
    public let bytesTransferred: Int64?
    public let expectedBytes: Int64?
    public let detail: String?

    public init(
        transactionID: UUID,
        phase: ImageMigrationProgressPhase,
        completedImageCount: Int,
        totalImageCount: Int,
        imageReference: String?,
        bytesTransferred: Int64?,
        expectedBytes: Int64?,
        detail: String?
    ) {
        self.transactionID = transactionID
        self.phase = phase
        self.completedImageCount = completedImageCount
        self.totalImageCount = totalImageCount
        self.imageReference = imageReference
        self.bytesTransferred = bytesTransferred
        self.expectedBytes = expectedBytes
        self.detail = detail
    }
}

/// The final state of a selected image. `requiresReview` deliberately covers an
/// uncertain `images/load` response or a changed source tag: it is never presented as
/// either a successful import or a rollback candidate.
public enum ImageMigrationItemOutcome: String, Sendable, Equatable, Codable {
    case verified
    case alreadyPresent = "already_present"
    case failed
    case cancelled
    case requiresReview = "requires_review"
}

/// Evidence collected after an image transfer. A config ID equality is useful local
/// identity evidence, but it is not a signature, provenance attestation, or SBOM.
public enum ImageMigrationVerification: String, Sendable, Equatable, Codable {
    case notRun = "not_run"
    case matched
    case sourceChanged = "source_changed"
    case destinationMissing = "destination_missing"
    case destinationDifferent = "destination_different"
    case destinationMatchesAfterLoadError = "destination_matches_after_load_error"
    case unavailable
}

/// Durable result for one selected image.
public struct ImageMigrationItemReport: Sendable, Equatable, Codable, Identifiable {
    public let reference: String
    public let expectedImageID: String
    public var sourceImageID: String?
    public var destinationImageID: String?
    public var archiveBytes: Int64
    public var outcome: ImageMigrationItemOutcome
    public var verification: ImageMigrationVerification
    public var detail: String?

    public var id: String { "\(reference)|\(expectedImageID)" }

    public init(
        reference: String,
        expectedImageID: String,
        sourceImageID: String?,
        destinationImageID: String?,
        archiveBytes: Int64,
        outcome: ImageMigrationItemOutcome,
        verification: ImageMigrationVerification,
        detail: String?
    ) {
        self.reference = reference
        self.expectedImageID = expectedImageID
        self.sourceImageID = sourceImageID
        self.destinationImageID = destinationImageID
        self.archiveBytes = archiveBytes
        self.outcome = outcome
        self.verification = verification
        self.detail = detail
    }
}

/// The durable report for one images-only transaction. It contains no credentials,
/// environment values, registry tokens, Docker configuration values, or volume data.
public struct ImageMigrationTransactionReport: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let preparedAt: String
    public let startedAt: String
    public var completedAt: String?
    public let source: MigrationPlanEndpoint
    public let destination: MigrationPlanEndpoint
    public let scope: String
    public let sourceUntouched: Bool
    public let excludedScopes: [String]
    public var items: [ImageMigrationItemReport]
    public var cancellationObserved: Bool
    public var reportPath: String?
    public var reportWriteError: String?
    public let rollbackGuidance: [String]
    public let credentialAndProvenanceLimits: [String]

    public init(
        transactionID: UUID,
        preparedAt: String,
        startedAt: String,
        source: MigrationPlanEndpoint,
        destination: MigrationPlanEndpoint,
        items: [ImageMigrationItemReport] = []
    ) {
        schemaVersion = 1
        self.transactionID = transactionID
        self.preparedAt = preparedAt
        self.startedAt = startedAt
        completedAt = nil
        self.source = source
        self.destination = destination
        scope = "selected_local_images_only"
        sourceUntouched = true
        excludedScopes = Self.excludedScopes
        self.items = items
        cancellationObserved = false
        reportPath = nil
        reportWriteError = nil
        rollbackGuidance = Self.rollbackGuidance
        credentialAndProvenanceLimits = Self.credentialAndProvenanceLimits
    }

    public var isFullyVerified: Bool {
        !items.isEmpty && items.allSatisfy {
            $0.outcome == .verified || $0.outcome == .alreadyPresent
        }
    }

    public var hasFailuresOrReview: Bool {
        items.contains { $0.outcome == .failed || $0.outcome == .requiresReview }
    }

    /// Writes an atomically replaced JSON report under Morbstack-owned state. The
    /// report location is stored in the encoded report itself so a later verification
    /// command or native route can be pointed at exactly this transaction.
    public func write() throws -> URL {
        let directory = MorbFeaturePaths.migrateDirectory
            .appendingPathComponent("image-transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = startedAt.replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(
            "images-\(timestamp)-\(transactionID.uuidString.lowercased()).json", isDirectory: false)
        var persisted = self
        persisted.reportPath = url.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persisted).write(to: url, options: .atomic)
        return url
    }

    public static func load(from url: URL) -> ImageMigrationTransactionReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ImageMigrationTransactionReport.self, from: data)
    }

    public static let excludedScopes = [
        "named volumes and bind mounts",
        "containers, stacks, and Kubernetes workloads",
        "Docker CLI contexts and configuration",
        "registry credentials, credential helpers, and registry access",
    ]

    public static let rollbackGuidance = [
        "The source engine is never changed by this transaction.",
        "There is no automatic rollback. Do not bulk-delete image IDs: images can share layers and tags.",
        "If a destination image must be removed, first inspect the report and Morbstack's current image details, then remove only the exact imported tag with normal Docker tooling.",
        "An item marked failed or requires_review is not evidence that no destination data was written; inspect and verify it before any cleanup.",
    ]

    public static let credentialAndProvenanceLimits = [
        "The transaction never calls a registry, Docker credential helper, or docker login; it transfers only already-local source image archives.",
        "Matching Docker image config IDs verifies local image identity across the two engines, not publisher identity, signatures, attestations, SBOMs, or registry provenance.",
    ]
}

/// Preparation or confirmation failures that prevent an image transfer from starting.
public enum ImageMigrationTransactionError: Error, CustomStringConvertible {
    case unavailable(String)
    case emptySelection
    case unknownReferences([String])
    case alreadyPresentReferences([String])
    case missingSourceSocket
    case confirmationDoesNotMatch

    public var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .emptySelection: return "the selected image set is empty; select one plan entry or use --all-images"
        case .unknownReferences(let references):
            return "these image references are not copyable entries in the current plan: \(references.joined(separator: ", "))"
        case .alreadyPresentReferences(let references):
            return "these image references already have the planned image ID in Morbstack: \(references.joined(separator: ", "))"
        case .missingSourceSocket: return "the prepared source has no Docker socket path"
        case .confirmationDoesNotMatch: return "confirmation does not belong to this prepared migration"
        }
    }
}

/// Executes a selected image migration through a fixed, narrow contract.
public enum ImageMigrationTransaction {

    /// Derives an exact, read-only plan and narrows it to an explicit selection.
    /// Calling this method does not create a report, write either engine, pull an
    /// image, start a runtime, access Docker configuration, or contact a registry.
    public static func prepare(
        from sourceToken: String? = nil,
        selection: ImageMigrationSelection
    ) throws -> PreparedImageMigration {
        let plan = MigrationReadOnlyPlanner.inspect(from: sourceToken)
        guard plan.source.readiness == .ready, plan.destination.readiness == .ready,
              let imagePlan = plan.imagePlan
        else {
            throw ImageMigrationTransactionError.unavailable(
                plan.unavailableReason ?? plan.source.detail ?? plan.destination.detail
                    ?? "source and destination must both be ready before an image migration can be prepared")
        }
        guard plan.source.socketPath != nil else {
            throw ImageMigrationTransactionError.missingSourceSocket
        }

        let copyable = imagePlan.wouldCopy
        let selected: [MigrationImagePlanItem]
        let selectionDescription: String
        switch selection {
        case .allPlanned:
            selected = copyable
            selectionDescription = "all currently planned tagged images"
        case .references(let requested):
            let normalized = requested.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !normalized.isEmpty else { throw ImageMigrationTransactionError.emptySelection }
            let requestedSet = Set(normalized)
            let copyableByReference = Dictionary(uniqueKeysWithValues: copyable.map { ($0.reference, $0) })
            let presentReferences = Set(imagePlan.alreadyPresent.map(\.reference))
            let unknown = requestedSet.filter { copyableByReference[$0] == nil && !presentReferences.contains($0) }.sorted()
            if !unknown.isEmpty { throw ImageMigrationTransactionError.unknownReferences(unknown) }
            let alreadyPresent = requestedSet.filter { presentReferences.contains($0) }.sorted()
            if !alreadyPresent.isEmpty { throw ImageMigrationTransactionError.alreadyPresentReferences(alreadyPresent) }
            selected = copyable.filter { requestedSet.contains($0.reference) }
            selectionDescription = "explicit image references"
        }
        guard !selected.isEmpty else { throw ImageMigrationTransactionError.emptySelection }

        return PreparedImageMigration(
            transactionID: UUID(),
            preparedAt: Format.timestamp(),
            source: plan.source,
            destination: plan.destination,
            items: selected,
            selectionDescription: selectionDescription,
            sourceUntouched: true,
            excludedScopes: ImageMigrationTransactionReport.excludedScopes)
    }

    /// Imports each selected image independently. Before any `POST /images/load`, the
    /// source tag must still resolve to its prepared config ID and Morbstack must not
    /// have acquired a conflicting tag. Every successful load is then verified by
    /// reading both image IDs again. The source uses only Docker GET requests.
    ///
    /// `isCancelled` is honored before an image begins and during source export. Once
    /// a destination load has begun, it is allowed to finish and be verified because
    /// the Engine client's upload primitive cannot safely abort a partial import.
    public static func execute(
        _ prepared: PreparedImageMigration,
        confirmation: ImageMigrationConfirmation,
        progress: @escaping (ImageMigrationProgress) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ImageMigrationTransactionReport {
        guard confirmation.transactionID == prepared.transactionID else {
            throw ImageMigrationTransactionError.confirmationDoesNotMatch
        }
        guard let sourceSocket = prepared.source.socketPath else {
            throw ImageMigrationTransactionError.missingSourceSocket
        }

        let source = MigrationSource(
            label: prepared.source.name,
            client: EngineClient.forUnixSocket(sourceSocket),
            socketPath: sourceSocket)
        let destination = EngineClient()
        var report = ImageMigrationTransactionReport(
            transactionID: prepared.transactionID,
            preparedAt: prepared.preparedAt,
            startedAt: Format.timestamp(),
            source: prepared.source,
            destination: prepared.destination)
        emit(
            progress, prepared: prepared, phase: .prepared, completed: 0, image: nil,
            bytes: nil, expected: nil, detail: "selection confirmed")

        var stopAfterCurrentImage = false
        for (index, item) in prepared.items.enumerated() {
            if stopAfterCurrentImage || isCancelled() {
                report.cancellationObserved = true
                report.items.append(contentsOf: prepared.items[index...].map {
                    cancelledReport(for: $0, detail: "cancelled before destination import began")
                })
                emit(
                    progress, prepared: prepared, phase: .cancelled, completed: index, image: nil,
                    bytes: nil, expected: nil, detail: "remaining selected images were not imported")
                break
            }

            var itemReport = transfer(
                item, itemIndex: index, prepared: prepared, source: source,
                destination: destination, progress: progress, isCancelled: isCancelled)

            // A cancellation arriving while `POST /images/load` is active is deferred
            // until that import has a truthful post-load verification result.
            if isCancelled() {
                report.cancellationObserved = true
                stopAfterCurrentImage = true
                if itemReport.outcome == .verified || itemReport.outcome == .alreadyPresent {
                    let suffix = "cancellation was requested after this image began; it was verified before stopping"
                    itemReport.detail = itemReport.detail.map { "\($0); \(suffix)" } ?? suffix
                }
            }
            report.items.append(itemReport)
            emit(
                progress, prepared: prepared, phase: .completedImage, completed: index + 1,
                image: item.reference, bytes: itemReport.archiveBytes,
                expected: item.sizeBytes, detail: itemReport.outcome.rawValue)
        }

        report.completedAt = Format.timestamp()
        emit(
            progress, prepared: prepared, phase: .writingReport, completed: report.items.count,
            image: nil, bytes: nil, expected: nil, detail: nil)
        do {
            report.reportPath = try report.write().path
        } catch {
            report.reportWriteError = "could not write migration report: \(error)"
        }
        emit(
            progress, prepared: prepared, phase: .completed, completed: report.items.count,
            image: nil, bytes: nil, expected: nil,
            detail: report.reportWriteError ?? (report.isFullyVerified ? "all selected images verified" : "review report items"))
        return report
    }

    // MARK: - One-image transfer

    private static func transfer(
        _ item: MigrationImagePlanItem,
        itemIndex: Int,
        prepared: PreparedImageMigration,
        source: MigrationSource,
        destination: EngineClient,
        progress: @escaping (ImageMigrationProgress) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> ImageMigrationItemReport {
        func event(
            _ phase: ImageMigrationProgressPhase, bytes: Int64? = nil, detail: String? = nil
        ) {
            emit(
                progress, prepared: prepared, phase: phase, completed: itemIndex,
                image: item.reference, bytes: bytes, expected: item.sizeBytes, detail: detail)
        }

        if isCancelled() {
            event(.cancelled, detail: "cancelled before preflight")
            return cancelledReport(for: item, detail: "cancelled before destination import began")
        }

        event(.checkingPreconditions)
        let sourceID: String?
        let destinationID: String?
        do {
            sourceID = try imageID(reference: item.reference, on: source.client)
            guard sourceID == item.imageID else {
                return ImageMigrationItemReport(
                    reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceID,
                    destinationImageID: nil, archiveBytes: 0, outcome: .failed,
                    verification: .sourceChanged,
                    detail: "source tag no longer resolves to the image ID selected in the prepared plan")
            }
            destinationID = try imageID(reference: item.reference, on: destination)
            if destinationID == item.imageID {
                return ImageMigrationItemReport(
                    reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceID,
                    destinationImageID: destinationID, archiveBytes: 0, outcome: .alreadyPresent,
                    verification: .matched,
                    detail: "Morbstack acquired the same image after preparation; no import was needed")
            }
            if destinationID != nil {
                return ImageMigrationItemReport(
                    reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceID,
                    destinationImageID: destinationID, archiveBytes: 0, outcome: .failed,
                    verification: .destinationDifferent,
                    detail: "Morbstack's tag changed after preparation; refusing to overwrite it")
            }
        } catch {
            return ImageMigrationItemReport(
                reference: item.reference, expectedImageID: item.imageID, sourceImageID: nil,
                destinationImageID: nil, archiveBytes: 0, outcome: .failed,
                verification: .unavailable, detail: "could not complete preflight: \(error)")
        }

        if isCancelled() {
            event(.cancelled, detail: "cancelled after preflight")
            return cancelledReport(for: item, detail: "cancelled before destination import began")
        }

        let directory = MorbFeaturePaths.migrateDirectory
            .appendingPathComponent("image-transactions", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ImageMigrationItemReport(
                reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceID,
                destinationImageID: destinationID, archiveBytes: 0, outcome: .failed,
                verification: .notRun, detail: "could not create Morbstack's temporary migration directory: \(error)")
        }
        let archive = directory.appendingPathComponent(
            "image-\(prepared.transactionID.uuidString.lowercased())-\(itemIndex).tar", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: archive) }

        var archiveBytes: Int64 = 0
        var destinationImportBegan = false
        do {
            event(.exporting, bytes: 0)
            let exported = try source.client.download(
                "GET", "/images/get", query: [("names", item.reference)], to: archive, timeout: 900,
                onProgress: { bytes in
                    archiveBytes = bytes
                    event(.exporting, bytes: bytes)
                    return !isCancelled()
                })
            archiveBytes = exported.bytes
            if isCancelled() {
                event(.cancelled, bytes: archiveBytes, detail: "cancelled after export")
                return cancelledReport(for: item, detail: "source archive was discarded before destination import")
            }

            event(.importing, bytes: 0)
            destinationImportBegan = true
            let loaded = try destination.upload(
                "POST", "/images/load", query: [("quiet", "0")], from: archive, timeout: 1800,
                onProgress: { bytes in event(.importing, bytes: bytes) })
            guard loaded.isSuccess else {
                throw EngineError.engine(status: loaded.status, message: loaded.engineMessage)
            }
            if loaded.text.contains("\"errorDetail\"") || loaded.text.lowercased().contains("\"error\"") {
                throw EngineError.malformed("/images/load reported an error: \(Format.truncate(loaded.text, 400))")
            }
        } catch {
            if isCancelled(), !destinationImportBegan {
                event(.cancelled, bytes: archiveBytes, detail: "cancelled during source export")
                return cancelledReport(for: item, detail: "cancelled before a confirmed destination import")
            }
            let destinationAfterError = try? imageID(reference: item.reference, on: destination)
            let verification: ImageMigrationVerification = destinationAfterError == item.imageID
                ? .destinationMatchesAfterLoadError : .notRun
            let outcome: ImageMigrationItemOutcome = destinationImportBegan ? .requiresReview : .failed
            let cancellationDetail = isCancelled() && destinationImportBegan
                ? "; a cancellation request arrived after destination import began, so inspect this destination tag before any cleanup"
                : ""
            return ImageMigrationItemReport(
                reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceID,
                destinationImageID: destinationAfterError ?? destinationID, archiveBytes: archiveBytes,
                outcome: outcome, verification: verification,
                detail: "transfer returned an error: \(error)\(cancellationDetail)")
        }

        event(.verifying, bytes: archiveBytes)
        do {
            let sourceAfter = try imageID(reference: item.reference, on: source.client)
            let destinationAfter = try imageID(reference: item.reference, on: destination)
            if sourceAfter == item.imageID && destinationAfter == item.imageID {
                return ImageMigrationItemReport(
                    reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceAfter,
                    destinationImageID: destinationAfter, archiveBytes: archiveBytes, outcome: .verified,
                    verification: .matched, detail: nil)
            }
            if sourceAfter != item.imageID {
                return ImageMigrationItemReport(
                    reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceAfter,
                    destinationImageID: destinationAfter, archiveBytes: archiveBytes,
                    outcome: .requiresReview, verification: .sourceChanged,
                    detail: "source tag changed while the archive was transferred; destination identity is recorded but the current tag no longer matches the plan")
            }
            if destinationAfter == nil {
                return ImageMigrationItemReport(
                    reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceAfter,
                    destinationImageID: nil, archiveBytes: archiveBytes, outcome: .requiresReview,
                    verification: .destinationMissing, detail: "destination image was absent after a successful load response")
            }
            return ImageMigrationItemReport(
                reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceAfter,
                destinationImageID: destinationAfter, archiveBytes: archiveBytes, outcome: .requiresReview,
                verification: .destinationDifferent,
                detail: "destination tag does not resolve to the image ID selected in the prepared plan")
        } catch {
            return ImageMigrationItemReport(
                reference: item.reference, expectedImageID: item.imageID, sourceImageID: sourceID,
                destinationImageID: nil, archiveBytes: archiveBytes, outcome: .requiresReview,
                verification: .unavailable, detail: "could not verify image IDs after import: \(error)")
        }
    }

    private static func imageID(reference: String, on client: EngineClient) throws -> String? {
        do {
            return JSONRead.string(try client.jsonObject("GET", "/images/\(reference)/json", timeout: 30), "Id")
        } catch let error as EngineError {
            if case .engine(let status, _) = error, status == 404 { return nil }
            throw error
        }
    }

    private static func cancelledReport(
        for item: MigrationImagePlanItem, detail: String
    ) -> ImageMigrationItemReport {
        ImageMigrationItemReport(
            reference: item.reference, expectedImageID: item.imageID, sourceImageID: nil,
            destinationImageID: nil, archiveBytes: 0, outcome: .cancelled,
            verification: .notRun, detail: detail)
    }

    private static func emit(
        _ progress: (ImageMigrationProgress) -> Void,
        prepared: PreparedImageMigration,
        phase: ImageMigrationProgressPhase,
        completed: Int,
        image: String?,
        bytes: Int64?,
        expected: Int64?,
        detail: String?
    ) {
        progress(ImageMigrationProgress(
            transactionID: prepared.transactionID, phase: phase,
            completedImageCount: completed, totalImageCount: prepared.items.count,
            imageReference: image, bytesTransferred: bytes, expectedBytes: expected,
            detail: detail))
    }
}
