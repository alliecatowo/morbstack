// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The container filesystem browser.
//
// It is an outline of a real parent/child structure, so it is a `List` of system
// `DisclosureGroup`s with system selection — not a hand-drawn tree, not indented cards,
// and not a second Finder. The one non-obvious construction is the `AnyView` at the
// recursion point: a `View` struct whose body contains itself cannot have its opaque
// return type inferred, and the alternative — flattening the tree into rows with a
// hand-drawn triangle — is precisely the custom disclosure layout the HIG coverage
// audit rules out.
//
// This tab reads. It does not write, upload, rename, delete, or change a mode, and it
// does not offer a control that says it will one day. What it can do is browse, read a
// text file within a stated limit, copy a path, and save a file or a whole folder to
// the host.

import AppKit
import SwiftUI

struct ContainerFilesTab: View {

    let container: ContainerSummary
    let client: DockerClient
    @Bindable var store: ContainerFileTreeStore

    @State private var saver = ContainerFileSaver()
    @State private var pathDraft = "/"
    @State private var viewerTarget: ContainerFileEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isScanning { scanStatus }
            content
            if let entry = store.selectedEntry {
                Divider()
                detail(for: entry)
            }
            if saver.isSaving || saver.outcome != nil {
                Divider()
                saveStatus
            }
        }
        .task { store.start(client: client, containerID: container.id) }
        .onChange(of: store.root) { _, root in pathDraft = root }
        .onAppear { pathDraft = store.root }
        .sheet(item: $viewerTarget) { entry in
            ContainerFileViewerSheet(
                entry: entry,
                container: container,
                client: client,
                saver: saver)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            pathBar
            if let problem = store.navigationProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("containers.files.pathProblem")
            }
        }
        .padding(8)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                guard let parent = ContainerFilePath.parent(of: store.root) else { return }
                store.navigate(to: parent)
            } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(store.root == "/")
            .accessibilityIdentifier("containers.files.enclosingFolder")
            .accessibilityLabel("Enclosing folder")
            .help("Browse the folder that contains this one")

            TextField("Path", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .lineLimit(1)
                .onSubmit { store.navigate(to: pathDraft) }
                .accessibilityIdentifier("containers.files.path")
                .accessibilityLabel("Container path to browse")
                .help("A path inside the container, not on this Mac. Press Return to browse it.")

            filesOptionsMenu
        }
    }

    private var filesOptionsMenu: some View {
        Menu {
            Button("Reload This Folder", systemImage: "arrow.clockwise") {
                store.reloadRoot()
            }
            .accessibilityIdentifier("containers.files.options.reload")
            .accessibilityLabel("Reload this folder")
            .help("Read this folder from the engine again")

            Button("Copy Path", systemImage: "doc.on.doc") {
                MorbPasteboard.copy(store.root)
            }
            .accessibilityIdentifier("containers.files.options.copyPath")
            .accessibilityLabel("Copy the path of this folder")
            .help("Copy this container path to the clipboard")

            Divider()

            Button("Save This Folder to Host…", systemImage: "square.and.arrow.down") {
                let entry = store.facts[store.root]
                    ?? ContainerFileEntry(path: store.root, kind: .directory)
                saver.begin(client: client, containerID: container.id, entry: entry)
            }
            .accessibilityIdentifier("containers.files.options.saveFolder")
            .accessibilityLabel("Save this folder to the host")
            .help("Save everything under this folder as one tar archive on this Mac")
        } label: {
            Label("File options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("containers.files.options")
        .accessibilityLabel("File options")
        .help("Reload, copy the path, or save this folder to the host")
    }

    // MARK: Progress

    private var scanStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(scanStatusText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("containers.files.scanStatus")

            Spacer(minLength: 4)

            Button("Stop") { store.stopScan() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("containers.files.stop")
                .accessibilityLabel("Stop listing")
                .help("Stop reading this folder from the engine")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Reads out real bytes off the wire and real entries admitted. It is not a
    /// percentage, because the engine never says how large the tree is.
    private var scanStatusText: String {
        guard let progress = store.progress else { return "Reading…" }
        let items = "\(progress.entriesListed) \(progress.entriesListed == 1 ? "item" : "items")"
        return "Reading \(progress.path) — \(Formatters.bytesString(progress.bytesRead)), \(items)"
    }

    // MARK: Tree

    @ViewBuilder
    private var content: some View {
        switch store.listing(for: store.root) {
        case .unavailable(let sentence):
            ContentUnavailableView {
                Label("Folder Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(sentence)
            } actions: {
                Button("Try Again") { store.reloadRoot() }
                    .accessibilityIdentifier("containers.files.empty.unavailable.retry")
            }
            .accessibilityIdentifier("containers.files.empty.unavailable")

        case .notListed:
            ContentUnavailableView {
                Label("Folder Not Listed", systemImage: "folder")
            } description: {
                Text("Morbstack has not read \(store.root) from this container yet.")
            } actions: {
                Button("List This Folder") { store.list(store.root) }
                    .accessibilityIdentifier("containers.files.empty.notListed.list")
            }
            .accessibilityIdentifier("containers.files.empty.notListed")

        case .listing(let entries) where entries.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .listed(let entries) where entries.isEmpty:
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("The engine reports nothing inside \(store.root).")
            }
            .accessibilityIdentifier("containers.files.empty.noEntries")

        default:
            tree
        }
    }

    private var tree: some View {
        List(selection: $store.selection) {
            ForEach(store.listing(for: store.root).entries) { entry in
                row(for: entry)
            }
            footer(for: store.listing(for: store.root), directory: store.root)
            if store.rejectedEntryCount > 0 { rejectedEntriesNotice }
        }
        // No explicit list style. The system picks the right one for where this list
        // actually lives (an inspector column), and forcing `.sidebar` here would drag
        // sidebar material in behind dense content — see DECISIONS.md §3.
        .accessibilityIdentifier("containers.files.list")
    }

    /// The engine's archive is written by the container's own filesystem. An entry whose
    /// name does not describe a path inside the folder that was requested is refused
    /// rather than placed somewhere plausible — and refusing quietly would hide a fact
    /// about this container that is worth knowing.
    private var rejectedEntriesNotice: some View {
        let count = store.rejectedEntryCount
        return Label(
            "\(count) \(count == 1 ? "entry" : "entries") in this archive named a path outside \(store.root) and \(count == 1 ? "was" : "were") not listed.",
            systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("containers.files.rejectedEntries")
    }

    /// One row, recursively. `AnyView` is the erasure a self-referential SwiftUI view
    /// needs; see the note at the top of the file.
    ///
    /// The selection tag and the identifier go on whatever the `List` treats as the row —
    /// the `DisclosureGroup` for a folder, the label itself for everything else — so a
    /// keyboard selection and an XCUITest query land on the same element.
    private func row(for entry: ContainerFileEntry) -> AnyView {
        let label = ContainerFileRowLabel(entry: entry, listing: store.listings[entry.path])

        guard entry.kind == .directory else {
            return AnyView(
                label
                    .tag(entry.path)
                    .contextMenu { contextMenu(for: entry) }
                    .onTapGesture(count: 2) { primaryAction(for: entry) }
                    .accessibilityIdentifier("containers.files.row.\(entry.path)"))
        }

        return AnyView(
            DisclosureGroup(isExpanded: expansion(of: entry.path)) {
                let listing = store.listing(for: entry.path)
                ForEach(listing.entries) { child in
                    row(for: child)
                }
                footer(for: listing, directory: entry.path)
            } label: {
                // The gesture is on the label, not the group: on the group it would also
                // fire for a double-click anywhere among the folder's children.
                label.onTapGesture(count: 2) { store.toggle(entry.path) }
            }
            .tag(entry.path)
            .contextMenu { contextMenu(for: entry) }
            .accessibilityIdentifier("containers.files.row.\(entry.path)"))
    }

    /// The disclosure binding. It compares before acting, because a `set` that toggles
    /// regardless of the value it was handed inverts itself the moment SwiftUI writes
    /// back a state it already holds.
    private func expansion(of path: String) -> Binding<Bool> {
        Binding(
            get: { store.expanded.contains(path) },
            set: { isExpanded in
                guard isExpanded != store.expanded.contains(path) else { return }
                store.toggle(path)
            })
    }

    /// What a directory says about itself below its children: nothing when the listing
    /// is complete and non-empty, and otherwise the exact state it is in.
    @ViewBuilder
    private func footer(
        for listing: ContainerDirectoryListing,
        directory: String
    ) -> some View {
        switch listing {
        case .listing:
            // The header already says a read is in flight, and repeating it on every
            // open folder is noise, not information.
            EmptyView()

        case .listed(let entries) where entries.isEmpty && directory != store.root:
            Text("Empty folder")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .partial(_, let stop):
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.sentence(entriesListed: listing.entries.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("List This Folder") { store.list(directory) }
                    .controlSize(.small)
                    .accessibilityIdentifier("containers.files.listFolder")
                    .accessibilityLabel("List \(directory) on its own")
            }
            .padding(.vertical, 2)

        case .unavailable(let sentence):
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .notListed, .listed:
            EmptyView()
        }
    }

    /// The per-entry commands. Only what this entry can actually do appears: a symlink
    /// gets no Save, because the engine sends the link and not what it points at, and a
    /// device node gets neither. Nothing here is present-but-disabled.
    @ViewBuilder
    private func contextMenu(for entry: ContainerFileEntry) -> some View {
        let linkDestination = entry.linkTarget
            .flatMap { ContainerFilePath.resolveLinkTarget($0, from: entry.path) }
        let hasNavigation =
            entry.kind == .regularFile || entry.kind == .directory || linkDestination != nil

        if entry.kind == .regularFile {
            Button("Open") { viewerTarget = entry }
                .accessibilityIdentifier("containers.files.open")
        }
        if entry.kind == .directory {
            Button("Browse from Here") { store.navigate(to: entry.path) }
            Button("List This Folder Again") { store.list(entry.path) }
        }
        if let linkDestination {
            Button("Go to \(linkDestination)") { store.navigate(to: linkDestination) }
                .accessibilityIdentifier("containers.files.followLink")
        }
        if hasNavigation { Divider() }

        if entry.kind == .regularFile || entry.kind == .directory {
            Button("Save to Host…") {
                saver.begin(client: client, containerID: container.id, entry: entry)
            }
            .accessibilityIdentifier("containers.files.save")
        }
        Button("Copy Path") { MorbPasteboard.copy(entry.path) }
            .accessibilityIdentifier("containers.files.copyPath")
    }

    /// Double-click on a non-folder row. Only a regular file has contents to open; a
    /// symlink, a device node or a socket selects, because the honest answer for those
    /// is the facts in the detail strip, not an empty document window.
    private func primaryAction(for entry: ContainerFileEntry) {
        if entry.kind == .regularFile {
            viewerTarget = entry
        } else {
            store.selection = entry.path
        }
    }

    // MARK: Selected entry

    private func detail(for entry: ContainerFileEntry) -> some View {
        Form {
            Section {
                LabeledContent("Kind", value: entry.kind.displayName)
                LabeledContent("Size") {
                    Text(sizeDescription(for: entry))
                        .monospacedDigit()
                }
                LabeledContent("Modified") {
                    Text(entry.modified.map(Formatters.absoluteDate) ?? "Not reported")
                }
                if let permissions = entry.permissions {
                    LabeledContent("Permissions", value: Self.permissionString(permissions))
                }
                if let target = entry.linkTarget {
                    LabeledContent("Links To") {
                        Text(target)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Path") {
                    Text(entry.path)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } header: {
                Text(entry.name)
            } footer: {
                Text("This path is inside the container; it is not on this Mac and cannot be opened in Finder. Saving copies it out.")
            }
        }
        .frame(maxHeight: 220)
        .accessibilityIdentifier("containers.files.selectedEntry")
    }

    /// Sizes are the engine's own bytes, and only where "size" means content length.
    private func sizeDescription(for entry: ContainerFileEntry) -> String {
        if let size = entry.size { return Formatters.bytesString(size) }
        if entry.kind == .directory {
            let listing = store.listing(for: entry.path)
            if case .listed(let entries) = listing {
                return "\(entries.count) \(entries.count == 1 ? "item" : "items")"
            }
            return "Not listed yet"
        }
        return "Not applicable"
    }

    /// `rwxr-xr-x`, from the permission bits the archive carried.
    static func permissionString(_ permissions: UInt16) -> String {
        let bits = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            let group = (permissions >> UInt16(shift)) & 0o7
            for (index, symbol) in bits.enumerated() {
                result += (group & UInt16(0o4 >> index)) != 0 ? symbol : "-"
            }
        }
        return result + String(format: " (%03o)", permissions & 0o777)
    }

    // MARK: Saving

    @ViewBuilder
    private var saveStatus: some View {
        HStack(spacing: 8) {
            if saver.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving \(saver.subject ?? "file") — \(Formatters.bytesString(saver.bytesWritten))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Cancel") { saver.cancel() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("containers.files.saveCancel")
            } else if let outcome = saver.outcome {
                switch outcome {
                case .saved(let url, let bytes):
                    Text("Saved \(Formatters.bytesString(bytes)) to \(url.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Show in Finder") { TrackBFinder.reveal(url.path) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("containers.files.saveReveal")
                case .failed(let sentence):
                    Label(sentence, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                case .cancelled:
                    Text("Save cancelled. Nothing was written.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                Button {
                    saver.dismissOutcome()
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("containers.files.saveDismiss")
                .accessibilityLabel("Dismiss this message")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityIdentifier("containers.files.saveStatus")
    }
}

// MARK: - Row

/// One entry's row. Name and glyph carry the kind; the trailing caption carries the one
/// number that is a fact about this entry, and nothing when there is none.
struct ContainerFileRowLabel: View {

    let entry: ContainerFileEntry
    var listing: ContainerDirectoryListing?

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: entry.kind.symbolName)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .help(helpText)
    }

    private var trailing: String? {
        if let size = entry.size { return Formatters.bytesString(size) }
        if entry.kind == .directory, case .listed(let entries) = listing {
            return "\(entries.count)"
        }
        return nil
    }

    private var accessibilityText: String {
        var parts = [entry.kind.displayName, entry.name]
        if let size = entry.size { parts.append(Formatters.bytesString(size)) }
        if let target = entry.linkTarget { parts.append("links to \(target)") }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        var parts = [entry.path, entry.kind.displayName]
        if let size = entry.size { parts.append(Formatters.bytesString(size)) }
        parts.append("Modified \(entry.modified.map(Formatters.absoluteDate) ?? "unknown")")
        if let target = entry.linkTarget { parts.append("→ \(target)") }
        return parts.joined(separator: " · ")
    }
}
