# File sharing

How a directory on your Mac becomes a directory inside the VM, and what to
do when it does not.

Status: **tier 1 (live VirtioFS)**, working. Tier 2 (synced shares) and
tier 3 (`morbfs`) are M1+ — see [`roadmap.md`](roadmap.md).

## The one rule

**A shared directory appears inside the guest at exactly the same absolute
path it has on your Mac.**

`/Users/you/project` on the Mac is `/Users/you/project` in the guest. That
is the normal mapping. There is no translation table or `/mnt/...` prefix.
The one deliberate exception is a verified macOS `/etc` or `/var` alias: those
literal paths are guest system paths, so the Docker proxy rewrites only the bind
source to its resolved, already-shared `/private/...` host path rather than letting
Docker read a plausible but wrong guest file.

```sh
docker run --rm -v /Users/you/project:/app alpine ls /app
```

`dockerd` receives `/Users/you/project` and looks for it in *its own*
filesystem, which is the guest's. Because the share is same-path, it finds
it. This is why compose files written for Docker Desktop, Colima, or a
Linux box all work unchanged, and why `-v $(pwd):/app` is safe.

The VirtioFS *tag* (`morbshare0`, `morbshare1`, …) is an internal device
identifier. It is never a path component and you should never need to know
it; `morb shares --json` reports it for diagnostics only.

Sharing is **live, not copied**. A write on either side is visible
immediately on the other — this is a mount, not a sync.

## What is shared by default

```toml
shared_paths = ["/Users", "/Volumes", "/private/tmp"]
```

Those three cover essentially every path a developer bind-mounts:
everything under a home directory, external and network volumes, and the
real location of `/tmp`. macOS makes `/tmp` a symlink to `/private/tmp`;
after that share mounts, Morbstack aliases the guest's `/tmp` to the same
VirtioFS content, so `-v /tmp/x` and `-v /private/tmp/x` see the same host
path too. The Docker proxy admits bare `/tmp` only after the running guest
confirms that alias mount; a failed or older guest gets a Docker-style bind-mount
error instead of a guest-local empty directory.

Anything **not** under one of these roots is invisible to the VM. `/opt`,
`/usr/local`, `/etc` and `/` itself are not shared, and deliberately so: a
shared directory is readable and writable by every container you ever run,
including one you pulled from a registry thirty seconds ago.

### Changing it

Edit `~/.morbstack/config.toml`:

```toml
# Directories the VM can see. Bind mounts must live under one of these.
shared_paths = ["/Users", "/Volumes", "/private/tmp", "/opt/data"]

# The subset mounted read-only in the guest.
read_only_shared_paths = ["/opt/data"]
```

Then restart the engine:

```sh
morb stop && morb start
```

**Shares are attached when the VM boots.** Editing the file changes
nothing about a VM that is already running, which is the single most common
source of confusion here — and why `morb shares` distinguishes what you
configured from what the guest actually has.

Constraints, all enforced by the host-side planner before the VM is
configured (a bad share must never be the reason a boot fails):

| Rule | Why |
| --- | --- |
| Absolute paths only | A relative path has no meaning to the guest |
| `/` may not be shared | It would expose the entire Mac to every container |
| At most 8 roots | One virtio device each, and one slot is reserved for Rosetta |
| Nested roots collapse | The outer share already covers the inner one |
| Missing directories are skipped | Reported, not fatal — an unplugged `/Volumes` disk is normal |

## Checking it

```
$ morb shares
[ok] 3 shared path(s), all mounted

  PATH           ACCESS       STATE
  /Users         read-write   mounted
  /Volumes       read-write   mounted
  /private/tmp   read-write   mounted
```

With no daemon running you get the configured list and an honest `unknown`
for every state, because there is no guest to ask. `morb shares` never
starts one: an observation that creates the thing it observes is not an
observation.

`morb shares --json` emits the same document either way, with
`daemon_running` and `source` telling a script which of the two answers it
is looking at.

In the app, **Settings › File Sharing** lists the same roots with their
live state, and a warning chip appears in the status footer whenever a
configured root is not mounted — but only while the engine is running,
since a stopped VM has nothing mounted and that is not a problem.

## Ownership: the host user maps to container root

VirtioFS presents every shared file with a single, fixed identity in each
direction — there is no per-file uid/gid mapping table. Verified directly:

- A file created on the Mac by your own user (`allie:wheel` on this host)
  shows up inside a container as **`root:root`**, regardless of which
  user the container process runs as.
- A file created inside a container — by `root` or by any other
  container-side uid — shows up back on the Mac owned by **your own host
  user**, not by whatever uid created it.
- **`chown` inside a container against a bind-mounted file is accepted
  and silently discarded.** `chown 1000:1000 /data/hostfile.txt` returns
  exit code 0 and prints nothing, but a follow-up `ls -l` in the same
  container still shows `root:root` — the ownership never actually
  changed. A script that `chown`s a shared path and trusts the exit code
  will not find out it didn't work.

