# What OrbStack and Docker Desktop have that we need — free, and better

**Status:** live tracking document. Update the *State* column whenever something moves; do not
rewrite the doc. Strategy narrative lives in [audit/DIFFERENTIATION.md](audit/DIFFERENTIATION.md);
ordering lives in [MASTER-PLAN.md](MASTER-PLAN.md). This file is the checklist.

State vocabulary is the project standard: `source-only` (compiles, never run) · `runs-here`
(executed against the current build) · `accepted` (passed the clean-profile matrix) · `absent`.

---

## The strategic correction that shapes this whole document

**OrbStack paywalls almost nothing.** Domains, HTTPS, routable container IPs, native file access
and Linux machines are all on the free tier. The only genuine feature gate is the debug/distroless
toolbox (~$8/user/mo). What you actually buy is a **commercial-use licence**.

**Docker Desktop's paid gate is real but is almost entirely compliance tooling** — Enhanced
Container Isolation, Hardened Docker Desktop, registry access management, SSO, air-gapped installs,
Settings Management, Docker Scout's paid tiers, Build Cloud. That is enterprise procurement, not
developer ergonomics.

So the pitch is **not** "free versions of paid features." It is: *the same free-tier capabilities,
in the open, Apache-2.0, no account, no telemetry, and no commercial-use asterisk.* Which means we
have to **build** them, not undercut a price. Every row below is a build, not a discount.

---

## Apple is now a competitor, and that is mostly good news

