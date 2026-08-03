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
observes the normal Engine response. This is also the standard Docker CLI path for a
fixed equal-length `-p` range: the CLI validates the spans and expands it into one
concrete `PortBindings` entry per container port before it sends the create request.
The [Docker CLI](https://github.com/docker/cli/blob/master/cli/command/container/opts.go#L400-L432)
hands publish options to `nat.ParsePortSpecs`; its
[upstream parser](https://github.com/docker/go-connections/blob/master/nat/nat.go#L159-L219)
rejects unequal container/host spans and produces those individual concrete mappings.
Existing UDP forwarding remains event-confirmed once Docker reports a concrete
endpoint. Neither mechanism can make an Engine-chosen dynamic port match a previously
reserved Mac endpoint.

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

## Source audit: why `-P` is not another empty `HostPort`

`PublishAllPorts` must stay outside Phase 1. It is not just a set of empty
`PortBindings` entries that a host-side JSON rewrite can see.

The normal Docker CLI constructs its create request's `Config.ExposedPorts` from
explicit `-p` and `--expose` options; it does not copy an image's Dockerfile
`EXPOSE` entries into that request. The daemon subsequently resolves `Config.Image`
and merges the image configuration during container creation. Its networking code
then clones `HostConfig.PortBindings`, adds every *merged* exposed port missing from
that map, and turns each empty binding into an ephemeral publication. The relevant
upstream paths are [Docker CLI option construction](https://github.com/docker/cli/blob/master/cli/command/container/opts.go#L2962-L3067),
[Moby image resolution and config merge](https://github.com/moby/moby/blob/master/daemon/create.go#L1337-L1387),
and [Moby's port-map expansion](https://github.com/moby/moby/blob/master/daemon/network.go#L912-L962).

Consequently, the ordinary `docker run -P image` body does not identify the complete
set that dockerd will publish. Rewriting only request-visible `ExposedPorts` would
silently omit ports supplied by the image, while waiting for `containers/json` or
inspect after create would again learn the endpoint too late to reserve it.

An extra image-inspect request is not a safe shortcut. A mutable tag can resolve to a
different image between that inspect and the unmodified create request. Rewriting the
create to an immutable image ID would close that particular race only by changing the
request's image-reference semantics, and still would not preserve `-P` lifecycle
semantics: upstream may release its allocated ports when a container stops and choose
new ones on a later start. Materializing fixed `PortBindings` and clearing
`PublishAllPorts` would instead make those endpoints persistent.

A future `-P` implementation therefore needs an atomic guest-Engine integration that
uses the same immutable image/config resolution as the create operation, asks the host
allocator to hold every selected loopback TCP endpoint before the Engine persists it,
and defines the corresponding stop/start/restart reallocation protocol. It must reject
the complete operation before guest side effects when the resolved set contains UDP,
SCTP, raw dynamic host-port ranges, a non-loopback address, or any
ambiguous/unsupported form. A proxy-only
request rewriter may support a clearly labeled direct-API subset whose complete
`ExposedPorts` set is already in the body, but that is not compatible support for the
standard Docker CLI `-P image` path and must not be advertised as such.

## Implemented Phase 1 transaction

For one recognized normal `POST .../containers/create`, Morbstack now supports an
omitted `HostPort`, exact `HostPort: ""`, or exact `HostPort: "0"` on one or more TCP
`PortBindings` entries. It holds a real `127.0.0.1` listener allocated by the macOS
kernel, writes each concrete number into a re-encoded create body and matching
`Content-Length`, and sends that body to the guest Engine. The host associates the
full ID from a bounded normal `201` response
*before any `201` byte reaches the Docker client*. A later recognized bodyless start
or restart continues to promote the same held listener under the existing lease
lifecycle.

The transaction consumes precisely the original create header and declared body; it
does not read ahead. On an HTTP keep-alive connection, it closes only the guest-side
one-request connection and gives the unconsumed client socket back to `DockerProxy`
for a fresh preflight. That means a same-connection or already-pipelined lifecycle
request still takes the normal lifecycle-response activation path after the create ID
is associated. A client-requested `Connection: close` closes normally after the create
response instead.

This Phase 1 path is bounded to a valid fixed-length JSON request already visible in
the existing 256 KiB preflight window, a single numeric `Content-Length`, no
`Expect: 100-continue`, and a nonchunked Engine response with at most 64 KiB of head
and 128 KiB of body. It returns a clear host error rather than exposing an unassociated
`201` if the response does not meet that contract.

### Normal `-p` compatibility matrix

This is a source audit of the ordinary Docker Engine request path, not substitute
for the live Docker/VM matrix below. Docker documents `-p` as an explicit mapping
and distinguishes it from `-P`, which publishes every exposed port to a random host
port ([Docker port publishing](https://docs.docker.com/engine/network/port-publishing/);
[CLI reference](https://docs.docker.com/reference/cli/docker/container/run/#publish)).
The difference matters here: `-p` supplies a `PortBindings` entry that the bounded
transaction can prove, whereas normal `-P` needs image configuration that the create
body does not completely identify.

| Docker CLI intent | Recognized create shape | Source-level outcome | Important limit |
| --- | --- | --- | --- |
| `-p 8080:80` or `-p 8080:80/tcp` | One concrete TCP `HostPort`; no explicit address, `""`, or `"0.0.0.0"` host address spelling | A held `127.0.0.1:8080` listener is reserved before create, associated with the returned full ID, and activated before the exact successful start response. | Morbstack deliberately exposes the Mac loopback endpoint, not an external interface. |
| `-p 127.0.0.1:8080:80` | Concrete TCP `HostPort` with `HostIp: "127.0.0.1"` | Same fixed-TCP lease path. | Live Docker/VM evidence is still pending. |
| `-p <container-port>`, `-p :<container-port>`, or `-p 0:<container-port>` | TCP `HostPort` omitted, exact `""`, or exact `"0"` | The create transaction holds a kernel-selected loopback listener and rewrites only that planned entry with its concrete port before the Engine sees it. | Fixed-length, bounded JSON/HTTP only; not a general HTTP transformer. |
| Multiple compatible TCP `-p` flags | Multiple distinct concrete or recognized dynamic TCP entries | One atomic lease holds every requested listener; dynamic entries are rewritten with the reserved values. | A duplicate host port may only name one guest target. |
| `-p 8080:80/udp` | Concrete IPv4/default UDP publication | The existing IPv4 UDP data plane reconciles the Engine-confirmed endpoint. | There is no synchronous held UDP allocation guarantee yet; IPv6-literal UDP publication is rejected rather than falsely forwarded through IPv4. |
| `-p '[::1]:8080:80'` | Concrete TCP `HostPort` with `HostIp: "::1"` | The preflight, held create/start lease, and event reconciler bind the actual local IPv6 endpoint `[::1]:8080`. | Live Docker/VM evidence is still pending. |
| `-p '[::]:8080:80'` | Concrete TCP `HostPort` with wildcard IPv6 `HostIp: "::"` | Morbstack keeps the publication local and binds `[::1]:8080`, not an external wildcard address. | This is an intentional local-desktop safety policy, not external-interface parity. |
| One container described on both IPv4 and IPv6 at the same numeric port | Dual-family records for the same proven target | The one-listener ledger chooses IPv4 when both families are present, preserving ordinary `127.0.0.1` access. | A simultaneous `127.0.0.1` **and** `[::1]` lease for one Docker mapping remains future dual-stack parity work. |
| `-p 8080-8081:80-81` | Docker CLI validates equal spans, then emits concrete `8080`→`80` and `8081`→`81` TCP bindings | The existing fixed-TCP path preflights, reserves, associates, activates, and recovers the complete concrete set as one atomic lease. | The recognized create window is 256 KiB and the held lease rejects more than 128 distinct concrete TCP host ports before guest create; this is source-level evidence, not live Docker/VM acceptance. |
| A fixed equal-length TCP range with more than 128 concrete host ports | Docker CLI-normalized concrete bindings | Rejected before guest create. | Holding listeners occurs under one ledger lock; the explicit cap prevents an oversized set from becoming a partial host lease. |
| `-p 8080-8081:80` | One container port with a host-port allocation range | Rejected before guest create as a raw dynamic host-port range. | Docker's parser deliberately preserves this as a range string for Engine-side selection; Morbstack must not partially reserve it. |
| `-P` / `--publish-all` | `HostConfig.PublishAllPorts: true` | Rejected before a guest create for the bounded dynamic path. | It is not another spelling of `-p <container-port>`; see the source audit above. |

The concrete implementation evidence is `DockerPortPublicationPreflight` for
classification/rewrite, `DockerProxy` for the bounded request/response hand-off, and
`PortForwarder`/`TCPListener` for the retained macOS listener. The remaining
dual-family row is an explicit known gap in that chain, not a compatibility claim.

## Fixed-TCP recovery after a VM stop

The listener itself is intentionally not persisted across a VM/daemon stop: while the
guest is absent, accepting the Mac port would be a false availability claim. The next
bodyless `POST /containers/<canonical-full-64-lowercase-hex-id>/(start|restart)`
instead gets a bounded inspect on a fresh Docker-API vsock connection after the guest
is ready. Morbstack accepts that recovery only when the inspect response proves the
same stopped ID and every
`HostConfig.PortBindings` entry is a concrete, unambiguous loopback TCP endpoint. It
then binds and associates all listeners under the current forwarder generation before
relaying the original lifecycle bytes; the existing exact-`204` observer remains the
only activation handoff. A fixed-TCP lease already associated with a container is
also claimed for its recognized bodyless `restart`, so its listener stays continuously
held across the Engine's stop/start cycle and is reactivated only after that `204`.
Docker documents `204` as the successful response for both
[start and restart](https://docs.docker.com/reference/api/engine/version/v1.43/);
all other responses leave the lease inactive.

This is not durable host-side lease persistence or general lifecycle interception. A
name/unique-prefix start or restart, inspect or lifecycle failure, a running container
with no existing full-ID lease, empty or zero host port, raw dynamic host-port range,
UDP/non-TCP,
unsupported address, malformed/ambiguous binding, or a non-bodyless request remains
an unchanged relay with no synchronous recovery claim. If a fully proved endpoint
cannot be bound on macOS, the start or restart is rejected before it reaches the
Engine rather than reporting a container that Morbstack cannot publish.

## Still outside the synchronous guarantee

The following remain unsupported or explicitly outside this transaction:

- Any dynamic `HostPort` spelling other than an omitted field, exact `""`, or exact
  `"0"`, and any opaque/slow/oversized create that does not enter the bounded
  preflight. They retain the raw Engine relay and therefore make **no** Phase 1
  synchronous allocation claim.
- `HostConfig.PublishAllPorts` (`docker run -P`). The standard CLI body omits image
  `EXPOSE` entries; an allocation contract needs atomic guest image/config resolution
  and separate stop/start/restart semantics, as documented in the source audit above.
- Raw dynamic host-port ranges (for example `-p 8080-8081:80`), which Docker keeps
  as one Engine-side allocation range rather than a fixed one-to-one mapping. The
  ordinary equal-length fixed range has already been normalized by the Docker CLI and
  is covered by the fixed-TCP row above.
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
retroactive allocation guarantee: it does not make `-P`, raw dynamic host-port
ranges, dynamic UDP,
omitted-host-port, or opaque/chunked creates synchronously supported.

## Required work beyond Phase 1

Further allocation work must preserve these invariants:

1. Extend classification only when the exact framing and JSON ownership can be proved.
   Chunked, malformed, oversized, upgraded, or otherwise opaque dynamic creates must
   either receive a clear pre-create error or remain explicitly outside the synchronous
   contract; forwarding one dynamically would restore the race this design removes.
2. Parse the create JSON exactly enough to identify published TCP and UDP bindings,
   loopback address spelling, and direct-API `ExposedPorts`. Reject unsupported
   protocols, addresses, ambiguous duplicates, and raw dynamic host-port ranges
   before a guest side effect. Do not add a second parser for ordinary equal-length
   CLI ranges: Docker CLI has already normalized them to concrete `PortBindings`.
   TCP and UDP use independent reservations, so they may legitimately share one
   numeric port. Do not mistake this request-visible subset for normal CLI `-P`: its
   complete image-derived set is available only during guest Engine image resolution.
3. The host allocator chooses candidate numeric ports and *holds real macOS loopback
   listeners/sockets* before the request is forwarded. A candidate may be released
   only on a failed create, a failed association, destroy, forwarder/VM shutdown, or
   the relevant documented lifecycle transition.
4. Rewrite every Phase-1 dynamic binding into the selected single concrete `HostPort`.
   Do not clear `PublishAllPorts` merely to materialize ports from a pre-create image
   inspect: that changes both image-reference and reallocation semantics. `-P` needs
   its own guest-Engine allocation handshake before any transformed request is sent.
   Re-encode a bounded transformed body and its `Content-Length`; do not depend on a
   later inspect call to learn an endpoint.
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
3. Add `PublishAllPorts` only after its guest image-resolution, held-allocation, and
   stop/start/restart contract exists; cover image-tag replacement, image-provided
   TCP/UDP/SCTP exposure, explicit `-p` precedence, `--expose`, conflict, destroy, and
   restart reallocation. Treat raw dynamic host-port ranges and UDP as separate
   allocation protocols with dedicated collision, lifecycle, and recovery coverage;
   do not infer either from string splitting. Ordinary equal-length fixed CLI ranges
   already use the fixed-TCP lease path.

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
