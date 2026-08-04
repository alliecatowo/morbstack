# Local developer domains and HTTPS

Status: **S5 delivery contract; mechanism decided in
[`docs/design/DNS-DECISION.md`](design/DNS-DECISION.md), which supersedes this
document wherever they disagree.** Morbstack does not currently resolve a local
name, listen for local HTTP(S), modify macOS DNS, install a Network Extension,
issue a certificate, or trust a local CA. The only domains code in the tree is
`MorbLocalDomain.Name`, a pure hostname validator with no network or Docker side
effect. The earlier host-loopback claim model (`MorbLocalDomain.Claim`/`Registry`
and `LocalDomainClaimReconciler`) encoded a host HTTP-router design the SP-2/SP-3
decision rejected, and was deleted on 2026-08-03 under SP-5 (see
[`docs/design/INERT-SUBSYSTEMS-DECISION.md`](design/INERT-SUBSYSTEMS-DECISION.md)).

This document is the implementation contract for the feature, not evidence that
any stage has shipped. A local-service URL is a security boundary: a browser
will treat the name, resolver, listener, certificate, and proxy as one product
promise. The implementation must earn that promise in the order below.

## Product outcome and non-goals

The useful outcome is deliberately small: a person explicitly chooses one
currently running Docker container, one of its already-published TCP ports, and
one exact local name. While all proofs remain current, that name can route only
to that one service on this Mac. HTTPS is an independent, later opt-in.

It is not a generic proxy, an ingress controller, a way to publish Docker
services to a LAN/VPN, a Docker label convention with hidden effects, a DNS
replacement, a container-IP network, or a mechanism for exposing an arbitrary
local process. Morbstack must not wake/start a VM, start a container, select a
replacement container, or create a Docker publication because a browser or DNS
query asked for a name.

The current public-looking spelling `*.morb.local` is **not a shipped naming
contract**. `.local` is reserved for Multicast DNS and is therefore a bad
default for a private, loopback-only service route. Its use in the inactive
model is a source fact, not permission to configure a resolver. S5.0 must make
one explicit product decision before any UI or host integration:

| Candidate | Decision |
| --- | --- |
| `*.morb.local` | Do not ship it unless a macOS-supported, user-approved resolver path proves that it does not leak names onto the LAN, override Bonjour/mDNS, or break scoped DNS. There is no `/etc/resolver` fallback. |
| `*.morb.test` | **Recommended canonical name.** `.test` avoids the `.local` mDNS collision, but still requires a narrowly scoped resolver configuration. It is not a license to intercept unrelated DNS. |
| Both names or an alias | Not in v1. An alias doubles collision, certificate, revocation, and support state. |

**UNRESOLVED — this document contradicts the source it describes.** This table
recommends `*.morb.test` as the canonical name and flags `*.morb.local` as
conditional on a resolver-safety proof that has not been done. But
`MorbLocalDomain.suffix` in `mac/Sources/MorbstackKit/MorbLocalDomain.swift`
is already hardcoded to `"morb.local"` — the candidate this document itself
says should not ship without further proof. Nothing here picks a winner
between the doc's recommendation and the source constant; that is a product
decision for someone with authority over S5.0, not something to resolve by
editing prose. Until it is resolved, the suffix used anywhere in code should
not be treated as the decided name.

Until that decision changes source and is accepted on supported macOS releases,
no documentation, UI, CLI, or marketing may say that `morb.local` resolves.

## What exists today

| Boundary | Current source evidence | What it proves | What it does **not** prove |
| --- | --- | --- | --- |
| Name shape | `MorbLocalDomain.Name` accepts an exact ASCII hostname below `morb.local` (unit-tested in `MorbLocalDomainNameTests`). | A malformed or non-`Host`-header-safe name is rejected rather than normalized loosely. | A hostname is configured, resolvable, or public. |
| Registrar, routing, withdrawal | Nothing — the DIF-4 mDNS registrar, guest reverse proxy, and lifecycle are unwritten. The former loopback claim/reconciler model was deleted with the host-router design it served. | — | Anything. |
| Existing TLS use | `K8sResourceReader` pins a narrow local Kubernetes identity. | Security.framework is already a project dependency. | A local CA, key lifecycle, trust setting, leaf issuance, or HTTPS proxy. |

