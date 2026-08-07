# Disk reclaim decision (TECH-3 / UX-16)

**Status:** spike run and answered (§4/§5), mechanism and reporting path
implemented in code (§7) — the periodic `fstrim` sweep, its `info`/`status`
reporting, a `morb doctor` check, and a corrected Disk-inspector sentence.
**§8 (this update): the periodic sweep as shipped in §7 could never fire in
practice** — its 10-minute warmup outlives the default `auto_suspend_minutes`
(5), so an idle-cycled guest was stopped before the sweep's first run every
time. Fixed by moving reclaim-on-idle off that timer entirely and onto a
bounded sweep in the guest's own shutdown sequence, which runs on every
teardown regardless of `auto_suspend_minutes`. Verified on a rebuilt guest —
see §8's "Verification" for the measured numbers, closing the "not yet
re-verified" gap this status line used to carry.

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

**What was still open at this point: rebuilt-guest verification.** This
commit's guest changes had not been through `mise run guest-image` — CLAUDE.md
§1.5's exact trap, called out explicitly because this project has drawn false
"the fix didn't work" conclusions from it before. The §4 numbers above are
from the spike's manual `mount -o remount,discard` / `fstrim -v` commands run
by hand inside a guest whose `morbinit` predates `spawn_periodic_trim`; they
demonstrate the mechanism `VZDiskImageStorageDeviceAttachment` supports, not
that the shipped background thread invokes it correctly on a schedule. **That
verification found the bug §8 below fixes** — the periodic sweep never got the
chance to invoke anything on the machine it was first tested on live, because
the guest was auto-suspended before its warmup elapsed. See §8.

## 8. The warmup outlived the thing it needed to survive (found live, fixed)

### 8.1 What was observed

