# Cross-compiling morbinit for aarch64-unknown-linux-musl

Working recipe verified on this Mac (macOS 26.4, Apple Silicon, rustc
1.95.0 via rustup, Homebrew 5.1.14) on 2026-08-01.

## What worked

**messense/homebrew-macos-cross-toolchains**, formula
`aarch64-unknown-linux-musl` (GCC 15.2.0 cross toolchain, installed from a
prebuilt bottle — no from-source build needed, ~416MB, installed in ~6s).

`filosottile/musl-cross` was NOT tried beyond tapping it — the messense
tap has a formula matching the target triple exactly
(`aarch64-unknown-linux-musl`) so it was tried first and worked
immediately; no need to fall back to `cargo-zigbuild`/`zig`.

## Setup steps (already performed)

```sh
# 1. Rust target
rustup target add aarch64-unknown-linux-musl

# 2. Cross GCC toolchain (prebuilt bottle, not built from source)
brew tap messense/macos-cross-toolchains
brew install messense/macos-cross-toolchains/aarch64-unknown-linux-musl
```

This installs a full binutils + gcc 15.2.0 cross toolchain under
`$(brew --prefix aarch64-unknown-linux-musl)/bin`, e.g.:

```
/opt/homebrew/opt/aarch64-unknown-linux-musl/bin/aarch64-unknown-linux-musl-gcc
/opt/homebrew/opt/aarch64-unknown-linux-musl/bin/aarch64-unknown-linux-musl-ld
/opt/homebrew/opt/aarch64-unknown-linux-musl/bin/aarch64-unknown-linux-musl-strip
... (also aliased as aarch64-linux-musl-* without "unknown")
```

## Cargo config (drop into morbinit's `.cargo/config.toml`)

```toml
[target.aarch64-unknown-linux-musl]
linker = "aarch64-unknown-linux-musl-gcc"
```

Make sure the toolchain's bin dir is on `PATH` when invoking cargo (or use
an absolute path for `linker` instead of relying on PATH):

```sh
export PATH="/opt/homebrew/opt/aarch64-unknown-linux-musl/bin:$PATH"
```

or, to avoid needing PATH at all, use the absolute path directly in
config.toml:

```toml
[target.aarch64-unknown-linux-musl]
linker = "/opt/homebrew/opt/aarch64-unknown-linux-musl/bin/aarch64-unknown-linux-musl-gcc"
```

## Build command

```sh
cargo build --target aarch64-unknown-linux-musl --release
```

For morbinit specifically (zero-dep, no libc dependencies expected beyond
what musl's static libc provides), this should be sufficient with no
extra `RUSTFLAGS`. If any C dependency needs `pkg-config`/`cc` at build
time, the toolchain also provides `aarch64-unknown-linux-musl-gcc` as a
working `CC_aarch64_unknown_linux_musl` value.

## Verification performed

Built a `hello_musl` binary-crate scratch project (`cargo init`) with the
above config, ran:

```sh
cargo build --target aarch64-unknown-linux-musl --release
file target/aarch64-unknown-linux-musl/release/hello_musl
```

Output:

```
target/aarch64-unknown-linux-musl/release/hello_musl: ELF 64-bit LSB
executable, ARM aarch64, version 1 (SYSV), statically linked,
BuildID[sha1]=318c010c8097ebc93d1640bfbb6ad0430d7acd22, not stripped
```

This matches the required signature: ARM aarch64, statically linked.

`file` was the acceptance check at the time, because nothing on the Mac
could execute an aarch64-linux binary directly. That gap has since closed
from the other direction: `morbinit` is built by this toolchain and runs as
PID 1 in the real VZ guest on every boot, which is a far stronger check
than any local execution would have been.

Note that Rosetta would never have helped here. Rosetta for Linux
translates x86-64 to arm64, not the reverse, and it runs *inside* the
guest — it is how Morbstack executes amd64 container images on Apple
silicon (see [`../docs/amd64.md`](../docs/amd64.md)), and has nothing to do
with cross-compiling aarch64 artefacts on the host.

## Not needed but documented as fallback

If the messense toolchain ever breaks (e.g. Homebrew removes the tap, or
a future macOS/Xcode update breaks the bottle), the fallback path is
`cargo-zigbuild`:

```sh
brew install zig
cargo install cargo-zigbuild
cargo zigbuild --target aarch64-unknown-linux-musl --release
```

This was not exercised in this session since the primary path succeeded.
