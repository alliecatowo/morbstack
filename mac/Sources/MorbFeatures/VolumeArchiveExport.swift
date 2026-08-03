// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deliberately narrow local named-volume archive export. Docker exposes volume
// bytes only through a container filesystem, so this creates one stopped, read-only
// helper container that Morbstack owns and removes before it publishes the archive.

import Foundation
import MorbstackKit

/// A completed archive export of one existing Morbstack named volume.
public struct VolumeArchiveExportResult: Sendable, Equatable {
    public let volumeName: String
    public let driver: String
    public let destination: URL
    public let bytes: Int64
    /// The already-local image used for the temporary stopped helper. No image pull
    /// occurs in this export contract.
    public let helperImage: String
    /// Stable request shapes, with the helper ID intentionally omitted.
    public let engineRequests: [String]

    public init(
        volumeName: String,
        driver: String,
        destination: URL,
        bytes: Int64,
        helperImage: String,
        engineRequests: [String]
    ) {
        self.volumeName = volumeName
        self.driver = driver
        self.destination = destination
        self.bytes = bytes
        self.helperImage = helperImage
        self.engineRequests = engineRequests
    }
}

/// Actual archive bytes written while a volume export is in progress. Docker may
/// omit a content length, in which case callers must remain indeterminate.
public struct VolumeArchiveExportProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let totalBytes: Int64?

    public init(bytesWritten: Int64, totalBytes: Int64?) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
    }
}

