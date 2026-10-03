// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A local, current-engine image archive export. This is intentionally narrower
// than migration: it writes a Docker-save-compatible tar to a user-selected host
// location, never contacts a registry, reads Docker configuration, or mutates the
// engine.

import Darwin
import Foundation
import MorbstackKit

/// A completed export from Morbstack's current local Docker Engine.
public struct ImageArchiveExportResult: Sendable, Equatable {
    public let reference: String
    public let destination: URL
    public let bytes: Int64
    /// The one Docker Engine request used by the export. The image reference is sent
    /// as a query value, rather than interpolated into a URL path component.
    public let engineRequest: String

    public init(reference: String, destination: URL, bytes: Int64, engineRequest: String) {
        self.reference = reference
        self.destination = destination
        self.bytes = bytes
        self.engineRequest = engineRequest
    }
}

/// A byte count reported while an archive is being streamed. Docker may omit a content
/// length for this endpoint, in which case `totalBytes` stays `nil` and a caller must
/// show only the actual bytes written rather than inventing a completion percentage.
public struct ImageArchiveExportProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let totalBytes: Int64?

    public init(bytesWritten: Int64, totalBytes: Int64?) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
    }
}

/// Errors whose wording is safe for a CLI. The selected path is intentionally not
/// echoed here: a caller may have supplied control characters, and presentation is
/// responsible for rendering such a path safely.
public enum ImageArchiveExportError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidImageReference
    case invalidOutputURL
    case outputDirectoryUnavailable
    case outputIsMorbstackOwned
    case outputIsDirectory
    case outputAlreadyExists
    case stagingFileUnavailable
    case archiveWasEmpty
    case cancelled
    case writeFailed
    case commitFailed
    case noEngineResponse
    case engineRejected(status: Int, message: String)

    public var description: String {
        switch self {
        case .invalidImageReference:
            return "image reference must be a nonempty Docker image name or ID"
        case .invalidOutputURL:
            return "--output must name a file path"
        case .outputDirectoryUnavailable:
            return "the output directory does not exist or is not a directory"
        case .outputIsMorbstackOwned:
            return "refusing to write an archive inside Morbstack-owned data"
        case .outputIsDirectory:
            return "--output names a directory, not an archive file"
        case .outputAlreadyExists:
            return "the output file already exists; pass --replace to replace it atomically"
        case .stagingFileUnavailable:
            return "could not create a private staging file beside the requested output"
        case .archiveWasEmpty:
            return "the Docker Engine returned an empty image archive"
        case .cancelled:
            return "image archive export was cancelled; no archive was saved"
        case .writeFailed:
            return "could not write the image archive to the staging file"
        case .commitFailed:
            return "could not atomically commit the completed image archive"
        case .noEngineResponse:
            return "the Docker Engine closed the image export without a response"
        case .engineRejected(let status, let message):
            return "docker engine returned \(status): \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// Exports exactly one already-local image as a Docker archive.
///
/// The only Engine API call is `GET /images/get?names=<reference>`. Docker documents
/// this as an archive of the selected local image and its parents. It is not an image
/// pull, inspect, load, tag, delete, container operation, registry request, or
/// credentials operation. The destination becomes visible only after the complete
/// 2xx response has been written and fsynced to a private sibling staging file.
public enum ImageArchiveExporter {

    /// Streams an image archive from Morbstack's current local Engine to `output`.
    ///
    /// `output` must have an existing parent directory and must not be under
    /// `MorbPaths.root`, including through a symlink. A caller has to explicitly pass
    /// `replaceExisting` before an existing regular file can be atomically replaced.
    /// A failed request, short write, non-2xx response, or failed commit removes the
    /// private staging file and leaves the destination unchanged. Return `false` from
    /// `onProgress` to cancel at the next received body chunk; the stream closes and
    /// the private staging file is discarded rather than being published.
    @discardableResult
    public static func export(
        imageReference: String,
        to output: URL,
        replaceExisting: Bool,
        engine: EngineClient = EngineClient(),
        timeout: TimeInterval = 1_800,
        onProgress: ((ImageArchiveExportProgress) -> Bool)? = nil
    ) throws -> ImageArchiveExportResult {
        guard isSafeImageReference(imageReference) else {
            throw ImageArchiveExportError.invalidImageReference
        }
        let destination = try validateDestination(output, replaceExisting: replaceExisting)
        let staging: LocalArchiveStagingFile
        do {
            staging = try LocalArchiveStagingFile(destination: destination)
        } catch {
            throw translateOutputError(error)
        }
        var responseHead: HTTPResponseHead?
        var errorBody = Data()
        var writeFailure: Error?
        var cancellationRequested = false

        do {
            try engine.stream(
                "GET", "/images/get", query: [("names", imageReference)], timeout: timeout,
                onChunk: { chunk, head in
                    guard (200..<300).contains(head.statusCode) else {
                        appendErrorBody(chunk, to: &errorBody)
                        return true
                    }
                    do {
                        try staging.write(chunk)
                        let progress = ImageArchiveExportProgress(
                            bytesWritten: staging.bytes,
                            totalBytes: responseHead?.contentLength.map { Int64($0) })
                        if onProgress?(progress) == false {
                            cancellationRequested = true
                            return false
                        }
                        return true
                    } catch {
                        writeFailure = translateOutputError(error)
                        return false
                    }
                },
                onHead: { responseHead = $0 })

            if let writeFailure { throw writeFailure }
            if cancellationRequested { throw ImageArchiveExportError.cancelled }
            guard let responseHead else { throw ImageArchiveExportError.noEngineResponse }
            guard (200..<300).contains(responseHead.statusCode) else {
                throw ImageArchiveExportError.engineRejected(
                    status: responseHead.statusCode,
                    message: engineMessage(from: errorBody, fallbackStatus: responseHead.statusCode))
            }
            guard staging.bytes > 0 else { throw ImageArchiveExportError.archiveWasEmpty }
            do {
                try staging.commit(replaceExisting: replaceExisting)
            } catch {
                throw translateOutputError(error)
            }
            return ImageArchiveExportResult(
                reference: imageReference,
                destination: destination,
                bytes: staging.bytes,
                engineRequest: "GET /images/get?names=<image-reference>")
        } catch let error as ImageArchiveExportError {
            staging.discard()
            throw error
        } catch {
            staging.discard()
            throw error
        }
    }

    /// Performs the same conservative reference check before the API request. It is
    /// not a second Docker-name parser; the current engine remains authoritative for
    /// resolving tags and image IDs. Its purpose is to reject whitespace, control
    /// text, and URL/path delimiters that cannot belong in this CLI's one reference.
    private static func isSafeImageReference(_ reference: String) -> Bool {
        guard (1...1_024).contains(reference.utf8.count) else { return false }
        return reference.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x2F, 0x3A, 0x40, 0x5F:
                return true
            default:
                return false
            }
        }
    }

    private static func validateDestination(_ requested: URL, replaceExisting: Bool) throws -> URL {
        do {
            return try LocalArchiveOutput.validateDestination(
                requested,
                replaceExisting: replaceExisting)
        } catch {
            throw translateOutputError(error)
        }
    }

    private static func translateOutputError(_ error: Error) -> ImageArchiveExportError {
        guard let error = error as? LocalArchiveOutputError else {
            return .commitFailed
        }
        switch error {
        case .invalidOutputURL: return .invalidOutputURL
        case .outputDirectoryUnavailable: return .outputDirectoryUnavailable
        case .outputIsMorbstackOwned: return .outputIsMorbstackOwned
        case .outputIsDirectory: return .outputIsDirectory
        case .outputAlreadyExists: return .outputAlreadyExists
        case .stagingFileUnavailable: return .stagingFileUnavailable
        case .writeFailed: return .writeFailed
        case .commitFailed: return .commitFailed
        }
    }

    private static func appendErrorBody(_ chunk: Data, to destination: inout Data) {
        let limit = 8 * 1_024
        guard destination.count < limit else { return }
        destination.append(chunk.prefix(limit - destination.count))
    }

    private static func engineMessage(from body: Data, fallbackStatus: Int) -> String {
        let response = EngineResponse(status: fallbackStatus, headers: [:], body: body)
        return response.engineMessage.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined().prefix(512).description
    }
}

