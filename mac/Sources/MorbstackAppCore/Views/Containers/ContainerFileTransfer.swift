// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Reading one file out of a container, and writing one path out to the host.
//
// Three rules hold this together:
//
//  - **Nothing is read into memory without a ceiling.** A viewer read stops at a fixed
//    number of bytes and says so; a save streams straight to the destination file and
//    never accumulates.
//  - **A directory leaves as the archive the engine sent.** Morbstack does not extract
//    a multi-entry tar onto the host, which is the only way to be categorically immune
//    to a `../../` entry name written by something inside the container. The user gets
//    a `.tar`, and the sheet says so before they choose a name.
//  - **A save that does not finish leaves nothing behind.** A cancelled or failed write
//    deletes its partial file rather than leaving a plausible-looking short one.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Is it text?

/// The result of deciding whether a file's bytes can be shown as text.
enum ContainerFileReadability: Equatable {
    case empty
    /// Decoded text, and whether the read stopped before the end of the file.
    case text(String, truncated: Bool)
    case notText(ContainerFileNotTextReason)
}

/// Why a file is not being shown as text. Both are facts about the bytes, not guesses.
enum ContainerFileNotTextReason: Equatable {
    case containsNullBytes
    case notValidUTF8
}

enum ContainerFileText {

    /// How much of a file the viewer reads. Two megabytes is comfortably more than any
    /// config, log excerpt or certificate somebody opens in a 400pt inspector, and small
    /// enough that opening the wrong file costs nothing.
    static let viewerByteLimit = 2 << 20

    /// How many leading bytes decide the text/binary question.
    static let sniffByteLimit = 8 << 10

    static func interpret(_ data: Data, truncated: Bool) -> ContainerFileReadability {
        guard !data.isEmpty else { return .empty }

        // A NUL byte in the first few kilobytes is what every other tool uses to call a
        // file binary, and it is a fact about the bytes rather than a heuristic score.
        let sniff = data.prefix(sniffByteLimit)
        if sniff.contains(0) { return .notText(.containsNullBytes) }

        // A truncated read almost always ends mid-character; dropping that fragment is
        // not "fixing" the file, it is declining to fail on a boundary we chose.
        let candidate = truncated ? trimmingIncompleteUTF8Suffix(data) : data
        guard let text = String(data: candidate, encoding: .utf8) else {
            return .notText(.notValidUTF8)
        }
        return .text(text, truncated: truncated)
    }

    /// Drops a trailing partial UTF-8 sequence, up to the three bytes one can occupy.
    static func trimmingIncompleteUTF8Suffix(_ data: Data) -> Data {
        var end = data.endIndex
        var dropped = 0
        while end > data.startIndex, dropped < 3 {
            let byte = data[data.index(before: end)]
            if byte & 0b1100_0000 != 0b1000_0000 {
                // A leading byte: keep it only if its whole sequence is present.
                let expected: Int
                if byte & 0b1000_0000 == 0 { expected = 1 }
                else if byte & 0b1110_0000 == 0b1100_0000 { expected = 2 }
                else if byte & 0b1111_0000 == 0b1110_0000 { expected = 3 }
                else if byte & 0b1111_1000 == 0b1111_0000 { expected = 4 }
                else { expected = 1 }
                if dropped + 1 >= expected { return data }
                return data[data.startIndex..<data.index(before: end)]
            }
            end = data.index(before: end)
            dropped += 1
        }
        return data
    }

    /// The sentence shown instead of the file's contents.
    static func sentence(for reason: ContainerFileNotTextReason, size: Int64?) -> String {
        let sizeClause = size.map { " It is \(Formatters.bytesString($0))." } ?? ""
        switch reason {
        case .containsNullBytes:
            return "This file contains bytes that are not text, so Morbstack is not guessing at how to display it.\(sizeClause) Save it to the host to open it in another app."
        case .notValidUTF8:
            return "This file is not valid UTF-8 text, so showing it here would show the wrong characters.\(sizeClause) Save it to the host to open it in another app."
        }
    }
}

// MARK: - Reading

/// One bounded read of a single file.
struct ContainerFileRead: Equatable {
    /// The bytes actually read, never more than the limit that was asked for.
    var data: Data
    /// The archive's own header for the file, which is where its true size comes from.
    var entry: ContainerTarEntry?
    /// `true` when the file is longer than the bytes in `data`.
    var truncated: Bool
}

/// Why a read or a save could not be done, in the words the person sees.
struct ContainerFileTransferError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

enum ContainerFileTransfers {

