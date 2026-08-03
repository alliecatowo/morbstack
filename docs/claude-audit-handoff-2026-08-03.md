# Claude audit handoff — 2026-08-03

## Purpose and review posture

This is the current engineering handoff for an independent Claude audit of
Morbstack on `code/native-content-continuation`. Morbstack is intended to be a
free, Apache-2.0, account-free, no-telemetry, native macOS replacement for
Docker Desktop that also captures the highest-value local-development ergonomics
of OrbStack without copying its licensing or web-extension model.

Review implementation and UX rigorously, but keep the evidence vocabulary
precise:

- **Implemented in source** means the code and its local static handoff exist.
- **Bundled** means `mise run app` assembled the signed app bundle; it does not
  rebuild the guest image.
- **Live accepted** requires the clean-profile and real-VM matrix. It has not
  been run for this wave, so this document never uses source review as proof of
  Docker compatibility.

The priority is normal Docker parity first: stock CLI/context discovery,
`docker run -p`, `-P`, Compose, Buildx, volumes, bind mounts, logs/exec/cp,
Testcontainers, and Dev Containers. Kubernetes and differentiators matter, but
must not distract from that release gate.

## Reviewer starting points

Read these before making a visual or behavioral judgement:

1. [`docs/design/README.md`](design/README.md) and its linked Native macOS
   playbook/HIG coverage audit. The app may not recreate a design system in its
   content layer; use standard `NavigationSplitView`, `Table`, `Form`,
   `LabeledContent`, `.inspector`, `Menu`, search, system panels, and standard
   confirmation/progress/unavailable states.
2. [`docs/docker-engine-compatibility-inventory.md`](docker-engine-compatibility-inventory.md)
   and [`docs/clean-profile-acceptance.md`](clean-profile-acceptance.md).
   They define the source-versus-proof boundary and release matrix.
3. [`docs/drop-in-delivery-plan.md`](drop-in-delivery-plan.md) and
   [`docs/competitive-capability-roadmap.md`](competitive-capability-roadmap.md)
   for the intended Docker Desktop/OrbStack comparison and priority order.
4. [`docs/protocol.md`](protocol.md),
   [`docs/dynamic-port-allocation.md`](dynamic-port-allocation.md),
   [`docs/live-share-bridge.md`](live-share-bridge.md), and
   [`docs/build.md`](build.md) for transport/build contracts.

## Current branch and commit set

The branch is `code/native-content-continuation` at `53f6d4a` before this
handoff-document commit. Recent work is deliberately small-commit, with each
commit grouped around one outcome:

| Area | Commits |
| --- | --- |
| App assembly and CLI integrity | `0e2fa40`, `2b7b26b`, `4269898`, `549085e`, `9b73d0c`, `83722b4` |
| Docker relay, socket/context, host aliases, bind mounts | `3fc2c33`, `17baca3`, `ce02ae4`, `435d09f`, `034c317`, `146dcf2`, `7de7a41`, `5149d12` |
| Port parity and Moby `-P` handoff | `a7bc29d`, `6b8a59f`, `c66a5bc`, `2f4fd62`, `06bf81d`, `8e3b82c`, `daa6828`, `b940000`, `2f8272f`, `bc94e78`, `87ae826`, `103ab2d` |
| Compose and Buildx | `64912ae`, `52f92ea`, `b6e808e`, `7a2faa4`, `127df9a` |
| Image/volume operations | `ac26a91`, `abf4230` |
| Native macOS migration | `e66c25e`, `d8c1193`, `ab413e0`, `f5e436e`, `62c4b0e` |
| File-notification transport | `3115ff0` |
| Grow-only Docker disk transaction | `53f6d4a` |

### Prior Claude checkpoints

The work began from a Claude-managed continuation, not from a fresh main branch:

- `claude/native-content-checkpoint` is `a9ca0db` (*Checkpoint: tooling,
  migration, MCP, benchmarks, and docs*), created 2026-08-02 20:22 PDT.
- `claude/all-work-checkpoint` is `a7187cc` (*Implement native CLI setup and
  feature command surfaces*), created 2026-08-02 21:06 PDT.
- This branch forked from `claude/native-content-checkpoint` and is currently
  260 commits ahead of it; it is 258 commits ahead of
  `claude/all-work-checkpoint`.

Claude should audit the current `code/native-content-continuation` tip directly;
the checkpoint branches are preserved recovery/review references, not alternate
implementation branches to merge.

## What is implemented now

### Docker, ports, and relay behavior

