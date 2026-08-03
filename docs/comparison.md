# Morbstack vs. the field

Status: one-time comparison, written 2026-08-02 against Morbstack git HEAD
`ba9afc6`. Not CI-enforced, not updated automatically — treat prices,
versions, and vendor claims below as accurate as of the access date on each
citation and nothing later.

## 1. Purpose, method, and an honesty statement

This document compares Morbstack against six things developers actually
reach for on macOS: Docker Desktop, OrbStack, Podman Desktop (+ `podman
machine`), Rancher Desktop, Colima (+ Lima), and Apple's open-source
`container` project. It exists to answer, as precisely as the evidence
allows, "how does Morbstack actually differ, and where is it actually
worse."

**Evidence tiers, and what each one is worth:**

- **Morbstack's own numbers** come from exactly four places in this repo —
  [`docs/parity.md`](parity.md), [`docs/roadmap.md`](roadmap.md),
  [`docs/compat.md`](compat.md), and [`docs/amd64.md`](amd64.md)/[`docs/k8s.md`](k8s.md)
  — and nowhere else. No number below about Morbstack was generated for
  this document. Where a Morbstack figure is a *target* rather than a
  *measurement*, it is labeled as such every time it appears; conflating
  the two is exactly the kind of dishonesty this document exists to avoid.
- **Local, first-hand inspection** covers Docker Desktop, which is
  installed on the machine this document was written on
  (`/Applications/Docker.app`, timestamps dated December 2024 — an older
  installed copy, not necessarily the current shipping release; see §8).
  It was inspected read-only: bundle contents, `codesign`, `otool`, `nm`,
  and a snapshot of its already-running processes, with nothing started,
  stopped, or reconfigured, and `~/.docker` never touched. OrbStack,
  Podman, Rancher Desktop, Colima, and Apple's `container` are **not**
  installed on this machine (`ls /Applications`, `which`, and `brew list
  --cask` all came back empty for all five, checked 2026-08-02) — every
  claim about them below is web-sourced, not independently reproduced
  locally, and is marked accordingly.
- **Vendor and third-party claims from the web** are quoted and attributed,
  never presented as Morbstack-verified fact. Several of these vendors are
  closed-source (OrbStack) or make performance claims Morbstack has no way
  to independently reproduce; those are flagged as claims, not results.
- Anywhere research was inconclusive or a page could not be verified, this
  document says **"could not verify"** rather than filling the gap from
  memory.

**The honesty statement this document is built to satisfy:** Morbstack is
**pre-alpha, unreleased, and has never been used by anyone outside this
repository's own test passes.** It has one maintainer, no security audit,
no notarized installer, and — per its own [parity audit](parity.md) — 6
outright failures and 4 behavioral gaps out of 29 real drop-in-compatibility
checks run against a live build. Every competitor discussed here has
shipped, has real users, and in most cases has been hardened by exactly the
kind of adversarial and edge-case usage Morbstack has not yet received. Where
this document argues Morbstack has a structural advantage (license, VM
topology, native UI), that advantage is real and evidenced below — but it
is an advantage of *design*, not of *maturity*, and §6 exists specifically
to keep those two things from blurring together.

---

## 2. Architecture

