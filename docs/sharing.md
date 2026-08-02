# File sharing

How a directory on your Mac becomes a directory inside the VM, and what to
do when it does not.

Status: **tier 1 (live VirtioFS)**, working. Tier 2 (synced shares) and
tier 3 (`morbfs`) are M1+ — see [`roadmap.md`](roadmap.md).

## The one rule

**A shared directory appears inside the guest at exactly the same absolute
path it has on your Mac.**

`/Users/you/project` on the Mac is `/Users/you/project` in the guest. That
is the whole mapping. There is no translation table, no `/mnt/...` prefix,
and no rewriting of `-v` arguments anywhere in Morbstack.

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
real location of `/tmp` (macOS symlinks `/tmp` to `/private/tmp`, and
Morbstack resolves symlinks before sharing, so a share of `/tmp` and a
`-v /tmp/x` both land on `/private/tmp`).

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

## The failure mode this exists for

**A bind mount whose host path is not shared does not produce an error.**

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
