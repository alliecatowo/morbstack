// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// Read-only capacity facts and a conservative resize preflight for the VM data disk.
///
/// A Morbstack data disk is a RAW image. Its file length is therefore the capacity the
/// guest block device sees, but changing that length alone does *not* grow the ext4 or
/// btrfs filesystem mounted inside the guest. ``Status`` makes that boundary explicit
/// so neither the app nor the CLI can imply that a configuration edit resized a live
/// disk before Morbstack has a verified guest filesystem-resize protocol.
///
/// This type never opens the image for writing. It is deliberately usable while the
/// daemon is stopped, and is the common source of truth for the future resize command
/// as well as today's read-only UI and CLI surfaces.
public enum MorbDiskCapacity {

    /// One binary gibibyte, the unit used by `disk_size_gib`.
    public static let bytesPerGiB: Int64 = 1024 * 1024 * 1024

    /// What Morbstack can truthfully say about an image and its configured capacity.
    public enum State: String, Codable, Equatable, Sendable {
        /// No image exists. The configured capacity will be used on first creation.
        case willCreate = "will-create"
        /// The file length and configured capacity agree.
        case matchesConfiguration = "matches-configuration"
        /// Increasing the RAW file would also require an in-guest filesystem resize.
        case increaseRequiresGuestResize = "increase-requires-guest-resize"
        /// Reducing a filesystem-backed image risks data loss and is never attempted.
        case decreaseUnsupported = "decrease-unsupported"
        /// The host could not inspect the existing image.
        case unavailable
    }

    /// A fact-only capacity report. `currentBytes` is the RAW file length — the capacity
    /// visible to the guest block device — not the APFS blocks currently allocated by
    /// the sparse file.
    public struct Status: Codable, Equatable, Sendable {
        public var imagePath: String
        public var configuredGiB: Int
        public var configuredBytes: Int64
        public var currentBytes: Int64?
        public var state: State
        public var inspectionError: String?

        public init(
            imagePath: String,
            configuredGiB: Int,
            configuredBytes: Int64,
            currentBytes: Int64?,
            state: State,
            inspectionError: String? = nil
        ) {
            self.imagePath = imagePath
            self.configuredGiB = configuredGiB
            self.configuredBytes = configuredBytes
            self.currentBytes = currentBytes
            self.state = state
            self.inspectionError = inspectionError
        }

        /// A compact, user-facing description of the safe next state.
        public var summary: String {
            switch state {
            case .willCreate:
                return "A new sparse disk will be created at the configured capacity on first start."
            case .matchesConfiguration:
                return "The existing disk matches the configured capacity."
            case .increaseRequiresGuestResize:
                return "The configuration is not applied to an existing disk. Morbstack needs a verified guest filesystem resize before it can grow this disk safely."
            case .decreaseUnsupported:
                return "The existing disk is larger than the configuration. Morbstack never shrinks an existing disk."
            case .unavailable:
                return "Morbstack could not inspect the disk image. No capacity change was made."
            }
        }
    }

    /// Returns the exact capacity derived from a positive `disk_size_gib` value.
    ///
    /// `MorbConfig` validates its value before it reaches the VM. This defensive
    /// conversion still clamps malformed in-memory input to one GiB rather than
    /// allowing a zero-sized future image or overflowing an `Int64` report.
    public static func configuredBytes(forGiB configuredGiB: Int) -> Int64 {
        let gib = max(1, configuredGiB)
        let (bytes, overflow) = Int64(gib).multipliedReportingOverflow(by: bytesPerGiB)
        return overflow ? Int64.max : bytes
    }

    /// Classifies supplied file-length facts without touching the filesystem.
    ///
    /// Keeping the policy separate from ``inspect(imageURL:configuredGiB:)`` gives a
    /// future mutating operation a pure preflight and keeps its no-shrink invariant
    /// independently reviewable.
    public static func status(
        imagePath: String,
        configuredGiB: Int,
        currentBytes: Int64?
    ) -> Status {
        let configuredBytes = configuredBytes(forGiB: configuredGiB)
        guard let currentBytes else {
            return Status(
                imagePath: imagePath,
                configuredGiB: max(1, configuredGiB),
                configuredBytes: configuredBytes,
                currentBytes: nil,
                state: .willCreate)
        }

        let state: State
        if currentBytes == configuredBytes {
            state = .matchesConfiguration
        } else if currentBytes < configuredBytes {
            state = .increaseRequiresGuestResize
        } else {
            state = .decreaseUnsupported
        }
        return Status(
            imagePath: imagePath,
            configuredGiB: max(1, configuredGiB),
            configuredBytes: configuredBytes,
            currentBytes: currentBytes,
            state: state)
    }

    /// Reads only the RAW image's file length and returns its resize preflight.
    ///
    /// A missing image is normal before the first engine start. Any other `stat(2)`
    /// error is surfaced as `.unavailable`; it never falls back to pretending a disk
    /// is absent, because that would turn an inspection failure into a misleading
    /// first-boot promise.
    public static func inspect(
        imageURL: URL = MorbPaths.diskImage,
        configuredGiB: Int
    ) -> Status {
        var info = stat()
        if stat(imageURL.path, &info) == 0 {
            return status(
                imagePath: imageURL.path,
                configuredGiB: configuredGiB,
                currentBytes: max(0, Int64(info.st_size)))
        }

        if errno == ENOENT {
            return status(imagePath: imageURL.path, configuredGiB: configuredGiB, currentBytes: nil)
        }

        let message = String(cString: strerror(errno))
        return Status(
            imagePath: imageURL.path,
            configuredGiB: max(1, configuredGiB),
            configuredBytes: configuredBytes(forGiB: configuredGiB),
            currentBytes: nil,
            state: .unavailable,
            inspectionError: "stat(\(imageURL.path)) failed: \(message)")
    }
}
