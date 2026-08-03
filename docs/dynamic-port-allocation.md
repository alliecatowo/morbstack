# Dynamic published-port allocation

Status: design prerequisite. This document deliberately records a boundary; it does
not enable dynamic published ports yet.

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

## Current boundary

Until that transaction exists, the following stay outside the synchronous publication
guarantee:

- Empty or omitted `HostPort` values, including `HostPort: "0"` when the Engine treats
  it as dynamic.
- `HostConfig.PublishAllPorts` (`docker run -P`), which needs every eligible
  `ExposedPorts` entry materialized into an explicit binding.
- Host-port ranges, which need an unambiguous container-port-to-host-port mapping
  before any listener can be reserved.
- A dynamic request whose HTTP framing or JSON shape cannot be proved within the
  transaction's explicit limits.

The existing proxy preserves those API calls byte-for-byte for the guest Engine. It
does **not** represent a later event-derived listener as proof that the create/start
reply had a matching host endpoint. Fixed TCP leases, explicit UDP's availability
diagnostic, event reconciliation, and loopback-only address/protocol validation are
unchanged by this document.

## Required allocation transaction

The future implementation must be a separately owned, stateful create path with these
invariants:

1. Classify a dynamic create before any request byte reaches the guest. Only normal
   HTTP/1.x `POST .../containers/create` with a complete, bounded body may enter this
   path. Chunked, malformed, oversized, upgraded, or otherwise opaque dynamic creates
   must receive a clear pre-create error; forwarding them dynamically would restore the
   race this design exists to remove. Non-dynamic opaque traffic continues through the
   raw relay.
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

## Why this is a larger protocol change

Reading a single create body is not sufficient. A Docker client may keep the Unix
connection alive, and the first read that completes a request can already contain a
following pipelined request. A correct transformer must retain and forward those
bytes, preserve HTTP framing and half-close behavior in both directions, and then
transition safely into raw relay mode for ordinary Engine traffic. It must also observe
the transformed create response without releasing it before container-ID association.

`MinimalHTTP` is deliberately a read-only parser and `FDRelay` deliberately has no
byte-mutation hook. Extending either opportunistically would make it a partial generic
HTTP proxy with silent data-loss or semantic risk. The work therefore needs a new
component with an explicit ownership model, such as
`DockerCreateTransactionRelay`, rather than a small change to preflight.

## Delivery plan and acceptance evidence

Build the transaction in narrowly enabled stages, while retaining raw relay behavior
for all non-dynamic calls:

1. Establish the stateful buffering/half-close component and prove it preserves a
   keep-alive create followed by another request, including a request already buffered
   with the create body. Add unit coverage for request parsing, JSON rewrite,
   `Content-Length`, unsupported-shape rejection, and cleanup on every response path.
2. Add one explicit empty `HostPort` for TCP. Verify a competing Mac bind fails before
   guest create, then verify the created container's reported port equals the still
   held Mac listener and is reachable immediately after a successful start response.
3. Add explicit UDP using a true UDP reservation/lease (not the present availability
   snapshot), including bidirectional datagrams and same-number TCP+UDP publication.
4. Add `PublishAllPorts` and ranges only after their mappings have dedicated parser,
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
