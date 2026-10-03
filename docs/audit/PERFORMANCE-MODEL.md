# Performance model — how OrbStack is actually fast, and where that leaves us

**Written 2026-08-07.** Third companion to [CAPABILITY-GAP.md](CAPABILITY-GAP.md) (capabilities)
and [UI-FEATURE-GAP.md](UI-FEATURE-GAP.md) (screens). This one is about **mechanism**: not "they
optimised it" but the specific engineering decisions that produce the numbers, what each of those
decisions costs, and which of them are available to us at all.

Competitor claims were fetched on 2026-08-07 and every one carries a URL and a date. Our side is
read from source on `swarm/cleanup` at `cd6627b` and every claim carries a file path. Evidence
labels match the companion docs: **VERIFIED** (the vendor's own words), **REPORTED** (secondary),
**INFERRED** (ours, flagged). Verdicts: **defend** · **build** · **build differently** ·
**measure first** · **refuse** (deliberate, with reasons).

**The standard, unchanged:** *"set the bar as if they can do it we can do it better for free and
without as much overhead and cruft."* Two constraints bound every recommendation below: **no GUI
that holds a credential, and no feature that requires an account.**

---

## 0. The one fact the rest of this document is downstream of

Everything OrbStack is famous for comes from a single decision, and they have said so plainly.

> **"Instead of Virtualization.framework, we have a custom Rust virtualization stack with custom
> devices and protocols for things like filesystem sharing. It's a highly optimized vertically
> integrated stack specifically for running our Linux machines and containers. Our biggest
> perf/resource gain is dynamic memory, which reduces memory usage a lot by releasing unused memory
> back to macOS."**
> — OrbStack's developer, [Hacker News, 2026-06-10](https://news.ycombinator.com/item?id=48470145) (VERIFIED)

and, the same day, on the filesystem specifically:

> **"we've put a lot of effort into optimizing for small files and other common developer workloads
> in OrbStack's customized filesystem sharing protocol (not standard virtiofs)."**
> — [Hacker News, 2026-06-10](https://news.ycombinator.com/item?id=48470405) (VERIFIED)

This is not a recent pivot. The same developer in **June 2023** said the opposite — *"I use
Virtualization.framework for OrbStack… So yes, I still use Virtualization.framework, but only
because I have no choice. Apple doesn't allow third-party VMMs to set the necessary CPU flags for
Rosetta"* ([HN 36189550](https://news.ycombinator.com/item?id=36189550), VERIFIED) — and in
**September 2024**: *"The virtualization stack is custom… It's not Virtualization.framework or
QEMU"* ([HN 41423187](https://news.ycombinator.com/item?id=41423187), VERIFIED). The changeover is
dated in their own changelog: **v1.6.0, 2024-05-22, "New virtualization engine: faster and more
stable"**, shipped the same day as the filesystem blog post
([release notes](https://docs.orbstack.dev/release-notes), VERIFIED).

So the causal chain is:

```
own the VMM
 ├── own the fs device        → custom protocol, 10x lower per-call overhead → 75-95% of native
 ├── own the guest RAM arena  → track live pages, release the rest          → dynamic memory
 ├── own the network device   → userspace stack, NAT v4+v6, custom DNS      → routable IPs, VPN compat
 ├── own the kernel           → patched, one version, KASLR without KPTI    → cheaper syscalls
 └── lose Apple's Rosetta path (in their own 2023 assessment)               → ??? see §6
```

**Two of those five are structurally closed to us and one is not.** Apple's
`VZVirtioFileSystemDeviceConfiguration` takes a tag and a directory and exposes no tuning at all;
the guest cannot even pass mount options, because *"the virtiofs driver accepts only `dax` and
`source`, and DAX needs a shared memory window that Virtualization.framework does not expose"*
(`guest/morbinit/src/mounts.rs:148-152`). Apple's memory balloon is host-to-guest only and gives no
view of the guest's live set (`guest/morbinit/src/meminfo.rs:5-8`). Networking, by contrast, **is**
reachable — `VZFileHandleNetworkDeviceAttachment` is how vfkit, gvisor-tap-vsock and Podman run
userspace stacks *on top of* Apple's framework, and we simply use `VZNATNetworkDeviceAttachment`
instead (`mac/Sources/MorbstackKit/VMManager.swift:2424-2425`).

**Docker independently reached the same conclusion and is paying the same price.** Docker VMM is
their own container-optimised hypervisor, claiming *"2x faster"* cold-cache `find` and *"as much as
25x"* warm-cache over the Apple framework — and it *"does not currently support Rosetta, so
emulation of amd64 architectures is slow"* and *"certain databases, like MongoDB and Cassandra, may
fail when using virtiofs"*. It has been **Beta since 4.35 in October 2024**, twenty-two months, and
is still not the default
([Docker VMM docs](https://docs.docker.com/desktop/features/vmm/), VERIFIED 2026-08-07).

That is the shape of the whole competitive question, and §7 is where it gets answered.

---

## 1. Filesystem — verdict: **refuse the transport race, measure and publish instead**

### What they do

Their [May 2024 blog post](https://orbstack.dev/blog/fast-filesystem) is the primary source and it
is more modest than the folklore. They did **not** invent a new sharing model; they rejected the
two alternatives and made the shared-filesystem path cheaper:

> *"Since synchronization has a lot of fundamental problems that are hard to overcome, we decided
> to focus on making shared file systems as fast as possible. **By reducing per-call overhead by up
> to 10x**, we're seeing 2–5x speedups for real-world use cases, typically within 75-95% of native
> macOS performance."* (VERIFIED)

Their published numbers, all against **native macOS**, 1614 packages / 807 MiB installed:

| Workload | OrbStack | Native macOS | % native |
| --- | ---: | ---: | ---: |
| `pnpm install` | 12.2 s | 10.9 s | 88% |
| `yarn install` | 9.8 s | 7.9 s | 77% |
| `rm -rf node_modules` | 4.0 s | 3.6 s | 87% |
| Postgres `pgbench` | 8998 TPS | 11785 TPS | 76% |

They admit the limit in the same post: *"This is an imperfect solution: the macOS file system stack
isn't as optimized as Linux's, and it's incredibly challenging to get overheads low enough… we're
not quite there yet for some more challenging workloads."* (VERIFIED) And their v0.14.0 changelog
(July 2023) carries the number people actually quote at us: **"3x faster search, 20x faster `git
status`"** (VERIFIED).

**One contradiction worth holding them to.** The blog says *"Bind mounts should always be a
reasonable choice."* Their own [quick start](https://docs.orbstack.dev/quick-start) says *"Use
volumes at `~/OrbStack/docker` for optimal file system performance."* (both VERIFIED). Whatever the
protocol does, their own onboarding still tells you to avoid bind mounts for the hot path.

### What we do

Apple's virtiofs, one `VZVirtioFileSystemDeviceConfiguration` per shared root, each mounted at **the
same absolute path inside the guest** so `-v /Users/me/app:/app` needs no translation anywhere
(`mac/Sources/MorbstackKit/VMManager.swift:2475-2478`; `DirectoryShares.swift:7-15`;
`guest/morbinit/src/shares.rs:4-12`). `VZMultipleDirectoryShare` is explicitly rejected because it
would reintroduce a path prefix (`VMManager.swift:2458-2464`). Defaults are `/Users`, `/Volumes`,
`/private/tmp` (`DirectoryShares.swift:66`), transported to the guest on the **kernel command line**
rather than a control channel (`DirectoryShares.swift:69`).

Mount options: **none, and none are available.** `sys::mount` passes a NULL `data` pointer
(`guest/morbinit/src/sys.rs:245-247`); the only flags are `MS_NOSUID`/`MS_NODEV`
(`mounts.rs:129-137`). No `cache=`, no DAX, no writeback. The kernel has `CONFIG_FUSE_DAX=y` and it
is unusable (`docs/shares.md:193-198`). No block-device caching mode either — the root disk uses the
plain `VZDiskImageStorageDeviceAttachment(url:readOnly:)` initializer (`VMManager.swift:2447`).

Measured, ours, 2000 files / 256 MiB, share vs. the guest's own overlay (`docs/shares.md:155-164`):

| Operation | VirtioFS share | Guest overlay | Ratio |
| --- | ---: | ---: | ---: |
| Sequential write, 256 MiB | 235 ms | 424 ms | **0.55x** (share is faster) |
| Create 2000 small files | 627 ms | 123 ms | **5.1x** |
| `ls -la` 2000 entries | 61 ms | 54 ms | 1.13x |
| `rm -rf` the tree | 340 ms | 81 ms | **4.2x** |

Streaming is fine — 1.1 GB/s write (`docs/COMPETITIVE-GAPS.md:90`, method not recorded at any of its
three citation sites). Metadata costs ~5x, and `docs/shares.md:166-170` already gives the right
advice: *"keep dependency directories in named volumes and bind-mount only source."*

### Are we ahead, level, or behind

**Behind, and structurally so, on the axis that matters.** Their 10x per-call reduction is inside a
device we do not own. There is no configuration change, no guest patch, and no amount of effort
short of writing a VMM that closes it.

**But nobody can compare the two numbers as they stand, including us.** Their ratio is
container-over-bind-mount vs. native macOS. Ours is bind-mount vs. named volume *inside the same
guest kernel*. Different denominators measuring different things. `MorbBench` already ships the two
benchmarks that would produce a comparable figure — `GitStatusBindmount.swift` and
`NpmInstallBindmountVsVolume.swift`, with targets of ≤2.0x and ≤1.5x
(`mac/Sources/MorbBench/Support/Targets.swift:67-71`, methodology in `docs/benchmarks.md:74-100`) —
and **neither has ever been run and published**. `TECHNOLOGY-AUDIT.md:168-172` says so outright:
*"the known industry weakness is metadata-heavy workloads — `git status`, `npm install` — and
Morbstack has never measured them."*

### Verdict: **refuse the transport race, and finish the measurement**

We are not going to out-engineer a funded team inside Apple's device. Say so, and compete on the
two things a closed competitor cannot answer:

1. **Run the harness and publish the numbers.** DIF-3/UX-14 built it; the last mile is a machine-lane
   pass and four lines of results. Right now our strongest filesystem statement is a competitor's
   admission plus our own "never measured." → **UX-30**
2. **Publish the guidance as a default, not a footnote.** Both products' honest answer is "named
   volume for `node_modules`, bind mount for source." OrbStack says it in their quick start while
   their blog says the opposite; we can just say it, in the first-run sheet and the docs, and be the
   one that didn't oversell.

The file-watch half is already better handled than theirs and is covered under §7's ledger.

---

## 2. Memory — verdict: **measure first; this is the memory analogue of TECH-3**

### What they do

The [August 2024 blog post](https://orbstack.dev/blog/dynamic-memory) explains the mechanism by
explaining why it was impossible before. Guest RAM is a flat mapping:

> *"there's no concept of 'used' or 'free' memory; we only know that Linux has written data to
> various parts of the array. Maybe it wrote to the first 512 MiB earlier, but now only the first
> 128 MiB is actually in use. The rest is just sitting there, but we can't discard it because we
> don't know whether it contains important data."* (VERIFIED)

> *"we've introduced a new memory management system that builds on top of the 'giant array' concept
> to **track which parts of the virtual RAM are actually in use**, and which parts are likely no
> longer needed and can be released if other apps need more memory."* (VERIFIED)

Shipped v1.7.0, 2024-08-22, *"Memory usage is (finally) a solved problem!… Works with running
containers and machines!"* (release notes, VERIFIED). Before that they were blocked: in April 2023
their developer said *"a macOS bug combined with a hypervisor restriction prevents us from shipping
this"* ([HN 35742336](https://news.ycombinator.com/item?id=35742336), VERIFIED) — the hypervisor
being Apple's. It became possible when they stopped using it.

Not perfect: [#2558](https://github.com/orbstack/orbstack/issues/2558) (LAN port-forwarding stalls
during balloon deflation, open) and [#2251](https://github.com/orbstack/orbstack/issues/2251) (high
memory with no running containers, open).

### What we do

`VZVirtioTraditionalMemoryBalloonDeviceConfiguration` attached (`VMManager.swift:2421`), and — as of
UX-17, which landed after CAPABILITY-GAP §5 was written — **actually driven**:
`balloon.targetVirtualMachineMemorySize = bytes` at `VMManager.swift:802-804`, on a 30-minute timer
(`VMManager.swift:156`), fed by the guest's own `/proc/meminfo` `MemTotal`/`MemAvailable` over the
MRB0 control channel (`guest/morbinit/src/meminfo.rs:29,48`) because the traditional balloon has no
host-visible feedback of its own (`meminfo.rs:5-8`). The decision logic is a pure, unit-tested
function with a 25% floor, 35% headroom, 15% max shrink step and hysteresis
(`MorbstackKit/MemoryBalloonPolicy.swift:70-79`). Default allocation 8192 MiB
(`MorbConfig.swift:132`) — more considerate than Docker Desktop's 50%-of-host, less adaptive than
theirs.

The guest does nothing proactive: checked `guest/morbinit/src/` for `balloon`, `madvise`, `MADV_`,
`drop_caches`, `zram`, `swapon`, `/proc/sys/vm` — **absent**. It only reports.

And the mitigation we have is genuinely strong: **auto-suspend at 5 minutes idle**
(`MorbConfig.swift:138`) with real inhibitors — any live relay connection, any running container,
and *inability to confirm the container list* all block it, and it re-checks immediately before the
hypervisor acts (`Daemon.swift:1266-1327`). Suspend returns **all** of it, which beats shaving
pages.

### Are we ahead, level, or behind

**Behind while running, level-or-ahead while idle — and we cannot prove either.**

The unresolved question is the important one: **does setting `targetVirtualMachineMemorySize`
actually return pages to macOS under Virtualization.framework, or does it only shrink the guest's
view?** Apple documents neither. Nothing in this repo has measured it. UX-17's own ticket text says
the guest-side `meminfo` reporting *"does nothing until `mise run guest-image` rebuilds the
initramfs… not yet verified end to end"*, and the policy explicitly adds **no** user-facing "dynamic
memory" claim.

This is exactly the shape of TECH-3, which asked whether VZ's `VZDiskImageStorageDeviceAttachment`
translates a guest `discard` into hole-punching on the backing file. Apple didn't document that
either. We ran the experiment, got a yes, and shipped a real capability off the back of it
(`docs/design/DISK-RECLAIM-DECISION.md` §4 — 4.01 GiB reclaimed on a live `discard` mount, 9.30 GiB
on a full `fstrim` sweep, with two no-discard controls moving <0.01% to rule out APFS lazy reclaim).

### Verdict: **measure first, claim nothing until then**

One afternoon, same method as TECH-3: boot with 8 GiB, allocate and free inside the guest, drive the
balloon down, and watch the `morbstackd` process's real footprint and system-wide memory pressure
across the transition. Two outcomes, both useful:

- **Pages come back.** Then our 30-minute timer becomes a shipped capability, the interval is worth
  tuning down, and we can say "memory returns to macOS" with a number — the only such claim in this
  market backed by a reproducible harness rather than a blog post.
- **They don't.** Then say so, delete the implication, and lean the copy entirely on auto-suspend,
  which returns 100% of it and which neither competitor's default configuration matches (Docker's
  Resource Saver is 5 minutes too but costs 3–10 s to resume; ours costs a 1.79 s cold boot in the
  worst case).

→ **UX-29**. Do **not** write "dynamic memory" anywhere user-facing before it returns a number.
OrbStack's own tracker shows what that claim costs when it slips.

---

## 3. Networking — verdict: **behind for reasons we could change; rank it low anyway**

### What they do

*"Access to the outside network is provided by a **custom virtual network stack** with tuning around
it for performance. NAT is used for IPv4 and IPv6, and a **custom DNS server forwards DNS queries to
macOS**. This setup makes it possible to follow VPN and DNS settings. Containers and machines are
connected to unified bridge networks, allowing them to communicate with each other and **with macOS
directly by IP address**. Host networking is also available. **Event-based port forwarding** makes
servers instantly available at localhost on macOS."*
([architecture](https://docs.orbstack.dev/architecture), VERIFIED — note the page is © 2024 and
still describes their filesystem as VirtioFS, so treat its currency with care.)

Their developer, 2023: *"I wrote a new virtual network stack in userspace and made sure to address
issues plaguing other virtual networking solutions (VPN compat, DNS failures, etc.)"*
([HN 36675039](https://news.ycombinator.com/item?id=36675039), VERIFIED). Changelog receipts: *"Up
to 75% faster network in Docker containers"* (v1.6.4), *"Significantly faster IPv6 networking"*,
*"Lower CPU usage under high network load"*. Still shipping fixes **today**: v2.2.3 (2026-08-07)
carries *"Fixed inbound UDP to host-networking containers"* and *"Fixed UDP packets over 1472 bytes
being dropped on port forwards"* (VERIFIED).

### What we do

`VZNATNetworkDeviceAttachment` with a pinned MAC (`VMManager.swift:2424-2440`) and a per-connection
vsock relay. Checked all of `mac/Sources/` for `VZFileHandleNetworkDeviceAttachment`,
`VZBridgedNetworkDeviceAttachment`, and all of `mac/Sources/` + `guest/` for `gvisor`, `netstack`,
`slirp`, `lwip`, `smoltcp` — **absent everywhere except the roadmap**
(`docs/architecture.md:481-483` names "morbnet, a userspace network stack forked from
gvisor-tap-vsock"; `docs/roadmap.md:169-170` names a smoltcp rewrite; neither exists).

The published-port data path, counted honestly:

```
Mac client
  → morbstackd TCPListener → FDRelay, 64 KiB buffer          [copy 1]  Relay.swift:75-92
  → vsock 2376, "TCP <port>\n" preamble                                StreamDial.swift:15-37
  → morbinit dial.rs, two-thread copy, 64 KiB                [copy 2]  dial.rs:275-300, proxy.rs:52
  → guest 127.0.0.1:<port>
  → stock docker-proxy                                       [copy 3]  the price of a stock dockerd
  → container veth
```

Three userspace copies. The third one is deliberate: we run an **unmodified upstream dockerd** and
reach `-P` through its own `--userland-proxy-path` hook rather than patching it
(`guest/morbinit/src/proxy_wrapper.rs:21-30`, `docs/design/PATCH-FREE-PUBLISH-ALL.md`). The wrapper
leases the Mac-side port over vsock 2382, gets an `OK`, then `exec`s the stock binary — so **no bytes
ever traverse our Rust wrapper**; it is control plane only.

Measured: **HTTP 200 in 0.003008 s** from the Mac to a container, port-forward setup 6 ms after the
forward is added (`ENGINE-MATRIX.md:130-131,182`); vsock bulk **>100 MB/s** (`docs/k8s.md:274-277`).
Checked `docs/` and `docs/audit/` for `iperf`, `Gbit`, `Mbit`, `RTT` — **there is no dedicated
network benchmark**, and none of the eight `MorbBench` entries is networking
(`Targets.swift:74-76`).

Guest→host: split-DNS stub answering `host.docker.internal` and `gateway.docker.internal` with the
VM's default gateway, A-records only (`guest/morbinit/src/dns.rs:19-24,60`) — implemented because
*"there is no 'host.docker.internal' string anywhere in [dockerd]"* (`dns.rs:5-7`). Host→container
by IP: DIF-4's step-0 gate **passed on Wi-Fi with no VPN on 2026-08-06** (ICMP + TCP to a live guest
at `192.168.64.27`, closed ports actively refused, unleased addresses timing out —
`docs/design/DNS-DECISION.md`); Ethernet and VPN untested.

### Are we ahead, level, or behind

**Behind on capability, level on latency, unmeasured on throughput.** 3 ms to a published port is
not a performance problem. IPv6, ICMP, VPN-aware DNS and routable container IPs are capability gaps,
and they are tracked as capability work in DIF-4 and DIF-6, not as performance work.

This is the one axis in this document where the gap is **not** structurally closed to us — a
userspace stack on `VZFileHandleNetworkDeviceAttachment` is a known pattern. It is also a quarter of
work with a large new attack surface, against a current path that answers in 3 ms.

### Verdict: **build differently, and not now**

Do not start morbnet as a performance project. Two smaller things instead:

1. **Say what the three copies buy.** A stock upstream dockerd is why every `-p` form, `-P`
   expansion and UDP publication behaves like Docker's, and why we have no engine patch to carry
   forward. That is a real product property currently recorded only in a design doc.
2. **Add one networking benchmark** so the next person arguing for morbnet has a baseline to beat
   rather than a hunch. Folds into **UX-30**.

---

## 4. Startup — verdict: **defend, and nobody can tell, including us**

### What they do

*"Starts in 2 seconds"* ([features](https://docs.orbstack.dev/features), VERIFIED). Their landing
page has since softened to *"Starts in seconds"* (VERIFIED 2026-08-07). No methodology is published
for either — the [benchmarks page](https://docs.orbstack.dev/benchmarks) contains **no startup
benchmark at all**. Docker publishes no macOS startup figure whatsoever (VERIFIED as absence).

### What we do

**1.79 s cold boot to a first successful Docker API call** — measured to a *served request*, not to
"VM running" (`ENGINE-MATRIX.md:471-479`). **0.0% idle CPU, 23 MB host RSS** after 20 s quiescence
(`:481-483`; guest memory is not attributed to host RSS under Virtualization.framework, so that is
the host-side footprint only).

And the thing that is better than a fast boot: **we don't boot at all until someone asks.**
`morbstackd`'s `run()` starts no VM (`Daemon.swift:290-328`); the first Docker socket connection
calls `vm.ensureRunning` before opening the vsock (`DockerProxy.swift:146-155`, *"the first thing
any real client sends is a `/_ping` that boots the VM regardless"*), and the launch agent's own
plist says *"The agent does not boot a VM on its own; it only keeps the lightweight host control
service available"* (`mac/AppResources/LaunchAgents/dev.morbstack.daemon.plist:13-14`). There is no
launchd socket activation — checked the only shipped plist for `Sockets`/`LaunchEvents`, absent;
the laziness lives in-process.

Suspend is fail-closed in a way neither competitor documents: a host on which `saveMachineStateTo`
succeeds and `restoreMachineStateFrom` then refuses is **permanently degraded to stop-and-cold-boot**
rather than allowed to keep writing state blobs it cannot restore
(`VMManager.swift:1610-1650,280-300`) — *"A save blob that will not restore is worse than no save
blob at all: every subsequent bring-up would pick it up and fail the same way, wedging the daemon."*

### Are we ahead, level, or behind

**Ahead on the number, and unable to prove it to a stranger.** Three problems with the 1.79 s
figure, all fixable in one machine-lane pass:

1. It is **two daemon-log timestamps**, not a benchmark run — no repetitions, no median.
2. It sits in a document carrying its own **"do not carry a row below forward as `runs-here`"**
   warning about a since-deleted mechanism (`ENGINE-MATRIX.md:5-21`).
3. The repeatable harness exists and does it properly — `ColdBoot.swift` stops the VM, starts it,
   polls `GET /_ping` to a 60 s deadline, median of five (`Benchmarks/ColdBoot.swift:29-73`) — and
   **its output has never been published.** Same for `resume` (target ≤500 ms) and
   `guest-memory-floor` (≤256 MB): targets exist, measured values do not.

### Verdict: **defend, and spend one machine-lane hour turning a log line into a benchmark**

This is the cheapest credibility on the page and it is already built. Also surface the lazy boot: the
honest cold-boot number for most of a developer's day is **zero seconds, because nothing is running**
— which is a better story than 1.79 s and appears nowhere a user reads. → **UX-30**

---

## 5. Install size — verdict: **build; we are ~36x behind and 123 MB of it is a packaging choice**

### What they do

*"A fresh install of OrbStack uses **less than 10 MB of disk space**. Usage increases and decreases
as needed thanks to fully dynamic disk management"* ([efficiency](https://docs.orbstack.dev/efficiency),
VERIFIED). Read carefully: that is the **data directory**, not the application. Their app bundle is
not published. Still, "less than 10 MB" is the number people quote.

### What we do

Measured on disk, 2026-08-07 build:

| Item | Bytes | |
| --- | ---: | --- |
| **`dist/Morbstack.app` total** | **383,663,935** | **366 MB** |
| `Resources/runtime/…/k8s/k3s` | 73,728,162 | staged in the bundle, installed to the guest on demand |
| `Resources/runtime/…/k8s/cri-dockerd` | 48,693,410 | same |
| `Resources/runtime/…/kernel/initrd.img` | 83,855,888 | the guest |
| `Resources/runtime/…/kernel/vmlinux` | 16,151,040 | kata 6.18.15-186 |
| `Resources/host-bin/cli-plugins/docker-buildx` | 62,541,792 | |
| `Resources/host-bin/cli-plugins/docker-compose` | 30,634,448 | |
| `Resources/host-bin/docker` | 27,780,112 | |
| `MacOS/MorbstackApp` + `morb` + `morbstackd` | 39,263,104 | our own code — 10% of the bundle |

No DMG exists in the tree (repo-wide `find -name "*.dmg"` excluding `.build`: zero results), so the
compressed download size cannot be quoted.

### Are we ahead, level, or behind

**Behind by roughly 36x on the number they advertise, and this one is entirely self-inflicted.** Our
own binaries are 39 MB of a 366 MB bundle. The rest is other people's software.

**The finding: k3s (74 MB) + cri-dockerd (49 MB) = 123 MB, a third of the bundle, for a feature
that is off by default — and the argument for not carrying it is already written in our own build
script, one layer down.** `scripts/mkinitramfs.sh:364-380` deliberately keeps both out of the
initramfs, and says why in terms that transfer almost verbatim to the bundle:

> *"Kubernetes is off by default, so that would be 122 MB spent on every boot for a feature most
> boots never use… Instead morbstackd streams the payload in over vsock 2377 the first time `morb
> k8s enable` runs, and morbinit writes it to the persistent ext4 disk. A guest that has never been
> asked for a cluster carries none of it."*

That reasoning solved the **guest RAM** cost (initramfs pages are ramfs and never reclaimed) and
stops exactly one layer short of the **download** cost: morbstackd streams the payload *out of the
app bundle*, so every user still downloads 123 MB of Kubernetes whether or not they ever enable it.

### Verdict: **build — fetch the Kubernetes payload on first `morb k8s enable`**

Extend the existing argument by one hop. Same hash pins, same verification, same
`fetch-guest-assets.sh` machinery and `RuntimeArtifacts.swift` staging as every other guest asset;
the only change is *when* the bytes arrive on the Mac. It removes a third of the download with no
capability lost and no new mechanism, and it takes two nested binaries out of the signing order,
which CLAUDE.md §1.1 calls a landmine. The one thing it costs is offline/air-gapped first-enable,
which is worth stating as the trade rather than discovering.

Explicitly **not** proposed: dropping the bundled `docker`/`compose`/`buildx` (94 MB). Those are what
"drop-in" means, and `MorbstackKit/CliPlugins.swift:222-292` re-verifies them against
`TOOLCHAIN.plist` and the bundle's code signature at *use* time — provenance neither competitor
documents. Pay the 94 MB and say why. → **UX-31**

---

## 6. Rosetta and x86-64 — verdict: **defend, and take the one free win we left on the table**

### What they do

Rosetta on by default, *"much faster than the commonly-used QEMU"*, no multiplier published anywhere
(VERIFIED as absence). AVX emulation *"when Rosetta is disabled"* (v1.11.0) and *"Fixed emulated x86
machines not starting when Rosetta is disabled"* — so they have a non-Rosetta fallback we do not.

**An open question about them worth recording.** In 2023 their developer said a custom VMM was
impossible precisely because *"Apple doesn't allow third-party VMMs to set the necessary CPU flags
for Rosetta. There are too many users relying on Rosetta for fast x86 emulation for me to ditch
it"* ([HN 36189550](https://news.ycombinator.com/item?id=36189550), VERIFIED). They shipped the
custom VMM in 2024 and still advertise Rosetta. How both are true is not explained anywhere public.
**INFERRED, flagged:** either Apple relaxed the restriction, or their Rosetta path is degraded in a
way their docs do not mention. Their steady drip of Rosetta syscall bugs —
[#2606](https://github.com/orbstack/orbstack/issues/2606),
[#2600](https://github.com/orbstack/orbstack/issues/2600),
[#2588](https://github.com/orbstack/orbstack/issues/2588), all open as of July 2026 — is consistent
with either. Worth a watch item, not a claim.

### What we do

`VZLinuxRosettaDirectoryShare` attached as an extra virtiofs device, **appended** rather than
assigned so installing Rosetta cannot silently drop every bind mount
(`VMManager.swift:2509-2517`; `MorbstackKit/Rosetta.swift:114-126`). On by default
(`MorbConfig.swift:137`). Never auto-installed, because a daemon-triggered system download dialog
would appear with no app behind it (`VMManager.swift:2498-2506`).

Guest registration via `binfmt_misc` with flags **`OCF`** (`guest/morbinit/src/binfmt.rs:133`). The
`F` is load-bearing and the file says why: *"Without it the kernel resolves the interpreter path at
exec time, in the mount namespace of the process being executed. A container's mount namespace has
its own root — the image's rootfs — which does not contain `/run/rosetta`"* (`binfmt.rs:26-33`).
That is why amd64 images run unmodified.

Measured, published, which neither competitor does: ~1.0x container start, and compute slower by a
factor `docs/amd64.md:139-141` puts at **1.8–2x** and `TECHNOLOGY-AUDIT.md:391` puts at
**1.5–1.7x**. Those two numbers disagree and are both labelled measured-here. `openssl speed
sha256` is ~5x because it loses Apple silicon's hardware SHA extensions.

### The free win

`VZLinuxRosettaDirectoryShare` supports **ahead-of-time translation caching** via
`cachingOptions` (macOS 14+): the guest runs `rosettad`, which writes `.aotcache` files so a repeated
x86 binary launch skips translation entirely. Lima shipped it in
[PR #2489](https://github.com/lima-vm/lima/pull/2489), merged 2024-07-19, using
`VZLinuxRosettaAbstractSocketCachingOptions`. Docker Desktop's backend links both caching symbols
(`docs/comparison.md:151-153`).

**We set neither.** `Rosetta.swift:120` constructs a bare `VZLinuxRosettaDirectoryShare()`; checked
all of `mac/Sources/` and `guest/` for `CachingOptions`, `AbstractSocket`, `rosettad` — **absent**.
`TECHNOLOGY-AUDIT.md:401-402` already flags it: *"The untaken cheap win is
`VZLinuxRosettaUnixSocketCachingOptions` AOT caching… effect unmeasured."*

The Lima PR names the real cost: `rosettad` must run in the same mount namespace as `rosetta` and be
executed directly from the share path (copies do not work), so wiring it for **containers** means
morbinit starting it in the right place, not just flipping a Swift property.

### Verdict: **defend, and build the AOT cache**

We are already in the best position of the three: on by default like OrbStack, with a published
multiplier neither offers, on the backend Docker's own faster hypervisor **cannot use**. And the
cache is the rare item that is available to us *because* we stayed on Virtualization.framework —
closed to OrbStack if they truly left it, and off-by-default-behind-off-by-default at Docker.
It targets exactly the repeated-launch case our 1.8–2x multiplier describes. → **UX-28**

Two truthfulness items while in there: reconcile the two multipliers, and either implement the
qemu-user fallback `docs/architecture.md` lists or stop listing it (nothing implements it).

---

## 7. What is comparable, and what is marketing

Their published performance material does not say what people think it says. Fetched 2026-08-07.

| Claim | Where | What it actually is |
| --- | --- | --- |
| The benchmarks page | [docs](https://docs.orbstack.dev/benchmarks) | *"Testing conducted in late August 2023 with… OrbStack (v0.17.0) and Docker Desktop (v4.22.0)… on an M1 Max."* Docker Desktop is now **4.85.0**. **Three years stale**, figures locked in chart images, and its five benchmarks are two *builds* and three *battery* tests — **no filesystem, no startup, no memory benchmark on it at all.** |
| "2–10x faster" filesystem | [blog](https://orbstack.dev/blog/fast-filesystem) | vs. **their own previous version**, not vs. a competitor. |
| "75-95% of native" | same | The honest one. Four workloads, denominators stated. This is the number to hold them to. |
| "20x faster `git status`" | v0.14.0 changelog, July 2023 | vs. their own v0.13. Three years old. |
| "5x faster database tasks (36x compared to Docker Desktop)" | same blog | A **tester's tweet**, quoted as a testimonial. Not a measurement. |
| "less than 10 MB of disk" | [efficiency](https://docs.orbstack.dev/efficiency) | The **data directory** on a fresh install, not the app bundle. |
| "Starts in 2 seconds" | [features](https://docs.orbstack.dev/features) | No method, no benchmark behind it. Softened to "Starts in seconds" on the landing page. |
| The feature-comparison table | [compare](https://docs.orbstack.dev/compare/docker-desktop) | *"Last updated in January 2025 for Docker Desktop v4.37.2."* **Nineteen months stale.** |
| The architecture page | [architecture](https://docs.orbstack.dev/architecture) | © 2024. Still says *"builds on top of a modern base (VirtioFS)"* — which their own engineer contradicted in **June 2026** (*"not standard virtiofs"*). Their landing page still says "VirtioFS file sharing" too. |

**So what is genuinely comparable today?** Their 75–95%-of-native filesystem figures from May 2024,
and nothing else. Everything on the benchmarks page predates two major versions of both products.

**And what does that mean for us?** Our position is not "our numbers beat theirs." It is that
**we are the only one of the three with a runnable harness**. Docker publishes a percentage with no
method. OrbStack publishes charts from v0.17.0. `morb bench run` measures eight things against a
published target table, refuses to invent a number for a benchmark that could not honestly run
(`docs/benchmarks.md`), and `StackGuard` refuses to call an engine idle while containers are visibly
running on it. "Here is the harness, run it on your Mac against all three" is a sentence a closed
competitor structurally cannot write — and four of its eight rows currently have **targets with no
published measurement**, which makes it a claim we cannot yet make either.

---

## 8. Copy, beat, refuse

### Refuse — with reasons, so a future parity sweep does not reopen them

- **Writing our own VMM.** This is the famous thing that is not worth building, and all three
  parties' evidence agrees. It costs Apple's Rosetta path (OrbStack's own 2023 assessment of why it
  was impossible), a **patched kernel maintained per version** (*"a lot of OrbStack's improvements
  are very closely tied to the kernel, and maintaining the patches for multiple versions wouldn't be
  worth the work"*, [HN 36675885](https://news.ycombinator.com/item?id=36675885), VERIFIED), a new
  security boundary, and a rewrite of every device. Docker committed a funded team and is
  **twenty-two months into Beta, still without Rosetta, still breaking MongoDB on virtiofs, still
  not the default.** For a project whose differentiator is being free, honest and account-free, this
  is the single worst place to spend a year. **Refuse.**
- **A custom filesystem sharing protocol.** Downstream of the same decision; not separately
  reachable. **Refuse.**
- **Matching their benchmark marketing.** Publishing our own chart images with our own workloads
  would put us in a game where the last mover wins and nobody can check. Publish the harness
  instead. **Refuse.**

### Beat — where we already lead and nobody can tell from the UI

| Axis | Us | Them |
| --- | --- | --- |
| **Disk reclaim** | `fstrim` on **every** guest shutdown plus an hourly sweep, measured: 4.01 GiB reclaimed from a live discard mount, 9.30 GiB from a full sweep, with two controls (`docs/design/DISK-RECLAIM-DECISION.md` §4, §8.6) | OrbStack [#2030](https://github.com/orbstack/orbstack/issues/2030) open since 2025-07-04, no documented compact command; Docker frees only on image delete, and shrinking the disk **deletes it** |
| **Lazy boot** | No VM until the first Docker socket connection; the login agent explicitly does not boot one (`DockerProxy.swift:146-155`, the LaunchAgent plist) | Both boot a VM to be "started" |
| **Fail-closed suspend** | A host that cannot restore is permanently degraded to cold boot rather than writing blobs it knows are dead (`VMManager.swift:1610-1650`) | Neither documents any such posture; Docker shipped a "spurious 500s after VM idle shutdown" fix in 4.79.0 |
| **Old-client compatibility** | `DOCKER_MIN_API_VERSION=1.24` in the guest (`guest/morbinit/src/supervisor.rs:192`) makes us the engine-29 distribution that testcontainers-java ≤1.20.x actually works against | Docker Desktop is insulated only until it moves off engine 27 |
| **Published watcher matrix** | Exactly which watchers our `IN_ATTRIB` bridge satisfies and which it does not, with the colima precedent (`docs/benchmarks.md:119-136`) | OrbStack regressed host→container watch events twice in a year ([#1931/#2033 in v2.0](https://github.com/orbstack/orbstack/issues/2033), [#2561 closed 2026-08-03](https://github.com/orbstack/orbstack/issues/2561)) and publish no matrix |
| **No license server** | Nothing to phone. | `api-license.orbstack.dev` is marked **Required** in their own [privacy policy](https://orbstack.dev/privacy) (VERIFIED). The app also automatically collects *"Usage Data: Information about how you use the Software, including actions you take, features you use, and time spent"* (VERIFIED). |

That last row is the one to say out loud. **OrbStack cannot run without contacting a server**, by
their own documentation — personal use is free but every commercial use needs a $8/user/month
license, with a 30-day grace period ([pricing](https://orbstack.dev/pricing),
[FAQ](https://docs.orbstack.dev/faq), VERIFIED). Their Debug Shell — the distroless-container
debugging feature — is **Pro-only**, which is what makes DIF-8 the one thing they actually paywall
that we can give away. Where a competitor's feature exists only to serve an account funnel, saying
so *is* the finding, and here the funnel is the runtime itself.

### Copy — two ideas, both small

- **Event-based port forwarding.** Their architecture page names it, and our `PortForwarder` already
  discovers through `GET /events` (`PortForwarder.swift:8-26`). Nothing to build; worth confirming we
  have no polling fallback anywhere and saying so.
- **The `OrbStack-Server-Detection` port probe** — guessing a container's listening port by asking
  rather than reading `EXPOSE`. Already recorded as belonging in DIF-4's spec
  ([CAPABILITY-GAP.md](CAPABILITY-GAP.md) §2); repeated here so it does not get lost.

---

## Ranked: what changes a user's day

Frequency × cost, the same axis the companion documents rank on. Novelty scores nothing. Items
already ranked in [CAPABILITY-GAP.md](CAPABILITY-GAP.md) are not repeated.

1. **Publish the numbers we already measure (UX-30).** Four of eight `MorbBench` rows have targets
   and no measured value — including both filesystem benchmarks, which are the ones this entire
   market argues about, and `resume`. Our headline cold-boot figure is two log lines in a document
   that warns against citing it. Everything in §1, §4 and §7 turns on this, it is already built, and
   it is one machine-lane pass. Highest ratio on the page.
2. **Measure whether the memory balloon returns pages to macOS (UX-29).** The memory analogue of
   TECH-3, which we ran and won. One afternoon decides whether UX-17 shipped a capability or a
   no-op, and until it is answered we cannot say anything about memory at all.
3. **Rosetta AOT caching (UX-28).** A real speedup on the repeated-launch case, available to us
   *because* we stayed on Apple's framework, closed to OrbStack, off-by-default at Docker. Lima has
   shipped the pattern since 2024. Needs a guest-side `rosettad` in the right namespace, so it is a
   week rather than an hour.
4. **Fetch the Kubernetes payload instead of shipping it (UX-31).** 123 MB — a third of the download
   — for a feature that is off by default, extending an argument `mkinitramfs.sh` already makes
   about the same two binaries by exactly one hop. No capability lost, two fewer nested binaries in
   the signing order.
5. **Say the structural things out loud.** Lazy boot (the honest startup number is often zero), the
   three-copy path buying an unpatched dockerd, disk reclaim on every stop, and no license server.
   These are all shipped and all invisible. Not a build; folds into the README and comparison copy.

**Deliberately not building:** a custom VMM, a custom filesystem protocol, morbnet as a performance
project, and competing benchmark charts (§8).

**The precondition, restated because it has not changed.** SP-9 is open and there is still not one
`notarytool` call in the repo. Every number on this page is worth nothing until somebody other than
the author can open the app.
