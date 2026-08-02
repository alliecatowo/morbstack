// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Finder affordance for a mount's host path.
//
// The Mounts table itself lives in `ContainerOverviewTab` now — a real `Table`, per
// `docs/design/COMPONENTS.md` §"What is deliberately NOT here" — but revealing a host
// path in Finder is real, testable AppKit behaviour that belongs in its own file rather
// than inline in a `TableColumn` closure.

import AppKit
import Foundation

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
