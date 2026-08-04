// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One explicit local Docker image archive reader. This is intentionally not a
// registry client, an archive inspector, a migration planner, or a general file
// upload API: it sends exactly the file a person selected to the current local
// Engine's documented image-load endpoint.

import Darwin
import Foundation

/// The archive filename forms the native document chooser offers for Docker image
/// loading. This is a chooser policy, not an archive parser: Docker remains
/// authoritative for validating the selected stream.
public enum ImageArchiveImportSelectionPolicy {
    /// Docker CLI accepts a tar archive whether uncompressed or compressed with gzip,
    /// bzip2, xz, or zstd. Keep aliases explicit because AppKit's content-type lookup
    /// is filename based for several of these formats.
    public static let supportedFilenameExtensions = [
        "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2", "tar.xz", "txz", "tar.zst", "tzst",
    ]

    public static func accepts(filename: String) -> Bool {
        let lowercasedName = filename.lowercased()
        return supportedFilenameExtensions.contains { lowercasedName.hasSuffix(".\($0)") }
    }
}

/// A stable POSIX file identity recorded during review and compared with the descriptor
/// that is actually streamed. A path can be atomically replaced without changing its
/// name or byte count, so size by itself is not a sufficient review boundary.
public struct ImageArchiveImportFileIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64

    init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

private struct ImageArchiveImportFileFacts {
    let bytes: Int64
    let identity: ImageArchiveImportFileIdentity
}

/// A selected local file whose current byte count is known before an image load starts.
///
/// The request deliberately records no inferred tags, manifest entries, or archive
/// format details. Docker is authoritative for interpreting the tar stream.
public struct ImageArchiveImportRequest: Sendable, Equatable, Identifiable {
    public let archiveURL: URL
    public let bytes: Int64
    public let fileIdentity: ImageArchiveImportFileIdentity

    public var id: URL { archiveURL }

    public init(archiveURL: URL) throws {
        guard archiveURL.isFileURL else { throw ImageArchiveImportError.invalidArchiveURL }

        do {
            let facts = try imageArchiveImportFileFacts(at: archiveURL)
            self.archiveURL = archiveURL
            self.bytes = facts.bytes
            self.fileIdentity = facts.identity
        } catch {
            throw ImageArchiveImportError.fromFileInspection(error)
        }
    }
}

/// A phase from a single streamed image load. Upload progress covers only bytes that
/// were actually written to Docker's socket. Once all source bytes are sent, Docker
/// can still unpack layers and register tags before it returns its result.
public enum ImageArchiveImportProgress: Sendable, Equatable {
    case uploading(bytesSent: Int64, totalBytes: Int64)
    case waitingForDocker(bytesSent: Int64, totalBytes: Int64)
}

/// The narrow result Morbstack can truthfully establish from `POST /images/load`.
/// It intentionally does not invent image names or tag preservation: the selected
/// archive may define zero, one, or many names, and Docker owns that interpretation.
public struct ImageArchiveImportResult: Sendable, Equatable {
    public let archiveURL: URL
    public let bytesSent: Int64
    public let engineStatus: Int
    public let engineRequest: String

    public init(archiveURL: URL, bytesSent: Int64, engineStatus: Int, engineRequest: String) {
        self.archiveURL = archiveURL
        self.bytesSent = bytesSent
        self.engineStatus = engineStatus
        self.engineRequest = engineRequest
    }
}

/// Failures whose wording is safe for the native document workflow. `cancelled` is
/// intentionally not a claim that Docker loaded nothing: it can have read a prefix
/// before the client closed its one-request connection.
public enum ImageArchiveImportError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidArchiveURL
    case archiveUnavailable
    case archiveIsNotAFile
    case archiveIsEmpty
    case archiveSizeChanged
    case archiveIdentityChanged
    case cancelled(bytesSent: Int64, totalBytes: Int64)
    case engineRejected(status: Int, message: String)
    case engineReportedFailure(String)

    public var description: String {
        switch self {
        case .invalidArchiveURL:
            return "choose a local image archive file"
        case .archiveUnavailable:
            return "the selected image archive is no longer available"
        case .archiveIsNotAFile:
            return "the selected image archive is not a regular file"
        case .archiveIsEmpty:
            return "the selected image archive is empty"
        case .archiveSizeChanged:
            return "the selected image archive size changed after review; choose it again before loading"
        case .archiveIdentityChanged:
            return "the selected image archive was replaced after review; choose it again before loading"
        case .cancelled(let bytesSent, let totalBytes):
            return "image archive upload was cancelled after \(bytesSent) of \(totalBytes) bytes; Docker may have received part of it"
        case .engineRejected(let status, let message):
            return "docker engine returned \(status): \(message)"
        case .engineReportedFailure(let message):
            return "docker engine reported an image-load error: \(message)"
        }
    }

    public var errorDescription: String? { description }

    fileprivate static func fromFileInspection(_ error: Error) -> Self {
        switch error {
        case ImageArchiveImportFileInspectionError.notARegularFile:
            return .archiveIsNotAFile
        case ImageArchiveImportFileInspectionError.empty:
            return .archiveIsEmpty
        default:
            return .archiveUnavailable
        }
    }
}

/// Streams one selected local archive to Docker's image-load endpoint.
///
/// The only Engine request is `POST /images/load?quiet=1` with a tar content type.
/// `quiet=1` asks Docker to suppress ordinary progress output; the current Engine
/// transport still reads its complete response before this service presents a bounded
/// error sentence. This service does not read `manifest.json`,
/// resolve names, pull or push images, contact a registry, or access Docker config or
/// credentials. It also does not promise that Docker preserved any particular tag.
public enum ImageArchiveImporter {
    public static let engineRequestDescription = "POST /images/load?quiet=1"

