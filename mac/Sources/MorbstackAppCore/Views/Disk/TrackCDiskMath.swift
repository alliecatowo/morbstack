// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The arithmetic behind the Disk screen, with no SwiftUI in sight.
//
// Everything the Disk screen shows is a *derivation*: `/system/df` reports four totals
// and one aggregate reclaimable figure, but the UI promises a per-category breakdown
// with a reclaimable overlay and a prune preview that names the things about to be
// deleted. Those derivations are the part most likely to be wrong and the part hardest
// to eyeball in a screenshot, so they live here as free functions over plain values and
// are covered by `TrackCDiskMathTests`.
//
// The honesty rule for this file: never invent a number. Where the engine does not
// report enough to be exact — container writable-layer sizes are not in the list
// endpoints, and build-cache records are not enumerable through anything the app
// already calls — the result is marked `isEstimate` and the UI says so out loud.

import Foundation
import MorbstackKit

// MARK: - Categories

/// The four buckets the stacked bar is divided into, in bar order.
///
/// Order is load-bearing: it is the left-to-right order of the bar, the top-to-bottom
/// order of the legend, and the order of the prune rows, and those three agreeing is
/// most of what makes the screen legible.
enum TrackCDiskCategory: String, CaseIterable, Identifiable, Sendable {
    case images
    case containers
    case volumes
    case buildCache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .containers: return "Containers"
        case .volumes: return "Volumes"
        case .buildCache: return "Build cache"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "square.on.square"
        case .containers: return "shippingbox"
        case .volumes: return "externaldrive"
        case .buildCache: return "hammer"
        }
    }

    /// One line describing precisely what a prune of this category removes. Shown in
    /// the preview sheet's header, where "what exactly am I about to lose" is the only
    /// question the user has.
    var pruneSummary: String {
        switch self {
        case .images:
            return "Removes dangling image layers — those left behind by a rebuild and no longer referenced by any tag."
        case .containers:
            return "Removes every container that is not running, along with its writable layer and anonymous volumes."
        case .volumes:
            return "Removes unused anonymous volumes. Named volumes are kept even when nothing is using them."
        case .buildCache:
            return "Removes build cache records that are not in use by the current image graph."
        }
    }

    /// The bytes this category occupies, pulled out of a `docker system df` fold.
    func bytes(in usage: DiskUsage) -> Int64 {
        switch self {
        case .images: return usage.imagesTotal
        case .containers: return usage.containersTotal
        case .volumes: return usage.volumesTotal
        case .buildCache: return usage.buildCacheTotal
        }
    }
}

// MARK: - Segments

/// One slice of the stacked bar: how much a category holds, and how much of that is
/// garbage.
struct TrackCDiskSegment: Identifiable, Hashable, Sendable {

    var category: TrackCDiskCategory
    /// Total bytes attributed to the category.
    var bytes: Int64
    /// The part of `bytes` a prune would give back. Never greater than `bytes`.
    var reclaimableBytes: Int64
    /// `true` when `reclaimableBytes` was inferred rather than reported. Drives the
    /// "approximate" wording in the legend, so it must not be set optimistically.
    var isEstimate: Bool

    var id: String { category.rawValue }

    /// The share of `total` this segment occupies, in `0...1`.
    func fraction(of total: Int64) -> Double {
        guard total > 0, bytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }
}

// MARK: - Named size

/// One row of a "largest things" list: something with a name and a number of bytes.
///
/// Deliberately not generic over `ImageSummary` and `VolumeSummary`. The two have
/// nothing in common but those two fields, and flattening them here is what lets the
/// view draw one row type instead of two nearly-identical ones.
struct TrackCNamedSize: Identifiable, Hashable, Sendable {

    var id: String
    /// What to print.
    var label: String
    /// The longer form, for the tooltip: every tag, or the mountpoint.
    var detail: String?
    var bytes: Int64
}

// MARK: - Disk image footprint

