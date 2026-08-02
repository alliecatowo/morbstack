// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One row of the Overview tab's Mounts table, plus the Finder affordance.
//
// Split out of `ContainerOverviewTab` because a mount row is no longer four strings: it
// carries a kind badge, a reveal button whose availability depends on the kind, a
// warning that spans the whole row, and a context menu. Inline, that is forty lines
// inside a `ForEach` inside a `TrackBTable` inside a section builder, and the type
// checker starts timing out long before a human does.

import AppKit
import SwiftUI

// MARK: - Row

struct TrackBMountRow: View {

    let row: TrackBMountDisplay
    let columns: [TrackBTableColumn]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackBTableRow {
                TrackCBadge(text: row.kindLabel, symbol: row.kind.symbol, tone: row.kind.tone)
                    .help(row.kind.explanation)
                    .trackBColumn(columns[0])

                TrackBMonoText(
                    text: row.source,
                    size: 11,
                    tint: row.warning == nil ? .primary : .orange)
                    .trackBColumn(columns[1])

                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .trackBColumn(columns[2])

                TrackBMonoText(text: row.destination, size: 11)
                    .trackBColumn(columns[3])

                Text(row.accessDescription)
                    .font(.caption2)
                    .foregroundStyle(row.readOnly ? .secondary : .primary)
                    .trackBColumn(columns[4])

                revealButton
                    .trackBColumn(columns[5])
            }

            if let warning = row.warning {
                warningLine(warning)
            }
        }
        .contextMenu {
            if let hostPath = row.hostPath {
                Button("Reveal in Finder") { TrackBFinder.reveal(hostPath) }
                Button("Copy Host Path") { TrackBClipboard.copy(hostPath) }
                Divider()
            } else if row.source != "—" {
                Button(row.kind == .volume ? "Copy Volume Name" : "Copy Source") {
                    TrackBClipboard.copy(row.source)
                }
                Divider()
            }
            Button("Copy Container Path") { TrackBClipboard.copy(row.destination) }
        }
    }

    // MARK: Reveal

    /// The Finder button, shown only for a mount that corresponds to a real folder on
    /// this Mac.
    ///
    /// A volume's `Source` is a path inside the VM's disk image and a tmpfs has none at
    /// all, so a button on those rows would open a Finder window on nothing — and,
    /// worse, imply that `/var/lib/docker/volumes/pgdata/_data` is somewhere the user
    /// could go looking. The column keeps its width on every row regardless, so the
    /// table stays in register.
    @ViewBuilder
    private var revealButton: some View {
        if let hostPath = row.hostPath {
            Button {
                TrackBFinder.reveal(hostPath)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal \(hostPath) in Finder")
            .accessibilityLabel("Reveal in Finder")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    // MARK: Warning

    /// The full-width explanation under a problem row.
    ///
    /// Under the row rather than in a tooltip because this is the one failure in the
    /// table that produces no error anywhere else: the container is running, the mount
    /// is listed, and the directory is empty. A hover-only affordance would be found by
    /// exactly the people who already knew.
    private func warningLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

// MARK: - Finder

/// Opening host paths in Finder.
enum TrackBFinder {

    /// Reveals `path`, falling back to the nearest ancestor that exists.
    ///
    /// `activateFileViewerSelecting` on a path that does not exist does nothing at all —
    /// no window, no error, no beep — which reads as a dead button. A bind mount whose
    /// source has since been deleted or renamed is a completely ordinary thing to be
    /// looking at (it is often *why* somebody is looking), so walking up to the nearest
    /// real directory at least lands them in the right neighbourhood.
    @MainActor
    static func reveal(_ path: String, fileManager: FileManager = .default) {
        let target = (path as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: target) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
            return
        }
        guard let ancestor = nearestExistingAncestor(of: target, fileManager: fileManager) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ancestor)])
    }

    /// The deepest existing directory at or above `path`, or `nil` if even `/` is out of
    /// reach — which happens when the app is sandboxed away from the volume.
    ///
    /// Pure enough to test: it takes its own `FileManager`.
    static func nearestExistingAncestor(
        of path: String,
        fileManager: FileManager = .default
    ) -> String? {
        var candidate = (path as NSString).standardizingPath
        while candidate != "/" && !candidate.isEmpty {
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate.isEmpty { break }
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return fileManager.fileExists(atPath: "/") ? "/" : nil
    }
}
