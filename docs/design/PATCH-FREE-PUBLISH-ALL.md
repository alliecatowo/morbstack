# Patch-free `docker run -P`: the userland-proxy wrapper

**Date:** 2026-08-04. **Status:** implemented; runtime proof recorded below.
**Decides:** TECH-1 (see `docs/audit/TECHNOLOGY-AUDIT.md` Bet 6). **Supersedes:**
the downstream Moby patch, the vsock 2379 publish-all allocator protocol, and
the entire patched-engine build/release apparatus (SP-4,
`docs/design/ENGINE-BUILD-DECISION.md`).

## The decision

Morbstack ships **stock upstream dockerd, unmodified**, and serves every
published port — including the `-P` set only dockerd can compute — through
dockerd's stock `--userland-proxy-path` hook. The hook is upstream, documented,
and load-bearing for Docker Desktop itself; nothing about it is Morbstack's to
rebase ever again.

What was deleted with the patch:

- `guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch` (174
  lines of engine change, well-made and no longer needed)
- `scripts/build-morbstack-dockerd.sh`, `scripts/fetch-moby-source.sh`,
  `mise-tasks/build-patched-dockerd`, `.github/workflows/build-engine.yml`,
  the `--morbstack-dockerd-only` fetch path, `dist/guest-bin/morbstack-dockerd`
- guest `publish_all.rs` (vsock 2379 broker) and host
  `PublishAllPortAllocator.swift`, plus every publish-all session, recovery
  and release-on-stop branch in `PortForwarder`
- **the Docker-to-build-Docker bootstrap**: building Morbstack no longer
  requires Docker, buildx, or a Moby source checkout in any form

## The dockerd ↔ proxy contract, pinned from source

Verified against the pinned engine source, Moby tag `docker-v29.7.1`, commit
`c5b8ce9274b5c00cb1f8287c8e258edc1f01176d` (the same version as the shipped
static binaries), 2026-08-04:

- `daemon/libnetwork/portmapper/proxy_linux.go` `StartProxy` execs the
  configured proxy path once per published port binding with argv:

  ```
  <proxy-path> -proto tcp -host-ip 0.0.0.0 -host-port 49153 \
               -container-ip 172.17.0.2 -container-port 80 [-use-listen-fd]
  ```

- **fd 3** is a pipe to dockerd ("signal-parent",
  `cmd/docker-proxy/main_linux.go`). The proxy writes `"0\n"` on success or
  `"1\n<error>"` on failure. dockerd waits up to **16 seconds**
  (`time.After(16 * time.Second)`) before giving up on the proxy.
- **fd 4** (with `-use-listen-fd`, which modern dockerd always passes —
  `drivers/bridge/port_mapping_linux.go` `mapPorts`) is the host-port
  listener socket dockerd already bound *inside the guest* via its
  portallocator. The in-guest bind is dockerd's own business; the Mac-side
  bind is the wrapper's.
- A proxy that exits non-zero or reports `"1\n…"` fails
  `mapPorts` → `addPortMappings` → **the container start fails** with
  `failed to start userland proxy for port mapping …: <our reason>`. There is
  **no retry with another port**, fixed or dynamic — the error surfaces
  honestly.
- One proxy per binding **per address family**: an unspecified host IP
  expands to `0.0.0.0` and (only when the network is IPv6-enabled) `[::]`
  (`sortAndNormPBs`). The default bridge is IPv4-only, so the common case is
  one proxy per port.
- Stop is `SIGINT` (`cmd.Process.Signal(os.Interrupt)`), with
  `Pdeathsig: SIGTERM` if the daemon thread dies. The proxy is re-execed on
  every container start/restart, after dockerd has re-resolved the effective
  port set — which is exactly when `-P` reallocates.

## The wrapper

`/usr/local/bin/morbstack-docker-proxy` is a symlink to `/init` — morbinit is
a multi-call binary and dispatches on argv[0]
(`guest/morbinit/src/proxy_wrapper.rs`). morbinit points dockerd at it via
`--userland-proxy-path` (`supervisor.rs`), falling back to the stock proxy
path only if the link is somehow missing (with a logged warning that
fail-closed Mac binding is lost).

Per invocation the wrapper:

1. Parses the five values above. `-v`/`-version` probes and `-proto sctp`
   exec the stock proxy directly (nothing to hold on the Mac); any other
   unparseable invocation **fails closed** on fd 3.