| | Hypervisor | VM topology | Container runtime | Filesystem sharing | Networking | Host UI | x86 emulation |
|---|---|---|---|---|---|---|---|
| **Morbstack** | `Virtualization.framework` | one shared VM for all containers | unmodified upstream `dockerd` + `containerd` (static 29.7.1) | VirtioFS, same-absolute-path bind mounts | outbound NAT only (M0); no `morbnet`/DNS/host-routable IPs yet | native SwiftUI, zero web views (planned; not part of M0) | Rosetta binfmt (working); qemu fallback (inert, no binary shipped) |
| **Docker Desktop** | `Virtualization.framework` — confirmed by local inspection (below); historically HyperKit on older releases | one shared LinuxKit VM | Moby `dockerd` inside the VM (Docker CLI 27.4.0 on the inspected copy) | VirtioFS (`com.docker.osxfs` binary present) | own virtual network stack + `vpnkit`-descended NAT, `host.docker.internal` DNS | Electron (`com.electron.dockerdesktop` bundle identifier, confirmed locally) | Rosetta (`VZLinuxRosettaDirectoryShare` symbols present) with a bundled `qemu-system-aarch64`/`qemu-img` as a secondary path |
| **OrbStack** | undisclosed, described only as "a lightweight Linux virtual machine with a shared kernel...similar to WSL 2" — closed source, cannot verify independently ([OrbStack architecture docs](https://docs.orbstack.dev/architecture), accessed 2026-08-02) | one shared VM for all containers and "machines" | runs "the Docker engine" per OrbStack's own docs; peripheral host-side services described as custom-built, not off-the-shelf — whether `dockerd` itself is patched is unverifiable from outside (closed source) | "VirtioFS with custom dynamic caching and optimizations" (OrbStack docs) | custom userspace network stack with NAT and a custom DNS server (OrbStack docs) | closed-source native app (not Electron, per OrbStack's own marketing; not independently verified here) | Rosetta ("boots an ARM64 Linux kernel, but paired with an x86-64 userspace filesystem, using Rosetta 2" — OrbStack docs) |
| **Podman Desktop + podman machine** | Apple Virtualization Framework (`applehv`) is the macOS default as of Podman 5.x, replacing QEMU ([Podman machine providers, DeepWiki summary of upstream docs](https://deepwiki.com/containers/podman/13.1-machine-providers-and-vm-configuration), accessed 2026-08-02) | one shared VM (the "machine") per configured machine, containers share it | `podman`/`libpod` + `crun`/`runc` — **not** `dockerd**; Docker CLI/API compatibility is via `podman-docker`/socket emulation, not the real Docker Engine | 9p/virtiofs-backed volume mounts (implementation detail of the machine image) | rootless slirp4netns-derived networking by default | Podman Desktop itself is an Electron-independent Node/Electron app — **note**: could not fully verify Podman Desktop's UI toolkit from primary sources in this pass; treat as unconfirmed | Rosetta supported on Apple silicon machines ([Podman Desktop docs](https://podman-desktop.io/docs/podman/rosetta), accessed 2026-08-02) |
| **Rancher Desktop** | Lima-managed VM, which itself uses QEMU or `vz` depending on Lima's configuration | one shared VM | user's choice: Moby `dockerd` (Docker CLI) or `containerd` (via `nerdctl`, Docker-CLI-compatible) — [Rancher Desktop docs](https://docs.rancherdesktop.io/), accessed 2026-08-02 | Lima's own 9p/virtiofs mount, `/Users`-rooted like Colima | Lima's user-mode networking | Electron ("Rancher Desktop is an open-source desktop application... Electron-based," per third-party technical summaries; not independently re-verified against the repo in this pass) | not confirmed to have a first-class Rosetta/x86 story distinct from whatever Lima provides — could not verify from primary sources in this pass |
| **Colima + Lima** | user-selectable: QEMU (Colima's default) or `vz` (Apple Virtualization Framework, recommended on macOS 13+); also `krunkit` for GPU-accelerated AI workloads ([Colima README/FAQ](https://colima.run/docs/faq/), accessed 2026-08-02) | one shared VM ("the" Colima instance; multiple named instances are possible but each is still one shared VM) | user's choice via `--runtime`: `docker` (default) or `containerd` ([search summary of Colima docs](https://github.com/abiosoft/colima), accessed 2026-08-02) | Lima's 9p/virtiofs mount, rooted at `/Users/$USER` by default; other paths need explicit mount config | Lima's user-mode networking | **CLI only — no GUI at all.** Colima is a command-line tool; there is no host application to compare on this axis. | not a first-class feature; QEMU can software-emulate x86 at a large performance cost, distinct from Rosetta's hardware-assisted translation |
| **Apple `container`** | `Virtualization.framework` via `vmnet`/XPC helpers | **one dedicated micro-VM per container** — the one architectural outlier in this table (Apple's own docs: "it runs a lightweight VM for each container that you create," [technical-overview.md](https://github.com/apple/container/blob/main/docs/technical-overview.md), accessed 2026-08-02) | Apple's own Swift `containerization` runtime, OCI-compliant, **not** `dockerd` and not Docker-API-compatible | selective per-container host-path mounts ("you mount only necessary data into each VM" — Apple's own docs) rather than a shared always-on share set | `container-network-vmnet`, an XPC helper managing per-VM networking | native, `container` is a CLI only (no bundled GUI in the `apple/container` repo itself) | **none** — Apple silicon only, no x86 container support of any kind |

**Reading this table honestly:** Morbstack, Docker Desktop, OrbStack, Podman
machine, Rancher Desktop, and Colima all converge on the same basic shape —
one shared Linux VM, `Virtualization.framework` (or Lima's abstraction over
it) as the hypervisor, VirtioFS-family bind mounts. Morbstack's specific bet
inside that shape is being the only one of the six with **zero
modification to the actual container engine** verified end-to-end (see
[`docs/parity.md`](parity.md) #1-#4, #12-#14) — Podman and Apple's
`container` aren't running Docker's engine at all, and OrbStack's engine
internals are unverifiable because the product is closed source. Apple's
`container` is architecturally the odd one out entirely: per-container
micro-VMs trade away exactly the shared-kernel properties (Compose
networks, `--network container:x`, shared page cache) that
[`docs/architecture.md`](architecture.md) explains Morbstack deliberately
kept a single shared VM to preserve.

### Local inspection: what Docker Desktop actually is on this Mac

Commands run, 2026-08-02, entirely read-only, Docker Desktop's own state
never touched:

```
$ du -sh /Applications/Docker.app
1.7G    /Applications/Docker.app

$ du -sh /Applications/Docker.app/Contents/*/
1.1G    /Applications/Docker.app/Contents/Resources/
624M    /Applications/Docker.app/Contents/MacOS/
7.3M    /Applications/Docker.app/Contents/Library/

$ du -sh "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app"
261M    .../Docker Desktop.app          # the Electron UI shell alone

$ du -sh /Applications/Docker.app/Contents/Resources/*/
558M    .../linuxkit/      # boot.img + kernel — the guest VM image
368M    .../cli-plugins/   # buildx, compose, etc., bundled
161M    .../bin/           # docker CLI, kubectl, hub-tool, credential helpers
```

```
$ codesign -dv --entitlements - "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app"
Identifier=com.electron.dockerdesktop
...
com.apple.security.cs.allow-jit: true
com.apple.security.cs.allow-unsigned-executable-memory: true
```

The `com.electron.dockerdesktop` bundle identifier, plus an on-disk
`Electron Framework.framework` and `@bugsnag/plugin-electron-app` inside
`app.asar.unpacked/build/node_modules`, confirm the management UI is
Electron, not native — a real architectural fact, not an assumption.

```
$ codesign -dv --entitlements - /Applications/Docker.app/Contents/MacOS/com.docker.backend
com.apple.security.hypervisor: true
com.apple.security.virtualization: true

$ otool -L /Applications/Docker.app/Contents/MacOS/com.docker.backend | grep -i -E "virtualization|hypervisor"
/System/Library/Frameworks/Virtualization.framework/Versions/A/Virtualization ...
/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor ...

$ nm -g /Applications/Docker.app/Contents/MacOS/com.docker.virtualization | grep -c VZ
307
```

This settles a question worth settling with evidence rather than
reputation: **on this machine, Docker Desktop's backend links and uses
Apple's `Virtualization.framework` and `Hypervisor.framework`** — the same
family of API Morbstack uses — not a legacy HyperKit path (HyperKit was
Docker Desktop's hypervisor in older releases; this installed copy has
moved on). The 307 `VZ`-prefixed symbols include
`VZLinuxRosettaDirectoryShare` and `VZLinuxRosettaAbstractSocketCachingOptions`,
confirming Rosetta support at the framework level, consistent with the
`qemu-system-aarch64` (24MB) and `qemu-img` (2.9MB) binaries also present in
`Contents/MacOS` as an apparent secondary/legacy path.

Docker Desktop was running at inspection time (not started or stopped for
this document): 8 `docker`/`com.docker.*` processes, combined RSS
**89.3 MB** (`ps aux`, summed). This is a live, already-open install with
its dashboard window open (`--reason=open-tray`), not a controlled
benchmark, and is reported here only as an observed data point, not a
performance claim about either product — and it does not include whatever
resident memory the guest LinuxKit VM itself is separately consuming, which
`ps` on the host cannot see for a VM process. Notably, the running Docker
Desktop process was launched with `--analytics-enabled=true` — telemetry is
on by default on this installed copy (see §4).

---

## 3. Licensing and cost

This is Morbstack's most precise, least hype-dependent differentiator, so
it gets stated exactly rather than rhetorically.

| | License | Cost to use | Commercial-use trigger |
|---|---|---|---|
| **Morbstack** | Apache-2.0 (`LICENSE`, `NOTICE` in this repo) | **Free**, always, for everyone, at any company size | none — there is no commercial-use clause in Apache-2.0 |
| **Docker Desktop** | Proprietary/closed source | Free only for (i) non-commercial open source projects, or (ii) a commercial undertaking with **fewer than 250 employees AND less than US $10,000,000 annual revenue**. Government entities may not use it unpaid at all. Above that: **Pro ~$9/user/mo, Team ~$15/user/mo, Business $24/user/mo** (annual billing; monthly billing is somewhat higher), per Docker's own pricing page, accessed 2026-08-02 | Exceeding either the 250-employee or $10M-revenue threshold — [Docker Subscription Service Agreement §4.2](https://www.docker.com/legal/docker-subscription-service-agreement/), [Docker pricing](https://www.docker.com/pricing/), both accessed 2026-08-02 |
| **OrbStack** | Proprietary/closed source | Free for genuinely personal, non-commercial use (full feature set except commercial rights and Debug Shell) and for non-commercial student/educational use. Commercial: **Pro $8/user/mo billed annually ($96/yr), or a higher monthly rate**, per-user with up to 5 devices/user; Enterprise is quote-only | Using it "professionally as a freelancer, for a commercial or non-profit entity, or for a government entity," **or generating more than $10,000/year in connection with work that uses OrbStack** — [OrbStack licensing docs](https://docs.orbstack.dev/licensing), [OrbStack Terms of Service](https://orbstack.dev/terms), [OrbStack pricing](https://orbstack.dev/pricing), all accessed 2026-08-02 |
| **Podman Desktop + podman machine** | Apache-2.0, fully open source | **Free**, always, for everyone — [`podman-desktop` LICENSE](https://github.com/containers/podman-desktop/blob/main/LICENSE), accessed 2026-08-02 | none |
| **Rancher Desktop** | Apache-2.0, fully open source, built on 100% open-source components (Moby, containerd, k3s) | **Free**, always, for everyone — [Rancher Desktop LICENSE](https://github.com/rancher-sandbox/rancher-desktop/blob/main/LICENSE), accessed 2026-08-02 | none |
| **Colima + Lima** | MIT, fully open source | **Free**, always, for everyone — [Colima docs](https://colima.run/docs/faq/), accessed 2026-08-02 | none |
| **Apple `container`** | Apache-2.0, fully open source | **Free**, always, for everyone — [`apple/container`](https://github.com/apple/container), accessed 2026-08-02 | none |

Morbstack, Podman Desktop, Rancher Desktop, Colima, and Apple's `container`
are all genuinely free-forever open source with no commercial trigger — on
licensing terms, Morbstack is tied with four established projects, not
uniquely differentiated from all of them. Its real differentiation is
narrower and specific: it is the only one of the six in this document that
is simultaneously (a) free with no commercial-use asterisk, (b) built
around an unmodified, off-the-shelf `dockerd`/`containerd` rather than a
different engine or a closed one, and (c) aimed at drop-in Docker Desktop
replacement rather than a CLI-only tool (Colima) or a different API
surface entirely (Podman, Apple `container`). Whether it *achieves* that
combination today is a feature-completeness and quality question, covered
honestly in §4 and §6 — the license alone does not answer it.

---

## 4. Feature matrix

Morbstack rows below are marked directly from the 29-check
[`docs/parity.md`](parity.md) audit and the [compatibility contract](compat.md)
— **PASS / PARTIAL / FAIL** where parity.md tested it explicitly, **not yet
built** where `docs/roadmap.md` places it at M1 or later, and **not
planned** where `docs/compat.md` states it as an explicit non-goal.
Competitor cells are sourced from vendor documentation, cited inline; where
a claim could not be confirmed from a primary source it says so.

| Feature | Morbstack | Docker Desktop | OrbStack | Podman Desktop | Rancher Desktop | Colima | Apple `container` |
|---|---|---|---|---|---|---|---|
| `docker` CLI compatibility | **PASS** — unmodified upstream CLI against the relayed Engine API ([parity.md #1-#4](parity.md)) | native (it's the reference implementation) | full, Docker CLI works unmodified against its relayed engine (vendor docs) | Docker-CLI-*compatible* via `podman`/`podman-docker` shim, not the real Docker API — not identical | full via bundled Moby, or `nerdctl` for the containerd path | full via bundled Docker, or `nerdctl` for containerd | **no** — separate `container` CLI, not Docker-API-compatible |
| Compose | **implemented pending clean-profile revalidation** — the signed runtime now bundles Compose and the reviewed first-run transaction can install only Morbstack-owned CLI links ([parity.md #5-#7](parity.md), [first-run.md](first-run.md)) | native | supported (vendor docs) | supported via `podman compose`/`docker-compose` shim | supported | supported (Docker runtime) | **not supported** — no Compose in the `apple/container` repo per its own docs |
| BuildKit / `buildx` | **implemented pending clean-profile revalidation** — the signed runtime bundles Buildx; the native app's reviewed local-build flow uses that same client and never invents an archive/progress model ([parity.md #13-#14](parity.md), [builds.md](builds.md)) | native | supported (vendor docs) | supported | supported | supported | not applicable — different build model entirely |
| Kubernetes | **working** — `morb k8s`, single-node k3s+cri-dockerd on the same engine, measured 8.3s cold enable ([k8s.md](k8s.md)) | native (built-in k3s toggle) | supported (built-in k3s) | supported (kind/other, vendor docs) | native — Rancher Desktop's original purpose | supported via `--kubernetes` flag | not built in |
| x86-64 emulation | **PASS for what's implemented** — Rosetta binfmt working and verified byte-identical; qemu fallback written but **inert, no binary shipped** ([amd64.md](amd64.md)) | Rosetta + bundled qemu fallback, confirmed present locally | Rosetta-based, vendor docs | Rosetta supported ([Podman Desktop docs](https://podman-desktop.io/docs/podman/rosetta)) | not confirmed — could not verify a first-class story | QEMU software emulation available; no confirmed Rosetta integration | **none at all** — Apple silicon only, no x86 containers |
| Bind-mount performance | VirtioFS, tier 1; no published benchmark yet, only the parity pass's qualitative pass ([parity.md #8](parity.md), [sharing.md](sharing.md)) | VirtioFS (`com.docker.osxfs`, confirmed locally) | "VirtioFS with custom dynamic caching," vendor performance claims not independently verified | 9p/virtiofs, no independently verified benchmark found | Lima's 9p/virtiofs mount | Lima's 9p/virtiofs mount | selective per-VM mounts, different model |
| File-watching / inotify across bind mounts | **FAIL, documented** — confirmed zero inotify events across a VirtioFS bind mount; polling (`--legacy-watch`) is the working mitigation ([parity.md #10-#11](parity.md), [sharing.md](sharing.md)) | works (Docker Desktop has shipped an FSEvents bridge for years) | claimed to work (vendor docs describe "low-latency, bidirectional file sharing"; not independently verified here) | not confirmed | not confirmed | not confirmed | per-VM mounts sidestep the cross-boundary watch problem differently; not confirmed either way |
| `host.docker.internal` | **implemented; live revalidation pending** — guest split DNS resolves both Docker host aliases to the VM NAT gateway, with the historical audit retained in [parity.md #18-#19](parity.md) until rerun | native, this is where the name comes from | supported (vendor docs) | supported | supported | not a default; needs manual host networking | not applicable, different networking model |
| Zero-config socket discovery | **implemented pending clean-profile revalidation** — the consented setup flow creates `~/.docker/run/docker.sock` only when safely absent and registers a `morbstack` context without overwriting a different explicit context ([first-run.md](first-run.md)) | native, installs and configures itself | supported (vendor docs) | requires `podman machine` context setup, broadly similar manual step | requires context/socket setup | requires manual `DOCKER_HOST` — Colima explicitly has no GUI or auto-config layer | different CLI, no Docker-socket concept |
| GUI | **native SwiftUI/AppKit operational app** — tables, inspectors, forms, standard toolbars, operations with explicit review, and no web view or custom dashboard design system ([product-audit.md](product-audit.md), [design decisions](design/DECISIONS.md)) | Electron, confirmed locally | native app (closed source, vendor claim, not independently verified) | Electron-family desktop app | Electron-based desktop app (third-party technical summaries; not independently re-verified here) | **none — CLI only** | CLI only, no bundled GUI |
| CLI | `morb` — start/stop/status/suspend/resume/shares/rosetta/doctor/k8s/reset-disk | `docker` (bundled) + Docker Desktop's own CLI surface | `orb`/`orbctl` (vendor docs) | `podman` | `rdctl` + bundled `nerdctl`/`docker` | `colima` + bundled `docker`/`nerdctl` | `container` |
| Telemetry | **none observed in the docs** — README states "no telemetry" as a project goal; not yet independently audited at scale | **on by default on the inspected copy** — the running process was launched with `--analytics-enabled=true` (local inspection, 2026-08-02) | none today; OrbStack's own privacy policy reserves the right to add "anonymous opt-out telemetry" in the future — [OrbStack privacy policy](https://docs.orbstack.dev/legal/privacy), accessed 2026-08-02 | present, described as anonymized, with an enterprise-managed opt-out (`locked.json`) — [Podman Desktop telemetry project](https://github.com/podman-desktop/telemetry), accessed 2026-08-02 | present, with an admin-configurable opt-in/opt-out setting — [Rancher telemetry FAQ](https://documentation.suse.com/cloudnative/rancher-manager/v2.10/en/faq/telemetry.html), accessed 2026-08-02 (note: this source is Rancher Manager's telemetry FAQ, not confirmed identical to Rancher *Desktop*'s own telemetry — treat as directionally indicative, not a Rancher-Desktop-specific citation) | could not verify | could not verify |
| Offline use | works — `mise run guest-image` and the boot path have no network dependency once assets are fetched; an offline `hello-world` load path is explicitly tested ([README.md](../README.md)) | requires periodic license/account checks above the free tier | requires periodic license check for Pro | fully offline-capable, no license server exists | fully offline-capable | fully offline-capable | fully offline-capable |
| Extensions / plugins | **not planned as Docker Desktop Extensions compatibility** — a native, non-web-view plugin SDK is a post-1.0 roadmap item, explicitly not a compatibility shim ([compat.md](compat.md), [roadmap.md](roadmap.md)) | native Extensions marketplace (web-view based) | no extension marketplace (vendor docs) | extension/plugin system exists (Podman Desktop's own architecture) | extension system exists, e.g. bundled Open WebUI/Ollama extension | none — CLI tool | none |
| GPU | **not supported, no commitment to add it** — explicit non-goal ([compat.md](compat.md)) | GPU support exists on some platforms (Windows/WSL primarily; not verified for this document's macOS focus) | not confirmed | not confirmed for macOS | GPU passthrough has documented gaps even on its best-supported platform (Windows/CUDA) — [Rancher Desktop GitHub issues](https://github.com/rancher-sandbox/rancher-desktop/issues/8487), accessed 2026-08-02 | `krunkit` VM type exists specifically for GPU-accelerated workloads on Apple silicon | not applicable |
| Windows containers | **never supported, explicit non-goal** ([compat.md](compat.md)) — Morbstack is Linux-containers-only by architecture | supported (Windows host only; not applicable to this macOS-focused document) | not applicable (macOS-only product) | not applicable on macOS | not applicable on macOS | not applicable on macOS | not applicable |

---

## 5. Performance: claims vs. measured reality

Kept in three explicitly separate buckets, because blurring them is the
single easiest way to lose a skeptical reader's trust.

### (a) Vendor claims — quoted and attributed, not verified by this document

- **OrbStack** states, on its own docker-desktop comparison page, that it
  has "fast startup," "low CPU usage," "low power usage," and "memory on
  demand" relative to Docker Desktop, presented as a checkmark comparison
  referencing external benchmarks rather than giving first-party numbers
  on that page itself — [OrbStack vs. Docker Desktop](https://docs.orbstack.dev/compare/docker-desktop),
  accessed 2026-08-02. Third-party writeups citing OrbStack-adjacent
  benchmarks report figures such as ~2s OrbStack startup vs. 20-30s for
  Docker Desktop, and roughly 200MB vs. 4GB idle memory — these are
  **third-party numbers, not this document's own measurements**, and this
  document did not attempt to reproduce them; treat them as claims, cited
  to where they were found, not as independently established facts (e.g.
  [sliplane.io's OrbStack vs. Docker comparison](https://sliplane.io/blog/orbstack-vs-docker),
  accessed 2026-08-02).
- **Apple's `container`** claims its per-container VMs achieve "sub-second
  startup times through careful kernel optimization," per third-party
  technical summaries of Apple's own materials — could not independently
  verify the underlying Apple source for this document.
- No performance claims from Podman Desktop, Rancher Desktop, or Colima
  were found stated as vendor marketing in this research pass; their
  documentation is comparatively feature/configuration-focused rather than
  benchmark-forward.

### (b) Morbstack's own measured numbers — with conditions, not marketing

All of the following are **real, timed, end-to-end runs on one development
machine, Apple silicon**, from `docs/architecture.md`, `docs/parity.md`,
`docs/amd64.md`, and `docs/k8s.md` — not the CI-gated `morb bench` numbers
`docs/roadmap.md` describes for M2+, and not reproduced independently for
this document:

- Cold, socket-activated `docker run --rm hello-world`: **2.09s wall
  clock**, guest MRB0 control socket ready 1.69-2.01s after VM bring-up
  ([architecture.md](architecture.md)).
- `morb stop`: 0.25-0.40s. A subsequent cold boot to a responsive `docker
  ps`: 1.69-1.73s, repeatable across multiple cycles with zero
  ERROR/WARN log lines ([architecture.md](architecture.md)).
- First-boot disk formatting (`mkfs.ext4`): 22ms; mount 56ms after that; a
  real `alpine` registry pull: 1.95s ([architecture.md](architecture.md)).
- Idle-auto-suspend cycle: guest powered off in 384ms after the idle timer
  fired; next socket-activated command woke a fresh VM in 2.13s. This is a
  **graceful stop, not a true suspend-to-zero snapshot/restore** —
  `Virtualization.framework`'s `restoreMachineStateFrom` does not work for
  Morbstack's direct-kernel-boot guest on this development host, a
  documented API limitation, not a Morbstack bug — see
  [architecture.md](architecture.md).
- amd64-via-Rosetta slowdown, measured directly, same guest and session
  ([amd64.md](amd64.md), corroborated by [parity.md #16](parity.md)):
  - No measurable container-*start* penalty (~0.3s either architecture
    once the image is warm).
  - General-purpose compute (pure-Python prime counting): **~1.8-2x
    slower** under Rosetta.
  - SHA-256 at 16KB blocks (`openssl speed sha256`): **2,214,112 KB/s
    native vs. 432,494 KB/s amd64 → ~5.1x slower.**
  - RSA-2048 sign: 1,643/s native vs. 435/s amd64 → **~3.8x slower**;
    verify: 64,156/s vs. 28,087/s → **~2.3x slower.**
- Kubernetes (`morb k8s`): cold enable-to-Ready **8.3s** with a full
  payload transfer (k3s 70MB in 0.6s, cri-dockerd 46MB in 0.3s, both over
  vsock at >100MB/s); ~4s on a subsequent enable with the payload already
  present. Idle cost with the cluster on and nothing deployed: guest
  memory rose from ~137MB to ~617MB, host VM-process CPU rose from ~0.7%
  to ~20-23% ([k8s.md](k8s.md)).

### (c) Morbstack's published targets — not yet measured, do not read as results

[`docs/roadmap.md`](roadmap.md)'s public performance target table commits
Morbstack to *publishing accurate status against these from M2 onward* via
`morb bench` — they are goals the project is answerable to, explicitly
**not** claims about the current build:

| Target | Goal |
|---|---|
| Cold boot | ≤ 2.0s |
| Resume (from suspend-to-zero) | ≤ 500ms |
| Idle host CPU | ≤ 0.1% |
| Idle wakeups | < 20/s |
| Host RSS (`morbstackd`, idle) | ≤ 120MB |
| Guest memory floor | ≤ 256MB |
| `git status` on a bind-mounted Linux tree, vs. native | ≤ 2x native |
| `npm install` on a bind-mounted project, vs. native | ≤ 1.5x native |

Note the overlap and the gap between (b) and (c): the *cold boot*
measurements in (b) (2.09s, 1.69-1.73s repeat boots) already land close to
the ≤2.0s *target* in (c) — but "resume ≤500ms" is a target with **no
real suspend-to-zero implementation to measure yet** (today's "resume" is a
graceful-stop-plus-cold-boot fallback, per (b) above), and idle
CPU/wakeups/RSS have no reported measurement at all in any doc as of this
writing. Treat the closeness of the boot numbers as encouraging, not as
evidence the harder targets (true suspend/resume, idle footprint) are
anywhere near proven.

---

## 6. Where Morbstack is worse — the honest section

This section is deliberately at least as detailed as §§2-5 combined are
flattering. Everything here is either a documented **FAIL**/**PARTIAL**
from [`docs/parity.md`](parity.md)'s real 29-check audit, an explicit
**not yet built** item from [`docs/roadmap.md`](roadmap.md), an explicit
**non-goal** from [`docs/compat.md`](compat.md), or a structural maturity
gap that is simply true of a one-maintainer, pre-alpha project regardless
of what its docs say.

### Things that are broken or absent today, not just "less polished"

- **The Docker host aliases need a fresh VM confirmation.** The guest now
  resolves `host.docker.internal` and `gateway.docker.internal` through a
  split-DNS service to the VM NAT gateway; this replaces the historical
  absence recorded in [parity.md #18-19](parity.md). The next parity pass
  must verify both DNS resolution and a real Mac-side connection before
  this comparison calls the feature a measured PASS.
- **No zero-config socket discovery.** A user must manually export
  `DOCKER_HOST` or run `docker context create`. Testcontainers, most IDE
  Docker integrations, and `docker-py`'s default client all try
  conventional socket paths first and will simply fail to find Morbstack
  out of the box ([parity.md #17](parity.md)).
- **Morbstack does not install a Docker client. Every product in this
  document does.** This is the single largest gap in the list and it is
  structural rather than cosmetic. Installing Docker Desktop, OrbStack,
  Podman Desktop or Rancher Desktop gives a user a working `docker` (or
  `podman`) command; installing Morbstack today gives them a daemon and a
  `morb` CLI and nothing to drive the engine with. Every demonstration of
  Morbstack to date has silently borrowed Docker Desktop's client — on the
  development machine, `/usr/local/bin/docker` is a symlink into
  `/Applications/Docker.app`. On a Mac that has never had Docker, nothing
  works. "Drop-in replacement" has to include the install path, and until
  the client toolchain is bundled and put on `PATH` by a consented
  first-run flow (tracked as the first gate on milestone L1 in
  [`docs/roadmap.md`](roadmap.md)), Morbstack is honestly an add-on to a
  Docker Desktop install rather than a replacement for one.
- **`docker build`/`docker buildx` does not work out of the box.** The
  modern default build path (BuildKit-by-default since Docker 23+) fails
  with a stock Docker CLI until a `docker-buildx` binary is in
  `~/.docker/cli-plugins/`. A pinned, hash-verified darwin/arm64 buildx is
  now fetched by `scripts/fetch-guest-assets.sh` into `dist/host-bin/`,
  but fetching is not installing: nothing places it where the Docker CLI's
  plugin resolver looks, so the user still does it by hand. The underlying
  engine-side BuildKit is fully functional once the client plugin exists,
  including multi-platform builds and cache mounts
  ([parity.md #13-14](parity.md)) — but "the engine works" is not the same
  claim as "buildx ships," and it does not ship yet.
- **Bare `/tmp` bind sources need a fresh VM confirmation.** When the
  `/private/tmp` VirtioFS share is live, the guest now aliases `/tmp` to it
  so the two source spellings select the same Mac files. If a custom config
  omits that share or it fails to mount, `morb doctor` warns that `/tmp`
  remains guest-local. The historical silent-mount failure is retained in
  [parity.md #9](parity.md) until a live rerun verifies the fix.
- **No inotify across VirtioFS bind mounts, confirmed directly.** A
  host-side file edit is correct the instant it's read, but the
  change-notification event a hot-reload watcher depends on
  (`nodemon`, `webpack --watch`, `vite`, `create-react-app`'s dev server)
  never crosses the boundary — confirmed with a live `nodemon` test that
  produced zero restarts after an 8-second wait. The working mitigation
  (`--legacy-watch`/polling) exists and was verified, but it is a
  workaround, not a fix ([parity.md #10-11](parity.md), [sharing.md](sharing.md)).
- **Fixed, non-negotiable bind-mount ownership.** Every file inside a
  VirtioFS bind mount shows up as `root:root` in the guest regardless of
  which host user owns it, and a container-side `chown` against it is
  silently accepted and silently discarded — `exit 0`, no change. Any
  workload that refuses to start unless a config file has a specific
  non-root owner will not work against a Morbstack bind mount today
  ([sharing.md](sharing.md)).
- **Published-port collision handling is intentionally narrow.** A conventional,
  fixed supported TCP `docker run -p <port>:...` now retains a real Mac listener
  before create, identifies it from a bounded standard create response, and hands it
  to forwarding before the exact `docker start` 204 reaches the client. That closes
  the host-port race for that exchange. Dynamic/ranged allocation, chunked or opaque
  create responses, name-based/nonstandard start handoff, VM-stop persistence, and
  UDP remain outside that synchronous **TCP lease** contract.
- **UDP forwarding is real but event-confirmed.** A framed datagram relay preserves
  per-client message boundaries and replies over loopback once Docker exposes a
  concrete port. Dynamic/ranged UDP does not claim a create/start reservation.
- **No qemu fallback for amd64**, despite the plumbing existing — no
  static `qemu-x86_64` ships, so anything Rosetta cannot translate simply
  fails with no fallback ([amd64.md](amd64.md)).
- **No `*.morb.local` DNS, no `morbnet`, no host-routable container IPs,
  no split-DNS.** Containers get outbound NAT and nothing else today
  ([README.md](../README.md)).
- **No synced-share filesystem tier.** VirtioFS (tier 1) is the only
  option; the opt-in synced-copy mode for workloads that don't suit
  VirtioFS's consistency/performance profile does not exist yet.

### Things competitors have that Morbstack has chosen never to build

Per [`docs/compat.md`](compat.md)'s explicit non-goals — stated up front so
readers don't mistake them for gaps that will eventually close:

- **Windows containers** — never supported, at any milestone. Not
  applicable to any of the macOS-only competitors in this document either,
  but Docker Desktop on Windows hosts does support this, and it is a real
  category some users need.
- **CUDA/GPU passthrough** — not supported, no commitment to add it.
  Colima has a `krunkit` VM type specifically for this; Docker Desktop has
  GPU support on some platforms.
- **Docker Desktop Extensions compatibility** — explicitly not a target.
  Docker Desktop, Podman Desktop, and Rancher Desktop all have some form of
  extension/plugin ecosystem today; Morbstack's native (non-web-view)
  plugin SDK is a post-1.0 idea, not a compatibility shim for anything that
  already exists.
- **CRIU (checkpoint/restore)** — off, not a target for 1.0 or the 1.x
  line as currently scoped.

### Maturity gaps that are just true, regardless of documentation quality

- **Pre-alpha, unreleased, no version number a user could install today.**
  Every other product in this document has a real release channel; a
  reader cannot `brew install morbstack` right now.
- **One maintainer.** Every open-source alternative here — Podman
  Desktop (Red Hat/CNCF), Rancher Desktop (SUSE), Colima (community, but
  long-running and widely depended-on), Apple's `container` (Apple) — has
  an organization or a sustained community behind it. Morbstack does not
  yet.
- **No independent security audit.** Explicitly a 1.0 gate per
  [`docs/roadmap.md`](roadmap.md), not done yet.
- **No notarized, signed release build; no installer.** Building from
  source with Xcode 26+ and a Rust cross-toolchain is the only way to run
  it today ([README.md](../README.md)).
- **Effectively zero user base outside this repository's own test passes.**
  No production usage, no bug reports from anyone who wasn't already
  working on the project, no evidence of behavior under load, concurrency,
  or adversarial input beyond what the parity pass covered.
- **VM suspend/resume is not actually implemented as suspend/resume.**
  `morb suspend` degrades to a graceful stop plus a cold boot on next use,
  because `Virtualization.framework`'s snapshot restore doesn't currently
  work for Morbstack's direct-kernel-boot guest on the development host it
  was tested on. The public "≤500ms resume" target in §5(c) has nothing
  behind it yet.
- **No public compat-matrix CI.** The Testcontainers/VS Code Dev
  Containers/JetBrains/kind/Tilt/Skaffold/act/Dagger matrix
  `docs/compat.md` describes is targeted for M2 and does not exist yet;
  everything in this document about Morbstack's ecosystem compatibility
  rests on one manual audit pass, not continuous verification.

Anyone reading this table and concluding "Morbstack is strictly better" has
not read it carefully enough — that conclusion isn't supported by the
project's own documentation, and this section exists so it doesn't need to
be argued with.

---

## 7. Who should use what

A recommendation section that doesn't send every reader to Morbstack is the
only kind worth writing.

- **Use Docker Desktop if:** you need Windows container support, GPU
  passthrough that's actually documented and supported, Docker Desktop
  Extensions, or you're inside an organization already paying for it and
  the $9-24/user/month is a non-issue. It is also, simply, the thing with
  the largest install base and the least chance of a workflow-specific
  surprise — real maturity is worth something `docs/parity.md`'s 19 PASSes
  can't yet buy Morbstack.
- **Use OrbStack if:** you're under the $10k/yr or personal-use threshold,
  want a closed-source but reportedly fast and well-integrated native
  experience today, and don't need the source to be inspectable or the
  product to be free at any company size.
- **Use Podman Desktop + podman machine if:** you specifically want a
  daemonless/rootless model, need Kubernetes-native tooling (`kind`,
  CRI-O-adjacent workflows), or your organization has policy reasons to
  avoid a Docker-Engine-shaped daemon at all — accepting that you're not
  running the actual Docker Engine, only something CLI-compatible with it.
- **Use Rancher Desktop if:** Kubernetes is the primary workload, not an
  afterthought, and you want first-class `containerd`/`nerdctl` alongside
  Moby with a choice between them.
- **Use Colima (+ Lima) if:** you don't want or need a GUI at all, you're
  comfortable at the command line, and you want the lightest possible free
  and open-source Docker-API-compatible VM with maximum backend
  flexibility (QEMU, `vz`, `krunkit`).
- **Use Apple's `container` if:** per-container VM-grade isolation matters
  more to you than Docker ecosystem compatibility, you're on macOS 26 with
  Apple silicon, and you're comfortable with a CLI that doesn't speak the
  Docker API and has no Compose story today.
- **Use Morbstack if:** you want a free-forever, Apache-2.0, source-visible
  Docker Desktop replacement built around an unmodified upstream Docker
  Engine — **and** you are comfortable being an early adopter of pre-alpha
  software with one maintainer, no security audit, unverified-newly-added
  Docker host aliases, missing zero-config discovery/buildx-out-of-the-box,
  and the inotify limitation documented in §6. If any of those gaps would
  break your actual workflow today, use one of the other six until
  Morbstack's roadmap closes them — that is exactly what
  `docs/roadmap.md`'s M1/M2 milestones exist to do, and this document will
  be updated as they land.

---

## 8. Sources

All accessed 2026-08-02 unless noted.

**Morbstack (this repository, git HEAD `ba9afc6`):**
- [`docs/parity.md`](parity.md) — the 29-check drop-in parity audit
- [`docs/roadmap.md`](roadmap.md) — milestones and the public performance target table
- [`docs/compat.md`](compat.md) — the compatibility contract and explicit non-goals
- [`docs/architecture.md`](architecture.md) — system design and VM-lifecycle measurements
- [`docs/amd64.md`](amd64.md) — Rosetta translation, measured slowdowns
- [`docs/k8s.md`](k8s.md) — `morb k8s`, measured enable/idle-cost numbers
- [`docs/sharing.md`](sharing.md) — VirtioFS bind mounts, ownership model, inotify gap
- [`README.md`](../README.md) — status, what works, what doesn't yet

**Local, first-hand inspection (this machine, read-only, 2026-08-02):**
`/Applications/Docker.app` via `du`, `codesign -dv --entitlements -`,
`otool -L`, `nm -g`, `ps aux`; `ls /Applications`, `which colima podman
nerdctl rdctl container`, `brew list --cask` for competitor presence.

**Docker Desktop / Docker Inc.:**
- [Docker Subscription Service Agreement](https://www.docker.com/legal/docker-subscription-service-agreement/) — free-use thresholds (§4.2)
- [Docker pricing](https://www.docker.com/pricing/) — plan prices
- [Docker Desktop release notes](https://docs.docker.com/desktop/release-notes/) — current version context (4.83.0, July 20 2026)

**OrbStack:**
- [Licensing](https://docs.orbstack.dev/licensing)
- [Architecture](https://docs.orbstack.dev/architecture)
- [Pricing](https://orbstack.dev/pricing)
- [Terms of Service](https://orbstack.dev/terms)
- [Privacy policy](https://docs.orbstack.dev/legal/privacy)
- [OrbStack vs. Docker Desktop](https://docs.orbstack.dev/compare/docker-desktop)
- Third-party benchmark summary (claims not independently reproduced): [sliplane.io — OrbStack vs Docker Desktop in 2026](https://sliplane.io/blog/orbstack-vs-docker)

**Podman / Podman Desktop:**
- [`podman-desktop` LICENSE](https://github.com/containers/podman-desktop/blob/main/LICENSE)
- [Podman machine providers (DeepWiki summary of upstream docs)](https://deepwiki.com/containers/podman/13.1-machine-providers-and-vm-configuration)
- [Podman Desktop — Rosetta support](https://podman-desktop.io/docs/podman/rosetta)
- [`podman-desktop/telemetry`](https://github.com/podman-desktop/telemetry)

**Rancher Desktop:**
- [Rancher Desktop LICENSE](https://github.com/rancher-sandbox/rancher-desktop/blob/main/LICENSE)
- [Rancher Desktop docs](https://docs.rancherdesktop.io/)
- [GPU/CUDA limitation discussion](https://github.com/rancher-sandbox/rancher-desktop/issues/8487)
- [Rancher (Manager) telemetry FAQ](https://documentation.suse.com/cloudnative/rancher-manager/v2.10/en/faq/telemetry.html) — cited with the caveat in §4 that this concerns Rancher Manager, not confirmed identical to Rancher Desktop's own telemetry implementation

**Colima / Lima:**
- [`abiosoft/colima`](https://github.com/abiosoft/colima)
- [Colima FAQ](https://colima.run/docs/faq/)

**Apple `container`:**
- [`apple/container`](https://github.com/apple/container)
- [`apple/container` technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md)
