# amd64 images on Apple silicon

How `docker run --platform linux/amd64` works, how to turn it on, and what
it does not cover.

Status: **Rosetta path working.** The qemu fallback is written but inert —
see "What does not work" below.

## What happens

Rosetta for Linux is exposed to the guest as a VirtioFS share, and
`morbinit` registers the interpreter it contains with the guest kernel's
`binfmt_misc` as the handler for ELF `x86_64` binaries. From then on the
kernel does the work: an amd64 executable is handed to Rosetta
transparently, by the same mechanism that makes `#!` scripts run.

```
$ docker run --rm --platform linux/amd64 alpine uname -m
x86_64
$ docker run --rm alpine uname -m
aarch64
```

Three properties are worth knowing because they determine what you have to
do, which is almost nothing:

**Nothing is required inside the container image.** The registration uses
`binfmt_misc`'s `F` (fix-binary) flag, which opens the interpreter *at
registration time*, in the init namespace, and keeps that open file. A
container in its own mount namespace never has to be able to see the
interpreter — verified directly: the interpreter path is absent from inside
the container's filesystem while x86_64 binaries continue to execute. No
bind-mounting `/run/rosetta` into containers, no `--platform`-aware base
images, no cooperation of any kind from the image.

**It is real translation, not a stub.** The gate for calling this working
was correctness, not process startup: `mysql:5.7` — which publishes no
arm64 manifest at all, so an arm64 pull hard-fails — boots a real server,
runs DDL, DML and aggregation, and returns a `SHA2('morbstack', 256)`
bit-identical to the host's `shasum -a 256`.

**It is per-boot.** The Rosetta share is a *device*, attached when the VM
is configured. Installing Rosetta, or setting `rosetta = true`, changes
nothing about a VM that is already running.

## Turning it on

```sh
morb rosetta            # what the state is
morb rosetta install    # explain, ask, then set it up
```

`morb rosetta install` prints exactly what it will do before it asks:

```
$ morb rosetta install --print-plan
`morb rosetta install` will:

  1. ask macOS to download and install the Rosetta for Linux runtime.
     macOS shows its own confirmation and licence prompt for this;
     Morbstack cannot and does not answer it for you.
  2. set `rosetta = true` in ~/.morbstack/config.toml,
     rewriting that file in its canonical form.
  3. on the next VM start, expose Rosetta to the guest, which registers
     it as the interpreter for x86_64 binaries so amd64 images run.
```

Then restart the engine so the guest picks up the device:

```sh
morb stop && morb start
morb rosetta
```

### There is no `--force`

`morb rosetta install` always asks, and no flag skips the prompt. Not an
oversight — a deliberate line, and the same line applies to every command
in the CLI:

> Morbstack never accepts a third-party licence, never triggers a
> system-level install without an interactive confirmation, and never
> answers a consent prompt on the user's behalf, whatever flags are passed.

`reset-disk` takes `--force` because it destroys a file *Morbstack* created
in a directory Morbstack owns, and a script that has already decided is
entitled to skip our confirmation. Installing Rosetta is different: macOS
presents Apple's licence to the person at the keyboard, and a flag that
skips the prompt is a flag that accepts that licence on somebody's behalf,
possibly on a Mac they do not own, from a process they did not start.

Two escape hatches that do not require crossing that line:

- `morb rosetta install --print-plan` prints the plan and exits `0`,
  changing nothing.
- An unattended pipeline runs `softwareupdate --install-rosetta` itself and
  owns that decision, then `morb rosetta` to confirm the result.

On a non-interactive stdin the command exits `2` and says both of those.

## Reading the state

Four independent facts, kept apart because they fail independently and the
remedies differ:

| Fact | Where it lives | If it is false |
| --- | --- | --- |
| Installed on the host | Virtualization.framework | `morb rosetta install` |
| `rosetta = true` | `config.toml` | Edit it, restart the engine |
| Share mounted in the guest | `morbinit` | Restart the engine |
| `binfmt_misc` registered | `morbinit` | A guest bug — please report it |

The distinction that earns them four columns rather than one boolean: the
first two are host facts and the last two are guest facts, and a VM that is
already running can disagree with both host facts at once. Right after
`morb rosetta install`, Rosetta *is* on the Mac and the running VM *does
not* have it. A status display that collapsed these would say "off" while
`morb doctor` said "installed", with no way to reconcile the two.

The guest facts are also tri-state: `null` when no guest has answered,
which is not `false`. "The VM is not running, so we cannot know" and "the
VM is running and Rosetta is broken" call for opposite advice, and
collapsing them is how a status display tells somebody to reinstall
software they already have.

In the app, **Settings › File Sharing** carries the Rosetta row, and the
Images list badges every image that is not native to this Mac.

## Prefer arm64 anyway

Translation works and it is not free: slower start, slower execution, and a
long tail of runtimes that misbehave under it — JITs especially, plus
anything reading `/proc/cpuinfo` or depending on AVX. If the publisher
ships an arm64 variant, use it.

The Images screen badges this rather than leaving it to be discovered:

- `arm64` on Apple silicon — plain text, no badge. The overwhelming
  majority; a badge on every row is wallpaper by the second screenful.
- `amd64` — a **translated** badge, amber. It will run, more slowly.
- `arm/v7`, `386`, `s390x`, … — an **unsupported** badge, red. Rosetta
  translates x86-64 and nothing else; these fail with `exec format error`.

An image whose platform has not been fetched yet renders as *blank*, never
as native — the badge column must not put a reassuring answer where the
amd64 warning belongs.

## What does not work

**The qemu fallback is inert.** The binfmt plumbing for a qemu interpreter
exists, but no static `qemu-x86_64` ships in the guest image, so the guest
reports `binfmt_amd64: "none"` for it. Anything Rosetta cannot translate
fails; it does not fall back. Do not rely on a qemu path today.

**Intel Macs and unsupported hosts.** Rosetta for Linux needs Apple
silicon and a macOS that offers the directory share. Where it cannot exist,
Morbstack reports `not supported` rather than offering an install — there
is nothing to suggest anybody do about it.

**32-bit x86.** `386` images are not translatable by Rosetta.

## See also

- [`sharing.md`](sharing.md) — the other capability that fails silently.
- [`architecture.md`](architecture.md) §4 — the amd64 strategy, including
  the FEX-Emu contingency.
- [`protocol.md`](protocol.md) — the `rosetta` control command and the
  `binfmt_amd64` field in the MRB0 `info` reply.
