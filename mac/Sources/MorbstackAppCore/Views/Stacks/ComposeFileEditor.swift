// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deliberately small source-first Compose workspace. It edits one file the person
// explicitly picked; it does not infer sibling files from running containers, evaluate
// Compose, access credentials, invoke Compose, or change Docker/VM/Kubernetes state.

import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The File-menu commands exposed while an explicitly opened Compose source document
/// is active. Focused values keep the command graph native without making the app a
/// `DocumentGroup` or pretending it owns every YAML file on the Mac.
struct ComposeFileEditorCommandActions {
    let save: () -> Void
    let discard: () -> Void
    let canSave: Bool
    let canDiscard: Bool
}

private struct ComposeFileEditorCommandActionsKey: FocusedValueKey {
    typealias Value = ComposeFileEditorCommandActions
}

extension FocusedValues {
    var composeFileEditorCommandActions: ComposeFileEditorCommandActions? {
        get { self[ComposeFileEditorCommandActionsKey.self] }
        set { self[ComposeFileEditorCommandActionsKey.self] = newValue }
    }
}

/// The two source files this local workspace can edit. Both are opaque source text:
/// their filenames select the local safety contract, not an inferred Compose project.
enum ComposeProjectSourceKind: Equatable {
    case composeYAML
    case projectEnvironment

    var defaultDisplayName: String {
        switch self {
        case .composeYAML: "Compose File"
        case .projectEnvironment: "Project Environment"
        }
    }

    var formSectionTitle: String {
        switch self {
        case .composeYAML: "Compose File"
        case .projectEnvironment: "Environment File"
        }
    }

    var formatDescription: String {
        switch self {
        case .composeYAML: "YAML source (not parsed)"
        case .projectEnvironment: "Environment source (not evaluated)"
        }
    }

    var editorAccessibilityLabel: String {
        switch self {
        case .composeYAML: "Compose YAML source"
        case .projectEnvironment: "Project environment source"
        }
    }

    var sourceFileName: String {
        switch self {
        case .composeYAML: "Compose YAML file"
        case .projectEnvironment: "project .env file"
        }
    }

    func validateSelectedFileName(_ url: URL) throws {
        switch self {
        case .composeYAML:
            let extensionName = url.pathExtension.lowercased()
            guard extensionName == "yaml" || extensionName == "yml" else {
                throw ComposeFileEditorError(
                    "Choose a .yaml or .yml file. Morbstack does not infer Compose files from a running project.")
            }
        case .projectEnvironment:
            guard url.lastPathComponent == ".env" else {
                throw ComposeFileEditorError(
                    "Choose the project's .env file. Morbstack does not infer or open a sibling environment file.")
            }
        }
    }
}

@MainActor
@Observable
final class ComposeFileEditor {

    enum PendingDiscard {
        case close
        case revert
    }

    static let yamlContentTypes = ["yaml", "yml"].compactMap(UTType.init(filenameExtension:))

    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    private(set) var fileURL: URL?
    private(set) var sourceKind: ComposeProjectSourceKind?
    private var originalData = Data()
    private var originalText = ""
    private var usesUTF8BOM = false
    private var holdsSecurityScopedAccess = false

    var text = ""
    var isPresented = false
    var openError: String?
    var saveError: String?
    var pendingDiscard: PendingDiscard?

    var isDirty: Bool { text != originalText }
    var displayName: String { fileURL?.lastPathComponent ?? sourceKind?.defaultDisplayName ?? "Source File" }
    var isEnvironmentFile: Bool { sourceKind == .projectEnvironment }
    var openErrorTitle: String {
        sourceKind == .projectEnvironment ? "Couldn’t Open Environment File" : "Couldn’t Open Compose File"
    }
    var saveErrorTitle: String {
        sourceKind == .projectEnvironment ? "Couldn’t Save Environment File" : "Couldn’t Save Compose File"
    }

    var commandActions: ComposeFileEditorCommandActions? {
        guard isPresented else { return nil }
        return ComposeFileEditorCommandActions(
            save: { self.save() },
            discard: { self.requestDiscard() },
            canSave: isDirty,
            canDiscard: isDirty)
    }

