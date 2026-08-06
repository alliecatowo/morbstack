# Fish completion for the `morb` CLI (Morbstack).
#
# Install: copy or symlink to ~/.config/fish/completions/morb.fish (fish
# loads completions from that directory automatically; no sourcing step
# needed). See integrations/shell/README.md.
#
# DO NOT hand-edit the top-level command block below without also updating
# mac/Sources/morb/main.swift. ShellCompletionDriftTests
# (mac/Tests/MorbstackKitTests/ShellCompletionDriftTests.swift) fails the
# build when the `__fish_use_subcommand` entries below differ, in name or
# in description, from the command table `morb`'s parser dispatches on.
# That test exists because these files silently went stale by seven
# commands once already.
#
# Per-subcommand flags are NOT derived from `morb --help`: morb strips
# --help/-h from the whole argument list before dispatch, so
# `morb mcp --help` prints the global usage, never the module's own. The
# grammars below come from mac/Sources/morb/main.swift and from the feature
# modules it dispatches to (MorbMCP, MorbMigrate, MorbBench, MorbScan,
# MorbExport).

complete -c morb -f

# --- Top-level commands (only before any subcommand has been typed) ---

complete -c morb -n __fish_use_subcommand -a status -d 'Show daemon and VM state'
complete -c morb -n __fish_use_subcommand -a start -d 'Boot the VM'
complete -c morb -n __fish_use_subcommand -a stop -d 'Shut the VM down'
complete -c morb -n __fish_use_subcommand -a suspend -d 'Release VM memory; a host that cannot restore state stops cleanly'
complete -c morb -n __fish_use_subcommand -a resume -d 'Start a suspended VM; cold-boots when state cannot be restored'
complete -c morb -n __fish_use_subcommand -a shares -d 'List the shared host paths and whether the guest has them'
complete -c morb -n __fish_use_subcommand -a rosetta -d 'Show Rosetta status; `rosetta install` sets it up'
complete -c morb -n __fish_use_subcommand -a k8s -d 'Run a local Kubernetes cluster (off by default)'
complete -c morb -n __fish_use_subcommand -a version -d 'Print CLI and daemon versions'
complete -c morb -n __fish_use_subcommand -a doctor -d 'Diagnose the host; works without the daemon'
complete -c morb -n __fish_use_subcommand -a diagnose -d 'Create a redacted, reviewable support bundle; never starts the daemon'
complete -c morb -n __fish_use_subcommand -a disk -d 'Inspect or grow VM disk capacity with an explicit target'
complete -c morb -n __fish_use_subcommand -a ports -d 'Check loopback port availability; never reserves or starts the daemon'
complete -c morb -n __fish_use_subcommand -a reset-disk -d 'Delete the Docker data disk and start over (destructive)'
complete -c morb -n __fish_use_subcommand -a mcp -d 'Model Context Protocol server; read-only unless granted'
complete -c morb -n __fish_use_subcommand -a migrate -d 'Import images, volumes and config from another runtime'
complete -c morb -n __fish_use_subcommand -a bench -d 'Run the open benchmark suite and report the numbers'
complete -c morb -n __fish_use_subcommand -a scan -d 'SBOM and CVE scan an image, entirely on this machine'
complete -c morb -n __fish_use_subcommand -a export -d 'Write an already-local image or named-volume archive to a user-selected file'
complete -c morb -n __fish_use_subcommand -a debug -d 'Inspect safe toolbox availability; does not open a shell yet'
complete -c morb -n __fish_use_subcommand -a context -d 'Inspect the `morbstack` Docker context and discovery socket'
complete -c morb -n __fish_use_subcommand -a service -d 'Manage Morbstack\'s explicit per-user background service'
complete -c morb -n __fish_use_subcommand -a install-cli -d 'Install bundled docker, compose, and buildx for this user'
complete -c morb -n __fish_use_subcommand -a uninstall-cli -d 'Remove only the CLI links/socket/context/profile block Morbstack owns'
complete -c morb -n __fish_use_subcommand -a install-cli-plugins -d 'Legacy: install only compose/buildx plugins (prefer install-cli)'

# --- Global options, valid anywhere in the command line ---

complete -c morb -l json -d 'Emit raw JSON instead of human-readable output'
complete -c morb -l help -d 'Print help and exit'
complete -c morb -s h -d 'Print help and exit'

# --- rosetta ---