    @discardableResult
    public static func load(
        _ request: ImageArchiveImportRequest,
        engine: EngineClient = EngineClient(),
        timeout: TimeInterval = 1_800,
        onProgress: ((ImageArchiveImportProgress) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> ImageArchiveImportResult {
        // Review records size and POSIX identity. Open exactly once at the mutation
        // boundary, validate the opened descriptor against those facts, and hand that
        // same descriptor to the Engine client. This closes the former path-restat to
        // path-reopen race where a replacement could be streamed after review.
        let source = try ImageArchiveImportSource.open(reviewed: request)
        defer { try? source.handle.close() }

        var bytesSent: Int64 = 0
        var finishedSending = false
        do {
            let response = try engine.upload(
                "POST", "/images/load", query: [("quiet", "1")], from: source.handle,
                sourceURL: request.archiveURL, sourceSize: source.facts.bytes,
                contentType: "application/x-tar", timeout: timeout,
                onProgress: { sent in
                    bytesSent = sent
                    onProgress?(.uploading(bytesSent: sent, totalBytes: source.facts.bytes))
                },
                shouldContinue: { !(isCancelled?() ?? false) },
                onUploadComplete: {
                    finishedSending = true
                    onProgress?(.waitingForDocker(bytesSent: bytesSent, totalBytes: source.facts.bytes))
                })

            guard response.isSuccess else {
                throw ImageArchiveImportError.engineRejected(
                    status: response.status,
                    message: boundedEngineMessage(response.engineMessage))
            }
            if let reportedFailure = loadErrorMessage(in: response.text) {
                throw ImageArchiveImportError.engineReportedFailure(reportedFailure)
            }
            return ImageArchiveImportResult(
                archiveURL: request.archiveURL,
                bytesSent: bytesSent,
                engineStatus: response.status,
                engineRequest: engineRequestDescription)
        } catch {
            // Only cancellation while the request body is incomplete can close the
            // upload. Once all bytes are sent, the UI deliberately removes Cancel:
            // abandoning the response would make the load outcome unknowable.
            if !finishedSending, isCancelled?() == true {
                throw ImageArchiveImportError.cancelled(
                    bytesSent: bytesSent,
                    totalBytes: source.facts.bytes)
            }
            throw error
        }
    }

    private static func loadErrorMessage(in output: String) -> String? {
        // Docker sometimes returns an error record in an HTTP-success JSON-lines
        // stream. We do not decode archive metadata or derive tags from it; this only
        // makes an explicit Docker-reported error visible to the person who selected
        // the archive.
        guard output.contains("\"error\"") || output.contains("\"errorDetail\"") else {
            return nil
        }
        return boundedEngineMessage(output)
    }

    private static func boundedEngineMessage(_ message: String) -> String {
        let sanitized = message.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        return String(sanitized.prefix(512))
    }
}

private enum ImageArchiveImportFileInspectionError: Error {
    case unavailable
    case notARegularFile
    case empty
}

private func imageArchiveImportFileFacts(at url: URL) throws -> ImageArchiveImportFileFacts {
    var sourceStat = stat()
    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.stat(path, &sourceStat)
    }
    guard status == 0 else { throw ImageArchiveImportFileInspectionError.unavailable }
    return try imageArchiveImportFileFacts(from: sourceStat)
}

private func imageArchiveImportFileFacts(from handle: FileHandle) throws -> ImageArchiveImportFileFacts {
    var sourceStat = stat()
    guard Darwin.fstat(handle.fileDescriptor, &sourceStat) == 0 else {
        throw ImageArchiveImportFileInspectionError.unavailable
    }
    return try imageArchiveImportFileFacts(from: sourceStat)
}

private func imageArchiveImportFileFacts(from sourceStat: stat) throws -> ImageArchiveImportFileFacts {
    guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
        throw ImageArchiveImportFileInspectionError.notARegularFile
    }
    let bytes = Int64(sourceStat.st_size)
    guard bytes > 0 else { throw ImageArchiveImportFileInspectionError.empty }
    return ImageArchiveImportFileFacts(
        bytes: bytes,
        identity: ImageArchiveImportFileIdentity(
            device: UInt64(sourceStat.st_dev),
            inode: UInt64(sourceStat.st_ino)))
}

/// The single descriptor that has been checked against the review facts. Keeping it
/// open eliminates pathname re-resolution between review validation and upload.
private struct ImageArchiveImportSource {
    let handle: FileHandle
    let facts: ImageArchiveImportFileFacts

    static func open(reviewed request: ImageArchiveImportRequest) throws -> Self {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: request.archiveURL)
        } catch {
            throw ImageArchiveImportError.archiveUnavailable
        }

        do {
            let facts = try imageArchiveImportFileFacts(from: handle)
            guard facts.bytes == request.bytes else {
                try? handle.close()
                throw ImageArchiveImportError.archiveSizeChanged
            }
            guard facts.identity == request.fileIdentity else {
                try? handle.close()
                throw ImageArchiveImportError.archiveIdentityChanged
            }
            return Self(handle: handle, facts: facts)
        } catch let error as ImageArchiveImportError {
            throw error
        } catch {
            try? handle.close()
            throw ImageArchiveImportError.fromFileInspection(error)
        }
    }
}
