// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackKit

/// Tests for the host half of Kubernetes support.
///
/// Every test here runs against fixture text or a temporary directory. **Nothing in
/// this file reads or writes the real `~/.kube/config`** — that is the whole point of
/// `K8s.mergeKubeconfig` being a pure function over strings, and a test that reached
/// for the developer's own kubeconfig would be exactly the accident the design
/// exists to prevent.
final class K8sTests: XCTestCase {

    // MARK: - Fixtures

    /// What k3s actually writes to `/etc/rancher/k3s/k3s.yaml`, trimmed of the
    /// multi-kilobyte base64 blobs but structurally identical.
    private let guestKubeconfig = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: LS0tLS1CRUdJTkNFUlQtLS0t
            server: https://127.0.0.1:6443
          name: default
        contexts:
        - context:
            cluster: default
            user: default
          name: default
        current-context: default
        kind: Config
        preferences: {}
        users:
        - name: default
          user:
            client-certificate-data: LS0tLS1CRUdJTkNMSUVOVC0tLS0t
            client-key-data: LS0tLS1CRUdJTktFWS0tLS0t
        """

    /// A user's existing kubeconfig with two real-looking clusters in it. The whole
    /// merge contract is "these survive, byte for byte".
    private let userKubeconfig = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: UFJPRENB
            server: https://prod.example.com
          name: production
        - cluster:
            server: https://staging.internal:6443
          name: staging
        contexts:
        - context:
            cluster: production
            namespace: payments
            user: prod-admin
          name: production
        - context:
            cluster: staging
            user: staging-dev
          name: staging
        current-context: production
        kind: Config
        preferences: {}
        users:
        - name: prod-admin
          user:
            token: PRODTOKEN
        - name: staging-dev
          user:
            token: STAGINGTOKEN
        """

    // MARK: - Kubeconfig rewriting

    func testRewriteChangesOnlyThePortAndKeepsTheLoopbackHost() {
        // The load-bearing detail: k3s's serving certificate carries 127.0.0.1 as a
        // SAN, so keeping the host and moving only the port is what lets TLS verify
        // from the Mac with no insecure-skip-tls-verify anywhere.
        let rewritten = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 16443)
        XCTAssertTrue(
            rewritten.contains("server: https://127.0.0.1:16443"),
            "expected the port to be rewritten, got:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("https://127.0.0.1:6443"))
        XCTAssertFalse(
            rewritten.contains("localhost"),
            "the host must stay as the literal 127.0.0.1 the certificate covers")
    }

