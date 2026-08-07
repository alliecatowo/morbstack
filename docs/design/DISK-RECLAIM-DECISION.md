# Disk reclaim decision (TECH-3 / UX-16)

**Status:** spike run and answered (§4/§5), mechanism and reporting path
implemented in code (§7) — the periodic `fstrim` sweep, its `info`/`status`
reporting, a `morb doctor` check, and a corrected Disk-inspector sentence.
**Not yet re-verified on a rebuilt guest**: the code has not been through
`mise run guest-image`, so the §4 numbers below are from the spike's manual
remount/`fstrim` commands, not from the shipped background thread. That
re-measurement is the remaining step and is recorded in §7 once it runs.

The spike itself: 2026-08-06, on a fresh `mise run guest-image` +
`mise run app` build (initramfs sha256
`49040a7437adbfe5bfb1224fcb9545bb77e9f424aa74689f7a1999ffd91a90f3`), against a
running `morbstackd` (8 vCPU, 8192 MiB, 72 GiB configured disk, ext4 confirmed
by the boot log: `mounted /dev/vda (ext4) at /var/lib/docker`).

This document is the experiment design, the current honest state of the code,
and the decision procedure. §4/§5 below are now filled in; §7 records what
shipped versus what was only measured by hand.

## 1. The question

`guest/morbinit/src/disk.rs:271-275` puts `discard=async` on the mount options
for the **btrfs arm only**:

```rust
pub fn mount_data(self) -> Option<&'static str> {
    match self {
        FsKind::Btrfs => Some("compress=zstd:1,discard=async"),
        FsKind::Ext4 => None,
    }
}
```

The shipped kata kernel has no btrfs driver (`docs/architecture.md:183`; there
is a regression test for exactly this at `disk.rs:1299-1302`,
`a_btrfs_superblock_is_enough_to_not_be_blank` guarding the *probe*, and the
btrfs `mkfs` binary is skipped by `which()` when the kernel can't mount what
it formats). So in every real boot the guest mounts **ext4 with kernel
defaults — no `discard`, no `fstrim` anywhere in the tree** — and
`disk.rs:271-275`'s btrfs arm is dead code that has never executed on a
shipped kernel. Resize (`MorbDiskGrowth`/`MorbDiskResize` on the host side) is
grow-only. Deleting files inside the guest — `docker system prune`, removing
an image — does not shrink `disk.img` on the Mac. This is Docker Desktop's
single most-complained-about behaviour, reproduced faithfully.

