// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the arithmetic and the mappings: stats maths, compose grouping,
// port URLs, disk-usage folding, and the launch switches the screenshot tour depends on.

import Foundation
import XCTest

@testable import MorbstackAppCore

// MARK: - Stats

final class StatsMathTests: XCTestCase {

    private func stats(
        total: Double, previousTotal: Double,
        system: Double, previousSystem: Double,
        cpus: Int? = 4,
        percpu: [Double]? = nil,
        memory: Int64 = 0, limit: Int64 = 0, extras: [String: Double]? = nil
    ) -> Wire.Stats {
        Wire.Stats(
            read: nil,
            cpu_stats: Wire.CPUStats(
                cpu_usage: Wire.CPUUsage(total_usage: total, percpu_usage: percpu),
                system_cpu_usage: system,
                online_cpus: cpus),
            precpu_stats: Wire.CPUStats(
                cpu_usage: Wire.CPUUsage(total_usage: previousTotal, percpu_usage: nil),
                system_cpu_usage: previousSystem,
                online_cpus: cpus),
            memory_stats: Wire.MemoryStats(usage: memory, limit: limit, stats: extras))
    }

    /// The formula the Docker CLI uses: `(cpu_delta / system_delta) * online_cpus * 100`.
    /// A container using one whole core out of four reads as 100%, not 25%.
    func testComputesCPUPercentTheSameWayTheCLIDoes() {
        let sample = StatsMath.cpuPercent(
            stats(total: 2_000_000, previousTotal: 1_000_000,
                  system: 40_000_000, previousSystem: 36_000_000))

        // (1e6 / 4e6) * 4 * 100 = 100
        XCTAssertEqual(sample, 100, accuracy: 0.001)
    }

    func testHalfACoreOfFour() {
        let sample = StatsMath.cpuPercent(
            stats(total: 1_500_000, previousTotal: 1_000_000,
                  system: 40_000_000, previousSystem: 36_000_000))

        // (0.5e6 / 4e6) * 4 * 100 = 50
        XCTAssertEqual(sample, 50, accuracy: 0.001)
    }

    /// The first sample of a stream has an empty `precpu_stats`, so the system delta is
    /// zero. Dividing by it would yield `inf`, which renders as "inf%" and poisons any
    /// chart it is fed to.
    func testGuardsAgainstAZeroSystemDelta() {
        XCTAssertEqual(
            StatsMath.cpuPercent(
                stats(total: 2_000_000, previousTotal: 1_000_000,
                      system: 40_000_000, previousSystem: 40_000_000)),
            0)
    }

    func testGuardsAgainstAZeroCPUDelta() {
        XCTAssertEqual(
            StatsMath.cpuPercent(
                stats(total: 1_000_000, previousTotal: 1_000_000,
                      system: 40_000_000, previousSystem: 36_000_000)),
            0)
    }

    /// A container restart makes the cumulative counter go backwards.
    func testGuardsAgainstACounterReset() {
        XCTAssertEqual(
            StatsMath.cpuPercent(
                stats(total: 500_000, previousTotal: 1_000_000,
                      system: 40_000_000, previousSystem: 36_000_000)),
            0)
    }

    func testReturnsZeroWhenTheStatsAreEmpty() {
        XCTAssertEqual(StatsMath.cpuPercent(Wire.Stats()), 0)
    }

    /// Older engines omit `online_cpus`; the per-CPU array length is the fallback.
    func testFallsBackToThePerCPUArrayLength() {
        let sample = StatsMath.cpuPercent(
            stats(total: 2_000_000, previousTotal: 1_000_000,
                  system: 40_000_000, previousSystem: 36_000_000,
                  cpus: nil,
                  percpu: [0, 0, 0, 0, 0, 0, 0, 0]))

        // (1e6 / 4e6) * 8 * 100 = 200
        XCTAssertEqual(sample, 200, accuracy: 0.001)
    }

    /// Raw `usage` includes page cache, which makes an idle container that once read a
    /// big file look like it is holding hundreds of megabytes.
    func testSubtractsPageCacheFromMemory() {
        let sample = stats(
            total: 0, previousTotal: 0, system: 0, previousSystem: 0,
            memory: 500_000_000, limit: 2_000_000_000,
            extras: ["inactive_file": 200_000_000])

        XCTAssertEqual(StatsMath.memoryBytes(sample), 300_000_000)
    }

    /// cgroup v1 calls it `cache` rather than `inactive_file`.
    func testSubtractsCgroupV1Cache() {
        let sample = stats(
            total: 0, previousTotal: 0, system: 0, previousSystem: 0,
            memory: 500_000_000, limit: 2_000_000_000,
            extras: ["cache": 100_000_000])

        XCTAssertEqual(StatsMath.memoryBytes(sample), 400_000_000)
    }

    func testMemoryNeverGoesNegative() {
        let sample = stats(
            total: 0, previousTotal: 0, system: 0, previousSystem: 0,
            memory: 100, limit: 1000, extras: ["inactive_file": 5000])

        XCTAssertEqual(StatsMath.memoryBytes(sample), 0)
    }

    func testMemoryFractionIsClamped() {
        XCTAssertEqual(
            StatsSample(cpuPercent: 0, memBytes: 500, memLimit: 1000, ts: .now).memFraction,
            0.5, accuracy: 0.0001)
        // A limit of zero means "unlimited"; dividing by it must not produce a NaN.
        XCTAssertEqual(
            StatsSample(cpuPercent: 0, memBytes: 500, memLimit: 0, ts: .now).memFraction, 0)
    }
}

// MARK: - Stats stream framing

/// The first document of a `stats?stream=1` response is a baseline, not a reading.
///
/// The payloads below are the shape a real dockerd sends, trimmed to the keys the app
/// reads: document 0 with `precpu_stats` zero-filled, document 1 with the previous
/// document's numbers moved into `precpu_stats`. The zero-filled baseline is the whole
/// bug — it does not produce an obviously broken value like `inf`, it produces the
/// container's lifetime average CPU wearing a one-second reading's clothes.
final class StatsStreamDecoderTests: XCTestCase {