/// Destination failures shared by explicit local archive writers. They deliberately
/// contain no path text; a CLI or native sheet owns safe path presentation.
enum LocalArchiveOutputError: Error {
    case invalidOutputURL
    case outputDirectoryUnavailable
    case outputIsMorbstackOwned
    case outputIsDirectory
    case outputAlreadyExists
    case stagingFileUnavailable
    case writeFailed
    case commitFailed
}

/// The output half of every local archive export. It rejects Morbstack-owned paths
/// and applies one no-clobber/explicit-replace policy before a service starts an
/// Engine stream or creates a temporary helper container.
enum LocalArchiveOutput {

    static func validateDestination(_ requested: URL, replaceExisting: Bool) throws -> URL {
        guard requested.isFileURL else { throw LocalArchiveOutputError.invalidOutputURL }
        let manager = FileManager.default
        let standardized: URL
        if requested.path.hasPrefix("/") {
            standardized = requested.standardizedFileURL
        } else {
            standardized = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(requested.path, isDirectory: false)
                .standardizedFileURL
        }
        guard standardized.path != "/", !standardized.lastPathComponent.isEmpty else {
            throw LocalArchiveOutputError.invalidOutputURL
        }

        let outputDirectory = standardized.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalArchiveOutputError.outputDirectoryUnavailable
        }

