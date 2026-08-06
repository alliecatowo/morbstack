// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The proxy environment Morbstack intends to hand the guest — the resolved
/// combination of the Mac's system proxy (``HostProxyConfiguration``) and any
/// ``MorbConfig`` override, before it is percent-encoded onto the kernel
/// command line by ``MorbGuestProxy``.
///
/// This is a *decision*, not a raw reading: it is what `effectiveGuestProxy`
/// computes and what `VMManager` boots the guest with. `morb doctor` uses the
/// same function to show what the *next* boot would do, and compares it
/// against what the *running* guest actually reports over the control channel
/// (``GuestReply/httpProxy`` and friends) — the difference between "we
/// configured it" and "it reached the engine" that UX-18 asks for.
public struct GuestProxyConfiguration: Equatable, Sendable {
    public var httpProxy: String?
    public var httpsProxy: String?
    public var noProxy: String?

    /// `true` when the Mac has no static proxy Morbstack can pass through —
    /// only a PAC script and/or WPAD auto-discovery — and no explicit
    /// `config.toml` override filled the gap either.
    ///
    /// A PAC file is a JavaScript program that picks a proxy per request;
    /// turning that into a single `HTTP_PROXY` string would require
    /// evaluating it, which Morbstack does not do (see the doctor check this
    /// drives). This is the flag that keeps that gap from silently presenting
    /// as "no proxy is configured" when the Mac in fact has one, just not one
    /// Morbstack can currently express.
    public var pacOnly: Bool
    public var pacURLString: String?

    public init(
        httpProxy: String? = nil,
        httpsProxy: String? = nil,
        noProxy: String? = nil,
        pacOnly: Bool = false,
        pacURLString: String? = nil
    ) {
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.noProxy = noProxy
        self.pacOnly = pacOnly
        self.pacURLString = pacURLString
    }

    /// `true` when nothing here would change dockerd's environment at all.
    public var isEmpty: Bool {
        httpProxy == nil && httpsProxy == nil && noProxy == nil
    }
}

extension MorbConfig {
    /// Resolves ``GuestProxyConfiguration`` from this configuration and the
    /// Mac's system proxy.
    ///
    /// Pure and injectable: `host` is the caller's already-read
    /// ``HostProxyConfiguration``, never fetched here, so this can be unit
    /// tested against a fixture with no `SCDynamicStore` involved.
    ///
    /// Precedence, matching the rest of `config.toml` (`kernelPath`,
    /// `initrdPath`, …): an explicit, non-empty override always wins over
    /// whatever the Mac has configured. `proxyEnabled = false` is the whole
    /// off switch — it short-circuits before either source is consulted, so
    /// turning it off cannot leave a stale override or a stale system value
    /// behind.
    public func effectiveGuestProxy(host: HostProxyConfiguration) -> GuestProxyConfiguration {
        guard proxyEnabled else { return GuestProxyConfiguration() }

        var result = GuestProxyConfiguration()

        let httpOverride = httpProxyOverride.flatMap { $0.isEmpty ? nil : $0 }
        let httpsOverride = httpsProxyOverride.flatMap { $0.isEmpty ? nil : $0 }
        let noProxyOverride = self.noProxyOverride.flatMap { $0.isEmpty ? nil : $0 }

        // The SOCKS proxy, when the Mac has one and no static HTTP/HTTPS proxy
        // is configured, becomes the fallback for both — see
        // `HostProxyConfiguration/socksProxyURL` for why a `socks5://` value
        // works here.
        let socksFallback = host.socksProxyURL

        result.httpProxy = httpOverride ?? host.httpProxyURL ?? socksFallback
        result.httpsProxy = httpsOverride ?? host.httpsProxyURL ?? socksFallback
        result.noProxy = noProxyOverride ?? (host.exceptionsList.isEmpty
            ? nil
            : host.exceptionsList.joined(separator: ","))

        let hasExplicitOverride = httpOverride != nil || httpsOverride != nil
        let hasStaticHostProxy = host.httpProxyURL != nil || host.httpsProxyURL != nil || socksFallback != nil
        if !hasExplicitOverride, !hasStaticHostProxy, host.autoConfigEnabled || host.autoDiscoveryEnabled {
            result.pacOnly = true
            result.pacURLString = host.autoConfigURLString
        }

        return result
    }
}

