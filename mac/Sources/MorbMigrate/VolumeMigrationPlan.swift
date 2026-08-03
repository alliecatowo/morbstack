// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A pure named-volume eligibility model. This is deliberately smaller than a
// transfer transaction: it only compares two inventories which were already read
// from Docker. In particular, it never asks whether an existing destination volume
// is empty, because answering that would require a helper container and turn an
// ordinary migration inspection into a mutating operation.

import Foundation

/// The subset of a Docker volume list entry needed for a migration eligibility
/// comparison. Inventory collection is kept outside this type so the decision policy
/// remains independently testable and cannot make Docker requests by accident.
public struct MigrationVolumeInventoryItem: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let driver: String

    public var id: String { name }

    public init(name: String, driver: String) {
        self.name = name
        self.driver = driver
    }
}

/// The only conclusions a read-only plan may draw about one source named volume.
///
/// An `eligible` item is a local-driver source volume whose name is not present on
/// Morbstack. It is *not* a promise that a later transfer will succeed: a later,
/// separately confirmed transaction still needs a helper image, a live source and
/// destination, available disk space, and archive-copy preflight.
public enum MigrationVolumePlanDisposition: String, Sendable, Equatable, Codable {
    case eligible
    case destinationExists = "destination_exists"
    case unsupportedDriver = "unsupported_driver"
}

/// A named source volume and the conservative conclusion reached from the two
/// inventories. `reason` is user-facing explanatory text, not an engine error.
public struct MigrationVolumePlanItem: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let driver: String
    public let disposition: MigrationVolumePlanDisposition
    public let reason: String

    public var id: String { name }

    public var isEligible: Bool { disposition == .eligible }

    public init(
        name: String,
        driver: String,
        disposition: MigrationVolumePlanDisposition,
        reason: String
    ) {
        self.name = name
        self.driver = driver
        self.disposition = disposition
        self.reason = reason
    }
}

/// The volume portion of a read-only migration inspection.
///
/// A plan intentionally has no byte estimate, emptiness result, or overwrite option.
/// None of those can be established from `GET /volumes` alone, and inventing one
/// would risk presenting a later merge as a safe copy.
public struct MigrationVolumePlan: Sendable, Equatable, Codable {
    public let items: [MigrationVolumePlanItem]

    public init(items: [MigrationVolumePlanItem]) {
        self.items = items
    }

    /// New, local-driver volumes a future explicitly confirmed transfer may offer
    /// for selection. The inspection itself never selects or copies them.
    public var eligible: [MigrationVolumePlanItem] {
        items.filter(\.isEligible)
    }

    public var destinationExisting: [MigrationVolumePlanItem] {
        items.filter { $0.disposition == .destinationExists }
    }

    public var unsupported: [MigrationVolumePlanItem] {
        items.filter { $0.disposition == .unsupportedDriver }
    }
}

/// Forms a conservative named-volume plan from two already-read Docker inventories.
///
/// This function is pure. It never creates a helper container, pulls an image,
/// inspects volume contents, or writes to either engine. Only Docker's `local`
/// driver is eligible because the existing archive-copy mechanism has no portable
/// contract for third-party driver data.
public enum MigrationVolumePlanner {

    public static func plan(
        source: [MigrationVolumeInventoryItem],
        destination: [MigrationVolumeInventoryItem]
    ) -> MigrationVolumePlan {
        let destinationNames = Set(destination.map(\.name))
        let items = source
            .sorted { $0.name < $1.name }
            .map { volume in
                if volume.driver != "local" {
                    return MigrationVolumePlanItem(
                        name: volume.name,
                        driver: volume.driver,
                        disposition: .unsupportedDriver,
                        reason: "Only Docker local-driver volumes are eligible for migration.")
                }
                if destinationNames.contains(volume.name) {
                    return MigrationVolumePlanItem(
                        name: volume.name,
                        driver: volume.driver,
                        disposition: .destinationExists,
                        reason: "Morbstack already has a volume with this name. Its contents were not inspected, so this read-only plan will not offer overwrite or merge.")
                }
                return MigrationVolumePlanItem(
                    name: volume.name,
                    driver: volume.driver,
                    disposition: .eligible,
                    reason: "A later explicitly confirmed transfer may create this new Morbstack volume.")
            }
        return MigrationVolumePlan(items: items)
    }
}
