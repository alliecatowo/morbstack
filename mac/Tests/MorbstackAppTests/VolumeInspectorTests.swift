// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation
import XCTest

@testable import MorbstackAppCore

/// Pure data and safety coverage for the selected-volume inspector. These cases avoid
/// a daemon: the UI is responsible for presenting Docker's absence/inconsistency as a
/// fact, while the Engine remains the authority for volume removal.
final class VolumeInspectorTests: XCTestCase {

    private func volume(
        name: String = "app_data",
        size: Int64? = 1_024,
        refCount: Int? = 0,
        labels: [String: String] = [:]
    ) -> VolumeSummary {
        VolumeSummary(
            name: name,
            driver: "local",
            mountpoint: "/var/lib/docker/volumes/\(name)/_data",
            size: size,
            refCount: refCount,
            labels: labels)
    }

    private func container(
        id: String,
        name: String,
        volumeNames: [String]
    ) -> ContainerSummary {
        ContainerSummary(
            id: id,
            names: [name],
            displayName: name,
            image: "example/service:latest",
            state: "running",
            status: "Up 1 minute",
            composeProject: nil,
            composeService: nil,
            ports: [],
            createdAt: .distantPast,
            volumeNames: volumeNames)
    }

    func testVolumeWireMappingPreservesLabelsAndUnreportedUsage() throws {
        let payload = """
        {
          "Volumes": [
            {
              "Name": "app_data",
              "Driver": "local",
              "Mountpoint": "/var/lib/docker/volumes/app_data/_data",
              "Labels": { "com.example.role": "database", "z.last": "yes" }
            }
          ]
        }
        """

        let wire = try JSONDecoder().decode(Wire.VolumeList.self, from: Data(payload.utf8))
        let subject = VolumeSummary(try XCTUnwrap(wire.Volumes?.first))

        XCTAssertNil(subject.size)
        XCTAssertNil(subject.refCount)
        XCTAssertEqual(subject.labels, ["com.example.role": "database", "z.last": "yes"])
        XCTAssertEqual(
            TrackCVolumeInspector.labels(for: subject).map(\.key),
            ["com.example.role", "z.last"])
    }

    func testContainerWireMappingIndexesOnlyNamedVolumeMounts() throws {
        let payload = """
        {
          "Id": "container-1",
          "Names": ["/database"],
          "Image": "postgres:16",
          "Mounts": [
            { "Type": "volume", "Name": "app_data" },
            { "Type": "bind", "Name": "not-a-volume" },
            { "Type": "volume", "Name": "app_data" },
            { "Type": "volume" }
          ]
        }
        """

        let wire = try JSONDecoder().decode(Wire.Container.self, from: Data(payload.utf8))
        let subject = ContainerSummary(wire)

        XCTAssertEqual(subject.volumeNames, ["app_data"])
    }

    func testSearchIncludesReportedLabelKeysAndValues() {
        let subject = volume(labels: ["com.example.role": "database"])

        XCTAssertTrue(TrackCVolumeList.matches(subject, query: "ROLE"))
        XCTAssertTrue(TrackCVolumeList.matches(subject, query: "DATABASE"))
        XCTAssertFalse(TrackCVolumeList.matches(subject, query: "cache"))
    }

    func testReferencedContainersUseExactVolumeNamesAndNaturalNameOrder() {
        let subject = volume(name: "app_data", refCount: 2)
        let references = TrackCVolumeInspector.referencedContainers(
            for: subject,
            in: [
                container(id: "worker", name: "worker10", volumeNames: ["app_data"]),
                container(id: "api", name: "api", volumeNames: ["app_data", "cache"]),
                container(id: "other", name: "other", volumeNames: ["app_data_old"]),
                container(id: "worker2", name: "worker2", volumeNames: ["app_data"]),
            ])

        XCTAssertEqual(references.map(\.id), ["api", "worker2", "worker"])
        XCTAssertEqual(references.map(\.name), ["api", "worker2", "worker10"])
    }

    func testUsageEvidenceNeverTurnsMissingOrMismatchedDataIntoUnused() {
        XCTAssertEqual(
            TrackCVolumeInspector.usageEvidence(reportedReferenceCount: nil, listedReferences: 0),
            .unreported)
        XCTAssertEqual(
            TrackCVolumeInspector.usageEvidence(reportedReferenceCount: 0, listedReferences: 0),
            .unused)
        XCTAssertEqual(
            TrackCVolumeInspector.usageEvidence(reportedReferenceCount: 2, listedReferences: 2),
            .matches)
        XCTAssertEqual(
            TrackCVolumeInspector.usageEvidence(reportedReferenceCount: 2, listedReferences: 1),
            .incomplete(reported: 2, listed: 1))
        XCTAssertEqual(
            TrackCVolumeInspector.usageEvidence(reportedReferenceCount: 0, listedReferences: 1),
            .inconsistent(reported: 0, listed: 1))
    }

    func testRemovalConsequenceKeepsDataLossAndUsageUncertaintyExplicit() {
        XCTAssertEqual(
            TrackCVolumeInspector.removalConsequence(for: volume(refCount: 0)),
            "Removing permanently deletes this volume’s contents. Docker reports no container references.")
        XCTAssertEqual(
            TrackCVolumeInspector.removalConsequence(for: volume(refCount: 1)),
            "Removing permanently deletes this volume’s contents. Docker will refuse while 1 container references it.")
        XCTAssertEqual(
            TrackCVolumeInspector.removalConsequence(for: volume(refCount: nil)),
            "Removing permanently deletes this volume’s contents. Docker did not report current usage and will refuse if the volume is attached.")
    }

    func testCreateRequestRequiresANonblankName() throws {
        XCTAssertNil(VolumeCreateRequest(name: ""))
        XCTAssertNil(VolumeCreateRequest(name: " \n\t "))

        let request = try XCTUnwrap(VolumeCreateRequest(name: "project-data"))
        XCTAssertEqual(request.name, "project-data")
    }

    func testArchiveReviewStatesWhetherTheSelectedDestinationWillBeReplaced() {
        let newArchive = VolumeArchiveExportReview(
            volumeName: "project-data",
            outputURL: URL(fileURLWithPath: "/tmp/project-data.tar"),
            replacesExisting: false)
        let replacement = VolumeArchiveExportReview(
            volumeName: "project-data",
            outputURL: URL(fileURLWithPath: "/tmp/project-data.tar"),
            replacesExisting: true)

        XCTAssertTrue(newArchive.destinationConsequence.contains("does not save the archive"))
        XCTAssertTrue(replacement.destinationConsequence.contains("replaced atomically"))
    }
}
