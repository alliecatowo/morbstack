// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// These are macOS UI tests, intentionally outside the Swift Package.  XCTest launches
// the assembled Morbstack.app through XCUIApplication(url:) so every attachment comes
// from the real WindowServer-composited window, not a SwiftUI renderer or a duplicate
// view hierarchy.  See ../README.md before changing this harness.

import Foundation
import XCTest

final class MorbstackFixtureUITests: XCTestCase {

    private enum Appearance: String {
        case light
        case dark
    }

    private struct Route {
        let sidebarTitle: String
        let fixtureMarker: String
    }

    private struct HarnessError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private let routes: [Route] = [
        // The first route is the app's deterministic initial selection.  The marker is
        // a fixture value, not another copy of the navigation label, so this verifies
        // the destination actually loaded.
        Route(sidebarTitle: "Containers", fixtureMarker: "shopfront-api-1"),
        Route(sidebarTitle: "Stacks", fixtureMarker: "shopfront"),
        Route(sidebarTitle: "Kubernetes", fixtureMarker: "coredns-7f9c69d9d8-4wqxr"),
        Route(sidebarTitle: "Images", fixtureMarker: "postgres"),
        Route(sidebarTitle: "Volumes", fixtureMarker: "shopfront_pgdata"),
        Route(sidebarTitle: "Networks", fixtureMarker: "morb-ingress"),
        Route(sidebarTitle: "Builds", fixtureMarker: "RUN npm run build"),
        Route(sidebarTitle: "Disk", fixtureMarker: "Build cache"),
    ]

    private var launchedApp: XCUIApplication?

    override func tearDownWithError() throws {
        if let launchedApp, launchedApp.state != .notRunning {
            launchedApp.terminate()
        }
        launchedApp = nil
        try super.tearDownWithError()
    }

    /// Keeps fixture browsing deterministic in the normal (light) macOS appearance.
    /// One attachment is retained for every route; review it in the `.xcresult` bundle.
    func testFixtureRoutesInLightAppearance() throws {
        let app = try launchFixture(appearance: .light)
        try verifyAllRoutes(in: app, appearance: .light)
    }

    /// Dark mode is a separate process because SwiftUI resolves a forced color scheme
    /// at window creation.  This catches regressions where custom content ignores the
    /// system surface while the titlebar/sidebar continue to adapt correctly.
    func testFixtureRoutesInDarkAppearance() throws {
        let app = try launchFixture(appearance: .dark)
        try verifyAllRoutes(in: app, appearance: .dark)
    }

    /// Covers the native search empty state, record selection, and inspector visibility
    /// without sending a lifecycle or destructive command to the fixture engine.
    func testSearchSelectionAndInspectorUseNativeControls() throws {
        let app = try launchFixture(appearance: .light)

        try selectSidebarRoute("Images", in: app)
        try assertFixtureMarker("postgres", in: app)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(
            search.waitForExistence(timeout: 10),
            "Images must expose the standard searchable toolbar field.")
        search.click()
        search.typeText("no-morbstack-fixture-result")
        XCTAssertTrue(
            app.staticTexts["No Results"].waitForExistence(timeout: 10),
            "An unmatched search must use ContentUnavailableView.search, not an empty custom table.")
        attachWindowEvidence(named: "light-images-search-empty", from: app)

        try selectSidebarRoute("Containers", in: app)
        try assertFixtureMarker("shopfront-api-1", in: app)

        // Clicking a list row is the ordinary selection path; the row is addressed by
        // its engine-facing reference identifier so this cannot accidentally click the
        // same name rendered in the inspector or a log line.
        let row = automationElement("containers.row.shopfront-api-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(
            app.buttons["Overview"].waitForExistence(timeout: 10),
            "Selecting a container must expose its inspector content.")

        // One control, one identifier, two spoken states: `containers.inspector`
        // addresses the toggle across both states, and the label assertions prove the
        // user-facing wording actually flips.
        let inspectorToggle = app.buttons["containers.inspector"]
        XCTAssertTrue(
            inspectorToggle.waitForExistence(timeout: 10),
            "A populated record screen must expose the system inspector toggle.")
        XCTAssertTrue(
            waitForLabel("Hide inspector", on: inspectorToggle),
            "With the inspector visible, the toggle must speak as Hide inspector.")
        inspectorToggle.click()
        XCTAssertTrue(
            waitForLabel("Show inspector", on: inspectorToggle),
            "Hiding the inspector must relabel the toggle, not merely swap a glyph.")
        inspectorToggle.click()
        XCTAssertTrue(waitForLabel("Hide inspector", on: inspectorToggle))
        attachWindowEvidence(named: "light-containers-selection-and-inspector", from: app)
    }

