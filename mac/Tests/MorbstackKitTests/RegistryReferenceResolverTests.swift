// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Pure parsing and fixture-decoding only: reference parsing, tag/token/challenge
// grammar, and response-document decoding. None of this opens a socket or reaches a
// real registry — `tags(for:)`/`platforms(for:tag:)` themselves are not exercised here
// because `RegistryReferenceResolver` has no injectable transport (by design: real
// HTTPS through `URLSession`, no fixture seam). See the task report for what that
// leaves unverified without live network.

import XCTest

@testable import MorbstackKit

// MARK: - RegistryReference parsing

final class RegistryReferenceTests: XCTestCase {

    func testASingleNameResolvesToDockerHubsImplicitLibraryNamespace() throws {
        let reference = try RegistryReference(parsing: "nginx")
        XCTAssertEqual(reference.registryHost, RegistryReference.dockerHubHost)
        XCTAssertEqual(reference.repository, "library/nginx")
        XCTAssertNil(reference.tag)
        // `displayReference` shows the stored `repository` verbatim on Docker Hub —
        // including the now-implicit `library/` this parse added — not a re-stripped
        // short form.
        XCTAssertEqual(reference.displayReference, "library/nginx")
    }

    func testATagIsParsedFromTheLastPathSegmentOnly() throws {
        let reference = try RegistryReference(parsing: "nginx:1.27")
        XCTAssertEqual(reference.repository, "library/nginx")
        XCTAssertEqual(reference.tag, "1.27")
        XCTAssertEqual(reference.displayReference, "library/nginx:1.27")
    }

    func testAnOrgSlashRepoWithNoDotOrColonStaysOnDockerHub() throws {
        // "nginx" does not look like a host (no `.`, no `:`, not `localhost`), so this
        // is Docker Hub's `nginx/nginx` org repository, not a custom registry host.
        let reference = try RegistryReference(parsing: "nginx/nginx")
        XCTAssertEqual(reference.registryHost, RegistryReference.dockerHubHost)
        XCTAssertEqual(reference.repository, "nginx/nginx")
        XCTAssertEqual(reference.displayReference, "nginx/nginx")
    }

    func testAHostWithADotIsRecognizedAsAnExplicitRegistry() throws {
        let reference = try RegistryReference(parsing: "ghcr.io/owner/repo:tag")
        XCTAssertEqual(reference.registryHost, "ghcr.io")
        XCTAssertEqual(reference.repository, "owner/repo")
        XCTAssertEqual(reference.tag, "tag")
        XCTAssertEqual(reference.displayReference, "ghcr.io/owner/repo:tag")
    }

    func testAHostPortIsNotMistakenForATagDelimiter() throws {
        let reference = try RegistryReference(parsing: "registry.example.com:5000/owner/repo:tag")
        XCTAssertEqual(reference.registryHost, "registry.example.com:5000")
        XCTAssertEqual(reference.repository, "owner/repo")
        XCTAssertEqual(reference.tag, "tag")
    }

    func testAHostPortWithNoTagIsStillRecognizedAsAHost() throws {
        let reference = try RegistryReference(parsing: "registry.example.com:5000/repo")
        XCTAssertEqual(reference.registryHost, "registry.example.com:5000")
        XCTAssertEqual(reference.repository, "repo")
        XCTAssertNil(reference.tag)
    }

    func testLocalhostIsRecognizedAsAHostByName() throws {
        let reference = try RegistryReference(parsing: "localhost/foo")
        XCTAssertEqual(reference.registryHost, "localhost")
        XCTAssertEqual(reference.repository, "foo")
    }

