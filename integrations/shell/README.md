# morb shell completions and man page

Shell completions and a man page for the `morb` CLI (Morbstack), derived
from `mac/Sources/morb/main.swift` rather than from `morb --help` alone,
because per-subcommand `--help` in the current binary just reprints the
global help text and does not enumerate per-subcommand flags. See
"Discrepancies between `morb --help` and the actual parser" below for
what that surfaced.

Files:

- `morb.bash` — bash completion, self-contained (`complete -F _morb morb`).
- `_morb` — zsh completion (`#compdef morb`).
- `morb.fish` — fish completion.
- `morb.1` — man page, section 1.

## A note on how this was built: the source moved while this was in progress

`mac/Sources/morb/main.swift` was actively being edited by another agent
while this work was done (as flagged in the task brief — "other agents
are actively editing Swift right now"). Partway through, the file grew
from 892 lines / 11 top-level commands to 1179 lines / 18 top-level
commands, adding `context`, `install-cli-plugins`, `mcp`, `migrate`,
`bench`, `scan`, and `debug`. Everything here reflects a full re-read of
the file after that growth, at 1179 lines — not the original 892-line
snapshot. If `main.swift` has changed further since, these files should
be regenerated rather than trusted as current; there is no way to know
from inside this task whether it has.

## Install

### bash

Either source it directly from your shell rc file:

```sh
echo 'source /path/to/integrations/shell/morb.bash' >> ~/.bashrc   # or ~/.bash_profile
```

or, if you have Homebrew's `bash-completion` (v2) installed, drop it into
its completions directory so it loads lazily on first use of `morb`:

```sh
cp integrations/shell/morb.bash "$(brew --prefix)/etc/bash_completion.d/morb"
```

(or, more precisely, wherever `pkg-config --variable=completionsdir
bash-completion` points, if you have `bash-completion@2`'s pkg-config
file installed.)

The script is written to work under both `/bin/bash` (3.2.57, the
system bash shipped by macOS) and bash 4/5 from Homebrew — it does not
use associative arrays, `mapfile`, or any bash-completion helper
functions like `_init_completion`.

### zsh

Put `_morb` (the filename matters — zsh completion files for a command
`foo` must be named `_foo`) in a directory on your `$fpath`, then make
sure `compinit` runs after that directory is added to `$fpath`:

```sh
mkdir -p ~/.zsh/completions
cp integrations/shell/_morb ~/.zsh/completions/_morb
```

```sh
# in ~/.zshrc, before `autoload -Uz compinit && compinit`:
fpath=(~/.zsh/completions $fpath)
```

If you use a framework (oh-my-zsh, prezto, zinit, etc.) with a
`custom completions` directory, drop `_morb` there instead, following
that framework's convention.

### fish

fish auto-loads completion files from `~/.config/fish/completions/`, no
sourcing step required:

```sh
mkdir -p ~/.config/fish/completions
cp integrations/shell/morb.fish ~/.config/fish/completions/morb.fish
```

**fish was not available on the machine these completions were written
on** (`command -v fish` found nothing). `morb.fish` was written by hand
against fish's `complete`/`__fish_seen_subcommand_from`/
`__fish_use_subcommand` conventions and kept structurally parallel to
the bash/zsh files, but it was never actually loaded or exercised in a
real fish session. Run `fish -n integrations/shell/morb.fish` before
trusting it, and ideally Tab through a few cases by hand.

### man page

One-off, without installing anywhere:

```sh
man -l integrations/shell/morb.1
```

(if your `man` doesn't support `-l` — the one on the machine this was
written on doesn't — `mandoc -T ascii integrations/shell/morb.1 | less`
works identically)

To install it properly:

```sh
sudo mkdir -p /usr/local/share/man/man1
sudo cp integrations/shell/morb.1 /usr/local/share/man/man1/
# macOS: refresh whatis/apropos database
sudo /usr/libexec/makewhatis /usr/local/share/man
# Linux: usually
sudo mandb
```

Then `man morb` works normally (assuming `/usr/local/share/man` is on
your `$MANPATH`, which it is by default on macOS via `/etc/man.conf` /
`man -w`).

### Future Homebrew formula

This is the realistic packaging path once Morbstack has a formula. In
the formula's `install` method:

```ruby
bash_completion.install "integrations/shell/morb.bash" => "morb"
zsh_completion.install "integrations/shell/_morb"
fish_completion.install "integrations/shell/morb.fish"
man1.install "integrations/shell/morb.1"
```

`bash_completion.install "morb.bash" => "morb"` renames it on install
because bash-completion's own convention is for the installed file to be
named after the command, not the source file; `zsh_completion.install`
and `fish_completion.install` keep `_morb` / `morb.fish` as-is since
those names are already what each shell's convention expects.

## The command surface (from `main.swift`, not `--help`)

Eighteen top-level commands: `status start stop suspend resume shares
rosetta k8s version doctor reset-disk context install-cli-plugins mcp
migrate bench scan debug`.

- `--json` and `--help`/`-h` are recognized **anywhere** on the command
  line — `main.swift` strips `--json` and checks for `--help`/`-h`
  across the *whole* argument list before it even looks at what the
  command is. `morb --json status` and `morb status --json` behave
  identically, and this holds even for `mcp`/`migrate`/`bench`/`scan`/
  `debug` below.
- `rosetta` takes an optional sub-subcommand, `status` (default) or
  `install`.
  - `rosetta install` accepts `--print-plan`. It explicitly **refuses**
    `--force` — passing it is a hard, documented error (exit 2).
- `k8s` takes an optional sub-subcommand, `status` (default), `enable`,
  `disable`, or `kubeconfig`.
  - `k8s kubeconfig` accepts `--merge`, `--switch-context`, `--force`.
  - `k8s status`/`enable`/`disable` accept no command-specific flags.
- `context` takes an optional sub-subcommand, `status` (default),
  `create`, or `use`. Never touches the daemon; reads/writes only under
  the docker CLI's own config directory (`~/.docker`, or `$DOCKER_CONFIG`
  if set).
  - `context create` accepts `--force` (skips its confirmation prompt).
  - `context use` accepts `--force`, but it does **not** skip that
    command's confirmation prompt — `context use` always asks
    interactively, no exceptions, per its own error message ("This
    command has no non-interactive form"). `--force` there only lifts
    the refusal to replace another *explicit* non-default context.
  - `context status` accepts no command-specific flags.
- `install-cli-plugins` (a standalone top-level command, not a
  subcommand of anything) accepts `--force` and `--print-plan`.
- `stop` and `reset-disk` accept `--force`.
- `start`, `suspend`, `resume` accept no command-specific flags.
- `mcp`, `migrate`, `bench`, `scan`, `debug`: **`main.swift` dispatches
  to these and stops.** Its own comment: "The feature modules own their
  own argument parsing, output and exit codes." Each is implemented in
  a separate Swift module (`MorbMCP`, `MorbMigrate`, `MorbBench`,
  `MorbScan`, and a debug module) that this task could not read — the
  hard constraint for this task was read access to
  `mac/Sources/morb/main.swift` only, and those modules live elsewhere.
  Consequently: **the completions here only offer the command name
  itself and the two globally-honored flags (`--json`, `--help`/`-h`)
  for these five — no sub-subcommands, no command-specific flags.**
  Nothing was guessed or fabricated for them. Whoever owns those modules
  should extend `morb.bash`/`_morb`/`morb.fish` with real per-command
  completions once their grammars are readable, and the man page's
  `EXIT STATUS` section flags that their exit codes were not verified to
  follow morb's own 0/1/2 convention, since morb just forwards whatever
  code each module returns.
  It was also not safe to execute any of `morb mcp`, `morb migrate`,
  `morb bench`, `morb scan`, or `morb debug` to reverse-engineer their
  behavior: the task's explicit safe-command allowlist (`status`,
  `version`, `doctor`, `shares`, `k8s status`, `--help`) predates these
  five commands entirely, and several of them sound plausibly
  side-effecting (`debug` opens a shell in a running container; `bench`
  runs a benchmark suite; the engine is live and shared with other
  agents right now), so none were run.

