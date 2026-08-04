// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest

@testable import MorbstackAppCore

/// The command form must preserve Docker's `Cmd` array semantics instead of pretending
/// that a text field can safely reproduce a shell parser.
final class ContainerExecCommandTests: XCTestCase {

    func testBuildsOneLiteralArgumentPerLine() throws {
        let command = try XCTUnwrap(
            ContainerExecCommand(
                program: "  /usr/bin/env  ",
                argumentLines: "-i\nNAME=hello world\nprintf %s\\n"))

        XCTAssertEqual(command.arguments, ["/usr/bin/env", "-i", "NAME=hello world", "printf %s\\n"])
    }

    func testDoesNotSplitShellSyntaxOrWhitespaceInsideAnArgument() throws {
        let command = try XCTUnwrap(
            ContainerExecCommand(
                program: "/bin/sh",
                argumentLines: "-c\necho one && echo two"))

        XCTAssertEqual(command.arguments, ["/bin/sh", "-c", "echo one && echo two"])
    }

    func testKeepsAnExplicitBlankArgument() throws {
        let command = try XCTUnwrap(
            ContainerExecCommand(program: "/bin/printf", argumentLines: "%s\n\nvalue"))

        XCTAssertEqual(command.arguments, ["/bin/printf", "%s", "", "value"])
    }

    func testRejectsBlankAndMultilinePrograms() {
        XCTAssertNil(ContainerExecCommand(program: "  \n  ", argumentLines: ""))
        XCTAssertNil(ContainerExecCommand(program: "/bin/echo\nwhoami", argumentLines: ""))
    }
}
