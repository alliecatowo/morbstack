// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The menu-bar extra's "Running" list is a bounded projection of the container
// inventory, and its truncation arithmetic decides two things at once: what is drawn,
// and which `/stats` sockets are opened. A row budget that disagrees with the stream
// list either leaves a container with a permanent em dash for its CPU or opens a stream
// nobody can see, so both come out of the same pure value.

import Foundation
import XCTest

@testable import MorbstackAppCore

final class MenuBarListTests: XCTestCase {

    private func container(
        _ name: String,
        project: String? = nil,
        kubernetes: Bool = false,
        running: Bool = true
    ) -> ContainerSummary {
        ContainerSummary(
            id: "id-\(name)",
            names: [name],
            displayName: name,
            image: "alpine:3.20",
            state: running ? "running" : "exited",
            status: running ? "Up 2 minutes" : "Exited (0) 1 minute ago",
            composeProject: project,
            composeService: project == nil ? nil : name,
            ports: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isKubernetesManaged: kubernetes)
    }

    // MARK: Grouping

    /// Compose projects lead, alphabetically; the two buckets that are not projects go
    /// last so their position does not shift as projects come and go.
    func testProjectsLeadAndTheUnnamedBucketsFollowInAStableOrder() {
        let list = TrackDMenuBarList.build(
            [
                container("loose"),
                container("kubelet", kubernetes: true),
                container("api", project: "shopfront"),
                container("grafana", project: "analytics"),
            ],
            limit: 8)

        XCTAssertEqual(list.groups.map(\.title), ["analytics", "shopfront", "Standalone", "Kubernetes-Managed"])
        XCTAssertEqual(list.groups.map(\.id), ["project:analytics", "project:shopfront", "standalone", "kubernetes"])
    }

    /// Each group points at the screen that owns its records, and the header's symbol
    /// is that screen's symbol — one decision, so the glyph cannot disagree with where
    /// the click lands.
    func testEachGroupPointsAtTheScreenThatOwnsItsRecords() {
        let list = TrackDMenuBarList.build(
            [container("api", project: "shopfront"), container("loose"), container("kubelet", kubernetes: true)],
            limit: 8)

        XCTAssertEqual(list.groups.map(\.kind.destination), [.stacks, .containers, .kubernetes])
        XCTAssertEqual(list.groups.map(\.symbol), [Nav.stacks.symbol, Nav.containers.symbol, Nav.kubernetes.symbol])
    }

    /// Only running containers are listed — but the header counts the whole project, so
    /// a stack that is half up says so without listing services it is not offering to
    /// act on.
    func testTheHeaderCountsTheWholeProjectWhileTheRowsListOnlyWhatIsRunning() throws {
        let list = TrackDMenuBarList.build(
            [
                container("api", project: "shopfront"),
                container("web", project: "shopfront"),
                container("worker", project: "shopfront", running: false),
            ],
            limit: 8)

        let group = try XCTUnwrap(list.groups.first)
        XCTAssertEqual(group.containers.map(\.displayName), ["api", "web"])
        XCTAssertEqual(group.runningCount, 2)
        XCTAssertEqual(group.memberCount, 3)
        XCTAssertEqual(group.subtitle, "2 of 3 running")
    }

    /// A project with nothing running is not a group with no rows — it is absent. The
    /// section is titled "Running".
    func testAProjectWithNothingRunningDoesNotAppear() {
        let list = TrackDMenuBarList.build(
            [
                container("api", project: "shopfront"),
                container("grafana", project: "analytics", running: false),
            ],
            limit: 8)

        XCTAssertEqual(list.groups.map(\.title), ["shopfront"])
        XCTAssertEqual(list.hiddenCount, 0)
    }

    func testAnEngineWithNothingRunningProducesAnEmptyList() {
        let list = TrackDMenuBarList.build([container("api", running: false)], limit: 8)
        XCTAssertTrue(list.isEmpty)
        XCTAssertTrue(list.visibleIDs.isEmpty)
        XCTAssertEqual(list.hiddenCount, 0)
    }

    /// One group is not a grouping. The header would be a label for the entire list,
    /// which the "Running" title already is.
    func testASingleGroupDrawsNoHeader() {
        let one = TrackDMenuBarList.build([container("a"), container("b")], limit: 8)
        XCTAssertFalse(one.showsGroupHeaders)

        let two = TrackDMenuBarList.build([container("a"), container("b", project: "shop")], limit: 8)
        XCTAssertTrue(two.showsGroupHeaders)
    }

    // MARK: Truncation

    /// The budget spans the whole list, not each group: three projects of four
    /// containers must not quietly draw twelve rows in a status popover.
    func testTheRowBudgetIsSharedAcrossEveryGroup() {
        let containers = (0..<4).flatMap { index in
            ["alpha", "beta", "gamma"].map { container("\($0)-\(index)", project: $0) }
        }

        let list = TrackDMenuBarList.build(containers, limit: 5)

        XCTAssertEqual(list.visibleIDs.count, 5)
        XCTAssertEqual(list.hiddenCount, 7, "Every running container is either drawn or counted as hidden.")
        XCTAssertEqual(list.visibleIDs.count + list.hiddenCount, containers.count)
    }

    /// A group the budget ran out before reaching is folded into the hidden count
    /// rather than rendered as an empty header.
    func testAGroupWithNoRoomLeftBecomesHiddenCountRatherThanAnEmptyHeader() {
        let list = TrackDMenuBarList.build(
            [
                container("a1", project: "alpha"),
                container("a2", project: "alpha"),
                container("b1", project: "beta"),
            ],
            limit: 2)

        XCTAssertEqual(list.groups.map(\.title), ["alpha"])
        XCTAssertEqual(list.hiddenCount, 1)
        XCTAssertFalse(list.groups.contains { $0.containers.isEmpty })
    }

    /// The stats streams follow the drawn rows exactly — never a socket for a row below
    /// the fold, never a row without a stream.
    func testTheStreamedIdsAreExactlyTheDrawnRows() {
        let list = TrackDMenuBarList.build(
            [container("a"), container("b"), container("c", project: "shop")],
            limit: 2)

        XCTAssertEqual(list.visibleIDs, list.groups.flatMap { $0.containers.map(\.id) })
        XCTAssertEqual(list.visibleIDs.count, 2)
    }

    func testAZeroOrNegativeBudgetDrawsNothingAndHidesEverything() {
        for limit in [0, -3] {
            let list = TrackDMenuBarList.build([container("a"), container("b")], limit: limit)
            XCTAssertTrue(list.isEmpty, "limit \(limit)")
            XCTAssertEqual(list.hiddenCount, 2, "limit \(limit)")
        }
    }

    /// A Kubernetes-managed container carrying Compose labels files under Kubernetes,
    /// matching the Containers route: the extra must not invent a second answer to a
    /// question that route already settled.
    func testTheKubeletFactWinsOverAComposeLabel() {
        let list = TrackDMenuBarList.build(
            [container("pod", project: "shopfront", kubernetes: true)],
            limit: 8)

        XCTAssertEqual(list.groups.map(\.id), ["kubernetes"])
    }
}