Verifying §7 on a guest actually built with `mise run guest-image` (rather
than the §4 spike's manual commands against an older guest), on the running
daemon, with the shipped default `auto_suspend_minutes = 5`:

```
19:37:54  docker relays idle
19:37:56  suspend-to-disk unavailable here; stopping the guest instead
```

The guest was up for roughly six minutes before the host's idle timer stopped
it. `spawn_periodic_trim`'s `TRIM_WARMUP_DELAY` is 10 minutes. The sweep
thread was still asleep, four minutes short of its very first run, when the VM
went away and took the thread with it. `morb doctor`'s `disk-trim` check
reported "no guest has reported a disk-trim sweep result yet on this boot" —
correctly, because none ever had a chance to.

This is not a one-off timing coincidence. `VMManager.isSaveRestoreBroken` is
`true` on every host this project has tested against on macOS 26.4 (`vz`
save/restore is broken for direct-kernel guests — see the guest-kernel-
constraints memory note), so every idle auto-suspend on a real developer
machine degrades to a full stop (`suspendOnQueue`, `VMManager.swift`). A
developer who steps away for coffee, or simply reads a PR for six minutes
between `docker` commands, hits this every time. **The periodic sweep as
shipped in §7 was correct code implementing a mechanism that could not run on
the exact machine it was built for.**

### 8.2 This is the second instance of this shape

The memory-balloon evaluator (UX-17, `MemoryBalloonPolicy.swift`) shipped with
a single fixed 30-minute re-evaluation interval against the same 5-minute
default `auto_suspend_minutes` — the VM idle-suspended and cancelled the timer
roughly six times over before the interval's first tick could ever fire. Two
independent features, in two different languages, on two sides of the vsock
boundary, both shipped as dead code for the identical reason: **a background
timer whose only path to ever firing is outliving a host-configurable idle
threshold is inert by construction the moment that threshold is shorter than
the timer**, and `auto_suspend_minutes`'s own shipped default already is
shorter than both timers were.

The balloon's fix (this same session, `MemoryBalloonPolicy.firstEvaluationDelay`)
and the disk-trim fix below are not the same shape of fix, and the difference
is instructive:

- The balloon evaluator runs **on the host**, in `VMManager.swift`, which
  already has `MorbConfig.autoSuspendMinutes` in scope. Its fix computes a
  *first*-tick delay relative to that value (half of `auto_suspend_minutes`,
  floored, capped at the steady-state interval) — the host already knew the
  threshold it was racing, so closing the gap was a matter of consulting a
  value it could already see.
- The disk-trim sweep runs **in the guest**, in `morbinit`, which has no
  channel carrying `auto_suspend_minutes` at all (checked: neither the boot
  config nor any control message mentions it — the guest genuinely cannot see
  the value it would need to race correctly). Doing the balloon's trick here
  would require a *new* piece of host→guest state just to keep a timer
  approximately synchronized with a setting the guest has no other reason to
  know, and would still break the moment a user picked a threshold shorter
  than whatever margin was chosen — the exact fragility called out below.

So the two fixes are not interchangeable, and applying the balloon's approach
here would not actually have closed the gap; it would have picked a new,
smaller version of the same race.

### 8.3 Options weighed

1. **Shorten `TRIM_WARMUP_DELAY` below the default `auto_suspend_minutes`.**
   Simplest change, and the one an unrelated fix (§8.2's balloon evaluator)
   might tempt a reader to imitate. Rejected: it does not fix the class of bug,
   it just moves the race to a smaller margin. `auto_suspend_minutes` is a
   user-editable `config.toml` value with no enforced minimum above zero — set
   it to 2 and a 3-minute warmup is exactly as inert as a 10-minute one was
   against 5. Any fixed guest constant loses this race against *some*
   reachable configuration, because the guest has no way to know what value it
   is racing (§8.2). This also does nothing for the case that matters most:
   the auto-suspend-as-stop path is the common one on every host this project
   has tested (§8.1), so "sometimes wins the race" is not good enough.
2. **Run the sweep on the way down, in the guest's shutdown sequence.**
   The moment immediately before a stop is exactly when reclaim is free:
   `sup.stop_all()` has already returned, so nothing is contending for the
   disk the way a fresh boot's image pulls are (the reason
   `TRIM_WARMUP_DELAY` exists at all), and the guest is about to go away
   regardless of whether anything reclaims space right now. `run_shutdown_sequence`
   already exists as exactly this hook — it already flushes and unmounts
   `/var/lib/docker` before replying `ok`. **Chosen** (§8.4).
3. **Trigger on resume rather than on a boot-relative timer.** Rejected on
   its own merits, independent of the auto-suspend-minutes problem: real
   suspend-to-disk is currently broken on this project's only tested host
   (`isSaveRestoreBroken`), so "resume" in practice means "cold boot", and
   running an `fstrim` sweep at boot is the one time this module goes out of
   its way to avoid disk contention (`TRIM_WARMUP_DELAY`'s whole reason to
   exist is *not* running at boot, when a fresh VM is normally pulling
   images). Even once save/restore is fixed, a real resume from a saved state
   blob has nothing to reclaim that ordinary boot-time discovery would not
   also need to re-derive, for no benefit over option 2.
4. **Have the host ask, since it already knows when it is about to stop the
   guest.** This is almost right, and turns out to be the same lever as
   option 2 pulled from the other end: the host *already* asks, via the
   existing `shutdown` control message (`VMManager.stopOnQueue` →
   `GuestControl.shutdown`) that every clean stop sends before tearing the VM
   down. A brand-new "trim now" message would duplicate a round trip that
   already exists and already blocks the host on a guest-side reply. Rather
   than add wire surface, option 2 makes the *existing* shutdown request do
   double duty: the guest treats "I've been asked to shut down" as the signal
   to trim, which is functionally the host asking, with zero protocol
   changes.

Options 2 and 4 converge on the same implementation. That convergence is the
tell that it is the right layer: the host has never needed to *tell* the guest
"you are about to stop" through any channel other than the shutdown request it
already sends, so the fix belongs entirely inside `run_shutdown_sequence`.

### 8.4 What shipped

`guest/morbinit/src/disk.rs`'s `trim_before_shutdown(on_disk: bool)` runs one
`fstrim -v /var/lib/docker` sweep, bounded by a new `TRIM_SHUTDOWN_DEADLINE`
(15s), and is called unconditionally from `run_shutdown_sequence` — after
`sup.stop_all()`, before `disk::flush_docker_data`, so the filesystem is still
mounted read-write when it runs. This covers every guest teardown: an
explicit `morb stop`, an app quit, and — the case that was actually broken —
an idle auto-suspend that degrades to a stop (`suspendOnQueue` when
`isSaveRestoreBroken`). None of those paths consult `TRIM_WARMUP_DELAY`,
`TRIM_INTERVAL`, or `auto_suspend_minutes` at all, so there is no value a user
can set that breaks this trigger again — it does not race anything.

The periodic sweep (`spawn_periodic_trim`, unchanged: still a 10-minute warmup
and hourly interval) stays exactly as it was, now correctly understood as a
bonus for a guest that stays up — busy or not — past its warmup without
stopping, not as the thing an idle-cycled guest's reclaim depends on. Its
doc comments were updated to say so explicitly, so a future reader does not
reach for it as the answer to "why didn't my disk shrink" and rediscover this
same investigation.

**Why bounded, unlike the periodic sweep.** The shutdown-time trim sits
directly in the critical path the host is already waiting on
(`control::SHUTDOWN_REPLY_TIMEOUT`) before it dares tear the VM down, so
letting it run unbounded risks the exact bug that budget exists to prevent —
an outer timeout expiring and hard-stopping the guest mid-operation. A killed
`fstrim` costs nothing but the reclaim opportunity: `FITRIM` only discards
extents the kernel has already decided to discard, so cutting it short loses
some potential space, never correctness. `TRIM_SHUTDOWN_DEADLINE` (15s) was
added to the guest's `SHUTDOWN_REPLY_TIMEOUT` formula, and every host-side
budget that has to nest above it (`VMManager.shutdownAckTimeout`,
`Daemon.stopBudget`, `Daemon.suspendBudget`, `Daemon.clientTimeout`) moved up
by the same 15s plus a small margin, restoring (and for the first time
actually documenting correctly) the intended slack at each layer — see the
doc comments on those constants and `LifecycleTests.swift`'s
`testShutdownBudgetsNestFromTheGuestOutwards`, which is the test that would
have caught the eroded margin sooner had it hardcoded the guest's real
derived value instead of a stale pre-Kubernetes one.

**Reporting.** `trim_before_shutdown`'s result is written into the same
`disk_last_trim_bytes` atomic the periodic sweep uses, so a control connection
that happens to land in the brief window between the trim and power-off would
see it — though in the ordinary case nothing queries `info` again once
shutdown has been requested, so this is honesty rather than a load-bearing
observability channel. `Doctor.diskTrimCheck`'s `nil`-case detail was updated
to say plainly that it is reporting on the periodic sweep only, and that
reclaim also happens on every stop independent of that counter — so a `nil`
reading on a freshly booted, previously-idled VM reads as "this line hasn't
seen one yet," not as "nothing is being reclaimed for you."
`TrackCDiskReclaimPresentation.reclaimSentence` similarly now says "reclaims
space ... automatically — periodically while the guest runs, and once more
every time it stops," rather than the narrower (and, for an auto-suspending
reader, largely untrue) "in the background."

