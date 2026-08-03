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

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" { return true }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
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
