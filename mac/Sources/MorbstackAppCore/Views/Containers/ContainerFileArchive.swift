// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Reading a container's filesystem through the one endpoint the Engine API gives us:
// `HEAD/GET /containers/{id}/archive?path=…`.
//
// Two facts about that endpoint shape everything below, and both were checked against
// a real engine (Docker 29.7.1, API 1.55) rather than taken from documentation:
//
//  1. **`HEAD` is a cheap stat.** It answers with `X-Docker-Container-Path-Stat`, a
//     base64 JSON document carrying `name`, `size`, `mode` (a Go `os.FileMode`, so the
//     kind lives in the high bits), `mtime` and `linkTarget`. It works on a *stopped*
//     container, which is why this browser does not need the container to be running
//     and does not need a shell, an `ls`, or an exec at all.
//
//  2. **`GET` returns the whole subtree, recursively, as one tar stream.** There is no
//     "list one level" request. Listing `/usr` means reading everything under `/usr`.
//     That is a property of the engine, not a choice made here, and it is why the scan
//     is budgeted and why a stopped scan reports itself as partial rather than
//     pretending to be a complete listing.
//
// The entry names in that tar are untrusted input from inside the container. A tar
// entry claiming to be `../../etc/passwd` is the classic bug in this exact shape, so
// every name is rebased against the requested path and rejected — never clamped,
// never sanitised into something else — if it does not land strictly beneath it.

import Foundation

// MARK: - Kinds

