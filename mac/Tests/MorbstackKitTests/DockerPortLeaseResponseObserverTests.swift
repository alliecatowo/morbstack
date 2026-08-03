// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackKit

/// Offline framing coverage for the passive response observer. These checks exercise
/// only parser state; DockerProxy still owns byte-exact relay behavior.
final class DockerPortLeaseResponseObserverTests: XCTestCase {

    func testCreateRecognizesAFragmentedIdentityBearingResponse() {
        var outcomes: [DockerPortLeaseResponseObserver.Outcome] = []
        let observer = DockerPortLeaseResponseObserver(kind: .create) { outcomes.append($0) }
        let body = Data(#"{"Id":"abcdef012345"}"#.utf8)
        let head = Data("HTTP/1.1 201 Created\r\nContent-Length: \(body.count)\r\n\r\n".utf8)

        observer.receive(Data((head + body).prefix(head.count + 7)))
        XCTAssertTrue(outcomes.isEmpty)
        observer.receive(Data((head + body).dropFirst(head.count + 7)))

        XCTAssertEqual(outcomes, [.created(containerID: "abcdef012345")])
    }

    func testCreateRejectsAChunkedSuccessRatherThanGuessingAnIdentity() {
        var outcomes: [DockerPortLeaseResponseObserver.Outcome] = []
        let observer = DockerPortLeaseResponseObserver(kind: .create) { outcomes.append($0) }

        observer.receive(Data("HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))

        XCTAssertEqual(outcomes, [.unrecognized])
    }

    func testStartRequiresDockerDocumented204() {
        var outcomes: [DockerPortLeaseResponseObserver.Outcome] = []
        let observer = DockerPortLeaseResponseObserver(kind: .start) { outcomes.append($0) }

        observer.receive(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))

        XCTAssertEqual(outcomes, [.startSucceeded])
    }

    func testRelayEndWithoutACompleteResponseIsUnrecognized() {
        var outcomes: [DockerPortLeaseResponseObserver.Outcome] = []
        let observer = DockerPortLeaseResponseObserver(kind: .create) { outcomes.append($0) }
        observer.receive(Data("HTTP/1.1 201 Created\r\nContent-Length: 20\r\n\r\n{\"Id\"".utf8))

        observer.relayFinished()

        XCTAssertEqual(outcomes, [.unrecognized])
    }
}
