// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One file's contents, read out of a container and shown as a document.
//
// It is a reader. There is no edit field, no save-back, and no control implying either
// will arrive: the Engine API's write half (`PUT …/archive`) rewrites a live
// container's filesystem, which deserves its own decision rather than a button parked
// next to a text view.
//
// The two honest limits it has to state, and does:
//
//  - **A ceiling on what it reads.** Two megabytes. A larger file is shown up to that
//    point with the real total beside it, rather than refused or silently clipped.
//  - **Bytes that are not text.** A NUL byte or invalid UTF-8 ends the attempt and the
//    sheet says which of the two it was, because "cannot display" without a reason is
//    the same as no answer.

import SwiftUI

struct ContainerFileViewerSheet: View {

    let entry: ContainerFileEntry
    let container: ContainerSummary
    let client: DockerClient
    let saver: ContainerFileSaver

    @Environment(\.dismiss) private var dismiss

    @State private var read: ContainerFileRead?
    @State private var readability: ContainerFileReadability?
    @State private var failure: String?
    @State private var isLoading = true
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            content
                .frame(minWidth: 520, minHeight: 320)
            Divider()
            footerBar
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 520)
        .task(id: entry.path) { await load() }
        .accessibilityIdentifier("containers.files.viewer")
    }

    // MARK: Chrome

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("containers.files.viewer.status")

            Spacer(minLength: 8)

            if case .text(let text, _) = readability {
                Button(didCopy ? "Copied" : "Copy") {
                    MorbPasteboard.copy(text)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        didCopy = false
                    }
                }
                .accessibilityIdentifier("containers.files.viewer.copy")
                .help("Copy the text shown here")
            }

            Button("Save to Host…") {
                saver.begin(client: client, containerID: container.id, entry: entry)
            }
            .accessibilityIdentifier("containers.files.viewer.save")
            .help("Save the whole file to this Mac")

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("containers.files.viewer.done")
        }
        .padding(12)
    }

    /// Always says how much of the file is on screen, and never rounds "some of it" up
    /// to "all of it".
    private var statusLine: String {
        if isLoading { return "Reading \(entry.path) from the container…" }
        if let failure { return failure }
        guard let read else { return "" }
        let total = read.entry?.size ?? entry.size
        switch readability {
        case .text(_, let truncated) where truncated:
            let shown = Formatters.bytesString(Int64(read.data.count))
            let whole = total.map(Formatters.bytesString) ?? "an unreported size"
            return "Showing the first \(shown) of \(whole). Save to the host for the whole file."
        case .text:
            return total.map { "\(Formatters.bytesString($0)), read in full." } ?? "Read in full."
        case .empty:
            return "This file is empty."
        case .notText, .none:
            return total.map { "\(Formatters.bytesString($0)) on disk in the container." } ?? ""
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            ContentUnavailableView {
                Label("File Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .accessibilityIdentifier("containers.files.viewer.retry")
            }
            .accessibilityIdentifier("containers.files.viewer.empty.unavailable")
        } else {
            switch readability {
            case .text(let text, _):
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityIdentifier("containers.files.viewer.text")

            case .notText(let reason):
                ContentUnavailableView {
                    Label("Not Text", systemImage: "doc.questionmark")
                } description: {
                    Text(ContainerFileText.sentence(for: reason, size: read?.entry?.size ?? entry.size))
                } actions: {
                    Button("Save to Host…") {
                        saver.begin(client: client, containerID: container.id, entry: entry)
                    }
                    .accessibilityIdentifier("containers.files.viewer.empty.notText.save")
                }
                .accessibilityIdentifier("containers.files.viewer.empty.notText")

            case .empty:
                ContentUnavailableView {
                    Label("Empty File", systemImage: "doc")
                } description: {
                    Text("This file has no contents. The engine reports it as zero bytes.")
                }
                .accessibilityIdentifier("containers.files.viewer.empty.noContents")

            case .none:
                ContentUnavailableView {
                    Label("Nothing to Show", systemImage: "doc")
                } description: {
                    Text("The engine sent no contents for this path.")
                }
                .accessibilityIdentifier("containers.files.viewer.empty.noContents")
            }
        }
    }

    private func load() async {
        isLoading = true
        failure = nil
        readability = nil
        read = nil
        do {
            let result = try await ContainerFileTransfers.read(
                client: client,
                containerID: container.id,
                path: entry.path,
                limit: ContainerFileText.viewerByteLimit)
            guard !Task.isCancelled else { return }
            read = result
            if let tarEntry = result.entry, tarEntry.kind != .regularFile {
                failure = Self.notARegularFileSentence(tarEntry, path: entry.path)
            } else {
                readability = ContainerFileText.interpret(result.data, truncated: result.truncated)
            }
        } catch {
            guard !Task.isCancelled else { return }
            failure = ContainerFileErrorText.sentence(error, path: entry.path)
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    /// A symlink is not a broken file, so it does not get an error's vocabulary — it
    /// gets told what it points at and what to do about it.
    static func notARegularFileSentence(_ tarEntry: ContainerTarEntry, path: String) -> String {
        if tarEntry.kind == .symbolicLink, let target = tarEntry.linkTarget {
            return "\(path) is a symbolic link to \(target). The engine sends the link, not what it points at — browse to \(target) to read that."
        }
        return "\(path) is a \(tarEntry.kind.displayName.lowercased()), which has no contents to read."
    }
}
