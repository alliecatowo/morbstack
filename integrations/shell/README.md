# morb shell completions and man page

Shell completions and a man page for the `morb` CLI (Morbstack).

Files:

- `morb.bash` — bash completion, self-contained (`complete -F _morb morb`).
- `_morb` — zsh completion (`#compdef morb`).
- `morb.fish` — fish completion.
- `morb.1` — man page, section 1.

## These four files are checked against the CLI, not trusted

`mac/Tests/MorbstackKitTests/ShellCompletionDriftTests.swift` fails the
build when any of them disagrees with `morb`'s parser. It derives the
command surface from `mac/Sources/morb/main.swift` — the column-zero
`case "…":` labels of the top-level `switch command`, and the `COMMANDS:`
block of the `usage` literal — and then checks that

1. the help text lists exactly the commands the parser dispatches,
2. each of the four files declares exactly that set, naming the specific
   command in the failure message when one is missing or invented,
3. the zsh and fish **descriptions match `morb --help` verbatim**, and
4. no completion offers a long option that appears nowhere in the CLI's
   own Swift sources.

That test exists because these files had already gone stale by seven
commands (`disk`, `ports`, `diagnose`, `service`, `install-cli`,
`uninstall-cli`, `export`), and because `debug` was described here as
"Open a toolbox shell in a container, even a distroless one" while the
implementation says, in main.swift's own words, that it "does not open a
shell yet" — the exact thing `CLAUDE.md` §1.8 forbids, living in a file
no build step read.

Check 3 is the one that catches §1.8 violations, and it is why
descriptions here are terse copies of the help text rather than
independently worded. **If you reword a description in `main.swift`,
reword it identically in `_morb` and `morb.fish`.**

`mise run check` and CI additionally `shellcheck` `morb.bash` and parse
all three completions with their own interpreters (`bash -n`, `zsh -n`,
`fish --no-execute`; fish is skipped when not installed).

### What the guard does *not* cover

Per-command **subcommands and flags** are not machine-checked against the
parser. Nothing in the Swift sources declares them as data a test could
compare against — `morb`'s nested grammars are hand-rolled switches, and
each feature module owns its own — so building an expected table in the
test would only move the drift somewhere less visible. What is checked in
that direction is containment: a flag the completions offer must at least
exist in the sources. A flag the parser *gains* will not fail anything
until someone notices.

## Where the command surface comes from

Not from `morb --help` alone. `morb` strips `--json` and checks for
`--help`/`-h` across the whole argument list *before* it reads the
command word, so `morb mcp --help` prints the global usage and never
reaches `MorbMCP`. Per-subcommand grammars were read out of the sources:

| Command | Grammar defined in |
| --- | --- |
| everything top-level, `rosetta`, `k8s`, `context`, `service`, `disk`, `ports`, `diagnose`, `install-cli`, `uninstall-cli`, `install-cli-plugins` | `mac/Sources/morb/main.swift` |
| `mcp` | `mac/Sources/MorbMCP/MCPCLI.swift` |
| `migrate` | `mac/Sources/MorbMigrate/MigrateCLI.swift` |
| `bench` | `mac/Sources/MorbBench/BenchCLI.swift` |
| `scan` | `mac/Sources/MorbScan/ScanCLI.swift` |
| `debug` | `mac/Sources/MorbScan/DebugCLI.swift` |
| `export` | `mac/Sources/MorbExport/ExportCLI.swift` |

Those six modules each accept the bare word `help` (`morb mcp help`,
`morb migrate help`, …) which *does* reach them and prints their own
usage. The completions offer it.

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

The script works under both `/bin/bash` (3.2.57, the system bash shipped
by macOS) and bash 4/5 from Homebrew — it does not use associative
arrays, `mapfile`, or any bash-completion helper functions like
`_init_completion`. `SC2207` is disabled file-wide for exactly that
reason: `mapfile` is bash 4, and `COMPREPLY=($(compgen …))` is the
portable idiom.

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

**fish is still not installed on the machine these were written on**, so
`morb.fish` has never been loaded in a real fish session or Tab-driven by
hand. Its structure is checked by the drift test and its syntax by
`fish --no-execute` wherever fish exists, but treat the interactive
behaviour as unverified until someone with fish confirms it.

### man page

One-off, without installing anywhere:

```sh
man -l integrations/shell/morb.1
```

(if your `man` doesn't support `-l`, `mandoc -T ascii
integrations/shell/morb.1 | less` works identically)

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

## Known gaps between `morb --help` and the actual parser

Still true, and worth fixing in `main.swift` rather than papering over
here. None of these is a false promise, so none is a §1.8 violation —
they are omissions:

1. **`-h` works as a synonym for `--help`**, but only `--help` appears in
   the OPTIONS section.
2. **Per-subcommand `--help` does not exist.** `--help`/`-h` is matched
   against the whole raw argument list before the command word is read,
   so `morb rosetta install --help` and `morb mcp --help` print the same
   global text. The bare word `help` is the way into a feature module's
   own usage.
3. **`--switch-context`, and `--force` on `k8s kubeconfig --merge`, are
   real and honored** but appear nowhere in the help text's OPTIONS
   section.
4. **`--allow`, `--only`, `--runs`, `--window`, `--limit`, `--from`,
   `--image`, `--sbom`, `--fail-on`, `--manifest`, `--replace`** and the
   rest of the feature modules' flags are documented only inside those
   modules' own usage strings, not by `morb --help`.
5. **`context use --force` does not do what "skip confirmation" would
   suggest.** Every other command's `--force` skips a prompt; this one
   always prompts, and `--force` only lifts the refusal to replace
   another *explicit* non-default context. Both completions and the man
   page say so explicitly.
6. **`--force` is silently ignored, not rejected, on commands that don't
   read it** (`morb start --force`, `morb k8s status --force`, …). The
   one deliberate rejection is `rosetta install --force`, which is a hard
   error by design.
7. **`morb debug` exits 2 on every successful invocation**, because "no
   toolbox is available" is never a success. Documented in the man page's
   EXIT STATUS.

## Testing

- `swift test --package-path mac --filter ShellCompletionDriftTests` —
  the drift guard described above. Proven to fail by deliberately
  deleting `export` from `morb.bash`, `service` from `morb.fish`, and
  `ports` from `morb.1`, by restoring `debug`'s old "Open a toolbox
  shell" description in `_morb`, and by deleting `export` from
  `main.swift`'s own COMMANDS block: each produced a failure naming that
  exact command, and the suite went green again on restore.
- `shellcheck integrations/shell/morb.bash` — clean.
- `bash -n`, `zsh -n` — both pass. `fish --no-execute` unrun; fish is not
  installed here.
- `morb.bash` was also exercised functionally: sourced in a `bash --norc`
  subshell and called directly with `COMP_WORDS`/`COMP_CWORD` set, for
  the empty case, `disk`, `ports`, `service`, `export`, `k8s`,
  `k8s port-forward`, `k8s port-forward start`, `migrate verify`,
  `debug check`, `install-cli`, `uninstall-cli`, and the partial word
  `morb dia`. All returned the expected sets.
- `_morb` was autoloaded into a scratch `$fpath` under `zsh -f` with
  `compinit`, and its `commands` array was evaluated standalone to
  confirm the `'…'\''…'` quoting of `service`'s apostrophe and the colon
  inside `install-cli-plugins`' description both survive. A
  keystroke-level completion trace was not attempted: `_arguments`
  refuses to run outside a real completion-widget context and this zsh
  has no `comptest`.
