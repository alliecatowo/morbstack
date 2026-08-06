// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Files tab's model: which directories are known, which are only partly known, and
// which scan is running right now.
//
// The budget is the load-bearing idea. Because the engine answers a directory request
// with the whole subtree, "list `/`" on a Debian image is a several-hundred-megabyte
// read. That is legitimate and it is fast locally — a live engine streamed 40 MB in
// 0.9 s over the Unix socket — but it is not something to start without saying so, and
// it is not something to let run unbounded. So a scan reports its bytes as it goes, can
// be stopped, stops itself at a ceiling, and when it stops early it says which
// directories it nevertheless finished.

import Foundation
import Observation

@MainActor
@Observable
final class ContainerFileTreeStore {

    /// How many response bytes one listing will read before stopping itself. Sized so
    /// that an ordinary application image lists completely and a machine-learning image
    /// full of model weights stops with an explanation instead of grinding.
    static let defaultByteBudget: Int64 = 512 << 20
    /// How many entries one listing will hold. `node_modules` trees exceed this, which
    /// is exactly the case the number exists for.
    static let defaultEntryBudget = 200_000

    struct ScanProgress: Equatable {
        var path: String
        var bytesRead: Int64
        var entriesListed: Int
    }

    /// The directory the tree is rooted at. Changing it is how a person reaches a part
    /// of the filesystem a budgeted scan never got to.
    private(set) var root = "/"
    private(set) var listings: [String: ContainerDirectoryListing] = [:]
    /// What the engine said about each path, by path. The root's own facts live here too.
    private(set) var facts: [String: ContainerFileEntry] = [:]
    private(set) var progress: ScanProgress?
    /// Entries the engine sent whose names did not describe a path inside the folder
    /// that was requested. Nonzero is worth saying out loud.
    private(set) var rejectedEntryCount = 0
    /// Set when a typed path could not be reached. The tree already on screen is still
    /// true, so this is a note beside it rather than a replacement for it.
    private(set) var navigationProblem: String?

    var expanded: Set<String> = []
    var selection: String?

    private var client: DockerClient?
    private var containerID: String?
    private var activeScanPath: String?
    private var queuedScanPath: String?
    private var activeCollector: ScanCollector?
    private var navigationTask: Task<Void, Never>?
    private var generation = 0

    var isScanning: Bool { activeScanPath != nil }

    var selectedEntry: ContainerFileEntry? {
        guard let selection else { return nil }
        return facts[selection]
    }

    func listing(for path: String) -> ContainerDirectoryListing {
        listings[path] ?? .notListed
    }

    // MARK: Lifecycle

    /// Binds the store to a container and lists the root on first sight. Called from
    /// the view's `.task`, so switching tabs does not re-read the filesystem.
    func start(client: DockerClient, containerID: String) {
        self.client = client
        self.containerID = containerID
        if listings.isEmpty && activeScanPath == nil { scan(root) }
    }

