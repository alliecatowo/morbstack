# Capability gap — Docker Desktop / OrbStack vs Morbstack

**Written 2026-08-05.** Companion to [UI-FEATURE-GAP.md](UI-FEATURE-GAP.md), which is about
**screens**, and to [PERFORMANCE-MODEL.md](PERFORMANCE-MODEL.md) (2026-08-07), which is about
**mechanism** — it supplies the engineering explanation behind §1, §5, §6 and §7 below, and
several of the "we have not measured it" statements here have moved since. This file is about
**capabilities** — the things that make somebody switch, or refuse
to, whether or not any of it is visible in a window. Competitor claims were fetched from vendor
docs, release notes and issue trackers on 2026-08-05; "our side" is read from source on
`swarm/cleanup` and every claim carries a file path. Engine-level *checklist* tracking stays in
[../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md); strategy narrative stays in
[DIFFERENTIATION.md](DIFFERENTIATION.md). This is the delta and the verdicts.

Evidence labels match the companion docs: **VERIFIED** (fetched from the vendor's own docs,
changelog or tracker), **REPORTED** (secondary), **INFERRED**. Where a competitor's docs are silent
that is recorded as silence, not filled in from memory.

**The standard**, unchanged: *"set the bar as if they can do it we can do it better for free and
without as much overhead and cruft."* Verdicts: **build** · **build differently** · **in flight** ·
**defend** (we lead; do not regress) · **decide** (a written ruling is the deliverable) ·
**skip** (deliberate, with reasons).

**Two facts that shape everything below.** OrbStack shipped **v2.2.2 on 2026-08-02** and Docker
Desktop shipped **4.85.0 on 2026-08-03** (both VERIFIED). Both are moving weekly. Any sweep of this
kind is a photograph, and the dates on it matter more than its confidence.

---

## 1. Bind-mount and filesystem performance — verdict: **defend the mechanism, build the proof**

**Docker.** VirtioFS has been the macOS default since 4.23; legacy osxfs was *removed* in 4.80.0
(2026-06-29) and its remaining users force-migrated (VERIFIED). Their claim is "up to 98%" reduction
in filesystem operation time (VERIFIED, settings doc). The faster path — **Synchronized file shares**,
an ext4 cache of host files inside the VM — is **Pro-tier and up** (VERIFIED, pricing page), capped
at roughly **2 million files per share**, and explicitly **not used by Kubernetes `hostPath` volumes**
(VERIFIED). And `docker/for-mac` **#77, "File access in mounted volumes extremely slow", is still
open**: filed 2016-08-02, 375 👍, 212 comments, `lifecycle/frozen`, last touched 2018 (VERIFIED via
the GitHub API, 2026-08-05). Ten years. Correctness bugs are current too — #7687 (2025) has
`renameat2 RENAME_EXCHANGE` on an AVF VirtioFS bind mount *losing data*, and 4.85.0 last week
shipped a "Linux VM kernel panic fix for file watcher issues on bind mounts" (both VERIFIED).

**OrbStack.** Also VirtioFS — "a modern base (VirtioFS) with custom dynamic caching and
optimizations" (VERIFIED, architecture page). Their own file-sharing doc concedes "there is still an
inherent cost associated with going through macOS for file access" and recommends named volumes over
bind mounts (VERIFIED). Their benchmarks page is **from August 2023, v0.17.0**, its figures live in
chart images, and it contains **no bind-mount throughput number at all** (VERIFIED). File watching
has been fixed, regressed and re-fixed: #1931 and #2033 closed in v2.0, then **#2561 "Host
file-change events on bind mounts are not delivered to in-container watchers" closed in v2.2.2 on
2026-08-03** — three days ago (VERIFIED).

**Us.** `mac/Sources/MorbstackKit/DirectoryShares.swift` mounts each host root at *the same absolute
path inside the guest*, which is why `-v /Users/me/app:/app` needs no translation anywhere in the
stack — the comment at the top of that file is the whole trick. Defaults are `/Users`, `/Volumes`,
`/private/tmp` (`MorbShares.defaultSharedPaths`), planned as a pure function so the daemon, `morb
doctor` and the tests all read one plan. Measured 1.1 GB/s write (COMPETITIVE-GAPS row 1).
File-watch propagation is the live-share bridge (`MorbstackKit/MorbLiveShareBridge.swift` +
`guest/morbinit/src/live_share.rs`), whose mechanism is a same-mode `fchmod(2)` emitting `IN_ATTRIB`
only — enough for chokidar/nodemon/vite/watchdog, filtered out by Go's `air`.

**Does it matter.** It is the single most-complained-about thing in this market, by an order of
magnitude, and it has been for a decade.

**Verdict: defend the mechanism, build the proof.** We are on the same VirtioFS both of them are on;
we are not going to out-engineer two funded teams on the transport. What we can do that neither
structurally can is **publish a runnable harness**. `MorbBench` already measures cold boot, idle CPU,
wakeups and RSS honestly (`mac/Sources/MorbBench/Benchmarks/`), and is **missing the two workloads
people actually compare**: `git status` over a bind mount, and `npm install` bind-mount vs named
volume. Docker publishes a percentage with no method; OrbStack publishes charts from a three-year-old
version. "Here is the harness, run it on your Mac against all three" is a claim a closed competitor
cannot answer. → **UX-14**

The file-watch story needs the same treatment and is worse today: our bridge covers `IN_ATTRIB`
consumers and we have never published *which watchers pass*. OrbStack regressed this feature twice in
a year; a matrix is both a defensive record and a marketing asset. → folds into **UX-14**.

