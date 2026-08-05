// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

final class DockerBindMountPreflightTests: XCTestCase {

    private let userShare = MorbDirectoryShare(tag: "morbshare0", path: "/Users")
    private let tmpShare = MorbDirectoryShare(tag: "morbshare1", path: "/private/tmp")
    private let privateEtcShare = MorbDirectoryShare(tag: "morbshare2", path: "/private/etc")
    private let privateVarShare = MorbDirectoryShare(tag: "morbshare3", path: "/private/var")

    private func mountedStates(for shares: [MorbDirectoryShare]) -> [String: MorbShares.GuestMountState] {
        Dictionary(uniqueKeysWithValues: shares.map { ($0.path, .mounted) })
    }

    private func inspect(
        _ json: String,
        shares: [MorbDirectoryShare]? = nil,
        states: [String: MorbShares.GuestMountState]? = nil,
        tmpAliasMounted: Bool? = true,
        hostDockerSocketPath: String? = nil,
        sourceExists: @escaping (String) -> Bool = { _ in true },
        sourcePathResolving: @escaping (String) -> String = { $0 }
    ) -> DockerBindMountPreflight.Verdict {
        let activeShares = shares ?? [userShare]
        return DockerBindMountPreflight.inspectContainerCreate(
            body: Data(json.utf8),
            shares: activeShares,
            guestShareStates: states ?? mountedStates(for: activeShares),
            guestTmpAliasMounted: tmpAliasMounted,
            hostDockerSocketPath: hostDockerSocketPath,
            sourceExists: sourceExists,
            sourcePathResolving: sourcePathResolving)
    }