    /// Re-roots the tree at `path`.
    ///
    /// Stats the path first, because `HEAD …/archive` answers in one header and a `GET`
    /// on the wrong kind of thing is a wasted archive read. A path that turns out to be
    /// a file browses its enclosing folder with the file selected, which is what "go to
    /// a path" means everywhere else on this platform.
    func navigate(to path: String) {
        guard let client, let containerID else { return }
        guard let normalized = ContainerFilePath.normalizeTyped(path) else {
            navigationProblem =
                "\(path.trimmingCharacters(in: .whitespaces)) is not an absolute container path. Paths start at / and cannot contain “..”."
            return
        }

        navigationTask?.cancel()
        navigationProblem = nil
        navigationTask = Task { [weak self] in
            do {
                let stat = try await client.containerPathStat(id: containerID, path: normalized)
                guard let self, !Task.isCancelled else { return }
                self.facts[normalized] = ContainerFileEntry(path: normalized, stat: stat)
                if stat.kind == .directory {
                    self.reroot(to: normalized, selecting: nil)
                } else if let parent = ContainerFilePath.parent(of: normalized) {
                    self.reroot(to: parent, selecting: normalized)
                } else {
                    self.reroot(to: normalized, selecting: nil)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                // The current tree is still true, so it stays. Only the attempt failed.
                self.navigationProblem = ContainerFileErrorText.sentence(error, path: normalized)
            }
        }
    }

    private func reroot(to path: String, selecting selection: String?) {
        root = path
        self.selection = selection
        expanded = []
        navigationProblem = nil
        scan(path, force: true)
    }

    /// Discards everything known about the current root and reads it again.
    func reloadRoot() {
        scan(root, force: true)
    }

    /// Expands or collapses one directory, listing it the first time it opens.
    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
            return
        }
        expanded.insert(path)
        if case .notListed = listing(for: path) { scan(path) }
    }

    /// Lists one directory on its own. The affordance a partial listing points at.
    func list(_ path: String) {
        scan(path, force: true)
    }

    func stopScan() {
        guard activeScanPath != nil else { return }
        activeCollector?.stopByPerson()
    }

    // MARK: Scanning

    private func scan(_ path: String, force: Bool = false) {
        guard let client, let containerID else { return }
        if activeScanPath != nil {
            // One archive read at a time. A second request waits rather than competing
            // with the first for the same socket and the same budget. There is one
            // waiting slot; a request that loses it goes back to "not listed" rather
            // than sitting on a spinner nothing is driving.
            if let displaced = queuedScanPath, displaced != path,
               listing(for: displaced).isLoading
            {
                listings[displaced] = .notListed
            }
            queuedScanPath = path
            listings[path] = .listing(listing(for: path).entries)
            return
        }
        if !force, listing(for: path).isComplete { return }

        generation += 1
        let token = generation
        activeScanPath = path
        listings[path] = .listing(force ? [] : listing(for: path).entries)
        if force { rejectedEntryCount = 0 }
        progress = ScanProgress(path: path, bytesRead: 0, entriesListed: 0)

        let collector = ScanCollector(
            requestedPath: path,
            byteBudget: Self.defaultByteBudget,
            entryBudget: Self.defaultEntryBudget,
            onUpdate: { [weak self] in
                Task { @MainActor [weak self] in self?.drain(token: token) }
            })
        activeCollector = collector

        let handle = client.containerArchive(
            id: containerID,
            path: path,
            onBody: { collector.consume($0) },
            onFinish: { error in
                Task { @MainActor [weak self] in
                    self?.finishScan(token: token, error: error)
                }
            })
        collector.attach(handle)
    }

    private func drain(token: Int) {
        guard token == generation, let collector = activeCollector else { return }
        let update = collector.takeUpdate()
        apply(update, path: collector.requestedPath)
    }

    private func finishScan(token: Int, error: Error?) {
        guard token == generation, let collector = activeCollector else { return }
        let path = collector.requestedPath
        let update = collector.takeUpdate()
        apply(update, path: path)

        let outcome = collector.outcome(transportError: error)
        finalize(path: path, collector: collector, outcome: outcome)

        activeScanPath = nil
        activeCollector = nil
        progress = nil

        if let queued = queuedScanPath {
            queuedScanPath = nil
            scan(queued)
        }
    }

    /// Merges one batch of scan results. Every directory the batch touched is `.listing`
    /// until the scan finalizes, because until then nobody can say whether the engine
    /// has more to send for it.
    private func apply(_ update: ScanCollector.Update, path: String) {
        for (directory, entries) in update.directories {
            listings[directory] = .listing(entries)
            for entry in entries { facts[entry.path] = entry }
        }
        if let rootEntry = update.requestedPathEntry { facts[path] = rootEntry }
        rejectedEntryCount = update.rejectedEntryCount
        if activeScanPath != nil {
            progress = ScanProgress(
                path: path,
                bytesRead: update.bytesRead,
                entriesListed: update.entryCount)
        }
    }

    private func finalize(
        path: String,
        collector: ScanCollector,
        outcome: ScanCollector.Outcome
    ) {
        switch outcome {
        case .failed(let sentence):
            // Nothing usable arrived. Say so on the folder that was asked for, and do
            // not leave a half-populated listing looking authoritative.
            listings[path] = .unavailable(sentence)
            return

        case .completed, .stopped:
            break
        }

        // The engine answered about something that is not a folder. Say that, rather
        // than showing it as a folder that happens to be empty.
        if let kind = collector.requestedPathKind, kind != .directory {
            listings[path] =
                .unavailable("\(path) is a \(kind.displayName.lowercased()), not a folder.")
            return
        }

        let stop: ContainerFileScanStop?
        if case .stopped(let reason) = outcome { stop = reason } else { stop = nil }
        let completed = collector.completedDirectories(streamCompleted: stop == nil)

        var touched = collector.knownDirectories
        touched.insert(path)
        for directory in touched {
            let entries = collector.entries(in: directory)
            if completed.contains(directory) {
                listings[directory] = .listed(entries)
            } else if entries.isEmpty {
                // Not reached at all. "Not listed" is the truth; an empty complete
                // listing would be a claim the scan never earned.
                listings[directory] = .notListed
            } else if let stop {
                listings[directory] = .partial(entries, stop)
            } else {
                listings[directory] = .listed(entries)
            }
        }
    }
}