    func testRewriteRenamesEveryDefaultEntryToMorbstack() {
        // k3s names its cluster, context and user all `default`, which collides with
        // every other k3s config a user has. A merge needs a distinctive name.
        let rewritten = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        XCTAssertFalse(
            rewritten.contains("default"),
            "no `default` should survive the rewrite, got:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("name: morbstack"))
        XCTAssertTrue(rewritten.contains("cluster: morbstack"))
        XCTAssertTrue(rewritten.contains("user: morbstack"))
        XCTAssertTrue(rewritten.contains("current-context: morbstack"))
    }

    func testRewriteRenamesANameCarriedOnTheListDashLine() {
        // Regression. k3s writes its users list as `- name: default`, with the key on
        // the same line as the YAML list marker, while clusters and contexts get
        // `name:` on a line of its own. A rewrite that only handled the second form
        // renamed the cluster and the context but left the *user* called `default`.
        // Nothing looked wrong: the file parsed, and `morb k8s kubeconfig` printed
        // happily. The damage showed up one step later — the merge looks entries up
        // by name, found no `morbstack` user, and produced a merged config whose
        // `morbstack` context referenced a user that was not in the file, so every
        // kubectl call failed with "no such user" against an apparently valid config.
        let rewritten = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        XCTAssertTrue(
            rewritten.contains("- name: morbstack"),
            "the users-list entry must be renamed too, got:\n\(rewritten)")
        // Every `default` in a k3s kubeconfig, and there are six of them: the
        // cluster's name, the context's cluster and user references, the context's
        // own name, `current-context`, and the user's name on the dash line.
        XCTAssertEqual(
            rewritten.components(separatedBy: "morbstack").count - 1, 6,
            "cluster name, context cluster, context user, context name, "
                + "current-context, user name")
    }

    func testRewriteDoesNotRenameEntriesThatMerelyStartWithDefault() {
        // Exact-match only. A user really can have a cluster called
        // `default-staging`, and a tool that renames it because they toggled a local
        // Kubernetes switch has corrupted their config.
        let source = """
            clusters:
            - cluster:
                server: https://elsewhere.example.com
              name: default-staging
            """
        let rewritten = K8s.rewriteKubeconfig(source, hostPort: 6443)
        XCTAssertTrue(rewritten.contains("name: default-staging"))
        XCTAssertFalse(rewritten.contains("morbstack"))
    }

    func testRewritePreservesCredentialsAndIndentation() {
        // A rewrite that mangled the base64 or the nesting would produce a file that
        // looks right and fails at TLS handshake time.
        let rewritten = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        XCTAssertTrue(rewritten.contains("certificate-authority-data: LS0tLS1CRUdJTkNFUlQtLS0t"))
        XCTAssertTrue(rewritten.contains("client-key-data: LS0tLS1CRUdJTktFWS0tLS0t"))
        XCTAssertTrue(
            rewritten.contains("    server: https://127.0.0.1:6443"),
            "the four-space indent under `cluster:` must be preserved")
    }

    func testRewriteIsIdempotent() {
        // `morb k8s kubeconfig` is run repeatedly; running it on its own output must
        // not accumulate changes.
        let once = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 16443)
        let twice = K8s.rewriteKubeconfig(once, hostPort: 16443)
        XCTAssertEqual(once, twice)
    }

    func testRewriteLeavesUnrelatedLinesUntouched() {
        let source = """
        apiVersion: v1
        # a comment nobody should lose
        kind: Config
        preferences: {}
        """
        let rewritten = K8s.rewriteKubeconfig(source, hostPort: 1234)
        XCTAssertEqual(rewritten, source)
    }

    // MARK: - Merging

    func testMergeIntoAnEmptyConfigJustUsesOurs() {
        let ours = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        let (text, replaced) = K8s.mergeKubeconfig(
            existing: "", morbstackConfig: ours, switchContext: false)
        XCTAssertEqual(text, ours)
        XCTAssertFalse(replaced)
    }

    func testMergePreservesEveryExistingClusterContextAndUser() {
        // The single most important test in this file. A user with production
        // credentials in ~/.kube/config must find all of them intact afterwards.
        let ours = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 16443)
        let (merged, replaced) = K8s.mergeKubeconfig(
            existing: userKubeconfig, morbstackConfig: ours, switchContext: false)