/// What `disk.img` claims to be versus what it actually costs on APFS.
///
/// A Morbstack VM disk is a sparse file: it is created at its maximum size and only
/// consumes blocks as the guest writes them. Every naive size readout — Finder's Get
/// Info, `ls -l`, `du --apparent-size` — reports the maximum, which is why a fresh
/// install looks like it ate 64 GB. This is the pair of numbers that puts that right.
struct TrackCDiskImageFootprint: Hashable, Sendable {

    var path: String
    /// `st_size`: the length of the file as the guest sees it.
    var apparentBytes: Int64
    /// `st_blocks * 512`: the blocks APFS has actually allocated.
    var actualBytes: Int64

    /// How much the sparseness is saving right now.
    var savedBytes: Int64 { max(0, apparentBytes - actualBytes) }

    /// Allocated over apparent, in `0...1`. Zero-length files read as full.
    var occupancy: Double {
        guard apparentBytes > 0 else { return 1 }
        return min(1, max(0, Double(actualBytes) / Double(apparentBytes)))
    }

    /// `true` when the file is meaningfully sparse — under the threshold we say so, to
    /// avoid captioning a 99.7%-full image as a clever space-saving trick.
    var isSparse: Bool { occupancy < 0.98 && savedBytes > 0 }
}

// MARK: - Prune previews

/// Which prune button was pressed.
enum TrackCPruneTarget: String, CaseIterable, Identifiable, Sendable {
    case containers
    case images
    case volumes
    case buildCache

    var id: String { rawValue }

    var category: TrackCDiskCategory {
        switch self {
        case .containers: return .containers
        case .images: return .images
        case .volumes: return .volumes
        case .buildCache: return .buildCache
        }
    }
}

/// One thing a prune is going to delete (or pointedly not delete).
struct TrackCPruneItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
    /// Bytes this item will free, when the engine told us. `nil` means "unknown", which
    /// is different from zero and is rendered differently.
    var bytes: Int64?
}

/// The answer to "what happens if I press this", computed entirely from lists the app
/// already holds — no extra round trip, so the sheet opens instantly.
struct TrackCPrunePreview: Hashable, Sendable {

    var target: TrackCPruneTarget
    /// Everything that will be removed.
    var items: [TrackCPruneItem]
    /// Things that look like candidates but are deliberately spared, with the reason in
    /// `detail`. Named unused volumes are the whole reason this exists: `docker volume
    /// prune` silently skips them, and a preview that omitted them would read as a
    /// promise to delete somebody's database.
    var kept: [TrackCPruneItem]
    /// Sum of the item sizes we actually know.
    var knownBytes: Int64
    /// `true` when at least one item's size is unknown, so `knownBytes` is a floor.
    var hasUnknownSizes: Bool

    var isEmpty: Bool { items.isEmpty }

    /// `3 items` / `1 item`, for the sheet's confirm button.
    var countLabel: String { items.count == 1 ? "1 item" : "\(items.count) items" }
}

// MARK: - The math

enum TrackCDiskMath {

    // MARK: Segments

