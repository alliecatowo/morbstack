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

## Smallest truthful design once unblocked

The implementation must begin with a guest delivery mechanism, not a host
watcher. A guest-local synced-share filesystem is one plausible architecture:
the guest synchronizer changes files on a guest-owned filesystem, so normal
Linux notification machinery can report those changes to watchers. Any other
approach needs equivalent proof that it causes real observer-visible Linux
events; a made-up inotify mask is not acceptable.

Once that mechanism exists, the smallest host lifecycle is:

1. Validate `MorbLiveShareBridge.Plan` from only explicit, narrow
   `live_share_paths`. Keep the configured root and its guest-side mapping as
   one immutable session record; never infer broad paths such as `/Users` or
   `/Volumes`.
2. Wait for the exact backing VirtioFS/sync root to be mounted and for the
   guest to advertise a versioned **ready** receiver. The additive
   `share_event_bridge_contract_version: 1` field alone is only a schema
   reservation; it cannot satisfy this gate. Until both facts are observed,
   state remains `waiting-for-guest-mount` or `delivery-unavailable`; no
   FSEvent stream exists.
3. Create the FSEvent stream in a daemon-owned lifecycle object. Feed its
   callback directly into the existing `EventBuffer`; retain the current
   scoped-path filtering, 4 KiB path bound, and rescan conversion rules.
4. Deliver ordered, bounded batches over a dedicated protocol (or a genuinely
   duplex successor to MRB0), with a session ID, contract version, monotonic
   delivery sequence, and explicit acknowledgement. The host removes records
   only after acknowledgement. A reconnect, rejected sequence, guest restart,
   timeout, or failed acknowledgement replaces pending incremental records
   with a `rescan` for every selected root before delivery resumes.
5. Stop the stream and discard the session whenever the VM stops, the receiver
   loses readiness, the share configuration changes, or the selected roots no
   longer match the active mapping. Do not carry unacknowledged incremental
   records across a session boundary.

`rescan` is not a normal event. The guest receiver must discard incremental
state for that root, rebuild it recursively, then acknowledge the rescan only
when it is again safe to accept later records. This preserves the existing
loss/overflow contract instead of silently pretending a dropped directory
event was a write notification.

## Required status and acceptance evidence

The first real implementation may report these factual states through the
existing shares/status surface: disabled, invalid configuration,
waiting-for-guest-mount, delivery unavailable, starting, active, resyncing,
and failed. Active status must include the selected root count and last
acknowledged delivery sequence; resyncing must expose the affected root count
and rescan reason. These are observations, not a toggle.

Before claiming the capability, acceptance must prove all of the following in
a real guest/container:

- a Mac edit in a configured root is observed by a Linux file watcher without
  polling;
- a path outside the configured roots is never watched or transmitted;
- rename-heavy activity, FSEvents drops, queue overflow, receiver restart,
  VM stop/start, and transport reconnect each force the documented rescan
  behavior rather than silently continuing incrementally; and
- a disabled, unmounted, unavailable, or failed receiver creates no host
  watcher and makes no hot-reload claim.

Until then, use the polling guidance in [sharing.md](sharing.md). The complete
current wire/failure contract remains in [protocol.md](protocol.md#54-future-scoped-file-event-contract).
