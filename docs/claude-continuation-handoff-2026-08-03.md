# Codex continuation handoff — 2026-08-03

## Review target

Review `codex/claude-continuation` at `ccdfa60` (or its descendant). It forks
directly from the prior Claude consolidation branch
`code/native-content-continuation` at `7158f5d`; that baseline remains a
preserved ancestor, not a competing branch to merge. The preceding audit
handoff is [`claude-audit-handoff-2026-08-03.md`](claude-audit-handoff-2026-08-03.md).
This document supersedes its current-candidate status claims for the source
batch below.

Morbstack's goal remains a free, open-source, account-free native macOS Docker
Desktop replacement. Normal Docker compatibility comes before Kubernetes or
product differentiation. Source review must not become a compatibility claim:
**source-covered**, **bundled**, and **live accepted** are different states.

## Baseline and committed Codex work

The worktree is clean at this handoff. The integration branch contains these
closing checkpoints after the Claude baseline:

| Commit | Scope | Evidence status |
| --- | --- | --- |
| `e865d74` | Native Images document workflow for local archive load | Source-covered; hardened below |
| `f79a090` | Normalize rewritten chunked Docker creates | Focused relay tests/static handoff; live matrix pending |
| `eb12ae5` | Scope engine/proxy audit evidence to the dated candidate | Documentation only |
| `1f5d779` | Keep fixture Builds/Stacks from reaching external operations | Static source scan/model assertion; window/XCUITest pending |
| `34c052c` | Harden image archive loading and its review boundary | Focused tests/parse; app/Engine round trip pending |
| `3960359` | Stabilize `docker run -P` lifecycle owner/session behavior | FD-level test/parse; runtime lifecycle matrix pending |
| `ccdfa60` | Record native workflow decisions | Documentation only |

Earlier Codex commits on this branch also add native Compose lifecycle/source
review, image tag/remove/run, volumes/networks operations, Buildx builder/log
workflow, container inspector/observability, streamed Docker proxy endpoints,
and fixture/XCUITest coverage. Inspect the concise range with:

```sh
git log --oneline 7158f5d..ccdfa60
```

### History caveat

The earlier range `72541e3..b5037f8` was followed by compilation repair
`51016ff`; intermediate commits in that historical range are not bisectable.
Do not rewrite shared continuation history during audit. The current tip is the
review target and must be built/tested as a whole.

## Closing-batch findings and fixes

### Docker request framing

`f79a090` closes a create-path hole: a supported bind/dynamic port create that
arrived as `Transfer-Encoding: chunked` could not be safely forwarded after its
JSON body was rewritten. The narrow rewrite now preserves unrelated headers,
replaces exactly one framing declaration with `Content-Length`, and removes
stale `Trailer` declarations only when the body changed. No-rewrite chunked
bodies remain byte-exact. Coverage includes a 200 KB ordinary create,
`Expect: 100-continue`, keep-alive reuse, dynamic allocation, and trailers.

This is source-covered only. Exercise ordinary, chunked, `Expect`, bind,
fixed/dynamic TCP+UDP, malformed, and `-P` creates against the rebuilt guest.

### `docker run -P` lifecycle ownership

The audit found that a direct allocation worker stopped serving after success
but could keep its fd open while an HTTP/1.1 observer retained it. A later
restart-policy allocation could be sent to that open-but-dead worker and block
until Moby timed out. Direct admission and restart recovery could also race into
different guest/host sessions.

`3960359` gives `PortForwarder` one per-immutable-container owner ledger.
Restart-policy containers obtain a durable session before Moby sees a direct
start/restart; ordinary direct sessions survive only through their observed
reply and then deterministically shut down their fd. Recovery uses the same
serialized registration path. Exact-ID lifecycle admission performs a bounded
inspect to decide if durable ownership is required; failure rejects rather than
risk a misrouted allocation.

The FD EOF test is useful but insufficient. Do not call `-P` compatible until
the live matrix proves TCP and UDP initial start, direct restart on a persistent
API connection, automatic restart policy, direct/recovery contention, and cold
VM restart without a follow-up Docker CLI request.

### Native image archive load

Images now has an Apple-native document workflow: Image menu + compact archive
menu, system `NSOpenPanel`, review `Form`, standard confirmation, truthful
upload/wait states, and system notices. It calls only
`POST /images/load?quiet=1` on the local Engine; it does not parse archives,
infer tags, or contact registries.