    func testDigestReferencesAreRejectedAsUnsupported() {
        XCTAssertThrowsError(try RegistryReference(parsing: "nginx@sha256:" + String(repeating: "a", count: 64))) {
            error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .invalidReference)
        }
    }

    func testAnEmptyOrWhitespaceOnlyReferenceIsRejected() {
        XCTAssertThrowsError(try RegistryReference(parsing: "")) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .invalidReference)
        }
        XCTAssertThrowsError(try RegistryReference(parsing: "   "))
    }

    func testAControlCharacterInTheReferenceIsRejected() {
        XCTAssertThrowsError(try RegistryReference(parsing: "nginx\n:latest"))
        XCTAssertThrowsError(try RegistryReference(parsing: "ng\u{0}inx"))
    }

    func testAnOverlongReferenceIsRejected() {
        let long = String(repeating: "a", count: 400)
        XCTAssertThrowsError(try RegistryReference(parsing: long))
    }

    func testAnInvalidTagIsRejectedAtParseTime() {
        XCTAssertThrowsError(try RegistryReference(parsing: "nginx:not a tag")) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .invalidReference)
        }
    }
}

// MARK: - Tag grammar

final class RegistryReferenceResolverTagTests: XCTestCase {

    func testValidTags() {
        for good in ["latest", "1.27.0", "v1_2-3", "_leading-underscore"] {
            XCTAssertTrue(RegistryReferenceResolver.isValidTag(good), good)
        }
    }

    func testInvalidTags() {
        XCTAssertFalse(RegistryReferenceResolver.isValidTag(""))
        XCTAssertFalse(RegistryReferenceResolver.isValidTag(".leading-dot"))
        XCTAssertFalse(RegistryReferenceResolver.isValidTag("-leading-dash"))
        XCTAssertFalse(RegistryReferenceResolver.isValidTag("has space"))
        XCTAssertFalse(RegistryReferenceResolver.isValidTag("has/slash"))
        XCTAssertFalse(RegistryReferenceResolver.isValidTag(String(repeating: "a", count: 129)))
    }

    func testValidBearerTokenCharset() {
        XCTAssertTrue(RegistryReferenceResolver.isSafeBearerToken("abc.DEF-123_456+/=="))
    }

    func testInvalidBearerTokenCharset() {
        XCTAssertFalse(RegistryReferenceResolver.isSafeBearerToken(""))
        XCTAssertFalse(RegistryReferenceResolver.isSafeBearerToken("has space"))
        XCTAssertFalse(RegistryReferenceResolver.isSafeBearerToken("has\nnewline"))
        XCTAssertFalse(RegistryReferenceResolver.isSafeBearerToken(String(repeating: "a", count: 8_193)))
    }
}

// MARK: - WWW-Authenticate: Bearer challenge parsing

final class RegistryReferenceResolverChallengeTests: XCTestCase {

    func testParsesAWellFormedChallenge() throws {
        let header = #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/nginx:pull""#
        let challenge = try RegistryReferenceResolver.parseBearerChallenge(header)
        XCTAssertEqual(challenge.realm, "https://auth.docker.io/token")
        XCTAssertEqual(challenge.service, "registry.docker.io")
        XCTAssertEqual(challenge.scope, "repository:library/nginx:pull")
    }

    func testParsesAChallengeWithNoServiceOrScope() throws {
        let header = #"Bearer realm="https://auth.example.com/token""#
        let challenge = try RegistryReferenceResolver.parseBearerChallenge(header)
        XCTAssertEqual(challenge.realm, "https://auth.example.com/token")
        XCTAssertNil(challenge.service)
        XCTAssertNil(challenge.scope)
    }

    func testRejectsAChallengeMissingTheBearerScheme() {
        let header = #"Basic realm="https://auth.example.com/token""#
        XCTAssertThrowsError(try RegistryReferenceResolver.parseBearerChallenge(header)) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedChallenge)
        }
    }

    func testRejectsANonHTTPSRealm() {
        // The token endpoint's realm is a value from an untrusted response and becomes
        // a request destination; only `https` is accepted, matching the file header's
        // stated discipline.
        let header = #"Bearer realm="http://auth.example.com/token""#
        XCTAssertThrowsError(try RegistryReferenceResolver.parseBearerChallenge(header)) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedChallenge)
        }
    }

    func testRejectsARealmWithNoHost() {
        let header = #"Bearer realm="https:///token""#
        XCTAssertThrowsError(try RegistryReferenceResolver.parseBearerChallenge(header))
    }

    func testRejectsAChallengeMissingARealm() {
        let header = #"Bearer service="registry.docker.io""#
        XCTAssertThrowsError(try RegistryReferenceResolver.parseBearerChallenge(header)) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedChallenge)
        }
    }

    func testRejectsAnOverlongChallenge() {
        let header = "Bearer realm=\"" + String(repeating: "a", count: 5_000) + "\""
        XCTAssertThrowsError(try RegistryReferenceResolver.parseBearerChallenge(header))
    }
}