The last distinction matters. A numeric loopback `connect` after a snapshot can
race a withdrawn listener and a later process binding the same port. The future
router must receive an opaque, generation-bound **transport lease** from
`PortForwarder` (or use an equivalently owner-bound guest stream). It must not
prove a port and then independently connect to `127.0.0.1:<port>` by number.

## Authority and state model

There are three deliberately separate kinds of state:

| State | Lifetime and owner | Contents | What may use it |
| --- | --- | --- | --- |
| Route intent | Per-user, persisted only after an explicit confirmation. | Random intent ID, exact name, immutable full Docker container ID, chosen published TCP port, and user choices for HTTP/TLS. | The reconciler may consider it after current facts are proved. |
| Route fact | In-memory and generation-scoped, owned by the daemon. | Current running-owner result, `PortForwarder` generation/opaque transport lease, router listener generation, and resolver state. | The router may serve a new connection only while the fact is live. |
| Trust material | Per-user Keychain/trust state, separately consented. | Morbstack CA identity reference, public certificate fingerprint, trust-setting reference, and exact leaf records. | The TLS listener may sign/serve only after a current route fact exists. |

An intent is never a durable permission for a name. It becomes inactive if the
container is stopped, removed, recreated with a new ID, changes its selected
publication, loses the forwarder, collides, the router is unavailable, or the
resolver/trust feature is disabled. A same-named or same-Compose-service
replacement never inherits the intent. The person deliberately chooses it
again.

The daemon owns a serial `ServiceRouteCoordinator`. It listens to the same
Docker lifecycle causes that refresh the port forwarder and re-reads a current
running-container snapshot before it publishes a new route generation. It
combines that result with one atomic forwarder snapshot, then replaces the
whole active-route map atomically. A failed, delayed, or contradictory
reconciliation withdraws availability; it never retains the previous route
because it was convenient.

An active route is keyed by `(exact hostname, full owner ID, selected host TCP
port, route generation)`. Before a router accepts a request it checks out a
short-lived opaque transport lease for that exact key. The forwarder refuses a
lease when its listener, owner, binding, or generation has changed, and tears
down dependent router streams on withdrawal. This closes the port-reuse race
without exposing a generic daemon dial API.

### Claim selection, collision, and revocation

1. The native container inspector may offer **Add Local Service…** only for a
   currently running record with observed, active, unambiguous TCP forwards.
   The port chooser lists those exact forwards; it never accepts a container
   port, arbitrary host port, UDP, an IP address, a URL, a label, or a guessed
   HTTP service.
2. The confirmation names the exact full-ID-backed container, chosen current
   host port, hostname, local-only boundary, and any host changes still needed.
   Compose metadata may suggest a human-readable name, but can never create a
   claim or win a collision.
3. Duplicate normalized names are a hard collision. No incumbent wins by
   creation time and no contender is silently renamed. All colliding intents
   are inactive until a person changes or revokes one. A router never serves a
   stale incumbent simply because a new request collided.
4. Revoking an intent atomically removes its route fact, refuses new resolver
   answers, closes route-owned connections, and retires the exact leaf
   certificate from use. It does not stop/delete the container or change its
   Docker port. DNS caches may retain an old answer until the displayed TTL
   expires; Morbstack must say that plainly rather than promise a cache flush.
5. Container stop/destroy, forwarder failure/conflict, changed port/owner,
   router failure, DNS-profile removal, sleep, and explicit opt-out use the
   same withdrawal path. There is no background retarget, retry that revives a
   stale route, or name-to-new-container repair.

## Router contract

The planned `ServiceRouter` is a daemon-owned, per-user loopback service. It
has no Docker socket listener and no LAN socket. It is separate from the
Docker API proxy and `PortForwarder` so a parser error or browser load cannot
become Engine authority.

### Listener and target boundaries

