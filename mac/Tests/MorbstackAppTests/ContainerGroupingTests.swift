// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Containers route's three presentation tiers — loose containers, Compose
// project sections, and the collapsed Kubernetes-Managed group — are a pure split
// over facts Docker reported (`com.docker.compose.project`,
// `io.kubernetes.docker.type`). These tests pin the split's rules without a daemon:
// nothing may be dropped, double-filed, or silently reordered inside a tier.

import XCTest

@testable import MorbstackAppCore

final class ContainerGroupingTests: XCTestCase {

    private func container(
        _ name: String,
        project: String? = nil,
        kubernetes: Bool = false
    ) -> ContainerSummary {
        ContainerSummary(
            id: "id-\(name)",
            names: [name],
            displayName: name,
            image: "alpine:3.20",
            state: "running",
            status: "Up 2 minutes",
            composeProject: project,
            composeService: project == nil ? nil : "svc",
            ports: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isKubernetesManaged: kubernetes)
    }

    func testEveryContainerLandsInExactlyOneTier() {
        let input = [
            container("plain-a"),
            container("web", project: "shop"),
            container("k8s_POD_x", kubernetes: true),
            container("plain-b"),
            container("db", project: "shop"),
            container("k8s_app_y", kubernetes: true),
        ]

        let groups = TrackBContainerGrouping.groups(of: input)

        let regrouped = groups.standalone + groups.projects.flatMap(\.containers) + groups.kubernetes
        XCTAssertEqual(regrouped.count, input.count, "The split must not drop or duplicate a record.")
        XCTAssertEqual(Set(regrouped.map(\.id)), Set(input.map(\.id)))
        XCTAssertEqual(groups.standalone.map(\.displayName), ["plain-a", "plain-b"])
        XCTAssertEqual(groups.projects.map(\.name), ["shop"])
        XCTAssertEqual(groups.projects.first?.containers.map(\.displayName), ["web", "db"])
        XCTAssertEqual(groups.kubernetes.map(\.displayName), ["k8s_POD_x", "k8s_app_y"])
    }

    func testKubernetesFactWinsOverAComposeLabel() {
        // A kubelet-created container that somehow also carries a Compose project
        // label must not appear twice or under the project.
        let both = container("k8s_odd", project: "shop", kubernetes: true)
        let groups = TrackBContainerGrouping.groups(of: [both])

        XCTAssertEqual(groups.kubernetes.map(\.id), [both.id])
        XCTAssertTrue(groups.projects.isEmpty)
        XCTAssertTrue(groups.standalone.isEmpty)
    }

    func testProjectSectionsSortByNameWhileRowsKeepCallerOrder() {
        let input = [
            container("z1", project: "zeta"),
            container("a1", project: "alpha"),
            container("z2", project: "zeta"),
        ]

        let groups = TrackBContainerGrouping.groups(of: input)

        XCTAssertEqual(groups.projects.map(\.name), ["alpha", "zeta"])
        XCTAssertEqual(
            groups.projects.last?.containers.map(\.displayName), ["z1", "z2"],
            "Rows inside a project keep the caller's order; only section order is normalized.")
    }

    func testEmptyProjectStringIsNotAProject() {
        let groups = TrackBContainerGrouping.groups(of: [container("x", project: "")])
        XCTAssertEqual(groups.standalone.map(\.displayName), ["x"])
        XCTAssertTrue(groups.projects.isEmpty)
    }

    func testWireLabelMapsToKubernetesManaged() {
        // The end-to-end fact: a dockershim label on the list endpoint becomes the
        // grouping flag. Guards against the label key drifting in either place.
        var wire = Wire.Container(Id: "abc123")
        wire.Names = ["/k8s_POD_thing"]
        wire.Labels = ["io.kubernetes.docker.type": "podsandbox"]

        XCTAssertTrue(ContainerSummary(wire).isKubernetesManaged)

        wire.Labels = ["com.docker.compose.project": "shop"]
        XCTAssertFalse(ContainerSummary(wire).isKubernetesManaged)
    }
}
