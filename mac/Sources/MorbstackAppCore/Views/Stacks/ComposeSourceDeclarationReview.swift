// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A read-only, source-backed declaration review for one document already selected in
// the Compose editor. It stores only the conservative inspection result, never source
// text or values, so this is not an environment viewer, secret vault, or Compose
// evaluator.

import Foundation
import SwiftUI

/// A safe, immutable declaration snapshot. The source editor creates it from the
/// currently selected document; project labels, Docker state, the host environment,
/// and referenced source files never contribute to it.
struct ComposeSourceDeclarationReview: Identifiable {
    enum Provenance: Equatable {
        case selectedFileSnapshot
        case editorDraft

        var description: String {
            switch self {
            case .selectedFileSnapshot: "Selected-file snapshot"
            case .editorDraft: "Editor draft over selected-file snapshot"
            }
        }
    }

    let id = UUID()
    let sourceURL: URL
    let sourceKind: ComposeProjectSourceKind
    let provenance: Provenance
    let inspection: ComposeProjectSourceInspection

    init(
        sourceURL: URL,
        sourceKind: ComposeProjectSourceKind,
        text: String,
        isEditorDraft: Bool
    ) {
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        provenance = isEditorDraft ? .editorDraft : .selectedFileSnapshot
        inspection = ComposeProjectSourceInspection.inspect(text: text, sourceKind: sourceKind)
    }

    // ComposeFileEditor is @MainActor-isolated, so reading its properties requires
    // main-actor isolation here. Both call sites live in SwiftUI view bodies, which
    // are already on the main actor, so this constrains nothing new — it just states
    // where the snapshot is legally taken. (The memberwise init above stays
    // nonisolated: it touches no actor-isolated state.)
    @MainActor
    init?(editor: ComposeFileEditor) {
        guard editor.isPresented,
              let sourceURL = editor.fileURL,
              let sourceKind = editor.sourceKind
        else { return nil }

        self.init(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            text: editor.text,
            isEditorDraft: editor.isDirty)
    }

    var displayName: String { sourceURL.lastPathComponent }
    var isEnvironmentFile: Bool { sourceKind == .projectEnvironment }
}

