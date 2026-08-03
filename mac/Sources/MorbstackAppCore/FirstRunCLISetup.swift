// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// First-run Morbstack setup.
//
// This file deliberately owns the presentation and nothing else.  The exact plan and
// every file-system mutation belong to `MorbCliInstallation` and
// `MorbBackgroundService`, which are also the sources of truth for `morb install-cli`
// and `morb service`. Keeping the app as a thin, explicit-consent client of those
// transactions means the graphical and terminal paths cannot quietly diverge.

import MorbstackKit
import Observation
import SwiftUI

// MARK: - Model

/// The state behind the first-run setup sheet.
///
/// `MorbCliInstallation.plan()` is read-only and is always calculated before the sheet
/// is presented.  The one mutation happens only in ``install()``, after the person has
/// pressed the clearly labelled confirmation button.  In particular, this model never
/// passes `makeDefault: true`: an existing Docker client or named context keeps its
/// priority unless the person uses the explicit terminal option designed for that.
@MainActor
@Observable
final class FirstRunCLISetupModel {

    private(set) var plan: MorbCliInstallation.Plan?
    private(set) var result: MorbCliInstallation.InstallResult?
    private(set) var backgroundServiceStatus: MorbBackgroundService.Status?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isInstalling = false
    private(set) var hasCompletedSetup = false

    /// The only route to `MorbBackgroundService.enable()`. This starts false so a
    /// durable per-user service is an affirmative choice made from the review sheet.
    var enableBackgroundService = false

    private var hasPrepared = false

    /// Whether the app should offer first-run setup for the current machine state.
    ///
    /// An incomplete development bundle is not a CLI consent opportunity: the model
    /// leaves that plan alone rather than presenting a button that can never succeed.
    /// A separately available background-service choice remains visible and is still
    /// never registered until confirmed.
    var requiresConsent: Bool {
        guard plan != nil, !hasCompletedSetup else { return false }
        return needsCLISetup || offersBackgroundService
    }

    /// There is a concrete CLI transaction to review and apply.
    var needsCLISetup: Bool {
        guard let plan, plan.hasCompleteToolchain, result == nil else { return false }

        let needsLinks = !plan.docker.alreadyCorrect
            || plan.plugins.contains(where: { !$0.alreadyCorrect })
        let needsPathRegistration: Bool
        switch plan.pathRegistration {
        case .addToProfile:
            needsPathRegistration = true
        case .alreadyReachable, .preservesExistingDocker, .profileAlreadyManaged,
             .skippedForHomeOverride, .unsupportedShell, .malformedExistingBlock:
            needsPathRegistration = false
        }
        let needsContextRegistration: Bool
        switch plan.contextRegistration {
        case .willCreateAndUse, .willCreateWithoutChangingCurrent,
             .staleWillReplaceAndUse, .staleWillReplaceWithoutChangingCurrent:
            needsContextRegistration = true
        case .alreadyCurrent, .alreadyRegisteredWithoutChangingCurrent:
            needsContextRegistration = false
        }
        return needsLinks || needsPathRegistration || needsContextRegistration
            || plan.directSocket.canCreate
    }

    /// Registration is possible only from a complete bundled app and only when macOS
    /// says the per-user service is not currently registered. A pending Login Items
    /// approval is deliberately not re-registered here.
    var offersBackgroundService: Bool {
        switch backgroundServiceStatus?.registration {
        case .notRegistered, .notFound:
            return true
        case .unavailable, .enabled, .requiresApproval, .unknown, .none:
            return false
        }
    }

    /// Prevent a confirmation button that would intentionally make no changes when
    /// command-line setup is already complete and the optional service is unchecked.
    var canApplyReviewedSetup: Bool {
        needsCLISetup || (offersBackgroundService && enableBackgroundService)
    }

    /// Reads the current state without writing to disk.  A detached task keeps profile
    /// and Docker-config inspection out of the main-actor rendering path.
    func prepare() async {
        guard !hasPrepared, !isLoading else { return }
        isLoading = true
        let planned = await Task.detached(priority: .userInitiated) {
            MorbCliInstallation.plan()
        }.value
        plan = planned
        // `status()` only inspects Service Management and the control-socket path. It
        // never registers, launches, or connects to the background service.
        backgroundServiceStatus = MorbBackgroundService.status()
        hasPrepared = true
        isLoading = false
    }