    /// Reads up to `limit` bytes of one regular file.
    ///
    /// Stops the connection the moment it has what it needs rather than draining the
    /// rest of the response, which matters when "the rest" is a 4 GB database file.
    static func read(
        client: DockerClient,
        containerID: String,
        path: String,
        limit: Int
    ) async throws -> ContainerFileRead {
        let collector = FileReadCollector(path: path, limit: limit)
        return try await withCheckedThrowingContinuation { continuation in
            let handle = client.containerArchive(
                id: containerID,
                path: path,
                onBody: { collector.consume($0) },
                onFinish: { error in continuation.resume(with: collector.finish(error: error)) })
            collector.attach(handle)
        }
    }

    /// Writes one regular file's contents to `destination`, streaming.
    static func saveFile(
        client: DockerClient,
        containerID: String,
        path: String,
        to destination: URL,
        handleSink: @escaping @Sendable (ContainerArchiveHandle) -> Void,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let writer = try FileWriteCollector(
            path: path, destination: destination, mode: .fileContents, progress: progress)
        return try await withCheckedThrowingContinuation { continuation in
            let handle = client.containerArchive(
                id: containerID,
                path: path,
                onBody: { writer.consume($0) },
                onFinish: { error in continuation.resume(with: writer.finish(error: error)) })
            writer.attach(handle)
            handleSink(handle)
        }
    }

    /// Writes the engine's archive of `path` to `destination` byte for byte.
    ///
    /// No extraction happens on the host, so an entry name crafted inside the container
    /// cannot address anything outside the file the person chose.
    static func saveArchive(
        client: DockerClient,
        containerID: String,
        path: String,
        to destination: URL,
        handleSink: @escaping @Sendable (ContainerArchiveHandle) -> Void,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let writer = try FileWriteCollector(
            path: path, destination: destination, mode: .rawArchive, progress: progress)
        return try await withCheckedThrowingContinuation { continuation in
            let handle = client.containerArchive(
                id: containerID,
                path: path,
                onBody: { writer.consume($0) },
                onFinish: { error in continuation.resume(with: writer.finish(error: error)) })
            writer.attach(handle)
            handleSink(handle)
        }
    }

    /// A file name for the host that cannot be steered by anything inside the container.
    ///
    /// The container-side name is untrusted, so the suggestion is rebuilt from its last
    /// component with the path separators, dots-only names and control characters
    /// removed. A name that survives none of that becomes a plain, honest fallback.
    static func suggestedFileName(for path: String, isDirectory: Bool) -> String {
        let raw = ContainerFilePath.displayName(of: path)
        let cleaned = raw.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control {
                result.append("-")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        let base = (trimmed.isEmpty || trimmed.allSatisfy { $0 == "." || $0 == "-" })
            ? "container-file" : String(trimmed.prefix(200))
        return isDirectory ? base + ".tar" : base
    }
}

// MARK: - Collectors

/// Shared cancellation plumbing: a stop can be decided on the reader thread before the
/// connection handle exists, so the request is remembered and applied on arrival.
private class ArchiveConsumer: @unchecked Sendable {

    let lock = NSLock()
    private var handle: ContainerArchiveHandle?
    private var stopRequested = false

    func attach(_ handle: ContainerArchiveHandle) {
        lock.lock()
        let stopNow = stopRequested
        if !stopNow { self.handle = handle }
        lock.unlock()
        if stopNow { handle.cancel() }
    }

    /// Ends the stream. Safe from the reader thread and from the main actor.
    func stop() {
        lock.lock()
        stopRequested = true
        let target = handle
        handle = nil
        lock.unlock()
        target?.cancel()
    }
}

/// Reads the first regular-file entry's bytes, up to a limit.
private final class FileReadCollector: ArchiveConsumer, @unchecked Sendable {

    private let path: String
    private let limit: Int
    private var reader = ContainerTarHeaderReader(capturesPayload: true)
    private var entry: ContainerTarEntry?
    private var data = Data()
    private var written: Int64 = 0
    private var failure: Error?
    private var isDone = false

    init(path: String, limit: Int) {
        self.path = path
        self.limit = limit
        super.init()
    }

    func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDone, failure == nil else { return }

        let events: [ContainerTarEvent]
        do {
            events = try reader.feed(chunk)
        } catch {
            failure = error
            isDone = true
            stopLocked()
            return
        }