/// A system document sheet for the task “review the environment and secret declarations
/// in this selected source.” It is deliberately read-only: `Form` and collapsed
/// `DisclosureGroup`s communicate bounded source metadata without turning it into a
/// second editor, a dashboard, or a claim about Compose's resolved runtime state.
struct ComposeSourceDeclarationReviewSheet: View {
    let review: ComposeSourceDeclarationReview
    @Environment(\.dismiss) private var dismiss
    @State private var environmentDeclarationsExpanded = false
    @State private var serviceEnvironmentExpanded = false
    @State private var environmentFilesExpanded = false
    @State private var interpolationReferencesExpanded = false
    @State private var sourceSecretsExpanded = false
    @State private var secretGrantsExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if review.isEnvironmentFile {
                    environmentFileSections
                } else {
                    composeEnvironmentSections
                    interpolationSection
                    secretsSection
                }
            }
            .formStyle(.automatic)
            .navigationTitle(review.isEnvironmentFile ? "Environment Declarations" : "Environment & Secrets")
            .navigationSubtitle(review.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 620)
    }

    private var sourceSection: some View {
        Section("Selected Source") {
            LabeledContent("File") {
                Text(review.sourceURL.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            LabeledContent("Provenance", value: review.provenance.description)
            LabeledContent(
                "Scope",
                value: review.isEnvironmentFile ? "Selected .env file only" : "Selected Compose YAML source only")
            LabeledContent("Values", value: "Not read or revealed")
            LabeledContent("Coverage", value: "Conservative source declarations only")
        }
    }

    private var environmentFileSections: some View {
        Group {
            Section("Environment") {
                LabeledContent("Effective Environment", value: "Unknown; not evaluated")
                LabeledContent("Compose Scope", value: "Unknown; source file not inferred")
                LabeledContent("Source Values", value: "Redacted")
                DisclosureGroup(
                    "Declarations (\(review.inspection.environmentDeclarations.count))",
                    isExpanded: $environmentDeclarationsExpanded)
                {
                    if review.inspection.environmentDeclarations.isEmpty {
                        Text("No simple KEY=value declarations were recognized in this selected source file.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(review.inspection.environmentDeclarations) { declaration in
                            environmentDeclarationRow(declaration)
                        }
                    }
                }
            }
            interpolationSection
        }
    }

    private var composeEnvironmentSections: some View {
        Section("Environment and Precedence") {
            LabeledContent("Effective Environment", value: "Unknown; not evaluated")
            LabeledContent("Source Precedence", value: "Declared service environment overrides env_file")
            LabeledContent("Default .env", value: "Unknown; not inferred")
            LabeledContent("Host Environment", value: "Unknown; not read")
            LabeledContent("Declared env_file Sources", value: "References only; not opened")
            DisclosureGroup(
                "Service environment (\(review.inspection.serviceEnvironmentDeclarations.count))",
                isExpanded: $serviceEnvironmentExpanded)
            {
                if review.inspection.serviceEnvironmentDeclarations.isEmpty {
                    Text("No block-style service environment declarations were recognized in this source file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(review.inspection.serviceEnvironmentDeclarations) { declaration in
                        serviceEnvironmentDeclarationRow(declaration)
                    }
                }
            }
            DisclosureGroup(
                "Declared environment files (\(review.inspection.environmentFileDeclarations.count))",
                isExpanded: $environmentFilesExpanded)
            {
                if review.inspection.environmentFileDeclarations.isEmpty {
                    Text("No block-style service env_file references were recognized in this source file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(review.inspection.environmentFileDeclarations) { declaration in
                        environmentFileDeclarationRow(declaration)
                    }
                }
            }
        }
    }

    private var interpolationSection: some View {
        Section("Interpolation") {
            LabeledContent("Resolution", value: "Unknown; not evaluated")
            DisclosureGroup(
                "Possible source references (\(review.inspection.interpolationReferences.count))",
                isExpanded: $interpolationReferencesExpanded)
            {
                if review.inspection.interpolationReferences.isEmpty {
                    Text("No $VAR or ${VAR} tokens outside single-quoted source spans were recognized.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(review.inspection.interpolationReferences) { reference in
                        LabeledContent {
                            Text("Line \(reference.line)")
                                .foregroundStyle(.secondary)
                        } label: {
                            if reference.isPotentiallySensitive {
                                Label(reference.name, systemImage: "key.fill")
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(reference.name)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .accessibilityLabel("Possible interpolation reference \(reference.name), source line \(reference.line)")
                        .help("Possible source interpolation input; its value is not read")
                    }
                }
            }
        }
    }

    private var secretsSection: some View {
        Section("Secrets") {
            LabeledContent("Interpretation", value: "Source declarations only")
            LabeledContent("Secret Contents", value: "Unavailable; not read or revealed")
            LabeledContent("Top-level Declaration", value: "Does not grant service access")
            LabeledContent("Service Access", value: "Only explicit source grants shown")
            DisclosureGroup(
                "Top-level declarations (\(review.inspection.secretDeclarations.count))",
                isExpanded: $sourceSecretsExpanded)
            {
                if review.inspection.secretDeclarations.isEmpty {
                    Text("No conventional top-level secrets block was recognized in this source file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(review.inspection.secretDeclarations) { declaration in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(secretSourceLabel(declaration.source))
                                    .foregroundStyle(.secondary)
                                Text("Line \(declaration.line)")
                                    .foregroundStyle(.tertiary)
                            }
                        } label: {
                            Text(declaration.name)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .accessibilityLabel(
                            "Source secret \(declaration.name), \(secretSourceLabel(declaration.source)), line \(declaration.line)")
                        .help("Source declaration only; no secret content is read")
                    }
                }
            }
            DisclosureGroup(
                "Service grants (\(review.inspection.secretGrants.count))",
                isExpanded: $secretGrantsExpanded)
            {
                if review.inspection.secretGrants.isEmpty {
                    Text("No block-style service secret grants were recognized in this source file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(review.inspection.secretGrants) { grant in
                        secretGrantRow(grant)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func environmentDeclarationRow(
        _ declaration: ComposeProjectSourceInspection.EnvironmentDeclaration
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(environmentDispositionLabel(declaration.valueDisposition))
                    .foregroundStyle(.secondary)
                Text("Line \(declaration.line)")
                    .foregroundStyle(.tertiary)
            }
        } label: {
            if declaration.isPotentiallySensitive {
                Label(declaration.key, systemImage: "key.fill")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            } else {
                Text(declaration.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .accessibilityLabel(
            "\(declaration.key), \(environmentDispositionLabel(declaration.valueDisposition)), source line \(declaration.line)")
        .help(
            declaration.isPotentiallySensitive
                ? "Potentially sensitive source declaration; its value is redacted"
                : "Source declaration; its value is not shown in this review")
    }

    @ViewBuilder
    private func serviceEnvironmentDeclarationRow(
        _ declaration: ComposeProjectSourceInspection.ServiceEnvironmentDeclaration
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(serviceEnvironmentSourceLabel(declaration.valueSource))
                    .foregroundStyle(.secondary)
                Text("Line \(declaration.line)")
                    .foregroundStyle(.tertiary)
            }
        } label: {
            let label = "\(declaration.service).\(declaration.key)"
            if declaration.isPotentiallySensitive {
                Label(label, systemImage: "key.fill")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .accessibilityLabel(
            "\(declaration.service) environment \(declaration.key), \(serviceEnvironmentSourceLabel(declaration.valueSource)), source line \(declaration.line)")
        .help("Source declaration only; no environment value is shown or resolved")
    }

    @ViewBuilder
    private func environmentFileDeclarationRow(
        _ declaration: ComposeProjectSourceInspection.EnvironmentFileDeclaration
    ) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(declaration.path ?? "Path not recognized")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(environmentFileDetailLabel(declaration))
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(declaration.service)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityLabel(
            "\(declaration.service) declared environment file \(declaration.path ?? "path not recognized"), source line \(declaration.line)")
        .help("Compose source reference only; Morbstack does not open this file")
    }

    @ViewBuilder
    private func secretGrantRow(_ grant: ComposeProjectSourceInspection.SecretGrant) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(grant.secretName ?? "Source name not recognized")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(secretGrantDetailLabel(grant))
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(grant.service)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityLabel(
            "\(grant.service) source secret grant \(grant.secretName ?? "not recognized"), source line \(grant.line)")
        .help("Source grant only; Compose resolves whether the secret exists")
    }

    private func environmentDispositionLabel(
        _ disposition: ComposeProjectSourceInspection.EnvironmentDeclaration.ValueDisposition
    ) -> String {
        switch disposition {
        case .empty: "Empty"
        case .unset: "Unset"
        case .set: "Set"
        case .redacted: "Redacted"
        }
    }

    private func serviceEnvironmentSourceLabel(
        _ source: ComposeProjectSourceInspection.ServiceEnvironmentDeclaration.ValueSource
    ) -> String {
        switch source {
        case .declaredInSource: "Source value withheld"
        case .requiresComposeResolution: "Compose resolves (not read)"
        }
    }

    private func environmentFileDetailLabel(
        _ declaration: ComposeProjectSourceInspection.EnvironmentFileDeclaration
    ) -> String {
        var details = ["Line \(declaration.line)"]
        if let required = declaration.required {
            details.append(required ? "Required" : "Optional")
        }
        if let format = declaration.format {
            details.append("Format \(format)")
        }
        return details.joined(separator: " · ")
    }

    private func secretSourceLabel(_ source: ComposeProjectSourceInspection.SecretDeclaration.Source) -> String {
        switch source {
        case .file(let path):
            path.map { "File \($0) (not read)" } ?? "File source (path not recognized)"
        case .environment(let variable):
            variable.map { "Host variable \($0) (not read)" } ?? "Host variable source (name not recognized)"
        case .external:
            "External source declaration"
        case .notDeclared:
            "Source not recognized"
        case .ambiguous:
            "Multiple source keys; validate source"
        }
    }

    private func secretGrantDetailLabel(_ grant: ComposeProjectSourceInspection.SecretGrant) -> String {
        var details = [grant.syntax == .short ? "Short syntax" : "Long syntax", "Line \(grant.line)"]
        if let target = grant.target {
            details.append("Target \(target)")
        }
        return details.joined(separator: " · ")
    }
}
