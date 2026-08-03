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

## Table stakes — if any of these is wrong, nothing else matters

| Capability | Them | Us | State |
| --- | --- | --- | --- |
| Stock `docker` CLI works with zero setup | both | bundled toolchain, docker 29.7.1 / compose v5.3.1 / buildx v0.36.0, SHA-pinned | `runs-here` |
| `docker run -p` in all forms | both | fixed/dynamic/UDP/ranges; ambiguity preflight bug just fixed | matrix in progress |
| `docker run -P` | both | patched Moby allocator; first execution today | in progress |
| Compose | both | 3-service healthcheck-chained stack up in 12.9 s incl. a BuildKit build | `runs-here` |
| BuildKit / buildx | both | bundled, real build verified | `runs-here` |
| Bind mounts that serve the *host's* files | both | `435d09f` fail-closed fix, first runtime check in progress | verifying |
| `host.docker.internal` | both | guest DNS | `source-only` |
| Volumes, networks, logs, exec, cp, stats | both | present | mostly `runs-here` |
| Testcontainers (Java/Go/Node/Python) | both | **never tested** | `absent` as evidence |
| Dev Containers | both | **never tested** | `absent` as evidence |
| Installs on a Mac with no Docker | both | bundle is right; **not notarized**, so Gatekeeper blocks everyone but the author | blocked |

---

## Ergonomics that make people pay — ranked by impact per effort

| # | Capability | What they give | Where we stand | State |
| --- | --- | --- | --- | --- |
| 1 | **Fast file sharing + working hot reload** | OrbStack's headline; inotify works inside containers | VirtioFS is fast (1.1 GB/s write). Live-share bridge exists; its mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB` **only** — fine for chokidar/nodemon/vite and Python watchdog, filtered out by Go tools like `air`. `liveSharePaths` defaults to `[]` with **no CLI or GUI writer**. | `source-only` |
| 2 | **Container shell one click away** | both, prominently | No `exec` in `DockerClient.swift`, no PTY view anywhere | `absent` |
| 3 | **Honest, reproducible benchmarks** | neither publishes a runnable harness | `MorbBench` measures cold boot, idle CPU, wakeups, RSS for real. Missing `git-status-bindmount` and `npm-install-bindmount-vs-volume` — the two people compare | `runs-here`, incomplete |
| 4 | **Automatic container domains** | OrbStack: `*.orb.local`, free | Router-only would already beat hand-wiring Traefik + mkcert + dnsmasq. `.local` vs `.test` unresolved in our own docs | `source-only` |
| 5 | **HTTPS via a local CA** | OrbStack, free | Needs a name-constrained CA. Spike `NEDNSSettings` first — it decides six weeks vs impossible | `absent` |
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

## Where we must stop claiming a win

- **"Unmodified upstream dockerd"** — false. The Moby patch adds 174 lines and `mkinitramfs.sh` hard-fails without it. It is in the README, the site, and four docs.
- **Building Morbstack currently requires Docker** (`build-patched-dockerd` needs `docker buildx`). Awkward for a Docker replacement; fix by publishing the engine as a pinned release artifact.

## Deliberately not chasing

Docker Desktop's compliance suite — ECI, Hardened Desktop, registry access management, SSO,
air-gapped install, Settings Management. Enterprise procurement is the wrong market for a
one-maintainer open-source project, and chasing it would eat the roadmap and win nobody.
