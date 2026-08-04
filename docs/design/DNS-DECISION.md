# SP-2 decision — how Morbstack resolves container domains on macOS

**Status:** decision record. Supersedes the resolver paragraphs of
[`docs/domains.md`](../domains.md) where the two disagree. Written 2026-08-03 against
macOS 26.4 (build 25E246). This document decides a *mechanism*; it is not a licence to
ship the feature, and no code was written for it.

---

## The decision, in one sentence

**Morbstack resolves container domains by registering per-container mDNS proxy `A`
records for names under `.local` from the ordinary, unprivileged user daemon — no
entitlement, no system extension, no admin password, no `/etc/resolver` write, no
persistent system mutation — and it points those records at the guest VM's own
`192.168.64.x` address so that a reverse proxy inside the VM can own ports 80 and 443
without the Mac ever granting anyone root.**

The corollary that matters to the roadmap: **the answer to "is this six weeks or
architecturally impossible" is neither.** It is roughly three to four weeks, it costs the
user *nothing* on first run, and the mechanism we were about to spike (`NEDNSSettings`) is
the one option we should not take.

---

## What was verified on this machine, and what was not

Everything in this section labelled **VERIFIED** was executed here, as the ordinary
non-root user `allie`, on macOS 26.4, in a scratch directory, with every change reverted.
No `sudo` was run. No system DNS configuration was modified.

### VERIFIED — an unprivileged process can publish resolvable hostnames under `.local`

`dns-sd -P` (mDNS proxy registration, which is `DNSServiceRegister`/
`DNSServiceRegisterRecord` under the hood) registered `morbspike.local` and the
multi-label name `web.morbspike.local`. Both resolved through `getaddrinfo(3)`,
`dscacheutil`, `ping`, and `curl`:

```
morbspike.local      -> 127.0.0.1
web.morbspike.local  -> 127.0.0.1
PING web.morbspike.local (127.0.0.1): 64 bytes from 127.0.0.1  time=0.064 ms
```

Multi-label names are the important half: `api.todo.morb.local` is a legal mDNS record
name, so the whole `<service>.<project>.morb.local` shape OrbStack ships is available to
us through the same call.

### VERIFIED — end-to-end HTTP by name, with the right `Host` header

A Python HTTP server on `127.0.0.1:18080`, an mDNS record for `api.todo.morb.local`, then:

```
$ curl http://api.todo.morb.local:18080/
served to Host: api.todo.morb.local:18080
```

The name reaches the listener and the `Host` header carries it, which is exactly what a
Host-header reverse proxy needs. Resolution latency after the first query: **0.5–1.0 ms**
(first query 6.4 ms).

### VERIFIED — it can be kept off the LAN entirely

Registering with `kDNSServiceInterfaceIndexLocalOnly` (`dns-sd -lo`) also works, for
multi-label names, and for a non-loopback target address:

```
$ dns-sd -lo -P vmip _http._tcp local 80 api.todo.morb.local 192.168.64.7
api.todo.morb.local -> 192.168.64.7
```

Local-only records are answered on this Mac and are **not** multicast to the network. This
removes the single strongest objection in `docs/domains.md` — that `.local` "leaks names
onto the LAN". It does not have to.

### VERIFIED — the records are process-lifetime, and clean up completely

Killing the registering process removed the names immediately and completely; the next
`getaddrinfo` failed with `nodename nor servname provided`. There is nothing to uninstall,
because nothing was installed. A crash, a force-quit, or a power cut leaves no residue.

### VERIFIED — mDNS gives us collision handling for free, with the semantics our own contract demands

A second process registering the *same* hostname with a *different* address was refused:

```
Got a reply for record api.todo.morb.local: Name in use, please choose another
```

