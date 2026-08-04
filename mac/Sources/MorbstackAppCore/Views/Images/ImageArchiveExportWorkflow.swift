// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Presentation state for the native image-archive save workflow. The archive stream,
// destination policy, and atomic commit live in MorbFeatures/ImageArchiveExporter;
// this file owns only the UI's truthful progress, cancellation, and feedback state.

import Foundation
import MorbFeatures
import SwiftUI

struct ImageArchiveExportOperation: Identifiable {
    let id = UUID()
    let imageLabel: String
    let outputURL: URL
    var bytesWritten: Int64 = 0
    var totalBytes: Int64?
    var isCancellationRequested = false

    mutating func record(_ progress: ImageArchiveExportProgress) {
        bytesWritten = progress.bytesWritten
        totalBytes = progress.totalBytes
    }
}

struct ImageArchiveExportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static func success(result: ImageArchiveExportResult) -> Self {
        Self(
            title: "Image Archive Exported",
            message: "Saved \(Formatters.bytesString(result.bytes)) to \(result.destination.path).")
    }

    static func cancelled() -> Self {
        Self(
            title: "Image Archive Export Cancelled",
            message: "No archive was saved.")
    }

    static func failure(_ error: Error) -> Self {
        Self(
            title: "Couldn’t Export Image",
            message: MorbErrorMessage.text(for: error))
    }
}

/// A tiny locked flag shared between the main actor and the blocking Engine worker.
/// The engine stream checks it for every received body chunk; returning `false` from
/// the service callback discards the private staging file instead of publishing it.
final class ImageArchiveExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

/// Coalesces a hot Engine body stream before it reaches SwiftUI. The byte count is
/// still the exact value written by the service, but the main actor receives at most
/// one update per tenth of a second instead of one invalidation per network chunk.
final class ImageArchiveExportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let update: @MainActor (ImageArchiveExportProgress) -> Void
    private var newest: ImageArchiveExportProgress?
    private var deliveryScheduled = false

    init(update: @escaping @MainActor (ImageArchiveExportProgress) -> Void) {
        self.update = update
    }

    func send(_ progress: ImageArchiveExportProgress) {
        lock.lock()
        newest = progress
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let progress = self?.takeNewest() else { return }
            await self?.update(progress)
        }
    }

    private func takeNewest() -> ImageArchiveExportProgress? {
        lock.lock()
        defer { lock.unlock() }
        let progress = newest
        newest = nil
        deliveryScheduled = false
        return progress
    }
}

/// Exposes the selected-image export command to the system menu bar while this route
/// is the active scene. `focusedSceneValue` keeps it available even when table focus is
/// elsewhere, which is the Apple-prescribed bridge between selection context and a
/// macOS command menu.
private struct ImageArchiveExportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var imageArchiveExportAction: (() -> Void)? {
        get { self[ImageArchiveExportActionKey.self] }
        set { self[ImageArchiveExportActionKey.self] = newValue }
    }
}

/// A document-modal progress presentation for a save operation the user explicitly
/// initiated from the selected image. It deliberately relies on the system sheet,
/// `Form`, `LabeledContent`, and `ProgressView` rather than inventing a dashboard
/// treatment for a single file stream.
struct ImageArchiveExportSheet: View {
    let operation: ImageArchiveExportOperation
    let cancel: () -> Void

    var body: some View {
        // A document-modal sheet without its own title bar or toolbar reads as an
        // orphaned form; wrapping it in NavigationStack with a title and a toolbar Cancel
        // matches the house pattern used by the other sheets in this route (see
        // ImageTagSheet and LocalImageRunSheet).
        NavigationStack {
            Form {
                Section("Image Archive") {
                    LabeledContent("Image") {
                        Text(operation.imageLabel)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Destination") {
                        Text(operation.outputURL.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Section("Progress") {
                    if let totalBytes = operation.totalBytes, totalBytes > 0 {
                        ProgressView(
                            value: min(Double(operation.bytesWritten) / Double(totalBytes), 1)) {
                            Text(operation.isCancellationRequested ? "Cancelling export…" : "Saving image archive")
                        } currentValueLabel: {
                            Text("\(Formatters.bytesString(operation.bytesWritten)) of \(Formatters.bytesString(totalBytes))")
                        }
                    } else {
                        ProgressView(operation.isCancellationRequested ? "Cancelling export…" : "Saving image archive")
                        LabeledContent("Written", value: Formatters.bytesString(operation.bytesWritten))
                    }
                }
            }
            .formStyle(.automatic)
            .navigationTitle("Exporting Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(operation.isCancellationRequested ? "Cancelling…" : "Cancel", role: .cancel) {
                        cancel()
                    }
                    .disabled(operation.isCancellationRequested)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 520)
    }
}
