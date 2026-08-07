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

- **Host → guest reachability at `192.168.64.x`.** Confirmed with a real booted VM on
  2026-08-06 — see "DIF-4 step 0 — host→guest reachability gate" below for the full
  evidence and, just as importantly, what was **not** tested (Ethernet, VPN, network
  change events).
- Everything about `NEDNSSettings`, `NEDNSProxyProvider`, entitlement acquisition, SMAppService
  authorization, and certificate trust prompts — all documentation and forum sourced, cited
  inline below.
- **OrbStack was not installed on this machine and was not installed for this spike.** All
  OrbStack claims below are from its public documentation, its issue tracker, and its
  author's own public statements.

---

## DIF-4 step 0 — host→guest reachability gate (executed 2026-08-06, UX-15)

**Result: PASS, on the one configuration tested (Wi-Fi, no VPN).** Recorded here per the
gate in the estimate table below: *"if this fails, drop to the `127.0.0.1` + high-port
fallback and re-estimate."* It did not fail on this configuration, so UX-15 (surfacing the
guest address in the inspector and `morb status --json`) proceeds — but the field's
`nil`-on-unknown design already assumes the untested configurations below can fail, and
nothing here changes that assumption.

macOS 26.4 (25E246), same build as the original spike. Used a Morbstack guest that was
already running (not booted for this test) with three containers up, so this is evidence
against a live daemon under real load, not a freshly booted idle VM.

**Network conditions tested:** Wi-Fi (`en1`, default route via gateway `10.0.0.1`). No VPN
configured (`scutil --nc list` returns no connections) and none active; the `utun0`–`utun3`
interfaces present are macOS's own idle tunnel interfaces, not a VPN session.

**Network conditions NOT tested, and why:** Ethernet-only, and any VPN — especially one that
captures or tunnels `192.168.64.0/24`, which `docs/domains.md` and this document both flag
as "the obvious risk." Also not tested: what happens to reachability across a live network
change (Wi-Fi ↔ Ethernet, sleep/wake) while a session is in progress. All three would
require either a second physical network path or disrupting a VM another agent was actively
using for unrelated work; neither was available in this session. These remain open risks the
step-3/step-4 guest-side proxy work should re-verify before it depends on this address being
stable across a network transition.

### Evidence

The guest's pinned MAC is `02:4d:52:42:00:01` (`VMManager.guestMACAddress`). macOS's own
`vmnet` DHCP server records leases at `/var/db/dhcpd_leases` (world-readable, root-owned);
the live entry for that MAC:

```
{
	ip_address=192.168.64.27
	hw_address=1,2:4d:52:42:0:1
	identifier=1,2:4d:52:42:0:1
	lease=0x6a753482
}
```

(macOS omits leading zeros in `hw_address`; `2:4d:52:42:0:1` and the pinned
`02:4d:52:42:00:01` are the same MAC.) `lease=0x6a753482` decodes to 2026-08-06 18:27:30,
roughly the one-hour grant window after this daemon's start — an ordinary, unremarkable
lease, not a fixture.

**ICMP, to the real address vs. an unleased address on the same segment:**

```
$ ping -c 4 192.168.64.27
64 bytes from 192.168.64.27: icmp_seq=0 ttl=64 time=9.295 ms
64 bytes from 192.168.64.27: icmp_seq=1 ttl=64 time=0.651 ms
2 packets transmitted, 2 packets received, 0.0% packet loss

$ ping -c 2 192.168.64.100      # no lease in the file for this address
Request timeout for icmp_seq 0
100.0% packet loss
```

`route get 192.168.64.27` resolves via `bridge100` — the same `vmnet` bridge
`ifconfig bridge100` shows with `vmenet0` as its only member — confirming the reply comes
over the local NAT segment, not a real network hop.

**TCP, to a container's published port, bypassing the host's own loopback forward
entirely:** `web-front` publishes `0.0.0.0:8090->80/tcp` (`docker ps`, via
`~/.morbstack/run/docker.sock`) — a non-loopback bind inside the guest, per
`guest/morbinit/src/proxy_wrapper.rs`'s `-host-ip 0.0.0.0` contract.

```
$ nc -z -v 192.168.64.27 8090
Connection to 192.168.64.27 port 8090 [tcp/*] succeeded!

$ curl -o /dev/null -w '%{http_code} from %{remote_ip}:%{remote_port}\n' http://192.168.64.27:8090/
200 from 192.168.64.27:8090
```

For comparison, the same request through the Mac's existing loopback port forward:

```
$ curl -o /dev/null -w '%{http_code} from %{remote_ip}:%{remote_port}\n' http://127.0.0.1:8090/
200 from 127.0.0.1:8090
```

Both succeed, which on its own would be consistent with `.27` just being a NAT alias for
the same forward. The next two results rule that out — they show the guest's TCP stack
itself is answering, not a translation rule that would echo any port:

```
$ nc -z -v 192.168.64.27 9999    # a port nothing in the guest is listening on
nc: connectx to 192.168.64.27 port 9999 (tcp) failed: Connection refused

$ nc -z -v 192.168.64.100 8090   # an unleased address, same port
nc: connectx to 192.168.64.100 port 8090 (tcp) failed: Operation timed out
```

`192.168.64.27:9999` came back **refused** — actively answered by a real TCP stack with no
listener on that port. `192.168.64.100:8090` **timed out** — nothing answers for an address
with no lease. If `192.168.64.27` were being answered generically (a NAT device replying for
the whole subnet, or the host's own forwarding table being consulted instead of the guest),
`9999` would time out too, the same as `.100` does. It does not: the guest kernel is the one
answering, at its own address, independent of anything the host's `PortForwarder` already
does at `127.0.0.1`.

### What this does and does not license

This proves the address is real and reachable *today, on this network, with no VPN*. It does
not prove the address is stable: the lease file above has 26 prior leases for other MACs
(`.2` through `.26`), consistent with the same host handing out a new address each time a
`vmnet`-backed VM (Morbstack's or anything else's) boots. A caller must re-resolve the
address every time it is needed and must never persist or infer it across a VM restart —
which is exactly what `GuestNetworkAddressLookup.currentAddress()` does (reads the lease file
fresh, keyed by MAC, every call) and why `Daemon.swift` reports `null` rather than a stale
guess whenever the VM is not `.running`.

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
| 0 | Prove host→guest reachability at `192.168.64.x` with a real booted VM, on Wi-Fi, on Ethernet, and under a VPN. **Gate: if this fails, drop to the `127.0.0.1` + high-port fallback and re-estimate.** **Wi-Fi/no-VPN: PASS, executed 2026-08-06 — see "DIF-4 step 0" above. Ethernet and VPN remain untested; do not treat this row as fully closed.** | 2 days, ~0.5 remaining for the two untested conditions |
| 1 | mDNS registrar in `morbstackd`: `DNSServiceRegisterRecord`, `LocalOnly`, `A` only, no advertised Bonjour service type, conflict handling, lifecycle bound to Docker events | 4 days |
| 2 | Name derivation + registry, wired to the existing `MorbLocalDomain.Name` validator (the loopback `LocalDomainClaimReconciler` was deleted under SP-5 — it validated claims against `PortForwarder` host-loopback snapshots, the rejected host-router model; the mDNS registrar keeps its own name-to-container index and duplicate rejection) | 3 days |
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