// MARK: - The reader-thread half

/// Accumulates one archive read off the socket thread.
///
/// Everything here runs on `DockerClient`'s private reader thread except `takeUpdate`,
/// which the main actor calls; one lock covers both.
private final class ScanCollector: @unchecked Sendable {

    struct Update {
        /// Only the directories whose contents changed since the last take.
        var directories: [String: [ContainerFileEntry]] = [:]
        var requestedPathEntry: ContainerFileEntry?
        var bytesRead: Int64 = 0
        var entryCount = 0
        var rejectedEntryCount = 0
    }

    enum Outcome: Equatable {
        case completed
        case stopped(ContainerFileScanStop)
        case failed(String)
    }

    let requestedPath: String

    private let lock = NSLock()
    private let byteBudget: Int64
    private let onUpdate: @Sendable () -> Void

    private var reader = ContainerTarHeaderReader()
    private var scan: ContainerDirectoryScan
    private var storage: [String: [ContainerFileEntry]] = [:]
    private var dirty: Set<String> = []
    private var requestedPathEntry: ContainerFileEntry?
    private var bytesRead: Int64 = 0
    private var lastPublish = Date.distantPast
    private var handle: ContainerArchiveHandle?
    private var stopReason: ContainerFileScanStop?
    private var readerFailure: String?
    private var sawAnyBytes = false
    private var isFinished = false

    /// How often the tree is allowed to repaint while a scan runs. Fast enough to look
    /// live, slow enough that a 200,000-entry archive does not publish 200,000 times.
    private static let publishInterval: TimeInterval = 0.12

    init(
        requestedPath: String,
        byteBudget: Int64,
        entryBudget: Int,
        onUpdate: @escaping @Sendable () -> Void
    ) {
        self.requestedPath = requestedPath
        self.byteBudget = byteBudget
        self.onUpdate = onUpdate
        self.scan = ContainerDirectoryScan(requestedPath: requestedPath, entryBudget: entryBudget)
    }

    func attach(_ handle: ContainerArchiveHandle) {
        lock.lock()
        let stopNow = stopReason != nil || isFinished
        if !stopNow { self.handle = handle }
        lock.unlock()
        if stopNow { handle.cancel() }
    }

    func stop(_ reason: ContainerFileScanStop) {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        let target = handle
        handle = nil
        lock.unlock()
        target?.cancel()
    }

    /// Stops on the person's behalf, recording how far the read had actually got.
    func stopByPerson() {
        lock.lock()
        let read = bytesRead
        lock.unlock()
        stop(.stoppedByPerson(bytesRead: read))
    }

    func consume(_ chunk: Data) {
        lock.lock()
        guard !isFinished, stopReason == nil, readerFailure == nil else {
            lock.unlock()
            return
        }
        sawAnyBytes = true
        bytesRead += Int64(chunk.count)

        var pendingStop: ContainerFileScanStop?
        do {
            for event in try reader.feed(chunk) {
                switch event {
                case .entry(let tarEntry):
                    switch scan.admit(tarEntry) {
                    case .requestedPath(let entry):
                        requestedPathEntry = entry
                    case .entry(let entry, let parent):
                        var entries = storage[parent] ?? []
                        ContainerFileEntry.insertSorted(entry, into: &entries)
                        storage[parent] = entries
                        dirty.insert(parent)
                        if entry.kind == .directory, storage[entry.path] == nil {
                            storage[entry.path] = []
                            dirty.insert(entry.path)
                        }
                    case .rejected:
                        continue
                    case .budgetExhausted:
                        pendingStop = .entryBudget(scan.entryBudget)
                    }
                case .payload, .endOfArchive:
                    continue
                }
                if pendingStop != nil { break }
            }
        } catch {
            if case ContainerTarHeaderReader.Failure.malformedArchive(let reason) = error {
                readerFailure = reason
            } else {
                readerFailure = MorbErrorMessage.text(for: error)
            }
            pendingStop = .interrupted(readerFailure ?? "the stream ended unexpectedly")
        }

        if pendingStop == nil, bytesRead >= byteBudget {
            pendingStop = .byteBudget(byteBudget)
        }

        let shouldPublish = Date().timeIntervalSince(lastPublish) >= Self.publishInterval
        if shouldPublish { lastPublish = Date() }
        lock.unlock()

        if let pendingStop { stop(pendingStop) }
        if shouldPublish || pendingStop != nil { onUpdate() }
    }

