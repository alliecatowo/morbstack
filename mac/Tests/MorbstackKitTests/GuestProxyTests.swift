// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Coverage for UX-18 (proxy support): reading the Mac's system proxy,
/// resolving Morbstack's config override on top of it, and the kernel-
/// command-line encoding that carries the decision to the guest.
///
/// `guest/morbinit/src/guest_proxy.rs` holds the mirror-image suite for the
/// command-line codec; the two are held together the same way
/// `SharesTests`/`shares.rs` are.
final class GuestProxyTests: XCTestCase {

    // MARK: - HostProxyConfiguration.parse

    func testEmptyDictionaryParsesToEverythingOff() {
        let config = HostProxyConfiguration.parse([:])
        XCTAssertEqual(config, HostProxyConfiguration())
        XCTAssertNil(config.httpProxyURL)
        XCTAssertNil(config.httpsProxyURL)
        XCTAssertNil(config.socksProxyURL)
    }

    func testParsesAnHTTPAndHTTPSProxy() {
        let proxies: [String: Any] = [
            "HTTPEnable": NSNumber(value: 1),
            "HTTPProxy": "proxy.corp.example",
            "HTTPPort": NSNumber(value: 8080),
            "HTTPSEnable": NSNumber(value: 1),
            "HTTPSProxy": "proxy.corp.example",
            "HTTPSPort": NSNumber(value: 8443),
        ]
        let config = HostProxyConfiguration.parse(proxies)
        XCTAssertEqual(config.httpProxyURL, "http://proxy.corp.example:8080")
        // Note the scheme: this is the URL used to *reach the proxy itself*, not
        // the scheme of the traffic being proxied — see the doc comment on
        // `httpsProxyURL`.
        XCTAssertEqual(config.httpsProxyURL, "http://proxy.corp.example:8443")
    }

    func testEnabledFlagGatesTheURLEvenWithAHostConfigured() {
        // A host left over from a proxy the user has since turned off, without
        // clearing the hostname field — a real macOS UI state.
        let proxies: [String: Any] = [
            "HTTPEnable": NSNumber(value: 0),
            "HTTPProxy": "stale.example",
            "HTTPPort": NSNumber(value: 8080),
        ]
        XCTAssertNil(HostProxyConfiguration.parse(proxies).httpProxyURL)
    }

    func testMissingPortOmitsItFromTheURL() {
        let proxies: [String: Any] = [
            "HTTPEnable": NSNumber(value: 1),
            "HTTPProxy": "proxy.example",
        ]
        XCTAssertEqual(HostProxyConfiguration.parse(proxies).httpProxyURL, "http://proxy.example")
    }

    func testOutOfRangePortIsTreatedAsAbsent() {
        let proxies: [String: Any] = [
            "HTTPEnable": NSNumber(value: 1),
            "HTTPProxy": "proxy.example",
            "HTTPPort": NSNumber(value: 999_999),
        ]
        XCTAssertEqual(HostProxyConfiguration.parse(proxies).httpProxyURL, "http://proxy.example")
    }

    func testParsesASOCKSProxyWithARealScheme() {
        let proxies: [String: Any] = [
            "SOCKSEnable": NSNumber(value: 1),
            "SOCKSProxy": "socks.corp.example",
            "SOCKSPort": NSNumber(value: 1080),
        ]
        XCTAssertEqual(
            HostProxyConfiguration.parse(proxies).socksProxyURL, "socks5://socks.corp.example:1080")
    }

    func testParsesTheExceptionsList() {
        let proxies: [String: Any] = ["ExceptionsList": ["localhost", "127.0.0.1", "*.internal"]]
        XCTAssertEqual(
            HostProxyConfiguration.parse(proxies).exceptionsList, ["localhost", "127.0.0.1", "*.internal"])
    }

    func testParsesPACAndAutoDiscoveryFlags() {
        let pac: [String: Any] = [
            "ProxyAutoConfigEnable": NSNumber(value: 1),
            "ProxyAutoConfigURLString": "https://example.com/proxy.pac",
        ]
        let parsedPAC = HostProxyConfiguration.parse(pac)
        XCTAssertTrue(parsedPAC.autoConfigEnabled)
        XCTAssertEqual(parsedPAC.autoConfigURLString, "https://example.com/proxy.pac")

        let wpad: [String: Any] = ["ProxyAutoDiscoveryEnable": NSNumber(value: 1)]
        XCTAssertTrue(HostProxyConfiguration.parse(wpad).autoDiscoveryEnabled)
    }