        for event in events {
            switch event {
            case .entry(let tarEntry):
                if entry == nil {
                    entry = tarEntry
                    if tarEntry.kind != .regularFile || tarEntry.size == 0 {
                        isDone = true
                        stopLocked()
                        return
                    }
                } else {
                    // Only the first entry belongs to the file that was asked for.
                    isDone = true
                    stopLocked()
                    return
                }
            case .payload(let bytes):
                let room = limit - data.count
                if room > 0 { data.append(bytes.prefix(room)) }
                written += Int64(bytes.count)
                if data.count >= limit {
                    isDone = true
                    stopLocked()
                    return
                }
            case .endOfArchive:
                isDone = true
            }
        }
    }

    func finish(error: Error?) -> Result<ContainerFileRead, Error> {
        lock.lock()
        let capturedFailure = failure
        let capturedEntry = entry
        let capturedData = data
        lock.unlock()

        if let capturedFailure {
            return .failure(ContainerFileTransferError(message: readerFailureSentence(capturedFailure)))
        }
        if let error, capturedEntry == nil {
            return .failure(error)
        }
        guard let capturedEntry else {
            return .failure(
                ContainerFileTransferError(
                    message: "The engine sent nothing for \(path)."))
        }
        let truncated = capturedEntry.kind == .regularFile
            && capturedEntry.size > Int64(capturedData.count)
        return .success(
            ContainerFileRead(data: capturedData, entry: capturedEntry, truncated: truncated))
    }

    private func stopLocked() {
        // `stop()` takes the same lock, so the unlock/relock dance is deliberate.
        lock.unlock()
        stop()
        lock.lock()
    }
}

/// Streams a response to a file on the host.
private final class FileWriteCollector: ArchiveConsumer, @unchecked Sendable {

    enum Mode { case rawArchive, fileContents }

    private let path: String
    private let destination: URL
    private let mode: Mode
    private let progress: @Sendable (Int64) -> Void
    private let output: FileHandle
    private var reader: ContainerTarHeaderReader
    private var entry: ContainerTarEntry?
    private var bytesWritten: Int64 = 0
    private var failure: Error?
    private var isDone = false

    init(
        path: String,
        destination: URL,
        mode: Mode,
        progress: @escaping @Sendable (Int64) -> Void
    ) throws {
        self.path = path
        self.destination = destination
        self.mode = mode
        self.progress = progress
        self.reader = ContainerTarHeaderReader(capturesPayload: mode == .fileContents)

        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw ContainerFileTransferError(
                message: "Morbstack could not create \(destination.lastPathComponent).")
        }
        self.output = try FileHandle(forWritingTo: destination)
        super.init()
    }

    func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDone, failure == nil else { return }

        switch mode {
        case .rawArchive:
            write(chunk)
            progress(bytesWritten)
        case .fileContents:
            let events: [ContainerTarEvent]
            do {
                events = try reader.feed(chunk)
            } catch {
                failure = error
                isDone = true
                stopLocked()
                return
            }
            for event in events {
                switch event {
                case .entry(let tarEntry):
                    if entry == nil {
                        entry = tarEntry
                        if tarEntry.kind != .regularFile {
                            failure = ContainerFileTransferError(
                                message: notARegularFileSentence(tarEntry))
                            isDone = true
                            stopLocked()
                            return
                        }
                        if tarEntry.size == 0 {
                            isDone = true
                            stopLocked()
                            return
                        }
                    } else {
                        isDone = true
                        stopLocked()
                        return
                    }
                case .payload(let bytes):
                    write(bytes)
                    progress(bytesWritten)
                    if let entry, bytesWritten >= entry.size {
                        isDone = true
                        stopLocked()
                        return
                    }
                case .endOfArchive:
                    isDone = true
                }
            }
        }
    }

    func finish(error: Error?) -> Result<Int64, Error> {
        lock.lock()
        let capturedFailure = failure
        let written = bytesWritten
        let capturedEntry = entry
        try? output.close()
        lock.unlock()

        if let capturedFailure {
            discard()
            let message = (capturedFailure as? ContainerFileTransferError)?.message
                ?? readerFailureSentence(capturedFailure)
            return .failure(ContainerFileTransferError(message: message))
        }
        if let error {
            discard()
            return .failure(error)
        }
        if mode == .fileContents {
            guard let capturedEntry else {
                discard()
                return .failure(
                    ContainerFileTransferError(message: "The engine sent nothing for \(path)."))
            }
            guard written == capturedEntry.size else {
                discard()
                return .failure(
                    ContainerFileTransferError(
                        message:
                            "The engine stopped after \(Formatters.bytesString(written)) of \(Formatters.bytesString(capturedEntry.size)). Nothing was saved."))
            }
        }
        return .success(written)
    }

    /// Removes the destination. A half-written file that looks finished is worse than
    /// no file at all.
    func discard() {
        try? FileManager.default.removeItem(at: destination)
    }

    private func write(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            try output.write(contentsOf: data)
            bytesWritten += Int64(data.count)
        } catch {
            failure = ContainerFileTransferError(
                message: "Morbstack could not keep writing \(destination.lastPathComponent): \(error.localizedDescription)")
            isDone = true
            stopLocked()
        }
    }

    private func notARegularFileSentence(_ entry: ContainerTarEntry) -> String {
        if let target = entry.linkTarget, entry.kind == .symbolicLink {
            return "\(path) is a symbolic link to \(target), not a file. Save the path it points to instead."
        }
        return "\(path) is a \(entry.kind.displayName.lowercased()), which has no contents to save."
    }

    private func stopLocked() {
        lock.unlock()
        stop()
        lock.lock()
    }
}

