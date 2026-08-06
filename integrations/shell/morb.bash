# shellcheck shell=bash
# shellcheck disable=SC2207
#
# SC2207 (prefer mapfile/read -a over $(...) word splitting) is disabled for
# the whole file on purpose: `mapfile` is bash 4, and macOS ships bash 3.2.
# `COMPREPLY=($(compgen ...))` is the portable completion idiom and the word
# splitting it warns about is exactly what compgen output needs.
#
# Bash completion for the `morb` CLI (Morbstack).
#
# Self-contained: does not depend on bash-completion's helper functions
# (_init_completion, _get_comp_words_by_ref, etc.), so it works whether or
# not the bash-completion package is installed. Written against the system
# /bin/bash on macOS (3.2.57, no associative arrays, no `mapfile`); nothing
# newer than 3.2 syntax is used.
#
# Install:
#   - one-off: `source morb.bash`
#   - bash-completion v2 layout: copy/symlink to
#     $(brew --prefix)/etc/bash_completion.d/morb, or wherever
#     `pkg-config --variable=completionsdir bash-completion` points.
#   - or just source it from ~/.bashrc / ~/.bash_profile.
#
# DO NOT hand-edit the `commands` list below without also updating
# mac/Sources/morb/main.swift. ShellCompletionDriftTests
# (mac/Tests/MorbstackKitTests/ShellCompletionDriftTests.swift) fails the
# build when this list differs from the command table `morb`'s parser
# dispatches on. That test exists because these files silently went stale
# by seven commands once already.
#
# Per-subcommand flags are NOT derived from `morb --help`: morb strips
# --help/-h from the whole argument list before dispatch, so
# `morb mcp --help` prints the global usage, never the module's own. The
# grammars below come from mac/Sources/morb/main.swift and from the feature
# modules it dispatches to (MorbMCP, MorbMigrate, MorbBench, MorbScan,
# MorbExport). That includes `migrate --to <runtime|socket>` (migrate
# images/volumes OUT of Morbstack) and `export --all` (export every local
# image to a directory) — both flags on the parent command itself, not
# subcommand names.

