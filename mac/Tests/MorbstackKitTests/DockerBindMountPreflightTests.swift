// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

final class DockerBindMountPreflightTests: XCTestCase {

    private let userShare = MorbDirectoryShare(tag: "morbshare0", path: "/Users")
    private let tmpShare = MorbDirectoryShare(tag: "morbshare1", path: "/private/tmp")

    private func mountedStates(for shares: [MorbDirectoryShare]) -> [String: MorbShares.GuestMountState] {
        Dictionary(uniqueKeysWithValues: shares.map { ($0.path, .mounted) })
    }

    private func inspect(
        _ json: String,
        shares: [MorbDirectoryShare]? = nil,
        states: [String: MorbShares.GuestMountState]? = nil,
        tmpAliasMounted: Bool? = true,
        sourceExists: @escaping (String) -> Bool = { _ in true },
        sourcePathResolving: @escaping (String) -> String = { $0 }
    ) -> DockerBindMountPreflight.Verdict {
        let activeShares = shares ?? [userShare]
        return DockerBindMountPreflight.inspectContainerCreate(
            body: Data(json.utf8),
            shares: activeShares,
            guestShareStates: states ?? mountedStates(for: activeShares),
            guestTmpAliasMounted: tmpAliasMounted,
            sourceExists: sourceExists,
            sourcePathResolving: sourcePathResolving)
    }

