# Linux Machines

Status: **M0 schema-only foundation is implemented; no machine runtime or UI exists yet.**

M0 is deliberately an inventory contract, not a partial VM feature. The pure
[MachineRegistry.swift](../mac/Sources/MorbstackKit/MachineRegistry.swift) model
accepts a strict `MachineImageManifest` and secret-free desired/observed machine
records, but cannot write images, download anything, start a VM, prepare a seed,
or expose a user command. Its only runtime answer is **unavailable** until M1 has
verified boot artifacts, NoCloud provisioning, and the separately-versioned
machine agent.

- A manifest's `image_digest` is a `sha256:` content identity of its complete v1
  boot/provisioning declaration: platform, distribution, agent protocol,
  NoCloud/SSH/VirtioFS expectations, each required artifact digest, provenance,
  and expiry. It is not a mutable release label or only the root-disk digest.
- The registry records machines by opaque UUID and associates them with that
  immutable image digest, never a Docker image, Docker disk, image path, or tag.
  M0 records have a stopped desired intent and an unavailable observation; neither
  represents a VM that exists.
- The document decoder rejects unknown fields at every schema level. The model has
  no field for cloud-init text, passwords, private keys, terminal output, Docker
  credentials, or security-scoped bookmark bytes. Selected share descriptors are
  declarative only and grant no filesystem access; M3 must acquire and review such
  access separately.
- Provenance is a declaration in M0, even when its stated result is `verified`.
  M1 must independently verify publisher material and every acquired artifact
  before any base becomes attachable.

## Decision

A Morbstack Linux machine is an independently addressed Virtualization.framework
machine with its own mutable disk, console, lifecycle, guest identity, and network
policy. It is never a mode or mutable reuse of the shared Docker VM.

- Docker remains one appliance: its singleton VMManager, disk image, morbinit,
  upstream dockerd, Docker-specific vsock relay, Kubernetes payload, and
  container-port forwarder.
- A machine receives none of Docker's disk, socket, Docker storage, guest MAC,
  saved state, shared paths, Kubernetes state, or port inventory.
- Machine create, start, stop, delete, export, and import cannot alter or observe
  Docker. Docker lifecycle cannot alter or observe a machine. This is an
  invariant, not a best-effort convention.

The current VMManager is intentionally Docker-specific. It directly boots
Morbstack's kernel/initramfs, runs morbinit as PID 1, owns one fixed-MAC VM and
one data/disk image, and uses vsock ports 1024, 2375, 2376, 2377, and 2378 for
Docker and Kubernetes contracts. Docker's broad, same-path VirtioFS shares exist
only to support bind mounts. See
[VMManager.swift](../mac/Sources/MorbstackKit/VMManager.swift),
[DirectoryShares.swift](../mac/Sources/MorbstackKit/DirectoryShares.swift), and
[protocol.md](protocol.md). Those constraints are reasons not to generalize it.

Machines instead need a registry and a supervisor with one serialized
Virtualization queue per machine UUID. Each image supplies its own compatible
kernel, initramfs, root disk, cloud-init support, and optional machine agent.
That agent contract is separately versioned even where a port number can be
reused inside another VM.

## Record, state, and image ownership

The declarative machine record contains only: opaque UUID, display name, native
architecture, base-image digest, hardware profile, network mode, selected share
descriptors, timestamps, and lifecycle state. It never contains a private SSH
key, password, raw cloud-init text, terminal transcript, or Docker credential.

- Machine images live under a content digest and contain an immutable manifest,
  kernel, initramfs, and base root disk. A verified base is never attached
  read-write.
- Each machine UUID owns its record, one mutable disk, a private console log,
  temporary NoCloud seed, redacted bootstrap receipt, and explicit export
  staging directory.
- All machine files and temporary artifacts are owner-only. The visible name is
  never a path component. A registry lock serializes create, delete, import,
  export, and image-cache cleanup.
- Creation makes a filesystem copy-on-write clone or full copy of a verified
  base into the individual disk. Never hard-link a writable disk or attach a
  base image read-write.

## Image provenance and compatibility

The first release supports one curated cloud-image family per host architecture.
A manifest is required before creation and contains:

- immutable upstream publisher URL and release, plus publisher verification
  result;
- architecture, distribution/cloud-init version, and guest-agent protocol;
- SHA-256 for kernel, initramfs, root disk, agent package, and seed-image input;
- SSH, VirtioFS, and cloud-init datasource expectations; and
- a compatibility key for virtual-device layout and boot assets.

The fetcher downloads privately, verifies publisher metadata when available and
every manifest digest, then atomically exposes a content-addressed cache. Bad,
unsigned, or unverified input is not attachable. A mutable “latest” label is
never identity. A new image has a new digest; existing machines retain their
recorded base until a separately reviewed migration exists.

Apple requires ARM64 Linux artifacts on Apple silicon and AMD64 artifacts on
Intel. A Virtualization.framework VM emulates a machine of the same architecture
as its Mac. Rosetta may later be opt-in for Intel user-space binaries in ARM
Linux; it is not x86 VM emulation and never permits an AMD64 root image on Apple
silicon.

