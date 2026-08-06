// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Finding syft and grype on this Mac, and reporting honestly when they are not
// there. Both are OPTIONAL downloads (`scripts/fetch-scan-tools.sh`) — Morbstack
// itself must build and run without them, and `morb scan` without them must say in
// one sentence how to get them rather than failing with a bare "command not found".

import Foundation
import MorbFeatures
import MorbstackKit

/// Where a tool binary was found, and how to run it.
public struct LocatedTool: Sendable {
    public var name: String
    public var path: String
    public var version: String?
}

public enum ToolLocator {

    /// Search order for `syft`/`grype`.
    ///
    /// `ScanPaths.toolsDirectory` (`$MORBSTACK_HOME/scan/bin`) is checked first: it is
    /// where `scripts/fetch-scan-tools.sh` installs the pinned copies, on a repo
    /// checkout and a shipped app alike, and unlike the directories below it is never
    /// swept into a signed app bundle (see that constant's doc comment).
    ///
    /// The remaining candidates match `MorbCliPlugins.sourceBinary` in MorbstackKit
    /// (not reused directly — that type is `internal` to its own module for this pair
    /// — but the layout it encodes is a project-wide contract: a shipped `.app`
    /// bundles `dist/host-bin` under `Contents/Resources/host-bin`, a dev checkout has
    /// `mac/.build/debug/morb` with `dist/host-bin` a few directories up). syft/grype
    /// are deliberately never fetched there (see `ScanPaths.toolsDirectory`), but a
    /// hand-placed copy is still honored rather than silently ignored. Falls through
    /// to `PATH` last: a developer who already has syft/grype from Homebrew for other
    /// projects should not be told to re-download 60 MB of binaries this repo can
    /// already see.
    static func candidateDirectories() -> [URL] {
        let exeDir = MorbExecutable.currentDirectory()
        var dirs: [URL] = [
            ScanPaths.toolsDirectory,
            exeDir.deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("host-bin", isDirectory: true),
            exeDir.appendingPathComponent("host-bin", isDirectory: true),
        ]
        var probe = exeDir
        for _ in 0..<8 {
            dirs.append(
                probe.appendingPathComponent("dist", isDirectory: true)
                    .appendingPathComponent("host-bin", isDirectory: true))
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        return dirs
    }

    /// Finds `name` (`"syft"` or `"grype"`), preferring the pinned copy
    /// `scripts/fetch-scan-tools.sh` fetched over whatever might be on `PATH`, so a
    /// scan's results are reproducible against the version pinned there rather than
    /// whatever a developer's Homebrew happened to have that week.
    public static func locate(_ name: String) -> LocatedTool? {
        for dir in candidateDirectories() {
            let candidate = dir.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return LocatedTool(name: name, path: candidate.path, version: version(of: candidate.path))
            }
        }
        if let onPath = Subprocess.which(name) {
            return LocatedTool(name: name, path: onPath, version: version(of: onPath))
        }
        return nil
    }

    private static func version(of path: String) -> String? {
        guard let result = try? Subprocess.run(path, ["version"], timeout: 10), result.succeeded else {
            return nil
        }
        // Both tools print a `Version: 1.2.3`-shaped line (syft: "Version:", grype:
        // "Version:") in their plain `version` output; the JSON form
        // (`version -o json`) is not used here to avoid a second exec just to save
        // one string split.
        for line in result.stdoutText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Version" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The one-sentence explanation printed whenever a scan cannot run because a
    /// tool is missing. Deliberately one sentence and deliberately actionable: this
    /// is the message users hit far more often than any error in the scan itself,
    /// on a machine that has never run `scripts/fetch-scan-tools.sh`.
    public static func missingToolMessage(_ name: String) -> String {
        "`\(name)` was not found (checked \(ScanPaths.toolsDirectory.path) and PATH) — run "
            + "`scripts/fetch-scan-tools.sh` to download it, or install it yourself and put it on PATH."
    }
}