    func testLegacyBindUnderMountedShareIsAllowed() {
        XCTAssertEqual(
            inspect(#"{"HostConfig":{"Binds":["/Users/allie/project:/workspace"]}}"#),
            .allowed)
    }

    func testTmpAliasMatchesThePrivateTmpShare() {
        XCTAssertEqual(
            inspect(
                #"{"HostConfig":{"Binds":["/tmp/project:/workspace"]}}"#,
                shares: [tmpShare],
                sourceExists: { $0 == "/private/tmp/project" }),
            .allowed)
    }

    func testBareTmpAliasRequiresTheGuestToConfirmItsAliasMount() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/tmp/project:/workspace"]}}"#,
            shares: [tmpShare],
            tmpAliasMounted: nil)
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path uses macOS /tmp, but the running VM has not confirmed its /tmp alias to the shared /private/tmp directory; repair that share and restart Morbstack"))
    }

    func testExplicitTmpBindChecksTheLiteralDockerSourceOnTheMac() {
        XCTAssertEqual(
            inspect(
                #"{"Mounts":[{"Type":"bind","Source":"/tmp/project","Target":"/workspace"}]}"#,
                shares: [tmpShare],
                sourceExists: { $0 == "/tmp/project" }),
            .allowed)
    }

    func testBareVarAliasIsRejectedRatherThanResolvedAgainstGuestSystemState() {
        let result = inspect(#"{"HostConfig":{"Binds":["/var/project:/workspace"]}}"#)
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path uses the macOS /var alias, but /var is a guest system path; use the explicit /private/var source path after sharing it"))
    }

    func testGuestDockerSocketBindIsAllowedWithoutAMacShare() {
        XCTAssertEqual(
            inspect(
                #"{"HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock:ro"]}}"#,
                shares: [],
                states: [:],
                sourceExists: { _ in false }),
            .allowed)
    }

    func testExplicitGuestDockerSocketBindIsAllowedWithoutAMacSourceCheck() {
        XCTAssertEqual(
            inspect(
                #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/run/docker.sock","Target":"/var/run/docker.sock","ReadOnly":true}]}}"#,
                shares: [],
                states: [:],
                sourceExists: { _ in false }),
            .allowed)
    }

    func testAdvancedBindOptionsRemainTheEnginesResponsibility() {
        XCTAssertEqual(
            inspect(
                #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/Users/allie/project","Target":"/workspace","ReadOnly":true,"BindOptions":{"Propagation":"rslave","NonRecursive":true,"ReadOnlyNonRecursive":true}}]}}"#),
            .allowed)
    }

    func testNamedVolumeOptionsBypassHostShareAdmission() {
        XCTAssertEqual(
            inspect(
                #"{"HostConfig":{"Mounts":[{"Type":"volume","Source":"workspace-cache","Target":"/cache","ReadOnly":false,"VolumeOptions":{"NoCopy":true,"Subpath":"npm"}}]}}"#,
                shares: [],
                states: [:],
                sourceExists: { _ in false }),
            .allowed)
    }

    func testOnlyTheExactGuestDockerSocketBypassesTheBareVarAliasCheck() {
        let result = inspect(#"{"HostConfig":{"Binds":["/var/run/docker.sock/child:/workspace"]}}"#)
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path uses the macOS /var alias, but /var is a guest system path; use the explicit /private/var source path after sharing it"))
    }

    func testUnsharedLegacyBindIsRejectedBeforeGuestDirectoryCanBeCreated() {
        let result = inspect(#"{"HostConfig":{"Binds":["/opt/secret:/run/secret"]}}"#)
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path is not shared with the Morbstack VM: /opt/secret (add a shared_paths root that contains it, then restart Morbstack)"))
    }

    func testFailedShareIsRejected() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/Users/allie/project:/workspace"]}}"#,
            states: ["/Users": .failed])
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": share /Users is not mounted in the running VM; repair the share and restart Morbstack"))
    }

    func testMissingGuestShareReportIsRejectedRatherThanAssumedMounted() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/Users/allie/project:/workspace"]}}"#,
            states: [:])
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": Morbstack cannot verify that /Users is mounted in the running VM; restart Morbstack to use a guest that reports VirtioFS share state"))
    }

    func testExplicitBindMountRequiresAnExistingSource() {
        let result = inspect(
            #"{"Mounts":[{"Type":"bind","Source":"/Users/allie/missing","Target":"/workspace"}]}"#,
            sourceExists: { _ in false })
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path does not exist: /Users/allie/missing"))
    }

    func testHostConfigMountsRejectAnUnsharedSourceBeforeItReachesTheGuest() {
        let result = inspect(
            #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/opt/project","Target":"/workspace"}]}}"#)
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path is not shared with the Morbstack VM: /opt/project (add a shared_paths root that contains it, then restart Morbstack)"))
    }

    func testHostConfigMountsRequireAnExistingSource() {
        let result = inspect(
            #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/Users/allie/missing","Target":"/workspace"}]}}"#,
            sourceExists: { _ in false })
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path does not exist: /Users/allie/missing"))
    }

    func testLegacyBindRetainsDockerDirectoryCreationInsideALiveShare() {
        XCTAssertEqual(
            inspect(
                #"{"HostConfig":{"Binds":["/Users/allie/new-directory:/workspace"]}}"#,
                sourceExists: { _ in false }),
            .allowed)
    }

    func testExplicitRelativeBindSourceIsRejected() {
        let result = inspect(#"{"Mounts":[{"Type":"bind","Source":"project","Target":"/workspace"}]}"#)
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path must be absolute: project"))
    }

    func testNamedVolumesAndMalformedJSONRemainTheEnginesResponsibility() {
        XCTAssertEqual(
            inspect(#"{"HostConfig":{"Binds":["workspace-cache:/cache"]}}"#),
            .allowed)
        XCTAssertEqual(inspect("not JSON"), .allowed)
    }

    func testSourceThatResolvesOutsideTheShareIsRejected() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/Users/allie/outside-link/project:/workspace"]}}"#,
            sourcePathResolving: { _ in "/opt/secret/project" })
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path resolves outside directories shared with the Morbstack VM: /Users/allie/outside-link/project -> /opt/secret/project (add the resolved root to shared_paths, then restart Morbstack)"))
    }

    func testBindSourcePreservesDotDotUntilSymlinkResolution() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/Users/allie/link/../project:/workspace"]}}"#,
            sourcePathResolving: { source in
                source == "/Users/allie/link/../project" ? "/opt/project" : "/"
            })
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path resolves outside directories shared with the Morbstack VM: /Users/allie/link/../project -> /opt/project (add the resolved root to shared_paths, then restart Morbstack)"))
    }
}