    /// Document 0: `precpu_stats` present but empty, exactly as the engine sends it.
    /// 12 s of CPU burned over a host that has accumulated 4 000 s across 4 cores.
    private static let priming = """
        {"read":"2026-08-02T09:00:00.100000000Z",
         "cpu_stats":{"cpu_usage":{"total_usage":12000000000},
                      "system_cpu_usage":4000000000000,"online_cpus":4},
         "precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":0,"online_cpus":0},
         "memory_stats":{"usage":52428800,"limit":2147483648,"stats":{"inactive_file":2428800}}}
        """

    /// Document 1, one second later: 0.25 s of container CPU against 4 s of system time
    /// across 4 cores — (0.25 / 4) * 4 * 100 = 25%.
    private static let second = """
        {"read":"2026-08-02T09:00:01.100000000Z",
         "cpu_stats":{"cpu_usage":{"total_usage":12250000000},
                      "system_cpu_usage":4004000000000,"online_cpus":4},
         "precpu_stats":{"cpu_usage":{"total_usage":12000000000},
                         "system_cpu_usage":4000000000000,"online_cpus":4},
         "memory_stats":{"usage":53477376,"limit":2147483648,"stats":{"inactive_file":2428800}}}
        """

    private func decode(_ json: String) throws -> Wire.Stats {
        try JSONDecoder().decode(Wire.Stats.self, from: Data(json.utf8))
    }

    /// The regression: sample 0 must not reach the caller at all.
    func testDropsThePrimingDocument() throws {
        var decoder = StatsStreamDecoder()
        XCTAssertNil(decoder.admit(try decode(Self.priming)))
        XCTAssertEqual(decoder.seen, 1)
    }

    /// And the document after it must be a true interval reading.
    func testEmitsTheFirstRealIntervalWithCLIMaths() throws {
        var decoder = StatsStreamDecoder()
        _ = decoder.admit(try decode(Self.priming))

        let sample = try XCTUnwrap(decoder.admit(try decode(Self.second)))
        XCTAssertEqual(sample.cpuPercent, 25, accuracy: 0.001)
        // usage minus inactive_file, not raw usage.
        XCTAssertEqual(sample.memBytes, 53_477_376 - 2_428_800)
        XCTAssertEqual(sample.memLimit, 2_147_483_648)
        XCTAssertEqual(
            sample.ts.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-02T09:00:01Z")!.timeIntervalSince1970 + 0.1,
            accuracy: 0.01)
    }

    /// What the dropped document would have claimed, had it been yielded: 1.2%, which
    /// is not the interval reading (25%) by any stretch — it is 12 s over the host's
    /// entire 4 000 s of accumulated CPU time. Plausible-looking and completely wrong,
    /// which is why the fix is to drop the document rather than to clamp the number.
    func testThePrimingDocumentWouldHaveReportedALifetimeAverage() throws {
        let lifetimeAverage = StatsMath.cpuPercent(try decode(Self.priming))
        XCTAssertEqual(lifetimeAverage, 1.2, accuracy: 0.001)
        XCTAssertTrue(StatsMath.isPriming(try decode(Self.priming)))
        XCTAssertFalse(StatsMath.isPriming(try decode(Self.second)))
    }

    /// An engine that sends two baselines — a container still starting up — must not
    /// slip one through on the strength of its index alone.
    func testDropsALaterDocumentThatStillHasNoBaseline() throws {
        var decoder = StatsStreamDecoder()
        XCTAssertNil(decoder.admit(try decode(Self.priming)))
        XCTAssertNil(decoder.admit(try decode(Self.priming)))
        XCTAssertNotNil(decoder.admit(try decode(Self.second)))
        XCTAssertEqual(decoder.seen, 3)
    }

    /// `precpu_stats` missing entirely, which is what older engines send.
    func testTreatsAnAbsentPrecpuAsPriming() {
        XCTAssertTrue(StatsMath.isPriming(Wire.Stats()))
    }
}

// MARK: - Ports

final class PortMappingTests: XCTestCase {