        XCTAssertFalse(replaced, "nothing named morbstack was there before")
        for survivor in [
            "name: production", "name: staging", "name: prod-admin", "name: staging-dev",
            "server: https://prod.example.com", "server: https://staging.internal:6443",
            "token: PRODTOKEN", "token: STAGINGTOKEN", "namespace: payments",
        ] {
            XCTAssertTrue(merged.contains(survivor), "merge dropped `\(survivor)`:\n\(merged)")
        }
        XCTAssertTrue(merged.contains("server: https://127.0.0.1:16443"), "ours was not added")
        XCTAssertTrue(merged.contains("name: morbstack"))
    }

    func testMergeDoesNotChangeCurrentContextUnlessAsked() {
        // Enabling a local cluster must never silently retarget a kubectl that was
        // pointed at production.
        let ours = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        let (merged, _) = K8s.mergeKubeconfig(
            existing: userKubeconfig, morbstackConfig: ours, switchContext: false)
        XCTAssertTrue(
            merged.contains("current-context: production"),
            "current-context must be left alone:\n\(merged)")
    }

    func testMergeSwitchesCurrentContextWhenAsked() {
        let ours = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        let (merged, _) = K8s.mergeKubeconfig(
            existing: userKubeconfig, morbstackConfig: ours, switchContext: true)
        XCTAssertTrue(merged.contains("current-context: morbstack"))
        XCTAssertFalse(merged.contains("current-context: production"))
    }

    func testMergeIsIdempotentAndReplacesRatherThanDuplicates() {
        // Running `--merge` twice is normal (a new cluster gets a new certificate),
        // and must replace the previous morbstack entry instead of appending a
        // second one that kubectl would reject as a duplicate name.
        let first = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 16443)
        let (once, replacedFirst) = K8s.mergeKubeconfig(
            existing: userKubeconfig, morbstackConfig: first, switchContext: false)
        XCTAssertFalse(replacedFirst)

        let second = K8s.rewriteKubeconfig(
            guestKubeconfig.replacingOccurrences(
                of: "LS0tLS1CRUdJTkNFUlQtLS0t", with: "TkVXQ0VSVElGSUNBVEU="),
            hostPort: 16443)
        let (twice, replacedSecond) = K8s.mergeKubeconfig(
            existing: once, morbstackConfig: second, switchContext: false)

        XCTAssertTrue(replacedSecond, "the second merge should report replacing our entry")
        XCTAssertEqual(
            twice.components(separatedBy: "name: morbstack").count - 1, 3,
            "exactly one morbstack entry per section (cluster, context, user):\n\(twice)")
        XCTAssertTrue(twice.contains("TkVXQ0VSVElGSUNBVEU="), "the new certificate should win")
        XCTAssertFalse(
            twice.contains("LS0tLS1CRUdJTkNFUlQtLS0t"), "the stale certificate should be gone")
        // And the user's clusters are still there after two merges.
        XCTAssertTrue(twice.contains("name: production"))
        XCTAssertTrue(twice.contains("token: PRODTOKEN"))
    }

    func testMergeAddsMissingSectionsToASparseConfig() {
        // A config with no `users:` section at all is legal; the merge must create
        // the section rather than silently dropping our user.
        let sparse = """
            apiVersion: v1
            kind: Config
            clusters:
            - cluster:
                server: https://only.example.com
              name: only
            """
        let ours = K8s.rewriteKubeconfig(guestKubeconfig, hostPort: 6443)
        let (merged, _) = K8s.mergeKubeconfig(
            existing: sparse, morbstackConfig: ours, switchContext: false)
        XCTAssertTrue(merged.contains("users:"), "a users section should have been created")
        XCTAssertTrue(merged.contains("contexts:"), "a contexts section should have been created")
        XCTAssertTrue(merged.contains("name: only"), "the existing cluster must survive")
        XCTAssertTrue(merged.contains("client-key-data: LS0tLS1CRUdJTktFWS0tLS0t"))
    }

    // MARK: - Writing, with a backup

    func testWritingAMergedConfigBacksUpTheOriginalFirst() throws {
        // Against a temporary directory, never the real ~/.kube.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-k8s-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("config")
        try Data(userKubeconfig.utf8).write(to: target)

        let outcome = try K8s.writeMergedKubeconfig(
            "merged contents", to: target, replacedExisting: false, switchedContext: true)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "merged contents")
        let backupPath = try XCTUnwrap(outcome.backupPath, "a backup must always be taken")
        XCTAssertEqual(
            try String(contentsOfFile: backupPath, encoding: .utf8), userKubeconfig,
            "the backup must hold the original bytes")
        XCTAssertTrue(outcome.switchedContext)
    }

    func testWritingTwiceInOneSecondKeepsBothRecoveryBackups() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-k8s-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("config")
        try Data("original contents".utf8).write(to: target)
        let timestamp = Date(timeIntervalSince1970: 1_722_679_200)

        let first = try K8s.writeMergedKubeconfig(
            "first merge", to: target, replacedExisting: false, switchedContext: false, now: timestamp)
        let second = try K8s.writeMergedKubeconfig(
            "second merge", to: target, replacedExisting: true, switchedContext: false, now: timestamp)

        let firstBackup = try XCTUnwrap(first.backupPath)
        let secondBackup = try XCTUnwrap(second.backupPath)
        XCTAssertNotEqual(firstBackup, secondBackup, "a backup collision must not replace recovery data")
        XCTAssertEqual(try String(contentsOfFile: firstBackup, encoding: .utf8), "original contents")
        XCTAssertEqual(try String(contentsOfFile: secondBackup, encoding: .utf8), "first merge")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "second merge")
    }

    func testWritingWhereNoConfigExistsTakesNoBackupAndStillSucceeds() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-k8s-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("config")
        let outcome = try K8s.writeMergedKubeconfig(
            "fresh", to: target, replacedExisting: false, switchedContext: false)

        XCTAssertNil(outcome.backupPath)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "fresh")
    }

    func testAWrittenKubeconfigIsNotReadableByOtherUsers() throws {
        // It holds a client certificate and key for a cluster-admin account.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("morbstack-k8s-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("config")
        _ = try K8s.writeMergedKubeconfig(
            "secret", to: target, replacedExisting: false, switchedContext: false)

        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.int16Value, 0o600)
    }

    // MARK: - Status decoding

    func testStatusDecodesAFullGuestReply() throws {
        let json = """
            {"type":"k8s_status","installed":true,"enabled":true,"persistent":true,
             "phase":"ready","nodes":1,"nodes_ready":1,"pods":7,"pods_ready":6,
             "apiserver_port":6443,"message":"node morbstack is Ready"}
            """
        let status = try JSONDecoder().decode(K8s.Status.self, from: Data(json.utf8))
        XCTAssertEqual(status.phase, .ready)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.persistent)
        XCTAssertEqual(status.nodes, 1)
        XCTAssertEqual(status.podsReady, 6)
        XCTAssertEqual(status.message, "node morbstack is Ready")
    }

    func testStatusTreatsMissingFieldsAsZeroRatherThanFailingToDecode() throws {
        // A guest older than this host must still produce a renderable status; the
        // alternative is `morb k8s status` reporting nothing at all.
        let status = try JSONDecoder().decode(
            K8s.Status.self, from: Data(#"{"type":"k8s_status"}"#.utf8))
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertFalse(status.installed)
        XCTAssertEqual(status.nodes, 0)
        XCTAssertEqual(status.apiserverPort, K8s.guestAPIServerPort)
    }

    func testAnUnknownPhaseFromANewerGuestDegradesToStarting() throws {
        // Never a decode failure: an unrecognised phase is still a running cluster,
        // and "starting" is the honest, cautious rendering of "we do not know yet".
        let status = try JSONDecoder().decode(
            K8s.Status.self, from: Data(#"{"phase":"reconciling"}"#.utf8))
        XCTAssertEqual(status.phase, .starting)
    }

    func testEveryPhaseHasAHumanSummary() {
        for phase in [K8s.Phase.notInstalled, .stopped, .starting, .ready] {
            XCTAssertFalse(phase.summary.isEmpty)
        }
        XCTAssertEqual(K8s.Phase.notInstalled.rawValue, "not-installed")
    }

    func testStatusIPCFieldsCarryEverythingTheCLIRenders() {
        let status = K8s.Status(
            installed: true, enabled: true, persistent: false, phase: .starting, nodes: 1,
            nodesReady: 0, pods: 5, podsReady: 2, message: "waiting for the node")
        let fields = status.ipcFields
        XCTAssertEqual(fields["phase"], .string("starting"))
        XCTAssertEqual(fields["nodes_ready"], .int(0))
        XCTAssertEqual(fields["persistent"], .bool(false))
        XCTAssertEqual(fields["message"], .string("waiting for the node"))
    }

    // MARK: - Diagnosis (UX-20: an honest `kubectl top` story once ready)

    func testReadyDiagnosisNamesTheMetricsServerTradeAndOffersDockerStats() {
        // metrics-server is deliberately disabled for boot speed
        // (guest/morbinit/src/k8s.rs); left unstated, `kubectl top` fails with a
        // raw "Metrics API not available" that reads like a broken cluster. The
        // ready-with-nothing-to-do guidance is the one place a user reliably sees
        // after enabling Kubernetes, so it is where this gets said honestly.
        let status = K8s.Status(
            installed: true, enabled: true, persistent: true, phase: .ready,
            nodes: 1, nodesReady: 1, pods: 3, podsReady: 3)
        let diagnosis = K8s.Diagnosis(
            status: status, hostAPIServerPort: 51234, kubeconfigExists: true)
        XCTAssertEqual(diagnosis.recommendedAction, .none)
        XCTAssertTrue(
            diagnosis.guidance.contains("metrics-server"),
            "must name the trade, not just say nothing is wrong: \(diagnosis.guidance)")
        XCTAssertTrue(
            diagnosis.guidance.contains("kubectl top"),
            "must name the command that will otherwise fail with no explanation: \(diagnosis.guidance)")
        XCTAssertTrue(
            diagnosis.guidance.contains("docker stats"),
            "must offer the resource data that already exists instead: \(diagnosis.guidance)")
        // The reversal command must be syntactically real, not a placeholder.
        XCTAssertTrue(diagnosis.guidance.contains("kubectl apply -f"))
    }

    func testOnlyTheFullyReadyNoActionGuidanceMentionsMetrics() {
        // Every other phase is guidance toward making the cluster reachable at
        // all; naming a `kubectl top` trade before there is a kubeconfig or an
        // API forward to run it against would be noise, not help.
        let notReady = K8s.Diagnosis(
            status: K8s.Status(installed: false, enabled: false, phase: .notInstalled),
            hostAPIServerPort: nil, kubeconfigExists: false)
        XCTAssertFalse(notReady.guidance.contains("metrics-server"))

        let readyNoKubeconfig = K8s.Diagnosis(
            status: K8s.Status(installed: true, enabled: true, phase: .ready, nodes: 1, nodesReady: 1),
            hostAPIServerPort: nil, kubeconfigExists: false)
        XCTAssertFalse(readyNoKubeconfig.guidance.contains("metrics-server"))
    }

    // MARK: - Payload pins

    func testPayloadDigestsMatchTheFetchScript() throws {
        // The host tells the guest which digest to expect, so this constant and the
        // one the fetch script downloads against must never drift. If they do, an
        // enable either re-streams 122 MB every time (harmless but slow) or asks the
        // guest to prove a hash nothing will ever have (a hard failure).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // K8sTests.swift -> MorbstackKitTests/
            .deletingLastPathComponent()  // MorbstackKitTests -> Tests/
            .deletingLastPathComponent()  // Tests -> mac/
            .deletingLastPathComponent()  // mac -> repo root
        let script = repoRoot.appendingPathComponent("scripts/fetch-guest-assets.sh")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else {
            throw XCTSkip("fetch-guest-assets.sh not found; not a source checkout")
        }
        for file in K8s.payloadFiles {
            XCTAssertTrue(
                text.contains(file.sha256),
                "\(file.name) digest \(file.sha256) is not pinned in fetch-guest-assets.sh")
        }
    }

    func testPayloadNamesAreExactlyWhatTheGuestAllows() {
        // Mirrors `k8s::PAYLOAD_NAMES` in the guest, which refuses anything else.
        XCTAssertEqual(K8s.payloadFiles.map(\.name), ["k3s", "cri-dockerd"])
    }
}
