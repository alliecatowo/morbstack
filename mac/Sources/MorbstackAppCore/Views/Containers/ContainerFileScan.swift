// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Turning one recursive tar stream into per-directory listings, and being exact about
// which of those listings are complete.
//
// The engine has no "list one level" request: asking for `/usr` streams everything
// under `/usr`. So a listing that ran out of budget is a real and frequent state, and
// the interesting question is not "did we stop" but "which directories did we
// nevertheless finish". Docker's writer walks the tree depth-first in lexical order, so
// a directory is finished the moment an entry arrives that is not inside it — but this
// type never *assumes* that ordering. It checks it, and the first entry that arrives
// out of order withdraws every completeness claim the scan would otherwise have made.
// A partial listing reported as complete is the one failure mode worth this bookkeeping.

import Foundation

// MARK: - Why a scan stopped short

/// The reason a directory listing is incomplete.
enum ContainerFileScanStop: Equatable, Sendable {
    case byteBudget(Int64)
    case entryBudget(Int)
    /// Carries the bytes actually read, because "you stopped it" without saying how far
    /// it got is not worth printing.
    case stoppedByPerson(bytesRead: Int64)
    /// The engine or the connection ended the stream early. The string is already a
    /// sentence fragment fit to read.
    case interrupted(String)

    /// What the person is told, and what they can do next. Every branch names an
    /// action, because "incomplete" on its own is a dead end.
    func sentence(entriesListed: Int) -> String {
        let listed = "\(entriesListed) \(entriesListed == 1 ? "item" : "items") were listed"
        switch self {
        case .byteBudget(let budget):
            return """
                The engine only sends whole folder trees, so listing this folder means \
                reading everything inside it. Morbstack stopped after \
                \(Formatters.bytesString(budget)) and \(listed). Open a folder below to \
                list just that folder.
                """
        case .entryBudget(let budget):
            return """
                Morbstack stopped after \(budget) items, which is as much of one tree as \
                it will hold at once. Open a folder below to list just that folder.
                """
        case .stoppedByPerson(let bytesRead):
            return "You stopped this listing after \(Formatters.bytesString(bytesRead)); \(listed). Reload to list the whole folder, or open one folder below on its own."
        case .interrupted(let reason):
            return "The engine stopped sending this folder: \(reason). \(listed.prefix(1).uppercased() + listed.dropFirst()) before it stopped."
        }
    }
}

// MARK: - Listing state

/// What is known about one directory.
enum ContainerDirectoryListing: Equatable {

    /// Nobody has asked the engine about it yet.
    case notListed
    /// A scan covering it is in flight; these are the entries so far.
    case listing([ContainerFileEntry])
    /// Every entry the engine holds for it, and we can prove it.
    case listed([ContainerFileEntry])
    /// Some of its entries, and the reason there are not more. Never presented as a
    /// complete listing.
    case partial([ContainerFileEntry], ContainerFileScanStop)
    /// The engine refused. The string is the sentence to show.
    case unavailable(String)

    var entries: [ContainerFileEntry] {
        switch self {
        case .listed(let entries), .partial(let entries, _), .listing(let entries): return entries
        case .notListed, .unavailable: return []
        }
    }

    var isComplete: Bool {
        if case .listed = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .listing = self { return true }
        return false
    }
}

// MARK: - The scan

/// Rebases and validates one archive's entries, and tracks which directories inside it
/// were provably enumerated to the end.
struct ContainerDirectoryScan {

    /// What happened to one archive entry.
    enum Admission: Equatable {
        /// The entry describing the requested path itself.
        case requestedPath(ContainerFileEntry)
        /// A listable entry, and the directory it belongs to.
        case entry(ContainerFileEntry, parent: String)
        /// The name did not describe a path beneath the requested one.
        case rejected(ContainerFilePath.Rejection)
        /// The scan's entry budget is used up; the caller must stop reading.
        case budgetExhausted
    }

    let requestedPath: String
    let entryBudget: Int

    private(set) var entryCount = 0
    private(set) var rejectedEntryCount = 0
    /// Directories that appeared as entries, so we know they exist.
    private(set) var knownDirectories: Set<String> = []
    /// Directories the stream has provably moved past.
    private(set) var closedDirectories: Set<String> = []
    /// `false` once an entry arrives somewhere the depth-first ordering says it cannot.
    /// Completeness claims are withdrawn wholesale rather than audited entry by entry.
    private(set) var orderingWasSequential = true
    /// What the entry for the requested path itself said it was, if the archive carried
    /// one. A file or a symlink here means the caller asked a folder question about
    /// something that is not a folder.
    private(set) var requestedPathKind: ContainerFileKind?

    private var openDirectories: [String]

    init(requestedPath: String, entryBudget: Int) {
        self.requestedPath = requestedPath
        self.entryBudget = entryBudget
        self.openDirectories = [requestedPath]
    }

    /// `true` when `ancestor` strictly contains `path`, checked on a `/` boundary so
    /// `/var/lib` is not treated as containing `/var/libexec`.
    static func isStrictAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" { return path != "/" && path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    mutating func admit(_ tarEntry: ContainerTarEntry) -> Admission {
        guard entryCount < entryBudget else { return .budgetExhausted }

        let resolved = ContainerFilePath.absolutePath(
            forEntryName: tarEntry.name, requestedPath: requestedPath)
        guard case .success(let path) = resolved else {
            rejectedEntryCount += 1
            if case .failure(let rejection) = resolved { return .rejected(rejection) }
            return .rejected(.outsideRequestedPath)
        }

        let entry = ContainerFileEntry(path: path, entry: tarEntry)

        if path == requestedPath {
            requestedPathKind = entry.kind
            if entry.kind == .directory { knownDirectories.insert(path) }
            return .requestedPath(entry)
        }

        guard let parent = ContainerFilePath.parent(of: path) else {
            rejectedEntryCount += 1
            return .rejected(.outsideRequestedPath)
        }

        if closedDirectories.contains(parent) { orderingWasSequential = false }

        while let top = openDirectories.last,
              top != parent,
              !Self.isStrictAncestor(top, of: parent)
        {
            openDirectories.removeLast()
            closedDirectories.insert(top)
        }
        // A child whose own directory entry never arrived means the stream is not the
        // strict depth-first walk the closure bookkeeping relies on.
        if openDirectories.last != parent { orderingWasSequential = false }

        if entry.kind == .directory {
            openDirectories.append(path)
            knownDirectories.insert(path)
        }

        entryCount += 1
        return .entry(entry, parent: parent)
    }

    /// The directories that are known to hold no further entries.
    ///
    /// - Parameter streamCompleted: `true` only when the archive reached its
    ///   end-of-archive marker. Anything less and completeness is limited to the
    ///   directories the stream demonstrably left behind — and to none at all if the
    ///   ordering the closure tracking depends on was ever violated.
    func completedDirectories(streamCompleted: Bool) -> Set<String> {
        if streamCompleted {
            var all = knownDirectories
            // A requested path that turned out to be a file has no listing to complete.
            if requestedPathKind == nil || requestedPathKind == .directory {
                all.insert(requestedPath)
            }
            return all
        }
        guard orderingWasSequential else { return [] }
        return closedDirectories
    }
}