    /// Verifies the built-in View-menu sidebar command.  This deliberately operates the
    /// system command rather than drawing or clicking a custom collapse affordance.
    func testSidebarUsesTheSystemViewMenuCommand() throws {
        let app = try launchFixture(appearance: .light)
        try assertFixtureMarker("shopfront-api-1", in: app)

        // The menu command title is the system's word; the sidebar row identifier is
        // how this test proves the command actually moved the sidebar rather than
        // only relabelling itself.
        let sidebarRow = automationElement("app.sidebar.containers", in: app)
        XCTAssertTrue(
            sidebarRow.waitForExistence(timeout: 10),
            "Every launch starts with the sidebar visible; its rows must be addressable.")

        let firstCommand = try sidebarMenuCommand(in: app)
        let originalTitle = firstCommand.label
        XCTAssertTrue(
            ["Hide Sidebar", "Show Sidebar"].contains(originalTitle),
            "The View menu must expose the standard sidebar command.")
        firstCommand.click()

        if originalTitle == "Hide Sidebar" {
            XCTAssertTrue(
                sidebarRow.waitForNonExistence(timeout: 10),
                "Hide Sidebar must actually remove the sidebar's rows from the window.")
        } else {
            XCTAssertTrue(
                sidebarRow.waitForExistence(timeout: 10),
                "Show Sidebar must actually restore the sidebar's rows.")
        }

        let expectedNextTitle = originalTitle == "Hide Sidebar" ? "Show Sidebar" : "Hide Sidebar"
        let secondCommand = try sidebarMenuCommand(in: app)
        XCTAssertEqual(secondCommand.label, expectedNextTitle)
        attachWindowEvidence(named: "light-sidebar-\(expectedNextTitle.replacingOccurrences(of: " ", with: "-"))", from: app)
        secondCommand.click() // Restore the caller's original sidebar state.
    }

    /// A selected record's trailing inspector must remain recoverable from View when a
    /// narrow window moves its toolbar toggle into system overflow. This exercises the
    /// command registered by `InspectorCommands`, not the route's visible glyph.
    func testSelectedRecordUsesTheSystemViewMenuInspectorCommand() throws {
        let app = try launchFixture(appearance: .light)
        try selectSidebarRoute("Containers", in: app)
        try assertFixtureMarker("shopfront-api-1", in: app)

        let row = automationElement("containers.row.shopfront-api-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let firstCommand = try inspectorMenuCommand(in: app)
        let originalTitle = firstCommand.label
        XCTAssertTrue(
            ["Hide Inspector", "Show Inspector"].contains(originalTitle),
            "The View menu must expose the standard inspector command for a selected record.")
        firstCommand.click()

        let expectedNextTitle = originalTitle == "Hide Inspector" ? "Show Inspector" : "Hide Inspector"
        let secondCommand = try inspectorMenuCommand(in: app)
        XCTAssertEqual(secondCommand.label, expectedNextTitle)
        attachWindowEvidence(
            named: "light-containers-system-inspector-\(expectedNextTitle.replacingOccurrences(of: " ", with: "-"))",
            from: app)
        secondCommand.click() // Restore the caller's original inspector state.
    }

    /// The app has a main operations window and a separate Settings scene, not a
    /// tabbed-document model. Its View menu must not advertise tab commands that have
    /// no meaningful destination.
    func testSingleWindowAppDoesNotAdvertiseWindowTabs() throws {
        let app = try launchFixture(appearance: .light)
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 10))
        viewMenu.click()

