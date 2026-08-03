# Migration contract

Morbstack migration is deliberately split into a read-only comparison and a
small, explicit transaction. It never changes another runtime's Docker CLI
configuration, contexts, credentials, images, containers, or volumes.

## Images-only transaction

The currently executable structured transaction imports selected **local
images only**:

```console
# Inspect both existing image inventories. This writes nothing.
morb migrate plan --from docker-desktop

# Prepare one exact image and ask for confirmation before importing it.
morb migrate run --from docker-desktop --image my-registry.example/app:1.4

# Show the exact all-image selection without writing anything.
morb migrate run --from docker-desktop --all-images --dry-run

# An unattended caller must make both choices explicitly.
morb --json migrate run --from docker-desktop --all-images --yes
```

`--image` can be repeated. Each reference must be a `would copy` entry from
the current `morb migrate plan`; a destination image that appeared after the
plan, or a source tag that changed to another image ID, is refused rather than
overwritten. `--all-images` is intentionally broad and selects every currently
planned **tagged** image only after its own confirmation. Dangling images are
not part of this transaction. `--from` is required for execution even when
only one source runtime is running; source auto-selection is reserved for the
read-only inspection path.

`--dry-run` prepares the same typed selection and prints it without reading an
archive, importing an image, writing a report, or changing either engine.
Without `--dry-run`, the command prints the selected images and asks once. The
`--yes` flag is an explicit opt-in to skip that terminal prompt. JSON output
requires `--yes` so a prompt can never corrupt a machine-readable response.

## Exact behavior

Preparation reads source and destination image inventories. For every selected
image, execution then:

1. Reads the source and destination tag again. The source must still match the
   selected Docker config ID; Morbstack must either lack the tag or already
   hold that same ID.
2. Streams a local `GET /images/get` archive from the source runtime into one
   temporary file in Morbstack-owned state.
3. Streams that file to Morbstack's `POST /images/load`; it never pushes or
   pulls a registry image.
4. Reads both image IDs again and records whether they match the selected ID.
5. Removes the temporary archive and writes a structured JSON report under
   `~/.morbstack/migrate/image-transactions/`.

The source-side Docker operations are only image inventory/inspect/export
`GET` requests. The only Docker mutation is loading an archive into
Morbstack's fixed destination socket. Docker documents the same archive model
for [`docker image load`](https://docs.docker.com/reference/cli/docker/image/load/)
and its backup/restore guidance describes saving local images and loading the
archive into a new image store. [Docker's backup guidance](https://docs.docker.com/desktop/settings-and-maintenance/backup-and-restore/)
also makes clear that volume data is a separate concern.

## Excluded on purpose

This transaction does **not** migrate:

- named volumes or bind mounts;
- containers, Compose stacks, Kubernetes workloads, or container writable
  layers;
- Docker contexts, `config.json`, registry credentials, or credential helpers;
- registry state, image pulls, signature/attestation retrieval, or network
  access outside the two local Docker sockets.

The existing `morb migrate volumes` command remains a separate, explicitly
reviewed operation because its current implementation requires helper
containers (including on the source) to access volume bytes. It is not bundled
into `run` and is not represented as part of an images-only success report.

## Progress, verification, and reports

`ImageMigrationTransaction` is a public typed service API. It produces a
prepared selection, requires a confirmation value bound to that exact
selection, emits per-image phase and byte progress, and returns a structured
`ImageMigrationTransactionReport`. The CLI renders that data; it does not
turn terminal text back into application state.

Every report records the selected reference, expected source image ID,
destination image ID when available, archive byte count, final item outcome,
verification state, source-untouched assertion, excluded scopes, and exact
rollback/provenance limits. A later independent comparison can use the report:

```console
morb migrate verify --report /path/from/the-transaction-report.json
```

Matching Docker image config IDs is useful local identity evidence for the
save/load operation. It is not a publisher signature, registry provenance
check, attestation, SBOM, or vulnerability result. Credentials are never read,
copied, or invoked; re-authentication and provenance policy remain separate
user-owned decisions. The current image comparison represents one exported
tagged reference per source image; it does not separately verify every alias
tag on that image. Review any additional tags after migration and re-tag them
explicitly if the workflow needs them.

## Cancellation and rollback

The typed service can stop before the next selected image and during source
archive export. Once `POST /images/load` begins, it completes that single load
and verifies the resulting destination state before stopping, because aborting
a partially uploaded archive would make the destination result less knowable.
The command-line interface does not yet install signal-driven resumable
cancellation; an interrupted process should be treated as uncertain and the
destination inspected before a retry.

There is no automatic rollback. It would be unsafe to bulk-delete image IDs:
images can share layers and tags, and another process may change the
destination after the transaction. The report identifies every selected tag;
inspect current Morbstack state and remove only an exact, reviewed imported tag
with normal Docker tooling if cleanup is required. An item marked `failed` or
`requires_review` is never evidence that the destination was left unchanged.
