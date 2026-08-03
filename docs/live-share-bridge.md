# Live-share event transport feasibility record

Status: **blocked — no host watcher is started and hot reload is not supported.**

This is a source-level feasibility review of the existing live-share foundation.
It is deliberately a capability record rather than an implementation claim: a
host FSEvents watcher without a guest receiver would collect user filesystem
metadata for no consumer, and a UI switch that called it “active” would be
false.

## Conclusion

The current checkout cannot complete an end-to-end FSEvents-to-guest watch
transport. The bounded host contract is present, but both delivery halves are
absent:

| Boundary | Present evidence | Missing capability |
| --- | --- | --- |
| Root scope and overflow policy | `MorbLiveShareBridge` validates at most eight explicit `live_share_paths`, each a strict descendant of a configured VirtioFS share. Its 1,024-record `EventBuffer` turns overflow, drops, root moves, wrapping IDs, and overlong paths into explicit `rescan` records. | A lifecycle owner that starts a real FSEvent stream only after the selected shares and an actual receiver are ready. |
| Host-to-guest transport | `VMManager` observes the additive `share_event_bridge` field and `Daemon` reports a read-only diagnostic. | A bounded, acknowledged data channel. MRB0 on vsock 1024 is request/reply only; its current request family has no share-event message or long-lived receiver. |
| Guest delivery | `morbinit` reports `share_event_bridge: "unavailable"` plus `share_event_bridge_contract_version: 1` in `guest/morbinit/src/control.rs`. The version reserves the event-record schema only. | A Linux filesystem/kernel mechanism that makes the intended guest/container watchers observe a host-originated change. The guest contains no inotify, fsnotify, fanotify, FUSE-notify, or equivalent receiver. |

Linux inotify descriptors are kernel-owned; host code cannot inject an event
into arbitrary container watchers. Therefore changing the advertised capability
to `ready`, adding a host FSEvent stream, or forwarding the existing records
over MRB0 would not establish hot reload. Those changes are explicitly out of
scope until the guest-side mechanism exists.

## Planned S3 design: a guest-local synchronized-share filesystem

Status: **design only — no cache, watcher, receiver, or transport is
implemented.** This is the implementation contract for S3, not evidence that
Tier 1 VirtioFS has gained hot reload.

The delivery mechanism must come first. The planned mechanism is an opt-in,
per-project **guest-local cache** on the persistent guest ext4 disk. The
active project path is then mounted inside the guest at the same absolute path
as the selected Mac project. Containers bind-mount that normal guest-local
filesystem, rather than the underlying VirtioFS subtree. Applying a change is
therefore an actual `write`, `rename`, `unlink`, or directory operation in the
guest kernel, so ordinary Linux watchers see ordinary Linux filesystem events.
The design deliberately does *not* try to write records into an application's
inotify descriptor.