complete -c morb -n '__fish_seen_subcommand_from rosetta; and not __fish_seen_subcommand_from status install' \
    -a status -d 'Show Rosetta status (the default)'
complete -c morb -n '__fish_seen_subcommand_from rosetta; and not __fish_seen_subcommand_from status install' \
    -a install -d 'Install Rosetta and enable it; always asks for confirmation'

# rosetta install's own flags. --force is deliberately refused by
# `rosetta install` (main.swift makes it a hard error), so it is not
# offered here even though it exists on other commands.
complete -c morb -n '__fish_seen_subcommand_from rosetta; and __fish_seen_subcommand_from install' \
    -l print-plan -d 'Print exactly what install would do, and stop'

# --- k8s ---

complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a status -d 'Show whether the cluster is installed, on, and Ready (the default)'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a enable -d 'Install the payload if needed, then start the cluster'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a disable -d 'Stop the cluster; the payload and its state are kept'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a diagnose -d 'Show real cluster recovery guidance without changing it'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a describe -d 'Read one selected Pod or Node through Morbstack\'s local API'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a port-forward -d 'Manage the one selected-Pod loopback TCP lease'
complete -c morb -n '__fish_seen_subcommand_from k8s; and not __fish_seen_subcommand_from status enable disable diagnose describe port-forward kubeconfig' \
    -a kubeconfig -d 'Write ~/.morbstack/kubeconfig and say how to use it'

# k8s kubeconfig's own flags.
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from kubeconfig' \
    -l merge -d 'Merge the morbstack context into ~/.kube/config, after asking'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from kubeconfig' \
    -l switch-context -d 'With --merge, also switch current-context to morbstack'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from kubeconfig' \
    -l force -d 'Skip the --merge confirmation prompt'

# k8s describe takes a resource kind, then its operands.
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from describe; and not __fish_seen_subcommand_from pod node' \
    -a pod -d 'describe pod <namespace> <name>'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from describe; and not __fish_seen_subcommand_from pod node' \
    -a node -d 'describe node <name>'

# k8s port-forward's operations and the flags only `start` accepts.
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from port-forward; and not __fish_seen_subcommand_from start cancel' \
    -a start -d 'Start one selected-Pod loopback TCP lease'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from port-forward; and not __fish_seen_subcommand_from start cancel' \
    -a cancel -d 'Cancel only that exact selected-Pod lease'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from port-forward; and __fish_seen_subcommand_from start' \
    -l container -r -d 'Select one container inside the Pod'
complete -c morb -n '__fish_seen_subcommand_from k8s; and __fish_seen_subcommand_from port-forward; and __fish_seen_subcommand_from start' \
    -l local-port -r -d 'Bind this loopback TCP port instead of an ephemeral one'

# --- context ---

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

# --- service ---

complete -c morb -n '__fish_seen_subcommand_from service; and not __fish_seen_subcommand_from status enable disable settings' \
    -a status -d 'Show background-service registration and approval state (the default)'
complete -c morb -n '__fish_seen_subcommand_from service; and not __fish_seen_subcommand_from status enable disable settings' \
    -a enable -d 'Register the signed app\'s per-user LaunchAgent'
complete -c morb -n '__fish_seen_subcommand_from service; and not __fish_seen_subcommand_from status enable disable settings' \
    -a disable -d 'Unregister it; does not stop a manually started daemon'
complete -c morb -n '__fish_seen_subcommand_from service; and not __fish_seen_subcommand_from status enable disable settings' \
    -a settings -d 'Open System Settings > Login Items explicitly'

# --- disk ---

complete -c morb -n '__fish_seen_subcommand_from disk; and not __fish_seen_subcommand_from status grow' \
    -a status -d 'Show VM disk capacity and safe growth status (the default)'
complete -c morb -n '__fish_seen_subcommand_from disk; and not __fish_seen_subcommand_from status grow' \
    -a grow -d 'Grow an existing disk to <GiB>; never shrinks'

# --- ports ---
#
# `check` is the only subcommand and is also the default, so its flags are
# offered whether or not the word was typed.

complete -c morb -n '__fish_seen_subcommand_from ports; and not __fish_seen_subcommand_from check' \
    -a check -d 'Check one or more loopback endpoints (the default)'
complete -c morb -n '__fish_seen_subcommand_from ports' -l tcp -r -d 'Check this loopback TCP port'
complete -c morb -n '__fish_seen_subcommand_from ports' -l udp -r -d 'Check this loopback UDP port'