2. Connects out over AF_VSOCK to the host (`VMADDR_CID_HOST`, port **2382** —
   the port registry's only guest-initiated channel) and sends one line:

   ```
   LEASE <tcp|udp> <host-ip> <host-port> <container-ip> <container-port>\n
   ```

3. Waits (bounded at 12 s, inside dockerd's 16 s budget) for `OK\n` or
   `ERR <reason>\n`.
4. On `OK`: leaves the lease connection open — deliberately **not**
   close-on-exec — and execs the stock `docker-proxy` with the original argv.
   fd 3, fd 4 and the lease fd all survive the exec, so readiness signaling,
   the pre-bound in-guest listener, and the lease all behave as if the stock
   proxy had been invoked directly.
5. On `ERR`, connect failure, or timeout: writes `1\n<reason>` to fd 3 and
   exits 1. dockerd fails the start with the reason in the error.

**Lease lifetime is process lifetime.** When dockerd stops the container it
kills the proxy; the vsock connection EOFs; the host releases the Mac
listener. Container stop, `docker rm -f`, restart policy, dockerd shutdown
and VM teardown are all the same signal. There is no session registry, no
re-registration on restart, and therefore no SP-6 class of bug: the failure
mode where the first `-P` start worked and every restart failed (a broker
session EOF'd 6 ms after its first allocation) is eliminated by construction,
not by bookkeeping.

## The host side

`VMManager.setGuestInitiatedConnectionHandler` installs a
`VZVirtioSocketListener` on host port 2382 on **every** VM the manager
creates (cold boot and restore), so a restart-policy container whose proxy
asks at guest boot always finds a listener.
`GuestPortLeaseServer` (`mac/Sources/MorbstackKit/GuestPortLease.swift`)
reads the one bounded request line, and `PortForwarder.leaseGuestProxyPort`
applies the ledger semantics:

- **Fresh** — nothing holds the endpoint: bind the exact requested
  address/port (TCP listener or UDP datagram listener), forward through the
  existing stream-dial (2376) / datagram-dial (2378) paths to the guest's own
  proxy listener at `127.0.0.1:<host-port>`, hold until EOF.
- **Adopted** — explicit `-p` runs through the create preflight *and* execs
  the wrapper. When a fixed create/start lease already holds the exact
  socket, the wrapper's lease succeeds without taking ownership; the fixed
  lifecycle (create/start/destroy) keeps it, and releasing the adopted lease
  is a no-op.
- **Takeover** — an event-discovered forward from a container lifecycle the
  snapshot hasn't caught up with still holds the socket: it is displaced.
  The wrapper speaks for the start happening *now*.
- **Refusal** — the endpoint is genuinely busy (another Mac process, or the
  user's port-exposure setting forbids the address): `ERR` with the honest
  reason, which becomes dockerd's container-start error.

Proxy-leased endpoints are excluded from the event-driven reconciliation
diff (their lifecycle is the lease connection), but the snapshot still
supplies the container identity for `morb status` display. The exposure
policy (`localNetwork`/`loopbackOnly`) is enforced on the lease path exactly
as on every other bind path — listeners are never silently rewritten to
loopback.

## Why fail-closed beats reactive discovery

Lima and gvisor-tap-vsock run stock dockerd and discover listening sockets
reactively (polling `/proc/net/tcp`, or explicit `Expose()` calls after the
fact). That answers the "Moby only knows the effective `-P` set after
`HostConfig` is fixed" objection recorded in `ENGINE-BUILD-DECISION.md` — but
it is **fail-open**: when the Mac cannot bind the port, the container runs
anyway and its published port silently doesn't answer, plus there is a
start-to-forward race window on every start.

The wrapper answers the same objection **fail-closed**: dockerd itself execs
the wrapper only after it has resolved the effective set, and cannot report
the start as successful until the Mac holds the port. A host collision
becomes `docker: Error response from daemon: … port is already allocated` —
the same honest refusal a busy port produces on native Linux. This is the
project's fail-closed admission philosophy applied at the one hook upstream
already provides for exactly this purpose.

## Wire protocol (registry entry 2382)

```
guest -> host:  "LEASE <tcp|udp> <host-ip> <host-port> <container-ip> <container-port>\n"
host  -> guest: "OK\n"           endpoint bound and forwarding
           or:  "ERR <reason>\n" then close
release:        connection EOF (either side), or forwarder stop
```

One ASCII line each way, byte-at-a-time bounded reads on both ends (256-byte
line cap host-side, 512 guest-side; 10 s host read timeout, 12 s guest reply
timeout), reasons flattened to one line so an error can never forge a second
frame — the same discipline as the 2376 stream-dial grammar. Both parsers are
unit-tested on the dev host (`GuestPortLeaseTests.swift`,
`proxy_wrapper.rs` tests). This channel replaces the retired 2379 protocol
(REGISTER/TRACE/ALLOC, three line grammars and a per-container session
registry on each side) with one stateless request per proxy process.

## Residual gaps, named honestly

- **SCTP** publishes exec the stock proxy without a Mac lease: macOS offers
  no SCTP listener to hold. Guest-side (container-to-container) SCTP still
  works. This matches the pre-existing behavior (the patched path never
  forwarded SCTP either).
- **IPv6-only publishes** (`-p '[::1]:8080:80'`): the Mac listener binds, but
  the stream-dial data path dials the guest at `127.0.0.1:<host-port>`, so
  traffic only flows when a v4 sibling listener exists in-guest. Pre-existing
  limitation of the dial path, unchanged by this work. Default `-P`
  publishes are v4 and unaffected.
- **Dynamic collision retry**: if the in-guest allocator picks an ephemeral
  port that is busy on the Mac, the start fails honestly; upstream provides
  no hook to ask for a different port (verified: no retry around proxy
  startup in v29.7.1). Rare — the collision has to land inside the guest's
  ephemeral range — and `docker start` again simply picks the next port.
- The explicit-`-p` create preflight and the wrapper now both guard fixed
  publishes (create-time refusal + start-time adoption). That redundancy is
  deliberate for this change — the preflight also carries bind-mount
  admission and stopped-container port retention — but consolidating fixed
  `-p` onto the wrapper path alone is a real future simplification.

## Proof

Runtime acceptance on a real engine, recorded 2026-08-04 (see EN-2):

<!-- PROOF-RESULTS -->

## What this unblocked

- The headline claim is true again in the right direction: **unmodified
  upstream dockerd**, with all Morbstack behavior in mac-side glue plus one
  guest-side wrapper binary Morbstack fully owns.
- SP-4 / `ENGINE-BUILD-DECISION.md` superseded: there is no non-upstream
  engine artifact to build, attest, or release.
- OPS-9: the CI guest-image job needs no Docker and no engine release asset.
- The rebase tax on every future Moby release is gone; engine upgrades are
  again "bump the pinned version, verify the hashes" — plus one source check
  that the `StartProxy` argv/fd contract is unchanged.
