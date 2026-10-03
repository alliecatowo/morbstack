# Driving the memory balloon (UX-17)

`VMManager` has attached a `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`
since the guest's earliest network device configuration, and nothing in
`mac/Sources` has ever set `targetVirtualMachineMemorySize` on the resulting
`VZVirtioTraditionalMemoryBalloonDevice`. The device exists; it has never
been driven. This is the smallest defensible fix: a slow-timer policy that
tracks the guest's *own* memory accounting and reclaims only what it reports
as genuinely spare, in bounded steps, restoring immediately and fully the
moment the guest looks like it wants the memory back.

## What signal is actually available

Apple's `VZVirtioTraditionalMemoryBalloonDevice` is **host-to-guest only**.
There is no host-visible stats feedback channel — unlike, say, QEMU's
`virtio-balloon` with `VIRTIO_BALLOON_F_STATS_VQ`, which reports guest memory
statistics back through the balloon device itself, Apple's traditional
balloon gives the host a single write-only knob
(`targetVirtualMachineMemorySize`) and nothing else. Whatever signal drives
that knob has to come from somewhere else entirely.

The only channel that exists is the one Morbstack already built: MRB0, the
guest control protocol on vsock 1024. UX-17 extends its `info` reply with two
additive fields, read fresh on every request (unlike every other `info`
field, which is a boot-time fact frozen once):

- `mem_total_kb` — the guest kernel's `/proc/meminfo` `MemTotal`
- `mem_available_kb` — the guest kernel's `/proc/meminfo` `MemAvailable`

**`MemAvailable`, not `MemFree`.** `MemFree` counts only genuinely unused
pages and ignores the page cache and reclaimable slab entirely, which would
make an ordinary, healthy Linux guest — one that has simply done some file
I/O, which is most of what a container engine does — look artificially
starved. `MemAvailable` is the kernel's own estimate (documented in
`Documentation/filesystems/proc.rst`) of memory available for starting a new
application without swapping, accounting for reclaimable cache. It is
designed to answer exactly the question a balloon driver needs answered:
"how much could I take away right now without causing trouble." This is not
a novel choice — it is the same class of signal production balloon
auto-tuning has used for years (libvirt's `virsh dommemstat`/auto-balloon
tooling and comparable QEMU-based schemes read the analogous "available"
stat off the guest for the identical reason).

**Is this signal good enough to act on automatically?** Yes, with real
caveats that shape the policy below, not with none:

- It is a snapshot, not a forecast. `MemAvailable` says nothing about a
  `docker build` about to start in the next thirty seconds.
- It is guest-kernel-reported, so it is only as trustworthy as MRB0 itself —
  fine here, since the guest has no reason to lie and the channel is not
  network-reachable.
- It is sampled on a slow timer (memory pressure that spikes and resolves
  faster than the sample interval is invisible to this policy by
  construction — which is the correct trade for a background reclaimer, not
  a defect: driving the balloon *itself* costs guest CPU and can transiently
  stall allocations while pages are surrendered, so reacting to every
  transient would cost more than it saves).

None of that makes the signal "too coarse to use" — it makes it a signal
that must be used conservatively. That is what the policy below does.

## The policy (`MemoryBalloonPolicy.swift`, pure and unit-tested)

`MemoryBalloonPolicy.nextTarget(previousTargetBytes:sample:configuration:)`
is a pure function: no IO, no VM, no timers — every asymmetry described
below is a unit test in `MemoryBalloonPolicyTests.swift`, not a comment
somebody has to trust.

- **No sample, no guess.** A missing or internally inconsistent sample
  (`nil`, or `availableKB > totalKB`, or a non-positive `totalKB`) changes
  nothing. A guest too old to report the fields, or one whose one-shot
  `/proc/meminfo` read failed, gets the same answer: hold whatever the
  balloon is already at.
- **A floor the policy will not cross.** `floorFraction` (default 25%) of
  the VM's configured memory, or `minimumFloorBytes` (default 1 GiB),
  whichever is larger, and never above the configured memory itself. The
  balloon will never ask the guest to run on less than this regardless of
  how idle `/proc/meminfo` says it is.
- **Headroom on top of the guest's own number.** The target is not "what the
  guest is using right now" — it is that plus `headroomFraction` (default
  35%) or `minimumHeadroomBytes` (default 512 MiB), whichever is larger.
  `MemAvailable` is a snapshot; the headroom is the margin against the next
  few minutes of activity that snapshot cannot see.
- **Growing back is immediate and unthrottled.** The moment the computed
  target is *above* the current balloon target, the policy returns it
  outright — no step limit, no waiting for the next slow tick to catch up.
  Reclaiming too slowly costs nothing but held-but-idle host RAM; restoring
  too slowly costs the guest a stall or, in the worst case, an OOM kill. The
  two directions are not symmetric risks, so the policy does not treat them
  symmetrically.
- **Shrinking is bounded per step.** At most `maxShrinkStepFraction`
  (default 15%) of the current target is given up in any single evaluation.
  A guest that has been busy and then goes idle gives memory back gradually
  across several slow-timer ticks, not in one potentially large jump.
