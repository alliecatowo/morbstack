# Engine build decision (SP-4)

**Status:** binding spike decision record. 2026-08-03.

## Recommendation

Publish `morbstack-dockerd` as a pinned, SHA-256-verified GitHub Release
artifact, built by a dedicated `build-engine.yml` workflow on a **Linux**
GitHub-hosted runner (which ships Docker + Buildx natively, unlike the
`macos-26` runners the rest of CI uses), consumed by `scripts/fetch-guest-assets.sh`
exactly the way every other third-party guest binary already is —
with `scripts/build-morbstack-dockerd.sh` kept as the from-source path an
auditor runs to reproduce and diff that same SHA, not deleted.

## Why this fits the repo before it fits SP-4

Every other third-party asset here already follows one pattern: fetched over
HTTPS, hash-verified either against a pin recorded at fetch time or against
an upstream-published sidecar, recorded in a `PROVENANCE.txt`, never
committed as a blob. `dist/host-bin/PROVENANCE.txt` and
`dist/guest-bin/PROVENANCE.txt` do this for the *stock* Docker CLI, Compose,
Buildx, and the *unpatched* `dockerd`/`containerd`/`runc` — several assets
doubly verified (own hash plus an independent second source, e.g. the
Homebrew formula API cross-check for the `docker` CLI bottle). `morbstack-dockerd`
is the one asset in the whole tree that is neither "download a stock binary"
nor "download a source tree and hash the checkout" — it is a **166-LOC
downstream patch** (`guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch`)
applied to a commit-pinned Moby checkout and then compiled. Nothing upstream
will ever publish a checksum for that output; Morbstack itself is the only
possible source of truth, so the "sidecar checksum" verification model this
repo prefers everywhere else cannot apply here. The substitute has to be:
(a) a deterministic build so a third party can reproduce the exact bytes,
and (b) a publicly inspectable link from "these bytes" back to "this exact
commit + this exact patch + this exact CI run," which a GitHub Release with
build provenance provides and neither of the other two options offers as
directly.

Useful outside precedent: Lima/Colima, who face the same "patched
Linux/QEMU binary needed on a Mac" problem, also build their patched
binaries in CI and distribute them as GitHub Release assets rather than
vendoring them in-tree — the same shape recommended here, for the same
reason (a git repo is a poor artifact store, a Release is a good one).

## Option 1 — Pinned, SHA-verified release artifact (recommended)

**Reproducibility.** `build-morbstack-dockerd.sh` already sets
`SOURCE_DATE_EPOCH` from the pinned commit's own timestamp specifically so
its output is deterministic, not merely hash-pinned after the fact — that
groundwork already exists and this option is the only one that cashes it in.
Anyone who doubts the published binary runs the same script against the
same pinned Moby commit + patch and diffs the resulting SHA-256 against the
one in the release notes and `dist/guest-bin/PROVENANCE.txt`. That is a real
falsifiable claim, not "trust the maintainer."

