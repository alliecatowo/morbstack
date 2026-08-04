# Morbstack master audit — 2026-08-03

> **Staleness note (2026-08-04):** this audit's engine/`-P` findings (the Moby patch,
> `build-morbstack-dockerd.sh`, the publish-all allocator) describe a mechanism
> deleted under TECH-1. Morbstack now ships unmodified upstream `dockerd`; `-P` is
> served through its stock `--userland-proxy-path` hook instead, with no engine patch
> and no Docker-to-build-Docker bootstrap. Findings left unchanged as dated evidence;
> see `docs/design/PATCH-FREE-PUBLISH-ALL.md`.

Independent audit of `code/native-content-continuation` (273 commits, tip `54de308`), covering the
app, the service, and the repository itself. Companion documents:

| Document | Scope |
| --- | --- |
| [BRANCH-DECISION.md](BRANCH-DECISION.md) | whether this branch becomes `main` |
| [UI-AUDIT.md](UI-AUDIT.md) | every UI defect and taste issue, with what it should be instead |
| [FUNCTIONAL-AUDIT.md](FUNCTIONAL-AUDIT.md) | UI action → CLI verification, per feature |
| [REPO-AUDIT.md](REPO-AUDIT.md) | architecture, code health, CI/CD, agent harness |
| [PRODUCT-AUDIT.md](PRODUCT-AUDIT.md) | claim-by-claim verification against source |
| [DIFFERENTIATION.md](DIFFERENTIATION.md) | what would make this genuinely competitive |

## Verdict

A real runtime and a real native app that **nobody has ever installed**. Architecturally a Docker
Desktop replacement; evidentially a demo of one. The distance between those two is a guest-image
rebuild, a clean-profile acceptance run, and a DMG — not another quarter of features.

Promote the branch to `main`. It is a fast-forward, and everything it deletes was formally retired.
Fix the test target first.

## The five findings that matter most

### 1. Nothing has ever been gated. `git remote -v` is empty; CI has never run.

273 commits, an 8.8 KB `.github/workflows/ci.yml`, and **zero executions**. The consequence is
mechanical, not hypothetical: six files across both toolchains were committed in a state where they
did not compile.

- `mac/Tests/MorbstackKitTests/DockerContextTests.swift` — wrong argument label; optional not unwrapped
- `mac/Tests/MorbstackAppTests/ComposeProjectSourceInspectionTests.swift` — `XCTAssertEqual` on arrays of tuples, which cannot conform to `Equatable`
- `guest/morbinit/src/live_share.rs:306` — `impl std::error::Error` with no `Debug`, so **`cargo test` was exiting 101 and running nothing at all**

The Rust break is the instructive one: every status document in this repo reports a passing Rust
suite. That number came from a suite that did not build. "It builds" had silently come to mean
"`mise run app` succeeded" — the one command that never touches tests.

**Fixed during this audit. The suite is now green** — independently re-verified:
`mise run test` → exit 0, **Swift 739 executed / 0 failures, Rust 217 passed / 0 failed.**

Getting there surfaced a real product bug hiding among the "stale test" failures:
`DockerPortPublicationPreflight`'s dedup key omitted the container port, so `-p 8080:80 -p 8080:81`
skipped the ambiguity check written for exactly that case and was admitted to the Engine. That test
had been failing all along and was the only one that was right — a reminder that the default on a
failing test is to check the code first.

Several other tests were **flaky by construction**: `inspectContainerCreate` performed a *real* bind,
so tests naming 5353/udp could never pass on a Mac running mDNSResponder; others read the developer's
actual `~/.morbstack` or round-tripped to a live daemon. Now behind an injectable probe seam with a
scratch `MORBSTACK_HOME`; production defaults unchanged.

A pre-push hook is theatre with no remote, so the gate now fires as `mise run check`
(+ `scripts/git-hooks/pre-commit`, installed via `mise run install-hooks`), mandated by CONTRIBUTING.md.

### 2. The guest image is stale, and it invalidates a large block of the wave.

