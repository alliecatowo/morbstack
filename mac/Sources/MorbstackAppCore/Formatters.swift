// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Every number the UI shows passes through here.
//
// Formatter objects are expensive to build and the app builds these inside `body`,
// which SwiftUI may call many times a second while a stats stream is running — so the
// instances are cached statics rather than locals.

import Foundation

enum Formatters {

    // MARK: - Bytes

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file  // decimal units, matching `docker system df`
        formatter.allowsNonnumericFormatting = false  // "0 bytes", never "Zero bytes"
        return formatter
    }()

    /// `1.2 GB`. Negative inputs are rendered as `0 bytes` rather than as a negative
    /// size — a reclaimable total can go slightly negative between two samples, and
    /// "-3 KB of disk" is never a useful thing to show somebody.
    static func bytesString(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytes))
    }

    // MARK: - Dates

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let uptimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    /// `4 minutes ago`.
    ///
    /// A zero `Date` means the engine did not report a creation time; showing
    /// "56 years ago" for that would be worse than admitting we do not know.
    static func relativeDate(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "unknown" }
        let interval = -date.timeIntervalSinceNow
        if interval < 5 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// `23 seconds`, `4 minutes`, or `2 days` for a known start instant.
    ///
    /// The value is intentionally relative to an explicit `now` so the list can update
    /// locally without re-querying Docker, and so its model transform is deterministic
    /// in tests. A future timestamp is shown as zero elapsed time rather than a negative
    /// duration.
    static func uptime(since start: Date, now: Date = .now) -> String {
        guard start.timeIntervalSince1970 > 0 else { return "unknown" }
        let seconds = max(0, now.timeIntervalSince(start))
        return uptimeFormatter.string(from: seconds) ?? "0 seconds"
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// `12 Mar 2026 at 09:41` — for tooltips, where precision beats brevity.
    static func absoluteDate(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "unknown" }
        return absoluteFormatter.string(from: date)
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// `09:41:22.418` — the gutter timestamp in the log viewer.
    static func logTime(_ date: Date) -> String {
        logTimeFormatter.string(from: date)
    }

    // MARK: - Numbers

    /// Ports, PIDs, exit codes, sequence numbers: identifiers render digits-only.
    ///
    /// Never hand one of these to a locale-aware number format — `18099` is a port,
    /// `18,099` is a lie. In SwiftUI, interpolating an `Int` into a `Text` string
    /// literal builds a `LocalizedStringKey`, which *does* group thousands; route any
    /// numeric identifier through this instead.
    static func identifier(_ value: some BinaryInteger) -> String {
        String(value)
    }

    /// `12.4%`. Clamped at zero because a CPU delta straddling a container restart can
    /// come out negative, and rounded to one place because the second place is noise.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f%%", max(0, value))
    }

    /// `4.2 GB / 8 GB` for a memory gauge's caption.
    static func memoryString(used: Int64, limit: Int64) -> String {
        guard limit > 0 else { return bytesString(used) }
        return "\(bytesString(used)) / \(bytesString(limit))"
    }

    /// Collapses a duration into the shortest honest unit: `3s`, `4m`, `2h`, `6d`.
    static func compactDuration(since date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "—" }
        let seconds = Int(max(0, -date.timeIntervalSinceNow))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
