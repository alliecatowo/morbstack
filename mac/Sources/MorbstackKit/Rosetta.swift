// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Rosetta — the host side of amd64 support.
//
// Virtualization.framework exposes Rosetta to a Linux guest as a directory
// share tagged `rosetta`; the guest mounts it and registers the interpreter
// with `binfmt_misc` (see guest/morbinit/src/binfmt.rs). This file owns the
// two host-side questions that wiring raises: *is Rosetta available*, and
// *who is allowed to install it*.

import Foundation
import Virtualization

/// The host's Rosetta-for-Linux state, in the terms Morbstack cares about.
///
/// A thin, `Sendable`, non-Virtualization-typed mirror of
/// `VZLinuxRosettaDirectoryShare.Availability`. Worth the extra type for two
/// reasons: it gives the mapping from Apple's enum to our user-facing text a
/// pure, testable home, and it keeps `@unknown default` handled in exactly
/// one place rather than at each of the three call sites (VMManager, Doctor,
/// the CLI) that used to switch over the raw enum independently.
public enum RosettaState: String, Codable, Equatable, Sendable {

    /// Rosetta for Linux is installed and a share can be created.
    case installed

    /// The host is capable, but the Rosetta for Linux runtime has not been
    /// downloaded yet. Recoverable — see ``RosettaSupport/install(_:)``.
    case notInstalled = "not-installed"

    /// This Mac cannot run Rosetta at all (an Intel host, or a macOS too old
    /// for the Linux runtime). Nothing the user can do.
    case notSupported = "not-supported"

    /// Apple added an availability case this build does not know about.
    /// Treated as "assume it does not work" everywhere.
    case unknown

    /// Whether a `VZLinuxRosettaDirectoryShare` can be attached in this state.
    public var canAttachShare: Bool { self == .installed }

    /// Whether `morb rosetta install` has anything to do.
    public var isInstallable: Bool { self == .notInstalled }

    /// One line of user-facing explanation. Also what `morb doctor` prints.
    public var detail: String {
        switch self {
        case .installed:
            return "installed"
        case .notInstalled:
            return "not installed — run `morb rosetta install` to enable "
                + "--platform linux/amd64 (downloads Apple's Rosetta runtime)"
        case .notSupported:
            return "not supported on this host — amd64 images will not run"
        case .unknown:
            return "availability unknown to this build — assuming amd64 images will not run"
        }
    }

    /// The severity `morb doctor` should report this state at.
    ///
    /// Never `.fail`: an arm64-only Morbstack is a perfectly working
    /// Morbstack, and failing the whole health check over a missing optional
    /// emulator would train people to ignore a red doctor.
    public var doctorStatus: DoctorCheck.Status {
        self == .installed ? .pass : .warn
    }
}

/// Host-side Rosetta queries and the (deliberately user-gated) installer.
public enum RosettaSupport {

    /// The virtiofs tag the Rosetta share is exported under.
    ///
    /// Shared with the guest by convention rather than by code: morbinit
    /// mounts this exact string (`binfmt::ROSETTA_TAG`). Changing one
    /// without the other silently disables amd64 support, so both sides name
    /// the constant and point at each other.
    public static let shareTag = "rosetta"

    /// Where the guest mounts the share. Only used for diagnostics on this
    /// side; the authority is `binfmt::ROSETTA_MOUNTPOINT`.
    public static let guestMountPoint = "/run/rosetta"

    /// The current state, read live from Virtualization.framework.
    public static var state: RosettaState {
        map(VZLinuxRosettaDirectoryShare.availability)
    }

    /// Pure mapping from Apple's enum to ``RosettaState``.
    ///
    /// Split out from ``state`` so it can be unit tested: the framework
    /// property reports whatever the test machine happens to have installed,
    /// which is exactly the thing a test must not depend on.
    /// - Note: the parameter type is the top-level `VZLinuxRosettaAvailability`,
    ///   not a type nested inside `VZLinuxRosettaDirectoryShare` — the header
    ///   declares it as a free `NS_ENUM` that the class merely returns.
    public static func map(_ availability: VZLinuxRosettaAvailability) -> RosettaState {
        switch availability {
        case .installed: return .installed
        case .notInstalled: return .notInstalled
        case .notSupported: return .notSupported
        @unknown default: return .unknown
        }
    }