### 8.5 Catching this class of bug again

Beyond this specific fix:

- `guest/morbinit/src/disk.rs` gained a test,
  `the_periodic_sweeps_warmup_outlives_the_default_auto_suspend_threshold_on_purpose`,
  which asserts — and documents *why* it is fine — that `TRIM_WARMUP_DELAY`
  exceeds the shipped default `auto_suspend_minutes`. It is deliberately not a
  "fix" assertion; it exists so that a future edit either shortening the
  warmup (chasing the race directly, §8.3 option 1) or deleting
  `trim_before_shutdown` (removing the thing that actually makes this safe)
  gets a nearby, explicit test failure pointing at this section instead of
  silently reintroducing the original bug.
- The bounded-wait mechanism itself (`poll_with_deadline` in `disk.rs`) was
  extracted as a pure, injectable-clock function specifically so "does the
  deadline actually stop the wait" is unit-testable on the macOS dev host in
  milliseconds, independent of a real `fstrim` binary or real wall-clock time
  — the property most likely to be gotten subtly wrong (checked before
  sleeping vs. after, measured from the wrong instant) and least likely to be
  noticed by hand, since it only shows up as an occasional slow shutdown.
- `morb doctor`'s `disk-trim` check (`Doctor.diskTrimCheck`) now says directly,
  in the `nil` case, that it can only see the periodic sweep and that reclaim
  also happens on every guest stop — see "Reporting" above.
