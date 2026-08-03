// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app-level recovery path for MorbDiagnostics. This is intentionally a small
// coordinator around the already-owned collector: it does not contact the daemon or
// Docker, and it never chooses an output location on the user's behalf.

import AppKit
import Foundation
import MorbstackKit
import Observation

@MainActor
@Observable
final class DiagnosticsBundleWorkflow {
    var isCollecting = false
    var notice: DiagnosticsBundleNotice?

    /// Prompts for an explicit parent folder, then starts the offline collection. The
    /// picker is cancellable before any write. Collection itself intentionally exposes
    /// no cancel action because MorbDiagnostics has no cancellation contract; claiming
    /// otherwise could leave a person unsure whether the bundle was complete.
    func chooseParentFolderAndCollect() {
        guard !isCollecting else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a parent folder for a redacted Morbstack diagnostics bundle. Review it before sharing."
        panel.prompt = "Choose Folder"

        guard panel.runModal() == .OK, let outputDirectory = panel.url else { return }
        isCollecting = true

        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                Self.collectBundle(in: outputDirectory)
            }.value
            self?.finish(outcome)
        }
    }

    private nonisolated static func collectBundle(in outputDirectory: URL) -> DiagnosticsBundleOutcome {
        do {
            return .succeeded(try MorbDiagnostics.collect(outputDirectory: outputDirectory))
        } catch {
            let message = (error as? MorbError)?.description ?? error.localizedDescription
            return .failed(message)
        }
    }

    private func finish(_ outcome: DiagnosticsBundleOutcome) {
        isCollecting = false
        switch outcome {
        case .succeeded(let result):
            let directory = URL(fileURLWithPath: result.directory, isDirectory: true)
                .standardizedFileURL
            notice = .success(directory: directory, warnings: result.warnings)
        case .failed(let message):
            notice = .failure(message: message)
        }
    }
}

private enum DiagnosticsBundleOutcome: Sendable {
    case succeeded(MorbDiagnostics.Result)
    case failed(String)
}

struct DiagnosticsBundleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let directory: URL?

    static func success(directory: URL, warnings: [String]) -> Self {
        var message = "Created a redacted diagnostics bundle at \(directory.path). Review README.txt and report.json before sharing."
        if !warnings.isEmpty {
            message += "\n\nCollection notes: \(warnings.joined(separator: "; "))"
        }
        return Self(
            title: "Diagnostics Bundle Created",
            message: message,
            directory: directory)
    }

    static func failure(message: String) -> Self {
        Self(
            title: "Couldn’t Create Diagnostics Bundle",
            message: message,
            directory: nil)
    }
}
