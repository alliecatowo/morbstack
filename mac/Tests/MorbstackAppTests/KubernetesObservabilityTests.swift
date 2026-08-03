// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackAppCore

/// Contract coverage for the deterministic fixture used by the native Kubernetes
/// inspector. Network API parsing belongs to the live local-cluster evidence lane;
/// this suite keeps the route's selection relationships deterministic and offline.
@MainActor
final class KubernetesObservabilityTests: XCTestCase {

    func testSelectedPodProvidesAContainerBoundedLogAndOnlyItsEvents() async throws {
        let client = K8sFixtureClient()
        let resources = try await client.resources()
        let pod = try XCTUnwrap(resources.pods.first { $0.name.hasPrefix("coredns-") })
        let container = try XCTUnwrap(pod.containers.first)

        let log = try await client.podLog(for: pod, container: container.name)
        let events = try await client.podEvents(for: pod)

        XCTAssertTrue(log.contains("fixture \(container.name) started"))
        XCTAssertEqual(events.map(\.reason), ["Scheduled"])
    }

    func testUnrelatedFixturePodDoesNotReceiveAnotherPodsEvents() async throws {
        let client = K8sFixtureClient()
        let resources = try await client.resources()
        let pod = try XCTUnwrap(resources.pods.first { $0.name.hasPrefix("hello-web-") })

        let events = try await client.podEvents(for: pod)

        XCTAssertTrue(events.isEmpty)
    }
}
