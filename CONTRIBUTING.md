# Contributing to Morbstack

Thanks for your interest in contributing. Morbstack is young (milestone
M0) and still moving fast, so please open an issue to discuss non-trivial
changes before sending a large PR.

## Licensing and sign-off (DCO, not a CLA)

Morbstack is Apache-2.0 and does not require a CLA (Contributor License
Agreement) — you keep copyright in your own contributions. Instead, every
commit must carry a `Signed-off-by` trailer certifying you wrote it, or
otherwise have the right to submit it, under the
[Developer Certificate of Origin (DCO) 1.1](https://developercertificate.org/):

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.
1 Letterman Digital Arts Center, Suite 500, San Francisco, CA 94129

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

**Why DCO and not a CLA:** a CLA reassigns or broadens rights over your
contribution to the project (or a company behind it); the DCO does not —
it is only a statement that you had the right to submit the code under
Morbstack's existing license. That keeps the barrier to a first PR low
(no separate agreement to sign, nothing to fax) while still giving the
project a paper trail proving every line was legitimately contributed,
which matters for an Apache-2.0 project that intends to be trusted with
`com.apple.security.virtualization` and root-equivalent access to a Docker
socket.

Add the trailer automatically:

```sh
git commit -s -m "your message"
```

This appends `Signed-off-by: Your Name <your@email.com>` using the name
and email from your `git config`. If you forgot on your last commit,
`git commit --amend -s` fixes it before you push. Squash/rebase merges
must preserve the sign-off trailer from the original commits — GitHub's
"Squash and merge" does this automatically when every commit being
squashed already has one.

## Development environment

You need two toolchains: Xcode (for the Swift host daemon/CLI/app under
`mac/`) and [mise](https://mise.jdx.dev/) (which pins the Rust toolchain
for the guest PID 1 under `guest/morbinit/`).

- **Xcode 26 or later** — installs the Swift 6.3 compiler and
  `Virtualization.framework`, both required. `mac/Package.swift` declares
  `swift-tools-version: 6.2` and a `macOS(.v26)` deployment target.
- **[mise](https://mise.jdx.dev/)** — pins the Rust toolchain
  (`mise.toml`: `rust = "stable"`) so every contributor and CI build
  against the same compiler. Swift is not mise-managed; it comes from
  whatever Xcode you have selected via `xcode-select`.
- **The `aarch64-unknown-linux-musl` cross toolchain** — only needed if
  you touch anything under `guest/morbinit`'s `#[cfg(target_os =
  "linux")]` boundary (most of `mounts.rs`, `sys.rs`, `disk.rs`, the real
  init sequence in `main.rs`) or you need to boot a real guest to check a
  change. Installed via Homebrew:

  ```sh
  brew tap messense/macos-cross-toolchains
  brew install messense/macos-cross-toolchains/aarch64-unknown-linux-musl
  ```

  See [`dist/CROSS_COMPILE.md`](dist/CROSS_COMPILE.md) for the full
  working recipe (cargo config, linker wiring, verification steps) this
  was derived from. You do **not** need this just to edit
  non-Linux-gated `morbinit` code or run the Rust unit test suite — see
  "Building and testing" below.

## Building and testing

On a fresh clone, `mise run` itself needs the config trusted before it can
even find the task list, so the very first command is the literal `mise
trust && mise install`, not a task:

```sh
mise trust && mise install   # one-time bootstrap
mise run build                # builds morbstackd, morb, and morbinit (host-arch dev build)
mise run test                 # runs the Swift and Rust test suites
```

(`mise run setup` runs the same `mise trust && mise install` and is fine to
use afterwards, e.g. once a change bumps the Rust pin — just not as the
literal first command on a fresh clone.)

`mise run build`/`mise run test` build `morbinit` for the host architecture
(macOS), which is enough to run the Rust unit test suite and to edit any
code outside the `#[cfg(target_os = "linux")]` boundary. If your change
touches that boundary, or you need to boot a real guest to verify it, you
additionally need:

```sh
./scripts/fetch-guest-assets.sh   # fetch + hash-verify kernel, Docker, Alpine, fsutils, compose
mise run guest-image              # cross-compile morbinit + assemble the initramfs
mise run run-daemon                # build, sign, and run morbstackd in the foreground
```

See [`README.md`](README.md) "Running" for the full walkthrough, including
the `DOCKER_HOST` step and the one-time `docker compose` plugin symlink.

**If you're iterating on `morbstackd` outside of `mise run run-daemon`**: a
plain `swift build` re-signs `morbstackd` ad-hoc and silently strips the
`com.apple.security.virtualization` entitlement `mise run sign` adds, so a
manually rebuilt binary that was signed before the rebuild fails to open a
VM with a confusing error rather than an obvious "not signed" one. `mise
run sign` (which `run-daemon` already depends on) must be the last build
step before starting the daemon.

Other useful tasks (see [`docs/build.md`](docs/build.md), or run `mise
tasks ls`, for the full, current list — `mise.toml` is now the single
source of truth for build logic):

