# Public image discovery

Status: native source interaction plus service foundation, added 2026-08-03.
It is not a registry integration, pull workflow, or Docker compatibility claim;
real-window and controlled-network acceptance remain pending.

## The first user-visible contract

The Images toolbar has an **Explore Public Images** command that opens a
system document-modal sheet. The sheet uses a `Form` for explicit input and a
native `List`/detail split for richer repository search results; it deliberately
does not turn the local operational image `Table` into a generic card browser.
Search runs only after the person submits text. It returns at most 25 first-page
repository hints, with a bounded short description and the provider's reported
public star/pull/official/automated fields. A selected result can copy its
canonical repository name for a later explicit command; it never pulls,
inspects, resolves a tag/digest, verifies provenance, or asserts that an image
is available for the current architecture.

The UI must show the following states distinctly:

- no results;
- cancellation, with no stale result applied;
- Docker Hub rate limiting, including a numeric `Retry-After` value when the
  service supplied a reasonable one;
- timeout or transport failure;
- service HTTP failure; and
- a malformed, redirected, or over-budget response that Morbstack declined to
  display.

It must not issue a discovery request while typing, on route appearance, on
launch, in the background, or as a side effect of selecting a local image.
There is intentionally no pagination control in the first slice: refine the
query instead of following a service-provided URL/cursor into an unbounded
crawl.

## Authority and privacy boundary

`PublicImageDiscovery` performs one HTTPS `GET` only for an explicit request
whose scope is `dockerHubPublic`. It constructs the fixed
`https://hub.docker.com/v2/search/repositories/` URL itself and permits only a
bounded, percent-encoded `query` value plus `page_size=25`. It follows no
redirects and caps the entire body at 512 KiB.

The transport is ephemeral and credential-free: no Docker daemon, Docker
context, Docker configuration, registry configuration, credential helper,
stored HTTP credential, cookie, cache, proxy, HTTP authentication challenge,
pull, process, or VM is touched. Search terms necessarily go to Docker Hub
when the person submits them; the future UI must say that plainly near the
action and must not imply an offline search.

The model also has a typed `OCIRegistryRepository` scope. That is a future
provider boundary for a known host and known repository, not a generic
registry-search implementation. OCI Distribution does not define a portable
registry-wide search API, so `PublicImageDiscovery` rejects that scope before
opening a connection. Adding a registry requires a provider-specific design
for API semantics, authentication/credential consent, TLS trust, pagination,
rate limits, provenance, and failure/recovery. It must never silently use
Docker Hub behavior, a user's Docker credentials, or an ambient registry
configuration as a fallback.

## Promotion gate

Before promoting the existing Explore Images sheet, validate the documented
public Docker Hub API contract, cancellation, response/body limits, rate-limit
presentation, and no-credential/no-pull behavior with a controlled network
fixture. Then inspect the actual app window in light/dark and narrow sizes,
including keyboard List selection, focus return to the Form field, VoiceOver
labels, toolbar overflow, and transparency/contrast/motion settings. A later
pull flow remains a separate, explicitly confirmed Docker Engine operation; it
must resolve an exact tag or digest and report the daemon's real progress and
error, not reuse search metadata as execution truth.

Relevant provider reference: [Docker Hub API documentation](https://docs.docker.com/docker-hub/api/latest/).