Researched 2026-08-03 against primary sources (GitHub releases/API, Apple's own docs).

Apple ships **`container`** (v1.2.0, 29 Jul 2026; 1.0 froze the API in June) on the
**Containerization** framework — 48.6k stars, monthly releases, active commits. It is real,
stable and mainstream. But its architecture is **VM-per-container**, not one shared VM, and
its compatibility posture is the opposite of ours:

- **Apple explicitly declined Docker Engine API compatibility.** The request to expose a
  `/var/run/docker.sock` equivalent was closed **"not planned"** ([apple/container#66]).
- **No native Compose. No Docker CLI compatibility.**
- macOS 15 containers cannot talk to each other at all; container-to-container networking
  needs macOS 26.
- virtiofs bind mounts are slow enough that a maintainer recommends named volumes (~3× faster,
  still 2–3× slower than bare metal).
- **VM memory is never returned to the host** — freed guest pages are not relinquished, so the
  per-VM model accumulates cost at scale.
- No prebuilt kernel is published; it is a build-it-yourself recipe derived from Kata's config.

**What the ecosystem did about it is the tell.** No major tool — not Docker Desktop, OrbStack,
Podman, or Colima — has adopted Containerization as a backend. Instead, third parties bolt
Docker compatibility *onto* Apple's tool (`socktainer` for a Docker-ish REST API,
`container-compose` for compose files, `kina`/`kiac` for Kubernetes). The gap Apple left open
is precisely the one Morbstack fills.

So Apple entering this space **validates the bet** — VM-based containerization on Apple silicon
is now first-class and mainstream — rather than threatening it. Morbstack's thesis (real Moby,
real Engine API, real Compose, real CLI) is the thing Apple has decided not to do.

**The one thing to watch:** `container machine`, shipped in 1.0 — a persistent VM with the
user's home directory mounted, framed as "the closest thing to WSL on macOS". That is adjacent
to DIF-13 (Linux machines), and Apple's roadmap reportedly includes Kubernetes and a
WSL competitor. Compete there deliberately or not at all; do not drift into it.

[apple/container#66]: https://github.com/apple/container/issues/66

---

## Table stakes — if any of these is wrong, nothing else matters

| Capability | Them | Us | State |
| --- | --- | --- | --- |
| Stock `docker` CLI works with zero setup | both | bundled toolchain, docker 29.7.1 / compose v5.3.1 / buildx v0.36.0, SHA-pinned; since ECO-1 `morb install-cli` also registers the `morbstack` context and the `~/.docker/run/docker.sock` link, so context-blind clients find Morbstack with no env vars ([design/ZERO-CONFIG-DISCOVERY.md](design/ZERO-CONFIG-DISCOVERY.md)). Defers to Docker Desktop when Desktop already owns the conventional socket | `runs-here` |
| `docker run -p` in all forms | both | fixed/dynamic/UDP/ranges; ambiguity preflight bug just fixed | matrix in progress |
| `docker run -P` | both | stock dockerd through its own `--userland-proxy-path` hook — no engine patch (TECH-1); `docker run -P nginx:alpine` served `curl` HTTP 200 in 4.3 ms against a rebuilt guest ([design/PATCH-FREE-PUBLISH-ALL.md](design/PATCH-FREE-PUBLISH-ALL.md)) | `runs-here` |
| Compose | both | 3-service healthcheck-chained stack up in 12.9 s incl. a BuildKit build | `runs-here` |
| BuildKit / buildx | both | bundled, real build verified | `runs-here` |
| Bind mounts that serve the *host's* files | both | `435d09f` fail-closed fix, first runtime check in progress | verifying |
| `host.docker.internal` | both | guest DNS | `source-only` |
| Volumes, networks, logs, exec, cp, stats | both | present | mostly `runs-here` |
| Testcontainers (Java/Go/Node/Python) | both | tested live 2026-08-04 (EN-8): all four languages ran real Postgres round trips against server 29.7.1 with Ryuk, warm totals 1.5–5.9 s, and after ECO-1/ECO-2 with **no Docker env vars at all**. Known limit: testcontainers-java ≤1.20.x fails against *any* engine-29 daemon (its `/v1.32/info` probe vs moby 29's `MinAPIVersion`), mitigated in the guest with `DOCKER_MIN_API_VERSION=1.24` | `runs-here` ([audit/ECOSYSTEM-MATRIX.md](audit/ECOSYSTEM-MATRIX.md)); `accepted` still needs CP-06 |
| Dev Containers | both | tested live 2026-08-04 (EN-9): @devcontainers/cli 0.88.0 `up` in 34 s incl. pull, plus exec, two-way workspace bind mount, `postCreateCommand`, and a features/derived-image build through Morbstack BuildKit — context-only discovery, no `DOCKER_HOST`. The VS Code extension flow is untested | `runs-here` ([audit/ECOSYSTEM-MATRIX.md](audit/ECOSYSTEM-MATRIX.md)); `accepted` still needs CP-07 |
| Installs on a Mac with no Docker | both | bundle is right; **not notarized**, so Gatekeeper blocks everyone but the author | blocked |

---

## Ergonomics that make people pay — ranked by impact per effort

| # | Capability | What they give | Where we stand | State |
| --- | --- | --- | --- | --- |
| 1 | **Fast file sharing + working hot reload** | OrbStack's headline; inotify works inside containers | VirtioFS is fast (1.1 GB/s write). Live-share bridge exists; its mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB` **only** — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`. `liveSharePaths` defaults to `[]` with **no CLI or GUI writer**. | `source-only` |
| 2 | **Container shell one click away** | both, prominently | No `exec` in `DockerClient.swift`, no PTY view anywhere | `absent` |
| 3 | **Honest, reproducible benchmarks** | neither publishes a runnable harness | `MorbBench` measures cold boot, idle CPU, wakeups, RSS for real. Missing `git-status-bindmount` and `npm-install-bindmount-vs-volume` — the two people compare | `runs-here`, incomplete |
| 4 | **Automatic container domains** | OrbStack: `*.orb.local`, free | Mechanism decided (SP-2/SP-3, [`design/DNS-DECISION.md`](design/DNS-DECISION.md)): unprivileged mDNS `A` records under `.local`, verified on macOS 26.4 — no entitlement, no password, nothing to uninstall. ~3–4 weeks. Suffix settled as `morb.local`; no wildcard subdomains | `source-only` |
| 5 | **HTTPS via a local CA** | OrbStack, free | Needs a name-constrained CA. `NEDNSSettings` spike done and the API is **rejected** — it accepts only DoH/DoT, so it would need a trusted cert before DNS works. ~2–3 weeks after #4; costs one Keychain trust prompt | `absent` |
| 6 | **Routable container IPs from the host** | OrbStack, free | | `absent` |
| 7 | **Native file access to volumes (Finder)** | OrbStack, free | | `absent` |
| 8 | **Debug toolbox for distroless images** | **the one thing OrbStack actually paywalls** | Depends on #2 | `absent` |
| 9 | **Migration from Docker Desktop with images + volumes** | OrbStack does this well | `morb migrate` exists; correctly refuses optioned local volumes rather than silently downgrading them | `source-only` |
| 10 | **Kubernetes in seconds** | both | k3s + cri-dockerd cluster works; pinned `kubectl` that pod port-forward needs is **not in the repo** | partial |
| 11 | **Seamless amd64 via Rosetta** | both | Verified: amd64-only mysql:5.7 boots, SHA2 bit-identical to host, ~1.0× container start, 1.5–1.7× compute | `runs-here` |
| 12 | **Image vulnerability scanning** | Docker Scout (paid tiers) | `morb scan` wraps syft/grype — bundles neither, and references `scripts/fetch-scan-tools.sh` five times, **which does not exist** | broken |
| 13 | **Linux machines / distro VMs** | OrbStack, free | | `absent` |
| 14 | **VS Code / JetBrains integration** | both | | `absent` |
| 15 | **Low idle cost** | OrbStack's other headline | 3.0 s cold boot; auto-suspend with a budget ladder; running containers inhibit suspend | `runs-here` |

---

## Where we already win, and should say so loudly

- **Apache-2.0, no account, no telemetry, no commercial-use licence.** Structural, not a feature.
- **3.0-second cold boot** to a ready engine.
- **Asset provenance** — every third-party binary SHA-256 pinned, several doubly; Moby pinned to tag *and* peeled commit. Better than most funded projects.
- **A publishable benchmark harness.** A closed competitor structurally cannot match "here is the harness, run it yourself."
- **Honest CLI writing.** `morb`'s help volunteers its own limits ("snapshots, not reservations", "does not open a shell yet"). Keep that voice.
- **Old Docker API clients work against engine 29** (2026-08-04, PROTO-7). Stock moby 29 defaults its
  minimum API version to 1.44 — an upstream default, not anyone's product decision — which 400s the
  `GET /v1.32/info` probe `testcontainers-java` ≤1.20.x uses for daemon discovery; the library then
  *silently* fails over to whatever other daemon is on the machine and the suite runs green against
  the wrong engine. Morbstack sets `DOCKER_MIN_API_VERSION=1.24` (upstream's own hard floor) in the
  guest, verified live: `/v1.32/info` → 200, modern negotiation unchanged at 1.55. Docker Desktop is
  only insulated from this because it still ships engine 27; when it moves to 29 it inherits the
  breakage unless it does the same. Morbstack is the engine-29 distribution the ≤1.20.x
  testcontainers-java installed base actually works against.

## Where we must stop claiming a win

- **"Unmodified upstream dockerd"** — resolved 2026-08-04 (TECH-1). This claim was false while the 174-line downstream Moby patch existed and `mkinitramfs.sh` hard-failed without it; the patch is now deleted and Morbstack ships stock, archive-hash-pinned Docker 29.7.1 binaries, with published ports served through dockerd's own stock `--userland-proxy-path` hook. The claim is true again and has been restored across the README, the site, and the docs it was previously removed from — see `docs/TRUTHFULNESS-PASS.md`'s third-pass section.
- **Building Morbstack currently requires Docker** — resolved 2026-08-04 as a side effect of the same decision: there is no patched engine to build, so nothing in the default build path (`build-patched-dockerd`, `docker buildx`) is needed at all.

## Deliberately not chasing

Docker Desktop's compliance suite — ECI, Hardened Desktop, registry access management, SSO,
air-gapped install, Settings Management. Enterprise procurement is the wrong market for a
one-maintainer open-source project, and chasing it would eat the roadmap and win nobody.
