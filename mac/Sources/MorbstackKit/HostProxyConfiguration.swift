// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import SystemConfiguration

/// The Mac's system-wide proxy configuration, as System Settings → Network →
/// (active service) → Proxies actually has it — the same store `curl`,
/// `networksetup`, and every other proxy-aware tool on the platform read.
///
/// Read with `SCDynamicStoreCopyProxies`, never by shelling out to
/// `networksetup` or reading `defaults`: the dynamic store is the live,
/// resolved-from-whichever-network-service-is-primary answer, which is
/// exactly what "the Mac's configured proxy" has to mean when the guest asks
/// what to inherit (UX-18). ``parse(_:)`` is the pure half — the dictionary
/// shape `SCDynamicStoreCopyProxies` returns is fixed and documented, so
/// parsing it needs no live system to test against.
public struct HostProxyConfiguration: Equatable, Sendable {
    public var httpEnabled: Bool
    public var httpHost: String?
    public var httpPort: Int?

    public var httpsEnabled: Bool
    public var httpsHost: String?
    public var httpsPort: Int?

    public var socksEnabled: Bool
    public var socksHost: String?
    public var socksPort: Int?

    /// Hostnames/domains/CIDRs the Mac is configured to reach directly,
    /// bypassing every proxy above.
    public var exceptionsList: [String]

    /// `true` when a PAC (proxy auto-config) script URL is configured.
    public var autoConfigEnabled: Bool
    public var autoConfigURLString: String?

    /// `true` when WPAD/Bonjour proxy auto-discovery is turned on. Like
    /// ``autoConfigEnabled``, this means "evaluate a script/protocol to find
    /// out", which Morbstack cannot do without a JavaScript engine — see
    /// ``GuestProxyConfiguration/pacOnly``.
    public var autoDiscoveryEnabled: Bool

    public init(
        httpEnabled: Bool = false,
        httpHost: String? = nil,
        httpPort: Int? = nil,
        httpsEnabled: Bool = false,
        httpsHost: String? = nil,
        httpsPort: Int? = nil,
        socksEnabled: Bool = false,
        socksHost: String? = nil,
        socksPort: Int? = nil,
        exceptionsList: [String] = [],
        autoConfigEnabled: Bool = false,
        autoConfigURLString: String? = nil,
        autoDiscoveryEnabled: Bool = false
    ) {
        self.httpEnabled = httpEnabled
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsEnabled = httpsEnabled
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
        self.socksEnabled = socksEnabled
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.exceptionsList = exceptionsList
        self.autoConfigEnabled = autoConfigEnabled
        self.autoConfigURLString = autoConfigURLString
        self.autoDiscoveryEnabled = autoDiscoveryEnabled
    }

    /// The configured HTTP proxy as a URL string, or `nil` when it is off or
    /// has no host.
    ///
    /// Rendered with an `http://` scheme regardless of which of the three
    /// dynamic-store toggles supplied it: the scheme in this string is how
    /// dockerd talks *to the proxy itself* (a plain connection, then either
    /// a forwarded request or a `CONNECT` tunnel for HTTPS traffic), not the
    /// scheme of the traffic being proxied. This matches how `curl` and every
    /// other consumer of `HTTP_PROXY`/`HTTPS_PROXY` interpret the variable.
    public var httpProxyURL: String? {
        Self.url(scheme: "http", enabled: httpEnabled, host: httpHost, port: httpPort)
    }

    /// The configured HTTPS proxy as a URL string, or `nil` when it is off or
    /// has no host. See ``httpProxyURL`` for why the scheme is `http://`.
    public var httpsProxyURL: String? {
        Self.url(scheme: "http", enabled: httpsEnabled, host: httpsHost, port: httpsPort)
    }