User-imported images are later and explicitly less-supported. They require an
immutable local manifest and successful compatibility inspection, are labelled
**user supplied**, cannot overwrite a curated base, and receive no Morbstack
provenance claim. Docker images, Docker's live disk image, and machine disks are
not interchangeable formats.

## Cloud-init, SSH, and editor access

Curated images must include cloud-init’s
[NoCloud datasource](https://cloudinit.readthedocs.io/en/stable/reference/datasources/nocloud.html).
First boot attaches a private read-only CIDATA seed block with only metadata,
user data, and optionally network configuration. This offline seed needs no
metadata service or host listener.

Creation reviews a unique instance ID, hostname, user, public SSH keys, hardware
profile, network policy, selected shares, and optional cloud-config text/file.
Cloud-init can run root-level package installation, runcmd, and user changes;
user data is privileged first-boot automation, not a harmless toggle. Validate
size, encoding, and seed layout; display supplied input for review; retain only a
digest and redacted receipt. Never copy raw seed/user data into logs, support
bundles, normal CLI JSON, diagnostics, or default export.

Detach and remove the seed only after the guest agent proves completion for that
same instance ID. Otherwise report “provisioning unknown”, not a fake recovery.
Re-provisioning is a future stopped-machine action with a new ID and review.

SSH is a machine capability, not key escrow:

- Accept OpenSSH public keys only through cloud-init’s SSH authorized-keys
  mechanism; reject private-key text.
- Never generate, import, upload, rewrite, export, or back up private keys. The
  local SSH client uses the key the person already owns.
- Curated images disable password and root SSH login. Custom cloud-config can
  change guest policy, but remains visible privileged input.
- The agent reports the SSH host-key fingerprint through host-only control before
  Morbstack offers a standard SSH config snippet and known-hosts entry; never
  disable host-key checking.
- Enabling SSH binds one selected or random 127.0.0.1 port. The agent relays
  only to guest loopback port 22 and the endpoint disappears at stop. No
  all-interface listener and no Docker port reuse are allowed.

The resulting standard SSH target is the first editor integration contract. No
editor plugin, web terminal, or direct disk access is required.

## Networking modes

“Shared” means an explicit network relationship only. It never means Docker-state
sharing, inherited Docker networking, or a hidden LAN bridge.

| Mode | Behavior | Boundary |
| --- | --- | --- |
| **Isolated** | No guest Virtio network device; host-only Virtio socket remains for agent lifecycle control. | Default for untrusted-code sandboxes. No outbound network, LAN presence, SSH endpoint, or host share. Change mode only while stopped in phase 1. |
| **Connected (NAT)** | One NAT attachment gives guest outbound access. SSH remains the explicit loopback relay. | Default general-machine mode. NAT does not claim that LAN, host, or another VM can route to the guest. |
| **Private machine network** | Future explicit group using the vmnet network attachment. | Docker never joins. Membership, DNS, ingress, egress, and group deletion need a separate design. |
| **Bridged LAN** | Not initial scope. | Requires the VM-networking entitlement, interface selection, firewall/LAN disclosure, distribution approval, and per-machine consent. |
| **Custom data link** | Research only through the file-handle network attachment. | Morbstack owns raw packet, buffer, filter, and failure behavior; do not claim isolation until threat modeled and tested. |

NAT is the launch default because Apple describes it as indirect external access
and it needs no bridged-network entitlement. A detached running attachment makes
network state degraded; do not claim the VM stopped or silently change modes.

## Scoped file sharing

Machines start with **no** host share. A person adds one narrow folder at a time
through an open panel and explicit read-only/read-write choice.

- Use one single-directory VirtioFS share with a unique tag per folder; the
  curated agent mounts it at a stable machine-specific path. Never inherit
  Docker shared paths or its same-path mapping.
- Read-only is the default. Read-write requires review that guest processes can
  change the selected folder as the effective macOS user.
- Refuse root, broad user/volume roots, SSH or credential locations, duplicate
  or conflicting nested roots, non-directories, and unreadable paths.
- Phase 1 changes shares only while stopped, validates a fresh configuration,
  records host/guest paths, and does not promise hot attach or inotify delivery.
- Retain only access-scoping material required by the distribution model. A
  sandboxed app uses a security-scoped bookmark; a non-sandboxed daemon running
  as the user has product scope, not an OS-level sandbox. Say that plainly.

Apple VirtioFS honors the effective user’s access rights and ignores guest host
UID/GID changes. That does not replace narrow selection or read-only by default.
Isolated machines never gain a host share incidentally; future ingress/egress is
an explicit audited copy transaction.

## Lifecycle, export, and deletion

**Create** is a transaction: reserve UUID, verify base, create individual disk
and seed, validate exact VM configuration, start, wait for agent/cloud-init
readiness, then commit visible state. On failure retain a redacted receipt and
clean only artifacts known not to contain user work.

Each machine has states created, provisioning, running, stopping, stopped,
error, and deleting. Normal stop asks the agent to flush/shut down before the
Virtualization stop request; force stop is explicitly unclean. Inspection and
SSH/editor commands never auto-start a stopped machine. Save/restore is not a
launch promise: the direct-kernel Docker VM has observed restore failure despite
validation, so any future machine state is per-machine disposable cache, never a
snapshot or export guarantee.

**Export** requires stopped state and no saved state, then atomically writes to a
user-selected destination. The initial portable bundle holds a manifest
(architecture, profile, provenance/digests, agent compatibility), the mutable
disk, and selected non-secret metadata such as public-key fingerprints. Exclude
seed/user data, private keys, SSH configuration and known hosts, host bookmarks,
live RAM, open ports, and Docker data. RAW is the initial truthful disk format;
Apple documents ASIF as transfer-efficient storage, but use it only after
conversion and cross-host restoration are proven. Import verifies hashes,
requires matching architecture/boot compatibility, creates a new UUID, and
cannot replace a machine or base cache.

**Delete** reviews the name, disk size, endpoints, and shares; for multiple
targets it requires the exact name. Release/stop first, then remove only the
machine UUID directory and private transient artifacts. Never delete a shared
base, selected host folder, SSH key, Docker data, another machine, or export
destination. Failure to release a device aborts deletion and reports the state.

## Apple capability and entitlement constraints

- The VM-owning daemon requires the virtualization entitlement and must validate
  before construction. Morbstack already gives it to morbstackd, not the app;
  release signing must retain that division.
- The Linux boot loader is the direct-kernel route and needs a generic platform.
  A base needs compatible kernel, initramfs, and disk—not merely a cloud disk.
- CPU, memory, storage, sockets, and shares are configuration-level devices.
  Validate each exact profile on its target Mac; one success is not universal.
- NAT needs no bridged-network entitlement. Bridging needs the VM-networking
  entitlement, making it a signing/distribution/consent project, not a hidden
  settings switch.
- vmnet is a custom logical topology and file-handle attachment delegates data
  link to the app. Neither removes the need for security engineering.
- Headless SSH is first. Graphics, USB, audio, GPU, bridge, snapshots, and
  device passthrough are separate capability and threat-model projects.

## Phased implementation plan

| Phase | Outcome | Acceptance gate |
| --- | --- | --- |
| M0 — records/images | Strict manifest/registry model, content-addressed identity, expiry/provenance declaration, and secret-free desired/observed records. No payload acquisition or lifecycle surface. | No VM creation; reject bad hash, wrong architecture, missing artifact, mutable identity, unknown secret-bearing field, and record/image platform mismatch. |
| M1 — isolated VM | One curated image with supervisor, disk, console, NoCloud seed, agent readiness, create/start/stop/delete. | Prove Docker VM state, disk, socket, Kubernetes, shares, and published ports stay unchanged through every machine lifecycle path. |
| M2 — NAT/SSH | Explicit NAT, public-key review, loopback relay, host-key verification, SSH snippet, truthful retry. | Prove no non-loopback listener and no private key/user data in records, logs, diagnostics, or exports. |
| M3 — export/shares | Stopped export/import; single-folder VirtioFS, read-only default, read-write review, share receipts. | Prove no Docker/global-share inheritance, ownership mutation, or delete path can touch base cache or selected host folder. |
| M4 — advanced | Private groups; later bridge, custom links, Rosetta, graphics, USB, snapshots. | One capability at a time with entitlement review, failure injection, security audit, and native accessibility/window acceptance. |

When M1 receives UI work, use a system Table of records, a selection-driven
inspector Form, native toolbar/menu lifecycle commands, an empty-state system
view, and standard create/export/delete sheets. Do not introduce dashboard cards,
fake progress, a web terminal, or opaque global settings.

## Primary sources

Apple facts checked 2026-08-03:

- [Creating and Running a Linux Virtual Machine](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine)
  — architecture-specific Linux artifacts and validation.
- [VZVirtualMachine](https://developer.apple.com/documentation/virtualization/vzvirtualmachine),
  [VZVirtualMachineConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration), and
  [VZLinuxBootLoader](https://developer.apple.com/documentation/virtualization/vzlinuxbootloader)
  — lifecycle, configuration, save/restore, direct Linux boot.
- [VZDiskImageStorageDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment)
  — RAW and ASIF storage.
- [VZNATNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment),
  [VZBridgedNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment),
  [VZVmnetNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzvmnetnetworkdeviceattachment), and
  [VZFileHandleNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment)
  — NAT, bridged entitlement, topology, and data-link constraints.
- [VZVirtioFileSystemDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration),
  [VZVirtioFileSystemDevice](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice), and
  [Adding the Virtualization Entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)
  — sharing/effective-user behavior and VM entitlement.
- [VZLinuxRosettaDirectoryShare](https://developer.apple.com/documentation/virtualization/vzlinuxrosettadirectoryshare)
  — Rosetta as an explicit Linux directory share, not CPU emulation.

Provisioning/key semantics use cloud-init's primary
[NoCloud datasource](https://cloudinit.readthedocs.io/en/stable/reference/datasources/nocloud.html)
and [SSH module](https://cloudinit.readthedocs.io/en/stable/reference/modules.html#ssh).
