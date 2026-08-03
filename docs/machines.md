# Linux Machines

Status: **M0 registry and a no-I/O M0.1 acquisition-admission boundary are
implemented; no machine runtime or UI exists yet.** The M1 blueprint below is
planned architecture, not implementation evidence or a user-visible capability.

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

### M0.1 image-acquisition admission boundary

[MachineImageAdmission.swift](../mac/Sources/MorbstackKit/MachineImageAdmission.swift)
adds a separate, pure `MachineImageAcquisitionManifest` for the first M1
precondition. It is not an image downloader or a partially implemented Create
path. Its strict decoder rejects unknown fields throughout the outer declaration
and M0 image manifest, then requires:

- one direct credential-free HTTPS source, expected byte count, and SHA-256 for
  each required artifact role, with no archive fan-out or duplicate source;
- a Sigstore-only policy whose publisher/release, verification-material digest,
  and expiry exactly match the content-addressed M0 image declaration, plus an
  exact issuer, signer identity, and detached-bundle source/digest;
- an explicit host architecture fact supplied by the future supervisor, never a
  Docker-guest label or an implicit translated-process guess; and
- a current policy expiry, exact source-to-artifact digest agreement, and a
  lexical owner-only storage plan beneath `~/.morbstack/data/machines/`.

The layout plan names content-addressed immutable image files, a policy-digest
staging namespace, and a separate policy receipt. It only computes those names
and desired `0700`/`0600` modes. It does not inspect or create a directory, read
or download a source, validate a signature, create a disk, change SSH/config,
or construct a VM. Even a valid, native-architecture declaration returns the
specific **acquisition and verification unavailable** state until an explicitly
initiated M1 transaction safely creates private paths, verifies every byte and
the Sigstore policy, and publishes an immutable base atomically.

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

## Planned M1 runtime boundary and authority

M1 is a new machine subsystem, not a second mode in `VMManager`. The existing
daemon may route an authenticated machine request to it, but the subsystem must
not receive a Docker API client, `VMManager`, `PortForwarder`,
`DirectoryShares`, Docker configuration, Kubernetes credentials, or a Docker
VM path. Sharing a low-level lock or listener primitive is acceptable only when
that primitive carries no Docker identity or state.

| Planned component | Sole authority | Explicit non-authority |
| --- | --- | --- |
| `MachineImageCatalog` | Read the sealed, app-shipped curated-image list, publisher verification material, and compatible device layouts. | No mutable label, Docker image, or user-writable catalog is a curated image. |
| `MachineImageStore` | Stage an explicit image acquisition, verify publisher material and every declared byte, then atomically expose an immutable content-addressed base. | No launch-time download, PATH/cache fallback, Docker image-cache reuse, or attachment of unverified bytes. |
| `MachineRegistryStore` plus journal | Serialize registry writes, UUID reservation, create/import/export/delete intent, and crash recovery records. | It never stores raw cloud-config/seed data, credentials, private keys, or console transcripts. |
| `MachineSupervisor` | Own one `VZVirtualMachine` queue and lifecycle state machine for each UUID. | It cannot call the Docker lifecycle or reuse Docker's MAC, vsock contract, disk, saved state, shares, or ports. |
| `MachineGuestControl` | Authenticate the versioned, host-only agent and graceful shutdown request for one VM. | It cannot treat a Docker/morbinit vsock service as a machine agent or publish a network service. |
| `MachineLoopbackRelay` (M2) | Hold one selected/random `127.0.0.1` SSH lease for a running NAT machine. | It never listens on LAN, survives stop, allocates Docker ports, or exposes an isolated machine. |

The planned tree is below `~/.morbstack/data/machines/`, never beneath Docker's
disk or runtime tree:

```text
machines/
  registry.json                 # secret-free desired/observed records
  registry.lock                 # serializes registry and image-cache mutation
  images/<image-digest>/        # verified immutable regular files only
  instances/<machine-uuid>/
    disk.raw                    # that UUID's writable clone only
    receipt.json                # redacted provisioning outcome
    console.log                 # owner-only bounded retention
    seed/                       # transient owner-only NoCloud material
    transactions/               # durable redacted recovery journal
    export-staging/             # one explicit export transaction
```