// MARK: - Token response decoding

final class RegistryReferenceResolverTokenTests: XCTestCase {

    func testExtractsTheModernTokenField() throws {
        let body = Data(#"{"token":"abc.def-123"}"#.utf8)
        XCTAssertEqual(try RegistryReferenceResolver.extractBearerToken(from: body), "abc.def-123")
    }

    func testFallsBackToTheLegacyAccessTokenField() throws {
        let body = Data(#"{"access_token":"xyz.789"}"#.utf8)
        XCTAssertEqual(try RegistryReferenceResolver.extractBearerToken(from: body), "xyz.789")
    }

    func testPrefersTokenOverAccessTokenWhenBothArePresent() throws {
        let body = Data(#"{"token":"preferred","access_token":"ignored"}"#.utf8)
        XCTAssertEqual(try RegistryReferenceResolver.extractBearerToken(from: body), "preferred")
    }

    func testRejectsAResponseWithNeitherField() {
        let body = Data(#"{"other":"value"}"#.utf8)
        XCTAssertThrowsError(try RegistryReferenceResolver.extractBearerToken(from: body)) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedTokenResponse)
        }
    }

    func testRejectsNonJSONBodies() {
        XCTAssertThrowsError(try RegistryReferenceResolver.extractBearerToken(from: Data("not json".utf8)))
    }

    func testRejectsATokenWithUnsafeCharacters() {
        let body = Data(#"{"token":"has space"}"#.utf8)
        XCTAssertThrowsError(try RegistryReferenceResolver.extractBearerToken(from: body)) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedTokenResponse)
        }
    }
}

// MARK: - Tags-list document decoding

final class RegistryReferenceResolverTagsDocumentTests: XCTestCase {

    private func reference() throws -> RegistryReference {
        try RegistryReference(parsing: "nginx")
    }