**Trust model.** The binary is signed for provenance, not code-signed for
Gatekeeper (that's SP-9/REL-2, a different signature over the final `.app`).
GitHub's native `actions/attest-build-provenance` action produces a
SLSA-style attestation binding the artifact's digest to the exact workflow
file, commit SHA, and run — verifiable with `gh attestation verify` by
anyone, with no secret Morbstack has to hold beyond the repo's own OIDC
identity. This is strictly additive to, not a replacement for, the
hash-pin-plus-diff story above.

**CI implications.** Two jobs instead of one: a `build-engine.yml`
(or a job within it) that runs on `ubuntu-latest` — which ships Docker
Engine and the `docker buildx` plugin preinstalled — builds `linux/arm64`
via the same `docker buildx bake binary --set *.platform=linux/arm64`
command already in `build-morbstack-dockerd.sh`, and publishes on a tag or
on `guest/moby-patches/**` changes. The existing `guest-image` job on
`macos-26` in `ci.yml` then just downloads and verifies a hash, the same
shape as its `fetch-guest-assets.sh --docker-only`/`--alpine-only` steps
already have — no Docker needed on the Mac runner, and the "Require Docker
Buildx" failing step (`ci.yml:225`) is deleted outright rather than kept as
a guard. One assumption this migration should smoke-test on first run and
not merely assert: Moby's Buildx bake target has always been built for
`linux/arm64` from a macOS/arm64 host (an OS cross-build); building it from
an `amd64` Linux host is an additional OS+arch cross-build. BuildKit's
Dockerfile-based build should handle it the same way Moby's own multi-arch
release process does, but this is unverified by this spike (no build was
run) and belongs as the first checkpoint in migration, not an assumed given.

**Onboarding cost.** A contributor who only wants to build the Mac app and
run it against a prebuilt engine needs **no Docker installed at all** —
`fetch-guest-assets.sh` gains a `fetch_morbstack_dockerd` function
parallel to `fetch_docker`/`fetch_docker_cli`, pinned URL + SHA-256, no
different from every other asset it already fetches. A contributor who
wants to touch the patch itself still needs Docker locally to run
`build-morbstack-dockerd.sh` — unavoidable, since Buildx really is Moby's
only supported build path on macOS (the script's own top comment explains
why: `hack/make.sh` assumes a GNU userland the Mac doesn't have) — but that
person is now a small minority of contributors, not everyone who checks out
the repo.

**What this gives up.** A default `mise run guest-image` clone-and-build
now depends on network access to GitHub Releases for one more asset (true
of every other guest asset already, so not a new category of risk, but it
is a new specific dependency). It also means the "one command builds
everything from source with nothing but Xcode+mise" story has one
documented, justified exception — worth stating plainly in
`dist/guest-bin/PROVENANCE.txt` and `docs/build.md` rather than leaving a
reader to discover it. And a maintainer now owns one more release/rotation
process (bump Moby's pinned commit → re-run `build-engine.yml` → new
release asset → bump the SHA pin in `fetch-guest-assets.sh`), which is real
but bounded work, not open-ended.

## Option 2 — Vendor a prebuilt binary in-repo (rejected)

**Reproducibility.** No better than Option 1's hash pin — a vendored binary
still needs the exact same "rebuild and diff the SHA" verification path,
since there is still no upstream checksum to check it against — but it
loses Option 1's natural home for build-provenance attestation. A commit
message ("update morbstack-dockerd to build X") is a much weaker,
easier-to-overlook link back to the source commit than a Release page with
an attached attestation and PROVENANCE-style notes.

**Trust model / supply chain.** Worse, not better: a compromised binary
landing in one commit stays in git history forever unless history is
rewritten (destructive, breaks every existing clone/fork reference); a
compromised Release asset can simply be deleted and re-cut. Nothing about
committing the bytes into git adds a trust signal Option 1 lacks — it only
removes one (GitHub attestation has no equivalent for a plain blob commit).

**CI implications.** Genuinely simpler in one respect — no download step,
`guest-image` just reads `dist/guest-bin/morbstack-dockerd` from the
checkout — but that's the entire benefit, and it comes at a real cost
described below.

**Onboarding cost.** Every clone of the repo pays ~93 MB forever, growing
by another ~93 MB in history each time the patch or the pinned Moby commit
changes, with no way to reclaim that space short of a history rewrite. This
repo carries no Git LFS today (checked: no `.gitattributes` LFS filter
anywhere), so adopting it here is a new piece of infrastructure this
project would have to stand up, document, and ask every contributor to
install, purely to work around a problem GitHub Releases already solves for
free.

**Why it loses to Option 1.** It matches the existing "pinned + hashed"
verification discipline but forfeits the provenance/attestation surface,
permanently bloats the one thing (`git clone`) every contributor does
first, and requires adopting Git LFS — a dependency this repo has
deliberately not needed until now — for no offsetting benefit over just
publishing the same bytes as a Release asset.

## Option 3 — Make the patch optional with a capability downgrade (rejected as primary)

**What "optional" means concretely.** Ship the *stock* `dockerd` binary
already fetched by `fetch_docker` in `fetch-guest-assets.sh` (from
`download.docker.com`, already hash-pinned, already in the tree) as the
default, and only substitute the patched `morbstack-dockerd` when a
developer has Docker locally and opts in.

**What breaks, precisely.** The patch's own commit message
(`guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch`)
explains why `-P` needs it at all: Moby only expands `Config.ExposedPorts`
into the effective published-port set *after* HostConfig is already fixed,
so the host-side port proxy has no ports to reserve until the guest daemon
tells it what it picked. Without the patch, `docker run -P` does not
degrade gracefully to "less nice" — the ports Moby picks are guest-internal
and Morbstack's host-forwarding path never learns what they are, so `-P`
publishes nothing reachable from the Mac at all. That is a silent,
user-visible break of a capability `docs/parity.md` already counts as a
Docker Desktop parity item, not a documented, narrow trade-off.

**CI implications.** This is the only option that actually removes Docker
as a build dependency on macOS runners without any new machinery — the
`guest-image` job just always uses the already-fetched stock binary and
never calls `build-morbstack-dockerd.sh` in CI at all. That is a genuine
point in its favor for CI cost specifically.

**Why it loses as the *primary* answer.** It solves "CI is green" by
disabling the feature under test rather than fixing how the feature gets
built, and it produces two materially different engines in the wild (patched
vs. stock) with no clear signal to a user about which one a given install
has — a support and testing-matrix cost with no natural end date, since the
patch was written specifically because the downgraded behavior is a real
regression, not a hypothetical one. It is not, however, wasted: it is the
right shape for a *fallback*, not a replacement — see step 6 below.

## Interaction with REL-1 and SP-9

REL-1 (`scripts/release.sh`, `docs/RELEASING.md`, `.github/workflows/release.yml`
— currently referenced by name and non-existent) now has a concrete second
input: the release pipeline is not just "sign and notarize the `.app`," it
also needs to either depend on `build-engine.yml` having already published
a current `morbstack-dockerd` for the Moby commit `dist/guest-bin/PROVENANCE.txt`
pins, or trigger it as a prerequisite stage. These are two different release
cadences (the engine changes only when the Moby pin or the patch changes;
the app changes on every release), so REL-1 should treat them as two
workflows with a dependency edge, not one monolithic pipeline.

SP-9 (signing/notarization identity) is adjacent but distinct: Developer ID
signing and notarization apply to the final `.app`/DMG for Gatekeeper, not
to `morbstack-dockerd`, which is Linux/arm64 ELF and never touched by
`codesign`/`notarytool`. The two do share one thing worth deciding once,
not twice: SP-9 will need CI to hold a secret identity (a signing
certificate) the same way `build-engine.yml` needs an OIDC-derived identity
for attestation — both should land through GitHub's OIDC/Actions secrets
model rather than two different ad hoc mechanisms.

## Migration steps (for OPS-9 and REL-1 to be rewritten from)

1. **Prove the cross-build assumption first, on a throwaway branch, before
   wiring CI to depend on it.** Run `docker buildx bake binary --set
   *.platform=linux/arm64` for the pinned Moby commit on an `ubuntu-latest`
   GitHub-hosted runner (or an equivalent local Linux/amd64 Docker install)
   and confirm it produces a `linux/arm64` `dockerd`. This spike did not run
   a build; this is the one unverified claim the whole plan rests on.
2. Add `.github/workflows/build-engine.yml`: triggers on changes to
   `guest/moby-patches/**`, `scripts/build-morbstack-dockerd.sh`,
   `scripts/fetch-moby-source.sh`, or a manual `workflow_dispatch`/tag push;
   runs on `ubuntu-latest`; runs `scripts/build-morbstack-dockerd.sh`
   unmodified (it already only needs `docker buildx`, which Linux runners
   ship); uploads `morbstack-dockerd` plus its SHA-256 as a GitHub Release
   asset (draft or tag-triggered, matching whatever REL-1 settles on for
   cadence); attaches build provenance via `actions/attest-build-provenance`.
3. Add a `fetch_morbstack_dockerd` function to `scripts/fetch-guest-assets.sh`,
   parallel to `fetch_docker`/`fetch_docker_cli`: pinned Release URL +
   SHA-256 constant, verify-then-cache into `dist/guest-bin/morbstack-dockerd`,
   with the same "existing file, re-verify before reuse" behavior the other
   `fetch_*` functions already have.
4. Update `dist/guest-bin/PROVENANCE.txt` with a `morbstack-dockerd` entry
   in the same voice as its existing `docker-29.7.1.tgz` entry: source
   Release URL, SHA-256, the Moby commit and patch file it was built from,
   and an explicit note that this one entry is a downstream-patched build
   rather than a redistributed upstream binary, verifiable by re-running
   `scripts/build-morbstack-dockerd.sh` and diffing the hash.
5. In `.github/workflows/ci.yml`'s `guest-image` job: delete the "Require
   Docker Buildx for the Moby build" step (`ci.yml:225-233`) entirely, and
   add `./scripts/fetch-guest-assets.sh --morbstack-dockerd-only` (new flag,
   same shape as `--docker-only`/`--alpine-only`) alongside the existing
   fetch steps, before `mise run guest-image`.
6. Keep `mise-tasks/build-patched-dockerd` and
   `scripts/build-morbstack-dockerd.sh` exactly as they are today as the
   documented from-source / verification path — do not delete or gate them
   behind a flag. `mise run guest-image` should prefer a locally-built
   `dist/guest-bin/morbstack-dockerd` if one is already present (a
   developer actively working on the patch), and fall back to
   `fetch-guest-assets.sh`'s pinned download otherwise.
7. As the documented last-resort fallback (Option 3's real role): if the
   pinned Release asset is ever unreachable and the developer has no local
   Docker either, `mkinitramfs.sh` should refuse to silently substitute the
   stock `dockerd` — it should fail with an explicit error naming both
   remaining options (install Docker and build locally, or fix network
   access to the Release), so "the build produced an engine with `-P`
   silently disabled" can never happen by accident.
8. Update `docs/build.md`/`docs/parity.md` to state plainly that
   `morbstack-dockerd` is the one guest asset built from a downstream patch
   rather than redistributed unmodified, and where its reproducibility
   story lives (this document + the PROVENANCE.txt entry from step 4).
9. Rewrite OPS-9 and REL-1 in `docs/BACKLOG.md` per this file (done as part
   of this spike — see below).
