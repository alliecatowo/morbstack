# Host directory sharing (bind mounts)

Morbstack exposes host directories to the guest over VirtioFS and mounts each one
**at the same absolute path it has on the Mac**. This is the Docker Desktop /
OrbStack approach, and it is what makes bind mounts work without a single line of
path translation:

```
docker run -v /Users/you/app:/app ...
```

The Docker CLI sends the literal string `/Users/you/app` to dockerd. dockerd, which
has no idea it is inside a VM, resolves it against the guest's filesystem. Because
the Mac's `/Users` is mounted at the guest's `/Users`, the two land on the same
bytes. Nothing translates paths, so nothing can translate them *wrongly* — symlinks
inside a share, `..`, and Compose files with relative `volumes:` all behave the way
they do on Linux.

## What is shared

`config.toml`:

```toml
shared_paths = ["/Users", "/Volumes", "/private/tmp"]
```

Roots that do not exist are skipped with a log line rather than failing the boot
(`/Volumes` is empty on a Mac with nothing mounted). `shared_paths = []` turns
sharing off entirely. `morb doctor` reports one line per root.

Each root becomes one `VZVirtioFileSystemDeviceConfiguration` carrying a
`VZSingleDirectoryShare`, tagged `morbshare0`, `morbshare1`, … A *single* directory
share, not a multiple one: a multiple share exposes its directories by name under a
synthetic parent, which would put a prefix in front of every guest path and destroy
the property this whole design exists to preserve.

### `/tmp`, `/var` and `/etc`

These are symlinks into `/private` on macOS, and they are rewritten to their
`/private` form before anything else happens. Sharing them under their symlink names
would mount the Mac's copy over the guest's own `/tmp` (the tmpfs used for service
scratch space), `/var` (which contains `/var/lib/docker`, the entire layer store) and
`/etc`. `NSString.standardizingPath` collapses paths the *other* way — `/private/tmp`
→ `/tmp` — which is exactly the destructive direction, so `MorbShares.normalise` is
hand-rolled and never resolves symlinks.

Once the default `/private/tmp` share is mounted, the guest bind-mounts it
over `/tmp`. This makes a literal `-v /tmp/x:/y` see the same Mac content
as `/private/tmp/x`, matching macOS. If you intentionally remove
`/private/tmp` from `shared_paths`, or that share fails to mount, `/tmp`
remains guest-local and bare `/tmp` bind sources can be empty; `morb doctor`
reports that as `shares-tmp`.

Guest system roots (`/usr`, `/bin`, `/sbin`, `/lib`, `/proc`, `/sys`, `/dev`, `/run`)
are refused outright: mounting the Mac's `/usr` at the guest's `/usr` hides dockerd,
containerd and busybox behind it.

## How the guest learns the map

One kernel command-line argument per share:

```
console=hvc0 rdinit=/init morb.share=morbshare0:/Users morb.share=morbshare1:/Volumes morb.share=morbshare2:/private/tmp
```

The command line was chosen over the alternatives because it is available to PID 1
from its first instruction — no boot-order dependency on a vsock channel that does
not exist yet — and it carries no state between boots, so editing `shared_paths`
takes effect on the next start with no guest-image rebuild. A file baked into the
initramfs would have made the share list part of the image.

Paths are percent-encoded (`MorbShares.encode` / `shares::encode_path`) because the
command line is whitespace-separated: `/Volumes/My Disk` would otherwise arrive as
two unrelated arguments. Only bytes outside `[A-Za-z0-9/._+-]` are escaped, so
ordinary paths stay readable in `/proc/cmdline`, which is the first place anyone
looks. `:` is escaped too, since it separates the tag from the path.

`morbinit` reads `/proc/cmdline` immediately after `early_mounts`, builds a mount
table (outer paths first, duplicate targets collapsed) and mounts each tag
`nosuid,nodev`. A share that fails to mount is logged loudly and skipped — a guest
missing `/Volumes` is worse than a guest that will not boot only in the sense that it
is *quieter*, which is why the log line is shouty and the failure is reported back to
the host in the `info` reply's `shares` field, surfaced by `morb doctor` and
`morb shares`.

Measured: all three default shares mount in **29 ms**, well inside the boot.

## Measured semantics

