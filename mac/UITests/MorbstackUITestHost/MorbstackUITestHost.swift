// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// Xcode's macOS UI-test runner requires an application target as its test host.  This
// deliberately empty application supplies that contract only. It has no window or
// product code. It is never the application under inspection: MorbstackFixtureUITests
// launches the shipping bundle explicitly with XCUIApplication(url:).

import AppKit

@main
final class MorbstackUITestHost: NSObject, NSApplicationDelegate {
    private static let hostDelegate = MorbstackUITestHost()

    static func main() {
        let application = NSApplication.shared
        application.delegate = hostDelegate
        application.run()
    }
}