    /// Starts a document session only after the Open panel returned an explicit user
    /// selection. The validation intentionally checks only the selected document's
    /// name and file safety. This feature has no Compose or environment evaluator and
    /// makes no claim about the file's effective runtime values.
    func open(_ url: URL, as sourceKind: ComposeProjectSourceKind) {
        close()
        // Retain the requested kind while presenting an Open error so the alert does
        // not misleadingly call a rejected `.env` selection a Compose YAML file.
        self.sourceKind = sourceKind
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            try Self.validateSourceFile(url, as: sourceKind)
            let data = try Self.coordinatedRead(url)
            let decoded = try Self.decodeUTF8(data)
            fileURL = url
            originalData = data
            originalText = decoded.text
            usesUTF8BOM = decoded.usesBOM
            holdsSecurityScopedAccess = accessed
            text = decoded.text
            isPresented = true
            openError = nil
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            openError = error.localizedDescription
        }
    }

    func save() {
        guard isDirty, let fileURL, let sourceKind else { return }
        do {
            let replacement = Self.encodeUTF8(text, usesBOM: usesUTF8BOM)
            try Self.coordinatedReplace(
                fileURL,
                as: sourceKind,
                expectedData: originalData,
                replacementData: replacement)
            originalData = replacement
            originalText = text
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func requestDiscard() {
        guard isDirty else { return }
        pendingDiscard = .revert
    }

    func requestClose() {
        if isDirty {
            pendingDiscard = .close
        } else {
            close()
        }
    }

    func resolveDiscard() {
        switch pendingDiscard {
        case .revert:
            text = originalText
        case .close:
            close()
        case nil:
            break
        }
        pendingDiscard = nil
    }

    func cancelDiscard() {
        pendingDiscard = nil
    }

    func close() {
        if holdsSecurityScopedAccess, let fileURL {
            fileURL.stopAccessingSecurityScopedResource()
        }
        fileURL = nil
        sourceKind = nil
        originalData = Data()
        originalText = ""
        usesUTF8BOM = false
        holdsSecurityScopedAccess = false
        text = ""
        isPresented = false
        pendingDiscard = nil
        saveError = nil
    }

    private static func validateSourceFile(_ url: URL, as sourceKind: ComposeProjectSourceKind) throws {
        try sourceKind.validateSelectedFileName(url)
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ComposeFileEditorError("The selected \(sourceKind.sourceFileName) no longer exists.")
        }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw ComposeFileEditorError("Select the actual \(sourceKind.sourceFileName), not a symbolic link. This prevents a save from replacing a link unexpectedly.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ComposeFileEditorError("The selected item is not a regular \(sourceKind.sourceFileName).")
        }
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else {
            throw ComposeFileEditorError("macOS could not coordinate access to the selected source file.")
        }
        return try result.get()
    }

    /// Save only after a coordinated, byte-for-byte comparison with the source we
    /// opened. A change made by another editor wins: this sheet stays dirty and asks
    /// the person to reopen or discard instead of silently overwriting it. The write is
    /// atomic and preserves the previous POSIX mode where the filesystem permits it.
    private static func coordinatedReplace(
        _ url: URL,
        as sourceKind: ComposeProjectSourceKind,
        expectedData: Data,
        replacementData: Data
    ) throws {
        try validateSourceFile(url, as: sourceKind)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                let currentData = try Data(contentsOf: coordinatedURL)
                guard currentData == expectedData else {
                    throw ComposeFileEditorError("This \(sourceKind.sourceFileName) changed on disk after Morbstack opened it. Reopen it to review the current version before saving.")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: coordinatedURL.path)
                try replacementData.write(to: coordinatedURL, options: .atomic)
                if let permissions = attributes[.posixPermissions] {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: permissions], ofItemAtPath: coordinatedURL.path)
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private static func decodeUTF8(_ data: Data) throws -> (text: String, usesBOM: Bool) {
        let usesBOM = data.starts(with: utf8BOM)
        let source = usesBOM ? Data(data.dropFirst(utf8BOM.count)) : data
        guard let text = String(data: source, encoding: .utf8) else {
            throw ComposeFileEditorError("Morbstack edits only UTF-8 source files. This file was left unchanged.")
        }
        return (text, usesBOM)
    }

    private static func encodeUTF8(_ text: String, usesBOM: Bool) -> Data {
        var data = Data(text.utf8)
        if usesBOM { data.insert(contentsOf: utf8BOM, at: 0) }
        return data
    }
}