- Bind only `127.0.0.1:80` for HTTP and `127.0.0.1:443` for HTTPS; never
  `0.0.0.0`, `::`, an interface address, a Unix socket exposed to another
  user, or a VPN/LAN address. IPv6 is unsupported until a separate `::1`
  resolver/listener/acceptance contract exists.
- The daemon must attempt an ordinary bind before activation and retain the
  bound listener as an owned lease. It never kills, steals, proxies through, or
  retries over another process holding 80/443.
- Morbstack has no privileged helper. The S5 gate must prove the signed
  per-user process can own the standard loopback port on every supported
  macOS configuration. If the OS rejects the bind, automatic bare-port URLs
  are unavailable. An explicit high-port diagnostic URL may be useful for
  development, but it is not marketed as automatic local-domain support and
  must obey the same route/lease rules.
- A selected route targets only the opaque forwarder transport lease for its
  exact owner/port/generation. It must not use a container IP, Docker socket,
  user URL, user process, arbitrary loopback port, or host-network endpoint.
- Router connection, request, response, idle, header, and queued-byte limits
  are fixed, documented resource limits. Rejection is a local HTTP error and
  bounded daemon diagnostic, never an unbounded queue or an engine restart.

### Protocol scope and implementation choice

This is an HTTP reverse proxy, not an occasion to hand-write a partial web
server. The implementation must use a maintained, pinned, audited streaming
HTTP/TLS implementation (for example, a version-locked SwiftNIO family with
its Apache-2.0 provenance recorded in the release manifest), or demonstrate
equivalent platform support. A custom HTTP parser, chunk decoder, TLS stack,
or HTTP/2 framing layer is out of scope.

The first public protocol set is decided only by acceptance, but a useful v1
must cover HTTP/1.1 request/response streaming, backpressure, cancellation,
and WebSocket upgrade without buffering a body or response in memory. HTTP/2,
gRPC, h2c, CONNECT, HTTP proxy requests, raw TCP tunnelling, and HTTP/3 are
all unavailable until each has a separate routing, resource, and acceptance
contract. Do not advertise a protocol merely because a dependency can parse it.

For every request, the router normalizes one exact ASCII authority, accepts
only the default port for the listener, and resolves it through the current
route generation. HTTPS requires SNI and requires the SNI, HTTP `Host`/HTTP/2
`:authority`, selected certificate, and route hostname to agree exactly.
Unknown/malformed/ambiguous authority is rejected; there is no default site,
wildcard route, suffix match, host-header fallback, or redirect to another
service. Client-supplied `Forwarded`, `X-Forwarded-*`, and `X-Real-IP` fields
are removed. If a later compatibility contract adds forwarded metadata, the
router emits one documented value itself rather than trusting the client.

## Resolver, DNS, VPN, and sleep contract

Resolution is a separate per-user capability. HTTP routing alone does not
enable it, and installing it is never first-run setup. The recommended product
shape is one explicitly enabled, domain-scoped resolver configuration for the
chosen canonical suffix. It returns only an `A` record for an exact active
route, with value `127.0.0.1` and a short documented TTL; it returns no
wildcard, search-domain, container-IP, LAN, or external-domain answer. AAAA
and unrelated query types receive a standards-correct negative response, not
an invented `::1` route.

Before implementation, the owning team must prove that the selected macOS API
and entitlement can scope answers to the one suffix without receiving,
recording, changing, or forwarding general DNS traffic. A user-approved DNS
provider/Network Extension is acceptable only if that proof holds. If the API
would turn Morbstack into a general DNS proxy, S5 is unavailable rather than
silently adding broad DNS authority. `/etc/resolver` writes, `scutil` hacks,
shell profiles, replacement Wi-Fi/VPN DNS servers, and an unmanaged local UDP
resolver are prohibited.

The resolver configuration shows its exact suffix, destination, app identity,
and removal action in the normal macOS approval surface and in a native
Morbstack `Form`. On disable or uninstall it removes only the configuration it
created and verifies that its identifier is gone. It never changes a corporate
DNS profile, VPN resolver order, search domain, or other app's setting.

