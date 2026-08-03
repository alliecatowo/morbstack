# Dynamic published-port allocation

Status: Phase 1 implementation complete; live Docker/VM acceptance evidence pending.
This document distinguishes the implemented bounded TCP transaction from the broader
dynamic-publication work that remains. It is not a release claim until the live matrix
at the end passes.

## Decision

Morbstack must not claim synchronous support for dynamic host-port publication until
the host has selected and retained the exact loopback endpoint that the guest Engine
will persist. This applies to both `-p <container-port>` / an empty `HostPort` and
`-P` / `PublishAllPorts`. Event or `containers/json` discovery after a successful
create or start is useful reconciliation, but it is not an allocation contract.

The existing fixed-TCP lease remains the deliberately smaller mechanism: it sees a
concrete port without consuming the request, binds that port on the Mac, and only
observes the normal Engine response. Existing UDP forwarding remains event-confirmed
once Docker reports a concrete endpoint. Neither mechanism can make an Engine-chosen
dynamic port match a previously reserved Mac endpoint.

## Why this cannot be added to the passive relay

Docker receives port bindings in `POST /containers/create` and its successful create
response contains a container ID and warnings, not the dynamically selected binding.
The binding becomes observable later through inspection/listing APIs. See the
[Engine create endpoint](https://docs.docker.com/reference/api/engine/version/v1.40/#tag/Container/operation/ContainerCreate)
and Docker's [port-publishing documentation](https://docs.docker.com/engine/network/port-publishing/).

Today `DockerProxy` does a bounded `MSG_PEEK`, then gives both descriptors to
`FDRelay`. It never removes, changes, delays, or inserts request bytes; `FDRelay`'s
observer is notification-only. Consequently the guest's unmodified `dockerd` selects
an empty host port in the guest after the request has already crossed the boundary.
At that point the host has no way to reserve the same macOS loopback port before
Docker reports success. A guest control RPC cannot repair this by itself: upstream
`dockerd` has no callback through which it would ask that RPC to allocate a port.

The only truthful host-owned design is therefore to select a port first and make the
guest Engine receive that concrete port *in its create document*. That requires an
intentional request-transforming proxy path, not another passive observer.

## Implemented Phase 1 transaction

For one recognized normal `POST .../containers/create`, Morbstack now supports an
explicit empty `HostPort: ""` on one or more TCP `PortBindings` entries. It holds a
real `127.0.0.1` listener allocated by the macOS kernel, writes each concrete number
into a re-encoded create body and matching `Content-Length`, and sends that body to
the guest Engine. The host associates the full ID from a bounded normal `201` response
*before any `201` byte reaches the Docker client*. A later recognized start continues
to promote the same held listener under the existing lease lifecycle.

The transaction consumes precisely the original create header and declared body; it
does not read ahead. On an HTTP keep-alive connection, it closes only the guest-side
one-request connection and gives the unconsumed client socket back to `DockerProxy`
for a fresh preflight. That means a same-connection or already-pipelined `start`
request still takes the normal start-response activation path after the create ID is
associated. A client-requested `Connection: close` closes normally after the create
response instead.

This Phase 1 path is bounded to a valid fixed-length JSON request already visible in
the existing 256 KiB preflight window, a single numeric `Content-Length`, no
`Expect: 100-continue`, and a nonchunked Engine response with at most 64 KiB of head
and 128 KiB of body. It returns a clear host error rather than exposing an unassociated
`201` if the response does not meet that contract.

## Fixed-TCP recovery after a VM stop

The listener itself is intentionally not persisted across a VM/daemon stop: while the
guest is absent, accepting the Mac port would be a false availability claim. The next
bodyless `POST /containers/<canonical-full-64-lowercase-hex-id>/start` instead gets
a bounded inspect on a fresh Docker-API vsock connection after the guest is ready.
Morbstack accepts that
recovery only when the inspect response proves the same stopped ID and every
`HostConfig.PortBindings` entry is a concrete, unambiguous loopback TCP endpoint. It
then binds and associates all listeners under the current forwarder generation before
relaying the original start bytes; the existing exact-`204` observer remains the only
activation handoff.

This is not durable host-side lease persistence or general start interception. A
name/unique-prefix start, inspect or lifecycle failure, a running container, empty or
zero host port, range, UDP/non-TCP, unsupported address, malformed/ambiguous binding,
or a non-bodyless request remains an unchanged relay with no synchronous recovery
claim. If a fully proved endpoint cannot be bound on macOS, the start is rejected
before it reaches the Engine rather than reporting a container that Morbstack cannot
publish.

## Still outside the synchronous guarantee

The following remain unsupported or explicitly outside this transaction:

- Omitted `HostPort`, `HostPort: "0"`, and any opaque/slow/oversized create that does
  not enter the bounded preflight. They retain the raw Engine relay and therefore make
  **no** Phase 1 synchronous allocation claim.
- `HostConfig.PublishAllPorts` (`docker run -P`), which needs every eligible
  `ExposedPorts` entry materialized into an explicit binding.
- Host-port ranges, which need an unambiguous container-port-to-host-port mapping
  before any listener can be reserved.
- Dynamic UDP, dynamic TCP combined with a non-TCP sibling, non-loopback addresses,
  missing/ambiguous binding fields, and unsupported protocols. UDP's existing
  post-start datagram forwarding remains unchanged; it is not a held dynamic lease.
- Chunked, malformed, upgraded, or otherwise opaque dynamic HTTP framing, and
  nonstandard/oversized/chunked create responses.

No event-derived listener is represented as proof that its create/start reply had a
matching host endpoint. Fixed TCP leases, explicit UDP's availability diagnostic,
event reconciliation, and loopback-only address/protocol validation are unchanged.

When event reconciliation cannot bind an endpoint that Docker has already reported,
`morb status` calls it an **unavailable host forward** and explicitly says that the
Docker CLI may still display it as published. This is a post-create diagnostic, not a
retroactive allocation guarantee: it does not make `-P`, ranges, dynamic UDP,
omitted-host-port, or opaque/chunked creates synchronously supported.

## Required work beyond Phase 1

Further allocation work must preserve these invariants:

1. Extend classification only when the exact framing and JSON ownership can be proved.
   Chunked, malformed, oversized, upgraded, or otherwise opaque dynamic creates must
   either receive a clear pre-create error or remain explicitly outside the synchronous
   contract; forwarding one dynamically would restore the race this design removes.
2. Parse the create JSON exactly enough to identify published TCP and UDP bindings,
   loopback address spelling, and `ExposedPorts`. Reject unsupported protocols,
   addresses, ambiguous duplicates, and ranges before a guest side effect. TCP and UDP
   use independent reservations, so they may legitimately share one numeric port.
3. The host allocator chooses candidate numeric ports and *holds real macOS loopback
   listeners/sockets* before the request is forwarded. A candidate may be released
   only on a failed create, a failed association, destroy, forwarder/VM shutdown, or
   the relevant documented lifecycle transition.
4. Rewrite every dynamic binding into the selected single concrete `HostPort`. For
   `PublishAllPorts`, materialize supported `ExposedPorts` into concrete `PortBindings`
   and clear `PublishAllPorts`, so the guest Engine sees only the host-selected values.
   Re-encode the body and its `Content-Length`; do not depend on a later inspect call
   to learn an endpoint.
5. Send that rewritten document to the guest Engine. Its normal create success proves
   that the selected number was usable in the guest as well as already reserved on the
   host. If guest bind/setup fails, return Docker's failure and release every host
   reservation. The transaction associates the returned full container ID before the
   create response bytes are released to the client.
6. Preserve the fixed lease's start truthfulness: only a recognized successful start
   may activate the held forwarder, and activation happens before its success response
   becomes client-visible. Create failure, client disconnect, start failure, destroy,
   and reconciliation of an absent container must all retire the transaction without a
   leaked reservation.

## Why the remaining work is still a larger protocol change

Reading a single create body is not sufficient. A Docker client may keep the Unix
connection alive, and the first read that completes a request can already contain a
following pipelined request. A correct transformer must retain and forward those
bytes, preserve HTTP framing and half-close behavior in both directions, and then
transition safely into raw relay mode for ordinary Engine traffic. It must also observe
the transformed create response without releasing it before container-ID association.

`MinimalHTTP` is deliberately a read-only parser and `FDRelay` deliberately has no
byte-mutation hook. Phase 1 therefore adds a separate
`DockerDynamicCreateTransaction` with explicit ownership, rather than weakening the
raw relay. Broader forms must extend that transaction deliberately rather than turning
either existing primitive into a partial generic HTTP proxy.

## Delivery plan and acceptance evidence

Build the transaction in narrowly enabled stages, while retaining raw relay behavior
for all non-dynamic calls:

1. **Implemented, pending execution:** the bounded stateful TCP transaction preserves
   unread keep-alive bytes for fresh preflight and includes offline parser/rewrite
   coverage. Verify that a competing Mac bind fails before
   guest create, then verify the created container's reported port equals the still
   held Mac listener and is reachable immediately after a successful start response.
2. Add explicit UDP using a true UDP reservation/lease (not the present availability
   snapshot), including bidirectional datagrams and same-number TCP+UDP publication.
3. Add `PublishAllPorts` and ranges only after their mappings have dedicated parser,
   collision, lifecycle, and recovery tests. Do not infer range semantics from string
   splitting.

The integration matrix must cover direct Docker API clients as well as Docker CLI,
create without start, start retry, create/start failure, client disconnect, destroy,
daemon restart, VM shutdown, externally occupied TCP and UDP ports, and simultaneous
TCP/UDP on one number. A live VM run is the evidence gate; static tests alone cannot
prove host reservation or guest-Engine acknowledgement.

## Non-options

- Do not call `containers/json` or inspect after a successful create and call that an
  allocation guarantee.
- Do not reserve a random Mac port while letting dockerd choose a different guest
  port.
- Do not add a guest allocator RPC unless the transformed create transaction supplies
  its result to dockerd before the Engine persists the binding.
- Do not advertise dynamic publication as drop-in compatible until the live matrix
  above passes.
