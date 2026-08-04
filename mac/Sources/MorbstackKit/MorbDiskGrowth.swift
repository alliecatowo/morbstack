// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// Durable host-side mechanics for the explicit grow-only VM disk transaction.
///
/// A RAW file's length is only one half of a disk expansion: the guest must later
/// identify the mounted filesystem, grow it, and return a proof. This type owns the
/// irreversible host half and its recovery record. It deliberately has no lifecycle
/// or guest-control knowledge; ``VMManager`` supplies the stopped-VM guard and the
/// MRB0 proof exchange around these calls.
public enum MorbDiskGrowth {

    public static let journalVersion = 1

    /// A stable identity for the exact object opened for mutation. A path alone is not
    /// enough: replacing the file while the daemon is down must fail closed rather
    /// than allowing a recovery command to grow a different image.
    public struct FileIdentity: Codable, Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// The monotonic state of the host/guest transaction.
    public enum Phase: String, Codable, Equatable, Sendable {
        /// Journal durable; the raw file may still have its original length.
        case prepared
        /// The RAW file was durably extended to `targetBytes`.
        case hostGrown = "host-grown"
        /// The guest returned a checked filesystem/device proof.
        case guestProved = "guest-proved"
    }

    /// The guest facts retained if a crash happens after the resize reply but before
    /// the journal can be removed. They make a retry an explicit re-verification,
    /// never a silent assumption that the previous command completed.
    public struct GuestProof: Codable, Equatable, Sendable {
        public let device: String
        public let mountPoint: String
        public let filesystem: String
        public let deviceBytes: Int64
        public let beforeFilesystemBytes: Int64
        public let afterFilesystemBytes: Int64
        public let resized: Bool
        public let previouslyProved: Bool

        public init(
            device: String,
            mountPoint: String,
            filesystem: String,
            deviceBytes: Int64,
            beforeFilesystemBytes: Int64,
            afterFilesystemBytes: Int64,
            resized: Bool,
            previouslyProved: Bool
        ) {
            self.device = device
            self.mountPoint = mountPoint
            self.filesystem = filesystem
            self.deviceBytes = deviceBytes
            self.beforeFilesystemBytes = beforeFilesystemBytes
            self.afterFilesystemBytes = afterFilesystemBytes
            self.resized = resized
            self.previouslyProved = previouslyProved
        }
    }

    /// The complete recoverable transaction record.
    public struct Journal: Codable, Equatable, Sendable {
        public let version: Int
        public let imagePath: String
        public let identity: FileIdentity
        public let originalBytes: Int64
        public let targetBytes: Int64
        public var phase: Phase
        public var proof: GuestProof?

        public init(
            imagePath: String,
            identity: FileIdentity,
            originalBytes: Int64,
            targetBytes: Int64,
            phase: Phase = .prepared,
            proof: GuestProof? = nil
        ) {
            self.version = journalVersion
            self.imagePath = imagePath
            self.identity = identity
            self.originalBytes = originalBytes
            self.targetBytes = targetBytes
            self.phase = phase
            self.proof = proof
        }
    }

    /// Opens the image without following a symlink and returns its exact stable
    /// identity and apparent RAW capacity.
    public static func inspectImage(at imageURL: URL) throws -> (identity: FileIdentity, bytes: Int64) {
        let fd = try openRegularImage(imageURL)
        defer { Darwin.close(fd) }
        let info = try fileStat(fd: fd, describing: imageURL.path)
        return (fileIdentity(info), Int64(info.st_size))
    }

    /// Creates a new journal only after proving an existing regular image has the
    /// supplied old capacity. The caller must persist this before calling
    /// ``extendRawImage(_:expecting:)``.
    public static func makeJournal(
        imageURL: URL = MorbPaths.diskImage,
        originalBytes: Int64,
        targetBytes: Int64
    ) throws -> Journal {
        guard originalBytes > 0, targetBytes > originalBytes else {
            throw MorbError.config("disk growth requires a positive target larger than the existing disk")
        }
        let inspected = try inspectImage(at: imageURL)
        guard inspected.bytes == originalBytes else {
            throw MorbError.io(
                "disk image changed while preparing growth (expected \(originalBytes) bytes, found \(inspected.bytes))")
        }
        return Journal(
            imagePath: imageURL.standardizedFileURL.path,
            identity: inspected.identity,
            originalBytes: originalBytes,
            targetBytes: targetBytes)
    }

