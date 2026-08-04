// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One explicit local Docker image archive reader. This is intentionally not a
// registry client, an archive inspector, a migration planner, or a general file
// upload API: it sends exactly the file a person selected to the current local
// Engine's documented image-load endpoint.

import Foundation

/// A selected local file whose current byte count is known before an image load starts.
///
/// The request deliberately records no inferred tags, manifest entries, or archive
/// format details. Docker is authoritative for interpreting the tar stream.
public struct ImageArchiveImportRequest: Sendable, Equatable, Identifiable {
    public let archiveURL: URL
    public let bytes: Int64

    public var id: URL { archiveURL }

    public init(archiveURL: URL) throws {
        guard archiveURL.isFileURL else { throw ImageArchiveImportError.invalidArchiveURL }

        let values: URLResourceValues
        do {
            values = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ImageArchiveImportError.archiveUnavailable
        }
        guard values.isRegularFile == true else { throw ImageArchiveImportError.archiveIsNotAFile }
        guard let bytes = values.fileSize, bytes > 0 else { throw ImageArchiveImportError.archiveIsEmpty }

        self.archiveURL = archiveURL
        self.bytes = Int64(bytes)
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
        case .cancelled(let bytesSent, let totalBytes):
            return "image archive upload was cancelled after \(bytesSent) of \(totalBytes) bytes; Docker may have received part of it"
        case .engineRejected(let status, let message):
            return "docker engine returned \(status): \(message)"
        case .engineReportedFailure(let message):
            return "docker engine reported an image-load error: \(message)"
        }
    }

    public var errorDescription: String? { description }
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
        // A person reviews the current file size in the native sheet. Refuse a changed
        // size instead of letting the displayed denominator become stale before the
        // request starts. This is deliberately not an identity/hash snapshot: a
        // same-size replacement remains a new selected-file risk the document flow
        // does not claim to detect. `EngineClient.upload` then opens and stats that
        // descriptor, so the Content-Length belongs to the actual open file rather
        // than its path.
        let currentRequest = try ImageArchiveImportRequest(archiveURL: request.archiveURL)
        guard currentRequest.bytes == request.bytes else {
            throw ImageArchiveImportError.archiveSizeChanged
        }

        var bytesSent: Int64 = 0
        var finishedSending = false
        do {
            let response = try engine.upload(
                "POST", "/images/load", query: [("quiet", "1")], from: request.archiveURL,
                contentType: "application/x-tar", timeout: timeout,
                onProgress: { sent in
                    bytesSent = sent
                    onProgress?(.uploading(bytesSent: sent, totalBytes: request.bytes))
                },
                shouldContinue: { !(isCancelled?() ?? false) },
                onUploadComplete: {
                    finishedSending = true
                    onProgress?(.waitingForDocker(bytesSent: bytesSent, totalBytes: request.bytes))
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
                    totalBytes: request.bytes)
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