The deciding, Apple-undocumented question: **does
`VZDiskImageStorageDeviceAttachment` translate a guest `discard` (TRIM) into
hole-punching on the raw backing file**, the way a well-behaved virtio-blk
host implementation (e.g. QEMU with `discard=unmap`) does? If yes, turning on
`discard`/`fstrim` on the ext4 mount Morbstack actually uses is nearly free.
If no, reclaim needs compact-by-copy: boot a helper, copy live data into a
fresh sparse image, replace the old one — a real feature with a real cost
(disk headroom for the copy, a maintenance window with the VM unavailable),
not "more plumbing than research". `docs/audit/DIFFERENTIATION.md`'s Tier B
list previously described this as already-solved plumbing; that claim was
wrong in our own favour and has been corrected in the same commit as this
document (see that file's "Disk reclaim" bullet).

**Answer: yes.** Both mechanisms below moved real, host-measured allocated
blocks — see §4.

## 2. What is already known

- `VMManager.swift` attaches `disk.img` — a plain flat file, sparse via
  `FileHandle.truncate(atOffset:)` on APFS (`VMManager.swift:2360-2383`, `MorbPaths.diskImage`)
  — with `VZDiskImageStorageDeviceAttachment(url:readOnly:)` and no format
  hint, so it is treated as a raw image (`VMManager.swift:2244-2247`).
- `Doctor.swift`'s `disk-image` check already distinguishes apparent size
  (`st_size`) from actually-allocated size (`st_blocks * 512`) — the exact
  measurement this experiment needs, already wired up and unit-testable
  independent of a running guest.
- Apple's `VZDiskImageStorageDeviceAttachment` documentation says nothing
  about TRIM/UNMAP passthrough. There is no public API to configure it either
  way — this is a black-box behavioural question, not a settings gap. This
  spike answers it empirically instead.

## 3. Experiment design

Designed to be run in one sitting once the machine lane is free. All
measurements use `stat -f %b` (512-byte blocks actually allocated) rather
than `%z`/`ls -l` (apparent size), since apparent size is fixed at creation
time by the `truncate` call and will not move regardless of the answer.

1. **Baseline.** With the VM stopped, record `disk.img`'s allocated blocks:
   `stat -f 'apparent=%z allocated=%b (block size %k)' "$MORBSTACK_HOME/data/disk.img"`.
   Multiply `allocated * block_size` for a byte figure comparable across runs.
2. **Boot and fill.** Start the VM (`morb start` / the app), then inside the
   guest (`morb exec` a toolbox, or `docker run` a container with the host
   root reachable) write a large, incompressible file well past any dirty-page
   cache — `dd if=/dev/urandom of=/var/lib/docker/tmp/fill.bin bs=1M
   count=4096` (4 GiB; incompressible defeats btrfs-style transparent
   compression from masking the result, and matters less for ext4 but keeps
   the method identical if the btrfs arm is ever revisited) — then `sync`.
   Re-measure `disk.img`'s allocated blocks on the host. This confirms the
   write path allocates real host blocks (expected: yes, trivially — this
   step is the control, not the interesting measurement).
3. **Delete without discard (control).** `rm /var/lib/docker/tmp/fill.bin`,
   `sync` inside the guest, then remount `/var/lib/docker` — no `discard`
   option — and measure host-side allocated blocks again. Expected: **no
   change**, since nothing tells the block layer the space is free. This step
   exists to rule out an unrelated confound (e.g. APFS itself lazily
   reclaiming) before attributing any later shrink to `discard`.
4. **Delete with discard (the actual test).** Repeat step 2 (re-fill), then
   remount `/var/lib/docker` `-o discard` (ext4 supports online `discard` as a
   mount option, no reformat needed — this does not require the btrfs arm at
   all) and delete the same file, `sync`. Measure allocated blocks. Also
   independently run `fstrim -v /var/lib/docker` after an ordinary (no
   `discard`-mount) delete, as the second, lower-overhead mechanism TECH-3's
   ticket names — `fstrim` issues the same `FITRIM` ioctl in one bounded pass
   instead of per-extent on every delete, and is the one most container
   engines actually schedule periodically rather than mounting `discard` live.
5. **Compare.** If step 4's allocated-block figure drops back toward (not
   necessarily all the way to) the step-1 baseline, virtio-blk discard is
   punching holes in the raw file and the answer is yes. If it stays flat
   (matching step 3's control), the answer is no.
6. **Record.** Exact `stat` output for every step, the VM's uptime and
   morbinit boot log excerpt (confirms which filesystem actually mounted —
   `disk.rs` logs this), and which of `-o discard` / `fstrim` were used for
   step 4, in §4 below.

Actual execution note: there is no `morb exec`. Guest-side commands were run
via `docker run --rm --privileged --pid=host alpine sh -c "apk add
util-linux; nsenter -t 1 -m -- <command>"` — `--pid=host` puts the container's
`/proc` in the guest's real PID namespace, so `nsenter -t 1 -m` enters
`morbinit`'s (PID 1's) mount namespace, which is the guest's root/host mount
namespace, not a container's private one. Confirmed the mount seen was the
real one: `/dev/vda /var/lib/docker ext4 rw,relatime 0 0` before any change.
Two things worth noting for whoever repeats this: `docker run -v /:/hostroot`
(the design's other suggested approach) does **not** work here — Morbstack's
`DockerBindMountPreflight` rejects any bind source outside `shared_paths`
(Mac-side directories), including the guest's own `/`, so `nsenter` is the
only route that worked. And the target image was `alpine` (arm64/amd64
mismatch warning appeared but the container ran fine via the guest's Rosetta
binfmt registration — irrelevant to the disk measurement).

## 4. Numbers

All `stat -f 'apparent=%z allocated=%b (block size %k)'
"$MORBSTACK_HOME/data/disk.img"` (`~/.morbstack/data/disk.img`, 72 GiB
configured). Bytes = allocated blocks × 512 (POSIX `st_blocks` unit;
independent of the `%k`/4096 preferred-I/O-size figure `stat` also prints).

| Step | Action | allocated blocks | allocated bytes | ≈ GiB | Δ from previous |
| --- | --- | ---: | ---: | ---: | --- |
| 1 | Baseline (VM already running, pre-existing images/containers/k8s state) | 14,711,320 | 7,532,195,840 | 7.014 | — |
| 2 | Fill: `dd ... bs=1M count=4096` (4 GiB), `sync` | 21,967,720 | 11,247,472,640 | 10.475 | **+3.461 GiB** (real allocation, as expected) |
| 3 | Delete, **no discard** (control), `sync` | 21,967,872 | 11,247,550,464 | 10.475 | +77,824 B (noise; **no reclaim**, as expected) |
| 4 | Re-fill (4 GiB), `sync` | 28,454,080 | 14,568,488,960 | 13.569 | +3.094 GiB |
| 4a | `mount -o remount,discard /var/lib/docker` confirmed live: `/dev/vda /var/lib/docker ext4 rw,relatime,discard 0 0` | — | — | — | — |
| 5 | Delete **with discard mount active**, `sync` | 20,043,152 | 10,262,093,824 | 9.560 | **−4.010 GiB reclaimed** — matches the deleted file size almost exactly |
| 6 | `mount -o remount,nodiscard`, re-fill (4 GiB), `sync` | 28,407,888 | 14,544,838,656 | 13.545 | +3.984 GiB |
| 7 | Delete, **no discard** (control 2), `sync` | 28,408,144 | 14,544,969,728 | 13.545 | +131,072 B (noise; **no reclaim**, confirms control again) |
| 8 | `fstrim -v /var/lib/docker` (whole-filesystem sweep, not scoped to the one file) | 8,903,096 | 4,558,385,152 | 4.246 | **−9.301 GiB reclaimed** (`fstrim` itself reported `59050795008 bytes trimmed` — it swept every free extent on the filesystem, including space freed by earlier no-discard deletes this session and never-trimmed slack since the filesystem was created, which is why the reclaim is larger than one 4 GiB file) |

Guest boot log (`~/.morbstack/logs/console.log`), matching this run
(`2026-08-06T15:55:57Z` UTC = `08:55:57` local, the boot under test):
`[        22ms] mounted /dev/vda (ext4) at /var/lib/docker`. `morb status` at
time of test: `vm running`, `docker ready`, `guest morbinit 0.1.0-m0`.

## 5. Verdict and first commit

**Discard passes through — hole-punching confirmed on both mechanisms.**
`VZDiskImageStorageDeviceAttachment` does translate a guest ext4 `discard` (live
mount option) and an explicit `FITRIM` (`fstrim`) into real deallocation on
the backing raw file: step 5 shows a live `-o discard` mount freeing ~4.01
GiB against a 4 GiB deleted file (should be almost the whole file, and is),
and step 8 shows `fstrim` freeing ~9.3 GiB by sweeping every free extent on
the filesystem including several sessions' worth of previously "leaked" free
space from the no-discard control deletes earlier in this same run — the
clearest possible demonstration that trim, not something else, is doing the
reclaiming (the two no-discard control deletes at steps 3 and 7 each moved
allocated blocks by <0.01%, ruling out APFS's own lazy reclaim or measurement
noise as an alternative explanation).

This means:

- Mount ext4 with `-o discard` by default (`disk.rs`'s `mount_data` gains an
  `Ext4 => Some("discard")` arm — trivial, symmetric with the existing btrfs
  arm), *or* prefer a periodic `fstrim` if live-mount discard overhead turns
  out to be measurable under `MorbBench` (this spike did not measure write
  throughput with `discard` mounted live — the design doc's `async discard
  should not be [measurable], but measure rather than assume` caveat still
  stands; only the reclaim mechanism itself was proven here, not its cost).
  Given `fstrim`'s single bounded pass swept far more space than the live
  `discard` mount did per delete, and is what most container engines actually
  schedule, it is the stronger first commit of the two — pair it with `-o
  discard` or without, but ship the periodic sweep regardless. **Decided
  (§7): periodic `fstrim` only, no live `discard` mount** — a continuous
  `discard` mount pays a synchronous TRIM round trip inline with every
  delete, which is the documented reason production Linux distributions run
  `fstrim.timer` instead of mounting `discard` live; Docker's own
  delete-heavy operations (`system prune`, `rmi`, layer-store GC) are exactly
  the latency-sensitive case that cost would fall on.
- Add a user-visible reclaim readout: `Doctor.swift`'s existing
  apparent-vs-allocated `disk-image` check already has the two numbers: a
  free before/after comparison is one more `stat` call away from becoming a
  "how much of the configured disk is actually in use on your Mac right now"
  line, which is the number OrbStack/Docker Desktop do not show either.
  Wiring this into the Disk route UI belongs to `native-macos-dev`, not this
  agent. **Done (§7):** the guest's own last-sweep byte count now rides the
  same `info`/`status` path as the memory-balloon sample and reaches both
  `morb doctor` and the Disk inspector.
- `docs/DIFFERENTIATION.md` T8 flips from `ABSENT` to a real, tested
  differentiator — the "we tried it and it works because of how
  Virtualization.framework attaches the disk" story is more credible than a
  bare claim.

Compact-by-copy (the no-branch) is now moot: it does not need to be scoped,
since discard/`fstrim` already answers UX-16 with a much cheaper mechanism
than a stop-the-VM copy-and-swap.

## 6. Honest statement of current behaviour, as of the spike commit (superseded by §7)

As shipped in the tree at the time of the spike (before `disk.rs` gained a
periodic-trim commit): **Morbstack's disk never shrinks.**
`docker system prune`, deleting images, removing volumes — none of it returns
space to the Mac, because nothing in the guest ever issues a `discard`/`FITRIM`
on the ext4 mount actually used (only the dead btrfs arm does, and the kata
kernel has no btrfs driver). The only way to reclaim space was to delete
`$MORBSTACK_HOME/data/disk.img` and let Morbstack recreate it, which destroys
every image, container, and volume. This section is kept for the historical
record; §7 below is the current state.

## 7. What shipped, and what is still only measured (this commit)

**Mechanism: periodic `fstrim`, not a live `discard` mount.**
`guest/morbinit/src/disk.rs`'s `spawn_periodic_trim` starts a background thread (a no-op
when the data root is the tmpfs fallback) that waits `TRIM_WARMUP_DELAY` (10
minutes, so it does not compete with a fresh VM's first-minute image pulls),
then runs `fstrim -v /var/lib/docker` every `TRIM_INTERVAL` (1 hour)
thereafter. `FsKind::mount_data`'s `Ext4` arm deliberately stays `None`
rather than gaining `Some("discard")` — see the doc comment on that function
for the full reasoning: continuous `discard` issues a synchronous
FITRIM-equivalent inline with every delete, which is exactly the cost
`fstrim.timer`-style periodic sweeps exist to avoid, and Docker's own
delete-heavy operations (`system prune`, `rmi`, layer-store GC) are the
latency-sensitive case that inline cost would land on.

**Reporting path.** The sweep's last result (bytes, or the `-1`
`disk::NO_TRIM_YET` sentinel before the first sweep completes) is shared via
an `Arc<AtomicI64>` with `ControlContext` and reported on `info` as
`disk_last_trim_bytes`. On the host, `GuestControl.swift`'s `GuestReply`
decodes it the same way as `memTotalKB`/`memAvailableKB` — collapsing the
sentinel to `nil` rather than exposing `-1` to any caller — `VMManager`
caches it alongside the guest's periodic memory sample
(`guestDiskLastTrimBytes`), and `Daemon.swift`'s `status` command republishes
it as `guest_disk_last_trim_bytes` (`null` until a sweep lands). Two readers
consume that field: `Doctor.diskTrimCheck` (a `morb doctor` line that is
`.info`, never `.warn`/`.fail`, on `nil` — the sweep's slow, deliberately
staggered cadence makes "no result yet" the ordinary state for a
recently-started VM, not a problem) and the app's
`DaemonClient.guestDiskLastTrimBytes()`.

**The Disk route.** Before this commit the VM-disk footnote said "Space
freed inside the guest remains allocated on APFS until the file is trimmed
or recreated" — true when written, false the moment a periodic sweep exists
and a reader has no way to trigger either action anyway.
`TrackCDiskReclaimPresentation.footprintExplanation` (pure, tested in
`TrackCDiskMathTests`) now states the current fact once: reclaim already
happens automatically in the background, and either names the most recent
sweep's byte count or says plainly that none has completed yet — never the
guest's internal sentinel or timer names, which a reader has no use for.

**What is still open: rebuilt-guest verification.** This commit's guest
changes have not been through `mise run guest-image` — CLAUDE.md §1.5's exact
trap, called out explicitly because this project has drawn false "the fix
didn't work" conclusions from it before. The §4 numbers above are from the
spike's manual `mount -o remount,discard` / `fstrim -v` commands run by hand
inside a guest whose `morbinit` predates `spawn_periodic_trim`; they
demonstrate the mechanism `VZDiskImageStorageDeviceAttachment` supports, not
that the shipped background thread invokes it correctly on a schedule. The
remaining step is: `mise run guest-image` (new initramfs with this commit's
`morbinit`), `mise run sign`, boot, fill and delete a large file exactly as
in §3, and confirm `disk_last_trim_bytes`/`guest_disk_last_trim_bytes`
eventually reports a nonzero figure without any manual `fstrim` invocation —
blocked, as of this commit, on the machine lane being free (another agent
was mid-session on the running app/daemon). Tracked as `TASKS.md` UX-16.
