# Architecture

Status: M0. This document describes the target architecture Morbstack is
building toward and which pieces exist at milestone M0. Where a component
is not yet implemented, it is marked accordingly. All four M0 functional
gates pass: the boot gate (`docker run --rm hello-world` against a
cold-started daemon), published ports reachable from the Mac, container
outbound networking, and disk persistence across a `morb stop`/`morb
start` cycle, plus `docker compose up -d` against a multi-service project.
See [`../README.md`](../README.md) Status section and
[`roadmap.md`](roadmap.md) for exactly what that does and does not cover.

## What Morbstack is

Morbstack is a Docker Desktop replacement for macOS. It runs unmodified
upstream Moby inside a single lightweight Linux VM, managed via Apple's
`Virtualization.framework` — `dockerd` and `containerd`, stock, no
downstream engine patch. Published ports (including `docker run -P`) reach
the Mac through a small Morbstack userland proxy, invoked via dockerd's own
stock `--userland-proxy-path` flag (`guest/morbinit/src/proxy_wrapper.rs`;
see §3.6 of `protocol.md`) — and does all product differentiation on the
macOS side: native SwiftUI host app, fast VM lifecycle, host-integrated
filesystem sync, host-integrated networking and DNS, and first-class Apple
platform features (App Intents, MCP). It is not a from-scratch container
runtime — the guest is boring, unmodified Docker, on purpose (see "The
load-bearing decision" below).

## System diagram

```
                              macOS host
  ┌───────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │   ┌────────────────┐        ┌──────────────────────────────┐       │
  │   │ Morbstack.app   │        │        morb (CLI)             │       │
  │   │ (SwiftUI, later)│        │  talks to morbstackd.sock      │       │
  │   └────────┬────────┘        └───────────────┬────────────────┘       │
  │            │ daemon control IPC (NDJSON)      │                       │
  │            └──────────────────┬───────────────┘                       │
  │                                ▼                                      │
  │                    ┌───────────────────────────┐                      │
  │                    │       morbstackd           │                      │
  │                    │  (Swift, launchd agent)    │                      │
  │                    │                             │                      │
  │                    │  - VM lifecycle (vz)        │                      │
  │                    │  - socket activation         │                      │
  │                    │  - docker.sock relay          │                     │
  │                    │  - PortForwarder (published    │                    │
  │                    │    ports, vsock 2376)           │                   │
  │                    │  - morbnet / morbdns (later)  │                     │
  │                    │  - FSEvents bridge (later)     │                    │
  │                    └──────┬───────────┬───────────┘                     │
  │                           │           │                                 │
  │        docker.sock        │           │  vsock (control: 1024,          │
  │   (~/.morbstack/run/)      │           │  docker API relay: 2375,        │
  │            ▲                │           │  stream-dial: 2376)             │
  │            │                │           ▼                                 │
  └────────────┼────────────────┼──────────────────────────────────────────┘
               │                │
     local Docker CLI /   ┌─────▼──────────────────────────────────────────┐
     Docker Engine API    │              Linux guest VM                    │
     clients               │        (Virtualization.framework)              │
                           │                                                  │
                           │   morbinit (PID 1, static Rust, boots as /init  │
                           │   from an initramfs — see "M0 boot path" below) │
                           │     - vsock control server (MRB0, port 1024)    │
                           │     - vsock stream/datagram dialers (2376/2378) │
                           │     - userland-proxy wrapper dials host 2382    │
                           │       per published port (port lease)          │
                           │     - supervises services below                 │
                           │                                                  │
                           │   containerd ── dockerd                         │
                           │   (Engine BuildKit via dockerd; no standalone   │
                           │    buildkitd supervisor is needed)               │
                           │                                                  │
                           │   /var/lib/docker on /dev/vda (ext4, or btrfs   │
                           │   when the kernel supports it) — overlay2;      │
                           │   tmpfs + vfs fallback only if disk unusable    │
                           │   VirtioFS mounts (bind mounts, tier 1) — M1+   │
                           │   Rosetta binfmt (amd64) — M1+                  │
                           │                                                  │
                           │   kata-containers 6.18.15 arm64 kernel (M0);    │
                           │   target: LTS kernel tuned for Morbstack        │
                           └──────────────────────────────────────────────────┘
```

Host-side persistent state lives under `~/.morbstack/`:
`config.toml` (settings), `run/docker.sock` + `run/morbstackd.sock`
(Unix sockets), `data/disk.img` (sparse raw guest disk — blank until the
guest's first boot, which formats it in place; see "Guest data root"
below), `data/vmstate.bin` (vz save/restore snapshot), `data/kernel/vmlinux`
(guest kernel image), `data/kernel/initrd.img` (M0's guest initramfs — see
below), `data/save-restore-unsupported` (marker written once a
suspend-to-disk restore has failed, so later suspend/resume cycles skip
straight to the degraded graceful-stop-plus-cold-boot path instead of
retrying a restore known to fail — see "VM lifecycle" below),
`logs/daemon.log` + `logs/console.log`.

## Components

### macOS side

- **Morbstack.app** (SwiftUI, later milestone) — menu bar presence,
  settings, container/image browser. Not part of M0.
- **morbstackd** — a Swift `launchd` agent, the single process that owns
  the VM's lifecycle end to end: booting/suspending/resuming/stopping the
  VM via `Virtualization.framework`, socket-activating the Docker API
  relay so the guest doesn't need to be running for the socket to exist,
  relaying `~/.morbstack/run/docker.sock` traffic to the guest's `dockerd`
  over the vsock Docker API port (2375), and mirroring published container
  ports onto `127.0.0.1` via `PortForwarder`, which dials the guest over
  vsock port 2376 per accepted connection (see `docs/protocol.md` §3.2), and
  serving the port-lease listener on vsock port 2382 that the guest's
  userland-proxy wrapper connects to for every published port (see
  `docs/protocol.md` §3.6). In
  later milestones this same process grows `morbnet` (userspace network
  stack), `morbdns`, and the FSEvents -> inotify bridge.
- **morb** — the CLI. Talks to `morbstackd` exclusively over the daemon
  control IPC socket (`morbstackd.sock`); never talks to the guest
  directly.

### Guest side

- **Kernel — M0 actual vs. target.** M0 boots a stock, unmodified
  `kata-containers` 3.28.0 arm64 release kernel (vmlinux 6.18.15), fetched
  and hash-pinned by `scripts/fetch-guest-assets.sh`. It was not built or
  configured by this project. The target described in earlier drafts of
  this document — an LTS kernel with a config forked from Apple's
  Containerization project, tuned for Morbstack (virtio devices, btrfs,
  binfmt_misc) — remains the plan for when Morbstack needs kernel config
  changes the kata build doesn't already cover (e.g. shipping `iptables`,
  see below); M0 didn't need to fork a kernel to hit the boot gate, so it
  didn't.
