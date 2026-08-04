// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Presentation state for the one local Docker image archive load workflow. The
// file stream and Engine endpoint live in MorbFeatures/ImageArchiveImporter; this
// file uses system document UI to make its scope, progress, and uncertain cancelled
// outcome clear without adding a custom dashboard surface.

import Foundation
import MorbFeatures
import SwiftUI

struct ImageArchiveImportOperation: Identifiable {
    enum Phase: Equatable {
        case uploading
        case waitingForDocker
    }

    let id = UUID()
    let request: ImageArchiveImportRequest
    var bytesSent: Int64 = 0
    var phase: Phase = .uploading
    var isCancellationRequested = false

    var canCancel: Bool { phase == .uploading && !isCancellationRequested }

    mutating func record(_ progress: ImageArchiveImportProgress) {
        switch progress {
        case .uploading(let bytesSent, _):
            self.bytesSent = bytesSent
            phase = .uploading
        case .waitingForDocker(let bytesSent, _):
            self.bytesSent = bytesSent
            phase = .waitingForDocker
        }
    }
}

struct ImageArchiveImportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static func success(result: ImageArchiveImportResult) -> Self {
        Self(
            title: "Image Archive Loaded",
            message: "Docker completed loading \(Formatters.bytesString(result.bytesSent)) from \(result.archiveURL.lastPathComponent). Morbstack requested a local image refresh. Docker determines which images and tags the archive defines.")
    }

    static func cancelled(bytesSent: Int64, totalBytes: Int64) -> Self {
        Self(
            title: "Image Archive Load Cancelled",
            message: "Stopped sending after \(Formatters.bytesString(bytesSent)) of \(Formatters.bytesString(totalBytes)). Docker may have received part of the archive; inspect local images before retrying.")
    }

    static func failure(_ error: Error) -> Self {
        Self(
            title: "Couldn’t Load Image Archive",
            message: MorbErrorMessage.text(for: error))
    }
}

/// A locked flag shared between the document sheet and the blocking socket worker.
/// Cancellation is checked before each source chunk is sent. After the complete file
/// is written to the Engine connection, the workflow changes phase and does not expose a false
/// cancellation affordance while Docker finishes unpacking the archive.
final class ImageArchiveImportCancellation: @unchecked Sendable {
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

/// Coalesces source-byte updates before they reach SwiftUI. The counts remain exact;
/// only presentation invalidations are throttled to prevent a local file stream from
/// making the document sheet less responsive.
final class ImageArchiveImportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let update: @MainActor (ImageArchiveImportProgress) -> Void
    private var newest: ImageArchiveImportProgress?
    private var deliveryScheduled = false

    init(update: @escaping @MainActor (ImageArchiveImportProgress) -> Void) {
        self.update = update
    }

    func send(_ progress: ImageArchiveImportProgress) {
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

    /// The all-bytes-sent boundary changes cancellation semantics, so it must not wait
    /// behind the ordinary byte-count coalescing interval. Clearing `newest` also
    /// prevents an older queued upload update from moving the sheet back to its
    /// cancellable phase after Docker has the complete file.
    func sendImmediately(_ progress: ImageArchiveImportProgress) {
        lock.lock()
        newest = nil
        deliveryScheduled = false
        lock.unlock()

        Task { [update] in
            await update(progress)
        }
    }

    private func takeNewest() -> ImageArchiveImportProgress? {
        lock.lock()
        defer { lock.unlock() }
        let progress = newest
        newest = nil
        deliveryScheduled = false
        return progress
    }
}

/// A native review before the selected archive is uploaded. `NSOpenPanel` chooses the
/// document; the Form names the exact scope; the system confirmation is the final
/// mutation boundary. There is no archive preview because Docker, not Morbstack,
/// interprets the selected tar stream.
struct ImageArchiveImportReviewSheet: View {
    let request: ImageArchiveImportRequest
    let load: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Image Archive") {
                    LabeledContent("File") {
                        Text(request.archiveURL.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Size", value: Formatters.bytesString(request.bytes))
                }

                Section("Scope") {
                    Text("Streams this selected local .tar file to Morbstack’s current Docker Engine. Morbstack does not inspect the archive, contact a registry, pull or push images, or use Docker credentials.")
                        .foregroundStyle(.secondary)
                }

                Section("Docker Result") {
                    Text("Docker determines which images and tags the archive defines. Morbstack does not infer or promise tag preservation before Docker completes the load.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Load Image Archive")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Load Archive…") { showsConfirmation = true }
                }
            }
            .confirmationDialog(
                "Load Docker Image Archive?",
                isPresented: $showsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Load Archive") {
                    dismiss()
                    load()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Morbstack will send the selected \(Formatters.bytesString(request.bytes)) archive to Docker. After all bytes are sent, Docker may continue unpacking before it returns a result.")
            }
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 320)
    }
}

/// A document-modal progress presentation for the actual upload. The denominator is
/// the selected file's current byte count, never an estimated Docker completion
/// percentage. Once source bytes are sent, the phase becomes indeterminate while
/// Docker does its own processing.
struct ImageArchiveImportSheet: View {
    let operation: ImageArchiveImportOperation
    let cancel: () -> Void

    var body: some View {
        Form {
            Section("Image Archive") {
                LabeledContent("File") {
                    Text(operation.request.archiveURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Size", value: Formatters.bytesString(operation.request.bytes))
            }

            Section("Progress") {
                switch operation.phase {
                case .uploading:
                    ProgressView(
                        value: min(Double(operation.bytesSent) / Double(operation.request.bytes), 1)) {
                            Text(operation.isCancellationRequested ? "Cancelling upload…" : "Sending archive to Docker")
                        } currentValueLabel: {
                            Text("\(Formatters.bytesString(operation.bytesSent)) of \(Formatters.bytesString(operation.request.bytes))")
                        }
                case .waitingForDocker:
                    ProgressView("Waiting for Docker to load archive")
                    Text("Morbstack finished sending the complete file. Docker may still be unpacking layers or registering tags. This phase cannot be safely cancelled.")
                        .foregroundStyle(.secondary)
                }
            }

            if operation.phase == .uploading {
                Section {
                    Button(operation.isCancellationRequested ? "Cancelling…" : "Cancel", role: .cancel) {
                        cancel()
                    }
                    .disabled(!operation.canCancel)
                }
            }
        }
        .formStyle(.automatic)
        .frame(minWidth: 500, idealWidth: 560)
    }
}

/// Exposes the document-scoped import action to the standard Image menu while the
/// Images route is active. Unlike export, this action has no selected-record
/// dependency, so it remains available for an empty local image inventory.
private struct ImageArchiveImportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var imageArchiveImportAction: (() -> Void)? {
        get { self[ImageArchiveImportActionKey.self] }
        set { self[ImageArchiveImportActionKey.self] = newValue }
    }
}