## Discrepancies between `morb --help` and the actual parser

Found while reading `main.swift` line by line to build these
completions — reported here per the task brief, since these are genuine
gaps between the shipped `--help` text and what the binary does:

1. **`--switch-context` (for `k8s kubeconfig`) is a real, working flag
   that is never mentioned anywhere in `morb --help`'s usage text.** The
   SUBCOMMANDS section documents `k8s kubeconfig --merge` but not
   `k8s kubeconfig --merge --switch-context`.
2. **`--force` is honored by `k8s kubeconfig --merge`** (it skips that
   command's confirmation prompt), which the OPTIONS section of the help
   text still does not say, even in its current, more detailed form
   (which now correctly documents `--force` for `reset-disk`, `context
   create`, `context use`, and `stop`, but omits `k8s kubeconfig
   --merge`).
3. **`context use --force` does not do what "skip confirmation" would
   suggest.** Every other command's `--force` skips an interactive
   prompt; `context use`'s does not — it always prompts, and `--force`
   only changes whether it's allowed to replace another explicit
   non-default context. The current help text's OPTIONS section lumps
   `context use` in with `reset-disk`/`context create`/`install-cli-
   plugins` under "Skip Morbstack's confirmation prompt" and then
   separately says `--force` will "replace another explicit default
   context (context use)" — technically both are true, but a reader
   skimming the first clause would reasonably conclude `context use
   --force` runs non-interactively, and it never does.
4. **`-h` works as a synonym for `--help`**, but only `--help` is listed
   in the OPTIONS section.
5. **Per-subcommand `--help` does not exist.** `--help`/`-h` is checked
   against the entire raw argument list before the command is even read,
   so `morb rosetta install --help`, `morb context create --help`, or
   `morb mcp --help` all print the exact same global usage text as
   `morb --help`, never anything specific to that command. This also
   means there is no way to discover `mcp`/`migrate`/`bench`/`scan`/
   `debug`'s own flags via `--help` either, since it never reaches their
   modules.
6. **`--force` is silently ignored, not rejected, on commands that don't
   use it.** `morb start --force`, `morb suspend --force`, `morb k8s
   status --force`, `morb context status --force`, etc. all run
   normally with `--force` simply never read by the parser — no error,
   unlike `rosetta install --force`, which is a deliberate, documented
   rejection.
7. **The `rosetta`/`k8s`/`context` sub-subcommand can appear anywhere
   among the trailing arguments**, not just immediately after the
   command word — all three are found via `extraArguments.first {
   !$0.hasPrefix("-") }` (or the `context`-specific equivalent). So
   `morb k8s --force kubeconfig --merge` resolves the subcommand to
   `kubeconfig` correctly even though a flag precedes it.
8. **`mcp`, `migrate`, `bench`, `scan`, `debug` exist in the shipped
   binary but their argument grammar is entirely outside `main.swift`.**
   Not a gap in the help text exactly (the top-level `--help` does list
   all five with a one-line description each, accurately), but worth
   surfacing plainly: nothing in `main.swift` says what subcommands or
   flags any of them take, so no completion tool built solely from this
   file can offer more than their bare command names. See the command
   surface section above.

Nothing in `main.swift`'s own argument-parsing and dispatch code reads
any environment variable directly (no `ProcessInfo.environment` /
`getenv` / `MORBSTACK_HOME` anywhere in it); the man page's ENVIRONMENT
section says so. `context`'s own code does reference the docker CLI's
`$DOCKER_CONFIG` convention in a comment ("against ~/.docker (or
$DOCKER_CONFIG)"), which the man page also notes. This task's brief was
scoped to reading only `mac/Sources/morb/main.swift`; whether a lower
layer (`MorbstackKit`, or any of the five feature modules) honors other
environment variables was out of scope to verify here.

File paths in `morb.1`'s FILES section
(`~/.morbstack/run/docker.sock`, `~/.morbstack/kubeconfig`,
`~/.morbstack/data/disk.img`) are quoted verbatim from `README.md` at
the repo root. `~/.morbstack/run/morbstackd.sock` and
`~/.morbstack/config.toml` are not spelled out as full literal paths
anywhere in that README (it mentions `morbstackd.sock` and
`config.toml` by name, without the `run/` / home-directory prefix
written out) but are consistent with the architecture diagram there —
`morbstackd.sock` living alongside `docker.sock` in `~/.morbstack/run/`,
and `config.toml` at the root of `~/.morbstack/` alongside `data/` and
`kubeconfig`. Flagged here rather than silently presented as equally
certain as the other three. `~/.docker/cli-plugins` and `~/.docker` (or
`$DOCKER_CONFIG`) come directly from `main.swift` itself (literal string
`~/.docker/cli-plugins` and the `$DOCKER_CONFIG` comment both appear in
the source).

## Testing

Environment this was tested in: macOS, `/bin/bash` 3.2.57(1) (system
bash — no Homebrew bash was installed on this machine, so bash was only
tested against 3.2, not additionally against bash 5), `zsh` 5.9, `fish`
not installed, `mandoc` present, `nroff` not present, macOS's `man` here
does not support GNU-style `--warnings` or even `-l` (it only accepts
`[-adho] [-t | -w] [-M manpath] [-P pager] [-S mansect] [-m
arch[:machine]] [-p [eprtv]]`), so `mandoc` was used directly instead.

- **`morb.bash`**
  - `bash -n integrations/shell/morb.bash` — passed, `/bin/bash` 3.2.57
    only (no Homebrew bash present to cross-check against).
  - Functional test: sourced the file in a bash subshell and called
    `_morb` directly with `COMP_WORDS`/`COMP_CWORD` set, printing
    `COMPREPLY`, for twelve cases (more than the three required):
    empty (`morb <TAB>`), `morb k8s <TAB>`, `morb rosetta <TAB>`,
    `morb rosetta install <TAB>` (confirms `--force` is absent),
    `morb k8s kubeconfig <TAB>` (confirms `--merge`/`--switch-context`/
    `--force` are present), `morb context <TAB>`,
    `morb context use <TAB>`, `morb install-cli-plugins <TAB>`,
    `morb mcp <TAB>` (confirms only the two global flags are offered,
    nothing fabricated), `morb stop <TAB>`, `morb start <TAB>`
    (confirms `--force` is absent), and a partial-word case
    `morb st<TAB>`. All returned exactly the expected completion sets.
- **`_morb` (zsh)**
  - `zsh -n integrations/shell/_morb` — passed.
  - Copied it into a scratch directory, then ran, as specified:
    `fpath=(DIR $fpath); autoload -Uz compinit; compinit -u;
    autoload -Uz _morb; echo ok` — loaded and autoloaded without error.
  - A deeper functional trace (actually simulating `<TAB>` and reading
    back the completion menu) was attempted two ways and neither
    panned out in this sandboxed environment: a `zpty`-driven
    interactive session produced no readable completion output (and a
    second, more elaborate attempt hung and had to be killed); and
    driving `_morb` directly with a stubbed `compadd` failed because
    zsh's `_arguments` (the `comparguments` builtin) refuses to run
    outside a real completion-widget context, stub or no stub. `zsh`'s
    own `comptest` helper (built for exactly this kind of scripted
    testing) is not present in this system's zsh install. So `_morb`'s
    logic was verified by syntax check + load test + careful manual
    review against `_arguments`/`_describe` conventions, not by an
    end-to-end simulated keystroke test. Say so plainly rather than
    claiming more than was actually confirmed.
- **`morb.fish`**
  - Not tested at all — fish is not installed on this machine
    (`command -v fish` found nothing). Written by hand, structurally
    parallel to the bash/zsh files, but unverified. Run
    `fish -n integrations/shell/morb.fish` before trusting it.
- **`morb.1`**
  - `mandoc -T lint integrations/shell/morb.1` — clean except five
    `STYLE: referenced manual not found` notes for `Xr docker 1`,
    `Xr docker-buildx 1`, `Xr docker-compose 1`, `Xr kubectl 1`. These
    are expected and not a defect in the page: this machine doesn't
    have those tools' man pages registered in its local `mandoc.db`, so
    `mandoc` can't resolve the cross-reference locally, even though the
    reference itself is syntactically correct and is exactly what the
    task asked the SEE ALSO section to contain. Three real issues were
    found and fixed along the way: `.Os Morbstack` was misparsed as an
    attempt at an OS release string (STYLE warning) and was changed to
    bare `.Os`; the AUTHORS section needed an `.An` macro rather than
    plain text; and the `Xr` list in SEE ALSO needed `docker-buildx`
    and `docker-compose` in alphabetical order (mandoc's own
    "unusual Xr order" check). After those fixes, `mandoc -T lint` has
    no warnings above STYLE.
  - Rendered with `mandoc -T ascii integrations/shell/morb.1` and read
    through in full, twice (once before and once after adding
    `context`/`install-cli-plugins`/`mcp`/`migrate`/`bench`/`scan`/
    `debug`): all sections present, no broken macros, no truncated
    tables, `.Bl -tag` lists (including the nested one under `--force`
    in OPTIONS) render correctly, examples section reads cleanly.