- The general pattern is worth naming for whoever adds the next guest-side
  background timer: **if a mechanism's only trigger is "stay alive for N
  minutes," ask what stops the guest before N minutes elapse on a real
  developer machine, not just in the test environment it was written
  against.** On this project, on every host tested so far, the answer is
  "the default idle auto-suspend," and it wins.

### 8.6 Verification

Guest rebuilt with `mise run guest-image` (initramfs sha256
`8cabc4b35bfa88495144be205c05297b07546230ccf100fbf316b91b067c36e1`, 81 MiB /
83,855,910 bytes), `mac/.build/debug/morbstackd` re-signed with `mise run sign`
(entitlement verified). Run in an **isolated scratch `MORBSTACK_HOME`**
(`/tmp/mb-trim8`, its own `morbstackd`/VM/`disk.img`) rather than against
`dist/Morbstack.app` or the developer's real `~/.morbstack` — a real daemon
with three named containers was already running at the time and another
agent's `ui-tour` computer-use session was actively driving
`dist/Morbstack.app`, so this used a completely separate daemon instance
instead of rebuilding/re-signing the bundle those depended on. The guest
kernel (`vmlinux`, unmodified by this change) was copied read-only from
`~/.morbstack/data/kernel/` and its sha256 confirmed identical rather than
re-downloaded.

**Scenario A — the regression this ticket exists to fix**, reproducing the
exact originally-broken conditions: default `auto_suspend_minutes = 5`
(unchanged), a guest whose restore genuinely fails on this host (confirmed
live — see below — matching the project's own recorded finding that `vz`
save/restore is broken for direct-kernel guests on macOS 26.4), so an idle
timeout degrades to a real stop, well inside the old 10-minute warmup.

1. Booted the scratch VM. First idle cycle attempted a *real* suspend (no
   `save-restore-unsupported` marker existed yet in the fresh scratch home):
   `vm state -> suspended` at first, then on the next resume attempt,
   `restoring VM state failed: ... "invalid argument"; discarding
   /tmp/mb-trim8/data/vmstate.bin and cold-booting`, at which point
   `markSaveRestoreBroken` recorded the marker — reproducing, live, in this
   session, the exact host behavior the project's own notes describe, rather
   than assuming it.
2. Wrote 4 GiB of `/dev/urandom` to a container's writable layer, `sync`,
   measured `disk.img`'s allocated blocks (`stat -f %b`, 512-byte units):
   baseline 7,016,448 B → 4,314,341,376 B after the write (confirms real
   allocation).
3. `docker rm -f` the container (deleting the layer) plus another `sync`, **no
   discard, no trim** — the control step: allocated blocks stayed at
   4,316,041,216 B (+1.7 MB noise), confirming deletion alone reclaims
   nothing, exactly like the TECH-3 spike's control step.