    func testWrongShapedValuesAreTreatedAsAbsentRatherThanThrown() {
        // A dictionary of unknown provenance: numbers where strings are expected
        // and vice versa. Must not crash `morb doctor`.
        let malformed: [String: Any] = [
            "HTTPEnable": "not-a-bool",
            "HTTPProxy": NSNumber(value: 1),
            "HTTPPort": "not-a-number",
        ]
        XCTAssertEqual(HostProxyConfiguration.parse(malformed), HostProxyConfiguration())
    }

    // MARK: - effectiveGuestProxy

    func testDisabledConfigYieldsNothingRegardlessOfTheHost() {
        var config = MorbConfig()
        config.proxyEnabled = false
        let host = HostProxyConfiguration(httpEnabled: true, httpHost: "proxy.example", httpPort: 8080)
        let effective = config.effectiveGuestProxy(host: host)
        XCTAssertTrue(effective.isEmpty)
        XCTAssertFalse(effective.pacOnly)
    }

    func testInheritsTheHostsHTTPAndHTTPSProxyByDefault() {
        let host = HostProxyConfiguration(
            httpEnabled: true, httpHost: "proxy.example", httpPort: 8080,
            httpsEnabled: true, httpsHost: "proxy.example", httpsPort: 8443,
            exceptionsList: ["localhost", "*.internal"])
        let effective = MorbConfig().effectiveGuestProxy(host: host)
        XCTAssertEqual(effective.httpProxy, "http://proxy.example:8080")
        XCTAssertEqual(effective.httpsProxy, "http://proxy.example:8443")
        XCTAssertEqual(effective.noProxy, "localhost,*.internal")
        XCTAssertFalse(effective.pacOnly)
    }

    func testExplicitOverrideWinsOverTheHost() {
        var config = MorbConfig()
        config.httpProxyOverride = "http://override.example:9090"
        let host = HostProxyConfiguration(httpEnabled: true, httpHost: "proxy.example", httpPort: 8080)
        XCTAssertEqual(config.effectiveGuestProxy(host: host).httpProxy, "http://override.example:9090")
    }

    func testEmptyOverrideStringFallsBackToTheHost() {
        var config = MorbConfig()
        config.httpProxyOverride = ""
        let host = HostProxyConfiguration(httpEnabled: true, httpHost: "proxy.example", httpPort: 8080)
        XCTAssertEqual(config.effectiveGuestProxy(host: host).httpProxy, "http://proxy.example:8080")
    }

    func testNoProxyOverrideDoesNotBypassEverything() {
        // An explicit `no_proxy = ""` in config.toml means "use the Mac's
        // exceptions list", not "bypass nothing" — same convention as every
        // other empty-string override in MorbConfig.
        var config = MorbConfig()
        config.noProxyOverride = ""
        let host = HostProxyConfiguration(exceptionsList: ["localhost"])
        XCTAssertEqual(config.effectiveGuestProxy(host: host).noProxy, "localhost")
    }

    func testSOCKSFillsInWhenNoStaticHTTPOrHTTPSProxyIsConfigured() {
        let host = HostProxyConfiguration(socksEnabled: true, socksHost: "socks.example", socksPort: 1080)
        let effective = MorbConfig().effectiveGuestProxy(host: host)
        XCTAssertEqual(effective.httpProxy, "socks5://socks.example:1080")
        XCTAssertEqual(effective.httpsProxy, "socks5://socks.example:1080")
    }

    func testStaticHTTPProxyIsPreferredOverSOCKS() {
        let host = HostProxyConfiguration(
            httpEnabled: true, httpHost: "proxy.example", httpPort: 8080,
            socksEnabled: true, socksHost: "socks.example", socksPort: 1080)
        XCTAssertEqual(
            MorbConfig().effectiveGuestProxy(host: host).httpProxy, "http://proxy.example:8080")
    }

    func testPACOnlyIsDetectedWhenNothingElseIsConfigured() {
        let host = HostProxyConfiguration(
            autoConfigEnabled: true, autoConfigURLString: "https://example.com/proxy.pac")
        let effective = MorbConfig().effectiveGuestProxy(host: host)
        XCTAssertTrue(effective.pacOnly)
        XCTAssertEqual(effective.pacURLString, "https://example.com/proxy.pac")
        XCTAssertTrue(effective.isEmpty)
    }

    func testAutoDiscoveryAloneAlsoCountsAsPACOnly() {
        let host = HostProxyConfiguration(autoDiscoveryEnabled: true)
        XCTAssertTrue(MorbConfig().effectiveGuestProxy(host: host).pacOnly)
    }