    func testBrowserAddressUsesOnlyTheReportedIPv4LoopbackTCPBinding() {
        let port = PortMapping(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: "TCP")
        XCTAssertEqual(port.browserAddress?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertNil(port.browserAddressUnavailableReason)
    }

    func testBrowserAddressUsesURLComponentsForIPv6Loopback() {
        let port = PortMapping(hostIP: "::1", hostPort: 8080, containerPort: 80, proto: "tcp")
        XCTAssertEqual(port.browserAddress?.absoluteString, "http://[::1]:8080")
        XCTAssertNil(port.browserAddressUnavailableReason)
    }

    func testBrowserAddressRejectsMappingsWithoutATrustworthyLoopbackDestination() {
        let wildcard = PortMapping(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")
        XCTAssertNil(wildcard.browserAddress)
        XCTAssertEqual(
            wildcard.browserAddressUnavailableReason,
            "Browser actions require a literal loopback binding; Docker reported 0.0.0.0.")

        let lan = PortMapping(hostIP: "192.168.1.40", hostPort: 8080, containerPort: 80, proto: "tcp")
        XCTAssertNil(lan.browserAddress)

        let udp = PortMapping(hostIP: "127.0.0.1", hostPort: 53, containerPort: 53, proto: "udp")
        XCTAssertNil(udp.browserAddress)
        XCTAssertEqual(udp.browserAddressUnavailableReason, "Browser actions require a TCP mapping.")

        let unpublished = PortMapping(hostIP: nil, hostPort: nil, containerPort: 80, proto: "tcp")
        XCTAssertNil(unpublished.browserAddress)
        XCTAssertEqual(unpublished.browserAddressUnavailableReason, "No host port was reported.")

        let invalid = PortMapping(hostIP: "127.0.0.1", hostPort: 0, containerPort: 80, proto: "tcp")
        XCTAssertNil(invalid.browserAddress)
        XCTAssertEqual(invalid.browserAddressUnavailableReason, "Docker reported an invalid host port.")
    }

    func testPublishedTCPPortGetsALoopbackURL() {
        let port = PortMapping(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")
        XCTAssertEqual(port.url?.absoluteString, "http://127.0.0.1:8080")
    }

    /// A binding reported on `0.0.0.0` — or on the host's LAN address — is reachable at
    /// loopback, and loopback is the address the user actually wants clicked.
    func testAlwaysUsesLoopbackRatherThanTheReportedHostIP() {
        let port = PortMapping(hostIP: "192.168.1.40", hostPort: 3000, containerPort: 3000, proto: "tcp")
        XCTAssertEqual(port.url?.absoluteString, "http://127.0.0.1:3000")
    }

    /// An exposed-but-unpublished port has nothing on the host to open.
    func testUnpublishedPortHasNoURL() {
        let port = PortMapping(hostIP: nil, hostPort: nil, containerPort: 5432, proto: "tcp")
        XCTAssertNil(port.url)
    }

    /// UDP has no browser story.
    func testUDPPortHasNoURL() {
        let port = PortMapping(hostIP: "0.0.0.0", hostPort: 53, containerPort: 53, proto: "udp")
        XCTAssertNil(port.url)
    }

    func testProtocolMatchIsCaseInsensitive() {
        let port = PortMapping(hostIP: nil, hostPort: 8080, containerPort: 80, proto: "TCP")
        XCTAssertEqual(port.url?.absoluteString, "http://127.0.0.1:8080")
    }

    func testLabels() {
        XCTAssertEqual(
            PortMapping(hostIP: nil, hostPort: 8080, containerPort: 80, proto: "tcp").label,
            "8080 → 80/tcp")
        XCTAssertEqual(
            PortMapping(hostIP: nil, hostPort: nil, containerPort: 80, proto: "tcp").label,
            "80/tcp")
    }

    /// Ports are identifiers, not quantities. The Overview inspector receives these
    /// String values directly, avoiding `LocalizedStringKey`'s grouped Int rendering.
    func testPortDisplaysNeverGroupDigits() {
        let port = PortMapping(
            hostIP: "0.0.0.0",
            hostPort: 18_099,
            containerPort: 18_080,
            proto: "tcp")

        XCTAssertEqual(port.hostDisplay, "0.0.0.0:18099")
        XCTAssertEqual(port.containerDisplay, "18080/TCP")
        XCTAssertEqual(port.label, "18099 → 18080/tcp")
        XCTAssertFalse(port.hostDisplay?.contains(",") == true)
        XCTAssertFalse(port.containerDisplay.contains(","))
    }

    /// Docker reports one entry per binding, so a container published on both IPv4 and
    /// IPv6 arrives with every port twice.
    func testDeduplicatesDoubleBoundPortsOnTheWayIn() {
        let wire = Wire.Container(
            Id: "abc",
            Names: ["/web"],
            Image: "nginx",
            State: "running",
            Status: "Up 2 minutes",
            Created: 1_700_000_000,
            Ports: [
                Wire.Port(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, proto: "tcp"),
                Wire.Port(IP: "::", PrivatePort: 80, PublicPort: 8080, proto: "tcp"),
            ],
            Labels: nil)

        XCTAssertEqual(ContainerSummary(wire).ports.count, 1)
    }
}

// MARK: - Container mapping

final class ContainerSummaryTests: XCTestCase {

    private func wire(
        id: String = "0123456789abcdef", names: [String]? = ["/web"],
        state: String = "running", status: String = "Up 2 minutes",
        labels: [String: String]? = nil
    ) -> Wire.Container {
        Wire.Container(
            Id: id, Names: names, Image: "nginx:latest", State: state, Status: status,
            Created: 1_700_000_000, Ports: nil, Labels: labels)
    }

    func testStripsTheLeadingSlashFromNames() {
        XCTAssertEqual(ContainerSummary(wire()).displayName, "web")
    }

    func testFallsBackToAShortIDWhenUnnamed() {
        XCTAssertEqual(ContainerSummary(wire(names: [])).displayName, "0123456789ab")
    }

    func testReadsComposeAttributionFromLabels() {
        let summary = ContainerSummary(
            wire(labels: [
                "com.docker.compose.project": "shop",
                "com.docker.compose.service": "api",
            ]))

        XCTAssertEqual(summary.composeProject, "shop")
        XCTAssertEqual(summary.composeService, "api")
    }

    func testAContainerWithoutComposeLabelsHasNoProject() {
        XCTAssertNil(ContainerSummary(wire()).composeProject)
    }

    /// Health lives in the status prose rather than in a field on the list endpoint.
    func testDetectsUnhealthyFromTheStatusProse() {
        XCTAssertTrue(ContainerSummary(wire(status: "Up 5 minutes (unhealthy)")).isUnhealthy)
        XCTAssertFalse(ContainerSummary(wire(status: "Up 5 minutes (healthy)")).isUnhealthy)
        XCTAssertFalse(ContainerSummary(wire(status: "Up 5 minutes")).isUnhealthy)
    }

    func testRunningStatusTicksFromAnExactDockerStartTime() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var summary = ContainerSummary(wire(status: "Up 5 minutes (healthy)"))
        summary.startedAt = startedAt

        let first = summary.statusDisplay(at: startedAt.addingTimeInterval(10))
        let later = summary.statusDisplay(at: startedAt.addingTimeInterval(70))

        XCTAssertTrue(first.hasPrefix("Up "))
        XCTAssertTrue(later.hasPrefix("Up "))
        XCTAssertTrue(first.hasSuffix(" (healthy)"))
        XCTAssertTrue(later.hasSuffix(" (healthy)"))
        XCTAssertNotEqual(first, later, "local ticking must not need another Docker refresh")
    }

    func testStatusFallsBackToDockerProseWithoutAnExactStartTime() {
        let summary = ContainerSummary(wire(status: "Up About a minute"))
        XCTAssertEqual(summary.statusDisplay(at: .distantFuture), "Up About a minute")
    }

    func testAvailableActionsDependOnState() {
        XCTAssertEqual(ContainerSummary(wire(state: "running")).availableActions, [.stop, .restart, .pause])
        XCTAssertEqual(ContainerSummary(wire(state: "paused")).availableActions, [.unpause, .stop])
        XCTAssertEqual(ContainerSummary(wire(state: "exited")).availableActions, [.start, .remove])
    }

    /// Docker documents a `dead` container as defunct: it can be removed but not
    /// started.  Keeping that distinction in the shared action contract also keeps a
    /// Compose project's recovery action from targeting an unrecoverable member.
    func testDeadContainerIsOnlyRemovable() {
        XCTAssertEqual(ContainerSummary(wire(state: "dead")).availableActions, [.remove])
    }
}

// MARK: - Network mapping

/// The attachment count, which the list endpoint refuses to tell you.
///
/// `GET /networks` returns `"Containers": null` for every network — the summary shape
/// deliberately omits the endpoint map, because building it for every network on a
/// swarm manager is expensive. Only `GET /networks/{id}` carries it. Believing the list
/// endpoint means every user network on the machine reports zero attachments, and the
/// Networks screen classifies `containers == 0` as *unused* — so it invites the user to
/// prune the network their database is currently talking over.
final class NetworkSummaryDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> Wire.Network {
        try JSONDecoder().decode(Wire.Network.self, from: Data(json.utf8))
    }

    /// The exact bytes `GET /networks` sends for a network that has containers on it.
    func testTheListEndpointReportsNullAttachments() throws {
        let wire = try decode("""
            {"Name":"shop_default","Id":"a1b2c3d4e5f6","Driver":"bridge",
             "Scope":"local","Containers":null}
            """)

        XCTAssertNil(wire.Containers)
        XCTAssertEqual(NetworkSummary(wire).containers, 0)
    }

    /// The same network as `GET /networks/{id}` sends it. The endpoint values are large
    /// and entirely unread, so they decode away to nothing — but they must still *count*.
    func testTheDetailEndpointCarriesTheAttachmentMap() throws {
        let wire = try decode("""
            {"Name":"shop_default","Id":"a1b2c3d4e5f6","Driver":"bridge","Scope":"local",
             "Containers":{
               "1111111111111111":{"Name":"shop-web-1","EndpointID":"aaaa","MacAddress":"02:42:ac:11:00:02",
                                   "IPv4Address":"172.18.0.2/16","IPv6Address":""},
               "2222222222222222":{"Name":"shop-db-1","EndpointID":"bbbb","MacAddress":"02:42:ac:11:00:03",
                                   "IPv4Address":"172.18.0.3/16","IPv6Address":""}}}
            """)

        XCTAssertEqual(wire.Containers?.count, 2)
        XCTAssertEqual(NetworkSummary(wire).containers, 2)
    }

    /// An empty map is a real answer — the network exists and nothing is on it — and has
    /// to stay distinguishable from the list endpoint's `null`, which means "not told".
    func testAnEmptyAttachmentMapIsNotTheSameAsNull() throws {
        let empty = try decode("""
            {"Name":"scratch","Id":"ffff","Driver":"bridge","Scope":"local","Containers":{}}
            """)

        XCTAssertNotNil(empty.Containers)
        XCTAssertEqual(empty.Containers?.count, 0)
        XCTAssertEqual(NetworkSummary(empty).containers, 0)
    }

    /// Driver and scope are optional on the wire; the built-in `none` network omits
    /// neither in practice, but a user-supplied plugin network can.
    func testFallsBackWhenDriverAndScopeAreAbsent() throws {
        let wire = try decode(#"{"Name":"weird","Id":"0001"}"#)
        let summary = NetworkSummary(wire)

        XCTAssertEqual(summary.driver, "bridge")
        XCTAssertEqual(summary.scope, "local")
        XCTAssertEqual(summary.containers, 0)
    }

    func testBuiltInsAreRecognisedByName() {
        for name in ["bridge", "host", "none"] {
            XCTAssertTrue(
                NetworkSummary(id: name, name: name, driver: "null", scope: "local", containers: 0)
                    .isBuiltIn)
        }
        XCTAssertFalse(
            NetworkSummary(id: "x", name: "shop_default", driver: "bridge", scope: "local", containers: 0)
                .isBuiltIn)
    }
}

// MARK: - Compose grouping

final class ComposeGroupingTests: XCTestCase {

    private func container(
        _ name: String, project: String? = nil, service: String? = nil, running: Bool = true
    ) -> ContainerSummary {
        ContainerSummary(
            id: name, names: [name], displayName: name, image: "img",
            state: running ? "running" : "exited", status: "",
            composeProject: project, composeService: service,
            ports: [], createdAt: .now)
    }

    func testGroupsByProject() {
        let groups = [
            container("a", project: "shop", service: "api"),
            container("b", project: "shop", service: "db"),
            container("c", project: "blog", service: "web"),
        ].groupedByComposeProject()

        XCTAssertEqual(groups.map(\.project), ["blog", "shop"])
        XCTAssertEqual(groups.last?.containers.count, 2)
    }

    /// The standalone bucket goes last rather than being interleaved, so its position
    /// stays stable as projects come and go.
    func testStandaloneContainersComeLast() {
        let groups = [
            container("loose"),
            container("a", project: "zeta", service: "one"),
            container("b", project: "alpha", service: "one"),
        ].groupedByComposeProject()

        XCTAssertEqual(groups.map(\.title), ["alpha", "zeta", "Standalone"])
        XCTAssertNil(groups.last?.project)
    }

    /// Within a group, order by service name — otherwise a stack reshuffles every time
    /// one member restarts.
    func testSortsWithinAGroupByServiceName() {
        let groups = [
            container("x", project: "p", service: "worker"),
            container("y", project: "p", service: "api"),
            container("z", project: "p", service: "db"),
        ].groupedByComposeProject()

        XCTAssertEqual(groups.first?.containers.map(\.composeService), ["api", "db", "worker"])
    }

    func testAProjectIsUpOnlyWhenEveryMemberIs() {
        let partial = [
            container("a", project: "p", service: "one", running: true),
            container("b", project: "p", service: "two", running: false),
        ].groupedByComposeProject()[0]

        XCTAssertFalse(partial.isFullyRunning)
        XCTAssertEqual(partial.runningCount, 1)

        let whole = [
            container("a", project: "p", service: "one", running: true),
            container("b", project: "p", service: "two", running: true),
        ].groupedByComposeProject()[0]

        XCTAssertTrue(whole.isFullyRunning)
    }

    func testAnEmptyListProducesNoGroups() {
        XCTAssertTrue([ContainerSummary]().groupedByComposeProject().isEmpty)
    }
}

// MARK: - Events

final class DockerEventTests: XCTestCase {

    func testDecodesTheModernShape() {
        let event = DockerEvent(
            Wire.Event(
                eventType: "container", Action: "die",
                Actor: Wire.EventActor(ID: "abc", Attributes: ["exitCode": "137"]),
                time: 1_700_000_000, timeNano: nil))

        XCTAssertEqual(event?.type, "container")
        XCTAssertEqual(event?.action, "die")
        XCTAssertEqual(event?.actorID, "abc")
        XCTAssertEqual(event?.attributes["exitCode"], "137")
    }

    /// Some proxies still emit the pre-1.22 shape, where the action is `status` and the
    /// actor id is a bare `id`.
    func testDecodesTheLegacyShape() {
        let event = DockerEvent(
            Wire.Event(eventType: nil, Action: nil, Actor: nil, time: 1_700_000_000, status: "start", id: "xyz"))

        XCTAssertEqual(event?.action, "start")
        XCTAssertEqual(event?.actorID, "xyz")
        XCTAssertEqual(event?.type, "container")
    }

    func testAnEventWithNoActionIsDiscarded() {
        XCTAssertNil(DockerEvent(Wire.Event()))
    }

    func testRecognisesLifecycleActions() {
        func isLifecycle(_ action: String, type: String = "container") -> Bool {
            DockerEvent(type: type, action: action, actorID: "a", attributes: [:], time: .now)
                .isContainerLifecycle
        }

        XCTAssertTrue(isLifecycle("start"))
        XCTAssertTrue(isLifecycle("die"))
        XCTAssertTrue(isLifecycle("health_status: unhealthy"))
        XCTAssertFalse(isLifecycle("exec_create: ls"))
        XCTAssertFalse(isLifecycle("start", type: "image"))
    }
}

// MARK: - Disk usage

final class DiskUsageTests: XCTestCase {

    func testFoldsASystemDFDocument() {
        // One in-use image (1 GB, 400 MB of it shared base layers) and one unused
        // image (500 MB, sharing the same 400 MB base). LayersSize is the on-disk
        // truth: 1 GB + the unused image's unique 100 MB.
        let usage = DockerClient.diskUsage(from: [
            "LayersSize": 1_100_000_000,
            "Images": [
                ["Id": "sha256:inuse", "Size": 1_000_000_000, "SharedSize": 400_000_000, "Containers": 2],
                ["Id": "sha256:unused", "Size": 500_000_000, "SharedSize": 400_000_000, "Containers": 0],
            ],
            "Volumes": [
                ["UsageData": ["Size": 300_000_000, "RefCount": 1]],
                ["UsageData": ["Size": 200_000_000, "RefCount": 0]],  // unused
            ],
            "BuildCache": [
                ["Size": 100_000_000, "InUse": true, "Shared": false],
                ["Size": 50_000_000, "InUse": false, "Shared": false],
            ],
            "Containers": [
                ["SizeRw": 10_000_000, "State": "running"],
                ["SizeRw": 20_000_000, "State": "exited"],
            ],
        ])

        // `LayersSize` is the honest image total: per-image `Size` double-counts every
        // shared base layer.
        XCTAssertEqual(usage.layersSize, 1_100_000_000)
        XCTAssertEqual(usage.imagesTotal, 1_100_000_000)
        XCTAssertEqual(usage.volumesTotal, 500_000_000)
        XCTAssertEqual(usage.buildCacheTotal, 150_000_000)
        XCTAssertEqual(usage.containersTotal, 30_000_000)
        // Docker's own formula: LayersSize (1.1 GB) minus in-use unique bytes
        // (1 GB − 400 MB shared = 600 MB) → 500 MB, not the unused image's 500 MB
        // `Size` (which would double-count the shared 400 MB whenever more images
        // overlapped).
        XCTAssertEqual(usage.imagesReclaimable, 500_000_000)
        // 500M images + 200M unused volume + 50M idle cache + 20M exited container
        XCTAssertEqual(usage.reclaimable, 770_000_000)
    }

    /// `/images/json` reports `Containers` as `-1` on every engine this app has been
    /// tested against, so the Images screen's "In use" column has to come from the
    /// same `/system/df` scan the reclaimable-bytes math above already reads
    /// `Containers` from. Keyed by image ID like `volumeUsage` is keyed by volume name.
    func testCollectsPerImageContainerCountsForTheImagesScreen() {
        let usage = DockerClient.diskUsage(from: [
            "Images": [
                ["Id": "sha256:inuse", "Size": 100, "Containers": 2],
                ["Id": "sha256:unused", "Size": 50, "Containers": 0],
            ]
        ])

        XCTAssertEqual(usage.imageUsage, ["sha256:inuse": 2, "sha256:unused": 0])
    }

    /// A `Containers` value below zero is Docker declining to answer, not a real
    /// count. It must not enter `imageUsage`, or a not-yet-merged image would look
    /// like a scanned, confidently-negative fact.
    func testOmitsImagesWhereDockerDidNotReportAContainerCount() {
        let usage = DockerClient.diskUsage(from: [
            "Images": [["Id": "sha256:unreported", "Size": 100, "Containers": -1]]
        ])

        XCTAssertTrue(usage.imageUsage.isEmpty)
    }

    /// A shared build-cache record is reported once per parent; counting it each time
    /// inflates the total by however many images share it.
    func testSkipsSharedBuildCacheRecords() {
        let usage = DockerClient.diskUsage(from: [
            "BuildCache": [
                ["Size": 100_000_000, "InUse": false, "Shared": true],
                ["Size": 100_000_000, "InUse": false, "Shared": true],
                ["Size": 25_000_000, "InUse": false, "Shared": false],
            ]
        ])

        XCTAssertEqual(usage.buildCacheTotal, 25_000_000)
        XCTAssertEqual(usage.reclaimable, 25_000_000)
    }

    /// An engine that reports no `LayersSize` still needs an image number.
    func testFallsBackToSummingImageSizes() {
        let usage = DockerClient.diskUsage(from: [
            "Images": [["Size": 700, "Containers": 1], ["Size": 300, "Containers": 1]]
        ])

        XCTAssertEqual(usage.imagesTotal, 1000)
    }

    func testAnEmptyDocumentIsAllZeroes() {
        XCTAssertEqual(DockerClient.diskUsage(from: [:]), DiskUsage.zero)
    }
}

// MARK: - Image references

final class ImageReferenceTests: XCTestCase {

    func testSplitsATaggedReference() {
        let split = DockerClient.splitImageReference("nginx:1.25")
        XCTAssertEqual(split.image, "nginx")
        XCTAssertEqual(split.tag, "1.25")
    }

    func testDefaultsToLatest() {
        XCTAssertEqual(DockerClient.splitImageReference("nginx").tag, "latest")
    }

    /// A registry host's port has a colon in it, and it is not a tag separator.
    func testDoesNotMistakeARegistryPortForATag() {
        let split = DockerClient.splitImageReference("registry.local:5000/team/app")
        XCTAssertEqual(split.image, "registry.local:5000/team/app")
        XCTAssertEqual(split.tag, "latest")
    }

    func testHandlesAPortAndATag() {
        let split = DockerClient.splitImageReference("registry.local:5000/team/app:v2")
        XCTAssertEqual(split.image, "registry.local:5000/team/app")
        XCTAssertEqual(split.tag, "v2")
    }

    func testKeepsADigestInTheTagSlot() {
        let split = DockerClient.splitImageReference("nginx@sha256:abc123")
        XCTAssertEqual(split.image, "nginx")
        XCTAssertEqual(split.tag, "sha256:abc123")
    }

    func testTagPathUsesImmutableSourceIDAndEscapesTheTargetFields() throws {
        let request = try XCTUnwrap(
            ImageTagRequest(
                sourceImageID: "sha256:deadbeef",
                repository: "registry.local:5000/team/api",
                tag: "build+42"))

        XCTAssertEqual(
            DockerClient.imageTagPath(request),
            "/images/sha256:deadbeef/tag?repo=registry.local%3A5000%2Fteam%2Fapi&tag=build%2B42")
    }

    func testRemovalPathUsesTheSelectedImmutableIDWithoutForce() {
        XCTAssertEqual(
            DockerClient.imageRemovalPath(id: "sha256:deadbeef"),
            "/images/sha256:deadbeef")
    }

    func testRepositoryAndTagOnTheSummary() {
        let tagged = ImageSummary(
            id: "sha256:deadbeefcafe0000", repoTags: ["nginx:1.25"], size: 1, createdAt: .now,
            containersUsing: 0)
        XCTAssertEqual(tagged.repository, "nginx")
        XCTAssertEqual(tagged.tag, "1.25")
        XCTAssertEqual(tagged.shortID, "deadbeefcafe")
        XCTAssertFalse(tagged.isDangling)

        let dangling = ImageSummary(
            id: "sha256:abc", repoTags: ["<none>:<none>"], size: 1, createdAt: .now,
            containersUsing: 0)
        XCTAssertTrue(dangling.isDangling)
        XCTAssertEqual(dangling.repository, "<none>")
    }
}

// MARK: - Local image run request

final class LocalImageRunRequestTests: XCTestCase {

    func testMakesOnlyLiteralEnvironmentAndFixedPublishedPortDeclarations() throws {
        let result = LocalImageRunRequest.make(
            requestedName: " web ",
            environment: [
                LocalImageEnvironmentEntry(name: "LOG_LEVEL", value: "debug"),
                LocalImageEnvironmentEntry(name: "EMPTY_VALUE", value: ""),
            ],
            publishedPorts: [
                LocalImagePortMappingEntry(
                    hostPort: "8080",
                    containerPort: "80",
                    transport: .tcp,
                    exposure: .thisMac),
                LocalImagePortMappingEntry(
                    hostPort: "5353",
                    containerPort: "53",
                    transport: .udp,
                    exposure: .allInterfaces),
            ])

        guard case .success(let request) = result else {
            return XCTFail("Expected a checked local-image request")
        }
        XCTAssertEqual(request.requestedName, "web")
        XCTAssertEqual(
            request.environment,
            [
                LocalImageEnvironmentDeclaration(name: "LOG_LEVEL", value: "debug"),
                LocalImageEnvironmentDeclaration(name: "EMPTY_VALUE", value: ""),
            ])
        XCTAssertEqual(
            request.publishedPorts,
            [
                LocalImagePublishedPort(
                    hostPort: 8080, containerPort: 80, transport: .tcp, exposure: .thisMac),
                LocalImagePublishedPort(
                    hostPort: 5353, containerPort: 53, transport: .udp, exposure: .allInterfaces),
            ])
    }

    func testRejectsIncompleteEnvironmentAndNonfixedPortRowsRatherThanDroppingThem() {
        XCTAssertEqual(
            LocalImageRunRequest.make(
                requestedName: "",
                environment: [LocalImageEnvironmentEntry(value: "present")],
                publishedPorts: []),
            .failure(.environmentNameRequired(entry: 1)))
        XCTAssertEqual(
            LocalImageRunRequest.make(
                requestedName: "",
                environment: [LocalImageEnvironmentEntry(name: "A=B", value: "present")],
                publishedPorts: []),
            .failure(.environmentNameContainsEquals(entry: 1)))
        XCTAssertEqual(
            LocalImageRunRequest.make(
                requestedName: "",
                environment: [],
                publishedPorts: [LocalImagePortMappingEntry(hostPort: "0", containerPort: "80")]),
            .failure(.invalidHostPort(entry: 1)),
            "This form deliberately has no dynamic or publish-all port behavior.")
        XCTAssertEqual(
            LocalImageRunRequest.make(
                requestedName: "",
                environment: [],
                publishedPorts: [LocalImagePortMappingEntry(hostPort: "8080", containerPort: "")]),
            .failure(.portMappingIncomplete(entry: 1)))
    }

    func testEncodesTheExactV143EnvironmentAndPortCreateShape() throws {
        let request = try LocalImageRunRequest.make(
            requestedName: "web",
            environment: [LocalImageEnvironmentEntry(name: "LOG_LEVEL", value: "debug")],
            publishedPorts: [
                LocalImagePortMappingEntry(
                    hostPort: "8080", containerPort: "80", transport: .tcp, exposure: .thisMac),
                LocalImagePortMappingEntry(
                    hostPort: "5353", containerPort: "53", transport: .udp, exposure: .allInterfaces),
            ]).get()
        let data = try DockerClient.localImageCreateBody(imageID: "sha256:immutable", request: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["Image"] as? String, "sha256:immutable")
        XCTAssertEqual(object["Env"] as? [String], ["LOG_LEVEL=debug"])
        let exposedPorts = try XCTUnwrap(object["ExposedPorts"] as? [String: Any])
        XCTAssertEqual(Set(exposedPorts.keys), Set(["80/tcp", "53/udp"]))
        XCTAssertEqual((exposedPorts["80/tcp"] as? [String: Any])?.count, 0)
        XCTAssertEqual((exposedPorts["53/udp"] as? [String: Any])?.count, 0)

        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(Set(hostConfig.keys), Set(["PortBindings"]))
        let bindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        let tcpBinding = try XCTUnwrap((bindings["80/tcp"] as? [[String: String]])?.first)
        XCTAssertEqual(tcpBinding, ["HostIp": "127.0.0.1", "HostPort": "8080"])
        let udpBinding = try XCTUnwrap((bindings["53/udp"] as? [[String: String]])?.first)
        XCTAssertEqual(udpBinding, ["HostIp": "0.0.0.0", "HostPort": "5353"])

        XCTAssertNil(object["Binds"])
        XCTAssertNil(object["NetworkingConfig"])
        XCTAssertNil(object["Privileged"])
    }

    func testOmitsEnvironmentAndHostConfigWhenTheFormHasNoDeclarations() throws {
        let request = try LocalImageRunRequest.make(
            requestedName: "", environment: [], publishedPorts: []).get()
        let data = try DockerClient.localImageCreateBody(imageID: "sha256:immutable", request: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object.keys.sorted(), ["Image"])
    }
}

// MARK: - Launch options

final class LaunchOptionsTests: XCTestCase {

    func testParsesEveryTourSwitch() {
        let options = LaunchOptions(arguments: [
            "/path/to/app",
            "--tour-select", "images",
            "--tour-container", "web",
            "--appearance", "dark",
            "--window-size", "1280x800",
        ])

        XCTAssertEqual(options.select, .images)
        XCTAssertEqual(options.container, "web")
        XCTAssertEqual(options.appearance, .dark)
        XCTAssertEqual(options.windowSize, CGSize(width: 1280, height: 800))
        XCTAssertTrue(options.isTour)
    }

    func testAnOrdinaryLaunchHasNoOptions() {
        let options = LaunchOptions(arguments: ["/path/to/app"])
        XCTAssertNil(options.select)
        XCTAssertNil(options.appearance)
        XCTAssertFalse(options.isTour)
        XCTAssertNil(options.fixtureProvenance)
    }

    // AppModel and its factory are @MainActor-isolated; the test hops onto the main
    // actor to construct them, matching the pattern used in TrackDSettingsTests.
    @MainActor
    func testFixtureLaunchCarriesNonLiveProvenance() {
        let options = LaunchOptions(arguments: ["/path/to/app", "--tour-fixtures"])
        let provenance = options.fixtureProvenance

        XCTAssertEqual(provenance?.windowTitle, "Morbstack — Fixture Data")
        XCTAssertEqual(provenance?.footerTitle, "Fixture Data")
        XCTAssertEqual(provenance?.detail, "Developer fixtures — not connected to a Docker Engine.")
        XCTAssertEqual(provenance?.accessibilityLabel, "Fixture data. Not connected to a Docker Engine.")
        XCTAssertFalse(provenance?.detail.localizedCaseInsensitiveContains("running") ?? true)
        XCTAssertFalse(provenance?.accessibilityLabel.localizedCaseInsensitiveContains("running") ?? true)
        XCTAssertFalse(AppModel.forLaunch(options).permitsExternalOperations)
        XCTAssertTrue(AppModel(launchOptions: .none).permitsExternalOperations)
    }

    /// macOS appends its own arguments when launching from Xcode; an app that refused
    /// to start over one of those would be maddening.
    func testIgnoresUnknownArguments() {
        let options = LaunchOptions(arguments: [
            "/path/to/app", "-NSDocumentRevisionsDebugMode", "YES", "--tour-select", "volumes",
        ])
        XCTAssertEqual(options.select, .volumes)
    }

    func testRejectsAnUnknownNavName() {
        XCTAssertNil(LaunchOptions(arguments: ["/app", "--tour-select", "nonsense"]).select)
    }

    func testToleratesAMissingValueAtTheEnd() {
        // Must not trap on the read past the end of the vector.
        XCTAssertNil(LaunchOptions(arguments: ["/app", "--tour-select"]).select)
    }

    func testSizeParsing() {
        XCTAssertEqual(LaunchOptions.parseSize("1440x900"), CGSize(width: 1440, height: 900))
        XCTAssertEqual(LaunchOptions.parseSize("1440×900"), CGSize(width: 1440, height: 900))
        XCTAssertNil(LaunchOptions.parseSize("1440"))
        XCTAssertNil(LaunchOptions.parseSize("wide x tall"))
        // Absurdly small sizes are rejected rather than producing an unusable window.
        XCTAssertNil(LaunchOptions.parseSize("10x10"))
    }

    func testAppearanceIsCaseInsensitiveAndValidated() {
        XCTAssertEqual(LaunchOptions(arguments: ["/app", "--appearance", "LIGHT"]).appearance, .light)
        XCTAssertNil(LaunchOptions(arguments: ["/app", "--appearance", "sepia"]).appearance)
    }
}

// MARK: - Navigation

final class NavTests: XCTestCase {

    /// `rawValue` is the `--tour-select` argument, so it is part of the screenshot
    /// tooling's contract and must not be renamed casually.
    func testRawValuesAreStable() {
        XCTAssertEqual(
            Nav.allCases.map(\.rawValue),
            [
                "containers", "stacks", "images", "volumes", "networks", "builds", "kubernetes",
                "disk", "migration",
            ])
    }

    /// ⌘1…⌘9, in sidebar order, with no gaps and no duplicates.
    func testShortcutIndicesAreOneThroughNine() {
        XCTAssertEqual(Nav.allCases.map(\.shortcutIndex), Array(1...Nav.allCases.count))
        XCTAssertEqual(Nav.allCases.count, 9)
    }

    func testEverySectionHasATitleAndASymbol() {
        for nav in Nav.allCases {
            XCTAssertFalse(nav.title.isEmpty)
            XCTAssertFalse(nav.symbol.isEmpty)
        }
    }
}

// MARK: - Engine status

final class EngineStatusTests: XCTestCase {

    func testRunningRequiresBothReachabilityAndState() {
        XCTAssertTrue(
            EngineStatus(state: "running", vmState: "running", version: nil, reachable: true).isRunning)
        // A cached state from before the daemon went away must not read as running.
        XCTAssertFalse(
            EngineStatus(state: "running", vmState: "running", version: nil, reachable: false).isRunning)
        XCTAssertFalse(EngineStatus.unknown.isRunning)
    }

    func testTransitionalStates() {
        for state in ["starting", "stopping", "pausing"] {
            XCTAssertTrue(
                EngineStatus(state: state, vmState: state, version: nil, reachable: true).isTransitional,
                "\(state) should be transitional")
        }
        XCTAssertFalse(
            EngineStatus(state: "running", vmState: "running", version: nil, reachable: true).isTransitional)
        // Unreachable is not "transitional" — nothing is going to change on its own.
        XCTAssertFalse(EngineStatus.unknown.isTransitional)
    }

    func testHeadlines() {
        XCTAssertEqual(EngineStatus.unknown.headline, "Engine stopped")
        XCTAssertEqual(
            EngineStatus(state: "running", vmState: "", version: nil, reachable: true).headline,
            "Engine running")
        XCTAssertEqual(
            EngineStatus(state: "suspended", vmState: "", version: nil, reachable: true).headline,
            "Suspended")
    }
}

// MARK: - Operational state

final class OperationalStateTests: XCTestCase {

    func testContainerStates() {
        XCTAssertEqual(OperationalState.container(state: "running"), .running)
        XCTAssertEqual(OperationalState.container(state: "running", unhealthy: true), .failed)
        XCTAssertEqual(OperationalState.container(state: "restarting"), .changing)
        XCTAssertEqual(OperationalState.container(state: "paused"), .paused)
        XCTAssertEqual(OperationalState.container(state: "dead"), .failed)
        XCTAssertEqual(OperationalState.container(state: "exited"), .stopped)
    }

    func testEngineStates() {
        XCTAssertEqual(OperationalState.engine(.unknown), .stopped)
        XCTAssertEqual(
            OperationalState.engine(EngineStatus(state: "running", vmState: "", version: nil, reachable: true)),
            .running)
        XCTAssertEqual(
            OperationalState.engine(EngineStatus(state: "error", vmState: "", version: nil, reachable: true)),
            .failed)
    }

    /// State remains distinguishable outside a particular visual treatment, including
    /// in menus, VoiceOver labels, and a greyscale screenshot.
    func testEveryOperationalStateHasADistinctSymbolAndLabel() {
        let states: [OperationalState] = [.running, .stopped, .changing, .paused, .failed]
        XCTAssertEqual(Set(states.map(\.symbol)).count, states.count)
        XCTAssertEqual(Set(states.map(\.label)).count, states.count)
    }
}

// MARK: - Formatters

final class FormattersTests: XCTestCase {

    /// A reclaimable total can go slightly negative between two samples, and
    /// "-3 KB of disk" is never a useful thing to show somebody.
    func testNegativeByteCountsRenderAsZero() {
        XCTAssertEqual(Formatters.bytesString(-5000), Formatters.bytesString(0))
    }

    func testPercentIsClampedAndFinite() {
        XCTAssertEqual(Formatters.percent(12.44), "12.4%")
        XCTAssertEqual(Formatters.percent(-3), "0.0%")
        XCTAssertEqual(Formatters.percent(.infinity), "—")
        XCTAssertEqual(Formatters.percent(.nan), "—")
    }

    /// A zero `Date` means the engine did not report a creation time; "56 years ago"
    /// would be worse than admitting we do not know.
    func testUnknownDates() {
        XCTAssertEqual(Formatters.relativeDate(Date(timeIntervalSince1970: 0)), "unknown")
        XCTAssertEqual(Formatters.compactDuration(since: Date(timeIntervalSince1970: 0)), "—")
    }

    func testCompactDurationPicksTheShortestHonestUnit() {
        XCTAssertEqual(Formatters.compactDuration(since: Date().addingTimeInterval(-30)), "30s")
        XCTAssertEqual(Formatters.compactDuration(since: Date().addingTimeInterval(-300)), "5m")
        XCTAssertEqual(Formatters.compactDuration(since: Date().addingTimeInterval(-7200)), "2h")
        XCTAssertEqual(Formatters.compactDuration(since: Date().addingTimeInterval(-172_800)), "2d")
    }
}