    /// The configured SOCKS proxy as a `socks5://` URL, or `nil` when it is
    /// off or has no host.
    ///
    /// Unlike the HTTP(S) case, the scheme here is real: Go's
    /// `net/http.ProxyFromEnvironment` (which dockerd's outbound registry
    /// client uses — see `guest/morbinit/src/guest_proxy.rs`) resolves a
    /// `socks5://` value in `HTTP_PROXY`/`HTTPS_PROXY` to a genuine SOCKS5
    /// dial, which is what lets Morbstack answer part of Docker's own
    /// Business-tier SOCKS5 gate for free (UX-18).
    public var socksProxyURL: String? {
        Self.url(scheme: "socks5", enabled: socksEnabled, host: socksHost, port: socksPort)
    }

    private static func url(scheme: String, enabled: Bool, host: String?, port: Int?) -> String? {
        guard enabled, let host, !host.isEmpty else { return nil }
        if let port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    // MARK: - Reading the live configuration

    /// The dictionary keys `SCDynamicStoreCopyProxies` uses, exactly as
    /// documented by `SCSchemaDefinitions.h`. Spelled out as plain strings
    /// (rather than importing the `kSCPropNetProxies*` symbols) so
    /// ``parse(_:)`` can be exercised with a literal `[String: Any]` fixture
    /// in tests with no dependency on the live system.
    private enum Key {
        static let httpEnable = "HTTPEnable"
        static let httpProxy = "HTTPProxy"
        static let httpPort = "HTTPPort"
        static let httpsEnable = "HTTPSEnable"
        static let httpsProxy = "HTTPSProxy"
        static let httpsPort = "HTTPSPort"
        static let socksEnable = "SOCKSEnable"
        static let socksProxy = "SOCKSProxy"
        static let socksPort = "SOCKSPort"
        static let exceptionsList = "ExceptionsList"
        static let proxyAutoConfigEnable = "ProxyAutoConfigEnable"
        static let proxyAutoConfigURLString = "ProxyAutoConfigURLString"
        static let proxyAutoDiscoveryEnable = "ProxyAutoDiscoveryEnable"
    }

    /// Parses the dictionary `SCDynamicStoreCopyProxies` returns.
    ///
    /// Every field is read defensively: the real dictionary mixes `CFNumber`
    /// (bridged to `NSNumber`) for the `*Enable`/`*Port` keys and `CFString`
    /// for host/URL keys, and a key is simply absent rather than null when a
    /// service has never had it set. Anything of the wrong shape is treated
    /// as absent rather than thrown, matching ``MorbConfig``'s tolerance for
    /// a dictionary of unknown provenance.
    public static func parse(_ proxies: [String: Any]) -> HostProxyConfiguration {
        func bool(_ key: String) -> Bool {
            (proxies[key] as? NSNumber)?.boolValue ?? false
        }
        func string(_ key: String) -> String? {
            let value = (proxies[key] as? String)?.trimmingCharacters(in: .whitespaces)
            return (value?.isEmpty ?? true) ? nil : value
        }
        func port(_ key: String) -> Int? {
            guard let number = proxies[key] as? NSNumber else { return nil }
            let value = number.intValue
            return (1...65535).contains(value) ? value : nil
        }
        func stringList(_ key: String) -> [String] {
            (proxies[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }

        return HostProxyConfiguration(
            httpEnabled: bool(Key.httpEnable),
            httpHost: string(Key.httpProxy),
            httpPort: port(Key.httpPort),
            httpsEnabled: bool(Key.httpsEnable),
            httpsHost: string(Key.httpsProxy),
            httpsPort: port(Key.httpsPort),
            socksEnabled: bool(Key.socksEnable),
            socksHost: string(Key.socksProxy),
            socksPort: port(Key.socksPort),
            exceptionsList: stringList(Key.exceptionsList),
            autoConfigEnabled: bool(Key.proxyAutoConfigEnable),
            autoConfigURLString: string(Key.proxyAutoConfigURLString),
            autoDiscoveryEnabled: bool(Key.proxyAutoDiscoveryEnable))
    }

    /// The Mac's live proxy configuration, or ``HostProxyConfiguration/init()``
    /// (everything off) if the dynamic store cannot be reached — which is not
    /// an error condition Morbstack can usefully surface; it just means no
    /// proxy will be inherited.
    public static func current() -> HostProxyConfiguration {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return HostProxyConfiguration()
        }
        return parse(proxies)
    }
}