Practically: this is fine for the common case (a container reading and
writing files a build or a dev server owns) and a real trap for anything
that checks ownership as a precondition — a container that refuses to
start unless a config file is owned by a specific non-root uid will not
work against a VirtioFS bind mount today, because that ownership can
never actually be set. Move that file into a named volume instead, where
`dockerd`'s own storage driver owns uid/gid mapping normally.

## No inotify across the bind mount

**A host-side edit to a file under a bind mount does not fire inotify
events inside the guest.** VirtioFS does not currently forward
filesystem-change notifications across the host/guest boundary, so any
tool that depends on inotify to notice a change — a dev server's
hot-reload watcher, `webpack --watch`, `nodemon`, `air`, and similar —
will not see edits made on the Mac side of a bind mount.

The file itself is correct and up to date the moment you read it (this is
a live mount, not a sync — see above); what is missing is the *event*
that would otherwise tell a watcher to re-read it. A process that polls
instead of watching, or one that is manually restarted after an edit,
still works exactly as expected. There is no workaround today short of
polling; do not rely on hot-reload working through a Morbstack bind mount
until this is closed. The planned solution is a guest-local synchronized
cache—not synthetic inotify—and its explicit privacy, reconciliation, and
failure contract is in [`live-share-bridge.md`](live-share-bridge.md). It is a
known gap, not a design decision, and nothing here should be read as a
hot-reload capability claim.

## Engine-side bind validation

Before relaying a normal Docker container-create request, Morbstack verifies bind
sources against the directories attached to the **running** VM and the guest's
VirtioFS mount report. It never treats a configured-but-not-yet-attached path as a
share, and it never adds a share on behalf of a container request.

An unshared source, a share the guest reports as failed, or a guest too old to
report share state fails the create request with Docker's familiar
`invalid mount config for type "bind": ...` error instead of letting dockerd
create an empty guest-local directory. `/tmp` is compared as `/private/tmp`, but
the request sent to Docker is not rewritten. Bare macOS `/etc` and `/var` sources
are different: the guest must keep its own system directories, so Morbstack admits
one only when the source exists, resolves to a path under a live VirtioFS share,
and rewrites that source to the verified resolved path. They are not part of the
default share set; add the necessary `/private/...` root and restart the engine
before requesting one. The check also follows existing symlinks (and the nearest
existing parent of a missing legacy source) before accepting it, so a path under
`/Users` that resolves to unshared `/opt` is rejected.

Docker's two bind syntaxes keep their normal behavior once the share is known
live: legacy `-v host:container` can create a missing host directory under a
shared root; explicit `--mount type=bind,src=…` requires its source to exist.
The validation does not add synced shares or filesystem notifications — VirtioFS
is still live sharing without host-to-guest `inotify` (see below). It is an
admission check rather than a filesystem sandbox: a symlink or share can still
change after the request snapshot, and chunked, oversized, or unrecognized Docker
create requests remain dockerd-owned opaque streams.

## The failure mode this prevents

Without that check, **a bind mount whose host path is not shared does not produce
an error.**

Docker asks the guest kernel for `/opt/secret`; the guest does not have it;
`dockerd` creates an empty directory there and starts the container. Your
application sees an empty directory. Nothing is logged, nothing exits
non-zero, and `docker inspect` shows a mount that looks perfectly correct.
Anything the container writes goes into the guest's own filesystem and is
lost on the next restart.

That is why Morbstack surfaces sharing in three places rather than one:

- `morb shares` — the roots and their live state.
- The container's **Overview › Mounts** table — each bind mount is checked
  against the share list, and one that is not covered is flagged on the row
  with an explanation.
- The status footer's warning chip — a configured root the guest does not
  have.

### Troubleshooting

**"My bind mount is empty."**
Run `morb shares`. If the path is not under a listed root, add it and
restart the engine. If it *is* under a listed root and that root says
`not mounted`, the reason is in the row.

**"I added a path and nothing changed."**
Restart the engine. Shares are devices, attached at boot.

**"It says `skipped`."**
The host planner rejected the root before the VM was configured. The reason
is printed next to it — usually the directory does not exist, or the eight-
root limit was reached.

**"Writes fail with permission denied."**
Check whether the root is in `read_only_shared_paths`. The Mounts table
flags a read-write mount under a read-only share, because otherwise the
failure surfaces at runtime as a permission error naming neither.

**"Performance is poor on a huge tree."**
Tier 1 is VirtioFS, and VirtioFS has a per-file cost that shows up on
`node_modules`-shaped workloads. Keeping build caches and dependency
directories in a *volume* rather than a bind mount avoids the crossing
entirely. Tier 2 (synced shares) is the planned answer for the cases where
that is not possible.

## See also

- [`architecture.md`](architecture.md) — the three-tier filesystem plan.
- [`amd64.md`](amd64.md) — the other capability that fails silently.
- [`protocol.md`](protocol.md) — the `shares` control command and the
  `morb.share` kernel command-line encoding.