`34c052c` fixes two blockers: the panel offers Docker-supported `.tar`, gzip,
bzip2, xz, and zstd tar filename forms; and review records size plus POSIX
device/inode. Confirmation opens once, `fstat`s the same descriptor, compares
all facts, and streams that descriptor. A same-size path replacement rejects
before opening an Engine socket. In-place mutation of the same open file is
explicitly not claimed to be detected. API-1.48+ platform selection is
intentionally absent.

It still needs a real `docker save` -> app load test for uncompressed and
compressed archives, plus light/dark/narrow/keyboard/VoiceOver review.

### Truthful fixture windows

`1f5d779` introduces `AppModel.permitsExternalOperations`. In
`--tour-fixtures`, Builds prevents Buildx history, active-builder, local-build,
and prune paths; Stacks prevents Compose source selection and lifecycle paths.
Handlers recheck the predicate before a direct socket, bundled process,
`NSOpenPanel`, or host action. Records remain inspectable; unavailable work uses
system disabled controls/help, `ContentUnavailableView`, or an inspector Form.

This closes a source-level contradiction where fixture chrome claimed no Docker
connection while routes could access the real socket. It still needs a fixture
window/XCUITest pass proving every entry point stays unavailable.

## Verification actually performed

- `git diff --check` before every closing commit.
- Focused `xcrun swiftc -frontend -parse` for archive-import, `-P`, and fixture
  source lanes.
- Focused source tests added/updated for archive selection/replacement identity,
  direct allocator fd retirement, relay framing, and fixture model permission.

**Not run for this closing batch:** full Swift/Rust suites,
`mise run cross-build-guest`, `mise run guest-image`, `mise run app`, signed
bundle verification, daemon/VM restart, Docker CLI acceptance, XCUITest, or
Computer Use. Treat new behavior as source-covered only.

## Required review and serialized acceptance

First read `CLAUDE.md`, `AGENTS.md`,
[`docs/design/README.md`](design/README.md), and
[`docs/development/codex.md`](development/codex.md). One owner must serialize
build and machine work. Never touch `~/.docker`; use a scratch `DOCKER_CONFIG`.
Keep scratch `MORBSTACK_HOME` short. Do not use `codesign --deep`, `nohup`,
`pkill`, or `killall`.

1. Review `f79a090`, `34c052c`, `1f5d779`, and `3960359` before expensive work.
2. Run `mise run test`, then `mise run cross-build-guest`; fix errors first.
3. Run `mise run guest-image`, then `mise run app`; verify bundled
   `morbstackd` retains `com.apple.security.virtualization`.
4. Cold-restart only the exact acceptance daemon PID in a short isolated home;
   prove the VM actually uses the current bundled initrd.
5. Rerun the engine matrix with scratch Docker config: fixed/dynamic publishes;
   chunked + `Expect` create; `-P` TCP/UDP initial/direct restart/restart
   policy/VM restart; bind write-through/refusal policy; aliases; streaming
   logs/exec/cp/events/stats; Compose and Buildx. Update the audit only with
   output tied to that candidate.
6. Run bundled XCUITest, then real Computer Use in light/dark and normal/narrow
   windows. Check fixture Builds/Stacks, archive menus/forms/panels, sidebar and
   inspector, search, menu reachability, toolbar overflow, keyboard, VoiceOver,
   and safe confirmations. Deliver actual Computer Use images in chat, not
   filesystem links.

## Priority after acceptance

1. Current-candidate engine acceptance: `-P`, framing, binds, aliases, disk
   growth, and clean-profile CLI/context behavior.
2. Testcontainers and Dev Containers.
3. Docker Desktop comparison: Compose/Buildx/images/volumes/networks,
   secrets/environment ergonomics, logs, and a real in-app exec PTY.
4. Second real-window UX/accessibility pass.
5. Only then domains/HTTPS, native volume access, debug toolbox, and machines.

## Handoff commands

```sh
git status --short
git log --oneline 7158f5d..HEAD
sed -n '1,260p' docs/claude-continuation-handoff-2026-08-03.md
mise run test
mise run cross-build-guest
```

Run guest-image, app, daemon, and real-window work only after source review and
only in the serialized machine lane.