/// Turns a tar-reader failure into a sentence. Kept out of both collectors so they
/// agree on the wording.
private func readerFailureSentence(_ error: Error) -> String {
    if case ContainerTarHeaderReader.Failure.malformedArchive(let reason) = error {
        return "Morbstack stopped reading because \(reason)."
    }
    return MorbErrorMessage.text(for: error)
}

// MARK: - The save workflow

/// One save-to-host operation, with the progress and the outcome the tab shows.
@MainActor
@Observable
final class ContainerFileSaver {

    enum Outcome: Equatable {
        case saved(URL, bytes: Int64)
        case failed(String)
        case cancelled(URL)
    }

    private(set) var isSaving = false
    private(set) var subject: String?
    private(set) var bytesWritten: Int64 = 0
    private(set) var outcome: Outcome?

    private var handle: ContainerArchiveHandle?
    private var wasCancelled = false

    /// Presents the save panel and then streams. The panel owns location choice and its
    /// own replacement prompt, as every other export in this app does.
    func begin(
        client: DockerClient,
        containerID: String,
        entry: ContainerFileEntry
    ) {
        guard !isSaving else { return }
        let isDirectory = entry.kind == .directory

        let panel = NSSavePanel()
        panel.nameFieldStringValue = ContainerFileTransfers.suggestedFileName(
            for: entry.path, isDirectory: isDirectory)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Save"
        panel.message = isDirectory
            ? "Saves everything under \(entry.path) as one tar archive. Morbstack does not unpack it on this Mac."
            : "Saves the contents of \(entry.path) from inside the container."
        if isDirectory { panel.allowedContentTypes = [UTType("public.tar-archive")].compactMap { $0 } }

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isSaving = true
        wasCancelled = false
        bytesWritten = 0
        outcome = nil
        subject = entry.name

        let progress: @Sendable (Int64) -> Void = { [weak self] written in
            Task { @MainActor in self?.bytesWritten = written }
        }
        let sink: @Sendable (ContainerArchiveHandle) -> Void = { [weak self] handle in
            Task { @MainActor in self?.adopt(handle) }
        }

        Task { [weak self] in
            do {
                let written: Int64
                if isDirectory {
                    written = try await ContainerFileTransfers.saveArchive(
                        client: client, containerID: containerID, path: entry.path,
                        to: destination, handleSink: sink, progress: progress)
                } else {
                    written = try await ContainerFileTransfers.saveFile(
                        client: client, containerID: containerID, path: entry.path,
                        to: destination, handleSink: sink, progress: progress)
                }
                self?.complete(destination: destination, bytes: written)
            } catch {
                self?.fail(destination: destination, error: error)
            }
        }
    }

    func cancel() {
        guard isSaving else { return }
        wasCancelled = true
        handle?.cancel()
    }

    func dismissOutcome() { outcome = nil }

    private func adopt(_ handle: ContainerArchiveHandle) {
        if wasCancelled {
            handle.cancel()
        } else {
            self.handle = handle
        }
    }

    private func complete(destination: URL, bytes: Int64) {
        handle = nil
        isSaving = false
        if wasCancelled {
            // A cancelled transfer never leaves a plausible-looking short file behind.
            try? FileManager.default.removeItem(at: destination)
            outcome = .cancelled(destination)
        } else {
            outcome = .saved(destination, bytes: bytes)
        }
    }

    private func fail(destination: URL, error: Error) {
        handle = nil
        isSaving = false
        try? FileManager.default.removeItem(at: destination)
        if wasCancelled {
            outcome = .cancelled(destination)
        } else {
            outcome = .failed(MorbErrorMessage.text(for: error))
        }
    }
}