    /// Splits a `docker system df` snapshot into the four bar segments, attributing the
    /// aggregate reclaimable figure across them using the live lists.
    ///
    /// Exactness, per category:
    ///
    ///   * **images** — exact. A dangling image's `Size` is reported per image and the
    ///     app already has the list.
    ///   * **volumes** — exact when usage data is present; an unused volume with an
    ///     unknown size contributes zero rather than a guess.
    ///   * **containers** — exact at the boundaries (all running, or none running) and a
    ///     count-weighted estimate in between, because writable-layer sizes are not on
    ///     `/containers/json`.
    ///   * **build cache** — whatever is left of the engine's own reclaimable total once
    ///     the other three are accounted for, clamped into range. Always an estimate.
    static func segments(
        usage: DiskUsage,
        containers: [ContainerSummary],
        images: [ImageSummary],
        volumes: [VolumeSummary]
    ) -> [TrackCDiskSegment] {

        let imagesReclaimable = min(
            max(0, usage.imagesTotal),
            images.filter(\.isDangling).reduce(Int64(0)) { $0 + max(0, $1.size) })

        let volumesReclaimable = min(
            max(0, usage.volumesTotal),
            volumes.filter(\.isUnused).reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) })

        let (containersReclaimable, containersEstimated) = containerReclaimable(
            total: usage.containersTotal, containers: containers)

        // The engine's own reclaimable number is the most trustworthy thing we have, so
        // build cache gets the residual rather than a fresh guess. Clamped both ways:
        // the residual can go negative when our per-category figures overshoot, and it
        // can exceed the cache when the engine counted something we did not.
        let accounted = imagesReclaimable + volumesReclaimable + containersReclaimable
        let cacheTotal = max(0, usage.buildCacheTotal)
        let cacheReclaimable = min(max(0, usage.reclaimable - accounted), cacheTotal)

        return [
            TrackCDiskSegment(
                category: .images,
                bytes: max(0, usage.imagesTotal),
                reclaimableBytes: imagesReclaimable,
                isEstimate: false),
            TrackCDiskSegment(
                category: .containers,
                bytes: max(0, usage.containersTotal),
                reclaimableBytes: containersReclaimable,
                isEstimate: containersEstimated),
            TrackCDiskSegment(
                category: .volumes,
                bytes: max(0, usage.volumesTotal),
                reclaimableBytes: volumesReclaimable,
                isEstimate: false),
            TrackCDiskSegment(
                category: .buildCache,
                bytes: cacheTotal,
                reclaimableBytes: cacheReclaimable,
                isEstimate: cacheReclaimable > 0),
        ]
    }

    /// Reclaimable container bytes, and whether the answer is a guess.
    static func containerReclaimable(
        total: Int64,
        containers: [ContainerSummary]
    ) -> (bytes: Int64, isEstimate: Bool) {
        let total = max(0, total)
        guard total > 0, !containers.isEmpty else { return (0, false) }
        let stopped = containers.filter { !$0.isRunning }.count
        if stopped == 0 { return (0, false) }
        if stopped == containers.count { return (total, false) }
        let share = Double(total) * Double(stopped) / Double(containers.count)
        return (Int64(share.rounded()), true)
    }

    // MARK: Bar layout

    /// Turns byte counts into pixel widths that add up to exactly `totalWidth`.
    ///
    /// A proportional split alone makes a 40 MB segment next to 12 GB of images
    /// literally invisible — sub-pixel, so it does not anti-alias into anything either.
    /// Non-empty segments are therefore floored at `minimumSegmentWidth` and the
    /// difference is borrowed proportionally from the segments that can afford it. When
    /// the floor cannot be honoured (a very narrow bar, or many segments) the split
    /// falls back to pure proportion rather than overflowing the bar.
    ///
    /// Returns one width per input, aligned by index, with zeros for empty segments.
    static func barWidths(
        byteValues: [Int64],
        totalWidth: Double,
        minimumSegmentWidth: Double = 5
    ) -> [Double] {
        let values = byteValues.map { max(0, $0) }
        let total = values.reduce(Int64(0), +)
        guard total > 0, totalWidth > 0 else { return Array(repeating: 0, count: values.count) }

        var widths = values.map { totalWidth * Double($0) / Double(total) }
        let nonEmpty = values.indices.filter { values[$0] > 0 }
        guard minimumSegmentWidth > 0,
              Double(nonEmpty.count) * minimumSegmentWidth <= totalWidth
        else { return widths }

        let starved = nonEmpty.filter { widths[$0] < minimumSegmentWidth }
        guard !starved.isEmpty else { return widths }

        let borrowed = starved.reduce(0.0) { $0 + (minimumSegmentWidth - widths[$1]) }
        let donors = nonEmpty.filter { widths[$0] >= minimumSegmentWidth }
        let donorWidth = donors.reduce(0.0) { $0 + widths[$1] }

        for index in starved { widths[index] = minimumSegmentWidth }
        if donorWidth > 0 {
            let scale = max(0, (donorWidth - borrowed) / donorWidth)
            for index in donors { widths[index] *= scale }
        }
        return widths
    }

    // MARK: Prune previews

    /// Volume names Docker generated itself, which is what `docker volume prune`
    /// removes: 64 lowercase hex characters and nothing else.
    static func isAnonymousVolumeName(_ name: String) -> Bool {
        guard name.count == 64 else { return false }
        return name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// A volume name at a length a person can read.
    ///
    /// An anonymous volume is named after a 64-character hex digest. Printed in full it
    /// is three times the width of the longest real name in the list, so three anonymous
    /// volumes decide the column width for all thirteen and the named ones — the only
    /// ones anybody is looking for — end up crushed against the left margin. Docker's own
    /// CLI abbreviates identifiers to twelve characters for exactly this reason, and
    /// twelve is still enough to paste back into `docker volume inspect`.
    static func volumeDisplayName(_ name: String) -> String {
        isAnonymousVolumeName(name) ? String(name.prefix(12)) : name
    }

    // MARK: Biggest items

    /// The `limit` largest tagged images, biggest first.
    ///
    /// Dangling layers are left out on purpose. They are already called out by their own
    /// row in the Images screen and by the reclaimable hatch in the bar, and a list whose
    /// top two entries are both `<none>` tells the reader nothing they can act on.
    static func largestImages(_ images: [ImageSummary], limit: Int) -> [TrackCNamedSize] {
        images
            .filter { !$0.isDangling && $0.size > 0 }
            .sorted { ($0.size, $0.id) > ($1.size, $1.id) }
            .prefix(limit)
            .map {
                TrackCNamedSize(
                    id: $0.id,
                    label: $0.repoTags.first ?? $0.shortID,
                    detail: $0.repoTags.joined(separator: ", "),
                    bytes: $0.size)
            }
    }

    /// The `limit` largest volumes, biggest first.
    ///
    /// A volume whose size the engine did not report is skipped rather than sorted as
    /// zero: `nil` means "not measured", and burying a possibly-huge volume at the bottom
    /// of a list headed "largest" would be a lie told by omission.
    static func largestVolumes(_ volumes: [VolumeSummary], limit: Int) -> [TrackCNamedSize] {
        volumes
            .compactMap { volume -> TrackCNamedSize? in
                guard let size = volume.size, size > 0 else { return nil }
                return TrackCNamedSize(
                    id: volume.name,
                    label: volumeDisplayName(volume.name),
                    detail: volume.mountpoint.isEmpty ? volume.name : volume.mountpoint,
                    bytes: size)
            }
            .sorted { ($0.bytes, $0.id) > ($1.bytes, $1.id) }
            .prefix(limit)
            .map { $0 }
    }

    /// Builds the "here is what will go" list for one prune button.
    static func prunePreview(
        target: TrackCPruneTarget,
        usage: DiskUsage?,
        containers: [ContainerSummary],
        images: [ImageSummary],
        volumes: [VolumeSummary]
    ) -> TrackCPrunePreview {
        switch target {
        case .containers:
            return containerPreview(containers)
        case .images:
            return imagePreview(images)
        case .volumes:
            return volumePreview(volumes)
        case .buildCache:
            return buildCachePreview(usage)
        }
    }

    private static func containerPreview(_ containers: [ContainerSummary]) -> TrackCPrunePreview {
        // Matches `POST /containers/prune`, which removes everything not in the running
        // or paused state. A paused container is still holding its process table, so it
        // survives — listing it as doomed here would be a lie.
        let doomed = containers
            .filter { $0.state != "running" && $0.state != "paused" && $0.state != "restarting" }
            .sorted { $0.createdAt > $1.createdAt }

        return TrackCPrunePreview(
            target: .containers,
            items: doomed.map {
                TrackCPruneItem(
                    id: $0.id,
                    title: $0.displayName,
                    detail: "\($0.image) · \($0.status.isEmpty ? $0.state : $0.status)",
                    bytes: nil)
            },
            kept: [],
            knownBytes: 0,
            hasUnknownSizes: !doomed.isEmpty)
    }

    private static func imagePreview(_ images: [ImageSummary]) -> TrackCPrunePreview {
        let dangling = images.filter(\.isDangling).sorted { $0.size > $1.size }
        let untaggedButUsed = dangling.filter { $0.containersUsing > 0 }
        let removable = dangling.filter { $0.containersUsing <= 0 }

        return TrackCPrunePreview(
            target: .images,
            items: removable.map {
                TrackCPruneItem(
                    id: $0.id,
                    title: $0.shortID,
                    detail: "dangling · created \(Formatters.relativeDate($0.createdAt))",
                    bytes: $0.size)
            },
            kept: untaggedButUsed.map {
                TrackCPruneItem(
                    id: $0.id,
                    title: $0.shortID,
                    detail: "in use by \($0.containersUsing) container\($0.containersUsing == 1 ? "" : "s")",
                    bytes: $0.size)
            },
            knownBytes: removable.reduce(Int64(0)) { $0 + max(0, $1.size) },
            hasUnknownSizes: false)
    }

    private static func volumePreview(_ volumes: [VolumeSummary]) -> TrackCPrunePreview {
        let unused = volumes.filter(\.isUnused)
        let removable = unused.filter { isAnonymousVolumeName($0.name) }
        let spared = unused.filter { !isAnonymousVolumeName($0.name) }

        return TrackCPrunePreview(
            target: .volumes,
            items: removable.map {
                TrackCPruneItem(
                    id: $0.name,
                    title: String($0.name.prefix(20)) + "…",
                    detail: "anonymous · \($0.driver)",
                    bytes: $0.size)
            },
            kept: spared.map {
                TrackCPruneItem(
                    id: $0.name,
                    title: $0.name,
                    detail: "named volume — prune leaves these alone",
                    bytes: $0.size)
            },
            knownBytes: removable.reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) },
            hasUnknownSizes: removable.contains { $0.size == nil })
    }

    private static func buildCachePreview(_ usage: DiskUsage?) -> TrackCPrunePreview {
        // The app never lists build cache records — nothing else needs them, and adding
        // an endpoint just to itemise a sheet is not worth a round trip. So the preview
        // is a single honest summary row rather than a fabricated inventory.
        let total = max(0, usage?.buildCacheTotal ?? 0)
        guard total > 0 else {
            return TrackCPrunePreview(
                target: .buildCache, items: [], kept: [], knownBytes: 0, hasUnknownSizes: false)
        }
        return TrackCPrunePreview(
            target: .buildCache,
            items: [
                TrackCPruneItem(
                    id: "build-cache",
                    title: "Unused build cache",
                    detail: "\(Formatters.bytesString(total)) of cache records, minus anything still in use",
                    bytes: nil)
            ],
            kept: [],
            knownBytes: 0,
            hasUnknownSizes: true)
    }

    // MARK: Sparse file footprint

    /// Builds a footprint from raw `stat` numbers. Pure, so the interesting cases —
    /// heavily sparse, fully allocated, empty file — are testable without a 64 GB file.
    static func footprint(path: String, apparentBytes: Int64, blocks512: Int64) -> TrackCDiskImageFootprint {
        TrackCDiskImageFootprint(
            path: path,
            apparentBytes: max(0, apparentBytes),
            actualBytes: max(0, blocks512) * 512)
    }

    /// Reads the VM disk image's real footprint, or `nil` when there is no image yet.
    ///
    /// `stat(2)` rather than `FileManager.attributesOfItem`: the allocated-block count
    /// is the entire point of this readout and `FileAttributeKey` has no key for it —
    /// `.size` is `st_size`, the apparent size, which is the number we are here to
    /// contradict. Read-only, and cheap enough to call on a refresh.
    static func readFootprint(path: String = MorbPaths.diskImage.path) -> TrackCDiskImageFootprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return footprint(path: path, apparentBytes: Int64(info.st_size), blocks512: Int64(info.st_blocks))
    }
}