- `mise run app` — assembles a launchable `Morbstack.app` bundle in `dist/`.
- `mise run run-app` — builds and opens it.
- `mise run clean` — removes build outputs for both toolchains.

A `make` compatibility shim (`make build`, `make sign`, `make app`, ...)
still exists in the root [`Makefile`](Makefile) for anything not yet
updated to call `mise run` directly — every target in it just forwards to
the matching mise task.

## Repo layout

```
mac/                Swift: morbstackd (daemon), morb (CLI), MorbstackApp
                     (SwiftUI), and the shared MorbstackKit/MorbstackAppCore
                     libraries. See mac/Package.swift for the exact
                     product/target list — it changes as the app grows.
guest/morbinit/      Rust: the guest's PID 1 — mounts, service supervisor,
                     vsock control server. Zero crates.io dependencies.
proto/               The target gRPC control-plane contract
                     (proto/morbstack/v1/control.proto) — not yet
                     implemented; MRB0 (see docs/protocol.md) is what
                     actually ships today.
scripts/             Bash: fetching/verifying third-party guest assets,
                     assembling the initramfs, disk image creation, the
                     UI tour harness, and other dev-loop tooling.
dist/                Build/runtime outputs and provenance records.
                     Gitignored except PROVENANCE.txt files and
                     dist/CROSS_COMPILE.md — see NOTICE for why.
docs/                Architecture, protocol, compatibility, and roadmap
                     documentation — the authoritative detail behind the
                     README's summaries.
```

## Code style

- **Swift** (`mac/`): standard Swift API design guidelines, 4-space
  indentation. No third-party SPM dependencies — Foundation and system
  frameworks only, so the build works offline. Prefer `struct` and value
  types where possible; keep `Virtualization.framework` calls isolated
  behind small, testable wrappers rather than scattered through business
  logic.
- **Rust** (`guest/morbinit/`): run `cargo fmt` and keep `cargo clippy`
  clean before submitting. No crates.io dependencies — std only, plus
  hand-rolled FFI to libc where needed (see `sys.rs`). As PID 1 in the
  guest, `morbinit` must handle errors defensively; avoid panics on the
  main control-loop path — a panic there takes the whole guest down.
- **Comments are heavy and explain *why*, not what.** This codebase
  consistently favors long, specific doc comments over terse code —
  Makefile recipes, protocol handlers, and module headers all explain the
  reasoning, the failure mode being avoided, and often a specific
  incident that led to the current design (see `docs/k8s.md`'s
  case-sensitivity bug, or the `DOCKER_RAMDISK` note in
  `docs/architecture.md`, for the prose version of the same habit). Match
  that: a comment restating what the next line already says is not
  useful, but a comment explaining why the obvious alternative doesn't
  work is exactly what this project wants.
- **No emoji**, anywhere — code, comments, commit messages, or docs.
- **Commit messages**: short imperative summary line, body explaining
  motivation when it's not obvious from the diff alone.

## Running the parity/compat checks

Two different things live under `docs/`, and they answer different
questions:

- **`docs/compat.md`** is the forward-looking *contract*: what "drop-in"
  means, and the CI-enforced ecosystem matrix (Testcontainers, Dev
  Containers, JetBrains, compose-spec conformance, etc.) targeted from M2
  onward per `docs/roadmap.md`. There is no separate script to run today —
  it's aspirational scope, tracked here so it doesn't drift.
- **`docs/parity.md`** is a point-in-time, manually-run audit against a
  real cold-booted VM (not simulated, nothing asserted from reading
  source) that answers "for the claim 'same docker CLI, same Engine API,
  same Compose files, same everything,' where is that true today, and
  where does it break?" It documents its own method at the top of the
  file: build once, copy the binaries out to an isolated directory so a
  concurrent `swift build` from another session can't strip the daemon's
  entitlement mid-run, and exercise a real `MORBSTACK_HOME` end to end. If
  you're proposing a fix for one of its FAIL/PARTIAL rows, re-running the
  specific check by hand against your own build (following that same
  method) and reporting the before/after in your PR is far more
  convincing than a description of the fix alone.

## The PR process

1. For anything beyond a small, obviously-correct fix, open an issue
   first describing the change — this project moves fast and a large PR
   against a moving target is expensive for everyone to review.
2. Keep commits signed off (`git commit -s`) and the sign-off intact
   through any rebase.
3. `mise run build && mise run test` must pass locally before you open the
   PR; CI runs the same tasks (see
   [`.github/workflows/ci.yml`](.github/workflows/ci.yml)) and will not
   merge on a red build.
4. Update the relevant `docs/*.md` file in the same PR as the behavior
   change it documents — this project treats stale docs as a defect, not
   a follow-up.
5. Fill out the PR template's DCO and tests-run checkboxes honestly; a
   checked box that doesn't reflect what you actually ran wastes a
   reviewer's time more than an honest unchecked one.

See [`README.md`](README.md) for the full build/run walkthrough (including
`mise run guest-image` and the guest asset provenance chain) and
architecture overview, and [`SECURITY.md`](SECURITY.md) if what you found is a security
issue rather than a bug — that goes through GitHub Security Advisories,
not a public issue.
