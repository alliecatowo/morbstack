# Fixed UDP publication transaction

Status: source implementation complete; **live Docker/VM acceptance is still
required and this is not a release claim**. This records the P0 transaction for
ordinary fixed Docker CLI UDP publication such as
`docker run -p 5353:53/udp image`. The later bounded dynamic transaction covers
omitted, empty, and exact-zero UDP `HostPort` values; see
[`dynamic-port-allocation.md`](dynamic-port-allocation.md). This fixed-path design
still excludes `-P`, raw dynamic host-port ranges, IPv6 UDP, and arbitrary Engine API
shapes.

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

## Source implementation

`PortForwarder.PortLease` is now the one transport-indexed ledger record: it carries
separate TCP and UDP publication lists and listener dictionaries under one container
identity. `DockerProxy` reserves the whole strict fixed plan before it forwards the
create, and a bind failure rolls both transport sets back before the guest observes
any create bytes. TCP and UDP may use the same numeric host port because their socket
spaces remain separate.

`UDPListener` now has a lock-protected `setDatagramHandler(_:)` transition. A held
UDP listener starts in drain-only mode; after the exact successful start or restart
response, the forwarder installs its handler and active `UDPForward` record while its
ledger is locked. A callback that was already in flight after a stop is rejected by
that active-forward ledger before it can open or keep a guest flow.

The normal event reconciler retains its role for opaque/name-based lifecycle calls,
but it may promote a held lease only after `containers/json` proves the complete
retained TCP+UDP set belongs to the one associated container. Stop clears both active
maps and UDP flows while retaining sockets; destroy/failed create/daemon stop releases
both sets. Full-ID stopped-container recovery uses a strict inspect plan for the
complete transport set before it relays start or restart.

The source boundary is one transport-indexed `PortLease`, not a second UDP ledger.
It retains distinct listener objects and maps for TCP and UDP and never shares a
socket, flow, or numeric-port dictionary across transports.

1. **Admission.** The fixed-path parser accepts only fixed UDP `HostPort` values
   `1...65535`, protocol `udp`, and host addresses `""`, `"0.0.0.0"`, or
   `"127.0.0.1"`. Its omitted/empty/zero UDP forms take the later bounded dynamic
   transaction instead; it rejects raw dynamic host-port ranges, `-P`, IPv6 UDP,
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

## Pending acceptance matrix

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

The source now implements the fixed UDP create/start reservation contract above.
Until this matrix passes against a signed candidate, it remains **implemented pending
live acceptance**, not a release compatibility claim.
