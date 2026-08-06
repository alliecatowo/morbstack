// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Search, sort and pull-log logic for the Images screen — the parts worth testing.
//
// Kept out of the view for the usual reason: `ImagesRootView.body` is not a place where
// off-by-one sort order or a log that grows without bound can be observed, and these are
// exactly the behaviours that rot silently.

import Foundation

// MARK: - Sorting

/// The columns the Images table can be ordered by.
enum TrackCImageSortKey: String, Hashable, CaseIterable {
    case repository
    case tag
    case size
    case created
    case used
}

// MARK: - Filtering and grouping

enum TrackCImageList {

    /// `true` when `query` matches anything a user would plausibly type to find an image:
    /// any of its tags, its short id, or its full id.
    ///
    /// Case- and diacritic-insensitive, and an empty query matches everything, so callers
    /// do not need to special-case the unfiltered state.
    static func matches(_ image: ImageSummary, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if image.shortID.localizedCaseInsensitiveContains(needle) { return true }
        if image.id.localizedCaseInsensitiveContains(needle) { return true }
        return image.repoTags.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// Orders images by one column.
    ///
    /// Text columns use `localizedStandardCompare`, so `nginx:9` sorts before `nginx:10`
    /// rather than after it. Ties fall back to the repository name, which keeps the table
    /// from reshuffling on every refresh when several rows share a size or a timestamp.
    static func sorted(
        _ images: [ImageSummary],
        by key: TrackCImageSortKey,
        ascending: Bool
    ) -> [ImageSummary] {
        let ordered = images.sorted { lhs, rhs in
            switch key {
            case .repository:
                if lhs.repository != rhs.repository {
                    return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
                }
                return lhs.tag.localizedStandardCompare(rhs.tag) == .orderedAscending
            case .tag:
                if lhs.tag != rhs.tag {
                    return lhs.tag.localizedStandardCompare(rhs.tag) == .orderedAscending
                }
                return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return lhs.size < rhs.size }
                return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
            case .created:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
            case .used:
                if lhs.containersUsing != rhs.containersUsing {
                    return lhs.containersUsing < rhs.containersUsing
                }
                return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
            }
        }
        return ascending ? ordered : ordered.reversed()
    }

    /// Filters, sorts, and splits into the two sections the screen shows.
    ///
    /// Dangling layers are always ordered largest-first regardless of the table's sort:
    /// nobody sorts a garbage pile alphabetically, they want to know what is big.
    static func sections(
        images: [ImageSummary],
        query: String,
        sortKey: TrackCImageSortKey,
        ascending: Bool
    ) -> (tagged: [ImageSummary], dangling: [ImageSummary]) {
        let visible = images.filter { matches($0, query: query) }
        let tagged = sorted(visible.filter { !$0.isDangling }, by: sortKey, ascending: ascending)
        let dangling = visible.filter(\.isDangling).sorted { $0.size > $1.size }
        return (tagged, dangling)
    }

    /// Total bytes across a set of images, for the header's subtitle.
    static func totalSize(_ images: [ImageSummary]) -> Int64 {
        images.reduce(Int64(0)) { $0 + max(0, $1.size) }
    }
}

// MARK: - Selected-image dependencies

/// The container relationship shown by the selected-image inspector.
///
/// Docker's image list supplies the authoritative reference count, while the container
/// inventory can supply names only when a container's image reference exactly matches a
/// current tag or the full image ID. Retagging and independently refreshed inventories
/// can make those two views disagree, so the UI represents that disagreement instead of
/// inventing a complete dependency list.
enum TrackCImageInspector {

    /// Shown wherever a container-use fact would be if the Disk scan had run.
    /// Matches `TrackCVolumeInspector.unscannedValue`: "not reported" reads as Docker
    /// having no answer, when the truth is that nobody has asked it yet.
    static let unscannedValue = "Not scanned yet"

    enum ContainerUsage: Equatable {
        /// Docker omitted the image's `Containers` count. The names, if any, are still
        /// exact matches from the current container inventory, not a total.
        case unreported(known: [ContainerSummary])
        case none
        case complete([ContainerSummary])
        /// Docker reported more references than are present in the current container
        /// inventory. The missing references cannot safely be named.
        case incomplete(known: [ContainerSummary], reported: Int)
        /// The inventories disagree in the other direction, so neither count should be
        /// presented as a complete dependency truth.
        case inconsistent(known: [ContainerSummary], reported: Int)
    }