| Artifact | Built | Source last changed |
| --- | --- | --- |
| `~/.morbstack/data/kernel/initrd.img` — what the VM actually boots | 2026-08-02 19:46 | `guest/` → 2026-08-03 14:36 |
| `dist/guest-bin/dockerd` | 2026-08-01 16:02 (upstream fetch) | the `-P` allocator patch |

`strings dist/guest-bin/dockerd | grep -c morbstack` → **0**. The shipped engine binary is unpatched
upstream Moby. **21 commits touching `guest/` have landed since the image was built**, including
publish-all `-P` (`06bf81d`, `103ab2d`, `8e3b82c`), `host.docker.internal` (`ce02ae4`), UDP publishing
(`5f94d3a`), host networking (`2f8272f`, `bc94e78`), disk grow (`53f6d4a`, `acd0925`) and the bind-mount
alias (`435d09f`).

Rebuilding the *app bundle* does not help: the bundle's initrd is byte-identical (SHA256 `e82ff43…`)
to the running one. Only `mise run guest-image` refreshes it.

So three headline features — `-P`, the live-share bridge, and the disk-grow transaction — **have never
been executed by anything**. Commit `53f6d4a` is titled "Add *verified* grow-only Docker disk
transaction"; nothing was verified, because the bytes that would run it do not exist.

Every functional result must therefore be labelled in three buckets: provable now, unprovable until a
guest rebuild, genuinely open. See FUNCTIONAL-AUDIT.md.

### 3. "Unmodified upstream dockerd" is false by construction.

The project's headline architectural claim, in `README.md:9,33,300`, `site/index.html:16,109`,
`docs/comparison.md`, `docs/architecture.md:139,144`, `docs/parity.md:71`, `docs/roadmap.md:36,219`.

But `guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch` adds 174 lines to Moby,
`scripts/mkinitramfs.sh:82-87` **hard-fails** without the patched binary, and `:215-219` installs it
*as* `dockerd`. Exactly one document (`docs/dynamic-port-allocation.md:80-87`) is honest about it.

There is a bootstrap problem behind it: `scripts/build-morbstack-dockerd.sh:44-47` requires
`docker buildx`. **You now need Docker to build the thing that replaces Docker.**

Either drop the claim, or make the patch optional with a documented capability downgrade when `-P`
is unavailable. It cannot stay as written.

### 4. XCUITest now runs — and 3 of its 5 tests fail on real defects.

It had never produced a green run. The blocker was never the harness: `DevToolsSecurity -status`
reported **"Developer mode is currently disabled"**, so runner init timed out at 60 s. One
`sudo DevToolsSecurity -enable` fixed it. Meanwhile `docs/build.md` and `docs/development/codex.md`
both cite XCUITest as *the* acceptance gate for real-window validation.

Clean run, 5 tests, 2 passed:

| Test | Result |
| --- | --- |
| `testFixtureRoutesInLightAppearance` | pass |
| `testFixtureRoutesInDarkAppearance` | pass |
| `testSidebarUsesTheSystemViewMenuCommand` | **fail** — "View menu lacks the standard Show/Hide Sidebar command" |
| `testSearchSelectionAndInspectorUseNativeControls` | **fail** — unmatched search does not use `ContentUnavailableView.search`; selecting a container does not expose inspector content |
| `testFixtureAccessibilityAudit` | **fail** — 8× "Element has no description", 3× "Contrast failed" |

Route navigation is sound. Menus, empty-state semantics and accessibility are not. The eight
undescribed elements matter more than they look: the Containers toolbar carries up to 12 symbol-only
items including **two visually identical trash cans**, so label quality is the only thing
disambiguating two destructive actions.

Harness defect to fix alongside: the accessibility test cannot attach screenshots — "Image creation
failed. Disable automatic screenshots in your test plan's configuration."

### 5. Documentation confidence outruns the code, temporally rather than dishonestly.

Six parallel status documents reconciled by hand, with commits outrunning them in both directions:

