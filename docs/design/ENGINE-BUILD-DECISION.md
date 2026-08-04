# Engine build decision (SP-4)

**Status:** binding spike decision record. 2026-08-03.

> **SUPERSEDED 2026-08-04 by TECH-1 / [`docs/design/PATCH-FREE-PUBLISH-ALL.md`](PATCH-FREE-PUBLISH-ALL.md).**
> This document recommended a release pipeline for `morbstack-dockerd`, a
> downstream-patched build of Moby carrying a 166-LOC patch
> (`guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch`)
> that let `docker run -P` reach the Mac. TECH-1 later found a patch-free
> mechanism — a Morbstack userland-proxy wrapper invoked through dockerd's
> own stock `--userland-proxy-path` hook — that gets the same result without
> any non-upstream engine. The patch, the build scripts
> (`scripts/build-morbstack-dockerd.sh`, `scripts/fetch-moby-source.sh`),
> and the `build-engine.yml` workflow this document specifies are all
> **deleted**. There is no `morbstack-dockerd` artifact to release, sign, or
> attest, and the entire "release pipeline for a patched engine" problem
> this document solved no longer exists. Everything below is preserved as
> historical record; git history has the full 250-line original if the
> superseded reasoning is ever needed.

## What this document decided (historical)

Faced with a downstream-patched `morbstack-dockerd` that had no upstream
checksum to verify against, this spike recommended publishing it as a
pinned, SHA-256-verified GitHub Release artifact built by a Linux CI runner
(`build-engine.yml`) and fetched by `scripts/fetch-guest-assets.sh` like
every other third-party guest binary, with `build-morbstack-dockerd.sh`
kept as the from-source reproduction path. It rejected vendoring the ~93 MB
binary in-repo (permanent git bloat, no attestation surface) and rejected
making the patch optional as the *primary* fix (silently breaks `-P`,
since Moby only knows the effective published-port set after the patch
runs) while keeping that same fallback shape for the case where the
Release asset is unreachable. A nine-step migration plan for `OPS-9` and
`REL-1` followed from that recommendation.

## Why it no longer applies

TECH-1 removed the premise this whole document argued from: there is no
longer a downstream patch, so there is no patched binary to build,
release-artifact, sign, or verify. `OPS-9` and `REL-1` are now rewritten
directly from TECH-1's outcome rather than from this document's migration
steps — see `TASKS.md`. `docs/design/PATCH-FREE-PUBLISH-ALL.md` is the
current design record for how `-P` reaches the Mac.