/// What a container path is, as far as the engine will tell us.
enum ContainerFileKind: String, Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case hardLink
    case characterDevice
    case blockDevice
    case fifo
    case socket
    case unknown

    /// The row glyph. Kind is never carried by colour alone.
    var symbolName: String {
        switch self {
        case .directory: return "folder"
        case .regularFile: return "doc"
        case .symbolicLink: return "arrow.turn.up.right"
        case .hardLink: return "doc.on.doc"
        case .characterDevice, .blockDevice: return "externaldrive"
        case .fifo: return "arrow.left.arrow.right"
        case .socket: return "network"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    /// Plain words, not a typeflag character.
    var displayName: String {
        switch self {
        case .directory: return "Folder"
        case .regularFile: return "File"
        case .symbolicLink: return "Symbolic link"
        case .hardLink: return "Hard link"
        case .characterDevice: return "Character device"
        case .blockDevice: return "Block device"
        case .fifo: return "Named pipe"
        case .socket: return "Socket"
        case .unknown: return "Unrecognised entry"
        }
    }

    /// Whether this kind's reported size is a count of content bytes.
    ///
    /// A directory's 4096 is its inode size and a symlink's is the length of the target
    /// string. Showing either as "the size of this thing" would be a confident number
    /// that means something else, so callers ask before formatting one.
    var sizeIsContentLength: Bool { self == .regularFile }
}

// MARK: - The stat header

/// Go's `os.FileMode` bit layout, which is what Docker puts in the stat header's
/// `mode` field. Only the bits this app reads are named.
enum GoFileMode {
    static let directory: UInt32 = 1 << 31
    static let symbolicLink: UInt32 = 1 << 27
    static let device: UInt32 = 1 << 26
    static let namedPipe: UInt32 = 1 << 25
    static let socket: UInt32 = 1 << 24
    static let characterDevice: UInt32 = 1 << 21
    static let irregular: UInt32 = 1 << 19
    static let permissionMask: UInt32 = 0o777

    static func kind(of mode: UInt32) -> ContainerFileKind {
        if mode & directory != 0 { return .directory }
        if mode & symbolicLink != 0 { return .symbolicLink }
        if mode & device != 0 { return mode & characterDevice != 0 ? .characterDevice : .blockDevice }
        if mode & namedPipe != 0 { return .fifo }
        if mode & socket != 0 { return .socket }
        if mode & irregular != 0 { return .unknown }
        return .regularFile
    }
}

/// The decoded `X-Docker-Container-Path-Stat` header.
struct ContainerPathStat: Equatable, Sendable {

    /// The base name the engine reports — `etc` for `/etc`, `/` for the root.
    var name: String
    /// Exactly what the engine said, in bytes. Read `kind.sizeIsContentLength` before
    /// presenting it as the size of a file's contents.
    var size: Int64
    /// The raw Go `os.FileMode`.
    var goMode: UInt32
    var modified: Date?
    /// The symlink target, when the path is a symlink. Never the empty string.
    var linkTarget: String?

    var kind: ContainerFileKind { GoFileMode.kind(of: goMode) }
    var permissions: UInt16 { UInt16(goMode & GoFileMode.permissionMask) }

    /// A hostile or broken engine cannot make this allocate: the header itself is
    /// length-capped before a single base64 byte is decoded.
    static let maximumHeaderBytes = 8 * 1024

    private struct Wire: Decodable {
        var name: String?
        var size: Int64?
        var mode: UInt32?
        var mtime: String?
        var linkTarget: String?
    }

    /// Decodes the raw header value. `nil` for anything that is not a base64 JSON
    /// document of the documented shape — the caller then says it could not read the
    /// path's details rather than inventing zeroes for them.
    static func decode(headerValue: String) -> ContainerPathStat? {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumHeaderBytes else { return nil }

        // Tolerate a peer that dropped the padding; `Data(base64Encoded:)` will not.
        var padded = trimmed
        let remainder = padded.utf8.count % 4
        if remainder != 0 { padded += String(repeating: "=", count: 4 - remainder) }

        guard let data = Data(base64Encoded: padded),
              let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { return nil }

        let link = wire.linkTarget.flatMap { $0.isEmpty ? nil : $0 }
        return ContainerPathStat(
            name: wire.name ?? "",
            size: wire.size ?? 0,
            goMode: wire.mode ?? 0,
            modified: wire.mtime.flatMap(LogLineAssembler.parseRFC3339),
            linkTarget: link)
    }
}

// MARK: - Tar

/// One header record from the archive stream. The `name` is exactly what the archive
/// claimed; nothing has validated it yet.
struct ContainerTarEntry: Equatable, Sendable {
    var name: String
    var kind: ContainerFileKind
    /// The header's size field. Only meaningful as a content length for a regular file.
    var size: Int64
    var permissions: UInt16
    var modified: Date?
    var linkTarget: String?
}

/// What the reader produces, in stream order.
enum ContainerTarEvent: Equatable, Sendable {
    case entry(ContainerTarEntry)
    /// Content bytes belonging to the most recent `.entry`. Only produced when the
    /// reader was asked to capture payload.
    case payload(Data)
    case endOfArchive
}

/// An incremental ustar/PAX/GNU header reader.
///
/// Deliberately not a tar *extractor*: it walks headers and, unless asked otherwise,
/// discards content bytes without ever holding them. That is what makes listing a
/// 40 MB `/etc` or a 4 GB `/usr` a bounded-memory operation rather than a download.
///
/// The formats it has to survive, in the order they bite:
///
///  - **ustar with a `prefix` field.** Docker's writer splits a path longer than 100
///    bytes across `prefix` + `name`. Ignoring `prefix` silently truncates deep paths
///    into wrong, shallower ones — a listing that looks fine and is wrong.
///  - **PAX extended headers** (`x`) for the paths, sizes and times that do not fit
///    ustar at all. Anything under `node_modules` will produce these.
///  - **GNU long name/link** (`L`, `K`), which older writers use for the same purpose.
///  - **base-256 numeric fields**, which is how any size above 8 GB is encoded.
struct ContainerTarHeaderReader {

    static let blockSize = 512
    /// The largest extended-header payload that will ever be buffered. A PAX record is
    /// a few hundred bytes in practice; this is the wall that keeps a malformed length
    /// from turning into an allocation.
    static let maximumExtendedRecordBytes = 1 << 20

    enum Failure: Error, Equatable {
        /// The stream stopped looking like a tar archive. Carries a short reason for
        /// the sentence the user sees, not an error code.
        case malformedArchive(String)
    }

    /// When true, regular-file content is emitted as `.payload` events instead of being
    /// skipped. Only the single-file read paths turn this on.
    var capturesPayload = false

    private var buffer: [UInt8] = []
    private var skipRemaining: Int64 = 0
    private var payloadRemaining: Int64 = 0
    private var collecting: Collecting?
    private var pendingName: String?
    private var pendingLinkName: String?
    private var pendingSize: Int64?
    private var pendingModified: Date?
    private var zeroBlockRun = 0

    private(set) var isComplete = false
    /// Body bytes consumed from the wire, headers included. Progress reporting only.
    private(set) var bytesRead: Int64 = 0

    private struct Collecting {
        var kind: Kind
        var remaining: Int
        var padding: Int
        var bytes: [UInt8]

        enum Kind { case paxExtended, paxGlobal, gnuLongName, gnuLongLink }
    }

    init(capturesPayload: Bool = false) {
        self.capturesPayload = capturesPayload
    }

    /// Feeds the next slice of the response body.
    ///
    /// - Throws: ``Failure/malformedArchive(_:)`` when a header fails its own checksum
    ///   or declares a nonsensical length. Stopping is the honest response: a desynced
    ///   tar reader invents entries.
    mutating func feed(_ data: Data) throws -> [ContainerTarEvent] {
        guard !isComplete else { return [] }
        bytesRead += Int64(data.count)

        var input = data
        // The hot path: most of an archive is file content nobody asked for. Dropping
        // it straight off the incoming slice keeps it out of `buffer` entirely.
        //
        // Only when there is no payload still owed. Skipping first while a capture is
        // in flight eats the very bytes the caller asked for, which is exactly what it
        // did before `payloadRemaining` joined this condition.
        if buffer.isEmpty && payloadRemaining == 0 && skipRemaining > 0 {
            let take = min(Int64(input.count), skipRemaining)
            skipRemaining -= take
            input = input.dropFirst(Int(take))
            if input.isEmpty { return [] }
        }

        var events: [ContainerTarEvent] = []
        buffer.append(contentsOf: input)
        var cursor = 0

        loop: while !isComplete {
            let available = buffer.count - cursor

            if payloadRemaining > 0 {
                guard available > 0 else { break loop }
                let take = Int(min(Int64(available), payloadRemaining))
                events.append(.payload(Data(buffer[cursor..<(cursor + take)])))
                cursor += take
                payloadRemaining -= Int64(take)
                continue loop
            }

            if skipRemaining > 0 {
                guard available > 0 else { break loop }
                let take = Int(min(Int64(available), skipRemaining))
                cursor += take
                skipRemaining -= Int64(take)
                continue loop
            }

            if var pending = collecting {
                guard available > 0 else { break loop }
                let want = pending.remaining + pending.padding
                let take = min(available, want)
                let contentTake = min(take, pending.remaining)
                if contentTake > 0 {
                    pending.bytes.append(contentsOf: buffer[cursor..<(cursor + contentTake)])
                    pending.remaining -= contentTake
                }
                pending.padding -= (take - contentTake)
                cursor += take
                if pending.remaining == 0 && pending.padding == 0 {
                    collecting = nil
                    applyExtended(pending)
                } else {
                    collecting = pending
                }
                continue loop
            }

            guard available >= Self.blockSize else { break loop }
            let block = Array(buffer[cursor..<(cursor + Self.blockSize)])
            cursor += Self.blockSize

            if block.allSatisfy({ $0 == 0 }) {
                zeroBlockRun += 1
                if zeroBlockRun >= 2 {
                    isComplete = true
                    events.append(.endOfArchive)
                }
                continue loop
            }
            zeroBlockRun = 0

            let parsed = try Self.parseHeader(block)

            switch parsed.typeflag {
            case UInt8(ascii: "x"), UInt8(ascii: "X"):
                try beginCollecting(.paxExtended, size: parsed.size)
            case UInt8(ascii: "g"):
                try beginCollecting(.paxGlobal, size: parsed.size)
            case UInt8(ascii: "L"):
                try beginCollecting(.gnuLongName, size: parsed.size)
            case UInt8(ascii: "K"):
                try beginCollecting(.gnuLongLink, size: parsed.size)
            default:
                let kind = Self.kind(forTypeflag: parsed.typeflag)
                let name = pendingName ?? parsed.name
                let link = pendingLinkName ?? parsed.linkName
                let size = pendingSize ?? parsed.size
                let modified = pendingModified ?? parsed.modified
                pendingName = nil
                pendingLinkName = nil
                pendingSize = nil
                pendingModified = nil

                events.append(
                    .entry(
                        ContainerTarEntry(
                            name: name,
                            kind: kind,
                            size: size,
                            permissions: parsed.permissions,
                            modified: modified,
                            linkTarget: link.isEmpty ? nil : link)))

                // Only a regular file carries content. Following a size field on a
                // symlink or directory entry is how a reader desyncs on archives that
                // set one; Go's own reader ignores it for the same reason.
                if kind == .regularFile && size > 0 {
                    guard size <= Int64.max - Int64(Self.blockSize) else {
                        throw Failure.malformedArchive("an entry declared an impossible length")
                    }
                    let padded =
                        ((size + Int64(Self.blockSize) - 1) / Int64(Self.blockSize))
                        * Int64(Self.blockSize)
                    if capturesPayload {
                        payloadRemaining = size
                        skipRemaining = padded - size
                    } else {
                        skipRemaining = padded
                    }
                }
            }
        }

        if cursor > 0 { buffer.removeFirst(cursor) }
        return events
    }

    private mutating func beginCollecting(_ kind: Collecting.Kind, size: Int64) throws {
        guard size >= 0, size <= Int64(Self.maximumExtendedRecordBytes) else {
            throw Failure.malformedArchive("an extended header declared an unreasonable length")
        }
        let length = Int(size)
        let padded = ((length + Self.blockSize - 1) / Self.blockSize) * Self.blockSize
        collecting = Collecting(kind: kind, remaining: length, padding: padded - length, bytes: [])
    }

    private mutating func applyExtended(_ collected: Collecting) {
        switch collected.kind {
        case .paxGlobal:
            // A global header applies to the whole archive; Docker writes nothing here
            // that changes a listing, so it is read and dropped.
            return
        case .gnuLongName:
            pendingName = Self.cString(collected.bytes[...])
        case .gnuLongLink:
            pendingLinkName = Self.cString(collected.bytes[...])
        case .paxExtended:
            for (key, value) in Self.parsePaxRecords(collected.bytes) {
                switch key {
                case "path": pendingName = value
                case "linkpath": pendingLinkName = value
                case "size": pendingSize = Int64(value)
                case "mtime": pendingModified = Self.paxTime(value)
                default: continue
                }
            }
        }
    }

    /// PAX records are `"%d %s=%s\n"`, where the decimal prefix is the length of the
    /// whole record including itself.
    static func parsePaxRecords(_ bytes: [UInt8]) -> [(String, String)] {
        var records: [(String, String)] = []
        var index = 0
        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: UInt8(ascii: " ")) else { break }
            let digits = String(decoding: bytes[index..<space], as: UTF8.self)
            guard let length = Int(digits), length > 0,
                  index + length <= bytes.count, space + 1 <= index + length
            else { break }
            var end = index + length
            // The record ends in a newline; tolerate its absence rather than dropping
            // the record.
            if end > space + 1, bytes[end - 1] == UInt8(ascii: "\n") { end -= 1 }
            let body = String(decoding: bytes[(space + 1)..<end], as: UTF8.self)
            if let equals = body.firstIndex(of: "=") {
                records.append(
                    (String(body[body.startIndex..<equals]), String(body[body.index(after: equals)...])))
            }
            index += length
        }
        return records
    }

    /// PAX times are decimal seconds since the epoch, optionally fractional.
    static func paxTime(_ value: String) -> Date? {
        guard let seconds = Double(value), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    struct ParsedHeader: Equatable {
        var name: String
        var linkName: String
        var size: Int64
        var permissions: UInt16
        var modified: Date?
        var typeflag: UInt8
    }

    static func parseHeader(_ block: [UInt8]) throws -> ParsedHeader {
        guard block.count == blockSize else {
            throw Failure.malformedArchive("the archive ended in the middle of an entry")
        }
        guard checksumMatches(block) else {
            throw Failure.malformedArchive("the archive stream stopped matching the tar format")
        }

        let magic = String(decoding: block[257..<262], as: UTF8.self)
        var name = cString(block[0..<100])
        if magic == "ustar" {
            let prefix = cString(block[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        guard let size = numericField(block[124..<136]), size >= 0 else {
            throw Failure.malformedArchive("an entry declared an unreadable length")
        }
        let mode = numericField(block[100..<108]).map { UInt16(truncatingIfNeeded: $0) } ?? 0
        let mtime = numericField(block[136..<148]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return ParsedHeader(
            name: name,
            linkName: cString(block[157..<257]),
            size: size,
            permissions: mode & 0o7777,
            modified: mtime,
            typeflag: block[156])
    }

    /// The ustar header checksum, accepting both the unsigned and the historical signed
    /// interpretation. A mismatch means the reader has lost the stream, which is a real
    /// failure rather than something to paper over with a best guess.
    static func checksumMatches(_ block: [UInt8]) -> Bool {
        guard block.count == blockSize, let declared = numericField(block[148..<156]) else {
            return false
        }
        var unsigned = 0
        var signed = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return declared == Int64(unsigned) || declared == Int64(signed)
    }

    /// Tar numerics are NUL/space-padded ASCII octal, except when the high bit of the
    /// first byte is set — then the field is big-endian base 256, which is how sizes
    /// above 8 GB and times after 2242 are written.
    static func numericField(_ field: ArraySlice<UInt8>) -> Int64? {
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            var value = Int64(first & 0x7F)
            for byte in field.dropFirst() {
                guard value <= (Int64.max >> 8) else { return nil }
                value = (value << 8) | Int64(byte)
            }
            return value
        }
        let text = String(decoding: field, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if text.isEmpty { return 0 }
        guard text.allSatisfy({ $0.isASCII && ("0"..."7").contains($0) }) else { return nil }
        return Int64(text, radix: 8)
    }

    static func cString(_ field: ArraySlice<UInt8>) -> String {
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }

    static func kind(forTypeflag typeflag: UInt8) -> ContainerFileKind {
        switch typeflag {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): return .regularFile
        case UInt8(ascii: "1"): return .hardLink
        case UInt8(ascii: "2"): return .symbolicLink
        case UInt8(ascii: "3"): return .characterDevice
        case UInt8(ascii: "4"): return .blockDevice
        case UInt8(ascii: "5"): return .directory
        case UInt8(ascii: "6"): return .fifo
        default: return .unknown
        }
    }
}

// MARK: - Paths

/// Path arithmetic for container-side absolute paths.
///
/// Every limit here matches the ones the guest protocol review settled on
/// (`docs/audit/INPUT-VALIDATION-REVIEW.md`): no empty, `.` or `..` components, no NUL,
/// components capped at 255 bytes, whole paths at 4096. Rejection is the only response;
/// nothing is repaired into a different path than the one that was claimed.
enum ContainerFilePath {

    static let maximumPathBytes = 4096
    static let maximumComponentBytes = 255

    /// Canonicalises a path a person typed. `nil` when it is not an absolute container
    /// path this app is willing to send to the engine.
    static func normalizeTyped(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }
        guard trimmed.utf8.count <= maximumPathBytes else { return nil }
        guard !trimmed.utf8.contains(0) else { return nil }

        var components: [String] = []
        for piece in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(piece)
            // A typed `.` is harmless, but `..` would mean this app resolved a path the
            // engine may resolve differently. Refuse instead of guessing.
            if component == "." { continue }
            guard component != ".." else { return nil }
            guard component.utf8.count <= maximumComponentBytes else { return nil }
            components.append(component)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// The enclosing directory, or `nil` at the root.
    static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// The display name of a path: its last component, or `/` for the root.
    static func displayName(of path: String) -> String {
        guard path != "/" else { return "/" }
        return String(path.split(separator: "/", omittingEmptySubsequences: true).last ?? "/")
    }

    /// Every path from `/` down to `path`, root first.
    static func ancestry(of path: String) -> [String] {
        var result = ["/"]
        var current = "/"
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            current = current == "/" ? "/\(piece)" : "\(current)/\(piece)"
            result.append(current)
        }
        return result
    }

    /// Joins a validated relative remainder onto a directory.
    static func join(_ directory: String, _ relative: String) -> String {
        guard !relative.isEmpty else { return directory }
        return directory == "/" ? "/" + relative : directory + "/" + relative
    }

    /// Resolves a symlink target the way the guest kernel would: an absolute target
    /// stands alone, a relative one resolves against the link's own directory.
    /// `nil` when the result is not a path this app will ask the engine about.
    static func resolveLinkTarget(_ target: String, from linkPath: String) -> String? {
        guard !target.isEmpty, !target.utf8.contains(0) else { return nil }
        if target.hasPrefix("/") { return normalizeTyped(target) }
        guard let directory = parent(of: linkPath) else { return nil }

        var components = directory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for piece in target.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(piece)
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }  // `..` at `/` stays at `/`
                continue
            }
            guard component.utf8.count <= maximumComponentBytes else { return nil }
            components.append(component)
        }
        let joined = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        return joined.utf8.count <= maximumPathBytes ? joined : nil
    }

    /// Why an archive entry name was refused. These are diagnostics for tests and for
    /// the scan's own "N entries were not listed" count, never a sentence shown as-is.
    enum Rejection: Error, Equatable {
        case outsideRequestedPath
        case relativeComponent
        case emptyComponent
        case containsNUL
        case componentTooLong
        case pathTooLong
    }

    /// Rebases one tar entry name onto the absolute path that was requested.
    ///
    /// The engine names entries relative to the *base* of the requested path: asking
    /// for `/etc` gives `etc/`, `etc/hosts`; asking for `/` gives `/`, `/bin/sh`;
    /// asking for `/etc/hostname` gives a single `hostname`. All three were confirmed
    /// against a live engine.
    ///
    /// - Returns: the absolute container path the entry describes, or the reason it was
    ///   refused. A refusal is never turned into a nearby path that *is* acceptable —
    ///   that is how a traversal entry ends up listed as though it were somebody's file.
    static func absolutePath(
        forEntryName entryName: String,
        requestedPath: String
    ) -> Result<String, Rejection> {
        guard !entryName.utf8.contains(0), !requestedPath.utf8.contains(0) else {
            return .failure(.containsNUL)
        }

        // A trailing `/` marks a directory entry; the root's own entry is *named* `/`,
        // so stripping unconditionally would erase it.
        var name = entryName
        while name.count > 1 && name.hasSuffix("/") { name.removeLast() }

        let remainder: String
        if requestedPath == "/" {
            // The root archive prefixes every entry with `/` itself.
            guard name.hasPrefix("/") else { return .failure(.outsideRequestedPath) }
            remainder = String(name.dropFirst())
        } else {
            let base = displayName(of: requestedPath)
            if name == base {
                remainder = ""
            } else if name.hasPrefix(base + "/") {
                remainder = String(name.dropFirst(base.count + 1))
            } else {
                return .failure(.outsideRequestedPath)
            }
        }

        if remainder.isEmpty { return .success(requestedPath) }

        // Splitting without omitting empties is what catches `etc//hosts` and a
        // remainder that is itself absolute: both produce an empty component.
        for piece in remainder.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(piece)
            if component.isEmpty { return .failure(.emptyComponent) }
            if component == "." || component == ".." { return .failure(.relativeComponent) }
            if component.utf8.count > maximumComponentBytes { return .failure(.componentTooLong) }
        }

        let absolute = join(requestedPath, remainder)
        guard absolute.utf8.count <= maximumPathBytes else { return .failure(.pathTooLong) }
        return .success(absolute)
    }
}

