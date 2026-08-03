# Fixed UDP publication transaction

Status: researched design; **not implemented** and not a release claim. This is the
P0 design boundary for ordinary fixed Docker CLI UDP publication such as
`docker run -p 5353:53/udp image`. It deliberately excludes dynamic UDP, `-P`,
raw dynamic host-port ranges, IPv6 UDP, and arbitrary Engine API shapes.

## What Docker does

The normal Docker CLI parses `-p` with
[`nat.ParsePortSpecs`](https://github.com/docker/cli/blob/master/cli/command/container/opts.go#L400-L432).
The upstream parser records the protocol and emits one concrete mapping for each
equal-length fixed range; a one-container-port host range remains an Engine-side
host-port range ([`ParsePortSpec`](https://github.com/docker/go-connections/blob/master/nat/nat.go#L159-L219)).
Thus ordinary fixed UDP is present in the create document as a concrete
`HostConfig.PortBindings` entry with a `/udp` container-port key.

Moby does **not** prove that the guest UDP endpoint is programmed at create time.
`ContainerStart` calls `initializeNetworking` before it records a successful start
([`daemon/start.go`](https://github.com/moby/moby/blob/master/daemon/start.go#L65-L246)).
That network setup copies each persisted `HostConfig.PortBindings` entry into a
protocol-bearing libnetwork port binding, preserving its fixed `HostPort` or
range ([`daemon/container_operations.go`](https://github.com/moby/moby/blob/master/daemon/container_operations.go#L103-L155)).
On cleanup, Moby releases the network sandbox and its port state
([`daemon/container_operations.go`](https://github.com/moby/moby/blob/master/daemon/container_operations.go#L916-L967)).

Consequently a truthful Morbstack fixed-UDP guarantee must mirror the existing
fixed-TCP timing: reserve the Mac endpoint before create, retain it after a
successful create, and enable forwarding only after the exact successful start or
restart response. A create `201` is an identity proof, not guest UDP-bind proof.

## Why the existing UDP path cannot make that guarantee

Today `PortForwarder` creates `UDPListener` only from an event-confirmed
`containers/json` endpoint. `UDPListener` is correctly an exclusive IPv4 loopback
datagram socket: it sets neither reuse option, and one listener owns every client
flow and reply source tuple. That is a sound data plane, but it is post-start and
can lose the Mac host-port race.

The fixed-TCP ledger is a different ownership system: one `TCPPortLease` has one
container identity, held listeners, a create-response association, and an exact-204
start handoff. A second independent UDP lease would be wrong: a fixed TCP+UDP create
can legally use the same numeric port in separate transport spaces, but association,
rollback, event promotion, destroy, restart, and VM-stop recovery must succeed or
retire for the **whole create**. Two records could partially activate or release the
same container transaction.

The current `UDPListener.onDatagram` property is also installed before `start()` and
read on the listener queue. A held UDP socket needs an explicit synchronized handler
transition, not a mutation of that property from the proxy/lifecycle queue while a
datagram drain is reading it.

## Required implementation shape

Implement this only as one transport-indexed `PortLease` replacement for the
TCP-only record. It must retain separate listener objects and maps for TCP and UDP;
it must not share sockets, flows, or numeric-port dictionaries across transports.

1. **Admission.** Parse only fixed UDP `HostPort` values `1...65535`, protocol
   `udp`, and host addresses `""`, `"0.0.0.0"`, or `"127.0.0.1"`. Reject raw
   dynamic host-port ranges, omitted/empty/zero UDP host ports, `-P`, IPv6 UDP,
   unsupported protocols/addresses, ambiguous same-UDP-port targets, and opaque
   documents. Normal equal-length UDP ranges are individual fixed bindings only if
   the Docker CLI supplied them; they use the same bounded concrete-binding ceiling
   as fixed TCP.
2. **One reservation transaction.** Under `PortForwarder`'s existing ledger lock,
   bind all fixed TCP listeners and all fixed UDP listeners. UDP binds a real
   `127.0.0.1` datagram socket with no handler yet. If any bind or record insertion
   fails, stop every listener obtained by the transaction and return a Docker-style
   create error before bytes reach the guest. TCP and UDP may use the same numeric
   port because their socket/protocol spaces are independent.
3. **Create identity.** The bounded normal create-response observer associates the
   single lease with the returned full container ID before any `201` byte reaches the
   Docker client. A failed, disconnected, malformed, duplicate, or unrecognized
   response stops **both** transport listener sets.
4. **Start/restart handoff.** Claim the full-ID lease once. On the exact `204`, under
   the same ledger lock, install synchronized UDP handlers, create `UDPForward`
   records that retain the pre-bound sockets, and activate TCP records. A failed
   response removes the claim but keeps the stopped-container lease. Before this
   point UDP datagrams are drained and discarded; they never create a guest flow.
5. **Event reconciliation.** A running-container snapshot may promote a lease for a
   name/opaque start only after it proves every retained TCP and UDP binding belongs
   to that lease. Reconciliation must recognize the pre-bound UDP listener and update
   its metadata instead of calling `openUDPForward` and observing `EADDRINUSE` against
   Morbstack itself. A competing UDP target withdraws that UDP socket and its flows
   permanently from the lease; it never chooses an arbitrary target.
6. **Stop, destroy, VM stop, and recovery.** A normal container stop removes active
   UDP forwarding, closes its per-client vsock flows, clears the synchronized handler,
   and retains the exclusive socket for the stopped container. Destroy/failed create
   releases both transport sets. VM/daemon stop releases all listeners because no
   guest exists. A bodyless start/restart by the canonical full ID may recover only
   after inspect proves that *every* persisted binding in the group is fixed,
   unambiguous, and supported; it binds the entire TCP+UDP group before forwarding
   the unchanged lifecycle request. Names, prefixes, dynamic forms, partial inspect
   documents, and unsupported shapes remain raw relay with no synchronous promise.

## Acceptance matrix required before promotion

| Case | Required outcome |
| --- | --- |
| `-p 5353:53/udp`, otherwise free | Mac UDP socket is bound before guest create; create associates it; exact start `204` activates the same descriptor; a request and reply work. |
| Another Mac process owns `5353/udp` | Docker-style create failure before any guest create; no TCP/UDP listener from the transaction remains. |
| One fixed TCP plus one fixed UDP mapping, including the same number | Both remain independently bound and activate together, with no shared socket; any one bind failure rolls both back. |
| Fixed equal-length TCP or UDP range within the concrete-binding ceiling | Every endpoint is retained/activated/recovered, or none is created. |
| Omitted, empty, `0`, raw host-port range, `-P`, IPv6 UDP, SCTP, unsupported address, or opaque/mixed document | Rejected or raw-relayed exactly as the documented boundary says; never a partial UDP reservation. |
| Create failure, malformed/oversized response, client disconnect, or duplicate identity | Every reserved transport socket is released. |
| Exact full-ID start/restart failure then retry | No activation on failure; retry uses the same stopped lease. |
| Start by name or opaque client | Event snapshot promotes only after full lease-set proof; no rebind race. |
| Stop then exact full-ID start/restart | UDP flows close on stop, socket stays held, and the same socket activates after `204`. |
| VM/daemon stop then exact full-ID start | All sockets release while guest is absent; inspect-backed recovery reserves all supported fixed mappings before guest start. |
| Conflict/replacement/destroy | Competing target is withheld, replacement cannot steal the pre-bound socket, and destroy releases all resources. |

Until this design is implemented and this matrix passes against a signed candidate,
fixed UDP remains event-confirmed forwarding only. The existing UDP relay is real,
but it is not the fixed-TCP-style create/start reservation contract.
