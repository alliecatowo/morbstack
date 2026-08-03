# Public image discovery

Status: source-level foundation only, added 2026-08-03. It is not an image
browser, registry integration, pull workflow, or Docker compatibility claim.

## The first user-visible contract

A future **Explore Images** command may search public Docker Hub repositories
only after a person submits text. It returns at most 25 first-page repository
hints, with a bounded short description and the provider's reported public
star/pull/official/automated fields. A result can prefill a later pull dialog;
it never pulls, inspects, resolves a tag/digest, verifies provenance, or
asserts that an image is available for the current architecture.

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

Before an Explore Images UI ships, validate the documented public Docker Hub
API contract, cancellation, response/body limits, rate-limit presentation,
and no-credential/no-pull behavior with a controlled network fixture. A later
pull flow remains a separate, explicitly confirmed Docker Engine operation;
it must resolve an exact tag or digest and report the daemon's real progress
and error, not reuse search metadata as execution truth.

Relevant provider reference: [Docker Hub API documentation](https://docs.docker.com/docker-hub/api/latest/).