The incumbent kept the name; the contender was told, not silently merged. That is the
behaviour `docs/domains.md` specifies ("no incumbent wins by creation time and no contender
is silently renamed") delivered by the operating system rather than by our code.

### VERIFIED — mDNS is `.local`-only. `.test` cannot be served this way.

Registering a record for `web.morbspike.test`, both with and without
`kDNSServiceFlagsForceMulticast`, failed:

```
DNSServiceRegisterRecord failed -65540      (kDNSServiceErr_BadParam)
```

and the name did not resolve. There is no unprivileged path to `*.test`. This is the fact
that decides SP-3.

### VERIFIED — a non-root process cannot bind 80, 443, or 53 on macOS 26

```
80   FAILED [Errno 13] Permission denied
443  FAILED [Errno 13] Permission denied
53   FAILED [Errno 13] Permission denied (TCP and UDP)
1024 BOUND OK
```

There is no Darwin equivalent of Linux's `net.ipv4.ip_unprivileged_port_start`; the
reserved-port check is in the kernel. `net.inet.ip.portrange.lowfirst/lowlast` control
which *reserved* ports a privileged process gets, not who may bind them.

**This retires an open question in `docs/domains.md`.** That document says: "The S5 gate
must prove the signed per-user process can own the standard loopback port on every
supported macOS configuration." It cannot, on any configuration. A host-side router
therefore cannot serve bare `http://name/` URLs without a root component — which is why
the recommended design moves the listener into the guest instead.

### VERIFIED — `NEDNSSettingsManager` does not answer an unentitled process at all

An ad-hoc-signed Swift binary calling the *read-only* `loadFromPreferences(_:)` never
received its completion handler; it timed out after 15 s with no error and nothing in the
`nehelper` log. The API is gated before it will even tell you that you are not allowed.
(Caveat: this was a command-line tool without an app bundle, which may itself be
disqualifying — but either way, no unentitled build can use it.)

### NOT verified here — stated from documentation or from the repo's own prior tests

- **Host → guest reachability at `192.168.64.x`.** `VMManager.swift:1884` uses
  `VZNATNetworkDeviceAttachment`, and `docs/parity.md:129` records a *previously executed*
  test showing the guest reaching a Mac listener at `192.168.64.1`. Host→guest over the
  same `bridge100` NAT segment is the standard behaviour of that attachment and is how
  every `vz` VM is SSH'd into, but **I did not confirm it, because confirming it requires
  booting the VM, which this spike was told not to do.** It is step 1 of DIF-4 and the
  whole bare-port story depends on it. If it fails, see the fallback below.
- Everything about `NEDNSSettings`, `NEDNSProxyProvider`, entitlement acquisition, SMAppService
  authorization, and certificate trust prompts — all documentation and forum sourced, cited
  inline below.
- **OrbStack was not installed on this machine and was not installed for this spike.** All
  OrbStack claims below are from its public documentation, its issue tracker, and its
  author's own public statements.

---

## The options, each with its true price

### 1. mDNS proxy records under `.local` — **RECOMMENDED**

| | |
| --- | --- |
| API | `DNSServiceRegisterRecord` / `DNSServiceRegister` (`dns_sd.h`), or `NWListener`/`NetService` at a higher level |
| Entitlement | **none.** Not restricted, not managed, not App-Store-gated. (Under App Sandbox it would need `com.apple.security.network.server`; `morbstackd` is not sandboxed — `mac/Resources/morbstackd.entitlements` carries only `com.apple.security.virtualization`.) |
| Privilege | **none.** Ordinary user process. |
| First-run cost to the user | **nothing.** No dialog, no password, no System Settings trip, no reboot. |
| Uninstall | **nothing to remove.** Records die with the process. |
| System mutation | none. No file written outside our own container, no preference, no daemon, no network service. |
| Scope | exactly the names we register, and only under `.local`. We cannot see, intercept, log, or affect any other DNS query — which is a stronger privacy guarantee than any Network Extension design could offer. |

Limits, stated plainly:

- **No wildcards.** mDNS has no wildcard records. `*.api.todo.morb.local` cannot resolve.
  Every name must be registered explicitly. We know our container and Compose service
  names, so the common case is covered; OrbStack's "wildcard subdomains" behaviour is not
  reproducible with this mechanism and must not be promised.
- **Hostile networks can still break `.local`.** A DNS server that claims authority over
  `.local` can win against mDNS on some paths; this is a real, reported failure mode for
  OrbStack ([orbstack#2274](https://github.com/orbstack/orbstack/issues/2274)). Morbstack
  should detect it (query our own name, compare the answer) and say so, rather than hang.
- **IPv6 / `AAAA`** is a separate registration and a separate decision; ship `A` only.

### 2. `/etc/resolver/<suffix>` plus a local DNS server

Still honoured on macOS 26 — `resolver(5)` is present and documents `nameserver`, `port`,
`domain`, `search_order`, and `timeout`. Two details worth recording:

- A resolver file may specify a **port**, so the local server does *not* need port 53:
  `nameserver 127.0.0.1` + `port 15353`, or the `127.0.0.1.15353` inline form.
- `resolver(5)` explicitly anticipates the `.local` case: `search_order` exists so that
  "two clients for the `.local` domain, which is used by [Bonjour] and by some sites as a
  private DNS domain name" can coexist.

The write that would be required (**not performed** — I have no `sudo` and did not attempt
it):

```sh
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/morb.test >/dev/null <<'EOF'
nameserver 127.0.0.1
port 15353
EOF
# uninstall:
sudo rm -f /etc/resolver/morb.test && sudo rmdir /etc/resolver 2>/dev/null
```

| | |
| --- | --- |
| Entitlement | none |
| Privilege | **root, once**, to write the file — meaning either an admin password prompt or a `SMAppService` LaunchDaemon (itself an approval *and* an admin authentication, [Apple: authorizing LaunchDaemons](https://developer.apple.com/forums/thread/761249)) |
| First-run cost | an admin password prompt when the feature is enabled |
| Uninstall | **we own it forever.** A root-written file outside the app bundle survives dragging the app to the Trash. Every uninstall path — including the one where the user never runs our uninstaller — leaves a resolver pointing at a dead port. That is exactly the residue OrbStack is criticised for. |
| Gains over option 1 | wildcards, arbitrary suffixes including `.test`, immunity to `.local` hijacking, and (with a root listener) bare ports 80/443 |

This is the *right* option only if wildcards or `.test` turn out to be non-negotiable. It
is a deliberate, reversible upgrade path we can add later behind an explicit opt-in; it is
the wrong thing to ship first.

### 3. `NEDNSSettingsManager` (the thing SP-2 was named after) — **rejected**

- The entitlement `com.apple.developer.networking.networkextension` has a `dns-settings`
  value, and Apple documents a Developer ID path ("enable the Network Extension capability
  for your Developer ID–signed app" in Certificates, Identifiers & Profiles), so a
  provisioning profile must be built into and shipped with the binary
  ([entitlement reference](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.networking.networkextension)).
- **It cannot express a plain local resolver.** Apple's documentation for
  [`dnsSettings`](https://developer.apple.com/documentation/networkextension/nednssettingsmanager/dnssettings)
  says the property "can be set to either an `NEDNSOverHTTPSSettings` object or an
  `NEDNSOverTLSSettings` object". Cleartext `NEDNSSettings` is not accepted. To use it we
  would have to run a **local DoH or DoT server with a system-trusted TLS certificate** —
  i.e. we would need the local CA and the trust prompt from DIF-5 *before* we could have
  DNS at all, inverting the dependency order and adding a TLS stack to the DNS path.
- **The user must go turn it on by hand.** Apple DTS, on
  [forums/thread/671196](https://developer.apple.com/forums/thread/671196): after
  `saveToPreferences` the configuration appears in System Preferences as a network service
  and the user must select it, choose "Make Service Active", and click Apply. Network
  service changes are behind the admin padlock.
- It creates a **persistent system network configuration** that outlives the app and must
  be removed on uninstall.
- Empirically (above) it will not even complete a read for an unentitled build.

Every axis is worse than option 1, and most axes are worse than option 2. `matchDomains`
scoping is genuinely good, but scoping is not a problem we have: mDNS registration is
scoped by construction.

### 4. `NEDNSProxyProvider` — **rejected outright**

Requires `dns-proxy-systemextension` for Developer ID distribution — a **system extension**
the user must approve in System Settings, in the same class of dialog as an antivirus
product. And it is a *proxy*: the provider receives the machine's DNS flows. Adopting it
would mean a product whose pitch is "no account, no telemetry" shipping a component that
sees every DNS query the Mac makes. `docs/domains.md` already forbids this shape ("If the
API would turn Morbstack into a general DNS proxy, S5 is unavailable"). It stays
unavailable.

### 5. Not DNS at all

For completeness: `/etc/hosts` (root, no wildcards, worse than option 2 in every way);
a system-wide PAC/proxy setting (changes the user's network settings, affects unrelated
traffic, browser-only); asking the user to configure it themselves (not a feature). None
of these are competitive with option 1.

---

## The port-80 problem, and why the listener belongs in the guest

Bare `http://api.todo.morb.local/` requires something to own port 80. On the Mac, that
requires root — verified above, no exceptions. Three ways out:

1. **Put the listener inside the VM.** The mDNS `A` record can carry any address; I
   verified registration with `192.168.64.7`. A Host-header reverse proxy running as root
   *inside the guest* — where root is free — owns 80 and 443 on the guest's own address and
   routes to container IPs directly, with no host-side port forward and no lease dance.
   **Zero host privileges, bare URLs, and it also happens to be the simplest design.**
2. A root-owned host component (`SMAppService` daemon, or a `pf` redirect) — an admin
   password, a persistent daemon, and an uninstall obligation.
3. Give up bare ports: point names at `127.0.0.1` and serve from a host router on a high
   port, so URLs read `http://api.todo.morb.local:8080/`. Still better than
   `localhost:8080` (stable, memorable, no port collisions between projects), but it is
   not the OrbStack experience.

**Option 1 is the recommendation, with option 3 as the automatic fallback** if host→guest
reachability fails on some configuration (VPNs that capture `192.168.64.0/24` are the
obvious risk). Option 2 is not to be built.

Note what this does to the router contract in `docs/domains.md`: the "daemon-owned loopback
listener on 127.0.0.1:80 that checks out an opaque transport lease from `PortForwarder`"
becomes unnecessary in the primary path. The guest proxy talks to container IPs on the
guest's own bridge; there is no host loopback port to race, so the entire
lease/generation mechanism exists only for the degraded fallback. That contract should be
rewritten, not implemented as written.

---

## What OrbStack appears to do (documentation and public statements only)

- It uses `*.orb.local` — a `.local` suffix, multi-label, exactly the shape mDNS supports.
- Its author's own public inventory of what OrbStack installs
  ([HN 39722284](https://news.ycombinator.com/item?id=39722284)) lists `~/.orbstack`, shell
  profile edits, a Docker context, `~/.ssh/config`, standard `~/Library` paths, Keychain
  items, and `/Library/PrivilegedHelperTools` "to create symlinks for compatibility". It
  does **not** mention `/etc/resolver`.
- `.local` names break for OrbStack users whose upstream DNS answers for `*.local`
  ([orbstack#2274](https://github.com/orbstack/orbstack/issues/2274)) — a failure mode that
  can only occur if the system resolver, not a private resolver file, is deciding.
- Its domains feature "depend[s] on the direct IP access feature"
  ([OrbStack docs](https://docs.orbstack.dev/docker/domains)) — i.e. names point at
  container IPs, and the listener is on the container, not on host loopback. Same shape as
  the recommendation above, one layer deeper (they route to individual container IPs; we
  would route to the guest and proxy inside it).

Conclusion, held loosely: OrbStack's resolution is almost certainly mDNS, and it does have
a privileged helper — but for direct container-IP routing, not for DNS. Their documented
wildcard support is the one behaviour I cannot explain with mDNS alone.

For contrast, Docker Desktop's privileged footprint is visible on this machine right now:
`/Library/LaunchDaemons/com.docker.vmnetd.plist` and `com.docker.socket.plist`. **Neither
competitor achieves a zero-privilege install. We can.** That is worth saying out loud on
the website.

---

## Consequences for SP-3 — the suffix decision is now forced

**Ship `.local`. Specifically `<name>.morb.local`.** `MorbLocalDomain.suffix` was
accidentally right and should not be changed; `docs/domains.md`'s recommendation of
`*.morb.test` should be withdrawn.

The reasoning inverts the objection in that document. `docs/domains.md` treats `.local` as
dangerous because it "collides with mDNS/Bonjour". It collides only if you try to resolve
`.local` names by *unicast DNS* — a `/etc/resolver/local` file or a private DNS zone. That
is the RFC 6762 violation. **Registering unique `A` records with mDNSResponder is not a
collision with Bonjour; it is Bonjour.** We are using the special-use suffix for exactly
the mechanism it is reserved for, the OS arbitrates conflicts for us (verified above), and
with `LocalOnly` registration the names never leave this Mac.

Whereas `.test` — the doc's recommendation — is unreachable without root. Choosing it means
choosing an admin password prompt, a `/etc/resolver` file we must clean up forever, and a
DNS server process, to buy a suffix whose only real advantage is protection against the
`.local`-hijacking ISPs described above.

Residual risks to accept knowingly, and write into the feature's own documentation:

1. A network whose DNS claims `.local` can break resolution. Detect and report; never hang.
2. No wildcard subdomains. Do not advertise them.
3. Names are visible to every user and process on this Mac (true of `localhost` too).
4. If we ever need `.test`, it is an additive opt-in via option 2, not a re-architecture.

DOC-4 is resolved by this: the contradiction is settled in favour of the source constant,
and `docs/domains.md` needs the correction, not the code.

---

## Effort estimates, now that the mechanism is known

### DIF-4 — container domains, router-only (no DNS entitlement, no CA): **3–4 weeks**

| Step | Work | Estimate |
| --- | --- | --- |
| 0 | Prove host→guest reachability at `192.168.64.x` with a real booted VM, on Wi-Fi, on Ethernet, and under a VPN. **Gate: if this fails, drop to the `127.0.0.1` + high-port fallback and re-estimate.** | 2 days |
| 1 | mDNS registrar in `morbstackd`: `DNSServiceRegisterRecord`, `LocalOnly`, `A` only, no advertised Bonjour service type, conflict handling, lifecycle bound to Docker events | 4 days |
| 2 | Name derivation + registry, wired to the existing `MorbLocalDomain` / `LocalDomainClaimReconciler` (which already validate claims and reject duplicates) | 3 days |
| 3 | Guest-side Host-header reverse proxy on `:80`/`:443`, pinned like every other guest binary, plus listening-port auto-detection per container | 6–8 days |
| 4 | Withdrawal paths: container stop/remove, VM suspend, wake, VPN transition, hostile-`.local` detection | 3 days |
| 5 | `morb domain` CLI + inspector affordance + the honest limits in `--help` | 4 days |

No admin prompt anywhere in that list. Compare with the pre-spike assumption of "~6 weeks
or impossible".

### DIF-5 — HTTPS via a name-constrained local CA: **2–3 weeks after DIF-4**

| Step | Work | Estimate |
| --- | --- | --- |
| 1 | Per-user CA generation, private key in the Keychain, ACL-restricted to our signed identities | 4 days |
| 2 | Trust installation + removal + repair. **This is the one place the user is asked for a password** (a user-domain certificate trust change prompts for the login password). It is opt-in, per-feature, and reversible — but it must be presented as what it is. | 3 days |
| 3 | Per-name short-lived leaf issuance; **decide where TLS terminates.** If the proxy is in the guest, leaf private keys are in the guest. Recommended: issue on the host, push over vsock, hold in guest tmpfs, keep the CA key on the host only, keep leaves short. This needs a written security ruling before code. | 4 days |
| 4 | Name constraints as defence in depth, plus honest verification of what Safari, Chrome and Firefox actually honour for a user-added root (Firefox uses its own trust store and will need manual import or will simply not work) | 3 days |

DIF-5's cost to the user is one password prompt, once, only if they turn HTTPS on. That is
a defensible ask. It is a materially different ask from a password prompt at first run —
and with this decision, first run stays clean.

---

## What must change in `docs/domains.md`

Not rewritten here (it is a contract document, and this is a decision document), but it is
now wrong in four places and DOC-4 should carry the fix:

1. "There is no `/etc/resolver` fallback" — there is; it is option 2, priced above.
2. The `*.morb.test` recommendation — withdrawn in favour of `.local` via mDNS.
3. "The S5 gate must prove the signed per-user process can own the standard loopback
   port" — proved impossible; the listener moves into the guest.
4. The host-side router + `PortForwarder` transport-lease contract — applies only to the
   degraded fallback path, not to the primary design.

---

## Sources

- [Network Extensions entitlement reference](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.networking.networkextension)
- [`NEDNSSettingsManager`](https://developer.apple.com/documentation/networkextension/nednssettingsmanager) ·
  [`dnsSettings`](https://developer.apple.com/documentation/networkextension/nednssettingsmanager/dnssettings) ·
  [`NEDNSSettings`](https://developer.apple.com/documentation/networkextension/nednssettings)
- [Apple DTS on enabling a DNS settings configuration on macOS](https://developer.apple.com/forums/thread/671196)
- [Apple forums: authorizing LaunchDaemons / `SMAppService`](https://developer.apple.com/forums/thread/761249)
- [OrbStack container domains](https://docs.orbstack.dev/docker/domains) ·
  [container networking](https://docs.orbstack.dev/docker/network)
- [orbstack#2274 — `.local` overridden by upstream DNS](https://github.com/orbstack/orbstack/issues/2274)
- [OrbStack author's list of installed files (HN)](https://news.ycombinator.com/item?id=39722284)
- `resolver(5)`, `dns_sd.h`, and `dns-sd(1)` on macOS 26.4
