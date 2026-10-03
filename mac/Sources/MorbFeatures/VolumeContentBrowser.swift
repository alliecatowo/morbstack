// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A read-only directory listing for the contents of a Docker named volume — beside
// VolumeArchiveExport.swift, and sharing its helper-container lifecycle exactly: create
// one stopped, read-only helper with the volume at /data:ro, read through it, and always
// remove it before returning, on every error path. See
// docs/audit/UI-FEATURE-GAP.md §6 (UX-7 resolved): the Engine API has no "read a volume"
// endpoint, only "read a path inside a (created-but-never-started) container", so
// browsing reuses that exact mechanism with a `HEAD` for the directory's own stat and a
// `GET` whose tar body is walked for immediate children only — never extracted, never
// written to host disk. Write is out of scope by design; see VolumeArchiveExportError's
// sibling reasoning for why a half-written volume is worse than a half-written archive.
//
// Every byte here is attacker-controlled: the volume's own contents were written by
// whatever container mounted it, not by Morbstack. In particular, a tar entry's *name* is
// data a hostile container could have chosen — including a `..`-carrying path designed to
// make a later "browse into this child" request escape the requested directory. Per
// docs/audit/INPUT-VALIDATION-REVIEW.md, that is rejected, not sanitised-and-continued:
// an entry whose validated relative name would collapse or escape is dropped from the
// listing rather than renamed into something that looks safe.

import Foundation
import MorbstackKit

// MARK: - Results

/// One immediate child of a browsed directory.
public struct VolumeContentEntry: Sendable, Equatable, Identifiable {

    public enum Kind: Sendable, Equatable {
        case directory
        case file
        case symlink
        /// A device, FIFO, socket, or anything else `ustar`/GNU/PAX can name. Shown
        /// honestly as "other" rather than guessed at.
        case other

        /// This browser's own four-way vocabulary is a deliberately coarser view of
        /// the same kinds MorbstackKit's shared typeflag mapping produces — a listing
        /// has no separate glyph for a character device versus a FIFO, so both
        /// collapse to `.other`. It is still one decision about what a typeflag means,
        /// made once, in `TarFormat.kind(forTypeflag:)`.
        init(_ kind: TarEntryKind) {
            switch kind {
            case .directory: self = .directory
            case .symbolicLink: self = .symlink
            case .regularFile: self = .file
            case .hardLink, .characterDevice, .blockDevice, .fifo, .socket, .unknown: self = .other
            }
        }
    }

    public var id: String { name }
    /// A single path component — already validated to contain no `/`, no `..`, and no
    /// control characters.
    public let name: String
    public let kind: Kind
    /// `0` for directories; the tar header's declared size otherwise.
    public let size: Int64
    public let modificationDate: Date?
    /// The raw symlink target text, for display only. Never followed by this browser.
    public let linkTarget: String?
}

/// One bounded directory listing.
public struct VolumeContentListing: Sendable, Equatable {
    public let volumeName: String
    /// The normalized absolute path listed, e.g. `/` or `/logs`.
    public let path: String
    /// Directories first, then everything else, each alphabetically — the same
    /// presentation order Finder and `ls -F` agree on.
    public let entries: [VolumeContentEntry]
    /// `true` when the directory held more entries than this listing returned, or more
    /// than this browser was willing to walk to find out.
    public let isTruncated: Bool
    /// Entries the tar stream carried whose name failed validation (see the file header)
    /// and were excluded rather than shown. Zero on every ordinary volume; a nonzero
    /// count is itself worth surfacing rather than silently dropping.
    public let rejectedEntryCount: Int
}