private struct ComposeFileEditorError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

/// A document-modal editor for one already-selected source file. The metadata uses a
/// system Form; the source itself uses TextEditor, which supplies native text selection,
/// undo, focus, editing, and scrolling instead of a faux code-editor/dashboard. An
/// `.env` document opens with its values withheld until the person explicitly reveals
/// the source in this sheet; the app never makes an effective-environment claim.
struct ComposeFileEditorSheet: View {
    @Bindable var editor: ComposeFileEditor
    @State private var environmentValuesAreRevealed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section(editor.sourceKind?.formSectionTitle ?? "Source File") {
                        LabeledContent("Path") {
                            Text(editor.fileURL?.path ?? "Unavailable")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        LabeledContent("Format", value: editor.sourceKind?.formatDescription ?? "Unavailable")
                        LabeledContent("Deployment", value: "Not applied automatically")
                        if editor.isEnvironmentFile {
                            LabeledContent(
                                "Values",
                                value: environmentValuesAreRevealed ? "Revealed in this editor" : "Hidden")
                            LabeledContent("Compose Result", value: "Not evaluated")
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: editor.isEnvironmentFile ? 194 : 148)

                if editor.isEnvironmentFile && !environmentValuesAreRevealed {
                    ContentUnavailableView {
                        Label("Environment Values Hidden", systemImage: "eye.slash")
                    } description: {
                        Text("Reveal values only when you are ready to view and edit this selected .env file. Morbstack does not read a sibling file, interpolate values, or determine the environment Docker Compose would use.")
                    } actions: {
                        Button("Reveal Values and Edit") {
                            environmentValuesAreRevealed = true
                        }
                    }
                    .accessibilityLabel("Environment values hidden")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $editor.text)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(
                            editor.sourceKind?.editorAccessibilityLabel ?? "Source file")
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle(editor.displayName)
            .navigationSubtitle(
                editor.isDirty
                    ? "Edited"
                    : (editor.isEnvironmentFile && !environmentValuesAreRevealed ? "Values hidden" : "Saved"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { editor.requestClose() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close source file")
                    .help("Close source file")
                }
                if editor.isEnvironmentFile {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            environmentValuesAreRevealed.toggle()
                        } label: {
                            Image(systemName: environmentValuesAreRevealed ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(
                            environmentValuesAreRevealed ? "Hide environment values" : "Reveal environment values")
                        .help(
                            environmentValuesAreRevealed ? "Hide environment values" : "Reveal environment values")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { editor.requestDiscard() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!editor.isDirty)
                    .accessibilityLabel("Discard source changes")
                    .help("Discard unsaved source changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { editor.save() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(!editor.isDirty)
                    .accessibilityLabel("Save source file")
                    .help("Save source file")
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 480, idealHeight: 660)
        .interactiveDismissDisabled(editor.isDirty)
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { editor.pendingDiscard != nil },
                set: { if !$0 { editor.cancelDiscard() } }),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { editor.resolveDiscard() }
            Button("Keep Editing", role: .cancel) { editor.cancelDiscard() }
        } message: {
            Text("Morbstack will discard only the unsaved text in this editor. The source file on disk will not change.")
        }
        .alert(
            editor.saveErrorTitle,
            isPresented: Binding(
                get: { editor.saveError != nil },
                set: { if !$0 { editor.saveError = nil } })
        ) {
            Button("OK", role: .cancel) { editor.saveError = nil }
        } message: {
            Text(editor.saveError ?? "")
        }
    }
}