These are planned names, not M0-created paths. Every access must be owner-only,
regular-file checked, and resolved beneath its expected root; opaque UUIDs and
content digests are the only model-controlled path components. Visible names,
archive names, and host paths never choose a machine-owned file. A per-UUID
serialized queue prevents two lifecycle requests from constructing two VMs. The
app sends intent over machine-specific daemon IPC and renders observation; it
does not edit machine files or turn an app restart into a lifecycle command.

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
The current M0 manifest binds platform, distribution, agent protocol, required
artifact digests, declared provenance, and expiry, but it deliberately has no
virtual-device-layout compatibility key or pinned publisher-verifier identity.
M1 must introduce those in an explicit versioned catalog/manifest contract; it
must not infer that a valid M0 declaration is attachable because its declared
verification result says `verified`.

The M1 attachability contract binds all of the following to the image digest and
the sealed app catalog entry:

- immutable upstream publisher URL and release, plus verification material,
  expected signer identity, and verification result;
- architecture, distribution/cloud-init version, and guest-agent protocol;
- SHA-256 for kernel, initramfs, root disk, agent package, and seed-image input;
- SSH, VirtioFS, and cloud-init datasource expectations; and
- a versioned compatibility key for virtual-device layout, boot assets, and
  guest-control handshake.

The catalog is sealed in the signed app release; an app update is the only way
to update trusted publisher material. Acquisition is separately initiated by a
person, shows source, identity, architecture, and expected size before any
networking, stages privately, verifies publisher material and every declared
byte, then atomically exposes a content-addressed cache. There is no `latest`,
Docker/cache/PATH fallback, account, or telemetry path. Bad, unsigned,
mismatched, or unverified input is not attachable. A new image has a new digest;
existing machines retain their recorded base until a separately reviewed
migration exists.

Expiry blocks a new fetch or new machine from relying on stale publisher
verification. It never starts a download, deletes a verified base, destroys a
machine, blocks stopped export, or strands existing user data. Updating an image
acquires a new digest; it may not replace a base in place.

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

M2 initially offers copy-only integration: a standard `ssh` command plus an
SSH-config/known-hosts snippet derived from the verified fingerprint. It never
silently edits `~/.ssh/config` or `~/.ssh/known_hosts`. Any later explicit
installer needs its own backup, collision, and rollback contract. Convenience
is never a reason to disable host-key checking.

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

### Planned transaction and recovery rules

M1 records intent before each non-idempotent filesystem or device change and a
terminal result afterward. On daemon ownership after an interruption it scans
only the private instance tree: an incomplete create, delete, import, or export
is **Recovery Required**, never silently reported as stopped or removed.
Recovery may offer a bounded, explained retry or discard only after proving the
exact UUID-owned files it affects. Uncertain cloud-init/agent completion retains
the disk and says `provisioning unknown`; it is not a successful creation.

Create validates the host architecture, sealed image availability, exact
hardware, isolated device configuration, and reviewed public configuration
before reservation. It reserves the UUID under the registry lock, clones or
copies the verified base, prepares the private seed, validates the exact VZ
configuration, boots, completes the per-instance agent/cloud-init handshake,
then atomically makes the record visible. A normal Stop asks the matching agent
to flush and power off before observing VM termination; Force Stop is a
separately labelled unclean action. Selection, diagnostics, export, and SSH copy
never auto-start a stopped machine.

The readiness handshake must prove the expected UUID/instance ID, image digest,
agent protocol, and cloud-init completion against a per-boot host challenge.
Raw seed data and that challenge remain private runtime material; only a digest,
timestamps, host-key fingerprint, and redacted outcome enter the receipt. A
mismatch is unavailable/provisioning unknown, not ready. M2 creates its relay
only after this check for a running NAT machine; any stop, network downgrade,
agent loss, conflict, or identity mismatch releases the loopback listener.
Isolated machines have no Virtio network device, share device, or SSH relay;
changing isolated/NAT is a stopped-machine validated-device replacement, not a
live toggle.

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
| M0.1 — acquisition admission | Strict source-bearing manifest and pure storage-layout plan bind each required role to one HTTPS source, exact byte count/digest, native architecture, Sigstore signer policy, and expiry. The only non-rejected result remains unavailable. | No network, manifest file read, directory/disk creation, signature verification, SSH/config mutation, Docker access, VM construction, or Create UI. M1 must still prove secure private-path creation, source/policy verification, atomic publish, and Docker-state isolation. |
| M1 — isolated VM | One curated image with supervisor, disk, console, NoCloud seed, agent readiness, create/start/stop/delete. | Prove Docker VM state, disk, socket, Kubernetes, shares, and published ports stay unchanged through every machine lifecycle path. |
| M2 — NAT/SSH | Explicit NAT, public-key review, loopback relay, host-key verification, SSH snippet, truthful retry. | Prove no non-loopback listener and no private key/user data in records, logs, diagnostics, or exports. |
| M3 — export/shares | Stopped export/import; single-folder VirtioFS, read-only default, read-write review, share receipts. | Prove no Docker/global-share inheritance, ownership mutation, or delete path can touch base cache or selected host folder. |
| M4 — advanced | Private groups; later bridge, custom links, Rosetta, graphics, USB, snapshots. | One capability at a time with entitlement review, failure injection, security audit, and native accessibility/window acceptance. |

