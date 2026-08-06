# CLAUDE.md — operational rules for agents working in this repo

This file is the **operational** source of truth: the landmines, the lane
discipline, and the commands that are safe to run. [`AGENTS.md`](AGENTS.md) is the
**design/workflow** agreement (native-macOS semantics, evidence standards, HIG
sources) and stays authoritative for those. When they overlap, this file wins on
"how do I run it without breaking the machine", AGENTS.md wins on "what should the
UI be".

Read this once before your first command. Every rule below cost somebody a
debugging session.

---

## 1. The landmines

### 1.1 `swift build` strips the virtualization entitlement

`morbstackd` cannot create a `VZVirtualMachine` without
`com.apple.security.virtualization`. **Every `swift build` strips it.** So:

- Signing is always the **last** step after the last build.
- `mise run sign` re-applies it to `mac/.build/debug/morbstackd`. If you rebuild,
  you must sign again before starting the daemon.
- **Never use `codesign --deep`.** `--deep` re-signs nested code with the *outer*
  invocation's arguments, which silently strips the entitlement off the bundled
  `morbstackd`. There is no build error. The symptom is a shipped app whose engine
  can never boot a VM.
- Bundle signing is **inside-out**: nested helpers first (`morb`, `morbstackd`
  with its entitlements, the bundled `docker`/`compose`/`buildx`), then the outer
  `Morbstack.app` on its own. The outer signature seals helpers by reference
  through `CodeResources` and leaves their own signatures and entitlements intact.
- The `app` task ends with a hard post-check that greps the entitlement back out
  of the signed daemon. **Do not remove it.** If you touch signing order, that
  check is the only thing standing between you and a dead shipped engine.

### 1.2 Never touch `~/.docker`

The user's `~/.docker/config.json` carries a `credsStore` that **hangs the Docker
CLI** when its helper cannot answer (see `docs/parity.md`). A hung `docker` call
will eat your turn and can wedge the terminal.

- Always run docker commands with a scratch config:
  `DOCKER_CONFIG="$(mktemp -d)" docker ...`
- Never write, move, back up, or "clean" `~/.docker`. Not the config, not
  `cli-plugins`, not `contexts`, not `~/.docker/run/docker.sock`.
- Morbstack's own context code goes out of its way to preserve a user's
  `config.json` symlink, mode bits, `auths`, `credHelpers` and `credsStore`
  (`mac/Sources/MorbstackKit/MorbDockerContext.swift`). Do not "simplify" that —
  it is protecting real registry credentials.

### 1.3 The 104-byte unix socket path limit

`sockaddr_un.sun_path` is 104 bytes on Darwin, NUL included
(`mac/Sources/MorbstackKit/UnixSocketServer.swift`). Every Morbstack socket lives
under `$MORBSTACK_HOME` (default `~/.morbstack`).

If you set `MORBSTACK_HOME` to a scratch directory — which tests and clean-profile
runs do — **keep it short**. `$(mktemp -d)` on macOS returns
`/var/folders/xy/…/T/tmp.XXXXXXXX`, which is already ~50 characters before
Morbstack appends `data/run/docker.sock`. Prefer something like
`/tmp/mb-$$` and expect `socket path too long` if you get greedy.

### 1.4 Foreground only, no `nohup`, PID-scoped kills

- Run the daemon in the foreground (`morbstackd --foreground`) in a backgrounded
  tool call you own, not detached with `nohup`/`&` and forgotten. A detached
  daemon outlives your session and the next agent inherits a stale engine.