    private func prepare(
        _ json: String,
        shares: [MorbDirectoryShare]? = nil,
        states: [String: MorbShares.GuestMountState]? = nil,
        tmpAliasMounted: Bool? = true,
        hostDockerSocketPath: String? = nil,
        sourceExists: @escaping (String) -> Bool = { _ in true },
        sourcePathResolving: @escaping (String) -> String = { $0 }
    ) -> DockerBindMountPreflight.Preparation {
        let activeShares = shares ?? [userShare]
        return DockerBindMountPreflight.prepareContainerCreate(
            body: Data(json.utf8),
            shares: activeShares,
            guestShareStates: states ?? mountedStates(for: activeShares),
            guestTmpAliasMounted: tmpAliasMounted,
            hostDockerSocketPath: hostDockerSocketPath,
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

    func testBareVarAliasIsRewrittenToAVerifiedPrivateVarSource() throws {
        let result = prepare(
            #"{"HostConfig":{"Binds":["/var/log/app:/workspace:ro"]}}"#,
            shares: [privateVarShare],
            sourcePathResolving: { _ in "/private/var/log/app" })
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected verified macOS /var source to be admitted")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(hostConfig["Binds"] as? [String], ["/private/var/log/app:/workspace:ro"])
    }

    func testBareEtcAliasIsRewrittenToTheVerifiedMacHostFile() throws {
        let result = prepare(
            #"{"HostConfig":{"Binds":["/etc/hosts:/host-etc-hosts:ro"]}}"#,
            shares: [privateEtcShare],
            sourcePathResolving: { _ in "/private/etc/hosts" })
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected verified macOS /etc/hosts to be admitted")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(hostConfig["Binds"] as? [String], ["/private/etc/hosts:/host-etc-hosts:ro"])
    }

    func testBareSystemAliasUsesItsResolvedHostTargetRatherThanAGuestTraversal() throws {
        let result = prepare(
            #"{"HostConfig":{"Binds":["/etc/tool-link:/tool"]}}"#,
            shares: [userShare],
            sourcePathResolving: { _ in "/Users/allie/host-tool" })
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected a shared resolved host target")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(hostConfig["Binds"] as? [String], ["/Users/allie/host-tool:/tool"])
    }

    func testBareSystemAliasRequiresAnExistingHostSourceEvenForLegacyV() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/etc/not-yet-created:/workspace"]}}"#,
            shares: [privateEtcShare],
            sourceExists: { _ in false })
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": macOS /etc alias source must exist before Morbstack can safely bind it: /etc/not-yet-created"))
    }

    func testBareSystemAliasRejectsAResolvedTargetOutsideMountedShares() {
        let result = inspect(
            #"{"HostConfig":{"Binds":["/etc/hosts:/workspace"]}}"#,
            sourcePathResolving: { _ in "/opt/secret/hosts" })
        XCTAssertEqual(
            result,
            .rejected(
                message: "invalid mount config for type \"bind\": bind source path resolves outside directories shared with the Morbstack VM: /etc/hosts -> /opt/secret/hosts (add the resolved root to shared_paths, then restart Morbstack)"))
    }

    func testExplicitBindAliasIsRewrittenInBothEngineAPILocations() throws {
        let result = prepare(
            #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/etc/hosts","Target":"/host"}]},"Mounts":[{"Type":"bind","Source":"/var/db/config","Target":"/config"}]}"#,
            shares: [privateEtcShare, privateVarShare],
            sourcePathResolving: { source in
                source == "/etc/hosts" ? "/private/etc/hosts" : "/private/var/db/config"
            })
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected both explicit aliases to be admitted")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let hostMounts = try XCTUnwrap(hostConfig["Mounts"] as? [[String: Any]])
        let topMounts = try XCTUnwrap(object["Mounts"] as? [[String: Any]])
        XCTAssertEqual(hostMounts.first?["Source"] as? String, "/private/etc/hosts")
        XCTAssertEqual(topMounts.first?["Source"] as? String, "/private/var/db/config")
    }

    func testHostDaemonSocketLegacyBindIsRewrittenToTheGuestSocket() throws {
        let result = prepare(
            #"{"HostConfig":{"Binds":["/Users/allie/.morbstack/run/docker.sock:/var/run/docker.sock:ro"]}}"#,
            hostDockerSocketPath: "/Users/allie/.morbstack/run/docker.sock")
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected the daemon's own socket bind to be admitted")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(
            hostConfig["Binds"] as? [String],
            ["/var/run/docker.sock:/var/run/docker.sock:ro"])
    }

    func testHostDaemonSocketDiscoveryLinkMountIsRewrittenThroughSymlinkResolution() throws {
        // `~/.docker/run/docker.sock` is the per-user discovery link `morb
        // install-cli` creates; a Testcontainers client mounts that spelling, and
        // only symlink resolution proves it is this daemon's socket.
        let result = prepare(
            #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/Users/allie/.docker/run/docker.sock","Target":"/var/run/docker.sock"}]}}"#,
            hostDockerSocketPath: "/Users/allie/.morbstack/run/docker.sock",
            sourcePathResolving: { source in
                source == "/Users/allie/.docker/run/docker.sock"
                    ? "/Users/allie/.morbstack/run/docker.sock" : source
            })
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected the discovery-link socket mount to be admitted")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let mounts = try XCTUnwrap(hostConfig["Mounts"] as? [[String: Any]])
        XCTAssertEqual(mounts.first?["Source"] as? String, "/var/run/docker.sock")
    }

    func testHostDaemonSocketUnderTmpComparesThroughTheMacPrivateAlias() throws {
        // A dedicated engine home under `/tmp` publishes its socket through macOS's
        // `/private` alias; both spellings are one identity.
        let result = prepare(
            #"{"HostConfig":{"Binds":["/private/tmp/mb-eco/run/docker.sock:/var/run/docker.sock"]}}"#,
            shares: [tmpShare],
            hostDockerSocketPath: "/tmp/mb-eco/run/docker.sock")
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected the /private/tmp-spelled daemon socket to be admitted")
        }
        XCTAssertTrue(wasRewritten)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(
            hostConfig["Binds"] as? [String],
            ["/var/run/docker.sock:/var/run/docker.sock"])
    }

    func testAForeignEngineSocketIsNeverRedirectedToTheGuestSocket() throws {
        // A live Docker Desktop socket at the conventional per-user path resolves to
        // itself, not to this daemon; it must keep ordinary share semantics rather
        // than silently becoming Morbstack's own API.
        let result = prepare(
            #"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/Users/allie/.docker/run/docker.sock","Target":"/var/run/docker.sock"}]}}"#,
            hostDockerSocketPath: "/Users/allie/.morbstack/run/docker.sock")
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("expected a shared foreign socket path to pass through untouched")
        }
        XCTAssertFalse(wasRewritten)
        XCTAssertEqual(
            body, Data(#"{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/Users/allie/.docker/run/docker.sock","Target":"/var/run/docker.sock"}]}}"#.utf8))
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

    func testGuestDockerSocketIsNeverRewrittenAsAMacVarAlias() {
        let original = #"{"HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock:ro"]}}"#
        let result = prepare(
            original,
            shares: [],
            states: [:],
            sourceExists: { _ in false })
        guard case .allowed(let body, let wasRewritten) = result else {
            return XCTFail("the guest Docker socket is an intentional exception")
        }
        XCTAssertFalse(wasRewritten)
        XCTAssertEqual(body, Data(original.utf8))
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
                message: "invalid mount config for type \"bind\": bind source path resolves outside directories shared with the Morbstack VM: /var/run/docker.sock/child -> /private/var/run/docker.sock/child (add the resolved root to shared_paths, then restart Morbstack)"))
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
