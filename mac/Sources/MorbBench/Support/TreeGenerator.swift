// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deterministic file tree for the filesystem benchmarks. Deterministic on
// purpose — "generate it, do not clone the internet" from the task brief —
// so a reader can reproduce the exact same tree (same file count, same
// bytes) on their own machine instead of trusting a downloaded fixture.

import Foundation

public enum TreeGenerator {

    /// Creates `directories` subdirectories under `root`, each containing
    /// `filesPerDirectory` small text files with fixed, reproducible content.
    ///
    /// - Returns: the total file count created.
    @discardableResult
    public static func makeDeterministicTree(at root: URL, directories: Int, filesPerDirectory: Int) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var count = 0
        for directoryIndex in 0..<directories {
            let directory = root.appendingPathComponent(
                "dir-\(String(format: "%04d", directoryIndex))", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerDirectory {
                let file = directory.appendingPathComponent("file-\(String(format: "%04d", fileIndex)).txt")
                let content =
                    "morbstack bench fixture — directory \(directoryIndex), file \(fileIndex)\n"
                    + "deterministic content, regenerate with TreeGenerator.makeDeterministicTree\n"
                try content.write(to: file, atomically: false, encoding: .utf8)
                count += 1
            }
        }
        return count
    }
}