- `docs/final-implementation-audit.md:34` says `-P` was "intentionally rejected" — nine hours before `-P` shipped.
- `docs/competitive-capability-roadmap.md:48` calls disk resize "unavailable" the same day `53f6d4a` landed.
- `docs/comparison.md:346-357` still tells the world no Docker client is bundled; that stopped being true before it was published.
- `docs/comparison.md:206` reports Kubernetes "working" — the cluster is, but pod port-forward needs a pinned `kubectl` (`KubectlTool.swift:16-30`) that is not in the repo. The internal audit says so; `comparison.html`, which outsiders read, does not.
- `morb scan` promises "SBOM and CVE scan an image, entirely on this machine" (`main.swift:46`), bundles neither syft nor grype, points five times at `scripts/fetch-scan-tools.sh` — **which does not exist** — and downloads a vulnerability database over the network.

The root cause is one word: **"implemented"**. The repo carefully defines "implemented in source" vs
"live accepted", then collapses "compiled, ran, awaiting clean-profile" and "the binary that would run
this does not exist" into the same status value. Several documents (`domains.md`, `machines.md`,
`debug.md`) are models of honest self-reporting; the problem is the aggregate, not the intent.

**Recommendation:** collapse the six status documents into one generated from a machine-checkable
source, and split the status vocabulary into `source-only` / `runs-here` / `accepted`.

### 6. ~1,750 lines of finished, inert subsystems ship inside the binary.

This — not stub screens — is the real "coming soon" violation:

| File | LOC | State |
| --- | --- | --- |
| `MorbShareSyncProtocol.swift` | 1,002 | zero callers; complete auth + wire protocol |
| `MachineImageAdmission.swift` | 581 | zero callers; `assess()` has **no success path at all** |
| `LocalDomainClaimReconciler`, `TarLite.swift` | — | zero callers |

Related: **test coverage runs backwards from the risk.** `VMManager.swift` (2,097 LOC) has no test
that boots or restores a VM; the `MorbDiskGrowth` journal has none; the live-share transport and both
guest modules (~1,850 LOC, self-described "authority boundary") have none; `PublishAllPortAllocator`
and guest `publish_all.rs` have none on either side. The tests that *do* exist are genuinely good —
they are simply pointed at the safe parts.

### 7. Packaging is real up to the DMG and vaporware past it.

`scripts/release.sh`, `docs/RELEASING.md`, `docs/sparkle.md`, `.github/workflows/release.yml` and any
Homebrew cask **do not exist** — all four are referenced by name as the source of truth. There is not
a single `notarytool` call anywhere in the repo. An unnotarized DMG is Gatekeeper-blocked for every
user who is not the author, so "single-path install" currently stops one step short of a stranger
being able to install it.

Adjacent: the guest-image CI job would have failed on every run — it needs `docker buildx` for the
Moby build, and hosted macOS runners ship no Docker. Now fails fast with a preflight naming the two
real options.

### 8. The UI ships three blockers, and one of them substitutes the VM's files for yours.

[UI-AUDIT.md](UI-AUDIT.md) registers **32 issues: 3 blocker, 9 major, 14 minor, 8 polish.**

The three blockers:

1. **Bind mounts silently serve the Linux VM's files as the Mac's.** `-v /etc/hosts:/x` yields the
   *guest's* hosts file, not yours. `/tmp` and `/var` yield empty directories. No error in any case.
   This is worse than data loss — it is data *substitution*, and a container reading a config file
   this way gets plausible wrong content. Fixed in `435d09f`; **the shipped bundle carries the
   pre-fix guest image**, so the fix is not in effect for anyone.
2. **Fixture mode is indistinguishable from live data.** A `--tour-fixtures` window shows fabricated
   containers with internally consistent badges and counts while the footer reads "Engine running" —
   which fixture mode never checks, because it never dials the engine. It fooled the auditor for
   ~60 seconds; it is uncatchable from a screenshot, which is exactly how screenshots get cited as
   evidence.
3. **A port renders as `18,099`.** A thousands separator applied to a port number.

