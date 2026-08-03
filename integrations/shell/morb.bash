# Bash completion for the `morb` CLI (Morbstack).
#
# Self-contained: does not depend on bash-completion's helper functions
# (_init_completion, _get_comp_words_by_ref, etc.), so it works whether or
# not the bash-completion package is installed. Tested against the system
# /bin/bash on macOS (3.2.57, no associative arrays, no `mapfile`); no
# Homebrew bash was available to additionally test against bash 5, but the
# script deliberately avoids anything newer than 3.2 syntax.
#
# Install:
#   - one-off: `source morb.bash`
#   - bash-completion v2 layout: copy/symlink to
#     $(brew --prefix)/etc/bash_completion.d/morb, or wherever
#     `pkg-config --variable=completionsdir bash-completion` points.
#   - or just source it from ~/.bashrc / ~/.bash_profile.
#
# The command surface here is derived from mac/Sources/morb/main.swift,
# not just `morb --help` — see integrations/shell/README.md for the
# discrepancies found between the two, and for an important caveat: `mcp`,
# `migrate`, `bench`, `scan` and `debug` each parse their own arguments in
# a separate Swift module that main.swift does not define and this
# completion could not read, so only their top-level command name and the
# globally-valid flags are completed for them — nothing subcommand- or
# flag-specific.

_morb() {
    local cur cmd sub i word
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    # morb's own parser treats --json/--help/-h as valid anywhere in the
    # argument list, and finds the command/subcommand as the first
    # non-option word wherever it falls. Mirror that here rather than
    # assuming positional args.
    local commands="status start stop suspend resume shares rosetta k8s version doctor reset-disk context install-cli-plugins mcp migrate bench scan debug"
    local global_opts="--json --help -h"

    cmd=""
    sub=""
    for ((i = 1; i < COMP_CWORD; i++)); do
        word="${COMP_WORDS[i]}"
        case "$word" in
            -*)
                continue
                ;;
        esac
        if [[ -z "$cmd" ]]; then
            cmd="$word"
        elif [[ -z "$sub" ]]; then
            sub="$word"
        fi
    done

    if [[ -z "$cmd" ]]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return 0
    fi

    case "$cmd" in
        rosetta)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "status install $global_opts" -- "$cur"))
            elif [[ "$sub" == "install" ]]; then
                # --force is deliberately refused by `rosetta install` (it
                # errors out), so it is not offered here.
                COMPREPLY=($(compgen -W "--print-plan $global_opts" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        k8s)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "status enable disable kubeconfig $global_opts" -- "$cur"))
            elif [[ "$sub" == "kubeconfig" ]]; then
                COMPREPLY=($(compgen -W "--merge --switch-context --force $global_opts" -- "$cur"))
            else
                # status / enable / disable take no extra flags.
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        context)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "status create use $global_opts" -- "$cur"))
            elif [[ "$sub" == "create" || "$sub" == "use" ]]; then
                # `context use --force` does NOT skip its confirmation
                # prompt (unlike --force elsewhere); it only lifts the
                # refusal to replace another explicit non-default context.
                # It is still a real, accepted flag either way.
                COMPREPLY=($(compgen -W "--force $global_opts" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        install-cli-plugins)
            COMPREPLY=($(compgen -W "--force --print-plan $global_opts" -- "$cur"))
            ;;
        stop | reset-disk)
            COMPREPLY=($(compgen -W "--force $global_opts" -- "$cur"))
            ;;
        start | suspend | resume | status | shares | version | doctor)
            COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            ;;
        mcp | migrate | bench | scan | debug)
            # Each of these owns its own argument parser in a separate
            # Swift module (MorbMCP / MorbMigrate / MorbBench / MorbScan /
            # a debug module) that main.swift merely dispatches to and
            # does not define the grammar of. Only the flags that morb's
            # top-level parser itself honors uniformly are offered.
            COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
    return 0
}

complete -F _morb morb
