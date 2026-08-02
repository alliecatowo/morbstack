# Contributing to Morbstack

Thanks for your interest in contributing. Morbstack is young (milestone
M0) and still moving fast, so please open an issue to discuss non-trivial
changes before sending a large PR.

## Licensing and sign-off

Morbstack is Apache-2.0 and does not require a CLA. Instead, we use the
[Developer Certificate of Origin (DCO)](https://developercertificate.org/):
every commit must include a `Signed-off-by` trailer certifying you wrote
it or otherwise have the right to submit it under the project's license.

Add it automatically with:

```sh
git commit -s -m "your message"
```

Squash/rebase merges should preserve the sign-off trailer from the
original commits.

## Code style

- **Swift** (`mac/`): standard Swift API design guidelines, 4-space
  indentation. No third-party SPM dependencies — Foundation and system
  frameworks only, so the build works offline. Prefer `struct` and value
  types where possible; keep `Virtualization.framework` calls isolated
  behind small, testable wrappers rather than scattered through business
  logic.
- **Rust** (`guest/morbinit/`): run `cargo fmt` and keep `cargo clippy`
  clean before submitting. No crates.io dependencies — std only. As PID 1
  in the guest, `morbinit` must handle errors defensively; avoid panics on
  the main control-loop path.
- **Comments**: write them where the *why* isn't obvious from the code,
  not to restate what a line already says.
- **Commit messages**: short imperative summary line, body explaining
  motivation when it's not obvious.

## Building

```sh
make setup   # mise trust + mise install — pinned Rust toolchain (Swift comes from Xcode)
make build   # build morbstackd, morb, and morbinit (host-arch dev build)
make test    # run the Swift and Rust test suites
```

`make build`/`make test` build `morbinit` for the host architecture, which
is enough for the Rust unit test suite and for editing non-Linux-gated
code. If your change touches anything under the `#[cfg(target_os =
"linux")]` boundary (most of `mounts.rs`, `sys.rs`, the real init sequence
in `main.rs`) or you need to boot a real guest to check it, you also need
`make guest-image`, which cross-compiles for
`aarch64-unknown-linux-musl` and requires that cross toolchain — see
[`dist/CROSS_COMPILE.md`](dist/CROSS_COMPILE.md).

If you're iterating on `morbstackd` outside of `make run-daemon`: a plain
`swift build` re-signs `morbstackd` ad-hoc and silently strips the
`com.apple.security.virtualization` entitlement `make sign` adds, so a
manually rebuilt binary that was signed before the rebuild will fail to
open a VM with a confusing error rather than an obvious "not signed" one.
`make sign` (which `run-daemon` already depends on) must be the last build
step before starting the daemon — if you rebuild after signing, re-sign
before running again.

See [`README.md`](README.md) for the full build/run walkthrough (including
`make guest-image` and the guest asset provenance chain) and architecture
overview.