    /// Applies the reviewed, conservative selections. No `--make-default` equivalent
    /// is exposed here: when another Docker client is first on PATH it stays first, and
    /// a named Docker context stays current. Background-service registration occurs
    /// only after the person has selected its clearly described toggle and confirms.
    func install() async {
        guard let reviewedPlan = plan, !isInstalling, canApplyReviewedSetup else { return }

        isInstalling = true
        errorMessage = nil
        do {
            if needsCLISetup {
                result = try await Task.detached(priority: .userInitiated) {
                    try MorbCliInstallation.install(reviewedPlan: reviewedPlan)
                }.value
            }
            if offersBackgroundService && enableBackgroundService {
                // ServiceManagement owns the user-visible Login Items state. This is
                // intentionally on the explicit setup path, never in `prepare()`.
                backgroundServiceStatus = try MorbBackgroundService.enable()
            }
            hasCompletedSetup = true
        } catch {
            errorMessage = (error as? MorbError)?.description ?? error.localizedDescription
        }
        isInstalling = false
    }

    func retry() async {
        result = nil
        errorMessage = nil
        backgroundServiceStatus = nil
        hasCompletedSetup = false
        hasPrepared = false
        await prepare()
    }
}

// MARK: - Sheet

/// Native first-run consent for Morbstack's bundled Docker CLI.
///
/// This is intentionally a normal macOS sheet containing a `Form`, not an overlay or
/// dashboard.  The system owns the sheet's glass and transition; the plan remains a
/// dense, legible content surface beneath it.
struct FirstRunCLISetupSheet: View {