The majors cluster around chrome and narrow widths: no Show/Hide Sidebar in the View menu (also
caught by XCUITest); ~12 symbol-only toolbar items across 6 groups against a stated cap of 3,
including two visually identical trash cans; toolbar items vanishing at narrow width with no
overflow affordance, which combined with the missing menu command makes some commands unreachable;
the Images table crushing its Repository column to one character per row; the Disk inspector
overdrawing the table; and container uptime freezing at "Up 23 seconds" while `docker ps` said "Up
About a minute".

**SIGTRAP is refuted** — four documented attempts including 16 rapid route switches at narrow width,
all against `argv`-verified live instances.

**Coverage caveat, and it is significant.** Stacks, Kubernetes, Networks, Builds, Migration,
Settings, ⌘K, the menu-bar extra, light mode, and prune/pull-from-app were **not tested**. No
screenshots were saved. The verdict rests on what was exercised; a fuller pass finds worse, not
better. A second UI pass is required before any of this is considered complete.

## What is genuinely good

- **Compose works properly.** A 3-service stack (nginx + a built-from-Dockerfile Python API +
  postgres:16), `depends_on: condition: service_healthy` chained db → api → web, all reaching
  `(healthy)`, `up -d --build` in **12.9 s including a BuildKit image build**. Named volume, host bind
  mount served through nginx, `environment:` delivery, and a real `secrets:` file mount authenticating
  psql. This is the strongest evidence in the audit.
- **The bundled toolchain is real.** `Contents/Resources/host-bin/{docker,cli-plugins/docker-buildx,
  cli-plugins/docker-compose}` with a `TOOLCHAIN.plist` carrying SHA256 + source_sha256 per tool —
  docker 29.7.1 (client matches server), compose v5.3.1, buildx v0.36.0. The single-path-install
  requirement is met in the bundle. (Caveat: plugins resolve from `$DOCKER_CONFIG/cli-plugins`, so
  isolating `DOCKER_CONFIG` loses `docker compose` unless `morb install-cli` links them.)
- **The bind-mount fix is fail-closed.** `435d09f` is two-sided — the guest aliases `/tmp` onto the
  shared `/private/tmp` root and *reports* it, and the host preflight admits a bare `/tmp` only after
  the guest confirms. An older guest is explicitly "not guessed to be safe". `/var` and `/etc` are
  rejected with a corrective message. This is how the whole codebase should handle version skew.
- **3.0-second cold boot** to a ready upstream dockerd 29.7.1. The best number in the audit, and the
  one that most directly justifies the architecture.
- **Live updates are correct.** New containers appear in under 2 s with no manual refresh, counts and
  badges track, and selection is preserved across list mutation — the detail most implementations get
  wrong.
- **Stats are accurate and the known first-sample bug is fixed** — first reading 100.6 % against
  `docker stats` 100.14 %.
- **`morb` and its help text are the house style.** Correct exit codes throughout, and prose that
  volunteers its own limits ("snapshots, not reservations", "does not open a shell yet"). This is what
  the rest of the product's writing should be measured against.
- **`MorbBench` measures real things** — cold boot, idle CPU, wakeups, RSS.
- **Asset provenance is exceptional.** Every third-party asset is SHA-256 pinned, several doubly, and
  Moby is pinned to both a tag and a peeled commit. This is better than most funded projects manage.
- **The codebase is maintainable, not slop.** No duplicate implementations across 186 Swift files, a
  clean acyclic module graph, essentially no TODO debris, honest unavailable states, and comments that
  explain *why* — `mise-tasks/app` teaches you which bug each line prevents. The AI provenance shows up
  in exactly one shape, consistently: **nothing was ever executed end to end.** Every defect above is
  invisible to a diff reviewer and obvious the moment something runs. The confidence was manufactured
  by review instead of by execution, and that is a mechanical fix.
- **The native migration is real.** Custom cards, chips, glass wrappers and the offscreen renderer are
  gone; routes use system `Table`, `Form`/`LabeledContent` and `.inspector`.