- Kill by the **PID you started**. Never `pkill -f morbstackd`, never
  `killall`. Another agent (or the user's own running app) is very likely holding
  a daemon you did not start.
- Same for the app: launch `dist/Morbstack.app`, don't `killall MorbstackApp`.

### 1.5 `mise run app` does NOT rebuild the guest image

The `app` task assembles and signs the bundle from host binaries only. The
bootable initramfs (`morbinit` as PID 1, the unmodified upstream Docker engine, the
Alpine rootfs) is built by a **separate** task:

```sh
mise run guest-image     # cross-builds morbinit, fetches pinned stock dockerd, writes $MORBSTACK_HOME/data/kernel/initrd.img
```

If you changed anything under `guest/morbinit/` and only ran `mise run app`,
**you tested the old guest**. This has produced false "the fix didn't work"
conclusions before.

`guest-image` needs the `aarch64-unknown-linux-musl` cross toolchain
(`dist/CROSS_COMPILE.md`). As of 2026-08-04 (TECH-1) it does not need Docker or
`docker buildx` at all — the guest engine is fetched as a pinned, hash-verified
upstream binary like every other third-party guest asset, not built locally. See
`docs/design/PATCH-FREE-PUBLISH-ALL.md`.

### 1.6 The offscreen renderer is not visual evidence

`swift run MorbShots` and `mise run shots-live` cannot composite the titlebar,
toolbar, inspector, sidebar materials, or Liquid Glass — those are drawn by
WindowServer, not by the view. An offscreen render that "looks fine" proves
nothing about the real window, and has misled this project before.

Real visual evidence, in increasing authority:

| Layer | What it proves |
| --- | --- |
| `swift run MorbShots` | fixture/route invariants, **no visual claim** |
| `mise run shots-live` | routes render in a real light/dark window, still no chrome claim |
| XCUITest (`mac/UITests/`) | accessibility identifiers, focus, keyboard, real bundled app |
| Computer Use on `dist/Morbstack.app` | the only authoritative full-window review |

The `ui-tour` skill drives the last one. Use it after any UI change.

### 1.7 Design law

If the system draws it, let the system draw it. Do not rebuild a design system in
the content layer.

- [`docs/design/DECISIONS.md`](docs/design/DECISIONS.md) — binding decisions
- [`docs/design/tahoe/HIG-FINDINGS.md`](docs/design/tahoe/HIG-FINDINGS.md) — macOS 26 / Liquid Glass findings with citations
- [`docs/design/NATIVE-MACOS-PLAYBOOK.md`](docs/design/NATIVE-MACOS-PLAYBOOK.md) and [`docs/design/HIG-COVERAGE-AUDIT.md`](docs/design/HIG-COVERAGE-AUDIT.md) — route-level decision record

The normal vocabulary is `NavigationSplitView`, `Table`, `Form`,
`LabeledContent`, `.inspector`, `.searchable`, `Menu`,
`ContentUnavailableView`, Swift Charts.

### 1.8 "All functional, no coming soon"

The standing product rule: no placeholder screens, no disabled "coming soon"
buttons, no `--help` text that promises behaviour the implementation does not
have. If a feature is not ready, the honest state is a real
`ContentUnavailableView` that says what is actually true — not a stub.

---

## 2. Lane discipline (multi-agent)

Expensive and machine-global operations must be **serialized to one owner**:

| Lane | Owns | Nobody else may |
| --- | --- | --- |
| Build lane | `swift build`, `swift test`, `cargo build/test`, `mise run build*`, `mise run test` | run those concurrently — SwiftPM will contend on `mac/.build` |
| Machine lane | `mise run app`, `mise run sign`, `mise run run-daemon`, `mise run guest-image`, launching the app, starting containers | rebuild or re-sign the bundle out from under the running app |

Everything else — reading code, writing focused tests, static checks, docs — is
safe in parallel. Say which lane you are in when you hand off.

---

## 3. Commands

```sh
mise trust && mise install     # first checkout only; mise refuses to read an untrusted config,
                               # so this cannot be `mise run setup` on a fresh clone
mise tasks                     # what is available
mise run build-mac             # Swift host binaries
mise run build-guest           # morbinit, host arch (see caveat below)
mise run test                  # Swift + Rust suites
git diff --check               # before every handoff
```

Caveats worth knowing:

- `mise` runs a multi-line task body as **one shell**, unlike make's fresh shell
  per line. A bare `cd` leaks into every subsequent line. Existing tasks wrap `cd`
  in subshells — `(cd mac && swift build)` — keep doing that.
- `cargo build`/`cargo test` on macOS compile only a fraction of `morbinit`:
  ~85 `#[cfg(target_os = "linux")]` gates across 19 of 22 source files mean the
  real guest paths are only type-checked by `mise run cross-build-guest`.
- `swift build --build-tests` is not implied by `swift build`. A test file that
  does not compile will not be noticed by a plain build. Run
  `swift build --package-path mac --build-tests` before claiming a change is green.
- `mise run test 2>&1 | tail` **masks the exit code** — the pipeline reports
  `tail`'s status. Capture `$?` directly or use `PIPESTATUS`.

---

## 4. Repository map

| Path | What it is |
| --- | --- |
| `mac/Sources/MorbstackKit` | engine/daemon core: VM lifecycle, vsock relay, port forwarding, docker context, disk growth |
| `mac/Sources/MorbstackAppCore` | SwiftUI app views and models |
| `mac/Sources/MorbstackApp` | app entry point |
| `mac/Sources/MorbFeatures`, `MorbMCP`, `MorbMigrate`, `MorbBench`, `MorbScan`, `MorbExport` | library targets consumed by the `morb` CLI |
| `mac/Sources/morb`, `morbstackd` | CLI and daemon executables |
| `mac/Sources/MorbShots`, `MorbLive` | fixture/route probes (see §1.6) |
| `guest/morbinit` | Rust PID 1 for the guest, std-only, no third-party crates |
| `guest/morbinit/src/proxy_wrapper.rs` | the userland-proxy wrapper that makes published ports (including `-P`) reachable via dockerd's stock `--userland-proxy-path` hook — no engine patch (see `docs/design/PATCH-FREE-PUBLISH-ALL.md`) |
| `scripts/` | asset fetch (all sha256-pinned), initramfs build, DMG |
| `dist/` | vendored payloads; only `PROVENANCE.txt`/`TOOLCHAIN.plist`/`CROSS_COMPILE.md` are tracked |

---

## 5. Known-bad state to be aware of

- The remote is `git@github.com:alliecatowo/morbstack.git` and **CI does execute**
  — check it rather than guessing: `gh run list --limit 5`, `gh run view <id>
  --log-failed`. This entry used to say there was no remote and CI had never run;
  that was true until 2026-08-04 and false after, and agents were acting on it.
  The README's CI badge still points at a `morbstack/morbstack` org that does not
  own this repo, so the badge is broken and is not evidence of anything.
- `swift test` used to fail on tests that bound **real host ports** (5353 is owned
  by mDNSResponder on any normal Mac) and on stale expectations. As of 2026-08-05
  `mise run check` is green — 1009 Swift, 260 Rust, 0 failures. Treat a red suite
  as a regression to investigate, not as the expected state.
  `docs/audit/REPO-AUDIT.md` holds the historical list.