    /// Creates the share to attach to a VM configuration, or `nil` when the
    /// host is not in a state to provide one.
    ///
    /// Never throws: a Rosetta share is optional, and a host problem here
    /// must degrade the VM to arm64-only rather than stop it booting. The
    /// reason is handed back so the caller can log something specific.
    public static func makeShare() -> (share: VZLinuxRosettaDirectoryShare?, reason: String) {
        let state = self.state
        guard state.canAttachShare else {
            return (nil, state.detail)
        }
        do {
            return (try VZLinuxRosettaDirectoryShare(), state.detail)
        } catch {
            // `.installed` and "constructible" are not quite the same thing:
            // the runtime can be present but unreadable by this user, or
            // mid-update.
            return (nil, "installed but the share could not be created: \(error.localizedDescription)")
        }
    }

    /// Errors from ``install(_:)``.
    public enum InstallError: Error, CustomStringConvertible {
        /// Rosetta is already there; nothing to do.
        case alreadyInstalled
        /// This Mac cannot run Rosetta.
        case notSupported
        /// Apple's installer failed or the user declined it.
        case failed(String)

        public var description: String {
            switch self {
            case .alreadyInstalled:
                return "Rosetta for Linux is already installed"
            case .notSupported:
                return "Rosetta for Linux is not supported on this host"
            case .failed(let message):
                return "Rosetta installation failed: \(message)"
            }
        }
    }

    /// Downloads and installs Rosetta for Linux, blocking until it finishes.
    ///
    /// - Important: **only ever call this from an interactive `morb` command
    ///   the user typed.** `VZLinuxRosettaDirectoryShare.installRosetta`
    ///   puts a system-level software-installation dialog on screen and
    ///   downloads a runtime from Apple. A background daemon must never be
    ///   the thing that does that: morbstackd can start at login, so a
    ///   daemon-side install would surface an unexplained system prompt with
    ///   no visible application behind it, and would do it on a machine
    ///   whose owner never asked for amd64 support. That is why
    ///   `VMManager` only ever *reports* ``RosettaState/notInstalled`` and
    ///   this function lives behind `morb rosetta install`.
    ///
    /// Synchronous because its one caller is a CLI command whose entire job
    /// is to wait for this.
    public static func install(timeout: TimeInterval = 600) throws {
        switch state {
        case .installed: throw InstallError.alreadyInstalled
        case .notSupported, .unknown: throw InstallError.notSupported
        case .notInstalled: break
        }

        // `@unchecked Sendable` box: the completion handler fires on an
        // arbitrary queue, and the semaphore is what orders the write
        // against the read below it.
        final class Box: @unchecked Sendable {
            var error: Error?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)

        VZLinuxRosettaDirectoryShare.installRosetta { error in
            box.error = error
            done.signal()
        }

        guard done.wait(timeout: .now() + timeout) == .success else {
            throw InstallError.failed("timed out after \(Int(timeout))s")
        }
        if let error = box.error {
            throw InstallError.failed(error.localizedDescription)
        }
    }
}

/// The three independent facts about amd64 translation, reconciled into one
/// answer with a sentence explaining it.
///
/// Whether `docker run --platform linux/amd64 …` works depends on three
/// things that live in three different places and disagree constantly:
///
///   1. **Is Rosetta installed on this Mac?** ``RosettaSupport/state``.
///   2. **Did the user ask for it?** `rosetta = true` in morb.toml.
///   3. **Is it working in the guest right now?** Only morbinit knows — it
///      has to mount the virtiofs share and win a `binfmt_misc` registration,
///      either of which can fail while (1) and (2) both say yes. Arrives in
///      the MRB0 `info` reply as `rosetta` and `binfmt_amd64`.
///
/// (1) and (3) diverge for a mundane and very common reason: the Rosetta
/// share is a *device*, attached when the VM is configured. Installing
/// Rosetta, or flipping `rosetta = true`, changes nothing about a VM that is
/// already running. A status display that collapses these into one boolean
/// says "Rosetta: off" while `morb doctor` says "installed", and the user has
/// no way to reconcile the two.
///
/// So this type keeps them apart, and its one interesting piece of logic is
/// ``composeNote(state:enabledInConfig:guestAnswered:guestRosetta:guestBinfmt:)``:
/// the sentence naming *which* fact is the blocker and what to do about it.
/// That function is pure and unit tested, because when the feature is not
/// working that sentence is the entire user-facing value.
public struct RosettaStatus: Codable, Equatable, Sendable {

