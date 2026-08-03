// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's read-only view of file sharing and Rosetta.
//
// Thin on purpose. `MorbShareSurface` in MorbstackKit already owns the hard parts — the
// config reconstruction, the daemon decode, the merge, and the `Source` distinction that
// keeps "the guest says it is missing" apart from "there is no guest" — and both the CLI
// and the app read the same answers from it. What lives here is only what a *window*
// needs and a terminal does not: the host Rosetta probe, and the wording and tone of the
// one chip in the status footer.
//
// The rule the chip turns on: *never warn about an engine that is not running.* A
// stopped VM has nothing mounted, which is correct and uninteresting. A chip that is
// always lit is furniture; people stop reading it, and then it is worse than absent
// because it was supposed to be the thing that told them.

import Foundation
import MorbstackKit
import Virtualization

// MARK: - Host capability

/// What this Mac can say about Rosetta without a VM.
enum TrackERosettaHost {

    /// `(installed, supported)` for this host.
    ///
    /// `VZLinuxRosettaDirectoryShare.availability` is a plain query: no entitlement, no
    /// VM, no permission prompt. That matters because Settings shows this row with the
    /// engine stopped, which is precisely when somebody is trying to work out why an
    /// amd64 image will not start.
    ///
    /// The two answers are separate. *Unsupported* — an Intel Mac, or an OS without the
    /// directory share — has no remedy and must not be rendered as a call to action.
    static func probe() -> (installed: Bool, supported: Bool) {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed: return (true, true)
        case .notInstalled: return (false, true)
        case .notSupported: return (false, false)
        @unknown default:
            // A case from a future OS is not evidence of absence. Claiming "not
            // installed" would send the user to install something they may already have.
            return (false, true)
        }
    }

    /// The Rosetta state observable from this host alone, before any daemon answers.
    ///
    /// `activeInGuest` and `binfmtRegistered` are left `nil` rather than `false`: the
    /// guest has not been asked, and the tri-state is what stops the UI telling somebody
    /// to reinstall Rosetta when all they have to do is start the engine.
    static func localState(enabledInConfig: Bool) -> MorbRosettaState {
        let (installed, supported) = probe()
        return MorbRosettaState(
            installed: installed,
            enabledInConfig: enabledInConfig,
            supported: supported)
    }
}

// MARK: - Status chip

/// A one-line warning for the status footer.
struct TrackEStatusChip: Equatable, Sendable {
    var text: String
    var detail: String
    var symbol: String
}

// MARK: - Derivation

/// The pure decisions behind the sharing UI.
enum TrackEShareStatus {

    /// The warning chip for the status footer, or `nil` when there is nothing to say.
    ///
    /// Two gates, and both matter. `Report.hasWarning` requires the rows to have come
    /// from a *daemon*, so a config-only reconstruction never accuses anybody of
    /// anything. `engineRunning` then requires the app to agree — the report can outlive
    /// a VM that stopped a moment ago, and a warning that flashes up during shutdown is
    /// noise at exactly the wrong time.
    static func chip(
        _ report: MorbShareSurface.Report,
        engineRunning: Bool
    ) -> TrackEStatusChip? {
        guard engineRunning, report.hasWarning else { return nil }
        let degraded = report.shares.filter(\.isDegraded)
        guard !degraded.isEmpty else { return nil }

        let text = degraded.count == 1
            ? "1 folder not shared"
            : "\(degraded.count) folders not shared"

        var lines: [String] = []
        lines.append(
            degraded.count == 1
                ? "This folder is configured for sharing but the VM has not mounted it:"
                : "These folders are configured for sharing but the VM has not mounted them:")
        for share in degraded {
            // The per-root reason when the host or the guest gave one — a `/Volumes`
            // that does not exist and a virtiofs mount that failed are the same row with
            // very different remedies.
            if let explanation = share.explanation {
                lines.append("  • \(share.path) — \(explanation)")
            } else {
                lines.append("  • \(share.path)")
            }
        }
        lines.append("")
        lines.append(
            "A container bind-mounting a path underneath "
                + (degraded.count == 1 ? "it" : "them")
                + " sees an empty directory rather than an error. Open Settings › File "
                + "Sharing, or restart the engine to re-apply the configuration.")

        return TrackEStatusChip(
            text: text,
            detail: lines.joined(separator: "\n"),
            symbol: "folder.badge.questionmark")
    }

    /// Whether the app knows enough to accuse a container's bind mount of being unshared.
    ///
    /// Requires a live answer. Judging a bind mount against a share list reconstructed
    /// from a config file the running VM may predate would flag working mounts as broken,
    /// which is a worse failure than saying nothing.
    static func canJudgeBindMounts(_ report: MorbShareSurface.Report) -> Bool {
        report.source == .daemon
    }

    /// The Settings row's summary line for one root.
    ///
    /// Deliberately different wording for "not mounted because nothing is running" and
    /// "not mounted and something is wrong". They are identical in the data and opposite
    /// in meaning to the reader.
    static func rowSummary(
        _ share: MorbShareState,
        source: MorbShareSurface.Source,
        engineRunning: Bool
    ) -> String {
        if !share.configured {
            return "mounted, but no longer listed in config.toml"
        }
        if share.mounted {
            return share.readOnly ? "mounted, read-only" : "mounted"
        }
        if source == .config || !engineRunning {
            // Nothing is mounted in a VM that is not running. Say why, and do not colour
            // it as a fault.
            if let explanation = share.explanation {
                return "not shared — \(explanation)"
            }
            return "not mounted — the engine is not running"
        }
        if let explanation = share.explanation {
            return "not mounted — \(explanation)"
        }
        return "not mounted"
    }
}