# --- diagnose ---

complete -c morb -n '__fish_seen_subcommand_from diagnose' -l output -r -F \
    -d 'Write the bundle below this absolute or ~/ directory'

# --- install-cli / uninstall-cli / install-cli-plugins ---

complete -c morb -n '__fish_seen_subcommand_from install-cli' \
    -l force -d 'Apply the printed plan without the confirmation prompt'
complete -c morb -n '__fish_seen_subcommand_from install-cli' \
    -l print-plan -d 'Print exactly what it would do, and stop'
complete -c morb -n '__fish_seen_subcommand_from install-cli' \
    -l make-default -d 'Put ~/.morbstack/bin before an existing docker on PATH'

complete -c morb -n '__fish_seen_subcommand_from uninstall-cli install-cli-plugins' \
    -l force -d 'Skip the confirmation prompt'
complete -c morb -n '__fish_seen_subcommand_from uninstall-cli install-cli-plugins' \
    -l print-plan -d 'Print exactly what it would do, and stop'

# --- stop / reset-disk: --force ---

complete -c morb -n '__fish_seen_subcommand_from stop reset-disk' \
    -l force -d 'Skip the confirmation prompt (reset-disk), or stop without asking the guest first (stop)'

# --- mcp ---

complete -c morb -n '__fish_seen_subcommand_from mcp; and not __fish_seen_subcommand_from serve init permissions help' \
    -a serve -d 'Run the MCP server over stdin/stdout'
complete -c morb -n '__fish_seen_subcommand_from mcp; and not __fish_seen_subcommand_from serve init permissions help' \
    -a init -d 'Create ~/.morbstack/mcp.toml with a read-only-by-default profile'
complete -c morb -n '__fish_seen_subcommand_from mcp; and not __fish_seen_subcommand_from serve init permissions help' \
    -a permissions -d 'Show every tool\'s effective permission and where it came from'
complete -c morb -n '__fish_seen_subcommand_from mcp; and not __fish_seen_subcommand_from serve init permissions help' \
    -a help -d 'Print the mcp usage text'

complete -c morb -n '__fish_seen_subcommand_from mcp; and __fish_seen_subcommand_from serve permissions' \
    -l allow -r -d 'Grant a tool, a group, or an argument guard'
complete -c morb -n '__fish_seen_subcommand_from mcp; and __fish_seen_subcommand_from init' \
    -l force -d 'Replace an existing mcp.toml with the empty template'

# --- migrate ---

complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a detect -d 'Survey local container runtimes (the default)'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a config -d 'Inspect Docker CLI configuration, read-only'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a plan -d 'Derive a read-only image comparison and named-volume eligibility plan'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a run -d 'Import an explicitly selected image set, verify it, and write a report'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a images -d 'Copy images into Morbstack'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a volumes -d 'Copy named volumes into Morbstack'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a verify -d 'Compare images and volumes between engines'
complete -c morb -n '__fish_seen_subcommand_from migrate; and not __fish_seen_subcommand_from detect config plan run images volumes verify help' \
    -a help -d 'Print the migrate usage text'

complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from plan run images volumes verify' \
    -l from -r -d 'Docker Desktop, Colima, OrbStack, or a socket path'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from plan images volumes' \
    -l filter -r -d 'Include only matching images or named volumes'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from plan images' \
    -l all -d 'Include dangling images'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from run images volumes' \
    -l dry-run -d 'Print the plan without changing anything'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from run images volumes verify' \
    -l yes -d 'Skip the confirmation prompt'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from volumes' \
    -l overwrite -d 'Rejected: migration never merges existing destination contents'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from run' \
    -l image -r -d 'Select one planned image; repeat for more'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from run' \
    -l all-images -d 'Explicitly select every currently planned tagged image'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from verify' \
    -l images -r -d 'Image references to compare'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from verify' \
    -l volumes -r -d 'Named volumes to compare'
complete -c morb -n '__fish_seen_subcommand_from migrate; and __fish_seen_subcommand_from verify' \
    -l report -r -F -d 'Read copied items from a migration report'

# --- bench ---

complete -c morb -n '__fish_seen_subcommand_from bench; and not __fish_seen_subcommand_from list run history compare help' \
    -a list -d 'Show published targets and implementation status'
complete -c morb -n '__fish_seen_subcommand_from bench; and not __fish_seen_subcommand_from list run history compare help' \
    -a run -d 'Run every implemented benchmark, or named ones only'