- The public Docker Unix socket normally relays opaque Engine HTTP bytes. The
  host and guest relays preserve half-closes, streaming/hijacked traffic
  (`attach`, `exec`, `logs -f`, `docker cp`, BuildKit sessions), bounded
  backpressure, and prompt cancellation.
- Normal fixed TCP/UDP publishes, bounded dynamic host-port allocation, normal
  CLI-expanded fixed ranges, external/LAN address policy, restart recovery, and
  endpoint reconciliation are implemented in source. `HostIp` canonicalization
  now makes IPv4-mapped IPv6 requests resolve to Moby's IPv4 endpoint identity,
  so held leases, forwarder state, `docker inspect`, and `docker port` cannot
  disagree for that normal form.
- `-P` has a guest-side Moby allocator patch and a host/guest framed allocator
  path. The guest allocator's previously malformed match arms were repaired in
  `103ab2d`. This is source implementation, not proof: `mise run app` does not
  rebuild the guest image, and the source needs a guest-image rebuild plus a
  live lifecycle matrix before calling `docker run -P` compatible.
- Host networking is a separate explicit policy. With the option enabled,
  running `--network host` containers with no explicit port bindings may expose
  only their declared `EXPOSE` TCP/UDP candidates, after a closed guest listener
  probe proves a loopback/wildcard listener. There is a cap, refresh budget,
  retries, and no arbitrary guest-port scan. Explicit `-p` continues through
  the ordinary lease path.
- `MorbDockerContext`/CLI installation preserve user Docker configuration,
  credential-helper/`credsStore` state and ownership; direct user-socket
  discovery and per-user service behavior are documented but remain a
  clean-profile acceptance item.

Important remaining port review items: paired dual-stack listener lifecycle,
IPv6 UDP/SCTP feasibility, other dynamic raw range forms, opaque create
framing, and real create/start/stop/restart reachability. Do not mistakenly
equate the source implementation with production parity.

### Compose, configuration, secrets, and images

- The Stacks route can open one person-selected Compose YAML source through
  `NSOpenPanel`. It treats project labels and existing Docker metadata as
  insufficient authority to access a local source tree.
- From an explicitly saved selected source, native reviewed Build/Up/Down
  operations use project-root/provenance checks, a standard confirmation sheet,
  isolated Compose process environment, redacted bounded diagnostics, and
  cancellation/result refresh. Browsing a stack does not deploy it.
- The Compose source inspector shows declarations, not secret values: service
  `environment` keys/source form, `env_file` metadata without opening it,
  possible interpolation variable names, top-level secret source kind, and
  explicit service grants. It intentionally does not resolve shell/default
  `.env`/Keychain values or claim `environment:` secret-source support from its
  isolated execution environment.
- Local Images have a native table/inspector and an explicit public Docker Hub
  discovery-to-pull-review path. It stays credential-free and does not create a
  second registry credential store or pretend OCI registries share a portable
  universal search API.
- Normal Engine/Compose named-volume `driver_opts` remain opaque. The separate
  archive migration helper now refuses optioned local volumes rather than
  silently recreating them as default local volumes.

### Native macOS app

- The app is a real SwiftUI/AppKit macOS app with system window frame, toolbar,
  sidebar, split-view collapse/reveal, tables/outlines where the task is
  collection scanning/hierarchy, and real Docker inventory in the reviewer
  machine.
- The current app areas include Containers, Stacks, Kubernetes, Images, Volumes,
  Networks, Builds, Disk, and Migration. Empty states use actual available
  actions and system unavailable semantics; they are not decorative dashboards.
- `62c4b0e` removes the remaining rounded mini-card presentation in selected
  record inspectors. Containers, Images, Stacks, Disk, Volumes, Networks,
  Builds, and Migration now use top-leading, aligned system `Form` /
  `LabeledContent` / count-labelled `DisclosureGroup` semantics. The reviewer
  should still examine this in a current real window at normal and narrow sizes.
- The design finding from the live pre-remediation Images/Disk review is useful:
  `Table` is correct for dense operational inventory; an inspector must be an
  aligned form, not a custom card surface. Preserve that distinction in future
  work.

### Live development shares and disk capacity

- `3115ff0` implements a bounded host-to-guest live-share notification path for
  declared VirtioFS roots: host FSEvents transport has explicit roots, a
  startup root-rescan to close READY-to-watch loss, bounded paths/queue and
  overflow/root-change rescans; the guest receiver on vsock 2381 requires a
  boot-scoped authenticated HELLO/root claim, validates mounted root/tag/RO
  state and monotonic records, and uses descriptor-confined no-follow delivery
  to trigger a guest VFS notification. This needs a guest-image rebuild and
  real edit/watch acceptance before claiming hot reload.