    static func containerUsage(
        for image: ImageSummary,
        in containers: [ContainerSummary]
    ) -> ContainerUsage {
        let currentReferences = Set(
            image.repoTags.filter { !$0.isEmpty && $0 != "<none>:<none>" }
        )
        let known = containers.filter { container in
            container.image == image.id || currentReferences.contains(container.image)
        }

        switch image.containersUsing {
        case ..<0:
            return .unreported(known: known)
        case 0 where known.isEmpty:
            return .none
        case 0:
            return .inconsistent(known: known, reported: 0)
        case let reported where reported == known.count:
            return .complete(known)
        case let reported where known.count < reported:
            return .incomplete(known: known, reported: reported)
        default:
            return .inconsistent(known: known, reported: image.containersUsing)
        }
    }
}

// MARK: - Pull log

/// The honest lifecycle of one explicit Engine image-pull request.
///
/// A Docker pull is a stream: HTTP success alone is not a result, because the daemon
/// reports registry failures as JSON lines in a 200 response. The Images sheet keeps
/// the entered reference and the terminal result together, so a successful pull does
/// not disappear before the person can see what completed and a failure has a real retry
/// state instead of being only the last line of an output viewport.
enum TrackCImagePullState: Equatable {
    case ready
    case pulling(reference: String)
    case succeeded(reference: String)
    case failed(reference: String, message: String)

    var isWorking: Bool {
        if case .pulling = self { return true }
        return false
    }

    var allowsPull: Bool {
        switch self {
        case .ready, .failed: return true
        case .pulling, .succeeded: return false
        }
    }

    var reference: String? {
        switch self {
        case .ready: return nil
        case .pulling(let reference), .succeeded(let reference), .failed(let reference, _):
            return reference
        }
    }

    var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    /// Docker is the parser and authority for reference syntax. The UI performs only
    /// the one safe normalization it can guarantee: outer whitespace never belongs to a
    /// reference, and an empty input cannot begin a request.
    static func reference(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TrackCPullLog {

    /// How many lines the log keeps. A multi-layer pull emits thousands of progress
    /// updates; the box only ever shows the tail, and holding the rest is pure leak.
    static let limit = 300

    /// The layer id a progress line belongs to, when it names one.
    ///
    /// `DockerClient.pull` formats per-layer updates as `"<layer>: <status> <progress>"`,
    /// so the prefix before the first colon is a candidate. Being a prefix is not enough,
    /// though — the engine also emits `"Status: Downloaded newer image for nginx:latest"`,
    /// `"Digest: sha256:…"` and `"latest: Pulling from library/nginx"`, and treating those
    /// as layer ids would collapse two unrelated lines into one and lose output.
    ///
    /// So the candidate must actually look like a layer id: at least eight lowercase hex
    /// characters and nothing else. Docker's short ids are twelve and some registries
    /// send the full sixty-four, while every false positive above fails on a non-hex
    /// character or on length.
    static func layerKey(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon])
        guard key.count >= 8 else { return nil }
        guard key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return key
    }

    /// Appends a progress line, collapsing consecutive updates for the same layer.
    ///
    /// Docker sends one line per progress tick per layer, interleaved. Appending them all
    /// produces a thousand-line wall of `Downloading  4.2MB/91MB`; rewriting the most
    /// recent line for that layer instead produces a live per-layer readout, which is
    /// what the Docker CLI shows and what people expect to see.
    static func appending(_ line: String, to lines: [String], limit: Int = limit) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines }

        var result = lines
        if let key = layerKey(trimmed),
           let last = result.last,
           layerKey(last) == key {
            result[result.count - 1] = trimmed
        } else {
            result.append(trimmed)
        }
        if result.count > limit { result.removeFirst(result.count - limit) }
        return result
    }

    /// Appends a batch, applying the same collapsing rules line by line.
    static func appending(contentsOf newLines: [String], to lines: [String], limit: Int = limit) -> [String] {
        newLines.reduce(lines) { appending($1, to: $0, limit: limit) }
    }
}

/// A lock-guarded hand-off for pull progress.
///
/// `DockerClient.pull` calls its progress closure from the stream reader's own thread.
/// Hopping each line onto the main actor with its own `Task` would both storm the
/// scheduler and lose ordering — unstructured tasks have no FIFO guarantee, so lines
/// would interleave wrongly. Buffering here and draining on a timer keeps the order the
/// engine sent and costs one wake-up every eighth of a second.
final class TrackCPullBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private var pending: [String] = []

    func append(_ line: String) {
        lock.lock()
        pending.append(line)
        lock.unlock()
    }

    /// Returns everything buffered since the last call and empties the buffer.
    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = pending
        pending.removeAll(keepingCapacity: true)
        return taken
    }
}
