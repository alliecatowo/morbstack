# Morbstack

**The Docker you wish Docker shipped.**

Morbstack is a free, Apache-2.0, drop-in replacement for Docker Desktop on
macOS. It runs unmodified upstream `dockerd`/`containerd` inside a single
shared, lightweight Linux VM powered by `Virtualization.framework` — and
everything else is thin, native, mac-side glue. Fast to boot, light on
battery and memory, no license nags, no accounts, no telemetry.

## Status: pre-alpha (past milestone M0, Kubernetes support landed) — the hello-world gate, the four functional gates, and Kubernetes all pass

M0's goal (per [`docs/roadmap.md`](docs/roadmap.md)) is "prove the core bet
— unmodified Docker Engine, one shared VM, fast boot — actually works
before investing in the surrounding product." **That gate is passed**, so
are the four functional gates added on top of it — published ports,
container outbound networking, disk persistence across a restart, and
`docker compose up -d` against a two-service project — and so, as of this
pass, is a local Kubernetes cluster (`morb k8s`, pulled forward from M2;
see [`docs/k8s.md`](docs/k8s.md)). All are proven end to end, from the
Mac, against a cold-started daemon:

```sh
DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock docker run --rm hello-world
```

prints the hello-world banner and exits 0 — verified repeatedly, including
from a fully cold start (daemon just launched, no VM booted yet, no image
present) via socket activation alone. Both a real registry pull (the
default path: DHCP + DNS + an outbound `docker pull` from Docker Hub inside
the guest) and an offline preload path (`docker load -i
dist/images/hello-world-oci.tar` on a VM with no network use) pass
independently.

It is still not something you run containers with day to day: there is no
host app yet, no `morb.local` DNS, and no UDP port forwarding (see "What
doesn't work yet" below). Bind-mount filesystem sharing does work (see the
VirtioFS bullet below) but has real, documented limits — no inotify across
the mount, and a fixed host-user-maps-to-container-root ownership model —
covered in [`docs/sharing.md`](docs/sharing.md) rather than glossed over
here.

**What works today:**

- The repo builds end to end (`make build`) with no external dependencies —
  Swift std/Foundation and Rust std only, so it builds offline.
  `make test` runs both suites (617 Swift tests, 190 Rust tests as of this
  writing) with zero failures, `cargo clippy` clean, no warnings.
- `morbstackd`, the host daemon: `Virtualization.framework` VM lifecycle
  management (boot, stop, suspend, resume) and socket-activation-style
  boot-on-demand — the VM starts on first connection to `docker.sock`, not
  at daemon launch, and a suspended VM resumes on the next `docker`
  command. Socket-activated cold start is ~1.4-2.1s wall clock to a usable
  Docker API.
- A `docker.sock` vsock relay: a Unix socket at
  `~/.morbstack/run/docker.sock` that forwards the Docker Engine API to the
  guest over vsock port 2375 as a byte-for-byte proxy, so existing Docker
  clients and tooling work unmodified. See
  [`docs/protocol.md`](docs/protocol.md) §3.1 for the wire-level design.
- **Published ports.** `docker run -d -p 8080:80 nginx` followed by `curl
  http://127.0.0.1:8080` from the Mac reaches the container. The host's
  `PortForwarder` watches the Engine API's container events, opens a
  loopback-only (`127.0.0.1`, never `0.0.0.0`) listener per published port,
  and splices each accepted connection to the guest over a dedicated vsock
  stream-dial (port 2376, one connection per client — see
  [`docs/protocol.md`](docs/protocol.md) §3.2). `docker rm -f` tears the
  Mac-side listener down cleanly.
- **Container outbound networking.** Containers reach the network, not just
  `dockerd` itself — `docker run --rm alpine wget -qO- http://example.com`
  works. Outbound NAT is programmed by dockerd's own `iptables` calls
  against the guest's bridge; the guest image ships the legacy-iptables
  frontend plus the `/usr/lib/xtables` match/target extension modules it
  dlopens at rule-parse time.
- **Persistent guest storage.** `/dev/vda` is formatted on first boot
  (ext4, or btrfs when the running kernel actually supports it — probed via
  `/proc/filesystems` rather than assumed from which `mkfs` binary is
  present) and mounted at `/var/lib/docker`, so images and containers
  survive a `morb stop` / `morb start` cycle. dockerd runs `overlay2` once
  the disk is mounted, falling back to `vfs` on tmpfs only when no usable
  disk is available. `morb doctor` and the MRB0 `info` reply both expose
  whether a given boot actually landed on disk (`docker_data_on_disk`).