VPN/interface transitions and wake are negative-proof events:

- On sleep or loss of the resolver/router/forwarder readiness, withdraw all
  active route facts before serving another request. Persisted intents remain
  inactive only; neither a DNS query nor a URL starts the VM or container.
- On wake, VPN connect/disconnect, or DNS configuration change, first verify
  the resolver remains domain-scoped and owned, then verify the listener,
  current Engine owner, forwarder transport lease, and TLS state. Only then
  may the coordinator publish a fresh generation.
- If a VPN/profile wins or removes the suffix scope, return an unavailable
  state with a specific repair action. Do not edit the VPN's settings, append a
  resolver file, or route around it.
- DNS publication is not liveness. A cached `127.0.0.1` answer without a
  current router gets a deliberate local connection failure, never another
  local process or a network address.

## Optional local HTTPS

HTTPS is a second explicit capability after routing and resolver acceptance.
Enabling it presents a separate review that says, in plain language, that
Morbstack will create a per-user local CA, request trust for that CA, and use
it only to present certificates for exact active local-service names. It does
not occur while enabling Docker, the background service, DNS, or a container.

### Key and trust boundaries

- Generate the CA key locally. Store the private key only as a Keychain item
  restricted to the signed Morbstack app/daemon identities required to serve
  it; do not write PEM keys to Application Support, the bundle, `/tmp`, a
  diagnostic, process arguments, or a container.
- Keep the public CA certificate fingerprint, Keychain persistent reference,
  and trust-setting reference as the repairable records. The system/user
  Keychain is the only trust store touched; no MDM profile, system-wide root
  store, browser-specific import, or command-line certificate injection is
  allowed.
- The root is used only by this per-user feature. Each leaf has one exact SAN
  for one active canonical hostname—never a wildcard, arbitrary user domain,
  IP address, or Compose suffix. Leaf issuance and renewal revalidate the
  current route fact first. Leaf validity is short and documented; CA/leaf
  lifetime values, rotation, and expiry recovery require a separately reviewed
  security policy before code lands.
- A certificate name constraint may be defense in depth only after Safari and
  URLSession acceptance proves it is honored. The product must not call the CA
  cryptographically name-scoped solely because an X.509 extension was emitted;
  exact leaf issuance is the enforceable baseline.
- A locked Keychain, failed trust request, missing identity, certificate
  mismatch, or expired leaf makes HTTPS unavailable. It never falls back to a
  self-signed certificate, HTTP while displaying `https`, an unrelated
  Keychain item, or a certificate for another name.

### Enable, disable, and repair

Trust is requested only after the CA exists and the person confirms the exact
certificate fingerprint/label. It can require authentication and can fail; the
router remains HTTP-only or unavailable as selected. **Disable HTTPS** stops
the TLS listener and leaf use but preserves neither a claim nor routing beyond
the separately chosen HTTP state. **Remove Morbstack CA…** identifies the
exact fingerprint/tag it created, removes its trust setting, then deletes its
identity only after confirmation. It refuses to remove a same-named unrelated
certificate.

A repair surface may show observed state—resolver disabled, port occupied,
collision, owner stopped, forwarder unavailable, Keychain locked, trust
missing, or certificate expiring—and offer the smallest explicit repair. It
must never kill a port owner, re-trust a CA, recreate a CA, reinstall a DNS
configuration, or reattach an intent to a new container without a new consent.

## Native UX contract

Local services belong with the selected container/service record and in a
dedicated Settings pane, not on a dashboard. Use a native inspector `Form` and
`LabeledContent` to show the observed hostname, selected published port,
route state, resolver state, and HTTPS trust state. When no route can exist,
use an honest `ContentUnavailableView` with an action such as **Add Local
Service…**, **Enable Local DNS…**, or **Repair…** only when that exact action
is available.

The normal lifecycle is:

1. Select a running container and an observed active TCP forward.
2. Choose an exact name and review the durable intent plus any loopback/DNS
   change. Confirm routing separately from resolver activation.