        XCTAssertFalse(app.menuItems["Show Tab Bar"].exists)
        XCTAssertFalse(app.menuItems["Show All Tabs"].exists)
    }

    /// Apple supplies a first-party semantic/accessibility audit in XCUIAutomation.
    /// It is separate from screenshot review so failures identify the offending AX
    /// element rather than being mistaken for a subjective image comparison.
    func testFixtureAccessibilityAudit() throws {
        let app = try launchFixture(appearance: .light)

        // Containers is the toolbar-heaviest route and Images carries the pull/tag/run
        // control set. Each audit runs inside a named activity so a failure identifies
        // the route as well as the offending AX element. Identifiers are invisible to
        // this audit by design — only labels can satisfy it.
        try assertFixtureMarker("shopfront-api-1", in: app)
        try XCTContext.runActivity(named: "audit-containers") { _ in
            attachWindowEvidence(named: "light-containers-before-accessibility-audit", from: app)
            try app.performAccessibilityAudit()
        }

        try selectSidebarRoute("Images", in: app)
        try assertFixtureMarker("postgres", in: app)
        try XCTContext.runActivity(named: "audit-images") { _ in
            attachWindowEvidence(named: "light-images-before-accessibility-audit", from: app)
            try app.performAccessibilityAudit()
        }
    }

    /// The load-bearing case for the SP-8 identifier convention: Networks and Volumes
    /// both present a symbol-only destructive trash can. Without identifiers the two
    /// are indistinguishable to automation; with route-scoped identifiers each is
    /// addressable while its spoken label stays distinct product vocabulary.
    func testRouteScopedIdentifiersDisambiguateIdenticalTrashCans() throws {
        let app = try launchFixture(appearance: .light)

        try selectSidebarRoute("Networks", in: app)
        try assertFixtureMarker("morb-ingress", in: app)
        let removeNetworks = app.buttons["networks.removeUnused"]
        XCTAssertTrue(
            removeNetworks.waitForExistence(timeout: 10),
            "The Networks trash can must be addressable by its route-scoped identifier.")
        XCTAssertEqual(
            removeNetworks.label, "Remove unused networks",
            "The identifier addresses the control; the label must keep speaking for it.")

        try selectSidebarRoute("Volumes", in: app)
        try assertFixtureMarker("shopfront_pgdata", in: app)
        let removeVolumes = app.buttons["volumes.removeUnused"]
        XCTAssertTrue(
            removeVolumes.waitForExistence(timeout: 10),
            "The Volumes trash can must be addressable by its route-scoped identifier.")
        XCTAssertEqual(
            removeVolumes.label, "Remove unused volumes",
            "Two identical glyphs must never share a spoken meaning.")
        XCTAssertFalse(
            removeNetworks.exists,
            "Route toolbars must not leak controls into one another's windows.")

        // Cross-route chrome uses the app. scope: the provenance banner is addressable
        // without hard-coding its full sentence.
        XCTAssertTrue(automationElement("app.fixtureBanner", in: app).exists)
    }

    /// Reviews Image pull and run boundaries without making a network request. Fixture
    /// mode deliberately disables tag mutation, while Run stops at its explicit review
    /// instead of manufacturing a container on the developer's daemon.
    func testImageReviewControlsRespectFixtureBoundaries() throws {
        let app = try launchFixture(appearance: .light)
        try selectSidebarRoute("Images", in: app)
        try assertFixtureMarker("postgres", in: app)

        let pull = app.buttons["Pull an image"]
        XCTAssertTrue(pull.waitForExistence(timeout: 10))
        pull.click()
        try assertStaticText("Pull Image", in: app)
        XCTAssertTrue(app.textFields["Reference"].exists)
        XCTAssertFalse(app.buttons["Pull"].isEnabled, "An empty image reference must not start a pull.")
        try cancelPresentedSheet(in: app)

        let image = app.staticTexts["postgres"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.click()
        let tag = app.buttons["Tag Image…"]
        XCTAssertTrue(tag.waitForExistence(timeout: 10))
        XCTAssertFalse(tag.isEnabled, "Fixture data must not offer an invented image-tag mutation.")

        let run = app.buttons["Run selected local image"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        XCTAssertTrue(run.isEnabled, "A selected local fixture image should reach its explicit run review.")
        run.click()
        try assertStaticText("Run Local Image", in: app)
        XCTAssertTrue(app.textFields["Name (Optional)"].exists)
        XCTAssertTrue(app.buttons["Run"].isEnabled)
        try cancelPresentedSheet(in: app)
    }

    /// Creates only review state. The test cancels before Docker's create endpoint, so
    /// it validates the native confirmation boundary without treating fixtures as live
    /// Engine data.
    func testNetworkAndVolumeCreationRequireExplicitConfirmation() throws {
        let app = try launchFixture(appearance: .light)

        try selectSidebarRoute("Networks", in: app)
        try assertFixtureMarker("morb-ingress", in: app)
        let createNetwork = app.buttons["Create network"]
        XCTAssertTrue(createNetwork.waitForExistence(timeout: 10))
        createNetwork.click()
        try assertStaticText("Create Network", in: app)
        let networkName = app.textFields["Name"]
        XCTAssertTrue(networkName.waitForExistence(timeout: 10))
        networkName.typeText("fixture-network")
        app.buttons["Create"].click()
        try assertStaticText("Create fixture-network?", in: app)
        try cancelPresentedConfirmation(in: app)
        try cancelPresentedSheet(in: app)

        try selectSidebarRoute("Volumes", in: app)
        try assertFixtureMarker("shopfront_pgdata", in: app)
        let createVolume = app.buttons["Create volume"]
        XCTAssertTrue(createVolume.waitForExistence(timeout: 10))
        createVolume.click()
        try assertStaticText("Create Volume", in: app)
        let volumeName = app.textFields["Name"]
        XCTAssertTrue(volumeName.waitForExistence(timeout: 10))
        volumeName.typeText("fixture-volume")
        app.buttons["Create"].click()
        try assertStaticText("Create fixture-volume?", in: app)
        try cancelPresentedConfirmation(in: app)
        try cancelPresentedSheet(in: app)

        let volume = app.staticTexts["shopfront_pgdata"]
        XCTAssertTrue(volume.waitForExistence(timeout: 10))
        volume.click()
        let export = app.buttons["Export selected volume"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        XCTAssertTrue(export.isEnabled, "A selected local volume must expose the system export command.")
    }

    /// Selected-network membership commands use native form and confirmation states.
    /// Both mutation points are deliberately cancelled before the fixture client is
    /// asked to change membership.
    func testNetworkMembershipReviewsAreReachableAndCancellable() throws {
        let app = try launchFixture(appearance: .light)
        try selectSidebarRoute("Networks", in: app)
        try assertFixtureMarker("morb-ingress", in: app)

        let network = app.staticTexts["morb-ingress"]
        XCTAssertTrue(network.waitForExistence(timeout: 10))
        network.click()
        let connect = app.buttons["Connect Container…"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertTrue(connect.isEnabled)
        connect.click()
        try assertStaticText("Connect Container", in: app)
        XCTAssertTrue(app.popUpButtons["Container"].exists || app.buttons["Container"].exists)
        XCTAssertTrue(app.textFields["Aliases (optional)"].exists)
        try cancelPresentedSheet(in: app)

        let disconnect = app.buttons["Disconnect Container…"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 10))
        XCTAssertTrue(disconnect.isEnabled)
        disconnect.click()
        let member = app.menuItems["shopfront-web-1"]
        XCTAssertTrue(member.waitForExistence(timeout: 10))
        member.click()
        try assertStaticText("Disconnect shopfront-web-1?", in: app)
        try cancelPresentedConfirmation(in: app)
    }

    /// Exercises the finite exec review plus the fixture client's explicit refusal,
    /// then verifies that log export is exposed as a system-save-panel command without
    /// opening that panel in this deterministic process.
    func testContainerExecAndLogExportRemainExplicitInFixtureMode() throws {
        let app = try launchFixture(appearance: .light)
        try assertFixtureMarker("shopfront-api-1", in: app)

        let container = automationElement("containers.row.shopfront-api-1", in: app)
        XCTAssertTrue(container.waitForExistence(timeout: 10))
        container.click()
        // Addressed by identifier because the spoken label embeds the selected
        // record's name; the label is then asserted as the user-facing contract.
        let runCommand = app.buttons["containers.runCommand"]
        XCTAssertTrue(runCommand.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel("Run command in shopfront-api-1", on: runCommand))
        runCommand.click()
        try assertStaticText("Run Command", in: app)
        let program = app.textFields["containers.execSheet.program"]
        XCTAssertTrue(program.waitForExistence(timeout: 10))
        program.click()
        program.typeText("true")
        app.buttons["containers.execSheet.run"].click()
        try assertStaticText("Couldn’t Run Command", in: app)
        try assertStaticText("Run Command is unavailable in fixture mode; no Docker command was performed.", in: app)
        try dismissPresentedSheet(in: app, button: "Done")

        let logs = app.buttons["Logs"]
        XCTAssertTrue(logs.waitForExistence(timeout: 10))
        logs.click()
        let options = app.buttons["Log options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.click()
        let saveTranscript = app.menuItems["Save Visible Transcript…"]
        XCTAssertTrue(saveTranscript.waitForExistence(timeout: 10))
        XCTAssertTrue(saveTranscript.isEnabled)
    }

    /// UX-1: a log search must not hide the log. Find highlights in place with a
    /// "3 of 47" position and Enter/Shift+Enter stepping; Filter remains an explicit
    /// second mode that hides non-matching lines and says so in the line count.
    /// (Hiding everything but the matching line is OrbStack issue #2178 — a shipped
    /// competitor defect this test exists to keep out.)
    func testLogFindHighlightsInPlaceAndFilterStaysExplicit() throws {
        let app = try launchFixture(appearance: .dark)
        try assertFixtureMarker("shopfront-api-1", in: app)

        let container = automationElement("containers.row.shopfront-api-1", in: app)
        XCTAssertTrue(container.waitForExistence(timeout: 10))
        // Synthesized clicks on the row's static text do not reliably land as a List
        // selection on this macOS build (the standing UI-029/UI-032 observation, which
        // also fails the pre-existing exec test). The row cell and the keyboard are
        // tried in turn; the selected-container toolbar command is the proof that the
        // detail pane actually opened.
        let runCommand = app.buttons["containers.runCommand"]
        let cell = app.cells
            .containing(.staticText, identifier: "containers.row.shopfront-api-1")
            .firstMatch
        for _ in 0..<3 where !runCommand.exists {
            if cell.exists { cell.click() } else { container.click() }
            if runCommand.waitForExistence(timeout: 3) { break }
            // The list carries keyboard focus at launch; arrow keys drive the system
            // List selection directly.
            app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
            _ = runCommand.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(
            runCommand.exists,
            "Selecting the fixture container never opened its detail pane.")

        let logsTab = automationElement("containers.detail.tab.logs", in: app)
        XCTAssertTrue(logsTab.waitForExistence(timeout: 10))
        logsTab.click()

        // The fixture scrollback is deterministic: 412 lines, none dropped.
        // SwiftUI Text reaches accessibility as a static text VALUE (the label is
        // empty), so these waits are value-based, unlike the control label waits.
        let lineCount = automationElement("containers.logs.lineCount", in: app)
        XCTAssertTrue(lineCount.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForValue("412 lines", on: lineCount),
            "The fixture log should present all 412 lines before any query.")

        let search = automationElement("containers.logs.search", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("error")

        // Find mode is the default. The query must not hide a single line…
        XCTAssertTrue(
            waitForValue("412 lines", on: lineCount),
            "A find query hid lines. Context preservation is the whole point of find mode.")

        // …while the position readout reports how many lines match. The element's
        // AX value is its spoken form ("5 matching lines", then "Match 1 of 5").
        let position = automationElement("containers.logs.match.position", in: app)
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let summary = (position.value as? String) ?? ""
        let matchTotal = Int(summary.split(separator: " ").first ?? "") ?? 0
        XCTAssertTrue(
            matchTotal > 0 && summary.hasSuffix(matchTotal == 1 ? "matching line" : "matching lines"),
            "Expected a '<n> matching lines' summary before stepping; got '\(summary)'.")
        probeShot(app, "logs-find-highlight")

        // Enter steps to the first match and the readout becomes positional.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("Match 1 of \(matchTotal)", on: position))
        if matchTotal > 1 {
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            XCTAssertTrue(waitForValue("Match 2 of \(matchTotal)", on: position))
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [.shift])
            XCTAssertTrue(
                waitForValue("Match 1 of \(matchTotal)", on: position),
                "Shift+Enter must step back to the previous match.")
        }
        probeShot(app, "logs-find-stepped")

        // Filter is the explicit second mode: same predicate, so the same count,
        // and the line count states the reduction honestly.
        let modePicker = automationElement("containers.logs.searchMode", in: app)
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
        modePicker.radioButtons["Filter"].click()
        XCTAssertTrue(
            waitForValue("\(matchTotal) of 412 lines", on: lineCount),
            "Filter mode must show exactly the lines the find query matched.")
        XCTAssertFalse(
            position.exists,
            "Stepping has no meaning while non-matching lines are hidden.")
        probeShot(app, "logs-filter-mode")

        // Switching back restores every line without losing the query.
        modePicker.radioButtons["Find"].click()
        XCTAssertTrue(waitForValue("412 lines", on: lineCount))
        XCTAssertTrue(position.waitForExistence(timeout: 10))
    }

    /// VM capacity comes from local Morbstack state, not fixture Docker data. Its
    /// potentially destructive growth controls must therefore remain absent while the
    /// developer fixture banner is active.
    func testFixtureDiskRouteOmitsDiskGrowthActions() throws {
        let app = try launchFixture(appearance: .light)
        try selectSidebarRoute("Disk", in: app)
        try assertFixtureMarker("Build cache", in: app)
        try assertStaticText("VM disk capacity is unavailable in developer fixture data.", in: app)
        XCTAssertFalse(app.buttons["Review Disk Growth…"].exists)
        XCTAssertFalse(app.buttons["Review Disk Recovery…"].exists)
    }

    /// The Stack project menu must present a review before a Compose lifecycle call.
    /// Cancel leaves the fixture collection untouched while checking the selected
    /// project's target count and destructive consequence copy.
    func testComposeLifecycleUsesProjectReviewBeforeMutation() throws {
        let app = try launchFixture(appearance: .light)
        try selectSidebarRoute("Stacks", in: app)
        try assertFixtureMarker("shopfront", in: app)

        let project = app.staticTexts["shopfront"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.click()
        let actions = app.buttons["Actions for shopfront"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.click()
        let stop = app.menuItems["Stop 5 Running Services…"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(stop.isEnabled)
        stop.click()
        try assertStaticText("Stop 5 Running Services?", in: app)
        try assertStaticText("Their containers, images, networks, and named volumes are kept.", in: app)
        try cancelPresentedConfirmation(in: app)
    }

    /// TEMPORARY PROBE — remove after the trailing-toolbar review.
    /// Drives the Volumes inspector toggle and the system sidebar command with rest
    /// pauses between transitions, so an external window-scoped frame recorder can
    /// bracket each animation unambiguously. XCUIScreenshot is far too slow to catch
    /// a ~0.3s transition — the recorder, not this test, produces the evidence.
    func testProbeVolumesTrailingCommandsRideTheInspector() throws {
        let app = try launchFixture(appearance: .dark)
        try selectSidebarRoute("Volumes", in: app)
        try assertFixtureMarker("shopfront_pgdata", in: app)

        // Window-scoped: a stale saved-state launch can restore a second window, and
        // an app-wide query would then match two identical toggles.
        let window = app.windows.firstMatch
        let toggle = window.buttons["volumes.inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["volumes.create"].exists)
        Thread.sleep(forTimeInterval: 3)

        // The leading-edge reference first, via the system key equivalents that
        // SidebarCommands registers — menu traversal is slow enough to outlive the
        // external recorder. Proof each command ran is the sidebar rows' visibility.
        let sidebarRow = automationElement("app.sidebar.containers", in: app)
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10))
        app.typeKey("s", modifierFlags: [.command, .control]) // hide sidebar
        XCTAssertTrue(sidebarRow.waitForNonExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        app.typeKey("s", modifierFlags: [.command, .control]) // show sidebar
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)

        toggle.click() // hide inspector
        XCTAssertTrue(waitForLabel("Show inspector", on: toggle))
        XCTAssertTrue(
            window.buttons["volumes.create"].exists,
            "Create must stay reachable while the inspector is closed.")
        XCTAssertTrue(
            window.searchFields.firstMatch.exists,
            "The search field must stay reachable while the inspector is closed.")
        Thread.sleep(forTimeInterval: 2)

        toggle.click() // show inspector
        XCTAssertTrue(waitForLabel("Hide inspector", on: toggle))
        Thread.sleep(forTimeInterval: 2)
    }

    private var probeDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MORB_PROBE_DIR"] ?? NSTemporaryDirectory())
    }

    private func probeShot(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        let shot = app.windows.firstMatch.screenshot()
        try? shot.pngRepresentation.write(to: probeDirectory.appendingPathComponent("probe-\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "probe-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func probeBurst(_ app: XCUIApplication, _ name: String) {
        for index in 0..<3 {
            probeShot(app, "\(name)-\(index)")
        }
    }

    // MARK: - Fixture launch and route assertions

    private func launchFixture(appearance: Appearance) throws -> XCUIApplication {
        let app = XCUIApplication(url: try appBundleURL())
        app.launchArguments = [
            "--tour-fixtures",
            "--appearance", appearance.rawValue,
            "--window-size", "1440x900",
            // Do not inherit an unrelated person's restored window geometry while
            // taking visual evidence.  AppKit consumes this standard argument; the
            // product's LaunchOptions parser safely ignores it.
            "-ApplePersistenceIgnoreState", "YES",
            // System-provided strings that the test checks (for example No Results and
            // View > Hide Sidebar) must be stable in the test result bundle.
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        launchedApp = app

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 15),
            "The real Morbstack window did not appear. The test must never substitute an offscreen renderer.")

        // Every fixture window must carry its provenance on screen, in a place that
        // survives sidebar collapse and screenshot cropping. A fixture window without
        // this banner has already been mistaken for live evidence once.
        let banner = app.staticTexts["Developer fixtures — not connected to a Docker Engine."]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 10),
            "A --tour-fixtures window must show the non-dismissible fixture provenance banner.")
        return app
    }

    private func verifyAllRoutes(in app: XCUIApplication, appearance: Appearance) throws {
        guard let initialRoute = routes.first else {
            throw HarnessError(message: "The fixture route matrix is unexpectedly empty.")
        }

        try assertFixtureMarker(initialRoute.fixtureMarker, in: app)
        attachWindowEvidence(named: "\(appearance.rawValue)-\(initialRoute.sidebarTitle)", from: app)

        for route in routes.dropFirst() {
            try selectSidebarRoute(route.sidebarTitle, in: app)
            try assertFixtureMarker(route.fixtureMarker, in: app)
            attachWindowEvidence(named: "\(appearance.rawValue)-\(route.sidebarTitle)", from: app)
        }
    }

    private func selectSidebarRoute(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Sidebar rows are addressed by their route-scoped automation identifier
        // (`app.sidebar.<route>`, docs/design/ACCESSIBILITY-IDENTIFIERS.md) rather than
        // by visible title: the detail column's navigation title is often the same
        // word, so `staticTexts["Containers"]` could match outside the sidebar. The
        // user-facing vocabulary stays verified by the fixture marker that must follow
        // every selection.
        let route = automationElement("app.sidebar.\(title.lowercased())", in: app)
        guard route.waitForExistence(timeout: 10) else {
            XCTFail(
                "Sidebar route \(title) is not addressable as app.sidebar.\(title.lowercased()).",
                file: file,
                line: line)
            throw HarnessError(message: "Missing sidebar route \(title).")
        }
        route.click()
    }

    /// Exact-match identifier lookup, deliberately type-agnostic: which element type
    /// SwiftUI's AX bridge surfaces an identifier on is an implementation detail,
    /// while the identifier itself is the app's automation contract
    /// (docs/design/ACCESSIBILITY-IDENTIFIERS.md).
    private func automationElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Waits for a static text's accessibility value. SwiftUI `Text` publishes its
    /// string as the AX value with an empty label, so label-based waits never match.
    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for an element's spoken label. Identifier addresses the control; the
    /// label assertion is what proves the user-facing semantics — see the convention's
    /// rule that tests find by identifier and assert by label.
    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func assertFixtureMarker(
        _ marker: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let markerElement = app.staticTexts[marker]
        guard markerElement.waitForExistence(timeout: 15) else {
            XCTFail(
                "Expected fixture content \(marker) did not appear in the selected route.",
                file: file,
                line: line)
            throw HarnessError(message: "Missing fixture marker \(marker).")
        }
    }

    private func assertStaticText(
        _ value: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let text = app.staticTexts[value]
        guard text.waitForExistence(timeout: 10) else {
            XCTFail("Expected visible text \(value).", file: file, line: line)
            throw HarnessError(message: "Missing visible text \(value).")
        }
    }

    private func cancelPresentedConfirmation(in app: XCUIApplication) throws {
        let cancel = app.buttons["Cancel"].firstMatch
        guard cancel.waitForExistence(timeout: 10) else {
            throw HarnessError(message: "The required confirmation did not expose Cancel.")
        }
        cancel.click()
    }

    private func cancelPresentedSheet(in app: XCUIApplication) throws {
        try dismissPresentedSheet(in: app, button: "Cancel")
    }

    private func dismissPresentedSheet(
        in app: XCUIApplication,
        button: String
    ) throws {
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 10) else {
            throw HarnessError(message: "Expected a document-modal sheet.")
        }
        let action = sheet.buttons[button]
        guard action.waitForExistence(timeout: 10) else {
            throw HarnessError(message: "The sheet did not expose \(button).")
        }
        action.click()
    }

    private func sidebarMenuCommand(in app: XCUIApplication) throws -> XCUIElement {
        let viewMenu = app.menuBars.menuBarItems["View"]
        guard viewMenu.waitForExistence(timeout: 10) else {
            throw HarnessError(message: "The standard View menu is unavailable.")
        }
        viewMenu.click()

        for title in ["Hide Sidebar", "Show Sidebar"] {
            let command = app.menuItems[title]
            if command.waitForExistence(timeout: 3) {
                return command
            }
        }
        throw HarnessError(message: "View menu lacks the standard Show/Hide Sidebar command.")
    }

    private func inspectorMenuCommand(in app: XCUIApplication) throws -> XCUIElement {
        let viewMenu = app.menuBars.menuBarItems["View"]
        guard viewMenu.waitForExistence(timeout: 10) else {
            throw HarnessError(message: "The standard View menu is unavailable.")
        }
        viewMenu.click()

        for title in ["Hide Inspector", "Show Inspector"] {
            let command = app.menuItems[title]
            if command.waitForExistence(timeout: 3) {
                return command
            }
        }
        throw HarnessError(message: "View menu lacks the standard Show/Hide Inspector command.")
    }

    // MARK: - Result evidence

    private func attachWindowEvidence(named name: String, from app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.exists else {
            XCTFail("Cannot attach \(name): the real app window is absent.")
            return
        }

        XCTContext.runActivity(named: name) { activity in
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "\(name).png"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)

            // The matching AX tree makes an image failure actionable without relying
            // on a fake view hierarchy or an opaque coordinate trace.
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(name).accessibility.txt"
            hierarchy.lifetime = .keepAlways
            activity.add(hierarchy)
        }
    }

    private func appBundleURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let rawPath = environment["MORBSTACK_APP_PATH"]
        let candidate: URL

        if let rawPath, !rawPath.isEmpty {
            if rawPath.hasPrefix("/") {
                candidate = URL(fileURLWithPath: rawPath)
            } else {
                candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(rawPath)
            }
        } else {
            // Four parents from this checked-in source file lead to the repository root:
            // MorbstackFixtureUITests → UITests → mac → repository.
            candidate = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("dist/Morbstack.app")
        }

        let standardized = candidate.standardizedFileURL
        let executable = standardized
            .appendingPathComponent("Contents/MacOS/MorbstackApp")
            .path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw HarnessError(
                message: "Morbstack.app is missing at \(standardized.path). Run `mise run app`, then set MORBSTACK_APP_PATH to that bundle.")
        }
        return standardized
    }

    // MARK: - Temporary verification probes (2026-08-05, machine-lane audit)
    //
    // These two deliberately launch WITHOUT --tour-fixtures: both claims under test are
    // about real engine data reaching the real window. They mutate nothing; they click
    // sidebar rows and the inspector toggle and write full-window screenshots to
    // MORB_PROBE_DIR. Delete after the audit.

    func testProbeVolumeUsageAppearsAfterTheDiskScan() throws {
        let app = XCUIApplication(url: try appBundleURL())
        app.launchArguments = [
            "--appearance", "dark",
            "--window-size", "1100x800",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        launchedApp = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 25))

        try selectSidebarRoute("Volumes", in: app)
        Thread.sleep(forTimeInterval: 8)
        probeShot(app, "t4-volumes-cold")

        try selectSidebarRoute("Disk", in: app)
        Thread.sleep(forTimeInterval: 20)
        probeShot(app, "t4-disk")

        try selectSidebarRoute("Volumes", in: app)
        Thread.sleep(forTimeInterval: 10)
        probeShot(app, "t4-volumes-after-disk")
        Thread.sleep(forTimeInterval: 4)
        probeShot(app, "t4-volumes-after-disk-settled")
    }

    func testProbeToolbarClusterAcrossInspectorToggle() throws {
        let app = XCUIApplication(url: try appBundleURL())
        app.launchArguments = [
            "--appearance", "dark",
            "--window-size", "1100x800",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        launchedApp = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: 8)

        let window = app.windows.firstMatch
        let row = automationElement("containers.row.payments-integration-gateway-canary", in: app)
        if row.waitForExistence(timeout: 20) { row.click() }
        Thread.sleep(forTimeInterval: 3)
        probeShot(app, "u51-containers-open")

        let toggle = window.buttons["containers.inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        Thread.sleep(forTimeInterval: 3)
        probeShot(app, "u51-containers-closed")
        toggle.click()
        Thread.sleep(forTimeInterval: 3)
        probeShot(app, "u51-containers-reopened")

        try selectSidebarRoute("Images", in: app)
        Thread.sleep(forTimeInterval: 5)
        probeShot(app, "u51-images-open")
        let imagesToggle = window.buttons["images.inspector"]
        if imagesToggle.waitForExistence(timeout: 10) {
            imagesToggle.click()
            Thread.sleep(forTimeInterval: 3)
            probeShot(app, "u51-images-closed")
        }

        try selectSidebarRoute("Volumes", in: app)
        Thread.sleep(forTimeInterval: 5)
        probeShot(app, "u51-volumes-open")
        let volumesToggle = window.buttons["volumes.inspector"]
        if volumesToggle.waitForExistence(timeout: 10) {
            volumesToggle.click()
            Thread.sleep(forTimeInterval: 3)
            probeShot(app, "u51-volumes-closed")
        }
    }

}