Everything below was measured against a running stack (macOS 26.4, Docker Engine
29.7.1 in the guest, Apple's VirtioFS), not inferred.

### uid / gid: the host user is squashed onto whoever asks

| Question | Answer |
|---|---|
| A file owned by `allie:wheel` (501:20) on the Mac, seen by a **root** container | `uid=0 gid=0` |
| The same file seen by a container running `-u 1000:1000` | `uid=1000 gid=1000` |
| A file created by a **root** container, seen on the Mac | `allie:wheel` |

Apple's VirtioFS presents every file as owned by the uid/gid of the process asking,
so permission checks inside the container always pass, and everything written back is
owned by the Mac user. This is strictly nicer than Docker on Linux, where a root
container litters root-owned files across your source tree. No `uid=`/`gid=` mount
option is needed, and none is available.

The corollary is that ownership is not *enforced* inside a share:

* `chown` **reports success and does nothing**. `chown 1000:1000 file` returns 0 and
  the file still reads back as the caller's uid. Software that chowns and then
  verifies will be satisfied; software that chowns and expects another user to be
  locked out will not get what it asked for.
* `chmod` works and round-trips (`chmod 600` shows `600` on both sides) — but the
  **setuid bit is silently dropped**: `chmod 4755` stores `755`. The shares are
  mounted `nosuid` anyway, so this is belt and braces.
* `mknod` fails with `EPERM`. `mkfifo`, hard links and symlinks all work and appear
  correctly on the Mac.
* `mtime` propagates in both directions.

### Scoped live-share notifications

Plain VirtioFS makes changed host bytes visible, but a host editor write does
not itself create a Linux watcher event. Morbstack’s opt-in live-share bridge
adds a guest-kernel notification operation for explicit project roots:

```toml
live_share_paths = ["/Users/you/work/project"]
```

The selected root must be a real strict descendant of a configured, writable
`shared_paths` root. The daemon never watches a broad default such as `/Users`
or `/Volumes`, and it does not infer a root from a Docker bind request. Once
the guest has confirmed the matching VirtioFS share, the daemon opens a scoped
FSEvent stream and sends authenticated invalidations to the guest over vsock.
The guest maps an accepted invalidation to a descriptor-confined same-mode
metadata operation on that exact VirtioFS object, producing a normal Linux
filesystem attribute notification without changing the object’s bytes or mode
bits.

FSEvents is still lossy and coalescing, so records are invalidations rather
than invented create/write/delete masks. `MustScanSubDirs`, dropped events,
ID wrap, root changes, long paths, and bounded-queue overflow become an
acknowledged recursive root rescan. See
[`live-share-bridge.md`](live-share-bridge.md) for root authority, reconnect,
security, and release-acceptance details, and
[`protocol.md`](protocol.md#36-the-vsock-2381-live-share-notification-protocol)
for the wire contract.

The acceptance boundary remains unchanged: until the guest endpoint, transport, and
real-container tests prove the behavior, **VirtioFS content coherence works but
host-originated inotify and hot reload do not**. Keep using tool-specific polling when
needed.

### Performance

2000-file and 256 MiB workloads run inside a container, share vs. the guest's own
overlay:

| Operation | VirtioFS share | Guest overlay |
|---|---|---|
| Sequential write, 256 MiB | 235 ms | 424 ms |
| Create 2000 small files | 627 ms | 123 ms |
| `ls -la` 2000 entries | 61 ms | 54 ms |
| `rm -rf` the tree | 340 ms | 81 ms |

Bulk data is fine — faster than the overlay, in fact, because it lands in the host
page cache on APFS. Metadata operations cost roughly **5x**, which is the familiar
VirtioFS profile: `npm install` into a bind-mounted `node_modules` will be noticeably
slower than into a named volume. The standard advice applies — keep dependency
directories in named volumes and bind-mount only source.

No mount options are passed. The Linux `virtiofs` driver accepts only `dax` and
`source`, and DAX needs a shared memory window that Virtualization.framework does not
expose, so anything else is rejected with `EINVAL`.

### The silent failure mode

Confirmed: `docker run -v /opt/not-shared:/x` **succeeds** and gives the container an
empty directory. dockerd creates a missing bind source rather than refusing, and the
directory it creates lives inside the guest, so nothing appears on the Mac and no
error appears anywhere.

That is why the guest reports its mount results back to the host and why the daemon
log, `morb doctor` and `morb shares` all name any root that was configured but not
mounted. If a bind mount is mysteriously empty, that is the first thing to check.

## Kernel support

Verified by extracting the embedded config from the shipped kernel
(`~/.morbstack/data/kernel/vmlinux`, `IKCFG_ST` blob):

```
CONFIG_VIRTIO_FS=y
CONFIG_FUSE_FS=y
CONFIG_FUSE_DAX=y
CONFIG_NET_9P=y          # present as a fallback; unused
CONFIG_9P_FS=y
```

All built in, not modules — which matters, because the initramfs carries no module
tree to load one from.