- **morbinit** — a statically linked Rust binary that runs as guest PID 1,
  as `/init` inside a gzipped-newc cpio initramfs (see "M0 boot path"
  below — this differs from a disk-root boot, which morbinit also
  supports as `/sbin/morbinit` via `MorbConfig.BootMode.disk`, but M0
  always has an initramfs available so that mode is the one actually
  exercised). Responsible for: early guest bring-up (mount `/proc` `/sys`
  `/dev` `/run` `/tmp` cgroup2, opportunistically mount `/dev/vda`),
  bringing up `eth0` + DHCP, starting and supervising `containerd` and
  `dockerd` (not a separately supervised `buildkitd` — see below), and serving the vsock control
  channel (MRB0 framing in M0; see `docs/protocol.md`).
- **containerd + dockerd** — static Docker 29.7.1 aarch64 release binaries,
  archive-hash-pinned. Both `containerd` and `dockerd` are unmodified
  upstream, with no downstream Morbstack patch. `dockerd` is started with
  `--userland-proxy-path` pointed at `morbstack-docker-proxy`, a multi-call
  symlink to `morbinit` (`guest/morbinit/src/proxy_wrapper.rs`); dockerd
  execs it once per published port — including `-P`/`EXPOSE`-derived
  dynamic allocations, which only dockerd can resolve — and the wrapper
  leases the Mac-side endpoint from the host before exec'ing the stock
  `docker-proxy`, so publishing depends on this stock hook rather than a
  patched build. See §3.6 of `docs/protocol.md`. Morbstack does not
  otherwise fork or reimplement the Docker Engine.
  `supervisor.rs`'s service table (`default_services`) starts exactly
  two services, `containerd` and `dockerd`; it intentionally does not
  supervise a separate `buildkitd` daemon. That is not a classic-builder
  fallback: the selected upstream dockerd exposes the Engine BuildKit path,
  which the recorded live parity run exercised through `docker buildx` with
  cache mounts and a multi-platform `--load` build. The signed app bundles
  the matching upstream Buildx client plugin. A user-selected Buildx
  `docker-container`, remote, or Kubernetes builder is still an ordinary
  Engine workload/client connection and must be validated separately before
  it is claimed as release evidence.