_morb() {
    local cur cmd sub op i word
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    # morb's own parser treats --json/--help/-h as valid anywhere in the
    # argument list, and finds the command/subcommand as the first
    # non-option word wherever it falls. Mirror that here rather than
    # assuming positional args.
    local commands="status start stop suspend resume shares rosetta k8s version doctor diagnose disk ports reset-disk mcp migrate bench scan export debug context service install-cli uninstall-cli install-cli-plugins"
    local global_opts="--json --help -h"

    cmd=""
    sub=""
    op=""
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
        elif [[ -z "$op" ]]; then
            op="$word"
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
                COMPREPLY=($(compgen -W "status enable disable diagnose describe port-forward kubeconfig $global_opts" -- "$cur"))
            elif [[ "$sub" == "kubeconfig" ]]; then
                COMPREPLY=($(compgen -W "--merge --switch-context --force $global_opts" -- "$cur"))
            elif [[ "$sub" == "describe" ]]; then
                if [[ -z "$op" ]]; then
                    COMPREPLY=($(compgen -W "pod node $global_opts" -- "$cur"))
                else
                    COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
                fi
            elif [[ "$sub" == "port-forward" ]]; then
                if [[ -z "$op" ]]; then
                    COMPREPLY=($(compgen -W "start status cancel $global_opts" -- "$cur"))
                elif [[ "$op" == "start" ]]; then
                    COMPREPLY=($(compgen -W "--container --local-port $global_opts" -- "$cur"))
                else
                    COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
                fi
            else
                # status / enable / disable / diagnose take no extra flags.
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
        service)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "status enable disable settings $global_opts" -- "$cur"))
            else
                # `service` accepts exactly one action word and no flags.
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        disk)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "status grow $global_opts" -- "$cur"))
            else
                # `disk grow` takes a positive GiB integer, which cannot be
                # completed from a word list.
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        ports)
            # `check` is the only subcommand and is also the default, so its
            # flags are offered alongside it.
            COMPREPLY=($(compgen -W "check --tcp --udp $global_opts" -- "$cur"))
            ;;
        diagnose)
            COMPREPLY=($(compgen -W "--output $global_opts" -- "$cur"))
            ;;
        install-cli)
            COMPREPLY=($(compgen -W "--force --print-plan --make-default $global_opts" -- "$cur"))
            ;;
        uninstall-cli | install-cli-plugins)
            COMPREPLY=($(compgen -W "--force --print-plan $global_opts" -- "$cur"))
            ;;
        stop | reset-disk)
            COMPREPLY=($(compgen -W "--force $global_opts" -- "$cur"))
            ;;
        start | suspend | resume | status | shares | version | doctor)
            COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            ;;
        mcp)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "serve init permissions help $global_opts" -- "$cur"))
            elif [[ "$sub" == "serve" || "$sub" == "permissions" ]]; then
                COMPREPLY=($(compgen -W "--allow $global_opts" -- "$cur"))
            elif [[ "$sub" == "init" ]]; then
                COMPREPLY=($(compgen -W "--force $global_opts" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        migrate)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "detect config plan run images volumes verify help --to $global_opts" -- "$cur"))
            elif [[ " ${COMP_WORDS[*]:0:COMP_CWORD} " == *' --to '* ]]; then
                # `--to` is a flag on `morb migrate` itself, not a subcommand
                # name, so `$sub` here is its <runtime|socket> value.
                COMPREPLY=($(compgen -W "--dry-run --yes $global_opts" -- "$cur"))
            else
                case "$sub" in
                    plan)
                        COMPREPLY=($(compgen -W "--from --filter --all $global_opts" -- "$cur"))
                        ;;
                    images)
                        COMPREPLY=($(compgen -W "--from --filter --all --dry-run --yes $global_opts" -- "$cur"))
                        ;;
                    volumes)
                        COMPREPLY=($(compgen -W "--from --filter --overwrite --dry-run --yes $global_opts" -- "$cur"))
                        ;;
                    verify)
                        COMPREPLY=($(compgen -W "--from --images --volumes --report --yes $global_opts" -- "$cur"))
                        ;;
                    run)
                        COMPREPLY=($(compgen -W "--from --image --all-images --dry-run --yes $global_opts" -- "$cur"))
                        ;;
                    *)
                        COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        bench)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "list run history compare help $global_opts" -- "$cur"))
            else
                case "$sub" in
                    run)
                        COMPREPLY=($(compgen -W "--only --runs --window --dry-run $global_opts" -- "$cur"))
                        ;;
                    history)
                        COMPREPLY=($(compgen -W "--limit $global_opts" -- "$cur"))
                        ;;
                    compare)
                        COMPREPLY=($(compgen -W "latest previous $global_opts" -- "$cur"))
                        ;;
                    *)
                        COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        scan)
            # `scan` takes options and one local image reference, which
            # cannot be completed without querying the engine.
            COMPREPLY=($(compgen -W "help --check --offline --sbom-only --sbom --fail-on --all $global_opts" -- "$cur"))
            ;;
        export)
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "image volume help --all $global_opts" -- "$cur"))
            elif [[ "$sub" == "image" || "$sub" == "volume" ]]; then
                COMPREPLY=($(compgen -W "--output --replace $global_opts" -- "$cur"))
            elif [[ " ${COMP_WORDS[*]:0:COMP_CWORD} " == *' --all '* ]]; then
                COMPREPLY=($(compgen -W "--output --replace $global_opts" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        debug)
            # `morb debug <container>` is also valid, but a container name
            # cannot be completed without querying the engine.
            if [[ -z "$sub" ]]; then
                COMPREPLY=($(compgen -W "check plan help $global_opts" -- "$cur"))
            elif [[ "$sub" == "check" ]]; then
                COMPREPLY=($(compgen -W "--manifest $global_opts" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            fi
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
    return 0
}

complete -F _morb morb
