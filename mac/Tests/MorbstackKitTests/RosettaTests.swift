// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Virtualization
import XCTest

@testable import MorbstackKit

/// Tests for the host side of amd64 support.
///
/// Everything here goes through ``RosettaSupport/map(_:)`` rather than
/// ``RosettaSupport/state``: the live property reports whatever the machine
/// running the suite happens to have installed, which would make these tests
/// pass or fail based on the developer's Rosetta setup rather than on the
/// code. The whole reason the mapping is a separate pure function is so the
/// three interesting states can be exercised on any host.
final class RosettaTests: XCTestCase {

    // MARK: - Availability mapping

    func testInstalledMapsToInstalled() {
        XCTAssertEqual(RosettaSupport.map(.installed), .installed)
    }

    func testNotInstalledMapsToNotInstalled() {
        XCTAssertEqual(RosettaSupport.map(.notInstalled), .notInstalled)
    }

    func testNotSupportedMapsToNotSupported() {
        XCTAssertEqual(RosettaSupport.map(.notSupported), .notSupported)
    }

    /// Only `.installed` may produce a share. This is the check that keeps a
    /// half-installed host from being handed to `VZLinuxRosettaDirectoryShare()`,
    /// which throws rather than returning nil.
    func testOnlyTheInstalledStateCanAttachAShare() {
        XCTAssertTrue(RosettaState.installed.canAttachShare)
        XCTAssertFalse(RosettaState.notInstalled.canAttachShare)
        XCTAssertFalse(RosettaState.notSupported.canAttachShare)
        XCTAssertFalse(RosettaState.unknown.canAttachShare)
    }

    /// `morb rosetta install` must only offer to act where acting can help.
    /// Offering it on an Intel Mac would download a runtime that can never be
    /// used; offering it when already installed would be a no-op prompt.
    func testOnlyTheNotInstalledStateIsInstallable() {
        XCTAssertTrue(RosettaState.notInstalled.isInstallable)
        XCTAssertFalse(RosettaState.installed.isInstallable)
        XCTAssertFalse(RosettaState.notSupported.isInstallable)
        XCTAssertFalse(RosettaState.unknown.isInstallable)
    }

    // MARK: - Doctor reporting

    /// An arm64-only Morbstack works fine, so a missing optional emulator must
    /// never fail the health check — that would train people to ignore a red
    /// `morb doctor`.
    func testRosettaNeverFailsTheDoctorReport() {
        for state: RosettaState in [.installed, .notInstalled, .notSupported, .unknown] {
            XCTAssertNotEqual(
                state.doctorStatus, .fail,
                "\(state.rawValue) must not fail the health check")
        }
        XCTAssertEqual(RosettaState.installed.doctorStatus, .pass)
        XCTAssertEqual(RosettaState.notInstalled.doctorStatus, .warn)
        XCTAssertEqual(RosettaState.notSupported.doctorStatus, .warn)
        XCTAssertEqual(RosettaState.unknown.doctorStatus, .warn)
    }

    /// The recoverable state is the only one that names a remedy, and it must
    /// name the real command.
    func testOnlyTheRecoverableStateSuggestsInstalling() {
        XCTAssertTrue(RosettaState.notInstalled.detail.contains("morb rosetta install"))
        XCTAssertFalse(RosettaState.installed.detail.contains("morb rosetta install"))
        // Nothing can be done about an Intel host, so do not send the user off
        // to run a command that will refuse.
        XCTAssertFalse(RosettaState.notSupported.detail.contains("morb rosetta install"))
    }

    func testEveryStateExplainsItself() {
        for state: RosettaState in [.installed, .notInstalled, .notSupported, .unknown] {
            XCTAssertFalse(state.detail.isEmpty, "\(state.rawValue) needs a detail line")
        }
    }

    // MARK: - The host/guest tag contract

    /// The tag is the entire interface between `VMManager`'s share and the
    /// guest's `mount -t virtiofs rosetta /run/rosetta`. If these drift, amd64
    /// support silently disappears with no error on either side — the share is
    /// attached, the mount just finds nothing.
    func testTheShareTagMatchesWhatTheGuestMounts() {
        XCTAssertEqual(RosettaSupport.shareTag, "rosetta")
        XCTAssertEqual(RosettaSupport.guestMountPoint, "/run/rosetta")
    }

    /// Virtualization.framework enforces its own tag rules; a tag it rejects
    /// throws at configuration time and takes the whole VM down with it.
    func testTheShareTagIsAcceptedByTheFramework() {
        XCTAssertNoThrow(
            try VZVirtioFileSystemDeviceConfiguration.validateTag(RosettaSupport.shareTag))
    }

    // MARK: - Wire form

    /// The states are `Codable` and appear in `morb doctor --json`, so the raw
    /// values are a published interface.
    func testStateRawValuesAreStable() {
        XCTAssertEqual(RosettaState.installed.rawValue, "installed")
        XCTAssertEqual(RosettaState.notInstalled.rawValue, "not-installed")
        XCTAssertEqual(RosettaState.notSupported.rawValue, "not-supported")
        XCTAssertEqual(RosettaState.unknown.rawValue, "unknown")
    }

    // MARK: - Install refusals

    /// The installer must refuse the two states it cannot help with, and it must
    /// do so *before* calling Apple's API — that call puts a system dialog on
    /// screen, and a refusal that prompts first is not a refusal.
    func testInstallRefusesStatesItCannotHelp() throws {
        // Only assertable for the state this host is actually in; the rest of
        // the ladder is covered by `isInstallable` above. On a machine with
        // Rosetta installed this exercises the `.alreadyInstalled` branch.
        guard RosettaSupport.state == .installed else {
            throw XCTSkip("this host does not have Rosetta installed")
        }
        XCTAssertThrowsError(try RosettaSupport.install(timeout: 1)) { error in
            guard case RosettaSupport.InstallError.alreadyInstalled = error else {
                return XCTFail("expected .alreadyInstalled, got \(error)")
            }
        }
    }

    func testInstallErrorsDescribeThemselves() {
        XCTAssertTrue(
            RosettaSupport.InstallError.alreadyInstalled.description.contains("already installed"))
        XCTAssertTrue(
            RosettaSupport.InstallError.notSupported.description.contains("not supported"))
        XCTAssertTrue(
            RosettaSupport.InstallError.failed("disk full").description.contains("disk full"))
    }
}