- `53f6d4a` adds the journaled grow-only RAW image transaction: stopped-VM
  ownership guard, device/inode identity, durable journal, `ftruncate`/sync,
  guest `/dev/vda` mounted at `/var/lib/docker` resize proof, post-proof
  cleanup/recovery, `morb disk grow <GiB>`, and a reviewed native Settings
  confirmation/progress state. It never shrinks the disk. It must still be
  guest-image rebuilt and exercised against ext4/btrfs before a compatibility
  claim.

## Verification completed and deliberately deferred

Completed in this work wave:

- Focused `swiftc -parse`, Rust formatter/parser, and `git diff --check` handoffs
  for individual commits.
- A serialized `mise run --raw app` bundle assembly followed by
  `codesign --verify --deep --strict dist/Morbstack.app` succeeded before the
  final inspector, file-share, guest allocator, and pending disk commits.
- Real Computer Use review of the WindowServer-composited app showed actual
  local Docker containers/images and validated safe navigation, selected-record
  inspection, the Resources policies, Stacks selection, and the native
  `NSOpenPanel` Compose-source entry. Stable captures are stored under
  `artifacts/visual/`; they include useful pre-remediation Image/Disk references.

Still required after the final commit:

1. One serialized app bundle build and signature verification.
2. Real-window review of the rebuilt inspector forms in light/dark, normal/narrow
   widths, sidebar/inspector animation, toolbar overflow, keyboard focus, menus,
   search, table sort/selection, and unavailable/confirmation states.
3. A guest-image rebuild before testing guest Rust/Moby changes. This is a Docker
   Buildx workload and was deliberately not run while the user was unavailable.
4. The serial clean-profile CP-01 through CP-07 acceptance matrix: normal CLI/
   context/direct socket, Docker/Compose/Buildx, `-p`/`-P`, mounts, Testcontainers
   (Java/Go/Node/Python), and Dev Containers.

## Exact reviewer questions

1. Does the `-P` patch/allocator preserve Moby's effective `EXPOSE`, explicit
   `-p`, create/start/restart, `docker port`, and failure semantics? Is the
   source-level transaction sufficient before the guest image is rebuilt?
2. Are the host-network discovery predicates suitably narrow and truthful, or is
   any lifecycle race still able to publish a stale/incorrect port?
3. Does the file-event receiver's boot authentication, root confinement,
   rescan/overflow semantics, and VFS-notification mechanism safely cover
   VirtioFS-mounted development roots without creating an arbitrary guest-file
   access protocol?
4. Does the disk-growth journal fail closed across crash/retry, VM state,
   image replacement, and guest filesystem-tool failure? Review `53f6d4a`
   specifically, including the daemon's recovery and config-update behavior.
5. Do the source-selected Compose operations and declaration inspector preserve
   Compose semantics and secret boundaries without leaking values or becoming a
   lossy YAML/secret-management replacement?
6. Is each app route using the right macOS semantic container? Reject any return
   of custom cards, content materials, branded pills, bespoke layout chrome, or
   fake progress. Preserve native tables where a large operational collection
   genuinely benefits from sortable columns.

## Recommended next sequence after audit

1. Address audit findings, commit them in isolated changes, then run the one
   serialized app build/real-window visual pass.
2. With explicit authority to perform stateful workloads, rebuild the guest
   image and execute the port/share/disk focused matrices.
3. Run the clean-profile CP-01–CP-07 acceptance matrix before any public
   claim of a Docker Desktop replacement.
4. Close remaining normal-Docker gaps before Kubernetes/differentiators:
   complex port forms, resilient bind/watch workflow, complete CLI ecology,
   and normal Compose/Buildx/Dev Containers behavior.
5. Only then advance OrbStack-style domains/HTTPS, native file access, debug
   toolbox, and Linux machines under their already-recorded security models.

## Handoff commands

```sh
git status --short
git log --oneline -25
mise run --raw app
codesign --verify --deep --strict dist/Morbstack.app
```

For full visual/functional acceptance, follow
[`docs/development/codex.md`](development/codex.md) and
[`docs/clean-profile-acceptance.md`](clean-profile-acceptance.md). Do not run
the guest-image or clean-profile workload opportunistically: both change runtime
state and should be performed in the single serialized evidence lane.