        // Resolve both the parent (for a not-yet-created output) and the final path
        // (for an existing output symlink) before checking Morbstack's private root.
        let canonicalRoot = MorbPaths.root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalParent = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalNewOutput = canonicalParent.appendingPathComponent(standardized.lastPathComponent)
        let canonicalExistingOutput = standardized.resolvingSymlinksInPath()
        guard !isDescendant(standardized, of: canonicalRoot),
              !isDescendant(canonicalNewOutput, of: canonicalRoot),
              !isDescendant(canonicalExistingOutput, of: canonicalRoot)
        else {
            throw LocalArchiveOutputError.outputIsMorbstackOwned
        }

        var outputIsDirectory = ObjCBool(false)
        if manager.fileExists(atPath: standardized.path, isDirectory: &outputIsDirectory) {
            if outputIsDirectory.boolValue { throw LocalArchiveOutputError.outputIsDirectory }
            if !replaceExisting { throw LocalArchiveOutputError.outputAlreadyExists }
        }
        return standardized
    }

    /// The directory counterpart of ``validateDestination(_:replaceExisting:)``, used
    /// by ``ImageArchiveExporter/exportAll(to:replaceExisting:engine:onItem:)``. A
    /// directory export writes many files, so the one thing this validates up front —
    /// rather than once per file — is that the directory itself is not inside
    /// Morbstack-owned data. It does not require the directory to already exist: the
    /// caller creates it after this check passes.
    static func validateDirectoryDestination(_ requested: URL) throws -> URL {
        guard requested.isFileURL else { throw LocalArchiveOutputError.invalidOutputURL }
        let manager = FileManager.default
        let standardized: URL
        if requested.path.hasPrefix("/") {
            standardized = requested.standardizedFileURL
        } else {
            standardized = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(requested.path, isDirectory: true)
                .standardizedFileURL
        }
        guard standardized.path != "/" else { throw LocalArchiveOutputError.invalidOutputURL }

        let canonicalRoot = MorbPaths.root.standardizedFileURL.resolvingSymlinksInPath()
        // The directory may not exist yet, so there is nothing for
        // `resolvingSymlinksInPath` to resolve through; checking both the requested
        // path and its (possibly identical) resolved form matches
        // `validateDestination`'s same pre/post-symlink pair of checks.
        let resolved = standardized.resolvingSymlinksInPath()
        guard !isDescendant(standardized, of: canonicalRoot), !isDescendant(resolved, of: canonicalRoot) else {
            throw LocalArchiveOutputError.outputIsMorbstackOwned
        }
        return standardized
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" { return true }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

// MARK: - `morb export --all`

/// One image's outcome inside a `--all` directory export. A batch of many images must
/// not let one failure discard archives already written for every other image, so
/// this records success or failure per item rather than aborting the loop.
public struct ImageArchiveExportAllItem: Sendable, Equatable {
    public let reference: String
    public let result: ImageArchiveExportResult?
    public let error: String?

    public init(reference: String, result: ImageArchiveExportResult?, error: String?) {
        self.reference = reference
        self.result = result
        self.error = error
    }
}

public struct ImageArchiveExportAllResult: Sendable, Equatable {
    public let directory: URL
    public let items: [ImageArchiveExportAllItem]
    public let manifestPath: URL

    public init(directory: URL, items: [ImageArchiveExportAllItem], manifestPath: URL) {
        self.directory = directory
        self.items = items
        self.manifestPath = manifestPath
    }

    public var succeeded: [ImageArchiveExportAllItem] { items.filter { $0.result != nil } }
    public var failed: [ImageArchiveExportAllItem] { items.filter { $0.result == nil } }
}

extension ImageArchiveExporter {

    /// Exports every currently local tagged image (dangling, untagged images are
    /// excluded — the same default `morb migrate` uses) into `directory`: one
    /// Docker-save-compatible tar per image, plus a manifest that says exactly how a
    /// stock `docker load` restores them. This is deliberately not a new archive
    /// format or a single combined tar — each file goes through the same
    /// ``export(imageReference:to:replaceExisting:engine:timeout:onProgress:)`` this
    /// type already uses for one image, so it keeps that function's atomic per-file
    /// publish, no-clobber policy, and Morbstack-owned-path refusal. One image's
    /// export failing does not stop the rest; it is recorded and the loop continues.
    public static func exportAll(
        to directory: URL,
        replaceExisting: Bool,
        engine: EngineClient = EngineClient(),
        onItem: ((String) -> Void)? = nil
    ) throws -> ImageArchiveExportAllResult {
        let standardizedDirectory = try translatingOutputError { try LocalArchiveOutput.validateDirectoryDestination(directory) }
        do {
            try FileManager.default.createDirectory(at: standardizedDirectory, withIntermediateDirectories: true)
        } catch {
            throw ImageArchiveExportError.outputDirectoryUnavailable
        }

        let images = try engine.jsonArray("GET", "/images/json", query: [("all", "0")], timeout: 30)
        var references = Set<String>()
        for image in images {
            let tags = (image["RepoTags"] as? [String]) ?? []
            for tag in tags where tag != "<none>:<none>" {
                references.insert(tag)
            }
        }

        var items: [ImageArchiveExportAllItem] = []
        var usedFileNames = Set<String>()
        for reference in references.sorted() {
            onItem?(reference)
            let output = standardizedDirectory.appendingPathComponent(
                uniqueFileName(for: reference, avoiding: &usedFileNames), isDirectory: false)
            do {
                let result = try export(imageReference: reference, to: output, replaceExisting: replaceExisting, engine: engine)
                items.append(ImageArchiveExportAllItem(reference: reference, result: result, error: nil))
            } catch {
                items.append(ImageArchiveExportAllItem(reference: reference, result: nil, error: "\(error)"))
            }
        }

        let manifestPath = standardizedDirectory.appendingPathComponent("MANIFEST.txt", isDirectory: false)
        try writeManifest(items: items, destination: standardizedDirectory, to: manifestPath, replaceExisting: replaceExisting)

        return ImageArchiveExportAllResult(directory: standardizedDirectory, items: items, manifestPath: manifestPath)
    }

    private static func uniqueFileName(for reference: String, avoiding used: inout Set<String>) -> String {
        let base = sanitizedFileName(for: reference)
        var candidate = base + ".tar"
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix).tar"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func sanitizedFileName(for reference: String) -> String {
        let mapped = reference.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "0"..."9", "a"..."z", "A"..."Z", "-", ".", "_":
                return Character(scalar)
            default:
                return "_"
            }
        }
        let name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "image" : String(name.prefix(200))
    }

    private static func writeManifest(
        items: [ImageArchiveExportAllItem], destination: URL, to path: URL, replaceExisting: Bool
    ) throws {
        var lines = [
            "Morbstack image export (morb export --all)",
            "One Docker-save-compatible tar per image. Restore any of them with a",
            "stock Docker CLI — Morbstack is not required on the receiving machine:",
            "",
            "  docker load -i <file>.tar",
            "",
            "FILE\tIMAGE\tBYTES",
        ]
        for item in items {
            if let result = item.result {
                lines.append("\(result.destination.lastPathComponent)\t\(item.reference)\t\(result.bytes)")
            } else {
                lines.append("#FAILED\t\(item.reference)\t\(item.error ?? "unknown error")")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { throw ImageArchiveExportError.writeFailed }
        if replaceExisting {
            try? FileManager.default.removeItem(at: path)
        }
        guard FileManager.default.createFile(atPath: path.path, contents: data) else {
            throw ImageArchiveExportError.writeFailed
        }
    }

    private static func translatingOutputError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw translateOutputError(error)
        }
    }
}