## Ranked fix list

| # | Fix | Why | Effort |
| --- | --- | --- | --- |
| 0 | ~~Green test suite + a local gate~~ | **done during this audit** — suite green, `mise run check` + pre-commit hook added | — |
| 1 | Finish the security review of the untrusted-input surfaces | see caveat below — this is an unclosed gap, not a clean bill of health | 1–2 days |
| 2 | Rebuild the guest image, then run the port / share / disk matrices | validates or kills three headline features at once | 1 day |
| 3 | Create the remote; make CI actually run | CI that has never executed is worse than none once a remote appears | hours |
| 4 | Fix the three XCUITest failures | missing standard View menu command, non-native empty state, 8 undescribed elements | 1–2 days |
| 5 | Retract or qualify "unmodified upstream dockerd" everywhere | headline claim, currently false | hours |
| 6 | Fixture-mode watermark | a `--tour-fixtures` window is visually indistinguishable from live, and its footer says "Engine running" while never dialling the engine | hours |
| 7 | Container `exec` + PTY in the app | no `exec` in `DockerClient.swift`, no PTY view; table stakes against both competitors | 1–2 wks |
| 8 | Collapse six status docs into one generated file | the "implemented" ambiguity is systemic | days |
| 9 | Ship `scripts/fetch-scan-tools.sh` or stop referencing it | `morb scan` cites a file that does not exist | hours |
| 10 | Clean-profile CP-01–CP-07 before any public claim | nobody has ever installed this | 1 day |

### Caveat: the security review did not complete

The systematic input-handling review of the untrusted-input surfaces — the vsock protocols (1024
control, 2375 docker, 2376 stream-dial, 2377 bulk, 2381 file events) and the MCP server — was
attempted twice and did not finish. **Treat those surfaces as unreviewed.** This is the single
largest unclosed gap in the audit, and it covers precisely the code that parses attacker-shaped input
across a trust boundary. REPO-AUDIT.md §5 records this explicitly rather than implying coverage.

Also unverified by lane discipline: `app`, `sign`, `guest-image`, `run-daemon`, `run-app` were
converted to file-based tasks but not executed. The entitlement-preserving signing order is the one
that must be re-proved by hand — `codesign --deep` silently strips the virtualization entitlement,
and the failure mode is a shipped app whose engine can never boot a VM.

## Strategic correction

**OrbStack paywalls almost nothing.** Domains, HTTPS, routable IPs, native file access and Linux
machines are all free tier. The only genuine feature gate is the debug toolbox ($8/user/mo); the
paywall is a **commercial-use licence**, not a feature wall. Docker Desktop's gate is real but is
almost entirely compliance tooling (ECI, Hardened, registry access management, SSO, air-gapped) — the
wrong market for a one-maintainer project.

So the strategy is not "free versions of paid features." It is **the same free-tier capabilities, in
the open, with no commercial-use asterisk** — which means building them, not undercutting a price.

Highest impact-per-effort, per [DIFFERENTIATION.md](DIFFERENTIATION.md): proven hot reload with a
published watcher conformance matrix (the mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB`
only — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`, and
nobody in this market publishes such a matrix); container exec + PTY; publishing the benchmark
harness itself; container domains sequenced router-first; then the debug toolbox.

## Method note

Two errors in this audit are worth recording, because both were caused by trusting an identifier over
its contents.

1. A running daemon was reused on the strength of its path. `PID 20575` resolved to
   `dist/Morbstack.app/…/morbstackd`, but had the old inode mapped — 3,654,240 bytes of text against a
   5,353,856-byte file on disk, started six hours before the bind-mount fix landed. Every host-side
   result measured against it was pre-fix, and a fixed bug was nearly filed as an open blocker.
2. `git ls-files | grep -i xcui` returned nothing, and was read as "the XCUITest harness is untracked."
   The directory is named `UITests`. Six files are tracked, including `project.pbxproj`.

**Verify contents, not names.** `pgrep` argv and inode size before trusting a process; `git ls-files
<path>` before concluding absence.
