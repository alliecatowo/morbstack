# Documentation truthfulness pass — 2026-08-03

Scope: `README.md`, `site/*.html`, `docs/**` excluding `docs/audit/**`,
`docs/MASTER-PLAN.md`, `docs/COMPETITIVE-GAPS.md`, `docs/parity.md` (owned
by other concurrent workers). No code changed.

## Facts verified before editing

- `guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch`
  touches 2 files, +174/-0 lines (`daemon/morbstack_publish_all.go` new at
  166 lines, `daemon/network.go` +8), confirmed via `wc -l` and the patch's
  own diffstat trailer.
- `scripts/mkinitramfs.sh` lines 80–84 hard-fail if
  `${PATCHED_DOCKERD_BIN}` is missing/non-executable; lines ~211–219 skip
  the stock `dockerd` from `dist/guest-bin/` and install the patched binary
  in its place as `/usr/local/bin/dockerd`. Confirmed by reading the
  script — the patched build is not optional.
- The patch's own commit message states its purpose: host-side allocation
  for `PublishAllPorts` (`docker run -P`), explicitly scoped ("has no
  effect unless HostConfig.PublishAllPorts is set").
- `containerd`, the `docker` CLI (29.7.1), Buildx (v0.36.0), and Compose
  (bundled `docker-compose`) binaries in this tree carry no Morbstack
  patch — confirmed by the absence of any patch file targeting them
  (only one patch file exists in the repo, and it targets `daemon/*.go`
  in the Moby/dockerd tree).
- I was not able to independently reproduce the "22 vs 0 symbol" count
  cited in my brief on this host (cross-arch ARM64 ELF binary; `nm`
  returned partial/unreliable results locally) but did not need to — the
  patch's existence, size, and hard-fail install path are sufficient and
  independently confirmed.
- `mac/Sources/MorbstackKit/MorbLocalDomain.swift:17` hardcodes
  `public static let suffix = "morb.local"`.
- `docs/domains.md`'s own candidate table (line 37, pre-edit) recommends
  `*.morb.test` as canonical and treats `*.morb.local` as unshippable
  without further proof — a direct contradiction with the source constant.
- `scripts/fetch-scan-tools.sh` does not exist anywhere in the repo
  (`find`/`grep` turned up zero matches for the file itself, only five
  references to it in `mac/Sources/MorbScan/*.swift`, which is code and
  out of scope for this pass).
- The only in-scope **documentation** claim repeating `morb scan`'s
  "entirely on this machine" framing was `site/docs.html:142`; the CLI
  help text itself (`mac/Sources/morb/main.swift:46`) is code and was not
  touched.

## Claims corrected

1. **`README.md:8-12`** (top pitch) — "It runs unmodified upstream
   `dockerd`/`containerd`" → now describes upstream Moby with `containerd`
   unmodified and `dockerd` carrying the one pinned patch, by name and
   line count.
2. **`README.md:33-39`** (bullet list) — "Unmodified upstream `dockerd`."
   → reworded to "Real upstream Moby, one small pinned patch," naming the
   patch and explicitly listing `containerd`, `runc`, `docker` CLI,
   Compose, and Buildx as unmodified.
3. **`README.md:264`** (Mermaid diagram node) — `dockerd / containerd
   (unmodified upstream)` → `dockerd (+ Morbstack patch) / containerd
   (unmodified)`.
4. **`README.md:288`** ("Guest" architecture bullet) — "supervises
   unmodified upstream `dockerd`/`containerd`" → split into `dockerd`
   (patch) and `containerd` (unmodified).
5. **`README.md:306`** (comparison table, Engine row, Morbstack cell only)
   — "Unmodified upstream `dockerd`" → "Upstream `dockerd` + one
   ~174-line Morbstack patch." (Left the Docker Desktop cell alone —
   not this pass's claim to verify.)
6. **`site/index.html:7,16,24`** (meta description, og:description,
   twitter:description) — "unmodified upstream dockerd" → "upstream
   Docker Engine (one small pinned patch to dockerd)."
7. **`site/index.html:71`** (hero lede) — same fix, inline.
8. **`site/index.html:109-110`** (pitch card) — "Unmodified upstream
   Docker Engine" / "A static, unpatched Docker Engine build" → "Real
   upstream Docker Engine, one small patch," with the patch named and
   sized in the body copy.
9. **`site/index.html:199`** (M0 status paragraph) — "core bet
   (unmodified Docker Engine..." → "core bet (real upstream Docker
   Engine...".
10. **`site/comparison.html:112`** (architecture table) — same
    dockerd/containerd split as README's table.
11. **`site/comparison.html:243`** (differentiation paragraph) — "built
    around an unmodified, off-the-shelf `dockerd`/`containerd`" →
    "built around real, off-the-shelf upstream `dockerd`/`containerd` —
    `containerd` unmodified, `dockerd` with a single small pinned
    Morbstack patch."
12. **`site/comparison.html:383`** ("Use Morbstack if" dd) — "built
    around an unmodified upstream Docker Engine" → "built around a real
    upstream Docker Engine (one small, pinned, in-repo Morbstack patch to
    `dockerd`; `containerd` unmodified)."
13. **`site/docs.html:191`** — "Engine API = upstream moby, verbatim." was
    a nearby paraphrase implying the whole engine is untouched. Kept the
    true part (no added/removed/reshaped *endpoints*) but retitled to
    "Engine API surface = upstream moby" and added a parenthetical naming
    the `dockerd` patch and confirming it doesn't change the API contract.
14. **`docs/architecture.md:15-23`** ("What Morbstack is") — "runs
    unmodified upstream `dockerd` + `containerd`" and "the guest is
    boring, unmodified Docker" → rewritten to name the patch, its path,
    and line count, and changed "unmodified Docker" to "real Docker"
    where the sentence was about the guest not being a from-scratch
    runtime (a claim that's still true) rather than about zero patches.
15. **`docs/architecture.md:139-148`** ("containerd + dockerd" bullet) —
    "unmodified upstream binaries... Morbstack does not fork or patch the
    Docker Engine" → corrected to state `containerd` is unmodified,
    `dockerd` carries the one pinned patch, cited the hard-fail behavior
    in `mkinitramfs.sh`, and narrowed "does not fork or patch" to "does
    not otherwise fork or reimplement."
16. **`docs/architecture.md:363-372`** ("load-bearing decision" section)
    — "running unmodified `dockerd`/`containerd`" → split the same way.
17. **`docs/roadmap.md:36`** (M0 goal) — "core bet (unmodified Docker
    Engine..." → "core bet (real upstream Docker Engine...".
18. **`docs/roadmap.md:219-220`** (competitive analysis note) — "the
    unmodified upstream engine and the licence are [the differentiators]"
    → named the patch and containerd's unmodified status.
19. **`docs/comparison.md:65`** (architecture table) — same
    dockerd/containerd split.
20. **`docs/comparison.md:181-184`** (differentiation paragraph) — same
    fix as site/comparison.html #11.
21. **`docs/comparison.md:501-503`** ("Use Morbstack if") — same fix as
    site/comparison.html #12.
22. **`docs/competitive-capability-roadmap.md:21-23`** (product promise)
    — "unmodified upstream Docker Engine" → "real upstream Docker Engine
    (one small, pinned, in-repo Morbstack patch to `dockerd`; `containerd`
    unmodified)."
23. **`docs/product-audit.md:9-13`** (product outcome) — "retaining an
    inspectable, unmodified upstream Docker Engine" → same pattern,
    naming the patch.
24. **`docs/PUBLISHING.md:44`** (`gh repo create --description`) —
    "unmodified upstream dockerd" → "real upstream Docker Engine (one
    small, pinned patch to dockerd; containerd unmodified)."
25. **`site/docs.html:142`** (`morb scan` CLI reference table) — "SBOM
    and CVE scan an image, entirely on this machine" → "SBOM and CVE scan
    an image using optional `syft`/`grype` tools you supply yourself (not
    bundled); building the CVE database requires a network fetch." Does
    not reference `scripts/fetch-scan-tools.sh` (it doesn't exist) and no
    longer claims full offline operation.
26. **`docs/domains.md`** — added an explicit **UNRESOLVED** block after
    the candidate-suffix table (originally ending at line 38) stating
    that `MorbLocalDomain.suffix` in
    `mac/Sources/MorbstackKit/MorbLocalDomain.swift:17` is hardcoded to
    `"morb.local"`, the exact candidate this document says should not
    ship without further proof, and that resolving the contradiction is
    a product decision, not something this pass should decide.

**26 corrections across 2 files in `site/`, `README.md`, and 8 files in
`docs/`.**

## Hits deliberately left unchanged, and why

- **`README.md:100`** — "Buildx plugin is the unmodified upstream
  binary" — true; only `dockerd` carries a patch, Buildx does not.
- **`README.md:250`** — Mermaid node `docker CLI (unmodified)` — true;
  the CLI client is unpatched 27.4.0/29.7.1 stock.
- **`site/comparison.html:254`** and **`docs/comparison.md:204`** —
  "unmodified upstream CLI against the relayed Engine API" — true, and
  explicitly named in my brief as a claim about the *client*, not the
  engine.
- **`site/comparison.html:327`** — "unmodified upstream Buildx plugin" —
  true.
- **`site/docs.html:189`** — "Unmodified `docker` CLI" — true, client
  claim.
- **`docs/compat.md:9`** and **`docs/compat.md:38-39`** — "Unmodified
  `docker` CLI" and "pinned, unmodified upstream `docker`,
  `docker-compose`, and `docker-buildx` binaries" — true; none of these
  three is `dockerd`/the engine, and none carries a patch.
- **`docs/first-run.md:22`** — "pinned, unmodified upstream client and
  plugins" — same three host-bin artifacts (docker CLI, compose, buildx)
  as above; true.
- **`docs/architecture.md:121`** ("stock, unmodified kata-containers...
  kernel") — about the guest kernel, not `dockerd`. The Moby patch
  doesn't touch the kernel; this claim was never implicated and stays.
- **`docs/architecture.md:272`** ("unmodified amd64 container images will
  run") — "unmodified" describes the *container images* users run under
  Rosetta emulation, not the engine. Different subject entirely.
- **`docs/debug.md:150`** ("The target container remains unmodified.")
  — about a specific container instance in a troubleshooting scenario,
  not the engine binary. Different subject.
- **`docs/PUBLISHING.md:274`** ("`LICENSE` (unmodified Apache-2.0
  text)") — about license text being verbatim, unrelated to the engine.
- **`docs/final-implementation-audit-2026-08-03.md:75`** ("The target is
  the unmodified upstream Engine API") — read in context (the paragraph
  above is entirely about the wire-visible API contract, matrix testing,
  and client compatibility), this is a claim that the *API surface* Morbstack
  targets is standard/upstream-shaped, not a claim that the `dockerd`
  binary has zero patches. The Moby patch is internal to port allocation
  and does not add, remove, or reshape any Engine API endpoint — so the
  claim as actually worded stays true. Flagged here rather than silently
  skipped because it uses the loaded word "unmodified" right next to
  "Engine," which is exactly the kind of sentence worth a second look.
- **`docs/dynamic-port-allocation.md:42`** ("the guest's unmodified
  `dockerd` selects an empty host port") — this sentence is specifically
  about the passive `-p` relay codepath, which the Moby patch does not
  touch (the patch's own commit message: "has no effect unless
  HostConfig.PublishAllPorts is set"). For that codepath, `dockerd`'s
  behavior really is stock/upstream. The same document's status line at
  the top already correctly discloses that `-P` *is* implemented via the
  pinned patch — so this isn't an oversight elsewhere in the file, just a
  narrower, accurate use of the word for one specific code path.
- **`docs/dynamic-port-allocation.md:73`** ("the unmodified create
  request") — "unmodified" here modifies *the HTTP create request*, not
  `dockerd`, contrasting it against a hypothetical proxy that rewrites
  requests before forwarding. Different subject.
- **`docs/roadmap.md:137`** ("`syft`/`grype` integration for image
  scanning") and **`docs/migrate.md:161`** (SBOM/vulnerability mention in
  a migrate-command context) — neither makes an "entirely on this
  machine" or bundling claim; both are unrelated to the `morb scan` issue.
- **`docs/parity.md`, `docs/MASTER-PLAN.md`, `docs/COMPETITIVE-GAPS.md`,
  `docs/audit/**`** — all contain "unmodified"/scan-related hits (e.g.
  `docs/parity.md:102,108,226`; `docs/MASTER-PLAN.md:114,116`;
  `docs/COMPETITIVE-GAPS.md:62`; `docs/audit/PRODUCT-AUDIT.md`,
  `docs/audit/DIFFERENTIATION.md`, `docs/audit/MASTER-AUDIT.md`) but are
  explicitly owned by other concurrent workers per my brief and were not
  touched. Several of them (`MASTER-PLAN.md:114`, `COMPETITIVE-GAPS.md:62`,
  the audit docs) already correctly *identify* these same false claims as
  problems to fix — they don't need correcting, they're the punch list
  this pass worked from.

## Overstatements found but not named in my brief

- **`site/docs.html:191`**, pre-edit: "Engine API = upstream moby,
  **verbatim**." The word "verbatim" applied to the whole Engine (not
  just its API surface) was a nearby paraphrase of the same false claim,
  not caught by a literal grep for "unmodified." Corrected (see #13
  above).
- The `morb scan` help text still promising "entirely on this machine" at
  **`mac/Sources/morb/main.swift:46`** is code and out of scope for this
  pass, but it is the *source* of the doc claim I fixed in
  `site/docs.html`. Flagging it here since it means the CLI's own `--help`
  output will keep making the claim I just removed from the website until
  someone with code-editing scope fixes it too.

## Third pass — 2026-08-04: the engine claim flips back, for a different reason

TECH-1 decided the `-P` publish-all problem this second pass's 174-line-patch
framing was built around should be solved a different way: instead of a
downstream-patched Moby, Morbstack now ships **unmodified upstream `dockerd`**
(stock static Docker 29.7.1 binaries, archive-hash-pinned). Published ports —
including `docker run -P` — are made reachable from the Mac by a small
Morbstack userland proxy (`guest/morbinit/src/proxy_wrapper.rs`), invoked
through dockerd's own stock `--userland-proxy-path` flag, leasing the Mac-side
endpoint from the host over a new guest-initiated vsock channel (host port
2382; see `docs/protocol.md` §3.6). The downstream patch
(`guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch`), the
scripts that built it (`scripts/build-morbstack-dockerd.sh`,
`scripts/fetch-moby-source.sh`), the `build-engine.yml` workflow, and the
vsock 2379 publish-all allocator protocol are all **deleted**.

This means the second pass's corrections above are now themselves stale in
the opposite direction from the first pass they corrected: they carefully
qualified "unmodified upstream dockerd" into "upstream dockerd + one small
patch," and that qualification is no longer true. **This pass restores
"unmodified upstream dockerd" as the accurate top-line claim** at every site
the second pass touched, and adds the new true mechanism — the userland-proxy
wrapper — wherever a reader needs to know how `-P` actually reaches the Mac
without an engine patch. Runtime acceptance for the wrapper is in progress
(2026-08-04); no document in this pass claims a `runs-here`/verified-working
result for it, only that it is implemented and undergoing acceptance.

**Sites corrected in the new form**, matching each document's existing tone
(not one pasted sentence): `README.md` (5 sites — pitch intro, bullet list,
Mermaid diagram node, guest architecture bullet, comparison table);
`site/index.html` (4 — meta descriptions, hero lede, pitch card, M0 status);
`site/comparison.html` (3 — architecture table, differentiation paragraph,
"Use Morbstack if"); `site/docs.html` (1 — Engine API surface note);
`docs/architecture.md` (3 — "What Morbstack is," containerd+dockerd bullet,
"load-bearing decision" section, plus two adjacent stale references to the
already-deleted port-2380 listener probe that were sitting in the same
paragraphs); `docs/roadmap.md` (2 — M0 goal, competitive analysis note);
`docs/comparison.md` (3 — architecture table, differentiation paragraph, "Use
Morbstack if"); `docs/competitive-capability-roadmap.md` (1 — product
promise); `docs/product-audit.md` (1 — product outcome); `docs/PUBLISHING.md`
(1 — `gh repo create --description`). Also corrected outside that list,
because they described the same now-deleted patch/allocator mechanism:
`docs/compat.md` (unmodified-CLI bullet and the relay description),
`docs/docker-engine-compatibility-inventory.md` (the `-P` ledger row and the
full "Publish-all source-level contract" section, rewritten around the
wrapper), `docs/dynamic-port-allocation.md` (status line, mechanism
paragraph, and the `-P` table row), `docs/MASTER-PLAN.md` (closed item 0.9,
updated 0.10/0.11's port list, marked the `PublishAllPortAllocator` test item
moot), `docs/COMPETITIVE-GAPS.md` ("where we must stop claiming a win," now
resolved), `docs/audit/BRANCH-DECISION.md` (dated staleness note, evidence
left intact), and `docs/audit/DIFFERENTIATION.md` (punch-list item marked
resolved the opposite way from how it was originally written).

`docs/design/ENGINE-BUILD-DECISION.md` is now a superseded stub pointing at
`docs/design/PATCH-FREE-PUBLISH-ALL.md`. `docs/protocol.md` §3 gained the
2382 port-lease registry entry and §3.6 documenting its wire grammar; `TASKS.md`
tickets TECH-1, SP-4, SP-6, EN-2, OPS-8, OPS-9, REL-1, TST-4, TECH-8, and
CONC-1 were all updated to match. `docs/audit/*` dated evidence files
(ENGINE-MATRIX.md, FUNCTIONAL-AUDIT.md, PROXY-FRAMING.md, MASTER-AUDIT.md,
PRODUCT-AUDIT.md, REPO-AUDIT.md, TECHNOLOGY-AUDIT.md) were left as recorded
evidence and given a short dated staleness annotation instead, per this
repo's documented failure mode of deleting a port/mechanism and leaving docs
describing it as live.