- **Guest data root.** `/dev/vda` (backed by `disk.img` on the host) is
  formatted the first time it's seen blank and mounted at
  `/var/lib/docker` before dockerd starts (`disk.rs`, called from
  `main.rs` as `disk::provision`), so images and containers survive a
  `morb stop`/`morb start` cycle. "Blank" is decided by reading the first
  1 MiB of the device and requiring it to be all zeros — both ext4's
  primary superblock (at byte 1024) and btrfs's primary superblock (at 64
  KiB) fall inside that window, so this is a real "has this disk ever been
  formatted by us" check, not a guess. A disk that's already been
  formatted is mounted as-is and logs "already holds data — mounting
  as-is"; morbinit never runs `mkfs` against a non-blank device, no matter
  which filesystem it finds there.

  Filesystem choice is btrfs first, then ext4, but **only among
  filesystems the running kernel actually supports** — `disk.rs` reads
  `/proc/filesystems` before choosing a candidate (an unreadable
  `/proc/filesystems` is treated as "assume everything is supported,"
  since refusing to format is a worse failure mode than a `mkfs` that then
  fails at mount time). The M0 kata-containers kernel has no btrfs driver,
  so on every fresh install this probe logs "kernel has no btrfs support —
  skipping it" and goes straight to ext4 rather than paying for a
  `mkfs.btrfs` run whose result can never mount — btrfs support in
  `disk.rs` is real and exercised by tests against a kernel that does
  support it, it's just never the winning candidate on the kernel M0
  actually ships. `mkfs.btrfs`/`mkfs.ext4` binaries themselves come from
  the `btrfs-progs`/`e2fsprogs` Alpine packages staged into the initramfs
  by `scripts/mkinitramfs.sh` (see "M0 boot path" below) — the *fsutils*
  package group, not part of the earlier Docker/Alpine/kernel asset
  classes.

  **Capacity changes are deliberately grow-only and not implemented as a
  host-file shortcut.** `disk.img` is a RAW
  [Virtualization disk-image attachment](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment):
  its file length maps one-to-one to the guest block device, but extending
  that file does not extend the ext4 or btrfs filesystem mounted inside the
  guest. `disk_size_gib` consequently remains a first-creation setting.
  `morb disk status` and Settings use `MorbDiskCapacity` to report the
  current RAW capacity and explicitly flag a larger configuration as
  requiring a guest resize; they never mutate the image. A future grow
  operation must (1) prove the VM and any saved state have been released,
  (2) grow the RAW image only, (3) identify the mounted guest filesystem,
  and (4) receive a successful in-guest resize confirmation before it
  reports the capacity changed. ext4's kernel interface requires a resize
  operation beyond exposing more blocks, and btrfs documents its mounted
  `filesystem resize max` operation separately
  ([ext4](https://docs.kernel.org/admin-guide/ext4.html),
  [btrfs](https://btrfs.readthedocs.io/en/stable/btrfs-filesystem.html)).
  Shrinking is out of scope permanently: it can relocate or discard live
  filesystem data, so Morbstack will never truncate an existing disk image.

  Once mounted, dockerd runs with `--storage-driver overlay2`
  (`supervisor::default_services(docker_data_on_disk)` switches on exactly
  this flag). If no usable disk is available at all — the attach failed,
  or formatting failed — morbinit falls back to what M0 originally always
  did: `/var/lib/docker` on a `tmpfs` (capped at half of guest RAM, chosen
  over leaving it on the initramfs's own `rootfs`, which is an unbounded,
  unswappable ramfs that would let a large `docker pull` OOM the guest),
  with dockerd started `--storage-driver vfs` since overlay2 cannot stack
  on tmpfs/rootfs. This fallback is correct but slow and space-hungry, and
  everything on it is lost on the next stop — it is a degradation path,
  not the expected case, but it keeps the guest bootable rather than
  refusing to start when the disk can't be used. Either way, morbinit
  reports which path it took as `docker_data_on_disk` on the MRB0 `info`
  reply (see `docs/protocol.md` §1) so the host — and `morb doctor` — can
  tell the user the truth about persistence instead of assuming it.

  What's still ahead of M0 here: mounting the formatted disk at `/` and
  `switch_root`-ing into it, rather than only mounting it at
  `/var/lib/docker` underneath the initramfs's tmpfs root. That's tracked
  as a later item and also fixes a second thing at the same time: it would
  restore a real `pivot_root`-based container root (see `DOCKER_RAMDISK`
  below) instead of the weaker chroot-based fallback M0 still uses,
  because morbinit's own root filesystem — not just `/var/lib/docker` —
  would then have a parent to pivot away from.
- **`DOCKER_RAMDISK=1`** — set in dockerd's environment
  (`supervisor.rs`) because morbinit's `/` is the kernel's initial
  `rootfs` mount, which has no parent and which `pivot_root(2)` therefore
  always rejects (`pivot_root .: invalid argument`), in every mount
  namespace cloned from it — independent of where `/var/lib/docker`
  itself lives. `DOCKER_RAMDISK` is Docker's own documented switch for
  exactly this "root filesystem is a ramdisk" situation; it propagates
  `NoPivotRoot` to the runc shim, which then isolates containers with
  `MS_MOVE` + `chroot` instead. Weaker than real `pivot_root` isolation
  (the old root stays reachable through stray file descriptors) — fixed
  by the same disk-root M2 work above, since a real root filesystem
  doesn't have this restriction.
- **Outbound container NAT.** The guest image ships the legacy-iptables
  frontend (`xtables-legacy-multi`, symlinked to the conventional
  `iptables`/`ip6tables`/`*-save`/`*-restore` names by
  `scripts/mkinitramfs.sh`) plus the `/usr/lib/xtables/libxt_*.so`
  match/target extension modules libxtables `dlopen()`s while parsing a
  rule — both come from Alpine's `iptables-legacy` and `iptables` apks
  respectively; only the latter's `usr/lib/xtables` subtree is staged (its
  `usr/sbin` is skipped, since that's the nft-backed frontend this project
  deliberately doesn't use). Without those extension modules present,
  dockerd crash-loops with `iptables v1.8.13 (legacy): Couldn't load match
  \`addrtype'` the moment it tries to program a bridge NAT rule that needs
  one — `/usr/lib/xtables` is frontend-agnostic, so this had nothing to do
  with the legacy-vs-nft choice, only with which apk actually ships that
  directory. `supervisor.rs` probes the usual install paths
  (`find_iptables`, trying `iptables`/`iptables-nft`/`iptables-legacy` in
  that order) and only falls back to `--iptables=false --ip6tables=false`
  if none of them is present, so the flag is a genuine fallback for a
  guest image built without the fsutils staged, not the M0 default. dockerd
  itself was never affected either way — it always reached the registry
  over the guest's own `eth0` regardless of container NAT — but containers
  now get a working NAT rule for their own outbound traffic, verified end
  to end (`docker run --rm alpine wget ... http://example.com` from inside
  a container). The kata kernel's netfilter/xtables support was already
  compiled in; this was purely a missing-userspace-binary problem.
- **VirtioFS** — tier 1 filesystem strategy for bind mounts (see
  Filesystem below). Not implemented in M0.
- **Rosetta binfmt** — registers Rosetta as the amd64 interpreter inside
  the guest so unmodified amd64 container images will run on Apple
  silicon hosts. Not implemented in M0; M1 per the roadmap.

#### M0 boot path

The kernel command line (`VZLinuxBootLoader.commandLine`, built by
`MorbConfig.resolvedKernelCmdline(for:)`) is mode-dependent and chosen
automatically by whether `~/.morbstack/data/kernel/initrd.img` exists
(`MorbConfig.detectedBootMode`) — an initramfs is preferred whenever one
is present, since it is the only mode that boots a guest with no prepared
root filesystem, which is the state of every fresh install:

- **initramfs mode (M0's actual path):**
  `console=hvc0 rdinit=/init` — no `root=`. The kernel runs morbinit as
  `/init` straight out of the initramfs; the rootfs lives entirely in RAM
  until/unless `/var/lib/docker` gets a real mount (see above).
- **disk mode (implemented, exercised by tests, not the M0 default path):**
  `console=hvc0 root=/dev/vda rw init=/sbin/morbinit` — boots morbinit off
  a formatted root disk instead. This is the shape the M2 disk-root work
  above will make the normal path; M0 keeps it working end to end (config
  parsing, `VMManager` boot-loader wiring) so that switch is a data-plane
  change, not a new code path to write from scratch.

`mise run guest-image` (`scripts/mkinitramfs.sh`) assembles the initramfs used
by the first path: cross-compiled `morbinit` as `/init`, the Alpine 3.24.1
aarch64 minirootfs, the static Docker 29.7.1 engine binaries under
`/usr/local/bin`, the fsutils group (`btrfs-progs`, `e2fsprogs`, and
`iptables-legacy` plus the `usr/lib/xtables` subtree of Alpine's plain
`iptables` apk — see "Outbound container NAT" and "Guest data root"
above), empty `/var/lib/docker` + `/run` + `/etc` scaffolding, and — if
present — a baked-in `dist/images/hello-world-oci.tar` under
`/usr/share/morb/` as an offline fallback payload (see
`scripts/fetch-image-oci.sh`; nothing in the guest currently loads this
file automatically — the offline boot-gate path today works by the host
streaming that same tarball over the relay and the guest's `docker load`
reading it from there, not by the guest self-loading its baked-in copy).
The result is packed as a gzipped newc cpio archive, matching what
`VZLinuxBootLoader.initialRamdiskURL` expects.

Every third-party input to that pipeline — the kernel, the Docker
binaries, the Alpine rootfs, the fsutils apks, and (a host-side, not
guest-image, asset) the `docker-compose` CLI plugin binary used for gate
G4 — is fetched and verified by `scripts/fetch-guest-assets.sh` against a
recorded, pinned provenance chain (archive URL, archive sha256, and — for
the kernel — the sha256 of the specific `vmlinux` member extracted from
the release archive; Alpine and its apks are verified against their own
CDN-published sha256 sidecars instead of an archive-hash pin, since Alpine
doesn't publish permanent versioned release URLs the way GitHub Releases /
`download.docker.com` do; `docker-compose` is verified the same
sidecar-sha256 way against its GitHub Release asset). The script is
idempotent — each step is skipped if its destination already exists and
still hashes correctly — and supports fetching a single asset class via
`--kernel-only` / `--docker-only` / `--alpine-only` / `--fsutils-only` /
`--compose-only`. `fetch-kernel.sh` is kept as a thin wrapper around
`--kernel-only` for anyone with the old command memorized; it carries no
pins of its own any more.

### Control plane

- **vsock** — the only channel between host and guest. The principal ports are:
  1024 (guest control, MRB0 framed), 2375 (Docker Engine API relay,
  unframed HTTP — see `docs/protocol.md` §3.1 for the relay's own design:
  one vsock connection per dockerd connection, half-close aware, no
  multiplexing), and 2376 (stream-dial: a one-line preamble naming a
  guest-local TCP port, then a raw splice — see `docs/protocol.md` §3.2;
  this is what makes published container ports reachable from the Mac,
  since unlike the Engine API there is no single well-known guest port to
  relay), 2378 (framed UDP datagram dial), and 2382 (host-side port lease:
  the guest userland-proxy wrapper asks the host to bind a published port;
  the registry's only guest-initiated channel — see `docs/protocol.md`
  §3.6). Ports 2379 (publish-all allocator) and 2380 (host-network listener
  probe) are both retired and must not be reused; see `docs/protocol.md`
  §3 for the full, current port registry.
- **MRB0 framed JSON** — the M0 guest control wire format (`ping`, `info`,
  `clock_sync`, `shutdown`). Deliberately simple and dependency-free so it
  can be implemented in Swift Foundation and Rust std with zero external
  crates/packages — the guest side (`jsonlite.rs`) is a hand-rolled parser
  restricted to flat objects (string/int/bool values, no nesting; see
  `docs/protocol.md` §4 for what that means for forward compatibility).
  `info`'s reply carries `docker_ready: bool`, `docker_data_on_disk:
  bool` and `userland_proxy: bool` beyond the two fields this document
  used to list (`morbinit_version`, `kernel`) — whether dockerd's Unix
  socket has accepted a connection yet (latched permanently true once it
  does), whether `/var/lib/docker` landed on the formatted disk rather
  than the tmpfs fallback (see "Guest data root" above), and whether
  dockerd kept its userland proxy, without which published ports are
  DNAT-only and the stream-dial path in `docs/protocol.md` §3.2 cannot
  reach them. The first two are parsed by the host's `GuestReply` decoder
  (`mac/Sources/MorbstackKit/GuestControl.swift`) and surfaced through
  `morb doctor`/`morb status`; `userland_proxy` is additive and currently
  guest-side only, logged as a boot warning when false.
  `clock_sync` is currently observe-and-log only: morbinit computes and
  logs the host/guest clock delta but does not call `clock_settime(2)`.
- **gRPC** (future) — `proto/morbstack/v1/control.proto` defines the
  target contract, including a `StreamEvents` RPC with no MRB0 equivalent
  today. Adopting it is gated on vendoring a gRPC toolchain for both Swift
  and Rust without breaking the offline-build requirement — not on
  protocol design; the shapes are already settled.

## The load-bearing decision: one shared VM, not per-container microVMs

Morbstack runs a single guest VM shared by every container, running
unmodified upstream `dockerd`/`containerd` inside it — no downstream engine
patch, published ports served through dockerd's own stock
`--userland-proxy-path` hook — rather than giving each container (or each
Compose project) its own microVM. This is the decision the rest of the
architecture is built around, and it is deliberate:

- **Compose networks and `--network container:x` need a shared kernel
  network namespace set.** Docker's networking model — user-defined
  bridge networks, containers sharing another container's network stack,
  `docker network connect` at runtime — assumes one kernel doing the
  namespacing. Splitting containers across separate microVMs means
  reimplementing all of that at a different layer (typically an overlay
  network), which breaks compatibility with tooling that pokes at
  `docker network` primitives directly (Testcontainers, Compose, DinD).
- **shm and other IPC-adjacent volume patterns need a shared kernel.**
  Some workloads (browser test runners, some ML serving stacks) rely on
  `--shm-size` and related shared-memory or IPC namespace behavior that
  is only meaningful within one kernel instance.
- **Page-cache sharing across containers matters for real workloads.**
  Multiple containers built from overlapping image layers benefit from
  the host (guest, in this case) page cache being shared, rather than
  each container paying for its own copy of that memory in an isolated
  microVM.
- **Memory density.** A microVM per container multiplies fixed per-VM
  memory overhead (kernel, guest agent, device buffers) by container
  count. On a laptop running a handful to a few dozen containers, that
  overhead is not negligible; a single shared VM pays it once.

The cost of this decision is that Morbstack does not get microVM-grade
isolation between containers for free — that is an explicit non-goal for
now (containers are isolated from each other the same way they are on
Linux Docker: kernel namespaces + cgroups + seccomp, not hypervisor
boundaries). Compatibility with the existing Docker ecosystem was judged
more valuable than that isolation property, since Docker itself doesn't
provide VM-grade isolation between containers on Linux either — Morbstack
is matching upstream Docker's isolation model, not weakening it.

## The five differentiation domains

Everything Morbstack does *beyond* "run Docker Engine in a VM" falls into
one of five domains:

### 1. VM lifecycle

Target behavior: **suspend-to-zero** when idle (the VM is fully suspended,
consuming no CPU and minimal resident memory, snapshotted to
`vmstate.bin`), **socket-activated resume in ~500ms** when a client
touches `docker.sock` or the CLI is invoked, and a **2s cold boot target**
when there's no snapshot to resume from at all (first run, or after an
update to the kernel/morbinit). This is the biggest single lever on the
public perf targets (see `docs/roadmap.md`) and is owned by `morbstackd`.

M0 measurements from an isolated `MORBSTACK_HOME` functional-gate run on
one development machine, Apple silicon — not yet the CI-gated `morb bench`
numbers `docs/roadmap.md` describes for M2+, but real end-to-end timings
against the current build: a cold, socket-activated `docker run --rm
hello-world` (daemon just launched, no VM booted yet) completes in 2.09s
wall clock, with the guest reaching a ready MRB0 control socket 1.69-2.01s
after VM bring-up and guest-reported uptime around 660-720ms at that
point. `morb stop` takes 0.25-0.40s; a subsequent socket-activated cold
boot back to a responsive `docker ps` takes 1.69-1.73s, repeatable across
multiple stop/start cycles with zero ERROR/WARN log lines. First-boot disk
formatting (`mkfs.ext4`, since the M0 kernel has no btrfs — see "Guest data
root" above) takes 22ms, mounted 56ms after that; a real registry pull of
`alpine` takes 1.95s.

Auto-suspend today is implemented as a graceful `stop` rather than a true
suspend-to-zero snapshot/restore, because `Virtualization.framework`'s
`restoreMachineStateFrom` does not work for a direct-kernel-boot guest like
Morbstack's on this host — this is a documented limitation of that API for
this boot mode, not a bug in Morbstack's use of it, and Morbstack does not
attempt to work around it. The degradation path is itself fast and safe: a
failed or unavailable restore is detected once, recorded at
`~/.morbstack/data/save-restore-unsupported` so later suspend attempts
skip straight to it, and the VM cold-boots instead. Observed end to end
with `auto_suspend_minutes=1` set: the idle timer (30s granularity) fired
at "idle for 86s; suspending," the guest acknowledged and powered off in
384ms, and the next socket-activated command woke a fresh VM in 2.13s.

### 2. Filesystem

Three tiers, increasing in ambition:

- **Tier 1 (current): tuned VirtioFS.** Bind mounts
  (`-v /host/path:/container/path`) go over VirtioFS, tuned for the common
  case (source code trees, node_modules, build caches). Host-written bytes are
  coherent, but host-originated Linux watch notifications are not implemented:
  the guest has no receiver/kernel delivery mechanism and the host does not
  start FSEvents. Tools that require notifications still need polling. See
  [`live-share-bridge.md`](live-share-bridge.md) for the bounded transport
  design and unblock criteria.
- **Tier 2 (M1/M2): free synced shares.** An opt-in synced-copy mode
  (rather than live-mount) for workloads where VirtioFS's consistency
  model or performance profile doesn't fit, modeled on (but not identical
  to) Docker Desktop's synced-shares feature — offered at no extra cost.
- **Tier 3 (post-1.0): morbfs.** A purpose-built filesystem protocol
  replacing VirtioFS for the bind-mount path, once tiers 1-2 have
  surfaced what actually needs fixing.

### 3. Networking

- **morbnet** — a userspace network stack forked from
  `gvisor-tap-vsock`, giving containers outbound connectivity without
  requiring host admin privileges or a kernel extension.
- **morbdns** — a DNS resolver that honors macOS's *scoped* resolver
  configuration (per-interface/per-domain resolvers set via
  `/etc/resolver`), so corporate VPN split-DNS setups keep working for
  containers the way they do for host processes.
- **`*.morb.local` domains** — stable, memorable hostnames for running
  containers/services.
- **Name-constrained local CA HTTPS** — a locally trusted CA scoped (via
  X.509 name constraints) to `*.morb.local`, so container services can be
  reached over HTTPS in local development without a CA that could be
  abused to mint certs for arbitrary domains.
- **Host-routable container IPs** — container IP addresses reachable
  directly from the host, not just via published ports.

### 4. amd64 (x86_64 containers on Apple silicon)

- **Rosetta binfmt (today, M0)** — Rosetta registered as the amd64
  interpreter inside the guest.
- **qemu fallback (registration code only; inert today)** — when the Rosetta
  share is absent (Rosetta not installed, `rosetta = false`, or an Intel Mac),
  `binfmt.rs` looks for `qemu-x86_64-static`/`qemu-x86_64` on the guest `PATH`
  and registers it with the same magic, mask and flags. **The initramfs ships
  no such binary**, so this path always reports `Amd64Binfmt::None` and
  `--platform linux/amd64` fails with `exec format error` on a machine without
  Rosetta. Dropping a static `qemu-x86_64` into the image is the only change
  needed to light it up (`guest/morbinit/src/binfmt.rs:52-60`, `:147`). Do not
  read this bullet as a shipped capability.
- **FEX-Emu contingency** — held in reserve in case Apple sunsets Rosetta
  for this use case; FEX-Emu is the fallback translation layer if that
  happens.

### 5. Host integration

- **SwiftUI only, zero web views.** The host app is native AppKit/SwiftUI,
  not an embedded browser — this is a hard constraint, not a preference,
  for both performance and platform-integration reasons.
- **MCP server** — expose Morbstack's state and actions (containers,
  images, logs) to MCP clients.
- **App Intents** — Shortcuts/Spotlight/Siri integration for common
  actions (start/stop a container, open a project's compose stack).