    @Bindable var model: FirstRunCLISetupModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading || model.plan == nil {
                    ProgressView("Checking Docker command-line setup…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = model.errorMessage {
                    failureView(errorMessage)
                } else if model.hasCompletedSetup {
                    completionView()
                } else if let plan = model.plan {
                    planForm(plan)
                }
            }
            .navigationTitle("Set Up Morbstack")
            .toolbar { toolbar }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 540)
        .task {
            await model.prepare()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.hasCompletedSetup ? "Done" : "Not Now") {
                isPresented = false
            }
            .disabled(model.isInstalling)
        }

        if model.errorMessage != nil || model.result?.contextError != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Review Setup Again") {
                    Task { await model.retry() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isInstalling)
            }
        } else if model.plan != nil, !model.hasCompletedSetup {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await model.install() }
                } label: {
                    if model.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Set Up Morbstack")
                    }
                }
                .accessibilityLabel("Set Up Morbstack")
                .help("Apply the changes shown in this sheet")
                .keyboardShortcut(.defaultAction)
                .disabled(model.isInstalling || !model.canApplyReviewedSetup)
            }
        }
    }

    private func planForm(_ plan: MorbCliInstallation.Plan) -> some View {
        Form {
            Section {
                Text(
                    "Use Morbstack’s bundled Docker client, Compose, and Buildx from new Terminal sessions."
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Command-Line Tools") {
                linkRow(plan.docker)
                ForEach(plan.plugins, id: \.name) { item in
                    linkRow(item)
                }
            }

            Section("Shell, Docker context, and discovery") {
                planLine(title: "PATH", detail: plan.pathRegistration.firstRunDescription)
                planLine(title: "Context", detail: plan.contextRegistration.firstRunDescription)
                planLine(title: "Direct socket", detail: plan.directSocket.firstRunDescription)
            }

            backgroundServiceSection

            Section {
                Label(
                    "The command-line changes above are limited to links, shell configuration, Docker connection setup, and one user-owned socket link. If selected, the Background Service option also registers the Login Item described above. No VM starts, and no images, volumes, or credentials change.",
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if case .preservesExistingDocker = plan.pathRegistration {
                    Label(
                        "Your existing Docker client remains first on PATH.",
                        systemImage: "arrow.right.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "Morbstack never makes another named Docker context current from this sheet. You can inspect or remove this setup later with morb uninstall-cli."
                )
            }
        }
        .disabled(model.isInstalling)
    }

    private func linkRow(_ item: MorbCliInstallation.LinkItem) -> some View {
        LabeledContent(item.name) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.source ?? "Bundled client unavailable")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(item.destination)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                if item.willReplace {
                    Label("Replaces the existing file or link", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if item.alreadyCorrect {
                    Label("Already linked", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func planLine(title: String, detail: String) -> some View {
        LabeledContent(title) {
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var backgroundServiceSection: some View {
        if model.offersBackgroundService {
            Section("Background Service") {
                Toggle("Start Morbstack’s host service at login", isOn: $model.enableBackgroundService)

                Text(
                    "If selected, Morbstack registers a per-user background service in Login Items. macOS may run the lightweight host service now and after future sign-in; it does not start the VM or containers, and it does not change Docker data, images, volumes, or credentials."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "You can turn it off later in System Settings > Login Items or with morb service disable."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if let status = model.backgroundServiceStatus,
                  status.registration != .unavailable {
            Section("Background Service") {
                LabeledContent("Status") {
                    Text(status.registration.firstRunDescription)
                }
                Text(status.diagnostic)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status.registration == .requiresApproval {
                    Button("Open Login Items…") {
                        MorbBackgroundService.openLoginItemsSettings()
                    }
                }
            }
        }
    }

    private func completionView() -> some View {
        Form {
            Section {
                if let result {
                    Label(
                        result.contextError == nil ? "Docker CLI Is Ready" : "Docker CLI Installed",
                        systemImage: "checkmark.circle"
                    )
                    Text(result.completionDescription)
                        .fixedSize(horizontal: false, vertical: true)

                    if let contextError = result.contextError {
                        Label(contextError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The CLI links were installed. Fix the Docker configuration issue, then try setup again.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Morbstack Is Ready", systemImage: "checkmark.circle")
                    Text("The command-line configuration was already ready.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Setup Complete")
            }
            if let status = model.backgroundServiceStatus {
                Section("Background Service") {
                    LabeledContent("Status") {
                        Text(status.registration.firstRunDescription)
                    }
                    Text(status.diagnostic)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if status.registration == .requiresApproval {
                        Button("Open Login Items…") {
                            MorbBackgroundService.openLoginItemsSettings()
                        }
                    }
                }
            }
            Section("Next Step") {
                if model.result != nil {
                    Text("Open a new Terminal session to use the updated command-line tools.")
                } else {
                    Text("Use the Morbstack menu to start the engine when you are ready.")
                }
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        Form {
            Section {
                Label("Could Not Finish Setup", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Setup Needs Attention")
            } footer: {
                Text("Review the current setup before applying it again. Any completed command-line changes remain in place.")
            }
        }
    }
}

// MARK: - Plan rendering

private extension MorbCliInstallation.PathRegistration {

    var firstRunDescription: String {
        switch self {
        case .alreadyReachable:
            return "Morbstack’s command-line tools are already on PATH. No shell profile changes."
        case .preservesExistingDocker(let existing):
            return "Leaves \(existing) ahead of Morbstack on PATH."
        case .addToProfile(let profile):
            return "Adds one reversible Morbstack PATH block to \(profile)."
        case .profileAlreadyManaged(let profile):
            return "The managed Morbstack block in \(profile) is already correct."
        case .skippedForHomeOverride:
            return "Not persisted because MORBSTACK_HOME is overridden."
        case .unsupportedShell:
            return "Not changed because this shell cannot be configured safely."
        case .malformedExistingBlock(let profile):
            return "Not changed: \(profile) contains a hand-edited Morbstack block."
        }
    }
}

private extension MorbCliInstallation.ContextRegistration {

    var firstRunDescription: String {
        switch self {
        case .willCreateAndUse:
            return "Creates the morbstack context and makes it current because Docker uses its default context."
        case .willCreateWithoutChangingCurrent(let current):
            return "Registers morbstack and leaves the named context \(current) current."
        case .alreadyCurrent:
            return "The morbstack context is already registered and current."
        case .alreadyRegisteredWithoutChangingCurrent(let current):
            return "Morbstack is registered; the named context \(current) stays current."
        case .staleWillReplaceAndUse:
            return "Repairs the stale morbstack context and makes it current because Docker uses its default context."
        case .staleWillReplaceWithoutChangingCurrent(let current):
            return "Repairs Morbstack’s stale context and leaves the named context \(current) current."
        }
    }
}

private extension MorbDockerContext.DirectSocketStatus {

    var firstRunDescription: String {
        switch state {
        case .missing:
            return "Creates \(path) → \(expectedDestination) for tools that use Docker’s conventional per-user socket."
        case .correct:
            return "\(path) already points to Morbstack."
        case .pointsElsewhere(let destination):
            return "Leaves the existing link to \(destination) unchanged."
        case .occupied(let kind):
            return "Leaves the existing \(kind) at \(path) unchanged."
        case .unavailable(let reason):
            return "Not changed: \(reason)."
        }
    }
}

private extension MorbCliInstallation.InstallResult {

    var completionDescription: String {
        var lines = ["Open a new Terminal, then run docker version, docker compose version, and docker buildx version."]
        if contextBecameCurrent {
            lines.append("Docker’s current context is now morbstack.")
        } else if contextCreated {
            lines.append("The morbstack Docker context was registered without changing your selected context.")
        }
        switch directSocket.state {
        case .correct:
            lines.append("Docker’s conventional per-user socket now points to Morbstack.")
        case .pointsElsewhere, .occupied, .unavailable, .missing:
            lines.append("An existing Docker discovery path was left unchanged.")
        }
        return lines.joined(separator: " ")
    }
}

private extension MorbBackgroundService.Registration {

    var firstRunDescription: String {
        switch self {
        case .unavailable:
            return "Unavailable from this app bundle"
        case .notRegistered, .notFound:
            return "Not enabled"
        case .enabled:
            return "Enabled at login"
        case .requiresApproval:
            return "Needs approval in Login Items"
        case .unknown:
            return "Needs review in Login Items"
        }
    }
}