/// Encodes/decodes ``GuestProxyConfiguration`` onto the kernel command line —
/// the guest-side twin is `guest_proxy::parse_cmdline` in
/// `guest/morbinit/src/guest_proxy.rs`.
///
/// Same rationale as ``MorbShares``' command-line encoding (see that type's
/// docs): dockerd is started by the supervisor before the vsock control
/// channel can exist, so the command line — visible to PID 1 from its very
/// first instruction — is the only channel available in time.
public enum MorbGuestProxy {

    /// The kernel command-line key carrying one proxy field. Must match
    /// `guest_proxy::CMDLINE_KEY` on the guest.
    public static let cmdlineKey = "morb.proxy"

    private static let httpKey = "http"
    private static let httpsKey = "https"
    private static let noProxyKey = "noproxy"

    /// The command-line fragments describing `proxy`, one per configured
    /// field. Reuses ``MorbShares/encode(_:)`` for the percent-encoding —
    /// both sides speak the identical escaping scheme, so there is exactly
    /// one codec to keep in agreement with the guest.
    public static func cmdlineArguments(for proxy: GuestProxyConfiguration) -> [String] {
        var out: [String] = []
        if let value = proxy.httpProxy {
            out.append("\(cmdlineKey)=\(httpKey):\(MorbShares.encode(value))")
        }
        if let value = proxy.httpsProxy {
            out.append("\(cmdlineKey)=\(httpsKey):\(MorbShares.encode(value))")
        }
        if let value = proxy.noProxy {
            out.append("\(cmdlineKey)=\(noProxyKey):\(MorbShares.encode(value))")
        }
        return out
    }

    /// `base` with the proxy arguments appended.
    ///
    /// - Throws: ``MorbError/config(_:)`` if the result would exceed
    ///   ``MorbShares/maximumCmdlineBytes`` — the kernel would silently
    ///   truncate it, same failure mode `MorbShares.appendToCmdline` guards.
    public static func appendToCmdline(_ base: String, proxy: GuestProxyConfiguration) throws -> String {
        let arguments = cmdlineArguments(for: proxy)
        guard !arguments.isEmpty else { return base }
        let combined = ([base] + arguments).joined(separator: " ")
        let byteCount = combined.utf8.count
        guard byteCount <= MorbShares.maximumCmdlineBytes else {
            throw MorbError.config(
                "the kernel command line would be \(byteCount) bytes once the configured proxy is "
                    + "added, over the \(MorbShares.maximumCmdlineBytes)-byte limit the kernel "
                    + "silently truncates at — shorten the proxy overrides in config.toml")
        }
        return combined
    }

    /// Recovers the proxy fields encoded in a kernel command line. Malformed
    /// or duplicate entries are tolerated the same way
    /// ``MorbShares/parseCmdline(_:)`` tolerates them: the last occurrence of
    /// a field wins, and anything unparseable is skipped rather than fatal.
    public static func parseCmdline(_ cmdline: String) -> GuestProxyConfiguration {
        var result = GuestProxyConfiguration()
        for token in cmdline.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            guard token.hasPrefix(cmdlineKey + "=") else { continue }
            let value = token.dropFirst(cmdlineKey.count + 1)
            guard let colon = value.firstIndex(of: ":") else { continue }
            let key = String(value[value.startIndex..<colon])
            let rest = String(value[value.index(after: colon)...])
            guard let decoded = MorbShares.decode(rest) else { continue }
            switch key {
            case httpKey: result.httpProxy = decoded
            case httpsKey: result.httpsProxy = decoded
            case noProxyKey: result.noProxy = decoded
            default: continue
            }
        }
        return result
    }
}
