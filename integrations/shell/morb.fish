# Fish completion for the `morb` CLI (Morbstack).
#
# Install: copy or symlink to ~/.config/fish/completions/morb.fish (fish
# loads completions from that directory automatically; no sourcing step
# needed). See integrations/shell/README.md.
#
# The command surface is derived from mac/Sources/morb/main.swift, not
# just `morb --help`. See the README for discrepancies found between the
# two, e.g. --switch-context (k8s kubeconfig) is real but undocumented by
# `morb --help`, and `rosetta install` refuses --force rather than
# accepting it.
#
# Important caveat: `mcp`, `migrate`, `bench`, `scan` and `debug` each
# parse their own arguments in a separate Swift module that main.swift
# does not define ("The feature modules own their own argument parsing,
# output and exit codes" — main.swift's own comment) and this completion
# could not read. Only their command name and the flags morb's top-level
# parser honors uniformly (--json, --help/-h) are completed for them —
# nothing subcommand- or flag-specific.
#
# NOTE: this file was syntax-checked with `fish -n`, but fish is not
# installed on the machine these completions were written and tested on,
# so it was not smoke-tested by actually loading it or invoking Tab
# completion in a real fish session. Treat the runtime behavior as
# unverified until someone with fish available confirms it.

complete -c morb -f

# --- Top-level commands (only before any subcommand has been typed) ---

complete -c morb -n __fish_use_subcommand -a status -d 'Show daemon and VM state'
complete -c morb -n __fish_use_subcommand -a start -d 'Boot the VM'
complete -c morb -n __fish_use_subcommand -a stop -d 'Shut the VM down'
complete -c morb -n __fish_use_subcommand -a suspend -d 'Save the VM to disk and free its memory'
complete -c morb -n __fish_use_subcommand -a resume -d 'Restore a suspended VM'
complete -c morb -n __fish_use_subcommand -a shares -d 'List the shared host paths and whether the guest has them'
complete -c morb -n __fish_use_subcommand -a rosetta -d 'Show Rosetta status; "rosetta install" sets it up'
complete -c morb -n __fish_use_subcommand -a k8s -d 'Run a local Kubernetes cluster (off by default)'
complete -c morb -n __fish_use_subcommand -a version -d 'Print CLI and daemon versions'
complete -c morb -n __fish_use_subcommand -a doctor -d 'Diagnose the host; works without the daemon'
complete -c morb -n __fish_use_subcommand -a reset-disk -d 'Delete the Docker data disk and start over (destructive)'
complete -c morb -n __fish_use_subcommand -a context -d 'Manage the morbstack docker context (zero-config discovery)'
complete -c morb -n __fish_use_subcommand -a install-cli-plugins -d 'Symlink docker-compose/docker-buildx into ~/.docker/cli-plugins'
complete -c morb -n __fish_use_subcommand -a mcp -d 'Model Context Protocol server; read-only unless granted'
complete -c morb -n __fish_use_subcommand -a migrate -d 'Import images, volumes and config from another runtime'
complete -c morb -n __fish_use_subcommand -a bench -d 'Run the open benchmark suite and report the numbers'
complete -c morb -n __fish_use_subcommand -a scan -d 'SBOM and CVE scan an image, entirely on this machine'
complete -c morb -n __fish_use_subcommand -a debug -d 'Open a toolbox shell in a container, even a distroless one'

# --- Global options, valid anywhere in the command line ---

complete -c morb -l json -d 'Emit raw JSON instead of human-readable output'
complete -c morb -l help -d 'Print help and exit'
complete -c morb -s h -d 'Print help and exit'

# --- rosetta sub-subcommands ---

complete -c morb -n '__fish_seen_subcommand_from rosetta; and not __fish_seen_subcommand_from status install' \
    -a status -d 'Show Rosetta status (the default)'
complete -c morb -n '__fish_seen_subcommand_from rosetta; and not __fish_seen_subcommand_from status install' \
    -a install -d 'Install Rosetta and enable it; always asks for confirmation'

# rosetta install's own flags. --force is deliberately refused by
# `rosetta install` (main.swift makes it a hard error), so it is not
# offered here even though it exists on other commands.
complete -c morb -n '__fish_seen_subcommand_from rosetta; and __fish_seen_subcommand_from install' \
    -l print-plan -d 'Print exactly what install would do, and stop'

# --- k8s sub-subcommands ---

complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable kubeconfig' \
    -a status -d 'Show whether the cluster is installed, on, and Ready (the default)'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable kubeconfig' \
    -a enable -d 'Install the payload if needed, then start the cluster'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable kubeconfig' \
    -a disable -d 'Stop the cluster; the payload and its state are kept'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable kubeconfig' \
    -a kubeconfig -d 'Write ~/.morbstack/kubeconfig and say how to use it'

# k8s kubeconfig's own flags.
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from kubeconfig' \
    -l merge -d 'Merge the morbstack context into ~/.kube/config, after asking'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from kubeconfig' \
    -l switch-context -d 'With --merge, also switch current-context to morbstack'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from kubeconfig' \
    -l force -d 'Skip the --merge confirmation prompt'

# --- context sub-subcommands ---

complete -c morb -n '__fish_seen_subcommand_from context; and not __fish_seen_subcommand_from status create use' \
    -a status -d 'Show whether the context is registered and current (the default)'
complete -c morb -n '__fish_seen_subcommand_from context; and not __fish_seen_subcommand_from status create use' \
    -a create -d 'Register the morbstack docker context; asks first'
complete -c morb -n '__fish_seen_subcommand_from context; and not __fish_seen_subcommand_from status create use' \
    -a use -d 'Make it the default context; always asks, refuses to replace another explicit default without --force'

# context create/use's own flags. Note: for `context use`, --force does
# NOT skip its confirmation prompt (it always asks); it only lifts the
# refusal to replace another explicit non-default context. Still a real,
# accepted flag either way.
complete -c morb -n '__fish_seen_subcommand_from context; and __fish_seen_subcommand_from create use' \
    -l force -d 'Skip confirmation (create), or allow replacing another explicit default context (use)'

# --- install-cli-plugins flags ---

complete -c morb -n '__fish_seen_subcommand_from install-cli-plugins' \
    -l force -d 'Skip the confirmation prompt'
complete -c morb -n '__fish_seen_subcommand_from install-cli-plugins' \
    -l print-plan -d 'Print exactly what it would symlink, and stop'

# --- stop / reset-disk: --force ---

complete -c morb -n '__fish_seen_subcommand_from stop reset-disk' \
    -l force -d 'Skip the confirmation prompt (reset-disk), or stop without asking the guest first (stop)'

# --- mcp / migrate / bench / scan / debug ---
#
# Each of these parses its own arguments in a separate Swift module
# (MorbMCP / MorbMigrate / MorbBench / MorbScan / a debug module) that
# main.swift merely dispatches to. No sub-subcommand or flag information
# for them is available from main.swift, so nothing beyond the command
# name and the global options above is completed here.
