# Build system

Morbstack's build logic lives in [`mise.toml`](../mise.toml) as [mise](https://mise.jdx.dev/)
tasks. This page is the map: what each task does, how they depend on each
other, and the couple of places where mise's behavior isn't quite what
`make` used to give you.

A `make` compatibility shim still exists at the repo root
([`Makefile`](../Makefile)) so anything not yet updated to call `mise run`
keeps working — every `make <target>` there just runs `mise run <target>`.
New code, docs, and CI should call `mise run <task>` directly. The shim can
be deleted once nothing references `make` anymore.

## First run on a fresh clone

`mise run <anything>` requires `mise.toml` to already be trusted — mise
refuses to even parse an untrusted config to find the task list, so a task
can't bootstrap its own trust. The very first commands on a fresh clone
must be:

```sh
mise trust
mise install
```

After that, `mise run setup` (below) does the same two commands and is
fine to use going forward, e.g. after pulling a change that bumps the Rust
pin.

## Task list

| Task | Depends on | What it does |
| --- | --- | --- |
| `setup` | — | `mise trust && mise install` — trusts the config and installs the pinned Rust toolchain (Swift comes from Xcode, not mise) |
| `build` | `build-mac`, `build-guest` | Everything: mac host binaries + guest init binary, host arch |
| `build-mac` | — | `swift build` in `mac/` — builds `morbstackd` and `morb` |
| `build-guest` | — | `cargo build` in `guest/morbinit/` — host-arch `morbinit`, enough for `cargo test`/`cargo check` |
| `cross-build-guest` | — | Cross-compiles `morbinit` for `aarch64-unknown-linux-musl` (the real guest target) via the messense Homebrew cross toolchain |
| `guest-image` | `cross-build-guest` | Runs `scripts/mkinitramfs.sh` — assembles the bootable initramfs (morbinit + Alpine rootfs + Docker engine binaries + fsutils) into `$MORBSTACK_HOME/data/kernel/initrd.img` (default `~/.morbstack`) |
| `sign` | `build-mac` | Ad-hoc codesigns `morbstackd` with the `com.apple.security.virtualization` entitlement. Must be the last step before starting the daemon — `swift build` strips the entitlement on every rebuild |
| `run-daemon`\* | `sign` | Runs `morbstackd --foreground` for local development |
| `test` | — | Runs the Swift suite (if `mac/Tests` exists) and the Rust suite |
| `shots-live` | `build-mac` | Self-captures the real `MorbstackApp` window (light + dark) into `dist/shots-live`, using `--tour-fixtures` so no engine/VM is needed |
| `app-icon` | — | Renders `AppIcon.icns` from `mac/AppResources/make-icon.swift`. Skipped if that script hasn't changed since the last icon build (see "Incrementality" below) |
| `app` | `app-icon` | Release-builds `MorbstackApp`, `morbstackd`, and `morb` (as three separate `swift build --product` invocations — combining them silently builds only the last one), assembles `dist/Morbstack.app`, stamps the version, and signs inside-out: `morb`, then `morbstackd` with entitlements, then the bundle with no `--deep`. Fails the build if `morbstackd` loses the virtualization entitlement. The three-product list is a curated bundle manifest, not derived from `Package.swift` — see the comment on `[tasks.app]` in `mise.toml` before "fixing" it to loop over the package graph |
| `run-app`\* | `app` | Builds and `open`s `dist/Morbstack.app` |
| `clean-app`\* | — | Removes the assembled bundle and icon build products |
| `clean`\* | `clean-app` | Removes build outputs for both toolchains |

\* **Reviewed, not executed, during the mise migration.** `run-daemon` and
`run-app` start a long-running process (the daemon, and potentially the VM
behind it via socket activation); `clean` and `clean-app` delete
`mac/.build` and `guest/morbinit/target` outright. All four were verified
by reading the generated `run` script and confirming it matches the
original Makefile recipe line for line, not by running them — the
migration happened with several other agents mid-build against those same
directories, and either running the daemon or deleting shared incremental
build state out from under them would have been actively destructive. If
you're picking this up later: these four are the ones still worth an
actual smoke test, ideally when the tree is quiet (no other agent
mid-build) and you're prepared to lose `mac/.build`/`guest/morbinit/target`
if `clean`/`clean-app` are what you're testing.

Run `mise tasks ls` at any time for the live list with one-line
descriptions, or `mise tasks deps <task>` to see a task's dependency tree.

## Things worth knowing about how these tasks run

- **One shell session per task, not one per line.** Unlike a `make`
  recipe (where each line is a fresh shell unless you use `\`
  continuations), a mise task's multi-line `run` script executes as a
  single continuous shell — a `cd` on one line persists to the next. Every
  task in `mise.toml` that changes directories more than once wraps each
  `cd` in a subshell (`(cd mac && swift build ...)`) to avoid that leaking
  across lines.
- **Abort on first error.** Like a `make` recipe, a multi-line task script
  stops at the first command that returns non-zero.
- **The Rust toolchain is active automatically.** `mise.toml` pins
  `rust = "stable"`; running a task through `mise run` (or `mise x --`)
  activates that pin via `RUSTUP_TOOLCHAIN`, so tasks can call `cargo`
  directly with no fallback logic needed.
- **Incrementality is mostly left to the underlying tool.** `swift build`
  and `cargo build`/`cargo test` already do their own incremental
  compilation, and every task here is meant to be safe to re-run — matching
  the old Makefile, where every target was `.PHONY` (always attempted, with
  incrementality left to the compiler). The one exception is `app-icon`:
  its `sources`/`outputs` are declared in `mise.toml` so mise skips
  re-rendering the icon when `mac/AppResources/make-icon.swift` — the one
  file that determines its output — hasn't changed. That task was a safe,
  genuinely useful place to add mise-level skipping; the others are not
  (adding it to, say, `build-mac` would let mise decide not to invoke
  `swift build` at all under some source-tree change it didn't track,
  instead of the Swift compiler making that call itself).
- **`MORBSTACK_HOME` and `DOCKER_CONFIG` are honored the same as before.**
  Neither is touched by any mise task; they pass through from the
  environment `mise run` was invoked in, exactly as they did under `make`.
