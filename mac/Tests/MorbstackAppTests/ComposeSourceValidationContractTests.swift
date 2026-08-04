// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackAppCore

final class ComposeSourceValidationContractTests: XCTestCase {

    func testValidationUsesOnlyTheSavedDocumentAndNonrenderingConfigFlags() {
        let source = URL(fileURLWithPath: "/Projects/example/compose.yaml")

        XCTAssertEqual(
            ComposeSourceValidationRunner.arguments(for: source),
            [
                "--project-directory", "/Projects/example",
                "-f", "/Projects/example/compose.yaml",
                "config",
                "--quiet",
                "--no-interpolate",
                "--no-env-resolution",
                "--no-path-resolution",
            ])
    }

    func testValidationEnvironmentUsesOnlyMorbstackSocketAndPrivateConfiguration() {
        let values = ComposeSourceValidationEnvironment.values(
            socketPath: "/tmp/morbstack/docker.sock",
            homeDirectoryPath: "/tmp/morbstack/validate")

        XCTAssertEqual(values["DOCKER_HOST"], "unix:///tmp/morbstack/docker.sock")
        XCTAssertEqual(values["DOCKER_CONFIG"], "/tmp/morbstack/validate")
        XCTAssertEqual(values["HOME"], "/tmp/morbstack/validate")
        XCTAssertEqual(values["COMPOSE_DISABLE_ENV_FILE"], "1")
        XCTAssertEqual(values["COMPOSE_ANSI"], "never")
        XCTAssertEqual(values["COMPOSE_PROGRESS"], "plain")
        XCTAssertEqual(values["COMPOSE_MENU"], "0")
        XCTAssertEqual(
            Set(values.keys),
            Set([
                "PATH", "HOME", "DOCKER_HOST", "DOCKER_CONFIG",
                "COMPOSE_DISABLE_ENV_FILE", "COMPOSE_ANSI", "COMPOSE_PROGRESS", "COMPOSE_MENU",
                "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT",
                "GIT_ASKPASS", "SSH_ASKPASS", "GIT_SSH_COMMAND",
            ]))

        for forbidden in [
            "DOCKER_CONTEXT", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY",
            "COMPOSE_FILE", "COMPOSE_ENV_FILES", "HTTP_PROXY", "HTTPS_PROXY",
            "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy",
            "no_proxy", "SSH_AUTH_SOCK",
        ] {
            XCTAssertNil(values[forbidden], "Validation must not inherit \(forbidden).")
        }
    }
}