    func takeUpdate() -> Update {
        lock.lock()
        defer { lock.unlock() }
        var update = Update()
        for directory in dirty { update.directories[directory] = storage[directory] ?? [] }
        dirty.removeAll(keepingCapacity: true)
        update.requestedPathEntry = requestedPathEntry
        update.bytesRead = bytesRead
        update.entryCount = scan.entryCount
        update.rejectedEntryCount = scan.rejectedEntryCount
        return update
    }

    func entries(in directory: String) -> [ContainerFileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage[directory] ?? []
    }

    var knownDirectories: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return scan.knownDirectories
    }

    var requestedPathKind: ContainerFileKind? {
        lock.lock()
        defer { lock.unlock() }
        return scan.requestedPathKind
    }

    func completedDirectories(streamCompleted: Bool) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return scan.completedDirectories(streamCompleted: streamCompleted)
    }

    /// How the read ended, once the connection has closed.
    func outcome(transportError: Error?) -> Outcome {
        lock.lock()
        isFinished = true
        let reason = stopReason
        let sawBytes = sawAnyBytes
        let complete = reader.isComplete
        let entries = scan.entryCount
        lock.unlock()

        if let transportError, !sawBytes {
            return .failed(ContainerFileErrorText.sentence(transportError, path: requestedPath))
        }
        if let reason {
            if entries == 0, requestedPathEntry == nil {
                return .failed(ContainerFileErrorText.sentence(reason, path: requestedPath))
            }
            return .stopped(reason)
        }
        if let transportError {
            return .stopped(.interrupted(MorbErrorMessage.text(for: transportError)))
        }
        if complete { return .completed }
        // The socket closed without the end-of-archive marker: everything read is real,
        // but the listing cannot be called finished.
        return .stopped(.interrupted("the engine closed the connection before the archive ended"))
    }
}

// MARK: - Sentences

/// The user-facing wording for a failed read. Kept in one place so the tab, the viewer
/// and the saver say the same thing about the same failure.
enum ContainerFileErrorText {

    static func sentence(_ error: Error, path: String) -> String {
        if let clientError = error as? DockerClientError {
            switch clientError {
            case .http(let status, let message):
                if status == 404 {
                    if message.localizedCaseInsensitiveContains("no such container") {
                        return "This container no longer exists on the engine."
                    }
                    return "There is nothing at \(path) in this container now."
                }
                if status == 403 || status == 401 {
                    return "The engine refused to read \(path): \(message)"
                }
                return "The engine could not read \(path): \(message)"
            case .engineUnreachable:
                return "Morbstack could not reach the Docker engine, so it cannot read this container's files."
            case .transport, .decoding:
                return "Morbstack could not read \(path): \(MorbErrorMessage.text(for: error))"
            }
        }
        if case ContainerTarHeaderReader.Failure.malformedArchive(let reason) = error {
            return "Morbstack stopped reading \(path) because \(reason)."
        }
        return MorbErrorMessage.text(for: error)
    }

    static func sentence(_ stop: ContainerFileScanStop, path: String) -> String {
        switch stop {
        case .interrupted(let reason):
            return "The engine stopped sending \(path): \(reason)"
        case .stoppedByPerson:
            return "You stopped this listing before anything arrived."
        case .byteBudget(let budget):
            return "Morbstack read \(Formatters.bytesString(budget)) of \(path) without reaching a single entry it could list."
        case .entryBudget(let budget):
            return "Morbstack stopped after \(budget) items."
        }
    }
}