    func testAnExplicitOverrideSuppressesThePACOnlyWarning() {
        // A PAC script *and* an explicit config.toml override: the override is
        // an intentional escape hatch and must win outright, not merely
        // supply one of the two fields while still flagging PAC-only.
        var config = MorbConfig()
        config.httpProxyOverride = "http://override.example:9090"
        let host = HostProxyConfiguration(
            autoConfigEnabled: true, autoConfigURLString: "https://example.com/proxy.pac")
        let effective = config.effectiveGuestProxy(host: host)
        XCTAssertFalse(effective.pacOnly)
        XCTAssertEqual(effective.httpProxy, "http://override.example:9090")
    }

    func testAStaticProxyAlongsidePACIsNotFlaggedPACOnly() {
        // Some corporate networks configure both a fallback static proxy and a
        // PAC script. The static proxy is usable, so this is not the "we have
        // nothing to offer" state PACOnly exists to name.
        let host = HostProxyConfiguration(
            httpEnabled: true, httpHost: "proxy.example", httpPort: 8080,
            autoConfigEnabled: true, autoConfigURLString: "https://example.com/proxy.pac")
        XCTAssertFalse(MorbConfig().effectiveGuestProxy(host: host).pacOnly)
    }

    // MARK: - MorbGuestProxy cmdline codec

    func testNoProxyFieldsProduceNoArguments() {
        XCTAssertEqual(MorbGuestProxy.cmdlineArguments(for: GuestProxyConfiguration()), [])
        XCTAssertEqual(
            try MorbGuestProxy.appendToCmdline("console=hvc0", proxy: GuestProxyConfiguration()),
            "console=hvc0")
    }

    func testRoundTripsAFullProxyConfiguration() throws {
        let proxy = GuestProxyConfiguration(
            httpProxy: "http://proxy.corp.example:8080",
            httpsProxy: "http://user:pass@proxy.corp.example:8443",
            noProxy: "localhost,127.0.0.1,.corp.example")
        let cmdline = try MorbGuestProxy.appendToCmdline("console=hvc0", proxy: proxy)
        XCTAssertEqual(MorbGuestProxy.parseCmdline(cmdline), proxy)
    }

    func testCoexistsWithShareArgumentsOnTheSameCommandLine() throws {
        let shares = [MorbDirectoryShare(tag: "morbshare0", path: "/Users")]
        let proxy = GuestProxyConfiguration(httpProxy: "http://proxy.example:8080")
        let base = try MorbShares.appendToCmdline("console=hvc0 rdinit=/init", shares: shares)
        let cmdline = try MorbGuestProxy.appendToCmdline(base, proxy: proxy)
        XCTAssertEqual(MorbShares.parseCmdline(cmdline), shares)
        XCTAssertEqual(MorbGuestProxy.parseCmdline(cmdline).httpProxy, proxy.httpProxy)
    }

    func testOverLengthCommandLineThrowsRatherThanSilentlyTruncating() {
        let proxy = GuestProxyConfiguration(noProxy: String(repeating: "a", count: 4096))
        XCTAssertThrowsError(try MorbGuestProxy.appendToCmdline("console=hvc0", proxy: proxy)) { error in
            guard case MorbError.config = error else {
                return XCTFail("expected MorbError.config, got \(error)")
            }
        }
    }

    func testMalformedTokensAreSkippedRatherThanFatal() {
        let cmdline = "morb.proxy morb.proxy=noseparator morb.proxy=bogus:val "
            + "morb.proxy=http:http%3A//ok%3A80"
        let proxy = MorbGuestProxy.parseCmdline(cmdline)
        XCTAssertEqual(proxy.httpProxy, "http://ok:80")
        XCTAssertNil(proxy.httpsProxy)
        XCTAssertNil(proxy.noProxy)
    }

    func testLastOccurrenceOfAFieldWins() {
        let cmdline = "morb.proxy=http:http%3A//first%3A80 morb.proxy=http:http%3A//second%3A80"
        XCTAssertEqual(MorbGuestProxy.parseCmdline(cmdline).httpProxy, "http://second:80")
    }

    // MARK: - Doctor checks

    func testProxyConfigCheckReportsTheOffSwitch() {
        var config = MorbConfig()
        config.proxyEnabled = false
        let check = Doctor.proxyConfigCheck(config: config, effectiveProxy: GuestProxyConfiguration())
        XCTAssertEqual(check.status, .info)
        XCTAssertTrue(check.detail.contains("proxy_enabled = false"))
    }

