// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

/// Coverage for turning Docker Engine API documents into Mac-side listeners.
final class PortForwardingTests: XCTestCase {

    /// A realistic two-container `GET /containers/json` body.
    ///
    /// `web` publishes 8080->80 on both address families the way dockerd really does;
    /// `sleeper` publishes nothing and merely exposes 9000.
    private let containersJSON = Data(
        """
        [
          {
            "Id": "aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddddddddddd",
            "Names": ["/web"],
            "Image": "nginx",
            "Ports": [
              {"IP": "0.0.0.0", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"},
              {"IP": "::", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"}
            ]
          },
          {
            "Id": "1111111111112222222222223333333333334444444444",
            "Names": ["/sleeper"],
            "Image": "alpine",
            "Ports": [
              {"PrivatePort": 9000, "Type": "tcp"}
            ]
          }
        ]
        """.utf8)

    // MARK: - containers/json -> port set

    func testExtractsPublishedPortsAndIgnoresMerelyExposedOnes() throws {
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: containersJSON)
        XCTAssertEqual(bindings.count, 2, "both address-family entries for 8080 are reported")
        XCTAssertTrue(bindings.allSatisfy { $0.hostPort == 8080 && $0.containerPort == 80 })
        XCTAssertEqual(bindings.first?.containerName, "web", "the leading slash is stripped")
        // 9000 has no PublicPort, so it is EXPOSEd rather than published.
        XCTAssertFalse(bindings.contains { $0.containerPort == 9000 })
    }

    /// Native IPv4 and IPv6 sockets retain their independent Docker endpoints even
    /// when dockerd reports the same numeric port for both families.
    func testDuplicateAddressFamiliesRetainTwoNativeListeners() throws {
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: containersJSON)
        let desired = PortForwardPlan.desiredListeners(bindings, exposure: .localNetwork)
        XCTAssertEqual(desired.count, 2)
        XCTAssertEqual(desired[endpoint("0.0.0.0", 8080)]?.hostIP, "0.0.0.0")
        XCTAssertEqual(desired[endpoint("::", 8080)]?.hostIP, "::")
    }

    func testNumericHostAddressesHonorTheExposurePolicy() {
        func binding(ip: String, proto: String = "tcp") -> DockerPortBinding {
            DockerPortBinding(
                hostIP: ip, hostPort: 8080, containerPort: 80, networkProtocol: proto,
                containerID: "abc", containerName: "web")
        }
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "0.0.0.0"), exposure: .localNetwork))
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "127.0.0.1"), exposure: .loopbackOnly))
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: ""), exposure: .localNetwork))
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "192.168.65.3"), exposure: .localNetwork))
        XCTAssertFalse(PortForwardPlan.isForwardable(binding(ip: "192.168.65.3"), exposure: .loopbackOnly))
        XCTAssertTrue(PortForwardPlan.isForwardable(binding(ip: "::", proto: "udp"), exposure: .localNetwork))
        XCTAssertFalse(PortForwardPlan.isForwardable(binding(ip: "not-an-ip"), exposure: .localNetwork))
    }

    func testUDPPortsGetTheirOwnConcreteListenerPlan() throws {
        let json = Data(
            """
            [{"Id":"d","Names":["/dns"],"Ports":[
              {"IP":"0.0.0.0","PrivatePort":53,"PublicPort":5353,"Type":"udp"}]}]
            """.utf8)
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: json)
        XCTAssertTrue(PortForwardPlan.desiredListeners(bindings, exposure: .localNetwork).isEmpty)
        XCTAssertEqual(
            Array(PortForwardPlan.desiredUDPListeners(bindings, exposure: .localNetwork).keys),
            [endpoint("0.0.0.0", 5353)])
    }

    func testRejectsANonArrayContainersDocument() {
        XCTAssertThrowsError(
            try DockerAPIDecoding.publishedPorts(containersJSON: Data(#"{"message":"nope"}"#.utf8)))
    }

    func testAnEmptyContainerListYieldsNoForwards() throws {
        let bindings = try DockerAPIDecoding.publishedPorts(containersJSON: Data("[]".utf8))
        XCTAssertTrue(PortForwardPlan.desiredListeners(bindings, exposure: .localNetwork).isEmpty)
    }

    func testHostNetworkDiscoveryRequiresDockerEffectiveExposedPorts() throws {
        let containerID = String(repeating: "a", count: 64)
        let containers = Data(
            """
            [
              {"Id":"\(containerID)","Names":["/hosted"],"State":"running"},
              {"Id":"stopped","Names":["/stopped"],"State":"exited"}
            ]
            """.utf8)
        XCTAssertEqual(
            try DockerAPIDecoding.runningContainers(containersJSON: containers),
            [DockerRunningContainer(id: containerID, name: "hosted")])

        let inspect = Data(
            """
            {
              "Id":"\(containerID)",
              "State":{"Running":true},
              "Config":{"ExposedPorts":{"80/tcp":{},"5353/udp":{},"5000/sctp":{},"0/tcp":{}}},
              "HostConfig":{"NetworkMode":"host","PublishAllPorts":false,"PortBindings":{}}
            }
            """.utf8)
        XCTAssertEqual(
            DockerAPIDecoding.hostNetworkExposedPorts(
                inspectJSON: inspect,
                expectedContainerID: containerID,
                containerName: "hosted"),
            [
                DockerHostNetworkExposedPort(
                    transport: .tcp, port: 80, containerID: containerID, containerName: "hosted"),
                DockerHostNetworkExposedPort(
                    transport: .udp, port: 5353, containerID: containerID, containerName: "hosted")
            ])
    }

    func testHostNetworkDiscoveryNeverDuplicatesExplicitPublishing() {
        let containerID = String(repeating: "b", count: 64)
        let inspect = Data(
            """
            {
              "Id":"\(containerID)",
              "State":{"Running":true},
              "Config":{"ExposedPorts":{"80/tcp":{}}},
              "HostConfig":{"NetworkMode":"host","PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}
            }
            """.utf8)
        XCTAssertTrue(
            DockerAPIDecoding.hostNetworkExposedPorts(
                inspectJSON: inspect,
                expectedContainerID: containerID,
                containerName: "hosted").isEmpty)
    }

    func testGuestListenerProbeHasOneClosedRequestGrammar() {
        XCTAssertEqual(
            GuestListenerProbe.preamble(transport: .tcp, guestPort: 8080),
            Data("LISTEN tcp 8080\n".utf8))
        XCTAssertEqual(
            GuestListenerProbe.preamble(transport: .udp, guestPort: 53),
            Data("LISTEN udp 53\n".utf8))
    }

    // MARK: - Fixed TCP create leases

    func testExplicitTCPCreateBindingsCollapseAddressFamiliesForOneMacLease() {
        let create = Data(
            """
            {"HostConfig":{"PortBindings":{
              "80/tcp":[
                {"HostIp":"0.0.0.0","HostPort":"8080"},
                {"HostIp":"::","HostPort":"8080"}
              ]
            }}}
            """.utf8)

        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: create), .allowed)
        XCTAssertEqual(
            DockerPortPublicationPreflight.explicitTCPBindings(in: create),
            [DockerExplicitTCPPortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80)])
    }

    func testExplicitTCPCreateBindingsDoNotGuessDynamicTargets() {
        let dynamic = Data(#"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":""}]}}}"#.utf8)

        XCTAssertTrue(DockerPortPublicationPreflight.explicitTCPBindings(in: dynamic).isEmpty)
    }

    func testPreflightRejectsOneHostEndpointWithMultipleContainerTargets() {
        let ambiguous = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}],"81/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}}}"#.utf8)

        guard case .rejected(let message) =
            DockerPortPublicationPreflight.inspectContainerCreate(body: ambiguous)
        else {
            return XCTFail("one host listener cannot safely represent two TCP targets")
        }
        XCTAssertTrue(message.contains("more than one container port"), message)
        XCTAssertTrue(DockerPortPublicationPreflight.explicitTCPBindings(in: ambiguous).isEmpty)
    }

    func testFixedLoopbackUDPCreateIsAdmittedButHasNoTCPLease() {
        let create = Data(
            #"{"HostConfig":{"PortBindings":{"53/udp":[{"HostIp":"127.0.0.1","HostPort":"5353"}]}}}"#.utf8)

        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: create), .allowed)
        XCTAssertTrue(
            DockerPortPublicationPreflight.explicitTCPBindings(in: create).isEmpty,
            "UDP is event-confirmed; it must not accidentally enter the fixed TCP lease ledger")
    }

    func testUnsupportedProtocolsAndInvalidHostRangesAreRejected() {
        let unsupported = Data(
            #"{"HostConfig":{"PortBindings":{"80/sctp":[{"HostPort":"8080"}]}}}"#.utf8)
        let invalidRange = Data(
            #"{"HostConfig":{"PortBindings":{"53/udp":[{"HostPort":"5355-5353"}]}}}"#.utf8)

        guard case .rejected(let unsupportedMessage) =
            DockerPortPublicationPreflight.inspectContainerCreate(body: unsupported)
        else {
            return XCTFail("SCTP must not look like a supported forward")
        }
        XCTAssertTrue(unsupportedMessage.contains("SCTP"))
        guard case .rejected(let rangeMessage) =
            DockerPortPublicationPreflight.inspectContainerCreate(body: invalidRange)
        else {
            return XCTFail("a descending host-port range is not a Docker allocation range")
        }
        XCTAssertTrue(rangeMessage.contains("valid port or port range"))
    }

    func testHostPortRangeUsesOneHostFirstAllocationForEachAddressFamily() throws {
        let create = Data(
            """
            {"HostConfig":{"PortBindings":{"80/tcp":[
              {"HostIp":"0.0.0.0","HostPort":"8080-8082"},
              {"HostIp":"::","HostPort":"8080-8082"}
            ],"53/udp":[{"HostIp":"::","HostPort":"5353-5355"}]}}}
            """.utf8)

        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: create), .allowed)
        guard case .supported(let plan) =
            DockerPortPublicationPreflight.dynamicPortCreatePlan(in: create)
        else {
            return XCTFail("a valid Docker host-port range must use the host-first allocator")
        }

        XCTAssertEqual(plan.fixedPlan, DockerFixedPortLeasePlan(tcp: [], udp: []))
        XCTAssertEqual(
            plan.requestedPublications.map(\.requestedHostPortRange?.stringValue),
            ["8080-8082", "5353-5355", "8080-8082"])

        let selected = [
            DockerDynamicPortPublication(
                transport: .tcp, hostIP: "0.0.0.0", hostPort: 8081, containerPort: 80,
                requestedHostPortRange: DockerHostPortRange(string: "8080-8082")),
            DockerDynamicPortPublication(
                transport: .udp, hostIP: "::", hostPort: 5354, containerPort: 53,
                requestedHostPortRange: DockerHostPortRange(string: "5353-5355")),
            DockerDynamicPortPublication(
                transport: .tcp, hostIP: "::", hostPort: 8081, containerPort: 80,
                requestedHostPortRange: DockerHostPortRange(string: "8080-8082"))
        ]
        let rewritten = try plan.rewrittenBody(with: selected)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let bindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        let tcp = try XCTUnwrap(bindings["80/tcp"] as? [[String: Any]])
        let udp = try XCTUnwrap(bindings["53/udp"] as? [[String: Any]])
        XCTAssertEqual(tcp.map { $0["HostPort"] as? String }, ["8081", "8081"])
        XCTAssertEqual(udp.first?["HostPort"] as? String, "5354")
    }

    func testHostPortRangeRewriterRefusesAnOutOfRangeAllocation() throws {
        let create = Data(
            #"{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080-8082"}]}}}"#.utf8)
        guard case .supported(let plan) =
            DockerPortPublicationPreflight.dynamicPortCreatePlan(in: create)
        else {
            return XCTFail("a valid Docker host-port range must use the host-first allocator")
        }

        XCTAssertThrowsError(
            try plan.rewrittenBody(with: [
                DockerDynamicPortPublication(
                    transport: .tcp, hostIP: "", hostPort: 8083, containerPort: 80,
                    requestedHostPortRange: DockerHostPortRange(string: "8080-8082"))
            ]))
    }

    func testDynamicRangePlanRetainsFixedDualStackSiblingEndpoints() {
        let create = Data(
            """
            {"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080-8082"}],
              "443/tcp":[
                {"HostIp":"0.0.0.0","HostPort":"8443"},
                {"HostIp":"::","HostPort":"8443"}
              ]}}}
            """.utf8)

        guard case .supported(let plan) =
            DockerPortPublicationPreflight.dynamicPortCreatePlan(in: create)
        else {
            return XCTFail("mixed fixed and range bindings must stay one transaction")
        }
        XCTAssertEqual(plan.requestedPublications.count, 1)
        XCTAssertEqual(
            Set(plan.fixedPlan.tcp.compactMap(\.endpoint)),
            Set([endpoint("0.0.0.0", 8443), endpoint("::", 8443)]))
    }

    func testHostNetworkLeavesPortPublishingToMobyUntilThePolicyIsEnabled() {
        let hostNetwork = Data(
            #"{"HostConfig":{"NetworkMode":"host","PortBindings":{"80/tcp":[{"HostPort":"8080-8082"}]}}}"#.utf8)
        let sharedContainerNetwork = Data(
            #"{"HostConfig":{"NetworkMode":"container:anchor","PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#.utf8)

        // The explicit host-network policy defaults off. Until it is enabled, Moby
        // owns its standard warning and Morbstack must not bind a Mac endpoint.
        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: hostNetwork), .allowed)
        guard case .notDynamic = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: hostNetwork) else {
            return XCTFail("host networking must remain an unmodified Engine create")
        }
        XCTAssertNil(DockerPortPublicationPreflight.fixedPortLeasePlan(in: hostNetwork))

        // Moby rejects port publishing when a container shares another
        // container's network namespace. It must receive that native error
        // without Morbstack first reserving a temporary host endpoint.
        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: sharedContainerNetwork), .allowed)
        guard case .notDynamic = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: sharedContainerNetwork) else {
            return XCTFail("container network sharing must remain an unmodified Engine create")
        }
        XCTAssertNil(DockerPortPublicationPreflight.fixedPortLeasePlan(in: sharedContainerNetwork))
    }

    func testOptedInHostNetworkUsesTheContainerPortAsItsGuestDialTarget() {
        let fixed = Data(
            #"{"HostConfig":{"NetworkMode":"host","PortBindings":{"80/tcp":[{"HostPort":"8080"}],"53/udp":[{"HostPort":"5353"}]}}}"#.utf8)
        let dynamic = Data(
            #"{"HostConfig":{"NetworkMode":"host","PortBindings":{"80/tcp":[{"HostPort":""}]}}}"#.utf8)

        XCTAssertEqual(
            DockerPortPublicationPreflight.inspectContainerCreate(
                body: fixed,
                hostNetworkPortPublishing: true),
            .allowed)
        let fixedPlan = DockerPortPublicationPreflight.fixedPortLeasePlan(
            in: fixed,
            hostNetworkPortPublishing: true)
        XCTAssertEqual(fixedPlan?.guestDialPort, .containerPort)
        XCTAssertEqual(fixedPlan?.tcp.first?.hostPort, 8080)
        XCTAssertEqual(fixedPlan?.tcp.first?.containerPort, 80)
        XCTAssertEqual(fixedPlan?.udp.first?.hostPort, 5353)
        XCTAssertEqual(fixedPlan?.udp.first?.containerPort, 53)

        guard case .supported(let dynamicPlan) =
            DockerPortPublicationPreflight.dynamicPortCreatePlan(
                in: dynamic,
                hostNetworkPortPublishing: true)
        else {
            return XCTFail("an opted-in host-network dynamic mapping needs the held lease path")
        }
        XCTAssertEqual(dynamicPlan.fixedPlan.guestDialPort, .containerPort)
        XCTAssertEqual(dynamicPlan.requestedPublications.first?.containerPort, 80)
    }

    func testContainerNetworkNeverEntersTheHostNetworkForwardingPath() {
        let sharedContainerNetwork = Data(
            #"{"HostConfig":{"NetworkMode":"container:anchor","PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#.utf8)

        XCTAssertEqual(
            DockerPortPublicationPreflight.inspectContainerCreate(
                body: sharedContainerNetwork,
                hostNetworkPortPublishing: true),
            .allowed)
        XCTAssertNil(DockerPortPublicationPreflight.fixedPortLeasePlan(
            in: sharedContainerNetwork,
            hostNetworkPortPublishing: true))
    }

    func testCustomBridgeNetworkKeepsTheHostPortReservationPath() {
        let create = Data(
            #"{"HostConfig":{"NetworkMode":"project_default","PortBindings":{"80/tcp":[{"HostPort":"8080-8082"}]}}}"#.utf8)

        XCTAssertEqual(DockerPortPublicationPreflight.inspectContainerCreate(body: create), .allowed)
        guard case .supported = DockerPortPublicationPreflight.dynamicPortCreatePlan(in: create) else {
            return XCTFail("a custom bridge network must retain normal host port forwarding")
        }
    }

    func testHostNetworkDoesNotRecoverAPublishAllAllocator() {
        let containerID = String(repeating: "f", count: 64)
        let inspect = Data(
            """
            {"Id":"\(containerID)","State":{"Running":false},"HostConfig":{
              "NetworkMode":"host","PublishAllPorts":true,
              "RestartPolicy":{"Name":"always"},
              "PortBindings":{"80/tcp":[{"HostPort":"8080"}]}
            }}
            """.utf8)

        XCTAssertFalse(DockerPortPublicationPreflight.stoppedContainerUsesPublishAllPorts(
            in: inspect, expectedContainerID: containerID))
        XCTAssertFalse(DockerPortPublicationPreflight.restartPolicyUsesPublishAllPorts(
            in: inspect, expectedContainerID: containerID))
        XCTAssertNil(DockerPortPublicationPreflight.stoppedContainerFixedPortLeasePlan(
            in: inspect, expectedContainerID: containerID))
    }

    // MARK: - Fixed TCP lease recovery after VM loss

    func testStoppedFullIDInspectYieldsOnlyConcreteLoopbackTCPLeaseBindings() {
        let containerID = String(repeating: "a", count: 64)
        let inspect = Data(
            """
            {
              "Id":"\(containerID)",
              "State":{"Running":false},
              "HostConfig":{"PortBindings":{
                "80/tcp":[
                  {"HostIp":"::","HostPort":"8080"},
                  {"HostIp":"0.0.0.0","HostPort":"8080"}
                ],
                "443/tcp":[{"HostIp":"127.0.0.1","HostPort":"8443"}]
              }}
            }
            """.utf8)

        XCTAssertTrue(DockerPortPublicationPreflight.isFullContainerID(containerID))
        XCTAssertEqual(
            DockerPortPublicationPreflight.stoppedContainerTCPBindings(
                in: inspect,
                expectedContainerID: containerID),
            [
                DockerExplicitTCPPortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80),
                DockerExplicitTCPPortBinding(hostIP: "127.0.0.1", hostPort: 8443, containerPort: 443)
            ])
    }

    func testStoppedInspectRecoveryRefusesUnprovenIdentityOrPublicationShapes() {
        let containerID = String(repeating: "b", count: 64)
        func inspect(id: String, running: Bool = false, bindings: String) -> Data {
            Data(
                """
                {"Id":"\(id)","State":{"Running":\(running)},
                "HostConfig":{"PortBindings":\(bindings)}}
                """.utf8)
        }

        XCTAssertFalse(DockerPortPublicationPreflight.isFullContainerID("short-id"))
        XCTAssertFalse(DockerPortPublicationPreflight.isFullContainerID(String(repeating: "B", count: 64)))
        XCTAssertNil(
            DockerPortPublicationPreflight.stoppedContainerTCPBindings(
                in: inspect(id: String(repeating: "c", count: 64), bindings: #"{"80/tcp":[{"HostPort":"8080"}]}"#),
                expectedContainerID: containerID))
        XCTAssertNil(
            DockerPortPublicationPreflight.stoppedContainerTCPBindings(
                in: inspect(id: containerID, running: true, bindings: #"{"80/tcp":[{"HostPort":"8080"}]}"#),
                expectedContainerID: containerID))

        for bindings in [
            #"{"80/tcp":[{"HostPort":""}]}"#,
            #"{"80/tcp":[{"HostPort":"0"}]}"#,
            #"{"80/tcp":[{"HostPort":"8080-8081"}]}"#,
            #"{"53/udp":[{"HostPort":"5353"}]}"#,
            #"{"80/tcp":[{"HostPort":"8080"}],"81/tcp":[{"HostPort":"8080"}]}"#
        ] {
            XCTAssertNil(
                DockerPortPublicationPreflight.stoppedContainerTCPBindings(
                    in: inspect(id: containerID, bindings: bindings),
                    expectedContainerID: containerID),
                "\(bindings) must retain the raw start relay")
        }
    }

    // MARK: - Running containers (the auto-suspend interlock)

    /// The idle timer asks the engine this question before it is allowed to tear the
    /// guest down, so the filter has to be the one dockerd actually understands.
    func testRunningContainersPathFiltersServerSide() {
        let path = DockerAPIDecoding.runningContainersPath
        XCTAssertTrue(path.hasPrefix(DockerAPIDecoding.containersPath + "?filters="), path)
        XCTAssertTrue(
            path.hasSuffix(MinimalHTTP.percentEncodeQueryValue(#"{"status":["running"]}"#)), path)
        // Percent-encoded, not raw: dockerd rejects the bare JSON punctuation.
        XCTAssertFalse(path.contains("{"), path)
    }

    func testCountsRunningContainers() throws {
        XCTAssertEqual(try DockerAPIDecoding.containerCount(containersJSON: containersJSON), 2)
        XCTAssertEqual(try DockerAPIDecoding.containerCount(containersJSON: Data("[]".utf8)), 0)
    }

    /// An unparseable answer must throw rather than read as "nothing is running":
    /// the caller treats a failure as "do not suspend", and a zero as "go ahead".
    func testAMalformedContainerListIsAnErrorNotAZero() {
        XCTAssertThrowsError(
            try DockerAPIDecoding.containerCount(containersJSON: Data(#"{"message":"nope"}"#.utf8)))
        XCTAssertThrowsError(
            try DockerAPIDecoding.containerCount(containersJSON: Data("not json".utf8)))
    }

    // MARK: - Diffing

    private func binding(_ port: Int, container: String, id: String = "id") -> DockerPortBinding {
        DockerPortBinding(
            hostIP: "0.0.0.0", hostPort: port, containerPort: 80, networkProtocol: "tcp",
            containerID: id, containerName: container)
    }

    private func endpoint(_ hostIP: String, _ port: Int) -> DockerHostEndpoint {
        DockerHostEndpoint(hostIP: hostIP, port: port)!
    }

    func testDiffOpensNewPortsAndClosesRetiredOnes() {
        let current = [endpoint("0.0.0.0", 8080): binding(8080, container: "web")]
        let desired = [endpoint("0.0.0.0", 9090): binding(9090, container: "api")]
        let plan = PortForwardPlan.diff(current: current, desired: desired)
        XCTAssertEqual(plan.close, [endpoint("0.0.0.0", 8080)])
        XCTAssertEqual(plan.open.map(\.hostPort), [9090])
    }

    func testDiffIsEmptyWhenNothingChanged() {
        let same = [endpoint("0.0.0.0", 8080): binding(8080, container: "web")]
        let plan = PortForwardPlan.diff(current: same, desired: same)
        XCTAssertTrue(plan.close.isEmpty)
        XCTAssertTrue(plan.open.isEmpty)
    }

    /// `docker compose up` after an edit replaces the container behind a port. The
    /// listener has to be rebuilt, and the close must be planned so it can happen
    /// before the open — otherwise the rebind hits EADDRINUSE against ourselves.
    func testAReplacedContainerOnTheSamePortIsClosedAndReopened() {
        let current = [endpoint("0.0.0.0", 8080): binding(8080, container: "web", id: "old")]
        let desired = [endpoint("0.0.0.0", 8080): binding(8080, container: "web", id: "new")]
        let plan = PortForwardPlan.diff(current: current, desired: desired)
        XCTAssertEqual(plan.close, [endpoint("0.0.0.0", 8080)])
        XCTAssertEqual(plan.open.map(\.containerID), ["new"])
    }

    // MARK: - Events

    func testDecodesAStartEvent() throws {
        let line = Data(
            """
            {"status":"start","id":"abc123","Type":"container","Action":"start",
             "Actor":{"ID":"abc123","Attributes":{"name":"web","image":"nginx"}},"time":1}
            """.utf8)
        let event = try XCTUnwrap(DockerAPIDecoding.containerEvent(line: line))
        XCTAssertEqual(event.action, "start")
        XCTAssertEqual(event.containerID, "abc123")
        XCTAssertEqual(event.containerName, "web")
        XCTAssertTrue(event.affectsPublishedPorts)
    }

    /// `exec_create: /bin/sh` fires on every `docker exec` and never moves a port;
    /// refreshing on it would make an interactive shell hammer the Engine API.
    func testNoisyEventsDoNotTriggerARefresh() throws {
        let line = Data(
            """
            {"Type":"container","Action":"exec_create: /bin/sh","id":"abc123","time":1}
            """.utf8)
        let event = try XCTUnwrap(DockerAPIDecoding.containerEvent(line: line))
        XCTAssertEqual(event.action, "exec_create")
        XCTAssertFalse(event.affectsPublishedPorts)
    }

    func testIgnoresNonContainerAndMalformedEvents() {
        XCTAssertNil(
            DockerAPIDecoding.containerEvent(
                line: Data(#"{"Type":"image","Action":"pull","id":"nginx"}"#.utf8)))
        XCTAssertNil(DockerAPIDecoding.containerEvent(line: Data("not json".utf8)))
        XCTAssertNil(DockerAPIDecoding.containerEvent(line: Data()))
        // An event with no id is unusable even if it parses.
        XCTAssertNil(
            DockerAPIDecoding.containerEvent(line: Data(#"{"Type":"container","Action":"die"}"#.utf8)))
    }

    /// Pre-1.22 engines only send `status`; the forwarder still has to understand them.
    func testFallsBackToTheLegacyStatusField() throws {
        let event = try XCTUnwrap(
            DockerAPIDecoding.containerEvent(line: Data(#"{"status":"die","id":"abc"}"#.utf8)))
        XCTAssertEqual(event.action, "die")
        XCTAssertTrue(event.affectsPublishedPorts)
    }

    // MARK: - Stream dial

    func testPreambleEncoding() {
        XCTAssertEqual(String(decoding: StreamDial.preamble(guestPort: 8080), as: UTF8.self), "TCP 8080\n")
        XCTAssertEqual(String(decoding: StreamDial.preamble(guestPort: 1), as: UTF8.self), "TCP 1\n")
    }

    func testReplyParsing() {
        XCTAssertNoThrow(try StreamDial.parseReply("OK").get())
        XCTAssertNoThrow(try StreamDial.parseReply("OK\n").get())
        XCTAssertNoThrow(try StreamDial.parseReply("OK\r\n").get())

        XCTAssertThrowsError(try StreamDial.parseReply("ERR connection refused\n").get()) { error in
            XCTAssertTrue("\(error)".contains("connection refused"), "\(error)")
        }
        XCTAssertThrowsError(try StreamDial.parseReply("").get())
        XCTAssertThrowsError(try StreamDial.parseReply("what?\n").get())
    }

    /// The reply reader must stop at the newline: everything after it is the peer's
    /// payload, and swallowing even one byte of it corrupts the spliced stream.
    func testReplyReaderLeavesThePayloadUntouched() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertTrue(POSIXSocketSupport.writeAll(fds[1], Data("OK\nHTTP/1.1 200 OK\r\n".utf8)))

        let line = try StreamDial.readReplyLine(fd: fds[0], deadline: Date().addingTimeInterval(2))
        XCTAssertEqual(line, "OK")

        var buffer = [UInt8](repeating: 0, count: 64)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(fds[0], into: raw.baseAddress!, count: raw.count)
        }
        XCTAssertEqual(String(decoding: buffer[0..<max(0, n)], as: UTF8.self), "HTTP/1.1 200 OK\r\n")
    }

    func testReplyReaderTimesOutRatherThanHanging() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertThrowsError(
            try StreamDial.readReplyLine(fd: fds[0], deadline: Date().addingTimeInterval(0.2))
        ) { error in
            XCTAssertTrue("\(error)".contains("in time"), "\(error)")
        }
    }

    // MARK: - Datagram dial

    func testDatagramDialPreambleAndFramingPreservePacketBoundaries() throws {
        XCTAssertEqual(String(decoding: DatagramDial.preamble(guestPort: 5353), as: UTF8.self), "UDP 5353\n")

        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        XCTAssertTrue(DatagramDial.writeFrame(fd: sockets[1], datagram: Data("one".utf8)))
        XCTAssertTrue(DatagramDial.writeFrame(fd: sockets[1], datagram: Data()))
        XCTAssertTrue(DatagramDial.writeFrame(fd: sockets[1], datagram: Data("three".utf8)))

        XCTAssertEqual(try DatagramDial.readFrame(fd: sockets[0]), Data("one".utf8))
        XCTAssertEqual(try DatagramDial.readFrame(fd: sockets[0]), Data())
        XCTAssertEqual(try DatagramDial.readFrame(fd: sockets[0]), Data("three".utf8))
    }

    func testDatagramDialRejectsAFrameLargerThanUDPPermits() throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        XCTAssertFalse(
            DatagramDial.writeFrame(
                fd: sockets[1],
                datagram: Data(repeating: 0, count: DatagramDial.maximumDatagramBytes + 1)))
        XCTAssertTrue(POSIXSocketSupport.writeAll(sockets[1], Data([0, 1, 0, 0])))
        XCTAssertThrowsError(try DatagramDial.readFrame(fd: sockets[0]))
    }

    // MARK: - Listener

    func testListenerAcceptsOnLoopbackAndReportsAConflict() throws {
        let queue = DispatchQueue(label: "test.tcplistener", attributes: .concurrent)
        let listener = TCPListener(port: 0, queue: queue)
        // Port 0 would ask the kernel to pick one, which the forwarder never does;
        // find a free port the honest way instead.
        listener.stop()

        let port = try findFreePort()
        let accepted = expectation(description: "connection accepted")
        let first = TCPListener(port: port, queue: queue)
        first.onConnection = { fd in
            close(fd)
            accepted.fulfill()
        }
        try first.start()
        defer { first.stop() }

        // A second listener on the same port must report the conflict rather than
        // silently shadowing the first — SO_REUSEADDR must not paper over this.
        let second = TCPListener(port: port, queue: queue)
        XCTAssertThrowsError(try second.start()) { error in
            guard case TCPListenerError.addressInUse(let reported) = error else {
                return XCTFail("expected addressInUse, got \(error)")
            }
            XCTAssertEqual(reported, port)
        }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(client, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "\(String(cString: strerror(errno)))")
        wait(for: [accepted], timeout: 5)
    }

    /// `stop()` has to free the port *before it returns*.
    ///
    /// The forwarder closes and immediately reopens the same host port every time a
    /// container is recreated, and rebinds the whole set on every suspend/resume.
    /// While the listening descriptor was closed asynchronously by the dispatch
    /// cancel handler, that reopen was a coin flip: often the old listener still held
    /// the port and the rebind failed EADDRINUSE against ourselves, leaving the
    /// published port dark with nothing but a warning to show for it. Fifty rounds
    /// makes the race, if it comes back, essentially certain to show up here.
    func testStopFreesThePortSynchronouslyEnoughToRebindImmediately() throws {
        let queue = DispatchQueue(label: "test.tcplistener.rebind", attributes: .concurrent)
        let port = try findFreePort()

        for round in 1...50 {
            let listener = TCPListener(port: port, queue: queue)
            listener.onConnection = { fd in close(fd) }
            do {
                try listener.start()
            } catch {
                return XCTFail("round \(round) could not bind 127.0.0.1:\(port): \(error)")
            }
            XCTAssertTrue(listener.isRunning)
            listener.stop()
            XCTAssertFalse(listener.isRunning)
        }
    }

    /// `stop()` is called from `deinit`, from the forwarder's work queue and from its
    /// own teardown; none of those may close the descriptor twice.
    func testStopIsIdempotent() throws {
        let queue = DispatchQueue(label: "test.tcplistener.idempotent", attributes: .concurrent)
        let port = try findFreePort()
        let listener = TCPListener(port: port, queue: queue)
        try listener.start()
        listener.stop()
        listener.stop()
        listener.stop()
        XCTAssertFalse(listener.isRunning)

        // If a double close had happened, this bind would be landing on a port some
        // other part of the process had since been handed.
        let rebound = TCPListener(port: port, queue: queue)
        XCTAssertNoThrow(try rebound.start())
        rebound.stop()
    }

    /// Asks the kernel for an unused loopback port and immediately gives it back.
    private func findFreePort() throws -> Int {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(probe, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw XCTSkip("could not bind a probe socket") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(probe, generic, &length)
            }
        }
        guard named == 0 else { throw XCTSkip("getsockname failed") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}
