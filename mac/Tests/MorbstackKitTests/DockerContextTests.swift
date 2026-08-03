// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation
import XCTest

@testable import MorbstackKit

final class DockerContextTests: XCTestCase {

    func testUsePreservesCredentialConfigSymlinkAndTargetPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("morbstack-context-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDirectory = root.appendingPathComponent(".docker", isDirectory: true)
        let credentialDirectory = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentialDirectory, withIntermediateDirectories: true)

        let credentialConfig = credentialDirectory.appendingPathComponent("config.json", isDirectory: false)
        let config: [String: Any] = [
            "auths": ["registry.example.test": ["auth": "dXNlcjpwYXNz"]],
            "credsStore": "osxkeychain",
            "credHelpers": ["registry.example.test": "osxkeychain"],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: credentialConfig)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: credentialConfig.path)

        let configLink = MorbDockerContext.configFile(dockerConfigDirectory: configDirectory)
        try FileManager.default.createSymbolicLink(at: configLink, withDestinationURL: credentialConfig)

        XCTAssertEqual(
            try MorbDockerContext.use(force: false, environment: ["DOCKER_CONFIG": configDirectory.path]),
            .current)

        var linkMetadata = stat()
        let linkResult = configLink.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &linkMetadata)
        }
        XCTAssertEqual(linkResult, 0)
        XCTAssertEqual(linkMetadata.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: configLink.path), credentialConfig.path)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: credentialConfig)) as? [String: Any]
        XCTAssertEqual(saved?["currentContext"] as? String, MorbDockerContext.name)
        XCTAssertEqual(
            ((saved?["auths"] as? [String: Any])?["registry.example.test"] as? [String: Any])?["auth"] as? String,
            "dXNlcjpwYXNz")
        XCTAssertEqual(saved?["credsStore"] as? String, "osxkeychain")
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: credentialConfig.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
}
