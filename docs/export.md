# Local archive export

`morb export image` is the explicit, current-engine equivalent of saving one
already-local Docker image to a `docker save` archive:

```console
morb export image <reference-or-id> --output <path> [--replace]
```

It uses exactly one Docker Engine request against Morbstack's own local socket:

```text
GET /images/get?names=<reference-or-id>
```

Docker documents this endpoint as an archive of the selected image (and its
parents). Treat the result as a Docker-save-compatible tar archive: it carries
Docker's `manifest.json` and, for named exports, `repositories` metadata along
with the image configuration and layer tar content. It is not promised as a
generic OCI-layout interchange directory. The export is a local Engine read:
Morbstack does not use a registry, Docker CLI configuration, credential helper,
image pull/push/load/tag/delete API, or any container API for this command.

## Destination contract

`--output` is mandatory. There is no default destination and the command never
creates parent directories. The path may be absolute, `~/`-relative, or relative
to the current directory, but it must name a file below an existing directory.

Morbstack writes the stream to a private `0600` staging file beside that output,
then fsyncs and publishes it atomically. An existing output is refused unless
`--replace` is explicit. Without `--replace`, the final no-clobber publish uses
an atomic filesystem link; with it, the old output is atomically replaced only
after the new archive is complete. Any download, Engine, write, or commit error
removes the staging file and leaves the requested output unchanged.

The command refuses every destination within `~/.morbstack` (or
`MORBSTACK_HOME`), including a selected path reached through a symlink. Runtime
state is not an archive destination.

An exported archive can contain image configuration and layer contents. Save it
in a location appropriate for that data and choose sharing/upload handling
separately; this feature does not upload or encrypt it.

## Native local image archive import

The native Images route can load one explicitly chosen **local `.tar` file**. It
is an app document workflow, not a registry feature and not a counterpart to the
images-only runtime migration tool. The system `NSOpenPanel` limits selection to
tar archives, then a document-modal `Form` names the selected path and current
file size before a separate confirmation. The app does not look inside
`manifest.json`, infer an image reference, or claim that a tag will be restored.

After confirmation, the typed `ImageArchiveImporter` issues exactly one current
Engine request:

```text
POST /images/load?quiet=1
Content-Type: application/x-tar
```

The selected file is opened and streamed in 1 MiB chunks with a real
`Content-Length`; it is never materialized as one in-memory `Data`. The client
stats the already-open descriptor before it writes that header, so the header
describes the file that was actually opened. The reviewed file **size** is checked
again before the Engine connection; if its size changed, the person must choose
the file again. This is not a content hash or file-identity snapshot: a same-size
replacement is not detected before the request. The importer does not
inspect the file's archive entries, request arbitrary Engine JSON, call the
Docker CLI, read Docker configuration or credentials, pull/push an image, or
contact a registry.

Progress is the exact number of source bytes written to Docker, against the
selected file's known size. When the complete file has been written, the sheet
switches to an indeterminate **Waiting for Docker** phase: unpacking layers and
registering tags can continue after upload progress reaches its endpoint. The
Cancel control is available only while source bytes are still being sent. A
cancelled connection may have delivered a prefix of the tar, so the app refreshes
its local image inventory and says to inspect it before retrying; it never says
that no image was loaded. Docker's 2xx response without a reported load error is
the only success condition. The UI displays a bounded, sanitized error sentence,
but that presentation cap is not a transport or response-memory cap; the current
Engine client reads the complete response body. The app does not derive image names
or tag-preservation claims from the response.

## Named-volume archive export

`morb export volume` exports exactly one existing Morbstack named volume as a
tar archive:

```console
morb export volume <name> --output <path> [--replace]
```

This is deliberately not a Finder mount or a volume migration/import path. The
command first reads `GET /volumes/<name>` and accepts only Docker's `local`
driver. It then finds one already-local image; v1 never pulls a helper image or
contacts a registry. Morbstack creates an owned, **stopped** helper container
with only that volume mounted at `/data:ro`, streams
`GET /containers/<helper>/archive?path=/data` into the same private atomic
staging writer, and force-removes the helper before it publishes the completed
archive. Every error path attempts owned-helper cleanup and discards the staging
file; a known cleanup failure prevents publication and is reported plainly.

The export is read-only with respect to the selected volume: it does not start
the helper, execute a command in it, import the archive, modify the volume,
write back its data, inspect an existing destination volume, access credentials,
or create a default output location. The archive is a filesystem tar for the
selected volume, not an OCI image archive or a general bidirectional file API.

## Native-app export boundary

The Images route exposes **Export Selected Image…** through the standard macOS
Image menu, its selection context menu, the selected-image inspector, and the
native **Image Archive** toolbar menu. The same toolbar menu and Image menu expose
**Load Image Archive…** even when the local image table is empty; import has no
selected-record dependency. Export starts from the exact local image ID, opens
`NSSavePanel` for an explicit location, lets the system present its normal
replacement decision, then calls the same `ImageArchiveExporter` contract as the
CLI.

While the Engine streams, the app uses a document-modal `Form` with actual bytes
written. It shows a determinate `ProgressView` only when Docker supplies a total
content length; otherwise the indicator stays indeterminate rather than
inventing a percentage. Cancel requests a stream stop and the service discards
the private staging file. Success is shown only after the atomic commit; a
failure or cancellation never claims that an archive was saved.

### App streaming boundary

The native app deliberately calls typed archive services, not `DockerClient`.
`DockerClient` has no public typed file-streaming/atomic-archive contract;
exposing a second raw archive writer or uploader there would duplicate chunk
decoding, cancellation, error-body handling, and atomic staging policy.
`ImageArchiveExporter` owns its reviewed
`GET /images/get?names=<immutable-image-id>` reader and is shared with
`morb export image`; `ImageArchiveImporter` owns the one reviewed
`POST /images/load?quiet=1` writer. Neither is a generic Docker request or
registry client.

There is no native volume-export action yet. A later volume route must begin
from an explicit selected local volume, use `NSSavePanel`, disclose the temporary
read-only helper and no-pull rule, and call `VolumeArchiveExporter` rather than
implementing another archive or cleanup path.

## Sources

- [Docker Engine API: export an image](https://docs.docker.com/reference/api/engine/version/v1.46/#tag/Image/operation/ImageGet)
- [Docker Engine API: load an image](https://docs.docker.com/reference/api/engine/version/v1.46/#tag/Image/operation/ImageLoad)
- [Docker image save](https://docs.docker.com/reference/cli/docker/image/save/)
- [Docker image load](https://docs.docker.com/reference/cli/docker/image/load/)

These describe Docker's archive format and endpoint. Morbstack's destination,
atomicity, and private-state restrictions are product policy defined here.