- **`docker compose up -d`.** The standard `docker compose` CLI plugin
  (fetched to `dist/host-bin/docker-compose`, a real `docker/compose`
  release binary — not reimplemented) drives the relayed Engine API the
  same way it would drive any other Docker host: multi-service projects,
  `depends_on: condition: service_healthy` gating, `docker compose down`
  cleanup. See "Running" below for the one-time plugin install step.
- `morb`, the CLI for controlling the daemon (start/stop/status/suspend/
  resume/version), plus `morb shares` and `morb rosetta` for the two
  capabilities whose failures are otherwise invisible — a configured-but-
  unmounted share makes a bind mount read an empty directory rather than
  raise an error, and a missing Rosetta makes an amd64 image fail with
  `exec format error` and nothing else. Both are read-only and, like
  `status`, never start a daemon in order to answer. `morb rosetta
  install` is the one mutating subcommand: it prints exactly what it will
  do, then asks. There is no `--force` and no other flag that skips the
  prompt, because macOS presents Apple's Rosetta licence to whoever is at
  the keyboard and accepting it is not Morbstack's to do —
  `--print-plan` prints the plan and exits for anyone who wants to read it
  first. Plus `morb doctor` for host readiness checks (code
  signing, kernel/initramfs presence, disk persistence status, and a
  `docker-credentials` check: Docker Desktop writes `credsStore: "desktop"`
  into `~/.docker/config.json`, and `docker-credential-desktop` hangs
  forever when Desktop isn't running and isn't in scope for uninstall, so
  `morb doctor` flags it and suggests the fix rather than letting the first
  `docker pull` hang silently — see Troubleshooting below). `morb stop`,
  `morb status`, and `morb suspend` never auto-start a daemon just to
  answer or act on a request; only `start` and `resume` do, since bringing
  the daemon up is the whole point of those two. `morb doctor` and `morb
  reset-disk` go further and never talk to a daemon they might spawn at
  all — they answer for themselves, which is the point of both.
- `morb reset-disk`, the escape hatch for a Docker data disk that is
  beyond repair. It deletes `~/.morbstack/data/disk.img` and nothing else,
  so the next boot creates and formats a fresh one; images, volumes and
  containers are gone, and it says so before asking. It refuses while the
  VM is running — the disk is attached to a live guest — and it refuses on
  a non-interactive stdin unless you pass `--force`, so a script cannot
  destroy a disk by accident. It probes the control socket directly rather
  than going through the normal client path, so asking whether it is safe
  to delete the disk can never be the thing that boots a VM onto it.
- **Suspend, with an honest fallback.** `morb suspend` (and the idle
  auto-suspend timer, when `auto_suspend_minutes` is set) asks the VM to
  suspend to disk. `Virtualization.framework`'s `restoreMachineStateFrom`
  does not currently work for a direct-kernel-boot guest like Morbstack's
  on this development setup, so a restore that fails degrades safely and
  automatically to a graceful stop plus a fast cold boot on the next
  command — never a hang or a corrupted VM. Morbstack detects this once
  and records it at `~/.morbstack/data/save-restore-unsupported`, so
  subsequent suspend/resume cycles skip straight to the degraded path
  instead of retrying a restore known to fail. See "VM lifecycle" in
  [`docs/architecture.md`](docs/architecture.md) for measured timings.
- `morbinit`, the guest-side PID 1 (Rust): mounts, network bring-up,
  supervises `containerd` + `dockerd` with restart/backoff, and serves the
  MRB0 control protocol (ping/info/clock_sync/shutdown) over vsock port
  1024, plus the stream-dial protocol over vsock port 2376.
- A prebuilt, provenance-pinned guest image pipeline: `make guest-image`
  cross-compiles `morbinit` for `aarch64-unknown-linux-musl` and assembles
  it, the Alpine 3.24.1 minirootfs, the static Docker 29.7.1 engine
  binaries, and the `iptables-legacy`/`btrfs-progs`/`e2fsprogs` userspace
  needed for NAT and disk formatting into a gzipped-newc initramfs
  (`~/.morbstack/data/kernel/initrd.img`). `scripts/fetch-guest-assets.sh`
  fetches and hash-verifies every one of those third-party inputs, plus the
  vz-bootable kernel and the host-side `docker-compose` CLI plugin binary,
  from pinned source URLs (see the script for the full digest chain).