/// Errors specific to the bounded volume-export contract. Engine transport and
/// Engine refusal errors remain `EngineError` so callers retain the daemon's detail.
public enum VolumeArchiveExportError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case invalidVolumeName
    case volumeNotFound
    case unsupportedVolumeDriver(String)
    case helperImageUnavailable
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
    case helperCleanupFailed(String)

    public var description: String {
        switch self {
        case .invalidVolumeName:
            return "volume name must be an explicit Docker-safe named-volume identifier"
        case .volumeNotFound:
            return "the selected Morbstack volume no longer exists"
        case .unsupportedVolumeDriver(let driver):
            return "refusing to export volume data from driver \(driver); only Docker local-driver volumes are supported"
        case .helperImageUnavailable:
            return "no already-local image is available for the temporary read-only volume helper; this export never pulls an image"
        case .invalidOutputURL:
            return "--output must name an archive file path"
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
            return "the Docker Engine returned an empty volume archive"
        case .cancelled:
            return "volume archive export was cancelled; no archive was saved"
        case .writeFailed:
            return "could not write the volume archive to the staging file"
        case .commitFailed:
            return "could not atomically commit the completed volume archive"
        case .noEngineResponse:
            return "the Docker Engine closed the volume archive export without a response"
        case .engineRejected(let status, let message):
            return "docker engine returned \(status): \(message)"
        case .helperCleanupFailed(let detail):
            return "could not remove Morbstack's temporary read-only volume helper; no archive was saved: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// Exports one selected, already-existing Docker `local` volume from Morbstack.
///
/// The service first validates the output policy and then reads `/volumes/<name>`.
/// It refuses every non-`local` driver and refuses to pull an image: the stopped
/// helper uses one already-local image only. The helper mounts exactly the selected
/// volume at `/data:ro`; its archive endpoint is streamed to the shared private
/// staging writer. The helper is removed before atomic publication, and every error
/// path attempts removal again in `defer` before discarding the partial staging file.
/// This is export only: it does not import, write back, mount in Finder, mutate the
/// selected volume, or contact a registry/credential helper.
public enum VolumeArchiveExporter {

    @discardableResult
    public static func export(
        volumeName: String,
        to output: URL,
        replaceExisting: Bool,
        engine: EngineClient = EngineClient(),
        timeout: TimeInterval = 1_800,
        onProgress: ((VolumeArchiveExportProgress) -> Bool)? = nil
    ) throws -> VolumeArchiveExportResult {
        guard isSafeVolumeName(volumeName) else {
            throw VolumeArchiveExportError.invalidVolumeName
        }
        let destination = try validateDestination(output, replaceExisting: replaceExisting)
        let staging: LocalArchiveStagingFile
        do {
            staging = try LocalArchiveStagingFile(destination: destination)
        } catch {
            throw translateOutputError(error)
        }

        var helperID: String?
        defer {
            // This is the final safety net for every early return/throw after helper
            // creation. A failed explicit cleanup below leaves the ID intact so this
            // second best-effort removal attempt still occurs.
            if let helperID {
                _ = removeOwnedHelper(on: engine, id: helperID)
            }
        }

        var responseHead: HTTPResponseHead?
        var errorBody = Data()
        var writeFailure: Error?
        var cancellationRequested = false

        do {
            let volume: [String: Any]
            do {
                volume = try engine.jsonObject("GET", "/volumes/\(volumeName)", timeout: 30)
            } catch let error as EngineError {
                if case .engine(let status, _) = error, status == 404 {
                    throw VolumeArchiveExportError.volumeNotFound
                }
                throw error
            }
            let driver = JSONRead.string(volume, "Driver") ?? "unknown"
            guard driver == "local" else {
                throw VolumeArchiveExportError.unsupportedVolumeDriver(driver)
            }

            guard let helperImage = try alreadyLocalHelperImage(on: engine) else {
                throw VolumeArchiveExportError.helperImageUnavailable
            }
            helperID = try createStoppedReadOnlyHelper(
                on: engine,
                image: helperImage,
                volumeName: volumeName)

            try engine.stream(
                "GET", "/containers/\(helperID!)/archive", query: [("path", "/data")], timeout: timeout,
                onChunk: { chunk, head in
                    guard (200..<300).contains(head.statusCode) else {
                        appendErrorBody(chunk, to: &errorBody)
                        return true
                    }
                    do {
                        try staging.write(chunk)
                        let progress = VolumeArchiveExportProgress(
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
            if cancellationRequested { throw VolumeArchiveExportError.cancelled }
            guard let responseHead else { throw VolumeArchiveExportError.noEngineResponse }
            guard (200..<300).contains(responseHead.statusCode) else {
                throw VolumeArchiveExportError.engineRejected(
                    status: responseHead.statusCode,
                    message: engineMessage(from: errorBody, fallbackStatus: responseHead.statusCode))
            }
            guard staging.bytes > 0 else { throw VolumeArchiveExportError.archiveWasEmpty }

            // Do not publish an archive while an owned helper is known to remain.
            // One immediate retry absorbs a transient daemon race; if both attempts
            // fail, `defer` makes a final cleanup attempt and the staging file is
            // discarded so the caller never receives a success-looking archive.
            if let ownedHelperID = helperID {
                if let firstFailure = removeOwnedHelper(on: engine, id: ownedHelperID),
                   let retryFailure = removeOwnedHelper(on: engine, id: ownedHelperID) {
                    throw VolumeArchiveExportError.helperCleanupFailed(
                        "\(firstFailure); retry: \(retryFailure)")
                }
                helperID = nil
            }

            do {
                try staging.commit(replaceExisting: replaceExisting)
            } catch {
                throw translateOutputError(error)
            }
            return VolumeArchiveExportResult(
                volumeName: volumeName,
                driver: driver,
                destination: destination,
                bytes: staging.bytes,
                helperImage: helperImage,
                engineRequests: [
                    "GET /volumes/<volume-name>",
                    "GET /images/json",
                    "POST /containers/create (temporary stopped /data:ro helper)",
                    "GET /containers/<temporary-helper>/archive?path=/data",
                    "DELETE /containers/<temporary-helper>?force=1&v=1",
                ])
        } catch let error as VolumeArchiveExportError {
            staging.discard()
            throw error
        } catch {
            staging.discard()
            throw error
        }
    }

    private static func alreadyLocalHelperImage(on engine: EngineClient) throws -> String? {
        let images = try engine.jsonArray("GET", "/images/json", timeout: 15)
        for image in images {
            if let tags = JSONRead.array(image, "RepoTags") as? [String],
               let first = tags.first, first != "<none>:<none>" {
                return first
            }
        }
        // An untagged image ID is still already local and works for a stopped
        // archive helper. There is deliberately no registry fallback.
        if let first = images.first, let id = JSONRead.string(first, "Id") {
            return id
        }
        return nil
    }

    private static func createStoppedReadOnlyHelper(
        on engine: EngineClient,
        image: String,
        volumeName: String
    ) throws -> String {
        let body: [String: Any] = [
            "Image": image,
            "Cmd": ["true"],
            "HostConfig": ["Binds": ["\(volumeName):/data:ro"]],
        ]
        let response = try engine.jsonObject("POST", "/containers/create", body: body, timeout: 30)
        guard let id = JSONRead.string(response, "Id"), !id.isEmpty else {
            throw EngineError.malformed("temporary volume helper create did not return an Id")
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

    private static func validateDestination(_ requested: URL, replaceExisting: Bool) throws -> URL {
        do {
            return try LocalArchiveOutput.validateDestination(
                requested,
                replaceExisting: replaceExisting)
        } catch {
            throw translateOutputError(error)
        }
    }

    private static func translateOutputError(_ error: Error) -> VolumeArchiveExportError {
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
        return sanitize(response.engineMessage).prefix(512).description
    }

    private static func sanitize(_ message: String) -> String {
        message.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
    }
}