## 2. Container domains and per-container DNS — verdict: **in flight (DIF-4), and our mechanism is better than theirs**

**OrbStack.** `<container>.orb.local`, `<service>.<project>.orb.local`, `*.k8s.orb.local`, custom
domains via a `dev.orbstack.domains` label, **wildcards by default** (`*.container.orb.local`
resolves), HTTP port auto-detected by probing with a `OrbStack-Server-Detection` user agent, override
by label (all VERIFIED). HTTPS is zero-config: a local CA whose **root private key is stored
encrypted in the macOS Keychain, gated by OrbStack's code signature**, auto-injected into containers
so container-to-container HTTPS verifies (VERIFIED). Admin is *not* required for any of it (VERIFIED,
FAQ) — admin is asked for only to install CLI tools and the `/var/run/docker.sock` symlink.

**The one thing their docs never say is how the Mac resolves `*.orb.local`.** The architecture page
describes only the guest→host direction. Their tracker suggests the answer indirectly: **#2274**
(open, 2025-12-16) reports a Korean ISP's DNS answering `*.local` queries and hijacking `orb.local`
resolution — behaviour consistent with an mDNS-style path rather than an `/etc/resolver` override,
which would normally win (INFERRED, flagged as inference in the source research).

**Us.** Not shipped, but **decided, and decided better**. SP-2 (`decided`) rejected `NEDNSSettings`
— its `dnsSettings` accepts only DoH/DoT, so it would need a trusted TLS certificate *before* DNS
works, and the user must activate the resulting network service behind the admin padlock — and
rejected `NEDNSProxyProvider` harder still, because Developer ID requires a user-approved
`dns-proxy-systemextension` that then sees every DNS query on the Mac. The chosen mechanism is
per-container mDNS proxy `A` records from the ordinary unprivileged daemon
(`DNSServiceRegisterRecord`, `LocalOnly`), **verified on macOS 26.4: no entitlement, no password, no
dialog, no `/etc/resolver` write, nothing to uninstall, ~1 ms resolution**
([../design/DNS-DECISION.md](../design/DNS-DECISION.md)). SP-3 settled the suffix at `morb.local` and
**accepted knowingly that there are no wildcard subdomains** — and cited orbstack#2274 while doing
it. The validator ships (`MorbstackKit/MorbLocalDomain.swift`); the registrar does not, and there is
no `morb domain` subcommand in `mac/Sources/morb/main.swift`. DIF-4 is `open`, ~3–4 weeks, six steps
with a hard gate at step 0.

**Does it matter.** Yes — it is OrbStack's headline and the thing people name when they say why they
switched.

**Verdict: in flight, and two notes for whoever builds it.** First, **no wildcards** is a real
functional gap against them and it should be stated in the UI, not discovered. Second, their
`OrbStack-Server-Detection` port probe is a good idea worth copying: guessing the listening port from
`EXPOSE` is worse than asking. Both belong in DIF-4's spec, not in a new ticket.

## 3. Routable container IPs, and `--network host` — verdict: **build differently, and say what we do instead**