3. Observe the active HTTP URL only after the coordinator owns the listener,
   resolver, and exact route fact.
4. Opt into HTTPS in a separate trust review; show an HTTPS URL only after
   its current certificate and loopback TLS listener are live.
5. Revoke, disable DNS, disable HTTPS, or remove the CA through distinct,
   reversible actions with normal confirmation for the irreversible trust
   removal.

“Open” and “Copy URL” are available only for a fresh active route. There is no
placeholder local URL, disabled-but-copyable link, auto-created name, magic
wand, or persistent green health indicator after the daemon has lost proof.

## Delivery gates and acceptance evidence

S5 cannot be promoted as one broad checkbox. Each gate needs implementation,
real-window native UX evidence, and live behavior evidence before the next
user-visible claim.

| Gate | Required result before promotion |
| --- | --- |
| S5.0 naming and capability decision | Canonical suffix, supported macOS versions, resolver API/entitlement, and non-root 80/443 feasibility are recorded. If `.morb.local` cannot be proven private and scoped, it is retired before source/UI work. |
| S5.1 exact claims and transport | Full-ID-only intent; selected active TCP forward; collision withdrawal; current-engine/forwarder reconciliation; opaque owner/generation-bound stream lease; stop/destroy/recreate/failed-bind/port-reuse race all fail closed. No DNS/router yet. |
| S5.2 loopback HTTP router | Standard port ownership is proven without privilege or reports unavailable; only 127.0.0.1 binds; no LAN/VPN reachability; strict authority routing; large streamed responses, cancellation, backpressure, WebSocket acceptance, resource limits, and no Engine/Docker-socket exposure. |
| S5.3 scoped resolver | Exact active A answers only; unknown/colliding/inactive names are negative; no wildcard/search/general query interception; approval/removal is visible and reversible; Safari, URLSession, command-line resolver, VPN/profile coexistence, sleep/wake, and uninstall prove the state machine. |
| S5.4 optional HTTPS | Keychain-only key; explicit per-user trust; exact leaf/SNI/authority match; no wildcard/arbitrary-domain issuance; certificate rotation/expiry; trust denial/removal; 443 conflict; Keychain lock; Safari/URLSession behavior; no key/credential in logs, diagnostics, or process arguments. |
| S5.5 recovery and product proof | Container/VM/daemon/app restart, router crash, DNS-profile loss, port conflict, resolver collision, VPN transition, sleep/wake, opt-out, and CA removal each leave either a truthful active route or a specific repair state. A clean-profile install/disable/uninstall proves that no resolver, listener, certificate trust, or Docker change survives outside its owned state. |

Passing the table is a prerequisite for the first claim that a local service
name works. Passing S5.4 is a prerequisite for any HTTPS claim. It is not
evidence of general host networking, a LAN ingress, or unrestricted local DNS.

## Sources and related delivery records

- [RFC 6762: Multicast DNS](https://datatracker.ietf.org/doc/html/rfc6762.html)
  and [RFC 6761: Special-Use Domain Names](https://datatracker.ietf.org/doc/html/rfc6761.html)
- [Apple DNS Settings](https://developer.apple.com/documentation/NetworkExtension/dns-settings),
  [DNS proxy provider](https://developer.apple.com/documentation/networkextension/dns-proxy-provider),
  [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension),
  and [`NEDNSSettings.matchDomains`](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains)
- [Apple Keychain services](https://developer.apple.com/documentation/security/keychain-services)
  and [certificate trust settings](https://developer.apple.com/documentation/security/sectrustsettingssettrustsettings(_:_:_:))
- [`drop-in-delivery-plan.md`](drop-in-delivery-plan.md) S5 — canonical order
  and release gate; [`product-audit.md`](product-audit.md) — current
  implementation status; [`MorbLocalDomain.swift`](../mac/Sources/MorbstackKit/MorbLocalDomain.swift)
  and [`PortForwarder.swift`](../mac/Sources/MorbstackKit/PortForwarder.swift)
  — inactive claim/current-forward foundation.