    /// Reads the durable recovery record, rejecting malformed or unknown schema rather
    /// than guessing which bytes belong to a partially completed transaction.
    public static func loadJournal(url: URL = MorbPaths.diskGrowJournal) throws -> Journal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decodeJournal(Data(contentsOf: url))
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.protocolViolation(
                "could not decode \(url.path); refusing to alter the disk: \(error.localizedDescription)")
        }
    }

    /// Atomically replaces the journal and syncs both the file and its containing
    /// directory. The durable ordering is the safety contract: a crash cannot leave
    /// `ftruncate` as the only evidence of a planned filesystem resize.
    public static func storeJournal(_ journal: Journal, url: URL = MorbPaths.diskGrowJournal) throws {
        try validateJournal(journal)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(journal)
        } catch {
            throw MorbError.io("could not encode disk-grow journal: \(error.localizedDescription)")
        }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".disk-grow-journal-\(UUID().uuidString).tmp", isDirectory: false)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw MorbError.io("could not create disk-grow journal: \(String(cString: strerror(errno)))")
        }
        var completed = false
        defer {
            Darwin.close(fd)
            if !completed { _ = Darwin.unlink(temporary.path) }
        }
        try writeAll(data, to: fd, describing: temporary.path)
        guard Darwin.fsync(fd) == 0 else {
            throw MorbError.io("could not sync disk-grow journal: \(String(cString: strerror(errno)))")
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw MorbError.io("could not install disk-grow journal: \(String(cString: strerror(errno)))")
        }
        try syncDirectory(containing: url)
        completed = true
    }

    /// Decodes the recoverable host journal without touching a disk or the
    /// filesystem. This is deliberately internal rather than file-backed so the
    /// schema and recovery invariants have hermetic coverage.
    static func decodeJournal(_ data: Data) throws -> Journal {
        let journal: Journal
        do {
            journal = try JSONDecoder().decode(Journal.self, from: data)
        } catch {
            throw MorbError.protocolViolation(
                "could not decode disk-grow journal: \(error.localizedDescription)")
        }
        try validateJournal(journal)
        return journal
    }

    /// Rejects a structurally contradictory journal before it can become recovery
    /// authority. The image identity is checked separately against the opened file;
    /// this method is intentionally pure so it can validate an interrupted state
    /// before any mutation is considered.
    static func validateJournal(_ journal: Journal) throws {
        guard journal.version == journalVersion else {
            throw MorbError.protocolViolation(
                "unsupported disk-grow journal version \(journal.version); refusing to alter the disk")
        }
        guard !journal.imagePath.isEmpty,
              journal.originalBytes > 0,
              journal.targetBytes > journal.originalBytes
        else {
            throw MorbError.protocolViolation("disk-grow journal has an invalid identity or capacity range")
        }

        switch journal.phase {
        case .prepared, .hostGrown:
            guard journal.proof == nil else {
                throw MorbError.protocolViolation(
                    "disk-grow journal carries a guest proof before the guest-proved phase")
            }
        case .guestProved:
            guard let proof = journal.proof else {
                throw MorbError.protocolViolation(
                    "disk-grow journal reached guest-proved without a guest proof")
            }
            // A terminal journal may be replayed after a crash, but its stored proof
            // must still satisfy the same evidence threshold that applied before the
            // phase was advanced. Temporarily remove the terminal allowance so a
            // forged `resized: false` proof cannot enter recovery.
            var unproven = journal
            unproven.phase = .hostGrown
            try validateGuestProof(proof, journal: unproven)
        }
    }

    /// Removes a fully proved journal and syncs its parent. No caller may invoke this
    /// merely because the raw file is larger; only a verified guest proof closes the
    /// transaction.
    public static func removeJournal(url: URL = MorbPaths.diskGrowJournal) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard Darwin.unlink(url.path) == 0 else {
            throw MorbError.io("could not remove disk-grow journal: \(String(cString: strerror(errno)))")
        }
        try syncDirectory(containing: url)
    }

    /// Extends the exact file described by `journal`, never shrinking it. The caller
    /// must write the journal first. A retry after a crash is idempotent: seeing the
    /// target length advances naturally to the guest-proof phase; any third length is
    /// a conflict and fails closed.
    @discardableResult
    public static func extendRawImage(_ journal: Journal) throws -> Phase {
        let expectedURL = URL(fileURLWithPath: journal.imagePath).standardizedFileURL
        guard expectedURL == MorbPaths.diskImage.standardizedFileURL else {
            throw MorbError.protocolViolation("disk-grow journal names an unexpected image path")
        }
        let fd = try openRegularImage(expectedURL)
        defer { Darwin.close(fd) }
        let info = try fileStat(fd: fd, describing: expectedURL.path)
        guard fileIdentity(info) == journal.identity else {
            throw MorbError.io("disk image identity changed since growth was prepared; refusing to alter it")
        }
        let actual = Int64(info.st_size)
        if actual == journal.targetBytes {
            return .hostGrown
        }
        guard actual == journal.originalBytes else {
            throw MorbError.io(
                "disk image has \(actual) bytes; expected \(journal.originalBytes) or \(journal.targetBytes). "
                    + "Refusing to grow an image changed outside this transaction.")
        }
        guard Darwin.ftruncate(fd, off_t(journal.targetBytes)) == 0 else {
            throw MorbError.io("could not grow disk image: \(String(cString: strerror(errno)))")
        }
        guard Darwin.fsync(fd) == 0 else {
            throw MorbError.io("could not sync grown disk image: \(String(cString: strerror(errno)))")
        }
        return .hostGrown
    }

    /// Re-opens the raw image without writing and verifies the durable target length
    /// and identity before the guest is asked to touch its mounted filesystem.
    public static func verifyHostGrowth(_ journal: Journal) throws {
        let expectedURL = URL(fileURLWithPath: journal.imagePath).standardizedFileURL
        let inspected = try inspectImage(at: expectedURL)
        guard inspected.identity == journal.identity, inspected.bytes == journal.targetBytes else {
            throw MorbError.io("disk image no longer matches the durable growth journal")
        }
    }

    /// Applies strict, host-owned acceptance criteria to a guest response. A successful
    /// resize command is not proof on its own: the report must name the expected raw
    /// device and mount point, show the exact expanded device capacity, and never show
    /// a filesystem getting smaller. An unchanged filesystem is accepted only while
    /// re-verifying a previous host proof or a durable guest receipt after a crash.
    public static func validateGuestProof(
        _ proof: GuestProof,
        journal: Journal
    ) throws {
        guard proof.device == "/dev/vda", proof.mountPoint == "/var/lib/docker" else {
            throw MorbError.protocolViolation("guest resize proof named an unexpected device or mount point")
        }
        guard proof.filesystem == "ext4" || proof.filesystem == "btrfs" else {
            throw MorbError.protocolViolation("guest resize proof named unsupported filesystem \(proof.filesystem)")
        }
        guard proof.deviceBytes == journal.targetBytes else {
            throw MorbError.protocolViolation(
                "guest sees \(proof.deviceBytes) bytes on /dev/vda, expected \(journal.targetBytes)")
        }
        guard proof.beforeFilesystemBytes > 0, proof.afterFilesystemBytes >= proof.beforeFilesystemBytes else {
            throw MorbError.protocolViolation("guest resize proof did not show a non-decreasing filesystem capacity")
        }
        guard proof.resized || proof.previouslyProved || journal.phase == .guestProved else {
            throw MorbError.protocolViolation(
                "guest reported no filesystem growth and no durable guest receipt")
        }
    }

    private static func openRegularImage(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw MorbError.io("could not open disk image \(url.path): \(String(cString: strerror(errno)))")
        }
        do {
            _ = try fileStat(fd: fd, describing: url.path)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func fileStat(fd: Int32, describing path: String) throws -> stat {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw MorbError.io("could not stat disk image \(path): \(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MorbError.io("refusing to resize non-regular disk image \(path)")
        }
        guard info.st_size > 0 else {
            throw MorbError.io("refusing to resize an empty disk image \(path)")
        }
        return info
    }

    private static func fileIdentity(_ info: stat) -> FileIdentity {
        FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func writeAll(_ data: Data, to fd: Int32, describing path: String) throws {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: written), data.count - written)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw MorbError.io("could not write \(path): \(String(cString: strerror(errno)))")
            }
            guard count > 0 else { throw MorbError.io("short write to \(path)") }
            written += count
        }
    }

    private static func syncDirectory(containing url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw MorbError.io("could not open disk data directory: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw MorbError.io("could not sync disk data directory: \(String(cString: strerror(errno)))")
        }
    }
}
