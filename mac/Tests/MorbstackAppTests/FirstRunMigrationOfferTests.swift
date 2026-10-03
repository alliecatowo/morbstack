// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest

@testable import MorbstackAppCore

/// Pure presentation coverage for the first-run sheet's migration offer (UX-23). These
/// cases avoid `RuntimeDetect`'s real install/socket probe entirely: the offer's
/// grammar and its "say nothing when nothing was found" rule are exercised against
/// literal name lists, the same detected names `FirstRunCLISetupModel.prepare()` would
/// have populated from `RuntimeDetect.detectDockerDesktop/detectColima/detectOrbStack`.
final class FirstRunMigrationOfferTests: XCTestCase {

    func testNoDetectedSourceOffersNothingRatherThanAnEmptyControl() {
        XCTAssertFalse(FirstRunMigrationOffer.offers([]))
        XCTAssertEqual(FirstRunMigrationOffer.detectionSentence(for: []), "")
    }

    func testOneDetectedSourceStatesItSingularly() {
        XCTAssertTrue(FirstRunMigrationOffer.offers(["Docker Desktop"]))
        XCTAssertEqual(
            FirstRunMigrationOffer.detectionSentence(for: ["Docker Desktop"]),
            "Docker Desktop is on this Mac.")
    }

    func testTwoDetectedSourcesJoinWithAndAndUsePluralAre() {
        XCTAssertEqual(
            FirstRunMigrationOffer.detectionSentence(for: ["Docker Desktop", "Colima"]),
            "Docker Desktop and Colima are on this Mac.")
    }

    func testThreeDetectedSourcesGetAnOxfordComma() {
        XCTAssertEqual(
            FirstRunMigrationOffer.detectionSentence(for: ["Docker Desktop", "Colima", "OrbStack"]),
            "Docker Desktop, Colima, and OrbStack are on this Mac.")
    }
}