- **VirtioFS bind mounts.** `-v /host/path:/container/path` works for any
  path under a shared root (`/Users`, `/Volumes` and `/private/tmp` by
  default; set `shared_paths` in `config.toml` to change it). A shared
  directory appears inside the guest at *exactly the same absolute path*
  it has on the Mac, so nothing rewrites a `-v` argument and compose files
  stay portable between Morbstack and any other Docker host. `morb shares`
  lists the roots and whether the guest actually mounted each one. See
  [`docs/sharing.md`](docs/sharing.md).
- **amd64 images, via Rosetta.** `docker run --platform linux/amd64 alpine
  uname -m` prints `x86_64` on Apple silicon. Rosetta is exposed to the
  guest as a VirtioFS share and registered in `binfmt_misc` with the `F`
  flag, which pins the interpreter at registration time in the init
  namespace — so amd64 images need no share, no interpreter binary, and no
  cooperation of any kind inside the container image. Verified beyond
  "the process started": `mysql:5.7`, which publishes *no* arm64 manifest,
  boots a real server and its `SHA2('morbstack',256)` comes out
  bit-identical to the host's `shasum`. `morb rosetta` reports the state
  and `morb rosetta install` sets it up. Measured cost: no container-start
  penalty, roughly 1.8-2x slower for general-purpose compute, and up to
  ~5x slower for code that leans on CPU-specific instructions (e.g. AES/SHA
  extensions) that native arm64 has and translated amd64 does not. See
  [`docs/amd64.md`](docs/amd64.md).
- **A local Kubernetes cluster, on the same Docker Engine.** `morb k8s
  enable` streams the k3s + cri-dockerd payload into the guest
  (sha256-verified, skipped if already present) and starts a single-node
  cluster wired to the same `dockerd` every other Morbstack workload
  already uses — a `docker build` is immediately deployable with
  `imagePullPolicy: IfNotPresent`, no registry push. Off by default and
  zero-cost until enabled. Measured: 8.3s cold enable-to-Ready (about 4s
  once the payload is already installed), a `LoadBalancer` Service
  reachable from the Mac with `curl`, a clean `morb k8s disable` that
  leaves the engine working, and an idle cost of roughly +480 MB guest
  memory and +20 points of host VM-process CPU while enabled with nothing
  deployed. Kubeconfig goes to `~/.morbstack/kubeconfig`, never silently
  merged into `~/.kube/config`. See [`docs/k8s.md`](docs/k8s.md).

**What doesn't work yet:**

- **No UDP port forwarding.** The vsock 2376 stream-dial forwarder is
  TCP-only; a container publishing a UDP port is not reachable from the
  Mac.
- **No qemu fallback for amd64.** The binfmt plumbing for a qemu
  interpreter is written but inert — the guest reports
  `binfmt_amd64: "none"` for it — because no static `qemu-x86_64` ships in
  the guest image yet. Anything Rosetta cannot translate simply fails; it
  does not fall back.
- **No `morb.local` DNS/domains, no `morbnet`.** Containers get outbound
  NAT and nothing else — no stable per-container hostnames, no
  host-routable container IPs, no split-DNS integration.
- **No synced-share filesystem tier.** Sharing is live VirtioFS (tier 1)
  only; the opt-in synced-copy mode for workloads that do not suit
  VirtioFS's consistency model is M1/M2 per the roadmap.
- **No inotify across a VirtioFS bind mount.** A host-side edit is
  correct the instant you read it, but the change-notification event
  that a hot-reload watcher (`webpack --watch`, `nodemon`, etc.) depends
  on does not cross the boundary. See [`docs/sharing.md`](docs/sharing.md).

See [`docs/roadmap.md`](docs/roadmap.md) for the full list and milestone
sequencing.

## Architecture

