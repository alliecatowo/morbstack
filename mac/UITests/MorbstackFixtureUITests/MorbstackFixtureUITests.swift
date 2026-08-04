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

        // Clicking a table row is the ordinary selection path; it should select the
        // record and make the standard inspector describe it.
        let rowText = app.staticTexts["shopfront-api-1"]
        XCTAssertTrue(rowText.waitForExistence(timeout: 10))
        rowText.click()
        XCTAssertTrue(
            app.buttons["Overview"].waitForExistence(timeout: 10),
            "Selecting a container must expose its inspector content.")

        let hideInspector = app.buttons["Hide inspector"]
        XCTAssertTrue(
            hideInspector.waitForExistence(timeout: 10),
            "A populated record screen must expose the system inspector toggle.")
        hideInspector.click()

        let showInspector = app.buttons["Show inspector"]
        XCTAssertTrue(showInspector.waitForExistence(timeout: 10))
        showInspector.click()
        XCTAssertTrue(hideInspector.waitForExistence(timeout: 10))
        attachWindowEvidence(named: "light-containers-selection-and-inspector", from: app)
    }

    /// Verifies the built-in View-menu sidebar command.  This deliberately operates the
    /// system command rather than drawing or clicking a custom collapse affordance.
    func testSidebarUsesTheSystemViewMenuCommand() throws {
        let app = try launchFixture(appearance: .light)
        try assertFixtureMarker("shopfront-api-1", in: app)

        let firstCommand = try sidebarMenuCommand(in: app)
        let originalTitle = firstCommand.label
        XCTAssertTrue(
            ["Hide Sidebar", "Show Sidebar"].contains(originalTitle),
            "The View menu must expose the standard sidebar command.")
        firstCommand.click()

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

        let row = app.staticTexts["shopfront-api-1"]
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
        try selectSidebarRoute("Images", in: app)
        try assertFixtureMarker("postgres", in: app)
        attachWindowEvidence(named: "light-images-before-accessibility-audit", from: app)
        try app.performAccessibilityAudit()
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
        // NavigationSplitView's sidebar is exposed as standard static text by SwiftUI
        // on current macOS.  The visible title is deliberate product vocabulary; no
        // hidden testing-only identifier is introduced into the shipping UI.
        let route = app.staticTexts[title]
        guard route.waitForExistence(timeout: 10) else {
            XCTFail("Could not find sidebar route \(title).", file: file, line: line)
            throw HarnessError(message: "Missing sidebar route \(title).")
        }
        route.click()
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
}
