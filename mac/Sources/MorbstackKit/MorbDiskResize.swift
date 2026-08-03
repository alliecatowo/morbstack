// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Readiness and recovery reporting for the stop-only VM disk grow transaction.

import Foundation

/// States the precise guest contract required before Morbstack may grow a
/// filesystem-backed RAW data image.
///
/// A larger host file is not a larger guest filesystem. This diagnostic is therefore
/// deliberately separate from ``MorbDiskCapacity``: it consumes capacity and lifecycle
/// facts but never opens, truncates, attaches, starts, or stops a disk. A future
/// mutator requires ``GuestCapability/ready``, a stopped VM, a retained journal of
/// the prior capacity, an explicit grow request, guest-side resize, and post-resize
/// verification before it can alter the image.
public enum MorbDiskResize {

    /// The additive capability carried by the guest's `info` reply.
    ///
    /// `unknown` is intentionally distinct from `unavailable`: it means an older or
    /// stopped guest did not make a statement. `ready` is reserved for a future guest
    /// that can accept an explicit target, resize the identified filesystem, and prove
    /// the result; a package containing `resize2fs` or `btrfs` alone is not enough.
    public enum GuestCapability: String, Codable, Equatable, Sendable {
        case unknown
        case unavailable
        case ready

        public init(wireValue: String?) {
            self = wireValue.flatMap(Self.init(rawValue:)) ?? .unknown
        }
    }

    /// The action state an app, CLI, or support bundle may truthfully display.
    public enum State: String, Codable, Equatable, Sendable {
        case notNeeded = "not-needed"
        case decreaseUnsupported = "decrease-unsupported"
        case capacityUnavailable = "capacity-unavailable"
        case vmMustStop = "vm-must-stop"
        case guestCapabilityUnknown = "guest-capability-unknown"
        case guestResizeUnavailable = "guest-resize-unavailable"
        /// A durable host journal exists. The only permitted next action is to retry
        /// the exact journal target and obtain a fresh guest proof.
        case recoveryRequired = "recovery-required"
        /// The ordinary preflight for an explicit end-to-end transaction.
        case readyForExplicitTransaction = "ready-for-explicit-transaction"
    }

    /// Reports a host crash or explicit interruption after a journal was written.
    /// This takes priority over ordinary file-length inspection: a RAW file can match
    /// its configured capacity while the filesystem proof is still missing, and
    /// presenting that state as "not needed" would be dangerously misleading.
    public static func recoveryDiagnostic(
        journal: MorbDiskGrowth.Journal,
        guestCapability: GuestCapability
    ) -> Diagnostic {
        Diagnostic(
            state: .recoveryRequired,
            guestCapability: guestCapability,
            currentBytes: journal.targetBytes,
            targetBytes: journal.targetBytes,
            summary: "A disk-growth transaction needs recovery. Retry the saved target to verify the guest filesystem; Morbstack will not shrink the disk.")
    }

    /// A fact-only diagnosis of one configured capacity change.
    public struct Diagnostic: Codable, Equatable, Sendable {
        public let state: State
        public let guestCapability: GuestCapability
        public let currentBytes: Int64?
        public let targetBytes: Int64
        public let summary: String

        public init(
            state: State,
            guestCapability: GuestCapability,
            currentBytes: Int64?,
            targetBytes: Int64,
            summary: String
        ) {
            self.state = state
            self.guestCapability = guestCapability
            self.currentBytes = currentBytes
            self.targetBytes = targetBytes
            self.summary = summary
        }

        /// Fields for the daemon's read-only status reply.
        public var ipcFields: [String: AnyCodableValue] {
            [
                "state": .string(state.rawValue),
                "guest_capability": .string(guestCapability.rawValue),
                "current_bytes": currentBytes.map { .int(Int($0)) } ?? .null,
                "target_bytes": .int(Int(targetBytes)),
                "message": .string(summary),
            ]
        }
    }

    /// Combines the host RAW-image preflight, VM lifecycle, and guest statement.
    ///
    /// The ordering is intentional: no action is needed for a new/matching image, and
    /// a shrink is refused before consulting a guest. For a true increase, `stopped`
    /// is a hard precondition even if a future guest advertises `ready`.
    public static func diagnose(
        capacity: MorbDiskCapacity.Status,
        vmState: VMState,
        guestCapability: GuestCapability
    ) -> Diagnostic {
        let targetBytes = capacity.configuredBytes
        switch capacity.state {
        case .willCreate, .matchesConfiguration:
            return Diagnostic(
                state: .notNeeded,
                guestCapability: guestCapability,
                currentBytes: capacity.currentBytes,
                targetBytes: targetBytes,
                summary: "No existing filesystem needs to be grown.")

        case .decreaseUnsupported:
            return Diagnostic(
                state: .decreaseUnsupported,
                guestCapability: guestCapability,
                currentBytes: capacity.currentBytes,
                targetBytes: targetBytes,
                summary: "Morbstack never shrinks an existing VM disk.")

        case .unavailable:
            return Diagnostic(
                state: .capacityUnavailable,
                guestCapability: guestCapability,
                currentBytes: capacity.currentBytes,
                targetBytes: targetBytes,
                summary: "Morbstack cannot inspect the current disk image, so no resize can be planned.")

        case .increaseRequiresGuestResize:
            guard vmState == .stopped else {
                return Diagnostic(
                    state: .vmMustStop,
                    guestCapability: guestCapability,
                    currentBytes: capacity.currentBytes,
                    targetBytes: targetBytes,
                    summary: "Stop the VM before any disk-growth transaction can inspect or change the image.")
            }
            switch guestCapability {
            case .unknown:
                return Diagnostic(
                    state: .guestCapabilityUnknown,
                    guestCapability: guestCapability,
                    currentBytes: capacity.currentBytes,
                    targetBytes: targetBytes,
                    summary: "The stopped or older guest has not proved a filesystem-resize protocol; Morbstack will not enlarge the image.")
            case .unavailable:
                return Diagnostic(
                    state: .guestResizeUnavailable,
                    guestCapability: guestCapability,
                    currentBytes: capacity.currentBytes,
                    targetBytes: targetBytes,
                    summary: "This guest reports no verified filesystem-resize protocol; Morbstack will not enlarge the image.")
            case .ready:
                return Diagnostic(
                    state: .readyForExplicitTransaction,
                    guestCapability: guestCapability,
                    currentBytes: capacity.currentBytes,
                    targetBytes: targetBytes,
                    summary: "A stop-only grow transaction may be requested explicitly; it must retain prior capacity metadata and verify the guest filesystem after resize.")
            }
        }
    }
}