complete -c morb -n '__fish_seen_subcommand_from bench; and not __fish_seen_subcommand_from list run history compare help' \
    -a history -d 'Show saved benchmark runs'
complete -c morb -n '__fish_seen_subcommand_from bench; and not __fish_seen_subcommand_from list run history compare help' \
    -a compare -d 'Compare two saved runs'
complete -c morb -n '__fish_seen_subcommand_from bench; and not __fish_seen_subcommand_from list run history compare help' \
    -a help -d 'Print the bench usage text'

complete -c morb -n '__fish_seen_subcommand_from bench; and __fish_seen_subcommand_from run' \
    -l only -r -d 'Run only these benchmarks'
complete -c morb -n '__fish_seen_subcommand_from bench; and __fish_seen_subcommand_from run' \
    -l runs -r -d 'Repeat each benchmark this many times'
complete -c morb -n '__fish_seen_subcommand_from bench; and __fish_seen_subcommand_from run' \
    -l window -r -d 'Idle sampling window, in seconds'
complete -c morb -n '__fish_seen_subcommand_from bench; and __fish_seen_subcommand_from run' \
    -l dry-run -d 'Print each exact plan without measuring'
complete -c morb -n '__fish_seen_subcommand_from bench; and __fish_seen_subcommand_from history' \
    -l limit -r -d 'How many saved runs to show (default 20)'
complete -c morb -n '__fish_seen_subcommand_from bench; and __fish_seen_subcommand_from compare' \
    -a 'latest previous' -d 'A saved run: a path, an id, latest, or previous'

# --- scan ---
#
# `scan` takes options and one local image reference, not a subcommand.

complete -c morb -n '__fish_seen_subcommand_from scan; and not __fish_seen_subcommand_from help' \
    -a help -d 'Print the scan usage text'
complete -c morb -n '__fish_seen_subcommand_from scan' -l check \
    -d 'Report local syft/grype/database prerequisites only'
complete -c morb -n '__fish_seen_subcommand_from scan' -l offline \
    -d 'Require a valid cached Grype database; never update it'
complete -c morb -n '__fish_seen_subcommand_from scan' -l sbom-only \
    -d 'Stop after the local syft SBOM is generated'
complete -c morb -n '__fish_seen_subcommand_from scan' -l sbom -r -F \
    -d 'Also write the generated syft JSON SBOM here'
complete -c morb -n '__fish_seen_subcommand_from scan' -l fail-on -r \
    -a 'negligible low medium high critical' -d 'Exit 2 at or above this severity'
complete -c morb -n '__fish_seen_subcommand_from scan' -l all \
    -d 'Show every finding instead of the first 20'

# --- export ---

complete -c morb -n '__fish_seen_subcommand_from export; and not __fish_seen_subcommand_from image volume help' \
    -a image -d 'Save one already-local Morbstack image to an archive'
complete -c morb -n '__fish_seen_subcommand_from export; and not __fish_seen_subcommand_from image volume help' \
    -a volume -d 'Archive one existing Docker local-driver named volume'
complete -c morb -n '__fish_seen_subcommand_from export; and not __fish_seen_subcommand_from image volume help' \
    -a help -d 'Print the export usage text'

complete -c morb -n '__fish_seen_subcommand_from export; and __fish_seen_subcommand_from image volume' \
    -l output -r -F -d 'Where to write the archive; required'
complete -c morb -n '__fish_seen_subcommand_from export; and __fish_seen_subcommand_from image volume' \
    -l replace -d 'Overwrite an existing file at --output'

# --- debug ---
#
# `morb debug <container>` is also valid, but a container name cannot be
# completed without querying the engine.

complete -c morb -n '__fish_seen_subcommand_from debug; and not __fish_seen_subcommand_from check plan help' \
    -a check -d 'Read the local toolbox descriptor; no engine or network access'
complete -c morb -n '__fish_seen_subcommand_from debug; and not __fish_seen_subcommand_from check plan help' \
    -a plan -d 'Inspect one container read-only and list what was not done'
complete -c morb -n '__fish_seen_subcommand_from debug; and not __fish_seen_subcommand_from check plan help' \
    -a help -d 'Print the debug usage text'

complete -c morb -n '__fish_seen_subcommand_from debug; and __fish_seen_subcommand_from check' \
    -l manifest -r -F -d 'Read this toolbox descriptor instead of the default'
