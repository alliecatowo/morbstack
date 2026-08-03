// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Presentation state for the native selected-volume archive save workflow. The
// service owns the stopped helper, read-only archive stream, atomic destination, and
// cleanup contract; this file only presents its real progress and user cancellation.

import Foundation
import MorbFeatures
import SwiftUI

struct VolumeArchiveExportOperation: Identifiable {
    let id = UUID()
    let volumeName: String
    let outputURL: URL
    var bytesWritten: Int64 = 0
    var totalBytes: Int64?
    var isCancellationRequested = false

    mutating func record(_ progress: VolumeArchiveExportProgress) {
        bytesWritten = progress.bytesWritten
        totalBytes = progress.totalBytes
    }
}

struct VolumeArchiveExportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destination: URL?

    static func success(result: VolumeArchiveExportResult) -> Self {
        Self(
            title: "Volume Archive Exported",
            message: "Saved \(Formatters.bytesString(result.bytes)) to \(result.destination.path).",
            destination: result.destination)
    }

    static func cancelled() -> Self {
        Self(
            title: "Volume Archive Export Cancelled",
            message: "No archive was saved.",
            destination: nil)
    }

    static func failure(_ error: Error) -> Self {
        Self(
            title: "Couldn’t Export Volume",
            message: MorbErrorMessage.text(for: error),
            destination: nil)
    }
}

/// A small lock-protected flag read from the Engine stream's worker thread. Returning
/// `false` from the service progress callback makes the service discard its private
/// staging file and remove its owned helper before returning cancellation.
final class VolumeArchiveExportCancellation: @unchecked Sendable {
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

/// Coalesces the stream's exact byte counter before invalidating the main-actor view.
/// The UI shows every delivered value as a real write count while avoiding one SwiftUI
/// update per Engine body chunk.
final class VolumeArchiveExportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let update: @MainActor (VolumeArchiveExportProgress) -> Void
    private var newest: VolumeArchiveExportProgress?
    private var deliveryScheduled = false

    init(update: @escaping @MainActor (VolumeArchiveExportProgress) -> Void) {
        self.update = update
    }

    func send(_ progress: VolumeArchiveExportProgress) {
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

    private func takeNewest() -> VolumeArchiveExportProgress? {
        lock.lock()
        defer { lock.unlock() }
        let progress = newest
        newest = nil
        deliveryScheduled = false
        return progress
    }
}

/// A document-modal progress presentation for the one selected-volume save operation.
/// It uses standard Form/LabeledContent/ProgressView behavior: determinate only when
/// Docker supplies a content length, otherwise an indeterminate progress indicator and
/// the actual byte count written to the private staging archive.
struct VolumeArchiveExportSheet: View {
    let operation: VolumeArchiveExportOperation
    let cancel: () -> Void

    var body: some View {
        Form {
            Section("Volume Archive") {
                LabeledContent("Volume") {
                    Text(operation.volumeName)
                        .font(.system(.body, design: .monospaced))
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
                Text(
                    "Morbstack reads the selected volume through a temporary stopped helper with a read-only mount. The volume is not changed.")
                    .foregroundStyle(.secondary)
            }

            Section("Progress") {
                if let totalBytes = operation.totalBytes, totalBytes > 0 {
                    ProgressView(
                        value: min(Double(operation.bytesWritten) / Double(totalBytes), 1)) {
                        Text(operation.isCancellationRequested ? "Cancelling export…" : "Saving volume archive")
                    } currentValueLabel: {
                        Text("\(Formatters.bytesString(operation.bytesWritten)) of \(Formatters.bytesString(totalBytes))")
                    }
                } else {
                    ProgressView(operation.isCancellationRequested ? "Cancelling export…" : "Saving volume archive")
                    LabeledContent("Written", value: Formatters.bytesString(operation.bytesWritten))
                }
            }

            Section {
                Button(operation.isCancellationRequested ? "Cancelling…" : "Cancel", role: .cancel) {
                    cancel()
                }
                .disabled(operation.isCancellationRequested)

                Text("Cancelling discards the private archive. Morbstack attempts to remove its temporary helper before reporting the result; no archive is saved.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
    }
}
