# Local developer domains and HTTPS

Status: **P2 design contract and inactive source foundation.** Morbstack does
not currently resolve `*.morb.local`, listen for local HTTP(S), modify macOS
DNS, install a Network Extension, issue certificates, or trust a local CA.
`MorbLocalDomain` validates in-memory prospective claims only; it has no
network or Docker side effects.

## Why this is not a small DNS switch

`morb.local` falls under `.local`, the [Multicast DNS special-use domain]
(https://datatracker.ietf.org/doc/html/rfc6762.html). A normal unicast DNS
resolver shortcut would therefore conflict with macOS Bonjour/mDNS semantics.
The eventual resolver must deliberately use a correctly deployed mDNS path or
a user-approved DNS provider path; it must never silently replace the Mac's
general resolver.

Apple's DNS Settings API manages system configurations for DNS-over-HTTPS or
DNS-over-TLS and requires the user to enable the configuration; it is not an
appropriate hidden redirect to a local UDP resolver. A custom DNS proxy is a
Network Extension with the `dns-proxy` entitlement and receives system DNS
flows, so it has a substantial forwarding, privacy, update, and approval
contract. [DNS Settings](https://developer.apple.com/documentation/NetworkExtension/dns-settings)
· [DNS proxy provider](https://developer.apple.com/documentation/networkextension/dns-proxy-provider)
· [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)

## Current hooks and gaps

| Layer | Existing source | What it proves | What is still absent |
| --- | --- | --- | --- |
| Guest DNS | `guest/morbinit/src/dns.rs` | Containers can resolve only `host.docker.internal` and `gateway.docker.internal` to the VM gateway. | Host-side `*.morb.local` resolution; it must not be repurposed as a host resolver. |
| Published-port transport | `PortForwarder.swift` | The daemon reconciles Docker events plus `containers/json` and mirrors actual TCP/UDP publications onto `127.0.0.1`. | A hostname registry, a 127.0.0.1 HTTP/SNI router, and an activation/lifecycle contract. |
| Container identity | `ContainerSummary` carries container ID, Compose project/service, and published ports. | The app can display source facts. | Daemon-owned, fresh Engine-derived labels/selectors and collision-safe domain claims. |
| Host integration | `BackgroundService.swift` / `MorbCliInstallation.swift` | Explicit per-user daemon and Docker context/socket integration. | Any DNS-provider entitlement, user-visible DNS approval/removal path, or certificate trust operation. |
| TLS primitives | `K8sResourceReader.swift` uses narrow certificate pinning for one local API. | Security.framework is already used for verification. | Local CA key lifecycle, leaf issuance, per-user trust consent, SNI routing, and revocation/removal. |

The new `MorbLocalDomain` model is intentionally narrower than all of those
gaps. A claim contains an exact, validated ASCII hostname, one owner ID, and a
known TCP target port. Its registry rejects duplicate hostnames and resolves
only an exact current snapshot. It cannot create a port, route a request, or
represent a wildcard as a working service.

## Required delivery stages

1. **Claim reconciliation, still inactive.** A daemon-owned reader derives
   claims from a fresh Engine snapshot and container lifecycle events. The
   first public policy must be explicit opt-in: a domain selector and one
   already-published TCP port, each revalidated against the running snapshot.
   Do not infer HTTP from an arbitrary exposed port or auto-publish every
   Compose service. A collision, stopped container, missing publication, or
   changed owner removes the claim before any route is served.
2. **Host resolution.** Decide one resolver mechanism before enabling a UI:
   an mDNS implementation for `.morb.local`, with conflict/LAN-visibility and
   sleep/VPN behavior tested, or a signed/entitled, explicitly enabled DNS
   proxy that answers only exact current claims and forwards all other queries
   unchanged. `/etc/resolver` edits and system-wide DNS replacement are not an
   acceptable hidden fallback. The user must see the exact system change and
   have an equally explicit disable/removal action.
3. **HTTP only, loopback only.** Bind `127.0.0.1:80` only after an explicit
   conflict check and consent. A bounded HTTP router matches a normalized,
   exact `Host` claim and proxies only to the pre-existing
   `127.0.0.1:<published-port>` forward owned by `PortForwarder`. It never
   opens a LAN interface, guesses a container port, forwards an unknown host,
   or keeps a route after the target disappears. WebSocket, HTTP/2, request
   limits, streaming, and error behavior need their own protocol contract;
   this is not permission to turn the Docker relay into a generic proxy.
4. **Local HTTPS.** Only after HTTP routing and resolver acceptance, generate
   a per-user CA whose private key is stored with Keychain access controls;
   issue short-lived leaf certificates for exact active names; and terminate
   SNI on loopback `:443`. Per-user trust changes display an authentication
   prompt and can block, so trust is a separate, reversible confirmation—not
   an onboarding side effect. [Keychain services](https://developer.apple.com/documentation/security/keychain-services)
   · [Trust settings](https://developer.apple.com/documentation/security/sectrustsettingssettrustsettings(_:_:_:))
5. **UX and evidence.** Only then add native availability/settings controls.
   The displayed domain must be an observed active route, not a prospective
   label. Acceptance covers default macOS resolution, Safari/URLSession,
   port-80/443 conflicts, container stop/restart/destroy, duplicate claims,
   IPv4/IPv6, sleep/wake, VPN and DNS-profile coexistence, CA removal, and
   clean-profile install/uninstall.

## Non-negotiable security boundaries

- Every non-TLS route targets an existing Morbstack-owned loopback TCP
  publication; never a container IP, LAN address, Unix socket, or arbitrary
  user URL.
- Claims are ephemeral Engine-derived state, not durable Docker labels copied
  into a privileged router. Reconciliation failure removes availability.
- The resolver returns only exact active names. No wildcard answer, suffix
  fallback, general DNS interception, or external DNS query logging is in
  scope.
- A certificate is never minted or trusted merely because a container starts.
  CA creation, per-user trust, TLS enablement, and removal are individually
  disclosed and reversible.
- `*.morb.local` is not a product claim until all resolver, router, lifecycle,
  and certificate rows have live evidence.

## Sources consulted

- [RFC 6762: Multicast DNS](https://datatracker.ietf.org/doc/html/rfc6762.html)
- [Apple DNS Settings](https://developer.apple.com/documentation/NetworkExtension/dns-settings)
- [Apple DNS proxy provider](https://developer.apple.com/documentation/networkextension/dns-proxy-provider)
- [Apple Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [Apple `NEDNSSettings.matchDomains`](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains)
- [Apple Keychain services](https://developer.apple.com/documentation/security/keychain-services)
- [Apple certificate trust settings](https://developer.apple.com/documentation/security/sectrustsettingssettrustsettings(_:_:_:))