This is the relevant behavioural model for a synchronized share: Docker
documents its feature as a bidirectionally synchronized ext4 cache inside the
VM, with normal bind mounts resolving to that cache while it is ready. It is
not a promise that an FSEvents record itself is an inotify event. See the
[Docker synchronized-share documentation](https://docs.docker.com/desktop/features/synchronized-file-sharing/).

### 1. Explicit roots, authority, and privacy

`live_share_paths` remains empty by default and has no runtime effect in the
current build. Its future meaning is an explicit list of project roots to make
available as synchronized shares. It is never inferred from a Docker bind
request, a Compose file, `shared_paths`, the current directory, `/Users`, or
`/Volumes`.

Before a session can start, the host must validate all of the following:

- Each root is a canonical, existing, user-selected directory; it is a strict
  descendant of a configured and live VirtioFS share, as
  `MorbLiveShareBridge.Plan` already requires.
- Selected roots are disjoint. A root may not be an ancestor or descendant of
  another selected root, so one cache can never hide another cache or create
  two writers for the same path.
- The exact configured root, backing share tag/path, access mode, host root
  identity, and a newly generated session ID become an immutable session
  record. A changed root, renamed root, missing root, share reconfiguration,
  or guest boot ID ends that session rather than being silently retargeted.
- A root covered by a read-only share is host-to-guest only: its cache is
  mounted read-only for containers and it has no guest-to-host writer. A
  read-write session may start only when the exact selected root is writable by
  the signed-in host user.
- The user has explicitly enabled the project in File Sharing (or named that
  exact path in configuration). The surface must show that the project’s
  contents, names, and metadata are being copied to the VM; it must not call
  this a global "watch files" preference.

The host synchronizer operates relative to an opened root descriptor and
accepts only normalized relative paths without an absolute prefix, `..`, or a
NUL. It never follows a symlink to reach outside the selected root; symlinks
are copied as link objects. Device nodes, sockets, FIFOs, and unsupported
hard-link cases fail the project with a useful diagnostic instead of becoming
a capability to read or create arbitrary host paths. A project may contain
secrets, so the daemon must not put manifests, paths, content hashes, or event
logs in analytics, shared diagnostics, or a general Docker API response.

The sync service is not a general host file server. Its guest listener accepts
only the host-side vsock peer plus a per-session unguessable capability; the
capability expires at session end. The host daemon remains reachable only
through Morbstack's per-user authority. A container does not receive a
capability to ask for another root, another user’s files, or an arbitrary host
pathname.

### 2. Cache layout and observable application

For an active root `/Users/me/work/app`, the guest keeps its private durable
cache outside all shares (for example under Morbstack's guest data root) and
bind-mounts that cache at `/Users/me/work/app`. The parent `/Users` VirtioFS
mount still covers non-selected paths, but the host synchronizer reads the
selected source from its host root descriptor. A container accesses only the
guest-local cache under the active child root. Normal non-selected paths
continue to use Tier 1 VirtioFS exactly as they do today.

The sync receiver applies a committed change to that local filesystem through
ordinary Linux operations. It writes file contents to a same-filesystem staging
name, verifies the announced digest and byte count, `fsync`s the content and
journal, then atomically renames the staged file into place. It creates parent
directories before children and commits removals only after the corresponding
transaction is durable. A host edit is thus never exposed as a partially
written final file in the cache. Containers and their Vite, Python, Go, or
other watchers receive kernel-generated changes because the visible tree
really changed.

The first version's portable data contract is regular files, directories,
symbolic links, bytes, and the portable permission/executable bits. Host UID
and GID are not a portable cross-VM ownership protocol. S3 must either retain
the documented fixed-identity limitation of normal shares or state, implement,
and accept a different mapping before it is advertised. `chown`, ACL, and
extended-attribute behavior must likewise be explicit. There is no
`.syncignore` equivalent in v1: silently hiding a path below a Docker bind
source breaks the same-path contract. Dependency caches belong in named volumes
until an explicit future exclusion design can state what a container sees.

### 3. Synchronization protocol and coherence model

The implementation needs a dedicated, duplex, bounded vsock protocol. MRB0
on port 1024 remains single-flight control traffic and is not reused. The
implementing change must reserve a new port in `docs/protocol.md` and
`MorbVsockPorts` before binding it; this design intentionally does not claim a
new port exists today.

Each connection starts with a versioned `hello` containing the session ID,
guest boot ID, root IDs, per-root cache epoch, peer capability, and a fresh
nonce. It then carries only framed, size-capped messages for:

| Message family | Required meaning |
| --- | --- |
| `snapshot` / `manifest` | A paged, digest-bearing description of one selected root. It is the source of truth for initial sync and every rescan; notification paths alone never decide file content. |
| `content` / `operation` | A bounded, digest-checked file payload or a create, metadata, rename, or delete operation relative to one root and one base revision. Large files are chunked with per-chunk and whole-object limits. |
| `commit` / `ack` | The receiver acknowledges a durable root revision and highest contiguous direction-local sequence only after its cache/journal has committed it. Senders retain data until that acknowledgement. |
| `rescan` / `conflict` | A root-wide reconciliation request, or a durable report that two writers changed incompatible versions of the same entry. Neither is translated to an inotify mask. |
| `stop` / `stopped` | A bounded drain-or-abandon handshake that states which root revisions actually reached the other side. |

Every record names a session, root ID, epoch, direction, sequence, base
revision, and content digest where applicable. Sequence numbers are ordered
only within a session and direction; FSEvent IDs are diagnostic hints, not
cross-boundary coherence versions. Messages with an unknown contract version,
wrong session/epoch, invalid path, unexpected sequence, bad digest, or excess
size close the connection and move the affected root to `resyncing` or
`failed`; they never get replayed as best-effort file events.

Coherence is **acknowledged convergence**, not the impossible claim that two
independent filesystems have instantaneous POSIX shared-memory semantics. A
root is not `active` until initial synchronization has a common committed
revision. Thereafter a successfully acknowledged change is durable on both
sides. Changes still in transit are shown as synchronizing, not claimed as
visible. The per-root manifest and journal make recovery deterministic:

1. A brand-new empty cache starts from a complete host manifest. The host
   starts the scoped FSEvent stream before that scan and retains all later
   invalidations. It then reconciles any events that arrived during the scan
   before mounting the cache for containers, closing the scan/watch race.
   An overflow during this window produces another complete root manifest.
2. A clean stop drains both directions and records the last common revision.
3. After an unclean stop, disconnect, or crash, both sides rebuild manifests
   and compare them with that last common revision. A change on only one side
   is propagated; identical content is already converged; incompatible changes
   to the same entry produce `conflict` and suspend that root. There is no
   last-writer-wins overwrite and no discarded guest cache.
4. Every committed update is journaled before acknowledgement. A crash during
   apply either rolls back the staging entry or resumes from the journal; it
   never reports a revision whose final tree is only half applied.

### 4. Watches are hints; local filesystem operations notify workloads

The host daemon starts a per-session FSEvent stream only after the exact
selected root is mounted, the guest has advertised an explicitly supported
receiver, and the authenticated sync session has completed `hello`. The
callback feeds the existing scoped `EventBuffer`; it is a scheduling hint for
a manifest scan, never a delivery of invented create/write/delete events.

Apple requires a recursive scan for `MustScanSubDirs`, including when records
are dropped, and calls out root moves/renames as a separate condition. The
existing bridge therefore retains its strict 4 KiB event-path bound and maps
`MustScanSubDirs`, user/kernel drops, ID wrap, root change, and queue overflow
to root rescans. A rescan scans the actual selected root and sends an ordered
manifest reconciliation. It does not tell a container that some guessed
`IN_MODIFY` occurred. [Apple's FSEvents guidance](https://developer.apple.com/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagmustscansubdirs/)
requires that conservative response.

On the guest, the synchronizer also observes the local cache to discover
container-originated changes for the outbound direction. It must recursively
watch newly created directories, detect its own transactions by journal
revision rather than assuming inotify identifies the writer, and treat
`IN_Q_OVERFLOW`, a watcher loss, or an unpaired/escaped rename as a local
manifest rescan. Linux documents that inotify reports changes made through the
filesystem API, can coalesce/overflow, is nonrecursive, and has inherently
racy rename pairing; those are reasons to reconcile manifests, not reasons to
make a narrower fake event protocol. [inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html)

Rename and deletion rules are intentionally conservative:

- A rename wholly inside one root may be sent as a rename only when both
  endpoints and their base revision are known. Otherwise reconciliation uses
  create-plus-delete. Cross-root moves are never inferred as a move.
- A deletion is an operation against the last common revision. If the other
  side changed that entry since that revision, the root conflicts rather than
  deleting new work.
- A root deletion, move, permissions failure, case collision, or an event path
  outside the immutable root stops that root and exposes repair/reselect
  guidance. It never widens the watcher to a parent directory.

### 5. Lifecycle, recovery, and truthful status

The daemon owns the complete lifecycle. It creates no FSEvent stream before a
consumer exists, and stops the stream before releasing the receiver or
unmounting the cache. VM stop, guest boot-ID change, transport timeout,
receiver loss, config/root/share change, cache mount failure, or explicit
disable ends the session and discards only unacknowledged *event hints*—not
the on-disk cache/journal needed for reconciliation. Reconnect always creates
a new session and begins with a manifest reconciliation; it never resumes from
an FSEvent cursor or replays a prior session's incrementals.

The app and `morb shares` may show these factual per-root states: `disabled`,
`invalid configuration`, `waiting for guest mount`, `preparing`, `initial
sync`, `active`, `synchronizing`, `resyncing`, `conflict`, `stopping`, and
`failed`. `active` includes the selected root count, cache epoch, last common
revision, and last acknowledged sequence; `resyncing` names the reason and
affected root count. Status must make it clear whether a bind source uses
VirtioFS or the synchronized cache. No state is a switch-shaped success claim,
and no status query starts a VM, watcher, or sync session.

### 6. Release acceptance required before an S3 claim

All evidence below must run against the signed build in a real VM and real
containers. None has run for this design.

1. **Observer proof.** Start a Linux inotify probe in a container on an active
   root, edit/create/delete/rename from macOS, and show the expected
   kernel-generated observations without polling. Also prove the resulting
   bytes and directory manifest on both sides.
2. **Normal developer loops.** Verify a Vite HMR/watch workflow, a Python
   `watchfiles` or `watchdog` reload workflow, and a Go `fsnotify`/Air rebuild
   workflow from Mac edits. Each must demonstrate the tool's normal watch path,
   not an environment variable that forces polling.
3. **Bidirectional correctness.** Have a container write, rename, and remove
   files; prove the signed-in host user sees the expected host result. Exercise
   concurrent distinct-file changes, same-file conflict, metadata limits,
   case collision, symlink escape rejection, and a path outside every selected
   root.
4. **Loss and recovery.** Force FSEvents `MustScanSubDirs`/drop behavior,
   host and guest queue overflow, transport interruption, receiver restart,
   VM stop/start, root rename/removal, and crash during apply. Each case must
   converge through the documented manifest rescan or surface a conflict—never
   silently continue incrementally.
5. **Operational quality.** Prove zero host watcher or content transport for
   disabled/unmounted/unavailable roots; prove stop/revoke leaves no mounted
   cache or retained capability; benchmark a representative large repository
   and the three watch workloads against a guest-native ext4 tree. Publish the
   limits, measured latency, cache space, conflict behavior, and any ownership
   differences before promotion.

### Primary-source basis

- [Apple FSEventStream callback](https://developer.apple.com/documentation/coreservices/fseventstreamcallback) and [required recursive-rescan flag](https://developer.apple.com/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagmustscansubdirs/): event paths can be coalesced or lost and must not be treated as a lossless operation log.
- [Linux `inotify(7)`](https://man7.org/linux/man-pages/man7/inotify.7.html): application watch descriptors and output queues are kernel objects; consumers observe filesystem operations, and robust users handle recursive-watch gaps, rename races, and overflow with reconciliation.
- [Docker synchronized file shares](https://docs.docker.com/desktop/features/synchronized-file-sharing/): the comparison bar is a bidirectionally synchronized ext4 cache in the VM, not a host event forwarder.