    /// Rosetta for Linux is installed on this Mac.
    public var installed: Bool
    /// `rosetta = true` in morb.toml.
    public var enabledInConfig: Bool
    /// The guest mounted the share *and* registered an interpreter from it.
    /// `nil` when no guest has answered.
    public var activeInGuest: Bool?
    /// Some x86-64 interpreter is registered in the guest — possibly qemu
    /// rather than Rosetta. `nil` when no guest has answered.
    public var binfmtRegistered: Bool?
    /// One sentence explaining the combination, and the next action if any.
    public var note: String
    /// The raw host state, so `doctor` can tell "install it" apart from
    /// "you are on an Intel Mac".
    public var state: RosettaState
    /// Which interpreter the guest registered: `rosetta`, `qemu`, or `none`.
    /// `nil` when no guest has answered.
    public var binfmtAmd64: String?

    public init(
        installed: Bool, enabledInConfig: Bool, activeInGuest: Bool?,
        binfmtRegistered: Bool?, note: String, state: RosettaState, binfmtAmd64: String?
    ) {
        self.installed = installed
        self.enabledInConfig = enabledInConfig
        self.activeInGuest = activeInGuest
        self.binfmtRegistered = binfmtRegistered
        self.note = note
        self.state = state
        self.binfmtAmd64 = binfmtAmd64
    }

    /// Builds a status from the three facts, composing the note.
    ///
    /// `guestAnswered` is what separates "no guest has told us" from "the
    /// guest told us `none`" — the caller knows this (it has a VM handle) and
    /// this type must not try to infer it from `guestBinfmt == nil`, since a
    /// guest older than the field also sends nothing.
    public static func make(
        state: RosettaState,
        enabledInConfig: Bool,
        guestAnswered: Bool,
        guestRosetta: Bool?,
        guestBinfmt: String?
    ) -> RosettaStatus {
        RosettaStatus(
            installed: state.canAttachShare,
            enabledInConfig: enabledInConfig,
            activeInGuest: guestAnswered ? (guestRosetta ?? false) : nil,
            binfmtRegistered: guestAnswered ? ((guestBinfmt ?? "none") != "none") : nil,
            note: composeNote(
                state: state, enabledInConfig: enabledInConfig, guestAnswered: guestAnswered,
                guestRosetta: guestRosetta, guestBinfmt: guestBinfmt),
            state: state,
            binfmtAmd64: guestAnswered ? (guestBinfmt ?? "none") : nil)
    }

    /// The sentence a user reads to find out why amd64 is or is not working.
    ///
    /// Ordered most-blocking first — hardware, then installation, then
    /// configuration, then "you need to restart", then the running states —
    /// so it always names the *first* thing that has to change rather than a
    /// downstream symptom.
    public static func composeNote(
        state: RosettaState,
        enabledInConfig: Bool,
        guestAnswered: Bool,
        guestRosetta: Bool?,
        guestBinfmt: String?
    ) -> String {
        switch state {
        case .notSupported:
            return "Rosetta is not available on this Mac, so amd64 images cannot be "
                + "translated."
        case .unknown:
            return "This build does not recognise the Rosetta availability macOS "
                + "reported, so amd64 support is unpredictable. Please file an issue."
        case .notInstalled:
            return "Rosetta for Linux is not installed. Run `morb rosetta install`, "
                + "then restart the VM with `morb stop && morb start`."
        case .installed:
            break
        }

        if !enabledInConfig {
            return "Rosetta is installed but switched off by `rosetta = false` in "
                + "morb.toml. Set it to true and restart the VM to run amd64 images."
        }
        guard guestAnswered else {
            return "Rosetta is installed and enabled; it will be attached to the guest "
                + "the next time the VM starts."
        }

        let backend = guestBinfmt ?? "none"
        if guestRosetta == true && backend == "rosetta" {
            return "Rosetta is translating x86_64 binaries in the guest; "
                + "`docker run --platform linux/amd64` works."
        }
        if backend == "qemu" {
            return "The Rosetta share did not come up, but qemu-user is registered for "
                + "x86_64, so amd64 images still run — considerably more slowly. "
                + "Restarting the VM may recover Rosetta."
        }
        // Installed, enabled, a guest is answering, and still nothing: almost
        // always "it was turned on after this VM booted", because the share is
        // attached at configuration time and never afterwards.
        return "Rosetta is installed and enabled, but the running VM has no x86_64 "
            + "interpreter — the share is attached when the VM boots, so a VM started "
            + "before Rosetta was installed or enabled will not have it. Restart with "
            + "`morb stop && morb start`."
    }

    /// Whether amd64 containers can actually run right now.
    ///
    /// Deliberately not ``installed``: at the point of use the only thing that
    /// matters is that the guest has *an* interpreter registered, whichever it
    /// turned out to be.
    public var amd64Works: Bool { binfmtRegistered == true }
}