**Docker.** States plainly in its own docs: *"You cannot see a `docker0` interface on the host"* and
*"Docker Desktop can't route traffic to Linux containers"* (VERIFIED). Host networking on macOS
arrived in 4.34, is **opt-in, requires being signed in to a Docker account**, is **layer 4 only**,
containers cannot bind host IPs, and it is **incompatible with Enhanced Container Isolation**
(VERIFIED). macvlan does not work on macOS at all (#3926, open since 2019).

**OrbStack.** Containers are reachable from macOS **by IP with no port forwarding**, IPs are shown in
the GUI, ICMP/ping/traceroute work, and `--net host` works natively across the full 1–65535 range
bidirectionally (VERIFIED). They call this out as unique among macOS Docker providers, and on the
evidence they are right.

**Us.** Absent. `--network host` shares the *Linux VM's* namespace and never macOS's, and we
deliberately create no Mac listener for host-network containers so a started container never implies
a fabricated Mac mapping (`docs/parity.md` #20). Container→host works through the guest gateway
(`192.168.64.1`) and `host.docker.internal` is implemented in the guest DNS path
(`docs/parity.md:23`). Host→container by IP: nothing.

**Does it matter.** More than the gap list credits. Routable IPs are the feature that makes port
publishing *optional* — no `-p`, no port collisions, no "which of my six Postgres containers owns
5432". It is also the substrate DIF-4's domains need anyway: an `A` record has to point somewhere,
and SP-2 already settled that it points at the **guest's** `192.168.64.x`.

**Verdict: build differently — it is DIF-4's step 0, not a separate feature.** DIF-4 already carries
"prove host→guest reachability at `192.168.64.x` on Wi-Fi/Ethernet/VPN" as a **hard gate** with a
documented fallback. That gate *is* routable-container-IP work; what it lacks is a user-visible
payoff of its own. When it passes, show the container's guest-reachable address in the inspector and
in `morb status --json` even before domains land. Half a day on top of work that must happen anyway,
and it converts an internal milestone into a shipped capability. → **UX-15**

We should also stop under-selling the honest half: Docker gates host networking behind a **login**
for a purely local capability. That belongs in the comparison copy.

## 4. Disk space that never comes back — verdict: **build; this is the highest-ranked item in this document**

**Docker.** Space is freed **only when images are deleted**, never automatically when files are
deleted inside containers; the manual escape hatch is
`docker run --privileged --pid=host docker/desktop-reclaim-space`; and **reducing the max disk-image
size deletes the disk image, losing every container and image** — documented behaviour, not a bug
(all VERIFIED, Mac FAQ).

**OrbStack.** `data.img` is a sparse file that appears as ~8 TB and, per their FAQ, "automatically
shrinks when data is deleted" (VERIFIED). Their tracker is less confident: **#2030 "OrbStack doesn't
reclaim disk space" is open** (2025-07-04), and there is **no documented `orb` command to compact or
TRIM the image** (VERIFIED as absence).

**Us. Worse than both, and our own docs disagree about it.** The design intent is right —
`guest/morbinit/src/disk.rs:273` mounts btrfs with `compress=zstd:1,discard=async`, whose entire
point is letting the sparse host image shrink. But the kata 6.18.15 kernel we ship **has no btrfs
driver** (empirical, `mount` fails `ENODEV`; `docs/architecture.md:183`), so every shipped install
falls to the ext4 path, which mounts with kernel defaults: **no `discard`, and there is no `fstrim`
anywhere in the tree**. `MorbDiskGrowth.swift` and `MorbDiskResize.swift` are **grow-only** by
design, correctly — never truncate live data. The net effect is that `~/.morbstack/data/disk.img`
grows monotonically and **never returns a byte to macOS**. [TECHNOLOGY-AUDIT.md](TECHNOLOGY-AUDIT.md)
Bet 8 states this precisely and files **TECH-3**; [DIFFERENTIATION.md](DIFFERENTIATION.md) Tier B
says the opposite ("`discard=async` is already on the guest mount… more plumbing than research").
TECHNOLOGY-AUDIT is right and DIFFERENTIATION is stale — see §16.

**Does it matter.** It is the incumbent's most-complained-about *behaviour* after bind-mount speed,
it is invisible until the day it is a crisis, and we currently reproduce it in a product whose pitch
is being better.

**Verdict: build, and run the experiment first.** TECH-3 is one afternoon: does
Virtualization.framework's virtio-blk translate a guest `discard` into hole-punching on the raw file?
Apple does not document it either way. If yes, `-o discard` or a periodic `fstrim` on ext4 reclaims
space with **zero new architecture** and we ship the one thing in this market that gives disk back.
If no, reclamation needs the heavier compact-by-copy path and the kernel fork moves up the list.
Either way the answer is cheap and everything downstream depends on it. → **UX-16** (the
user-visible half; TECH-3 stays the experiment).

## 5. Memory returned to the host — verdict: **build (small), currently a silent gap**

**Docker.** #6120, "Docker process doesn't free up memory — macOS, Apple Silicon,
Virtualization.framework", open since 2022-01-03, 159 👍, 117 comments; recent notes claim
improvement ("improved Linux VM memory return to host") (VERIFIED). Default memory allocation is
**50% of host RAM** (VERIFIED).

**OrbStack.** "Fully dynamic memory allocation", "automatically returned to macOS", 8 GB cap by
default (VERIFIED, settings + comparison pages). Their tracker confirms the mechanism is ballooning —
**#2558, "LAN port-forwarding stalls during VM memory balloon deflation"** (open, 2026-06-22) — and
also carries **#2251 "high memory with no running containers"** (open). So: real, and imperfect.

**Us.** `mac/Sources/MorbstackKit/VMManager.swift:2136` attaches a
`VZVirtioTraditionalMemoryBalloonDeviceConfiguration` — and **nothing in `mac/Sources` ever sets
`targetVirtualMachineMemorySize`**. The device is present and undriven. Default allocation is a flat
8192 MiB (`MorbConfig.swift:92`), which is more considerate than Docker's 50%-of-host and less
adaptive than OrbStack's dynamic pool.

**Does it matter.** Moderately, and the mitigation we already have is strong: auto-suspend at 5
minutes idle (`MorbConfig.swift:98`) stops the guest entirely, which returns *all* of it. That is a
better answer than shaving pages while running. What it does not cover is the developer whose engine
is busy all day.

**Verdict: build small.** Driving the balloon toward the guest's actual working set on a slow timer
is a contained change in one file, and it closes the one case auto-suspend cannot. Rank it below
everything in §1–4. Do **not** promise "dynamic memory" in copy until it is measured — OrbStack's own
tracker shows what that claim costs when it slips. → **UX-17**

## 6. Startup, idle cost and suspend — verdict: **defend, and nobody can see it**

**Docker.** Publishes **no macOS startup-time figure at all** (VERIFIED as absence — the only 2026
startup entry in the release notes is Windows/WSL). Resource Saver stops the idle VM, is on by
default, idle timeout **5 minutes** (min 30 s, `autoPauseTimeoutSeconds`), claims "2 GB or more"
saved, and costs **3–10 seconds to resume** (all VERIFIED). 4.79.0 in June 2026 fixed "spurious 500
errors after VM idle shutdown" — the resume path was returning errors to the API two months ago.

**OrbStack.** "Starts in 2 seconds", "around 0.1% CPU when idle, often dropping to 0%", "a fresh
install uses less than 10 MB of disk" (all VERIFIED, their features/efficiency pages). Their one
head-to-head number is a provisioning comparison, 17 min vs 45 min.

**Us. We win this on measured numbers and no user will ever know.**
[ENGINE-MATRIX.md](ENGINE-MATRIX.md) §10: **1.79 s cold boot to a first successful Docker API call**
— not to "VM running", to a *served request* — and **0.0% idle CPU, 23 MB host RSS** after 20 s
quiescence. Auto-suspend defaults to 5 minutes, matching Docker's Resource Saver, with running
containers inhibiting suspend. Suspend-to-disk is fail-closed: `VMManager.swift:215-273` records a
host on which `saveMachineStateTo` succeeded and `restoreMachineStateFrom` then refused, and
permanently degrades that host to stop-and-cold-boot rather than writing a 150 MB state blob it knows
cannot be restored. That is a more honest posture than either competitor documents.

**Does it matter.** Yes, and it is our cheapest credibility win, because it is the one axis where we
have a *measured* number and Docker has none.

**Verdict: defend, and surface it.** The number exists in an audit document nobody outside this repo
will read. `morb bench` should be runnable in one command against a stock install, its output
copy-pasteable, and the cold-boot figure should appear in the README's first screenful next to the
harness that produces it. This is not a feature build; it is publishing something we already have.
→ folds into **UX-14**.

## 7. Rosetta and x86-64 — verdict: **defend, with one honest caveat**

**Docker.** Rosetta is **off by default** and **only available under Apple Virtualization framework**
(VERIFIED). Their own container-optimised hypervisor, **Docker VMM — the one with the "25x warm
cache" claim — does not support Rosetta at all**, breaks MongoDB/Cassandra on virtiofs, and has been
**Beta since 4.35 in October 2024**, roughly 22 months, and is still not the default (all VERIFIED).

**OrbStack.** Rosetta on by default, "much faster than the commonly-used QEMU", "near-native
performance" — **no multiplier published anywhere** (VERIFIED as absence). AVX emulation landed
v2.0.2. The tracker shows a steady drip of syscall-level breakage concentrated in Nix, tar/glibc
builds and Go/Mongo runtimes: #2606, #2600, #2588 all **open** as of July 2026 (VERIFIED).

**Us.** `MorbstackKit/Rosetta.swift` owns availability and installation; the guest registers the
interpreter via `binfmt_misc` (`guest/morbinit/src/binfmt.rs`) with the `F` flag so
`/run/rosetta/rosetta` need not exist inside container images. **On by default**
(`MorbConfig.swift:96`, `rosetta: Bool = true`). Measured, not claimed: amd64-only `mysql:5.7` boots,
digests bit-identical to host, ~1.0× container start, **1.5–1.7× compute** (`docs/amd64.md`).

**Does it matter.** Yes, and we are already in the best position of the three: on by default like
OrbStack, with a *published multiplier* neither of them offers, on the backend Docker's own faster
hypervisor cannot use.

**Verdict: defend.** The honest caveat to keep writing down: no 32-bit x86, historically no AVX-class
sets inside Linux VMs, JIT-heavy workloads carry the worst multipliers, and the documented qemu-user
fallback **does not ship** (`docs/architecture.md` lists it; nothing implements it). That last one is
a truthfulness item, not a build item — either implement it or stop listing it.

## 8. Proxies, corporate networks and custom CAs — verdict: **build; this is the one hard blocker we have zero of**

**Docker.** Two independent proxies (Desktop's own, and a Containers proxy that is **always enforced**
for pulls); system/manual/PAC modes; bypass lists; Basic auth cached in the OS credential store.
**SOCKS5 requires Business. Kerberos/NTLM requires Business** plus an installer flag (all VERIFIED).

**OrbStack.** Containers and machines **inherit macOS's HTTP/HTTPS/SOCKS proxy settings
automatically**, SOCKS takes precedence, and `orb config set network_proxy` accepts `auto`, `none`,
or a URL. v2.2.0 fixed no-proxy exclusions **and corporate intermediate certificate trust**; v2.1.0
added per-host bypass. "Fully compatible with VPNs, including advanced DNS resolver settings" (all
VERIFIED). Two open tracker items temper it (#2334 VPN DNS names, #2144 internet blocked).

**Us. Nothing.** A repo-wide grep for `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `socks` across
`guest/morbinit/src`, `mac/Sources/MorbstackKit` and `mac/Sources/morb` returns **zero hits**. There
is no proxy configuration, no inheritance of macOS system proxy settings, and no path for a corporate
intermediate CA into the guest's trust store. On a laptop behind a corporate MITM proxy, `docker pull`
fails and Morbstack has nothing to say about why.

**Does it matter.** This is the difference between "a tool I can use at work" and "a tool I use at
home". It is not glamorous and it is not on anyone's feature comparison, and it silently disqualifies
an entire population of users. It is also the one place in this document where **OrbStack's free tier
beats us on a capability we could ship in days**: inheriting the system proxy is a read of
`SystemConfiguration`'s dynamic store and a handful of environment variables handed to dockerd in
`guest/morbinit/src/supervisor.rs`, which already builds that environment (it is where
`DOCKER_MIN_API_VERSION=1.24` is set, line 192).

**Verdict: build, and make the default the good one.** Inherit macOS's configured proxy by default
(the way OrbStack does), with an explicit `config.toml` override and an explicit off switch; add a
`morb doctor` check that says "a system proxy is configured and containers are using it" or "…and
containers are **not**". Corporate CA injection into the guest trust store is a second, larger
commit with its own trust story and should not block the first. **Neither costs an account, and
Docker charges Business money for the SOCKS5 half of it.** → **UX-18**

## 9. SSH agent forwarding — verdict: **build (small)**

**Docker.** Documented and supported on macOS: bind-mount `/run/host-services/ssh-auth.sock` and set
`SSH_AUTH_SOCK` to it (VERIFIED). Open bug #7204 says it stopped working (2024-02-28, still open).

**OrbStack.** Agent forwarding to Linux machines, with a doc/changelog contradiction worth knowing
about: the SSH page says it happens by default, the v2.1.2 changelog (2026-05-09) lists "SSH agent
forwarding opt-in" (both VERIFIED — the page appears stale).

**Us.** No `SSH_AUTH_SOCK` handling anywhere in `mac/Sources` or `guest/morbinit/src`. **But the
build-time half already works and nobody has said so**: `docker buildx build --ssh default` forwards
the agent over BuildKit's gRPC session rather than a bind mount, and
`MorbstackKit/DockerRequestFraming.swift`'s hijack detection nominates any request carrying an
`Upgrade` header, so the session upgrade passes through the relay untouched
(`DockerHijackDetection.isHijackCandidate`). That is the case most people mean by "SSH agent" —
`RUN --mount=type=ssh` cloning a private repo in a build.

**Does it matter.** The build case matters a lot and is probably already fine. The runtime case
(a container that needs to `git push`) matters less and is one bind mount away.

**Verdict: build small, and verify the free half first.** Commit one is a `parity-tester` run proving
`docker buildx build --ssh default` against a private repo works end to end, and a line in
`docs/parity.md` recording it. Commit two provides the Docker-compatible runtime path so that copied
`compose.yaml` files with `/run/host-services/ssh-auth.sock` in them do not simply fail.
→ **UX-19**

## 10. Credential helpers — verdict: **defend**

**Docker.** Bundles and pre-configures `docker-credential-osxkeychain` (VERIFIED). Notably, **4.84.0
on 2026-07-27 shipped "Fixed invalid config.json hanging Docker Desktop with high CPU usage"**
(VERIFIED) — the exact failure class this repo has warned about in CLAUDE.md §1.2 since long before
Docker fixed it. **OrbStack** uses the macOS keychain via `osxkeychain` too, "differing from Docker
Desktop's approach", and shipped keychain-login fixes in both v2.2.0 and v2.2.2 (VERIFIED).

**Us.** We ship **no credential store and hold no credential**, and
`MorbstackKit/MorbDockerContext.swift` goes to considerable trouble to *preserve* the user's existing
`credsStore`, `credHelpers` and `auths` — along with the file's mode bits and symlink identity —
when it writes `currentContext`. `Doctor.swift` reports a `docker-credentials` check either way.

**Does it matter.** Only when it breaks, which is exactly when it matters most: both competitors
shipped credential-storage bug fixes in the last two months and we cannot ship that class of bug
because we do not have that code.

**Verdict: defend.** This is product identity and it is already correct. The only action is to keep
saying it: authentication is the `docker` CLI's job, using the user's own helper, and no Morbstack
GUI will ever hold a credential. (The UX-5 resolution in [UI-FEATURE-GAP.md](UI-FEATURE-GAP.md) §3
restates the same boundary for registry browsing.)

## 11. Kubernetes — verdict: **defend, and press**

**Docker.** Since 4.65.0 (2026-03-16) **kind is the default provisioner** for new clusters (VERIFIED).
kind gives multi-node and a version selector; kubeadm gives neither. Context is `docker-desktop`.
Their docs **do not state** whether locally built images are visible to a kind-provisioned cluster
without `kind load` (VERIFIED as absence — a real question, unanswered by the vendor).

**OrbStack.** Single node only — their docs send you to kind/k3d/k3s/minikube for multi-node — no
pre-installed Ingress controller, Flannel only, and **no Kubernetes version selection** (all
VERIFIED). What they do well: **no registry push required**, "built images are immediately available
for use in Pods", plus `cluster.local` resolvable from macOS and `*.k8s.orb.local` for
LoadBalancer/Ingress. Version tracks the release (1.35 in v2.2.2). #1858 (PersistentVolumes not
deleted) has been open since March 2025.

**Us.** k3s + cri-dockerd, which means the cluster's runtime **is** the Docker engine — the same
"built images are immediately runnable" property OrbStack advertises, arrived at structurally rather
than as a feature. `guest/morbinit/src/k8s.rs:430-443` disables traefik (the single biggest
contributor to time-to-ready), metrics-server and the helm controller, and **deliberately keeps
servicelb** with a test that says why: klipper-lb is what turns a `LoadBalancer` Service into a node
hostPort and thence into a Mac-side listener through machinery we already have
(`K8sRuntime.swift:107`). On the UI side we are simply deeper than they are:
`Views/Kubernetes/KubernetesRootView.swift` is 1,401 lines of pods/nodes/events tables with sort and
detail, `K8sResourceReader.swift` describes pods and nodes, and `K8sPortForward.swift` does real port
forwarding. OrbStack has no comparable screens (VERIFIED as absence in the UI research).

**Does it matter.** For the subset of developers who use local Kubernetes, enormously; for everyone
else, not at all. That subset is not small and is badly served by both incumbents.

**Verdict: defend, and press on exactly two axes.**
1. **Say the image-store thing out loud.** "No registry, no `kind load`, no push — `docker build` and
   the Pod runs it" is OrbStack's advertised advantage over Docker's kind default, and it is true of
   us for free. It appears nowhere a user can see.
2. **`kubectl top` does not work** because metrics-server is disabled for boot speed. That is a
   defensible trade, but it should be an honest, discoverable message rather than a confusing error —
   and our own Kubernetes route already renders resource data it could offer instead. → **UX-20**

Do not chase multi-node. Docker gets it free from kind and OrbStack refuses it; a single-node cluster
that starts fast and shares the image store is the right product.

## 12. Dev Containers, Testcontainers, IDEs and CI — verdict: **defend loudly; our own docs undersell us badly**

**Docker.** **Dev Environments was deprecated and removed in 4.42+**, and the replacement Docker
points to is plain Compose — **not** Dev Containers (VERIFIED). Testcontainers *libraries* are free
OSS; **Testcontainers Cloud** is metered by tier (Pro 100 min/mo, Team 500, Business 1,500)
(VERIFIED). Docker Debug — shell into any container including distroless — **requires Pro, Team or
Business** (VERIFIED).

**OrbStack.** Testcontainers is **not documented by the vendor at all** (VERIFIED as absence); the
community recipe is `DOCKER_HOST` plus `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`
(REPORTED), and **orbstack#2035, "Docker Compose (Java) TestContainers fail to work with OrbStack",
has been open since 2025-07-10** (VERIFIED). Dev Containers gets one sentence saying the VS Code
extension "should be compatible". For CI they publish a `/headless` page — undercut by **#1767**:
OrbStack "cannot run as root — it requires a user context", so a `LaunchDaemon` on a headless Mac
does not work (VERIFIED, closed with no maintainer answer).

**Us. This is our strongest position in the entire document and three of our own docs still call it
`absent`.**
- **Testcontainers, four languages, real Postgres round trips, Ryuk enabled, zero environment
  variables**: Node 12.1.0, Go v0.43.0, Java 1.21.4 and Python 4.15.0 all green against server
  29.7.1 after ECO-1/ECO-2 ([ECOSYSTEM-MATRIX.md](ECOSYSTEM-MATRIX.md) zero-config rerun;
  design in [../design/ZERO-CONFIG-DISCOVERY.md](../design/ZERO-CONFIG-DISCOVERY.md)).
  `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` is **no longer required in any language**, because
  `DockerBindMountPreflight` rewrites a bind of the daemon's own socket — matched by exact,
  symlink-resolved path identity, never by pattern — to the guest's `/var/run/docker.sock`.
- **Dev Containers CLI 0.88.0 passes zero-config** (context-only, no `DOCKER_HOST`), including exec,
  a two-way workspace bind mount, and a features/derived-image build (ECOSYSTEM-MATRIX).
- **A VS Code extension exists and is built**: `integrations/vscode/` ships a `.vsix`, with containers
  grouped by `com.docker.compose.project`, clickable published ports, logs demultiplexed out of
  stdcopy framing, a read-only Kubernetes view, an engine status bar that warns when a published port
  could not be bound on the Mac, and **an interactive shell over the Engine API's exec endpoints on a
  hijacked stream, resize included — it does not shell out to `docker exec`, so it works with no
  `docker` CLI installed and no `DOCKER_HOST` set**.
- **JetBrains** is a researched verdict, not a gap: `integrations/jetbrains/README.md` concludes no
  plugin is needed (Unix-socket connection type, fully expanded path), with a feature matrix and an
  honest note that no IDE was installed on the machine that wrote it.
- **Shell completions and a man page** ship in `integrations/shell/`; `integrations/env/morbstack-env.sh`
  covers the `DOCKER_HOST`-only tools (Tilt, Skaffold, the Go SDK, `act`, GitLab Runner) that will
  never read a context.
- **Old clients work against engine 29.** `guest/morbinit/src/supervisor.rs:192` sets
  `DOCKER_MIN_API_VERSION=1.24` (upstream's own floor), so the `GET /v1.32/info` probe that
  `testcontainers-java` ≤1.20.x uses for discovery returns 200 instead of 400. Docker Desktop is
  currently insulated only because it still ships engine 29.6.2 with its default floor; **we are the
  engine-29 distribution that installed base actually works against.**

**Does it matter.** This is *the* switching decision for anyone with a test suite, and it is the axis
where "no account" turns into an actual capability rather than a principle: Testcontainers Cloud
minutes and Docker Debug are metered, and we have neither meter.

**Verdict: defend loudly, and fix the paperwork.** No new capability is needed. What is needed is
that [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) stop saying Testcontainers and Dev Containers
were "never tested" and that VS Code/JetBrains integration is `absent` — see §16. → **UX-21** is the
correction pass, not a build.

## 13. Linux machines — verdict: **decide (DIF-13), and the case for "no" got stronger**

**OrbStack.** 16 distros, version pinning, per-machine CPU/memory/disk limits (v2.2.0), `/mnt/mac`
sharing both ways, `ssh <machine>@orb` on localhost:32222 with an auto-managed ED25519 key,
cloud-init, `orb clone` as copy-on-write, `orb export/import`, and **isolated machines** explicitly
pitched for AI-agent sandboxing with docs that say plainly they are "not full security boundaries"
because all machines share one kernel (all VERIFIED). **You cannot bring your own image** — "support
for custom distros and images is planned" — and there is **no importer from Lima, Colima, multipass
or Vagrant** (VERIFIED).

**Us.** Spec only. SP-5 deleted 1,601 lines of `MachineRegistry`/`MachineImageAdmission` validation
that had zero callers and, by design, no success path; `docs/machines.md` opens by saying so, and the
code is recoverable at `3157c39`. There is no `morb machine` in `mac/Sources/morb/main.swift`.

**Does it matter.** It is a second product: image provenance, disk lifecycle, cloud-init, key
management, and a per-machine agent, all with their own security surface. Apple's `container machine`
now occupies the adjacent ground.

**Verdict: decide, and the honest recommendation is "not yet, and say so".** Two things changed since
DIF-13 was written and both argue against entering. First, **OrbStack itself has not finished it** —
no custom images, no importer from the tools people actually have. Second, their isolated-machine
pitch is aimed at AI-agent sandboxing, and their own docs disclaim the security property that use
case needs. Competing there means either matching a disclaimer or building a real boundary, and only
one of those is worth a quarter. Keep `docs/machines.md` as the spec, leave DIF-13 `open (decision
required)`, and put the sentence "Morbstack does not manage Linux VMs; it runs containers" somewhere
a prospective user reads it. Absence is only a feature if it is stated.

## 14. Migration in, and out — verdict: **build the way out**

**Docker.** Nothing to migrate *to* — it is the incumbent.

**OrbStack.** Migration **in** is strong: automatic offer after install, `orb docker migrate`, moves
containers/volumes/images, **copies rather than moves**, resumable since v2.2.0 (VERIFIED). Migration
**out** is three sentences in the FAQ: stop OrbStack and `docker context use desktop-linux`. **There
is no data-export path out** — per-object `docker save` or `orb docker volume export` is all there
is, and machine export is an OrbStack-proprietary `.tar.zst`. **#2517, "No off-boarding or
uninstallation scripts", is open** (2026-06-08) (all VERIFIED).

**Us.** In: `mac/Sources/MorbMigrate/MigrateCLI.swift` supports `detect`, `plan`, `images`, `volumes`
and `verify`, `--from` accepting Docker Desktop, Colima, OrbStack **or a raw socket path** — already a
wider net than OrbStack casts, and with a checksum-manifest `verify` step neither competitor
documents. Out: `mac/Sources/MorbExport/ExportCLI.swift` does one image or one volume at a time, and
`morb uninstall-cli` reverses installation precisely, removing only artifacts that are still positively
Morbstack's own (`docs/design/ZERO-CONFIG-DISCOVERY.md`, the reversal table).

**Does it matter.** Migration *in* matters on day one. Migration *out* matters on day zero — it is what
someone checks before they trust an unfunded one-maintainer project with their working environment.
"You can leave, here is the command" is worth more to us than to either competitor precisely because
we are the risky choice.

**Verdict: build the way out, and make it the pitch.** `morb migrate` already has the entire mechanism
— `HelperContainer.createMounted` reads volume bytes through a stopped helper, `ImageMigrationTransaction`
and `VolumeMigrationTransaction` move them transactionally, `VerifyCommand` checksums the result. Point
it the other way: `morb migrate --to <runtime|socket>`, same transactions, same verification, plus a
bulk `morb export --all` that writes a directory a stock `docker load` can restore. Then say it in the
README, in one line, above the fold: **"Leaving is one command, and it is tested."** Neither competitor
can copy that sentence — OrbStack's own tracker says so. → **UX-22**

## 15. The things they ship that we should not build

Recorded so a future parity sweep does not quietly reopen them.

- **USB passthrough, sound, webcams, CAN bus, Xbox controllers** (OrbStack v2.2.0/v2.2.1/v2.2.2,
  VERIFIED). Genuinely impressive, genuinely a different product. A container tool does not need an
  oscilloscope driver. **Skip.**
- **Docker checkpoint/restore (CRIU)** (OrbStack v2.2.0, VERIFIED). Already a stated non-goal here.
  **Skip.**
- **GPU passthrough.** *Neither* competitor has it — no GPU/CUDA/Metal passthrough anywhere in
  OrbStack's docs or changelog, and Docker's Model Runner on macOS runs the inference engine on the
  **host** under `sandbox-exec`, not in a container (both VERIFIED). This is the axis the rest of the
  free field (Lima's 2026 "hardening AI" roadmap, Podman's libkrun/krunkit) is investing in. **Skip —
  but know it is the axis we are ceding**, and that the incumbents are ceding it too.
- **Docker Model Runner, Ask Gordon, Docker Offload, the MCP *Gateway*, extensions marketplace,
  Settings Management, ECI, RAM/IAM, air-gapped containers, SSO/SCIM, Build Cloud, Testcontainers
  Cloud** (all VERIFIED as shipped; most Business-tier). Same verdict as
  [UI-FEATURE-GAP.md](UI-FEATURE-GAP.md) §12, extended to their capability side: these exist to serve
  enterprise procurement or to meter a cloud service, and Morbstack structurally has neither motive.
  **Skip.**
- **One caveat on MCP specifically.** Docker's **MCP Toolkit/Catalog** is not cruft in the way the
  rest of that list is — 300+ servers as signed container images with SBOMs, sandboxed at 1 CPU / 2 GB
  / no host filesystem by default, and no stated tier (VERIFIED). We already have `mac/Sources/MorbMCP/`
  with a read-only tool set, a separate mutating set, a permission model and an audit log. That is the
  right shape and the right size. **Do not build a catalog.** Being a good MCP *server* is the
  extension surface; being a marketplace is the cruft.

## 16. Where this repo's own documents are now wrong

Found while writing this. Each is a claim in a current doc that the code or a later audit contradicts.
None are edited here — they belong to their owners.

| Document | Claim | Reality |
| --- | --- | --- |
| [DIFFERENTIATION.md](DIFFERENTIATION.md) Tier B | "Disk reclaim. `discard=async` is already on the guest mount (`disk.rs:269-273`), so … more plumbing than research." | The kata kernel has **no btrfs**, so that mount option is dead code on every shipped install; ext4 mounts without `discard` and there is no `fstrim`. [TECHNOLOGY-AUDIT.md](TECHNOLOGY-AUDIT.md) Bet 8 (TECH-3) has it right; these two audits contradict each other. |
| [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) table stakes | Testcontainers "**never tested**", Dev Containers "**never tested**" | Four Testcontainers languages and the Dev Containers CLI pass zero-config against 29.7.1 — [ECOSYSTEM-MATRIX.md](ECOSYSTEM-MATRIX.md). |
| [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) row 14 | "VS Code / JetBrains integration — `absent`" | `integrations/vscode/` is a built `.vsix` with compose grouping, logs, a hijacked-stream exec terminal and a k8s view; `integrations/jetbrains/README.md` is a researched no-plugin-needed verdict with a feature matrix. |
| [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) row 10 | "pinned `kubectl` that pod port-forward needs is **not in the repo**" | `scripts/fetch-guest-assets.sh` pins kubectl v1.36.2 darwin-arm64 against its published sha256 sidecar (`fetch_kubectl`, `--host-kubectl-only`). |
| [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) row 1 | "`liveSharePaths` defaults to `[]` with **no CLI or GUI writer**" | `Settings/TrackDSharingSettings.swift` has "Add Project Folder…" with an `NSOpenPanel` and per-row Remove. (`sharedPaths` is still "Open config.toml" only — that half is accurate.) |
| [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) row 2 | "No `exec` in `DockerClient.swift`, no PTY view anywhere" | DIF-2 is in flight: `mac/Sources/MorbstackAppCore/Terminal/` exists with tests. The VS Code extension has shipped exec over a hijacked stream for longer than that. |
| `integrations/jetbrains/README.md` | "Morbstack does not ship buildx today" | buildx v0.36.0 is fetched and verified by `fetch-guest-assets.sh` step 8 and `docker buildx ls` was VERIFIED against the engine in `integrations/ecosystem.md`. |
| [ECOSYSTEM-MATRIX.md](ECOSYSTEM-MATRIX.md) header | "MinAPIVersion **1.40** (stock upstream default — Morbstack does not modify it)" | `guest/morbinit/src/supervisor.rs:192` sets `DOCKER_MIN_API_VERSION=1.24` unconditionally, and [../COMPETITIVE-GAPS.md](../COMPETITIVE-GAPS.md) reports `/v1.32/info` → 200. One of the two ran before that landed; they cannot both be current. |
| `docs/architecture.md` | lists a qemu-user fallback for workloads Rosetta cannot translate | Nothing implements it (§7). |
| `integrations/shell/_morb` | completions | Missing `export`, which `mac/Sources/morb/main.swift` dispatches. |
| `docs/parity.md` #18 | `host.docker.internal` **FAIL**, "not degraded, just absent" | Implemented in the guest DNS path per the same file's line 23 and COMPETITIVE-GAPS row; the #18 row records a pre-fix run and reads as current. |

---

## Ranked: what changes a user's day

Frequency × cost, the same axis [UI-FEATURE-GAP.md](UI-FEATURE-GAP.md) ranks on. Novelty scores
nothing.

1. **Disk space that never comes back (UX-16, via TECH-3).** Every user, every day, invisibly, until
   the morning the Mac is full and the only remedy is deleting the disk image. We currently reproduce
   the incumbent's most-complained-about behaviour, our two audits disagree about whether we do, and
   the experiment that decides the fix is one afternoon. Highest cost-to-benefit ratio on this page.
2. **Proxy support (UX-18).** Zero lines of it exist. It is invisible to everyone at home and
   disqualifying for everyone behind a corporate MITM — and OrbStack gives away for free the SOCKS5
   half that Docker charges Business money for. Days of work, not weeks.
3. **Publishing the benchmark harness and the watcher matrix (UX-14).** We have a measured 1.79 s cold
   boot and 0% idle CPU; Docker publishes **no** macOS startup number at all and OrbStack's benchmarks
   page is three years stale with the figures locked in images. This is the cheapest credibility we
   will ever buy, and it is already built — it needs two more workloads and a place to read it.
4. **Migration *out* (UX-22).** The mechanism exists in `MorbMigrate` and points one way. Turning it
   around buys the single sentence that answers the objection every prospective user of a
   one-maintainer project has, and OrbStack's own tracker (#2517) confirms they cannot answer it.
5. **Correcting our own docs (UX-21).** Three current documents describe our Testcontainers, Dev
   Containers and IDE story as absent when it is the strongest thing we have. A capability nobody can
   find is not shipping, and this one is not even a build.
6. **Routable guest addresses surfaced (UX-15).** Half a day on top of DIF-4's mandatory step 0, and
   it turns an internal gate into a visible capability while domains are still weeks away.
7. **Memory balloon driven (UX-17).** Real, contained, and mostly already covered by 5-minute
   auto-suspend. Below everything above it.
8. **SSH agent forwarding (UX-19).** Verify the build-time path first — it is probably already free —
   then add the runtime bind mount for copied Compose files.
9. **`kubectl top` honesty (UX-20).** Small, and only touches the Kubernetes subset. Worth doing
   because it is currently a confusing error rather than a stated trade.

**Deliberately not building:** everything in §15 (USB, sound, CRIU, GPU, the AI/cloud/fleet surface,
an MCP catalog), Linux machines until DIF-13 says otherwise (§13), and Kubernetes multi-node (§11).

**The precondition none of this survives without.** SP-9 is open: there is not one `notarytool` call
in the repo, and an unnotarized DMG is Gatekeeper-blocked for everyone but the author. Every
capability on this page is worth exactly nothing until somebody other than us can open the app.
