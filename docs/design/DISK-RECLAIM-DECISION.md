# Disk reclaim decision (TECH-3 / UX-16)

**Status:** spike **not yet run** — blocked on the machine lane. 2026-08-06.

This document is the experiment design, the current honest state of the code,
and the decision procedure. The numbers are not filled in yet: at the time of
writing, `dist/Morbstack.app` and `morbstackd` were already running under
another agent's `--tour-select` capture session (`ps -p 74089`/`ps -p 73206`
both showed live processes started minutes earlier), and CLAUDE.md §1.4/the
machine-lane rule in `TASKS.md`'s brief for this work say not to boot a second
VM instance or restart the daemon out from under a running capture. Whoever
picks this up next should run §3 below and fill in §4/§5.

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
  way — this is a black-box behavioural question, not a settings gap.

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

## 4. Numbers

*(Not yet collected — see Status above.)*

## 5. Verdict and first commit

*(Follows from §4. Both branches sketched now so the next agent can act
immediately once the numbers land.)*

**If discard passes through (hole-punching confirmed):**
- Mount ext4 with `-o discard` by default (`disk.rs`'s `mount_data` gains an
  `Ext4 => Some("discard")` arm — trivial, symmetric with the existing btrfs
  arm), *or* prefer a periodic `fstrim` if step 4 shows discard's live-mount
  overhead is measurable under `MorbBench` (async discard should not be, but
  measure rather than assume).
- Add a user-visible reclaim readout: `Doctor.swift`'s existing
  apparent-vs-allocated `disk-image` check already has the two numbers: a
  free before/after comparison is one more `stat` call away from becoming a
  "how much of the configured disk is actually in use on your Mac right now"
  line, which is the number OrbStack/Docker Desktop do not show either.
  Wiring this into the Disk route UI belongs to `native-macos-dev`, not this
  agent.
- `docs/DIFFERENTIATION.md` T8 flips from `ABSENT` to a real, tested
  differentiator — the "we tried it and it works because of how
  Virtualization.framework attaches the disk" story is more credible than a
  bare claim.

**If discard does not pass through:**
- Scope compact-by-copy honestly, including its real cost: it needs a stopped
  VM (or a brief pause), a helper boot, enough free host disk to hold a full
  copy of the live data during the operation (worst case: current allocated
  size again, on top of what is already used), and an atomic swap of the old
  image for the new one with the same crash-safety posture
  `MorbDiskGrowth`/`MorbDiskResize` already use for grow (never truncate live
  data without a completed, verified transaction).
- `docs/DIFFERENTIATION.md` T8 stays `ABSENT` until compact-by-copy ships;
  update its "why" line to name the real mechanism and cost instead of "more
  plumbing than research".

## 6. Honest statement of current behaviour (ships now, independent of §3–5)

Regardless of which branch the experiment lands on: **as of this commit,
Morbstack's disk never shrinks.** `docker system prune`, deleting images,
removing volumes — none of it returns space to the Mac. The only way to
reclaim space today is to delete `$MORBSTACK_HOME/data/disk.img` and let
Morbstack recreate it, which destroys every image, container, and volume.
This is tracked as `TASKS.md` UX-16/TECH-3 and reflected in
`docs/audit/DIFFERENTIATION.md`'s corrected "Disk reclaim" bullet and T8 row.
The Disk route in the app does not currently say this on screen; giving it a
truthful line (not a promise this document has not earned yet) is a
follow-up for `native-macos-dev`, tracked by UX-16.