public enum VolumeContentBrowserError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidVolumeName
    case invalidPath
    case volumeNotFound
    case unsupportedVolumeDriver(String)
    case helperImageUnavailable
    case pathNotFound
    case pathIsNotADirectory
    case pathIsSymlink
    case noEngineResponse
    case engineRejected(status: Int, message: String)
    case malformedArchive(String)
    case helperCleanupFailed(String)

    public var description: String {
        switch self {
        case .invalidVolumeName:
            return "volume name must be an explicit Docker-safe named-volume identifier"
        case .invalidPath:
            return "path must be an absolute path with no `..` segments"
        case .volumeNotFound:
            return "the selected Morbstack volume no longer exists"
        case .unsupportedVolumeDriver(let driver):
            return "refusing to browse volume data from driver \(driver); only Docker local-driver volumes are supported"
        case .helperImageUnavailable:
            return "no already-local image is available for the temporary read-only volume helper; browsing never pulls an image"
        case .pathNotFound:
            return "that path no longer exists in the volume"
        case .pathIsNotADirectory:
            return "that path is a file, not a directory"
        case .pathIsSymlink:
            return "that path is a symbolic link; Morbstack does not follow symlinks while browsing a volume"
        case .noEngineResponse:
            return "the Docker Engine closed the volume browse request without a response"
        case .engineRejected(let status, let message):
            return "docker engine returned \(status): \(message)"
        case .malformedArchive(let detail):
            return "the Docker Engine's directory archive could not be read: \(detail)"
        case .helperCleanupFailed(let detail):
            return "could not remove Morbstack's temporary read-only volume helper; no listing was returned: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Browser

/// Lists exactly one directory's immediate children in one selected, already-existing
/// Docker `local` volume. Never extracts a file, never writes to host disk, never follows
/// a symlink, and never lists more than ``VolumeContentBrowser/maximumEntriesPerListing``
/// children — a directory with more than that reports ``VolumeContentListing/isTruncated``
/// rather than growing the request without bound.
public enum VolumeContentBrowser {

    /// The most immediate children one listing returns before it stops reading further
    /// tar data and reports ``VolumeContentListing/isTruncated``.
    public static let maximumEntriesPerListing = 1_000
    /// A hard stop on tar headers walked (at any depth) before giving up on a directory
    /// that never seems to end, even though its bound-1,000 immediate children were never
    /// reached — the safety net for a pathological archive shaped to stall this browser
    /// rather than to exceed the child-count bound.
    static let maximumEntriesScanned = 200_000
    /// The most bytes a GNU long-name/PAX extended-header entry may declare before this
    /// browser refuses to hold it and falls back to treating it as ordinary tar data to
    /// skip. Real long names are at most a few hundred bytes; this exists only to bound a
    /// hostile header's claimed size.
    static let maximumAuxDataBytes = 64 * 1_024
    /// The bound on the base64-decoded `X-Docker-Container-Path-Stat` header.
    static let maximumStatHeaderBytes = 16 * 1_024

    public static func list(
        volumeName: String,
        path rawPath: String = "/",
        engine: EngineClient = EngineClient(),
        timeout: TimeInterval = 60
    ) throws -> VolumeContentListing {
        guard isSafeVolumeName(volumeName) else {
            throw VolumeContentBrowserError.invalidVolumeName
        }
        let normalizedPath = try normalize(path: rawPath)

        var helperID: String?
        defer {
            // Final safety net for every early return/throw after helper creation,
            // mirroring VolumeArchiveExporter's contract exactly.
            if let helperID {
                _ = removeOwnedHelper(on: engine, id: helperID)
            }
        }

        let volume: [String: Any]
        do {
            volume = try engine.jsonObject("GET", "/volumes/\(volumeName)", timeout: 30)
        } catch let error as EngineError {
            if case .engine(let status, _) = error, status == 404 {
                throw VolumeContentBrowserError.volumeNotFound
            }
            throw error
        }
        let driver = JSONRead.string(volume, "Driver") ?? "unknown"
        guard driver == "local" else {
            throw VolumeContentBrowserError.unsupportedVolumeDriver(driver)
        }

        guard let helperImage = try alreadyLocalHelperImage(on: engine) else {
            throw VolumeContentBrowserError.helperImageUnavailable
        }
        helperID = try createStoppedReadOnlyHelper(on: engine, image: helperImage, volumeName: volumeName)
        let containerPath = normalizedPath == "/" ? "/data" : "/data\(normalizedPath)"

        let headResponse = try engine.request(
            "HEAD", "/containers/\(helperID!)/archive", query: [("path", containerPath)], timeout: 30)
        if headResponse.status == 404 { throw VolumeContentBrowserError.pathNotFound }
        guard headResponse.isSuccess else {
            throw VolumeContentBrowserError.engineRejected(
                status: headResponse.status, message: headResponse.engineMessage)
        }
        guard let statHeaderValue = headResponse.headers["x-docker-container-path-stat"] else {
            throw VolumeContentBrowserError.malformedArchive("missing X-Docker-Container-Path-Stat header")
        }
        let stat = try decodePathStat(statHeaderValue)
        guard !stat.isSymlink else { throw VolumeContentBrowserError.pathIsSymlink }
        guard stat.isDirectory else { throw VolumeContentBrowserError.pathIsNotADirectory }

        let rootName = stat.name.isEmpty ? ((containerPath as NSString).lastPathComponent) : stat.name

        var walker = TarChildWalker(
            rootName: rootName,
            maxEntries: maximumEntriesPerListing,
            maxScanned: maximumEntriesScanned,
            maxAuxDataBytes: maximumAuxDataBytes)
        var responseHead: HTTPResponseHead?
        var errorBody = Data()
        var walkerFailure: Error?

        try engine.stream(
            "GET", "/containers/\(helperID!)/archive", query: [("path", containerPath)], timeout: timeout,
            onChunk: { chunk, head in
                guard (200..<300).contains(head.statusCode) else {
                    appendErrorBody(chunk, to: &errorBody)
                    return true
                }
                do {
                    try walker.feed(chunk)
                } catch {
                    walkerFailure = error
                    return false
                }
                // Stopping here once the walker has everything it needs closes the
                // connection early rather than reading a huge directory's full tar to
                // the end — the bound this module exists to enforce.
                return !walker.isFinished
            },
            onHead: { responseHead = $0 })

        if let walkerFailure {
            throw VolumeContentBrowserError.malformedArchive("\(walkerFailure)")
        }
        guard let responseHead else { throw VolumeContentBrowserError.noEngineResponse }
        guard (200..<300).contains(responseHead.statusCode) else {
            throw VolumeContentBrowserError.engineRejected(
                status: responseHead.statusCode,
                message: engineMessage(from: errorBody, fallbackStatus: responseHead.statusCode))
        }

        if let ownedHelperID = helperID {
            if let firstFailure = removeOwnedHelper(on: engine, id: ownedHelperID),
                let retryFailure = removeOwnedHelper(on: engine, id: ownedHelperID)
            {
                throw VolumeContentBrowserError.helperCleanupFailed("\(firstFailure); retry: \(retryFailure)")
            }
            helperID = nil
        }

        return VolumeContentListing(
            volumeName: volumeName,
            path: normalizedPath,
            entries: sortedEntries(walker.children),
            isTruncated: walker.isTruncated,
            rejectedEntryCount: walker.rejectedCount)
    }

    /// Directories first, then everything else; each group alphabetical. Pure and
    /// separately testable from the tar walk, since it is presentation, not parsing.
    static func sortedEntries(_ entries: [VolumeContentEntry]) -> [VolumeContentEntry] {
        entries.sorted { lhs, rhs in
            let lhsIsDirectory = lhs.kind == .directory
            let rhsIsDirectory = rhs.kind == .directory
            if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Joins a listed child's validated `name` onto an already-normalized `parentPath`.
    /// Callers building the next `list(path:)` request from a previous listing's own
    /// entries should use this rather than string concatenation, so the join is
    /// re-validated by the same rules the top-level path is.
    public static func childPath(of parentPath: String, name: String) throws -> String {
        guard isSafeChildName(name) else { throw VolumeContentBrowserError.invalidPath }
        let joined = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        return try normalize(path: joined)
    }

    // MARK: - Path stat

    struct ContainerPathStat: Equatable {
        let name: String
        let size: Int64
        let mode: UInt32
        let mtime: Date?
        let linkTarget: String

        /// Go's `os.ModeDir`: the top bit of the reported `os.FileMode`.
        var isDirectory: Bool { mode & 0x8000_0000 != 0 }
        /// Go's `os.ModeSymlink`: bit 27 (`1 << (32 - 1 - 4)`).
        var isSymlink: Bool { mode & 0x0800_0000 != 0 }
    }

    /// Decodes the base64 JSON `X-Docker-Container-Path-Stat` header
    /// (`{"name","size","mode","mtime","linkTarget"}`).
    static func decodePathStat(_ headerValue: String) throws -> ContainerPathStat {
        guard headerValue.utf8.count <= maximumStatHeaderBytes,
            let raw = Data(base64Encoded: headerValue)
        else {
            throw VolumeContentBrowserError.malformedArchive("path-stat header was not valid base64")
        }
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw VolumeContentBrowserError.malformedArchive("path-stat header was not a JSON object")
        }
        guard let name = object["name"] as? String else {
            throw VolumeContentBrowserError.malformedArchive("path-stat header is missing name")
        }
        let size = (object["size"] as? NSNumber)?.int64Value ?? 0
        let mode = (object["mode"] as? NSNumber)?.uint32Value ?? 0
        let linkTarget = object["linkTarget"] as? String ?? ""
        let mtime = (object["mtime"] as? String).flatMap(parseTimestamp)
        return ContainerPathStat(name: name, size: size, mode: mode, mtime: mtime, linkTarget: linkTarget)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: text)
    }

    // MARK: - Path validation

    /// `/`, or an absolute path with no empty, `.`, or `..` segment and no control
    /// character — the same discipline `isSafeChildName` applies to one component,
    /// generalized to the whole request path this module accepts as a parameter.
    static func normalize(path rawPath: String) throws -> String {
        guard rawPath.utf8.count <= 4_096, rawPath.hasPrefix("/") else {
            throw VolumeContentBrowserError.invalidPath
        }
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        for segment in segments {
            guard isSafeChildName(String(segment)) else { throw VolumeContentBrowserError.invalidPath }
        }
        guard !segments.isEmpty else { return "/" }
        return "/" + segments.joined(separator: "/")
    }

    /// One path component: nonempty, not `.`/`..`, no `/`, no control character, and
    /// bounded to a normal filename length. This is the exact gate a tar entry's name
    /// must also pass before this browser will list it as a child — see the file header.
    static func isSafeChildName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else { return false }
        guard !name.contains("/") else { return false }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: - Helper lifecycle (shared shape with VolumeArchiveExporter)

    private static func alreadyLocalHelperImage(on engine: EngineClient) throws -> String? {
        let images = try engine.jsonArray("GET", "/images/json", timeout: 15)
        for image in images {
            if let tags = JSONRead.array(image, "RepoTags") as? [String],
                let first = tags.first, first != "<none>:<none>"
            {
                return first
            }
        }
        if let first = images.first, let id = JSONRead.string(first, "Id") {
            return id
        }
        return nil
    }

    private static func createStoppedReadOnlyHelper(
        on engine: EngineClient, image: String, volumeName: String
    ) throws -> String {
        let body: [String: Any] = [
            "Image": image,
            "Cmd": ["true"],
            "HostConfig": ["Binds": ["\(volumeName):/data:ro"]],
        ]
        let response = try engine.jsonObject("POST", "/containers/create", body: body, timeout: 30)
        guard let id = JSONRead.string(response, "Id"), !id.isEmpty else {
            throw EngineError.malformed("temporary volume browse helper create did not return an Id")
        }
        return id
    }

    private static func removeOwnedHelper(on engine: EngineClient, id: String) -> String? {
        do {
            let response = try engine.request(
                "DELETE", "/containers/\(id)", query: [("force", "1"), ("v", "1")], timeout: 30)
            guard response.isSuccess else {
                return sanitize(response.engineMessage)
            }
        } catch {
            return sanitize("\(error)")
        }
        return nil
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

    private static func appendErrorBody(_ chunk: Data, to destination: inout Data) {
        let limit = 8 * 1_024
        guard destination.count < limit else { return }
        destination.append(chunk.prefix(limit - destination.count))
    }

    private static func engineMessage(from body: Data, fallbackStatus: Int) -> String {
        let response = EngineResponse(status: fallbackStatus, headers: [:], body: body)
        return sanitize(response.engineMessage).prefix(512).description
    }

    private static func sanitize(_ message: String) -> String {
        message.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
    }
}

// MARK: - Incremental tar walk

/// Walks a `ustar`/GNU/PAX tar byte stream as it arrives and keeps only the entries that
/// are immediate children of `rootName` — the directory Docker rooted the archive at.
/// Every other entry's *data* is still consumed (tar is sequential; there is no way to
/// skip to "the next sibling" without reading through what comes first), but its bytes
/// are discarded as they arrive rather than held, so memory use stays bounded by whatever
/// one 512-byte header and one in-flight chunk cost regardless of how large a declared
/// entry size is.
struct TarChildWalker {

    /// A stream this walker refuses to keep reading. Both cases stop the walk rather
    /// than continue on data that can no longer be trusted to describe real entries.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// A header's own checksum did not match its bytes — the reader has lost the
        /// tar stream (a truncated/corrupted response, or a hostile one), and parsing
        /// further fields out of a block that failed this check would mean inventing
        /// entries rather than reading them.
        case badChecksum
        /// A numeric header field (currently only `size`) could not be read: either its
        /// octal ASCII was not octal ASCII, or its GNU base-256 encoding overflowed
        /// `Int64`. Continuing with a wrapped-around value risks treating file content
        /// as the next header and desyncing silently instead of stopping cleanly.
        case malformedNumericField(String)

        var description: String {
            switch self {
            case .badChecksum:
                return "a tar header failed its checksum"
            case .malformedNumericField(let field):
                return "a tar header's \(field) field could not be read"
            }
        }
    }

    private enum Phase: Equatable {
        case header
        case auxData(kind: AuxKind, size: Int, padded: Int)
        case skipData(remaining: Int)
    }

    private enum AuxKind: Equatable {
        case gnuLongName
        case gnuLongLink
        case paxExtended
        /// A `g` header applies to the whole archive, not the entry that follows it.
        /// Docker never writes one that changes a listing, so its bytes are still
        /// walked (to stay in sync with the stream) but never applied — a per-entry
        /// PAX override is not something a global header gets to become.
        case paxGlobal
    }

    private let rootName: String
    private let maxEntries: Int
    private let maxScanned: Int
    private let maxAuxDataBytes: Int

    private var buffer: [UInt8] = []
    private var phase: Phase = .header
    private var pendingLongName: String?
    private var pendingLongLink: String?
    private var pendingPaxOverrides: [String: String] = [:]

    private(set) var children: [VolumeContentEntry] = []
    private(set) var rejectedCount = 0
    private(set) var scannedCount = 0
    private(set) var isTruncated = false
    /// `true` once the walker has everything it can use, or has given up. The caller
    /// closes the connection once this is `true` rather than reading a whole huge
    /// directory to its end.
    private(set) var isFinished = false

    init(rootName: String, maxEntries: Int, maxScanned: Int, maxAuxDataBytes: Int) {
        self.rootName = rootName
        self.maxEntries = maxEntries
        self.maxScanned = maxScanned
        self.maxAuxDataBytes = maxAuxDataBytes
    }

    mutating func feed(_ data: Data) throws {
        guard !isFinished else { return }
        buffer.append(contentsOf: data)
        try drain()
    }

    private mutating func drain() throws {
        while !isFinished {
            switch phase {
            case .skipData(let remaining):
                let take = min(remaining, buffer.count)
                if take > 0 { buffer.removeFirst(take) }
                let left = remaining - take
                if left > 0 {
                    phase = .skipData(remaining: left)
                    return
                }
                phase = .header

            case .auxData(let kind, let size, let padded):
                guard buffer.count >= padded else { return }
                let content = Array(buffer[0..<size])
                buffer.removeFirst(padded)
                switch kind {
                case .gnuLongName:
                    // GNU writers declare the field's size *including* its NUL
                    // terminator. `TarFormat.cString` truncates at that byte on the
                    // raw bytes directly, rather than decoding to a `String` first and
                    // only then hunting for a NUL — which is what let that trailing
                    // byte survive into `isSafeChildName`'s control-character check and
                    // silently drop every real-world long-name entry.
                    pendingLongName = TarFormat.cString(content)
                case .gnuLongLink:
                    pendingLongLink = TarFormat.cString(content)
                case .paxExtended:
                    applyPaxRecords(content)
                case .paxGlobal:
                    break
                }
                phase = .header

            case .header:
                guard buffer.count >= 512 else { return }
                let header = Array(buffer[0..<512])
                buffer.removeFirst(512)

                if header.allSatisfy({ $0 == 0 }) {
                    // One (or the terminating pair of) all-zero blocks. Nothing further
                    // in the archive can be an immediate child; stop cleanly.
                    isFinished = true
                    return
                }

                scannedCount += 1
                if scannedCount > maxScanned {
                    isTruncated = true
                    isFinished = true
                    return
                }

                // A checksum failure means the reader has lost the stream — stop rather
                // than parse fields out of what is no longer a header block and invent
                // entries from it.
                guard Self.checksumMatches(header) else {
                    throw Failure.badChecksum
                }

                let parsed = try Self.parseHeader(header)
                let padded = Self.paddedSize(parsed.size)

                switch parsed.typeflag {
                case UInt8(ascii: "L"):  // GNU long name: data is the *next* entry's name
                    if parsed.size >= 0, parsed.size <= maxAuxDataBytes {
                        phase = .auxData(kind: .gnuLongName, size: parsed.size, padded: padded)
                    } else {
                        // Refuses to hold an implausibly large "long name" rather than
                        // buffering an attacker-chosen amount of data for it; the next
                        // entry simply keeps its literal ustar name instead.
                        phase = .skipData(remaining: padded)
                    }
                case UInt8(ascii: "K"):  // GNU long link: data is the *next* entry's link target
                    if parsed.size >= 0, parsed.size <= maxAuxDataBytes {
                        phase = .auxData(kind: .gnuLongLink, size: parsed.size, padded: padded)
                    } else {
                        phase = .skipData(remaining: padded)
                    }
                case UInt8(ascii: "x"):  // PAX extended header — applies to the next entry only
                    if parsed.size >= 0, parsed.size <= maxAuxDataBytes {
                        phase = .auxData(kind: .paxExtended, size: parsed.size, padded: padded)
                    } else {
                        phase = .skipData(remaining: padded)
                    }
                case UInt8(ascii: "g"):  // PAX global header — applies archive-wide, not per-entry
                    if parsed.size >= 0, parsed.size <= maxAuxDataBytes {
                        phase = .auxData(kind: .paxGlobal, size: parsed.size, padded: padded)
                    } else {
                        phase = .skipData(remaining: padded)
                    }
                default:
                    handleRegularEntry(parsed)
                    phase = .skipData(remaining: padded)
                }
            }
        }
    }

    private mutating func handleRegularEntry(_ parsed: ParsedHeader) {
        defer {
            pendingLongName = nil
            pendingLongLink = nil
            pendingPaxOverrides = [:]
        }
        var finalName = pendingLongName ?? parsed.name
        if let overridden = pendingPaxOverrides["path"] { finalName = overridden }
        if finalName.hasSuffix("/") { finalName.removeLast() }

        let components = finalName.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = components.first, String(first) == rootName else {
            // Not part of the directory this listing is rooted at — Docker's archiver
            // does not produce this, but a hostile or corrupted stream might.
            return
        }
        guard components.count == 2 else {
            // The root entry itself (`count == 1`) or a grandchild+ (`count > 2`) —
            // neither is an immediate child.
            return
        }
        let childName = String(components[1])
        guard VolumeContentBrowser.isSafeChildName(childName) else {
            rejectedCount += 1
            return
        }
        guard children.count < maxEntries else {
            isTruncated = true
            isFinished = true
            return
        }

        // GNU `K` (long link) beats the ustar `linkname` field the same way `L` beats
        // `name`; a PAX `linkpath` record, applied last, beats both.
        var linkTarget = pendingLongLink ?? parsed.linkname
        if let overridden = pendingPaxOverrides["linkpath"] { linkTarget = overridden }
        let kind = VolumeContentEntry.Kind(TarFormat.kind(forTypeflag: parsed.typeflag))
        if kind != .symlink { linkTarget = "" }

        children.append(
            VolumeContentEntry(
                name: childName,
                kind: kind,
                size: kind == .directory ? 0 : Int64(parsed.size),
                modificationDate: parsed.mtime,
                linkTarget: linkTarget.isEmpty ? nil : linkTarget))

        if children.count >= maxEntries {
            isTruncated = true
            isFinished = true
        }
    }

    /// Only `path` and `linkpath` are kept from a per-entry PAX header; anything else
    /// is parsed by `TarFormat.parsePaxRecords` (so the stream stays in sync) and
    /// discarded here.
    private mutating func applyPaxRecords(_ bytes: [UInt8]) {
        for record in TarFormat.parsePaxRecords(bytes) where record.key == "path" || record.key == "linkpath" {
            pendingPaxOverrides[record.key] = record.value
        }
    }

    private static func paddedSize(_ size: Int) -> Int {
        guard size > 0 else { return 0 }
        return ((size + 511) / 512) * 512
    }

    private struct ParsedHeader {
        let name: String
        let typeflag: UInt8
        let size: Int
        let mtime: Date?
        let linkname: String
    }

    private static func parseHeader(_ header: [UInt8]) throws -> ParsedHeader {
        let magic = string(header, 257, 6)
        let isUstar = magic.hasPrefix("ustar")

        var name = string(header, 0, 100)
        if isUstar {
            let prefix = string(header, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let typeflag = header[156]
        // A wrapped-around size is the dangerous case: it would make the walker treat
        // an entry's own content as the start of the next header, silently desyncing
        // rather than stopping. Refused rather than clamped.
        guard let rawSize = TarFormat.numericField(header[124..<136]), rawSize >= 0, rawSize <= Int64(Int.max)
        else {
            throw Failure.malformedNumericField("size")
        }
        let size = Int(rawSize)
        // An unreadable mtime is not dangerous the same way — it never drives how many
        // bytes get consumed — so it degrades to "unknown" rather than aborting the walk.
        let mtimeSeconds = TarFormat.numericField(header[136..<148]) ?? 0
        let mtime = mtimeSeconds > 0 ? Date(timeIntervalSince1970: Double(mtimeSeconds)) : nil
        let linkname = string(header, 157, 100)
        return ParsedHeader(name: name, typeflag: typeflag, size: size, mtime: mtime, linkname: linkname)
    }

    /// A fixed-width tar text field, NUL-terminated (`TarFormat.cString`), with any
    /// leftover ASCII whitespace also trimmed — defensive against a writer that pads a
    /// text field with spaces rather than NULs, which the ustar spec permits.
    private static func string(_ header: [UInt8], _ offset: Int, _ length: Int) -> String {
        TarFormat.cString(header[offset..<(offset + length)]).trimmingCharacters(in: .whitespaces)
    }

    /// The ustar header checksum: the field itself is treated as spaces while summing,
    /// and both the (correct) unsigned and the historical signed-byte interpretation are
    /// accepted, matching real-world writers. A mismatch means this block is not a tar
    /// header at all — the stream has been lost.
    static func checksumMatches(_ header: [UInt8]) -> Bool {
        TarFormat.checksumMatches(header)
    }
}
