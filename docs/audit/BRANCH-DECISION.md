# Branch decision: `code/native-content-continuation` → `main`

**Date:** 2026-08-03 · **Decided by:** orchestrator session · **Verdict: MERGE, as a fast-forward, once the test target compiles.**

## The merge is not a merge

```
git merge-base --is-ancestor main code/native-content-continuation  →  true
git log --oneline main --not code/native-content-continuation       →  (empty)
```

`main` is a strict ancestor. There is no divergence, no conflict, and nothing on `main` to
rescue. Promoting the branch is `git merge --ff-only`. `main` is 7 commits; the branch is 273.

## What the branch deletes, and why that is correct

Twenty files disappear between `main` and the branch. Every one of them is something this
project had already formally retired:

| Deleted | Retired by |
| --- | --- |
| `Theme.swift`, `Design/Morb{Brand,Card,Chip,EmptyState,Glass,GroupState,Metric,Motion,Row,Status,Toolbar}.swift` | [DECISIONS.md](../design/DECISIONS.md) §2 — "the custom visual system is retired"; no replacement token library or compatibility wrapper is allowed |
| `Shots/Shot{Renderer,Scenes,Chrome}.swift` | DECISIONS.md §6 — the offscreen render path cannot validate WindowServer-owned chrome and produces no visual acceptance evidence |
| `TrackCChrome.swift`, `TrackDChrome.swift`, `TrackCConfirmSheet.swift`, `ContainerListRow.swift` | §2 — hand-drawn chrome and custom row rendering, superseded by `Table` |
| `MorbMCP/Placeholder.swift` | replaced by a real implementation |

This is the "if the system draws it, let the system draw it" rule being carried out, not
work being lost.

Everything load-bearing from the earlier line survives: `docs/design/DECISIONS.md`,
`docs/design/tahoe/HIG-FINDINGS.md`, `docs/parity.md`, `scripts/ui-tour.sh`,
`.claude/workflows/ui-tour.js`, `mise.toml`.

## Blocking condition

Do not promote until the test target compiles. At tip `54de308`:

```
swift build --package-path mac --build-tests
mac/Tests/MorbstackKitTests/DockerContextTests.swift:29:46: error: incorrect argument label
  in call (have '_:atPath:', expected '_:ofItemAtPath:')
mac/Tests/MorbstackKitTests/DockerContextTests.swift:56:120: error: value of optional type
  'Int?' must be unwrapped to a value of type 'Int'
```

The app target builds and the bundle signs; only the tests are broken. That is the tell —
`mise run app` was run and `mise run test` was not, so the whole 273-commit wave landed
without a green suite. See [REPO-AUDIT.md](REPO-AUDIT.md).

## The guest image is stale, and it invalidates a large block of the wave

Independently verified, not taken from the handoff doc:

| Artifact | Built | Source last changed |
| --- | --- | --- |
| `~/.morbstack/data/kernel/initrd.img` (the image the VM actually boots) | 2026-08-02 19:46 | `guest/morbinit/` → 2026-08-03 14:36 |
| `dist/guest-bin/dockerd` | 2026-08-01 16:02 (upstream fetch) | `guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch` |

`strings dist/guest-bin/dockerd | grep -c morbstack` → **0**. The shipped engine binary is
unpatched upstream Moby. The publish-all host allocator is not in any built artifact, and
roughly nineteen hours of guest-side commits are not in the image the VM boots.

Consequence: the twelve-commit "Port parity and Moby `-P` handoff" block, the two
file-notification transport commits, and the guest half of the disk-grow transaction have
never executed anywhere. They are source, not behaviour. Any live test run today measures
the Aug 2 guest.

## Recommended sequence

1. Fix the two test compile errors; get a genuinely green `mise run test`.
2. `git checkout main && git merge --ff-only code/native-content-continuation`.
3. Rebuild the guest image (`mise run guest-image`, which needs `build-patched-dockerd`
   first) in a single serialized lane, then re-run the port / live-share / disk matrices.
   Until then, label those features source-only.