4. Left the guest alone. At 300s idle (`idle for 300s with no running
   containers; suspending` / `suspend-to-disk unavailable here; stopping the
   guest instead`), the guest console log shows, in order:
   `shutdown: running a bounded disk-trim sweep before flushing` →
   `fstrim /var/lib/docker: 67039899648 bytes trimmed` → `flushing docker's
   data root` → `powering off`. The trim itself ran in **314 ms** of guest
   wall-clock (boot-relative timestamps 301154 ms → 301468 ms) — nowhere near
   the 15 s `TRIM_SHUTDOWN_DEADLINE` ceiling. The large reported figure (62.4
   GiB) is `fstrim` reporting the *filesystem's whole free extent set*, not
   just the one deleted file — the same effect the original TECH-3 spike's
   step 8 documented (§4), amplified here because this ext4 filesystem had
   never been trimmed before.
5. Host-side, immediately after the VM finished stopping:
   `disk.img` allocated blocks **4,316,745,728 B → 21,401,600 B** — a reclaim
   of **4,295,344,128 B (≈4.00 GiB)**, matching the deleted file almost
   exactly, with no `fstrim` run by hand anywhere in this sequence. Total wait
   from the last Docker activity to the guest fully stopped: the configured
   5-minute idle threshold, then well under 2 seconds of actual shutdown work.

**Scenario B — the pre-existing periodic sweep, confirmed still correct on
the rebuilt guest** (this exercises the refactored `run_fstrim`'s `None`
deadline / unbounded path specifically, since `run_fstrim` itself changed
shape in this commit even though `TRIM_WARMUP_DELAY`/`TRIM_INTERVAL` did not).
Rebooted the same scratch VM with `auto_suspend_minutes = 0` so it would stay
up past the periodic sweep's 10-minute warmup without an idle stop
intervening. Wrote and deleted a second (2 GiB) file the same way (control
step confirmed again: 2,172,248,064 B allocated after delete, no change from
before). At **exactly 600.4 s post-boot** — `TRIM_WARMUP_DELAY` to the
millisecond — the console log shows
`fstrim /var/lib/docker: 67025408000 bytes trimmed`, and `disk.img`'s
allocated blocks dropped from 2,172,248,064 B to 24,567,808 B, again with no
manual `fstrim` invocation. This confirms the periodic sweep — unchanged in
cadence, refactored in implementation — still does exactly what §7 shipped.

One honest gap, not part of this ticket's scope: `guest_disk_last_trim_bytes`
(the host-cached figure `morb status`/`morb doctor` show) is only refreshed on
the memory-balloon evaluator's own polling cadence (first tick at 5 minutes
when auto-suspend is disabled, then every 30 minutes — `VMManager`'s comment
on `_guestDiskLastTrimBytes` already says it "rides the balloon's existing
round trip" rather than polling separately). In scenario B the daemon's cached
value was still `null` via `morb status` a full 12 minutes into the boot, even
though the sweep had already reclaimed real space 2 minutes earlier —
confirmed directly from the guest's own console log and the host's `stat`,
not from that cached field. This is an existing, already-documented design
tradeoff (a dedicated poll would cost its own timer and round trip for a
figure nobody needs faster than "eventually"), not a new defect; it does mean
a `morb doctor` run shortly after a periodic sweep completes can still
legitimately show `nil` for a while. Worth a future ticket if the reporting
latency itself becomes the complaint; out of scope here, where the complaint
was that reclaim never happened at all.

The scratch environment's own daemon instances (two, needed for the
`auto_suspend_minutes` change between scenarios) were both stopped cleanly by
their own PIDs; neither the shared `~/.morbstack`, the shared `morbstackd`
that was independently running throughout most of this session, nor
`dist/Morbstack.app` were modified by this verification. That shared daemon
happened to receive an external `SIGTERM` and exit partway through this
session's testing (`2026-08-06 20:38:32 shutting down (SIGTERM)` in its own
log) — not from any command run here; nothing in this session's transcript
sent it a signal.
