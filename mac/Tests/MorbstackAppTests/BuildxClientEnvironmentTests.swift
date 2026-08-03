// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackAppCore

final class BuildxClientEnvironmentTests: XCTestCase {

    func testLocalBuildEnvironmentDoesNotInheritRemoteBuilderSelection() {
        let environment = BuildxClientEnvironment.isolatedEnvironment(
            inherited: [
                "BUILDX_BUILDER": "cloud-builder",
                "BUILDKIT_HOST": "tcp://buildkit.example.invalid:1234",
                "BUILDKIT_PROGRESS": "tty",
                "BUILDX_NO_DEFAULT_LOAD": "1",
                "DOCKER_CONTEXT": "remote",
                "DOCKER_HOST": "tcp://docker.example.invalid:2376",
                "PATH": "/usr/bin:/bin",
            ],
            socketPath: "/tmp/morbstack-test.sock",
            dockerConfigDirectory: URL(fileURLWithPath: "/tmp/morbstack-docker-config"),
            buildxConfigDirectory: URL(fileURLWithPath: "/tmp/morbstack-buildx-config"))

        XCTAssertNil(environment["BUILDX_BUILDER"])
        XCTAssertNil(environment["BUILDKIT_HOST"])
        XCTAssertNil(environment["BUILDKIT_PROGRESS"])
        XCTAssertNil(environment["BUILDX_NO_DEFAULT_LOAD"])
        XCTAssertNil(environment["DOCKER_CONTEXT"])
        XCTAssertEqual(environment["DOCKER_HOST"], "unix:///tmp/morbstack-test.sock")
        XCTAssertEqual(environment["DOCKER_CONFIG"], "/tmp/morbstack-docker-config")
        XCTAssertEqual(environment["BUILDX_CONFIG"], "/tmp/morbstack-buildx-config")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    }
}