    func testProxyConfigCheckWarnsOnPACOnly() {
        let effective = GuestProxyConfiguration(
            pacOnly: true, pacURLString: "https://example.com/proxy.pac")
        let check = Doctor.proxyConfigCheck(config: MorbConfig(), effectiveProxy: effective)
        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.detail.contains("proxy.pac"))
        XCTAssertTrue(check.detail.lowercased().contains("cannot evaluate"))
    }

    func testProxyConfigCheckReportsNothingConfigured() {
        let check = Doctor.proxyConfigCheck(config: MorbConfig(), effectiveProxy: GuestProxyConfiguration())
        XCTAssertEqual(check.status, .info)
        XCTAssertTrue(check.detail.contains("no proxy configured"))
    }

    func testProxyConfigCheckPassesWhenAProxyWillBeConfigured() {
        let effective = GuestProxyConfiguration(httpProxy: "http://proxy.example:8080")
        let check = Doctor.proxyConfigCheck(config: MorbConfig(), effectiveProxy: effective)
        XCTAssertEqual(check.status, .pass)
        XCTAssertTrue(check.detail.contains("http://proxy.example:8080"))
    }

    func testProxyLiveCheckReportsAnAbsentGuest() {
        let check = Doctor.proxyLiveCheck(expected: GuestProxyConfiguration(), reported: nil)
        XCTAssertEqual(check.status, .info)
        XCTAssertTrue(check.detail.contains("no guest has reported"))
    }

    func testProxyLiveCheckConfirmsNoProxyWhenBothAgree() {
        let check = Doctor.proxyLiveCheck(
            expected: GuestProxyConfiguration(), reported: (http: "", https: "", noProxy: ""))
        XCTAssertEqual(check.status, .info)
        XCTAssertTrue(check.detail.contains("no proxy configured"))
    }

    func testProxyLiveCheckPassesWhenTheGuestConfirmsTheConfiguredProxy() {
        let expected = GuestProxyConfiguration(httpProxy: "http://proxy.example:8080")
        let check = Doctor.proxyLiveCheck(
            expected: expected, reported: (http: "http://proxy.example:8080", https: "", noProxy: ""))
        XCTAssertEqual(check.status, .pass)
        XCTAssertTrue(check.detail.contains("http://proxy.example:8080"))
    }

    func testFullDoctorReportIncludesTheProxyCheckWiredToTheHostConfiguration() {
        let host = HostProxyConfiguration(httpEnabled: true, httpHost: "proxy.example", httpPort: 8080)
        let report = Doctor.run(
            config: MorbConfig(), includeLiveShares: false, includeDaemonChecks: false, hostProxy: host)
        let check = report.checks.first { $0.name == "proxy" }
        XCTAssertEqual(check?.status, .pass)
        XCTAssertTrue(check?.detail.contains("http://proxy.example:8080") == true)
        // No daemon checks requested, so there is no live-guest comparison row.
        XCTAssertFalse(report.checks.contains { $0.name == "proxy-live" })
    }

    func testProxyLiveCheckWarnsOnAMismatch() {
        // The state right after editing config.toml without restarting the VM.
        let expected = GuestProxyConfiguration(httpProxy: "http://new.example:8080")
        let check = Doctor.proxyLiveCheck(
            expected: expected, reported: (http: "http://old.example:8080", https: "", noProxy: ""))
        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.detail.contains("restart the VM"))
        XCTAssertTrue(check.detail.contains("http://old.example:8080"))
    }

    // MARK: - Boot-log redaction

    func testRedactsProxyTokensButLeavesSharesAndTheRestOfTheCmdlineAlone() {
        let cmdline = "console=hvc0 rdinit=/init morb.share=morbshare0:/Users "
            + "morb.proxy=http:http%3A//user%3Apass%40proxy%3A8080 "
            + "morb.proxy=noproxy:localhost"
        let redacted = VMManager.redactingProxyTokens(cmdline)
        XCTAssertFalse(redacted.contains("user"))
        XCTAssertFalse(redacted.contains("pass"))
        XCTAssertTrue(redacted.contains("morb.proxy=<redacted>"))
        XCTAssertTrue(redacted.contains("morb.share=morbshare0:/Users"))
        XCTAssertTrue(redacted.contains("console=hvc0"))
    }

    func testRedactionIsANoOpWithNoProxyTokens() {
        let cmdline = "console=hvc0 rdinit=/init morb.share=morbshare0:/Users"
        XCTAssertEqual(VMManager.redactingProxyTokens(cmdline), cmdline)
    }
}