```
┌──────────────────────────── macOS host ────────────────────────────┐
│                                                                    │
│   Morbstack.app (later)        morb (CLI)                          │
│            │                       │                               │
│            └───────────┬───────────┘                               │
│                        │  morbstackd.sock (JSON control IPC)       │
│                        ▼                                           │
│                 morbstackd (daemon)                                │
│                        │                                           │
│          ┌─────────────┼─────────────┬─────────────┐               │
│          │             │             │             │               │
│  Virtualization    docker.sock   PortForwarder      │               │
│  .framework        (vsock relay) (published ports)  │               │
│          │             │             │             │               │
└──────────┼─────────────┼─────────────┼─────────────┼───────────────┘
           │             │             │  vsock port 1024: guest control (MRB0 framed JSON)
           │             │             │  vsock port 2375: Docker Engine API relay
           │             │             │  vsock port 2376: stream-dial (published ports,
           │             │             │                    and the Kubernetes API server)
           │             │             │  vsock port 2377: bulk payload install (k3s payload)
┌──────────▼─────────────▼─────────────▼─────────────────────────────┐
│                          guest Linux VM                            │
│                                                                    │
│   morbinit (PID 1, Rust)   ────── dockerd / containerd             │
│   mounts, supervisor,             (unmodified upstream Moby)       │
│   vsock control + dial server     overlay2 on /dev/vda (ext4/btrfs)│
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

- **Host**: `Morbstack.app` (menu bar UI, planned) and the `morb` CLI both
  talk to `morbstackd`, the daemon, over `morbstackd.sock` using
  newline-delimited JSON. `morbstackd` owns the VM's lifecycle via
  `Virtualization.framework`, relays the Docker Engine API from
  `~/.morbstack/run/docker.sock` to the guest over vsock, and mirrors
  published container ports onto the Mac's loopback interface.
- **Guest**: a minimal Linux environment where `morbinit` runs as PID 1 and
  supervises unmodified upstream `dockerd`/`containerd`, with `/dev/vda`
  formatted and mounted as `/var/lib/docker` whenever the kernel supports
  it.
- **Control protocol**: today, "MRB0"-framed JSON messages over vsock
  (4-byte magic + big-endian length-prefixed UTF-8 JSON) for host↔guest
  control (ping, info, clock sync, shutdown), plus a separate one-line
  handshake on vsock port 2376 for dialing arbitrary guest-local TCP ports
  (published container ports). A richer gRPC control plane is planned —
  see [`proto/`](proto/).

## Building

Requirements: Xcode 26+ (for Swift 6.3 and `Virtualization.framework`) and
[mise](https://mise.jdx.dev/). To build a bootable guest image from source
(`make guest-image`, below) you additionally need the
`aarch64-unknown-linux-musl` cross toolchain — see
[`dist/CROSS_COMPILE.md`](dist/CROSS_COMPILE.md) for the one-line Homebrew
recipe (the `messense/macos-cross-toolchains` tap). You do not need the
cross toolchain just to build and test the host/guest binaries for their
own dev-loop targets (`make build`/`make test` below use the host arch for
`morbinit`, which compiles and unit-tests fine on macOS since only the
Linux-only modules are `cfg`-gated out).

```sh
make setup   # mise trust + mise install — pulls the pinned Rust toolchain
make build   # builds morbstackd, morb, and morbinit (host-arch dev build)
make test    # runs the Swift and Rust test suites
```

## Running

This is the exact command sequence that gets you from a fresh clone to a
working `docker run`/`docker compose` setup against Morbstack.

Check that the host is capable, and see what setup is still outstanding:

```sh
./mac/.build/debug/morb doctor
```

Fetch and hash-verify the pinned guest kernel, the static Docker 29.7.1
engine binaries, the Alpine 3.24.1 minirootfs, the guest fsutils
(`iptables-legacy`, `btrfs-progs`, `e2fsprogs`), and the host
`docker-compose` CLI plugin binary — everything `make guest-image` and
`docker compose` need as raw material:

```sh
./scripts/fetch-guest-assets.sh
# or individually: --kernel-only / --docker-only / --alpine-only /
# --fsutils-only / --compose-only
# fetch-kernel.sh still exists as a thin wrapper for --kernel-only, kept
# for anyone with that command memorized.
```

Cross-compile `morbinit` and assemble the bootable initramfs (kernel +
morbinit-as-`/init` + Alpine rootfs + Docker engine binaries + fsutils)
into `~/.morbstack/data/kernel/initrd.img`:

```sh
make guest-image
```

Then start the daemon:

```sh
make run-daemon
```

This builds, ad-hoc codesigns `morbstackd` with the entitlements it needs
to open a VM, and runs it in the foreground. The VM does not boot yet at
this point — `morbstackd` publishes `docker.sock` and waits; the first
client connection is what boots it (socket activation). The root disk
image (`~/.morbstack/data/disk.img`) is created and formatted automatically
on first boot; `scripts/mkdisk.sh` can pre-create the sparse file, but
formatting itself only happens inside the guest, on first use.

In another terminal, point Docker tooling at Morbstack's relay socket:

```sh
export DOCKER_HOST=unix://$HOME/.morbstack/run/docker.sock
docker ps
docker run --rm hello-world
docker run -d -p 8080:80 nginx
curl -fsS http://127.0.0.1:8080   # nginx welcome page, from the Mac
```

(Or configure a `docker context` pointing at that socket.)

To use `docker compose`, install the fetched plugin binary where the
`docker` CLI's plugin resolver looks for it (a one-time step this repo
does not do for you — it only fetches and verifies the binary):

```sh
mkdir -p ~/.docker/cli-plugins
ln -sf "$(pwd)/dist/host-bin/docker-compose" ~/.docker/cli-plugins/docker-compose
docker compose version
```

Then `docker compose up -d` against any standard compose file works the
normal way. (nginx images ship `curl` but not `wget`; if you're writing a
healthcheck for a compose service based on one of the standard images,
`curl -fsS http://localhost/` is the portable choice — `/dev/tcp`-based
`CMD-SHELL` healthchecks don't work here because Compose's `CMD-SHELL` runs
`/bin/sh`, which is `dash` on Alpine/Debian-slim-derived images, and
`/dev/tcp` is a `bash` builtin, not a POSIX shell feature.)

