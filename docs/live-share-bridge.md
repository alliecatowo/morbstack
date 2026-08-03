# Live-share filesystem notification bridge

Status: implemented in the host and guest source tree; real VM/container
acceptance remains a release gate.

Morbstack's ordinary VirtioFS shares make changed Mac bytes visible at the
same absolute guest path. A Linux workload watching that path does not
necessarily receive a corresponding kernel notification when the Mac editor
writes it. The live-share bridge adds that missing notification path for
explicit project roots without turning the daemon into a broad host watcher or
a file server.

## What activates it

`live_share_paths` is empty by default. Each entry must be an existing real
directory, a strict descendant of an actual configured `shared_paths` VirtioFS
root, and disjoint from the other selected roots. The daemon rejects root
symlinks, inaccessible directories, read-only shares, unmounted guest shares,
or a mismatched guest contract before it opens FSEvents.

The active session has these facts:

- Host FSEvents watches only the selected project roots. It asks for file
  events and root changes, never `/Users`, `/Volumes`, the current directory,
  or a path inferred from a Docker bind request.
- Guest `morbinit` listens on the dedicated vsock port 2381. It accepts only
  exact tag/path/access-mode claims for VirtioFS shares mounted in *this* boot.
- The guest presents Linux's per-boot ID. The host creates a fresh in-memory
  256-bit capability and session ID for every connection. HMAC-SHA256 covers
  the immutable hello claims and every later event/acknowledgement.
- The guest resolves an accepted relative event path only below an opened root
  descriptor with `openat(O_NOFOLLOW)`. It does not follow a selected-project
  symlink into another guest path and never accepts a raw host path from a
  container.

The detailed wire contract is [§3.6 of the protocol specification](protocol.md#36-the-vsock-2381-live-share-notification-protocol).

## Notification mechanism

The host forwards an invalidation, not a guessed create/write/delete mask. The
guest locates that existing VirtioFS file (or its nearest existing parent after
a deletion) and applies the same permission bits with `fchmod(2)` through the
guest VFS. The contents and mode bits are unchanged; the guest kernel emits an
ordinary filesystem attribute notification for watchers of that object. This
is intentionally a real filesystem operation rather than an impossible
attempt to write a record into another process's inotify queue.

For a root rescan, the receiver walks the selected tree through no-follow
descriptors and applies the same operation to each regular file/directory. It
has hard limits of 65,536 objects and 64 directory levels. A limit hit returns
`rescan-required` and closes the current session instead of representing a
partial rescan as completed delivery. The daemon reports a terminal failed
state instead of repeatedly walking the same oversized root; selecting a
smaller root or changing the configuration starts a fresh session.

## Overflow and lifecycle

`MorbLiveShareBridge.EventBuffer` holds at most 1,024 events. A normal FSEvent
becomes an invalidation. `MustScanSubDirs`, a root change, an overlong path,
or queue overflow become a root rescan; a user/kernel drop or FSEvent ID wrap
becomes one root rescan for every selected project, following Apple's
recursive-rescan rule. The receiver acknowledges an applied event before the
host sends the next one.

The daemon starts its FSEvent stream only after the guest has authenticated
the exact session claims, then requests one bounded rescan of every selected
root before marking delivery active. That closes the handshake-to-watch setup
gap without creating a watcher before there is an authenticated receiver. VM
stop, guest boot change, mount/config mismatch, bad capability/HMAC,
mismatched authenticated claims, bad sequence, receiver rejection, or a
transport disconnect stops the
FSEvent stream, closes the descriptor, destroys the capability, and later
reconnects with a new boot/session handshake. A short same-path echo window
suppresses the guest's metadata nudge feeding directly back into the host
event stream.

The daemon surfaces `disabled`, `invalid-configuration`,
`waiting-for-guest-mount`, `waiting-for-session`, `active`, and `failed`.
Status reads do not start a VM or a watcher.

## Required release acceptance

The implementation must be exercised in a signed bundle with a real VM and
containers before it is advertised as a completed developer-loop feature:

1. Run an inotify/fsnotify probe in a container under a selected root; edit,
   create, delete, and rename from macOS; prove changed bytes and observed
   guest filesystem notifications.
2. Exercise Vite, Python watchfiles/watchdog, and Go fsnotify workflows with
   their normal watcher settings, not forced polling.
3. Force FSEvents `MustScanSubDirs`, user/kernel drops, ID wrap, a receiver
   disconnect, VM restart, selected-root rename/removal, and a rescan bound;
   verify active delivery resumes only after the documented fresh session or
   reports the affected failure.
4. Prove an unselected sibling, a broad share root, a root symlink, a path
   outside the selected root, a read-only share, and a symlink escape cannot
   cause a guest filesystem operation.

Apple requires recursive rescans for `MustScanSubDirs` and dropped FSEvents:
[FSEventStreamEventFlags](https://developer.apple.com/documentation/coreservices/file_system_events/1455361-fseventstreameventflags/kfseventstreameventflagmustscansubdirs).