## Native macOS route and promotion gates

M0 does not receive an aspirational route. Once M1 has a truthful supervisor,
Machines is a record-management task: use a system `Table` (name, state, image,
architecture, CPU/memory, network intent), normal selection/sorting and
`.searchable` when needed, with a selection-driven inspector `Form` for identity,
configuration, endpoint, receipt, and recovery detail. The sidebar names the
area; it does not become a second dashboard.

| Semantic state | Native presentation and command rule |
| --- | --- |
| No M1 runtime / no attachable curated image | `ContentUnavailableView` with the precise unavailable reason and a non-destructive review path. No fake machines or Create button. |
| No records | `ContentUnavailableView` with **New Machine…** only when an attachable image exists. |
| Creating, provisioning, starting, stopping, export/import/delete | Retain the selected row and use real phase text with an indeterminate `ProgressView` in the inspector or standard sheet. Offer Cancel only with a defined cancellation/recovery path; never invent a percentage. |
| Running / stopped | **Stop** / **Start** respectively is the primary lifecycle command. SSH copy appears only after verified readiness and a live loopback lease. |
| Provisioning unknown, error, interrupted transaction | The inspector states the safe error and exact recovery choices. There is no generic “fix it”, auto-restart, or destructive cleanup. |
| Export/delete/import replacement | Use standard sheets with exact machine name and affected disk/endpoints/shares. Multiple deletion requires exact-name confirmation and is never a one-click toolbar action. |

Lifecycle commands live in the route toolbar and scoped **Machine** menu;
secondary operations use a standard `Menu` or contextual menu. Per-machine
controls never move into global settings. Use standard forms, buttons,
confirmation dialogs, inspector behavior, and accessibility labels—not cards,
custom pills, a web terminal, custom progress dashboard, or a parallel visual
system.

M1 is not promoted from planned to implemented until all of these have dated
evidence from a signed, real app/daemon installation. Source review or a
fixture alone is insufficient.

| Gate | Required proof |
| --- | --- |
| **G0 — migration and ownership** | M0 data has an explicit compatible migration or remains read-only; M1 does not reinterpret `stopped`/`unavailable`. Registry, journal, image, and instance paths reject traversal/symlinks and retain owner-only permissions. |
| **G1 — pinned base** | A person-initiated catalog acquisition verifies publisher material and every byte; it rejects bad, wrong-architecture, expired input and exposes no partial base. No launch-time network or Docker/PATH/cache fallback. |
| **G2 — isolated lifecycle** | Create/start/normal stop/force stop/delete plus each interrupted phase show truthful recovery. Before/after evidence proves Docker VM state, disk, socket, Kubernetes, shares, MAC, and published ports are unchanged. |
| **G3 — provisioning and SSH** | NoCloud accepts reviewed public input, redacts seed data, and requires the matching agent handshake. Private keys never enter records/logs/diagnostics/exports; NAT SSH is machine-owned loopback only, and isolated machines expose none. |
| **G4 — portable data and shares** | Stopped export/import verifies data and creates a new UUID; cancellation/failure leaves source/destination safe. Scoped read-only and reviewed read-write shares prove no Docker/global-share inheritance or ownership mutation. |
| **G5 — native accessibility** | Real WindowServer review covers light/dark, normal/narrow widths, sidebar/inspector/table sort and selection, keyboard/focus, VoiceOver, progress/error/recovery, accessibility display settings, and destructive confirmation. |
| **G6 — clean profile** | A fresh profile creates, reaches over SSH, stops, exports, imports, and deletes a machine while Docker state stays unchanged, without Docker Desktop, account setup, telemetry, or manual environment wiring. |

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