    func testDecodesAnOrdinaryTagsList() throws {
        let body = Data(#"{"name":"library/nginx","tags":["1.27","1.26","latest"]}"#.utf8)
        let page = try RegistryReferenceResolver.tagPage(from: body, reference: try reference(), linkHeader: nil)
        XCTAssertEqual(page.tags, ["1.27", "1.26", "latest"])
        XCTAssertFalse(page.hasMoreTags)
    }

    func testAMissingTagsFieldDecodesAsAnEmptyPageRatherThanThrowing() throws {
        let body = Data(#"{"name":"library/nginx"}"#.utf8)
        let page = try RegistryReferenceResolver.tagPage(from: body, reference: try reference(), linkHeader: nil)
        XCTAssertEqual(page.tags, [])
        XCTAssertFalse(page.hasMoreTags)
    }

    func testMoreTagsThanTheMaximumPageIsTruncatedAndFlagged() throws {
        let tags = (0..<(RegistryReferenceResolver.maximumTags + 10)).map { "t\($0)" }
        let body = try JSONSerialization.data(withJSONObject: ["name": "library/nginx", "tags": tags])
        let page = try RegistryReferenceResolver.tagPage(from: body, reference: try reference(), linkHeader: nil)
        XCTAssertEqual(page.tags.count, RegistryReferenceResolver.maximumTags)
        XCTAssertTrue(page.hasMoreTags)
    }

    func testALinkHeaderWithRelNextFlagsMoreTagsEvenUnderTheLimit() throws {
        let body = Data(#"{"name":"library/nginx","tags":["1.27"]}"#.utf8)
        let page = try RegistryReferenceResolver.tagPage(
            from: body, reference: try reference(), linkHeader: #"</v2/library/nginx/tags/list?n=1&last=1.27>; rel="next""#)
        XCTAssertTrue(page.hasMoreTags)
    }

    func testMalformedTagsDocumentsThrow() {
        XCTAssertThrowsError(
            try RegistryReferenceResolver.tagPage(
                from: Data("not json".utf8), reference: try! reference(), linkHeader: nil)
        ) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedResponse)
        }
    }
}

// MARK: - Manifest platform-list decoding

final class RegistryReferenceResolverPlatformTests: XCTestCase {

    func testASingleArchitectureManifestReportsItIsNotMultiPlatformRatherThanEmptyPlatforms() throws {
        let body = Data(#"{"schemaVersion":2,"config":{}}"#.utf8)
        let resolution = try RegistryReferenceResolver.platformResolution(
            from: body, contentType: "application/vnd.docker.distribution.manifest.v2+json", tag: "latest",
            digest: "sha256:abc")
        XCTAssertFalse(resolution.isMultiPlatform)
        XCTAssertEqual(resolution.platforms, [])
        XCTAssertEqual(resolution.manifestDigest, "sha256:abc")
    }

    func testADockerManifestListDecodesEveryPlatform() throws {
        let body = Data(
            #"""
            {"manifests":[
              {"platform":{"os":"linux","architecture":"amd64"}},
              {"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}
            ]}
            """#.utf8)
        let resolution = try RegistryReferenceResolver.platformResolution(
            from: body, contentType: "application/vnd.docker.distribution.manifest.list.v2+json", tag: "latest",
            digest: nil)
        XCTAssertTrue(resolution.isMultiPlatform)
        XCTAssertEqual(resolution.platforms.count, 2)
        XCTAssertTrue(resolution.platforms.contains(RegistryPlatform(os: "linux", architecture: "amd64", variant: nil)))
        XCTAssertTrue(
            resolution.platforms.contains(RegistryPlatform(os: "linux", architecture: "arm64", variant: "v8")))
    }

    func testAnOCIImageIndexIsRecognizedTheSameAsADockerManifestList() throws {
        let body = Data(#"{"manifests":[{"platform":{"os":"linux","architecture":"arm64"}}]}"#.utf8)
        let resolution = try RegistryReferenceResolver.platformResolution(
            from: body, contentType: "application/vnd.oci.image.index.v1+json", tag: "latest", digest: nil)
        XCTAssertTrue(resolution.isMultiPlatform)
        XCTAssertEqual(resolution.platforms, [RegistryPlatform(os: "linux", architecture: "arm64", variant: nil)])
    }

    func testAttestationAndSBOMManifestsAreFilteredOutAsUnknownUnknown() throws {
        let body = Data(
            #"""
            {"manifests":[
              {"platform":{"os":"linux","architecture":"arm64"}},
              {"platform":{"os":"unknown","architecture":"unknown"}}
            ]}
            """#.utf8)
        let resolution = try RegistryReferenceResolver.platformResolution(
            from: body, contentType: "application/vnd.docker.distribution.manifest.list.v2+json", tag: "latest",
            digest: nil)
        XCTAssertEqual(resolution.platforms, [RegistryPlatform(os: "linux", architecture: "arm64", variant: nil)])
    }

    func testShortNameOmitsTheVariantWhenThereIsNone() {
        XCTAssertEqual(RegistryPlatform(os: "linux", architecture: "arm64", variant: nil).shortName, "arm64")
        XCTAssertEqual(RegistryPlatform(os: "linux", architecture: "arm", variant: "v7").shortName, "arm/v7")
    }

    func testMalformedManifestListBodiesThrowRatherThanReportingEmptyPlatforms() {
        XCTAssertThrowsError(
            try RegistryReferenceResolver.platformResolution(
                from: Data("not json".utf8),
                contentType: "application/vnd.docker.distribution.manifest.list.v2+json", tag: "latest", digest: nil)
        ) { error in
            XCTAssertEqual(error as? RegistryReferenceResolverFailure, .malformedResponse)
        }
    }
}