## Troubleshooting

**`docker pull`/`docker run` hangs with no output for minutes.** Run `morb
doctor`. This is very likely the `docker-credentials` check: Docker
Desktop writes `"credsStore": "desktop"` into `~/.docker/config.json`, and
the standard `docker` CLI tries to shell out to `docker-credential-desktop`
for every registry auth lookup. That helper only works while Docker
Desktop itself is running — with Desktop absent, the CLI hangs waiting on
a process that never answers, and it looks like Morbstack is stuck instead
of Docker Desktop leftovers. Fixes: remove the `credsStore` line from
`~/.docker/config.json`, or point `DOCKER_CONFIG` at a directory with a
config that omits it. Morbstack never edits `~/.docker/config.json` for
you — `morb doctor` only flags the problem and suggests the fix.

**A curl to a published port comes back "connection refused" right after
`docker run -p`.** The forwarder needs the container's port binding to
show up in a `containers/json` refresh, which happens shortly after
`docker run` returns, not synchronously with it — retry after a moment.

**A published port answers nothing and `docker ps` insists it is
published.** Something else on the Mac already holds that host port, so
the forwarder could not bind it — a state `docker ps` cannot show you,
because as far as the engine is concerned the port *is* published. `morb
status` lists these under **unavailable ports** (`failed_port_forwards`
in `--json`), with the reason: `another process holds 127.0.0.1:8080;
will retry`. Quit whatever holds the port and the forwarder picks it up
on its own within about five seconds — it retries on a timer, not only on
Docker events, because the event that resolves the conflict happens on the
Mac and produces nothing for Docker to report. Repeated failures back off
from 5 s to a maximum of 60 s between attempts.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — how the pieces fit and
  why the load-bearing decisions were made that way.
- [`docs/sharing.md`](docs/sharing.md) — file sharing: the same-path rule,
  `shared_paths`, and why an unshared bind mount fails silently.
- [`docs/amd64.md`](docs/amd64.md) — running amd64 images through Rosetta,
  and what the qemu fallback does not yet cover.
- [`docs/protocol.md`](docs/protocol.md) — the vsock wire protocols.
- [`docs/compat.md`](docs/compat.md) — Docker API surface coverage.
- [`docs/k8s.md`](docs/k8s.md) — the local Kubernetes cluster: how it
  works, what was measured, and the case-sensitivity build bug this pass
  found and fixed.
- [`docs/roadmap.md`](docs/roadmap.md) — milestones.

## Roadmap

See [`docs/roadmap.md`](docs/roadmap.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

---

**Everything that runs on your machine is free forever.**