/// A private sibling file with a single atomic commit path. The final destination is
/// not opened or truncated during download. Without `--replace`, `link(2)` supplies
/// an atomic no-clobber publish; with it, `rename(2)` atomically replaces the old file
/// only after the new bytes have been fsynced and closed.
final class LocalArchiveStagingFile {
    private let destination: URL
    private let temporary: URL
    private var descriptor: Int32?
    private var committed = false
    private(set) var bytes: Int64 = 0

    init(destination: URL) throws {
        self.destination = destination
        let directory = destination.deletingLastPathComponent()
        var selected: (URL, Int32)?
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(
                ".\(destination.lastPathComponent).morbstack-export-\(UUID().uuidString).partial",
                isDirectory: false)
            let descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if descriptor >= 0 {
                selected = (candidate, descriptor)
                break
            }
            if errno != EEXIST { break }
        }
        guard let selected else { throw LocalArchiveOutputError.stagingFileUnavailable }
        temporary = selected.0
        descriptor = selected.1
    }

    deinit { discard() }

    func write(_ data: Data) throws {
        guard let descriptor else { throw LocalArchiveOutputError.writeFailed }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        throw LocalArchiveOutputError.writeFailed
                    }
                }
            }
            bytes += Int64(data.count)
        } catch let error as LocalArchiveOutputError {
            throw error
        } catch {
            throw LocalArchiveOutputError.writeFailed
        }
    }

    func commit(replaceExisting: Bool) throws {
        guard let descriptor else { throw LocalArchiveOutputError.commitFailed }
        let syncSucceeded = Darwin.fsync(descriptor) == 0
        let closeSucceeded = Darwin.close(descriptor) == 0
        self.descriptor = nil
        guard syncSucceeded, closeSucceeded else { throw LocalArchiveOutputError.commitFailed }

        if replaceExisting {
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw LocalArchiveOutputError.commitFailed
            }
        } else {
            guard Darwin.link(temporary.path, destination.path) == 0 else {
                if errno == EEXIST { throw LocalArchiveOutputError.outputAlreadyExists }
                throw LocalArchiveOutputError.commitFailed
            }
            // `link` made the destination visible atomically. The old name is only a
            // private staging alias now, so cleanup cannot affect the published file.
            guard Darwin.unlink(temporary.path) == 0 else {
                // The archive itself is complete and visible. Keep that success rather
                // than falsely reporting a failed export solely because temp cleanup
                // lost a race with an unrelated filesystem event.
                committed = true
                return
            }
        }
        committed = true
    }

    func discard() {
        if let descriptor {
            _ = Darwin.close(descriptor)
            self.descriptor = nil
        }
        if !committed { _ = Darwin.unlink(temporary.path) }
    }
}