// MARK: - Entries

/// One row in the browser: a path the engine described, and only what it described.
struct ContainerFileEntry: Identifiable, Hashable, Sendable {

    var path: String
    var name: String
    var kind: ContainerFileKind
    /// Content bytes, for the kinds where the engine's size field means that. `nil`
    /// everywhere else, so nothing downstream can print a directory's inode size as
    /// though it were the size of its contents.
    var size: Int64?
    var modified: Date?
    var permissions: UInt16?
    var linkTarget: String?

    var id: String { path }

    init(
        path: String,
        kind: ContainerFileKind,
        size: Int64? = nil,
        modified: Date? = nil,
        permissions: UInt16? = nil,
        linkTarget: String? = nil
    ) {
        self.path = path
        self.name = ContainerFilePath.displayName(of: path)
        self.kind = kind
        self.size = kind.sizeIsContentLength ? size : nil
        self.modified = modified
        self.permissions = permissions
        self.linkTarget = linkTarget
    }

    init(path: String, entry: ContainerTarEntry) {
        self.init(
            path: path,
            kind: entry.kind,
            size: entry.size,
            modified: entry.modified,
            permissions: entry.permissions,
            linkTarget: entry.linkTarget)
    }

    init(path: String, stat: ContainerPathStat) {
        self.init(
            path: path,
            kind: stat.kind,
            size: stat.size,
            modified: stat.modified,
            permissions: stat.permissions,
            linkTarget: stat.linkTarget)
    }

    /// Finder's order: folders first, then a natural-language name comparison so
    /// `file10` sorts after `file9`.
    static func isOrderedBefore(_ lhs: ContainerFileEntry, _ rhs: ContainerFileEntry) -> Bool {
        let lhsIsDirectory = lhs.kind == .directory
        let rhsIsDirectory = rhs.kind == .directory
        if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.path < rhs.path
    }

    /// Inserts into an already-sorted array, keeping it sorted. The scan appends
    /// thousands of entries into hundreds of directories; re-sorting each one on every
    /// append is the version of this that stutters.
    static func insertSorted(_ entry: ContainerFileEntry, into entries: inout [ContainerFileEntry]) {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if isOrderedBefore(entries[middle], entry) { low = middle + 1 } else { high = middle }
        }
        entries.insert(entry, at: low)
    }
}