- **Hysteresis in both directions.** A change smaller than
  `minimumAdjustmentFraction` (default 3%) of configured memory, or
  `minimumAdjustmentBytes` (default 64 MiB) — whichever is larger — is
  treated as noise and produces no change at all. This is what keeps a
  guest whose usage is oscillating right at a threshold from generating a
  `targetVirtualMachineMemorySize` write on every tick.

## What drives it (`VMManager.swift`)

A slow timer (30 minutes — see the constant and its own reasoning in
source) polls `GuestControl.info()` while the guest is control-ready and
`state == .running`, computes the next target, and — only when the policy
actually returns a new value — hops onto the VM's dispatch queue to set
`targetVirtualMachineMemorySize` on the live balloon device. Every step is
guarded by the same boot-generation check `beginControlProbe` already uses
(`CONC-2`'s fix), so a stale evaluation from a superseded boot cannot clobber
a fresh one's target. The tracked "previous target" resets to the VM's full
configured memory on every fresh boot (`setControlReady(true)`) and stops
being evaluated the moment the guest is no longer known-ready
(`setControlReady(false)`) — the same lifecycle hooks that already gate the
existing control probe.

**30 minutes, not the auto-suspend cadence.** Auto-suspend's 30 s idle-check
timer answers "is anything talking to this VM at all"; the balloon question
— "has the guest's actual memory need changed" — moves far slower than
connection activity and does not need to be re-evaluated every half minute.
A slower cadence also means fewer guest control round trips for a benefit
that, by design (the bounded step + hysteresis above), cannot materialize
faster than several ticks anyway.

**The first tick does not wait a full 30 minutes.** This was found live and
fixed in the same change as this note: with the default
`auto_suspend_minutes = 5` and a *fixed* 30-minute repeating timer, the VM
idle-suspends — cancelling the balloon timer along with it (`setControlReady(false)`,
above) — six times over before the interval's first tick could ever fire.
Reproduced directly: a VM suspended at 315 s idle, 3.5 minutes short of a
30-minute deadline that was never close. UX-17 had shipped as inert code
under the shipped default.

`MemoryBalloonPolicy.firstEvaluationDelay(autoSuspendMinutes:interval:...)`
(pure, unit-tested in `MemoryBalloonPolicyTests.swift`) fixes this by giving
the *first* tick a shorter deadline than the steady-state 30-minute
`interval`, without changing that steady-state cadence at all:

- **Auto-suspend enabled:** half of the auto-suspend window (floored at 30 s
  so the first read is not taken before the guest has had time to settle
  post-boot). Half, not "just under," leaves real margin — for the default
  5-minute window that is a first tick at 2.5 minutes, comfortably ahead of
  the 5-minute suspend deadline rather than racing it.
- **Auto-suspend disabled (`0`):** a fixed 5-minute default first tick, so an
  always-on guest still gets an early evaluation rather than waiting the full
  30 minutes with no deadline forcing the question.
- Either way, the result is capped at `interval` itself — "early" is only
  meaningful relative to the normal cadence, never longer than it.

Three options were weighed for this fix, and the one above was chosen
deliberately rather than by default:

1. *Shorten the 30-minute interval outright.* Rejected: it would make the
   steady-state busy-all-day case — the one case this policy actually
   exists for — re-sample and potentially re-write the balloon target far
   more often than the bounded-step/hysteresis design calls for, for no
   benefit to that case.
2. *Defer or reset auto-suspend until the balloon has evaluated at least
   once.* Rejected: auto-suspend is a setting the user configured for an
   unrelated reason (return memory/CPU promptly when idle); silently
   stretching it to let an unrelated subsystem get its first sample would be
   a surprising interaction the user did not ask for.
3. *Make the first evaluation happen early, chosen above.* This is honest
   about what the balloon is actually for: a VM idle enough to auto-suspend
   inside one interval does not need ballooning at all, because suspend
   already returns all of its memory (see "What this does not cover" below,
   unchanged). The fix does not try to make ballooning relevant to that
   case — it only makes sure a VM that turns out to be busy past the
   auto-suspend window, or never idle at all, gets its first real
   evaluation promptly instead of accidentally never getting one.

## What this does not cover, on purpose

- **The 5-minute auto-suspend window.** A VM that goes idle for 5+ minutes
  is stopped entirely by the existing auto-suspend policy, which returns
  *all* of its memory — a strictly better outcome than any balloon target
  this policy could compute. The balloon only matters for the case
  auto-suspend cannot serve: a VM that is busy all day, on and off, and
  therefore never idle long enough to suspend, but that is not always using
  the memory it was given an hour ago.
- **"Dynamic memory" as marketing copy.** Nothing in this change adds that
  phrase anywhere a user can see it, and nothing should until real
  measurement (via `MorbBench`, comparing host RSS reclaim against a
  realistic idle-then-busy workload) backs the claim. A balloon that thrashes
  is a bug users experience as random container deaths, and this repo has a
  standing rule against shipping a capability claim ahead of the evidence
  for it.
