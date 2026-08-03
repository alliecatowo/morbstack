# Builds

Morbstack's Builds route has two deliberately separate pieces of Docker state:

- **BuildKit cache records** come from Docker Engine's `GET /system/df`. They are a
  shared cache graph, not individual completed builds. The native table lets a person
  search, sort, inspect, and copy an actual cache-record ID. Docker Engine exposes only
  an engine-wide unused-cache cleanup (`POST /build/prune`), so the app never pretends
  it can delete one reviewed record.
- **Buildx completed-build history** is a separately requested active-builder record
  list from `docker buildx history ls --format=json`; it is never inferred from cache
  layers. Selecting a history row does not create another process. The trailing native
  inspector starts with a direct `ContentUnavailableView` and the clearly labeled
  **Load Details** action. Only that action runs the bounded, sealed-environment
  `docker buildx history inspect --format=json <selected-record-id>` read. Its `Form`
  contains only JSON fields Buildx actually returned; absent fields stay absent. Only
  after that inspection, the same selected-record inspector offers **Load Logs**. That
  separate, bounded, sealed-environment `docker buildx history logs --progress rawjson
  <selected-record-id>` read is cancellable and renders only its real stdout in a
  selectable native scroll view. The reader drains both child pipes but retains at most
  the first 4 MB of each, marking a displayed log prefix as truncated rather than
  claiming it is complete. The implementation does not read attachments or invoke
  history export, import, open, or removal.
- **A new local build** is started only after the person selects a folder containing a
  root `Dockerfile` and confirms the request. The app runs its reviewed bundled
  `docker buildx build --progress=rawjson --load` client against Morbstack's own socket.
  Docker/Buildx, rather than an app-written archive, creates the context and applies
  `.dockerignore`, symlink, and Dockerfile rules. `--load` means this intentionally
  single-platform workflow adds the successful result to the local image store; it does
  not push a registry. It uses a one-build temporary Docker CLI configuration containing
  only the bundled Buildx plugin path, then deletes it. It does not read, modify, or
  invoke the person's `~/.docker` credential helpers; consequently, a Dockerfile that
  needs to pull a private base image can fail until a separate explicit credentials
  design is implemented.

## Progress, cancellation, and recovery

The Docker Engine [Build endpoint](https://docs.docker.com/reference/api/engine/version/v1.54/#tag/Image/operation/ImageBuild)
streams one build's output after it accepts a context. The bundled Buildx client exposes
that same work as documented `--progress=rawjson` records, which Morbstack presents in
a standard indeterminate `ProgressView` plus recent observed output. BuildKit does not
promise a total step count before a build begins, so the app never invents a percentage.

Cancel terminates only the explicit bundled Docker client. Docker documents that a build
is canceled when its client drops the connection. The app then refreshes images, cache,
and disk usage; it does not claim which cache entries BuildKit retained before the
cancellation. Failed builds keep the selected context and tag available for an explicit
retry and show the actual client/BuildKit diagnostic.

Docker Engine does **not** report a durable build history: `/system/df` cache records do
not identify a completed build, its logs, duration, or produced tag. Docker documents
that this information is instead active-builder Buildx history metadata
([history list](https://docs.docker.com/reference/cli/docker/buildx/history/ls/) and
[history inspect](https://docs.docker.com/reference/cli/docker/buildx/history/inspect/), and
[history logs](https://docs.docker.com/reference/cli/docker/buildx/history/logs/)).
Morbstack adopts the three explicit, read-only history commands above. It does not
present a history detail until the person explicitly loads it, never requests a log
until that inspected record's **Load Logs** command, and never synthesizes a history,
inspect field, or log line from shared cache layers.

## Native macOS semantics

The route is a native sortable `Table` for each explicitly selected collection, standard
`.searchable` discovery, and a system `.inspector`. The on-demand Buildx detail path
uses `ContentUnavailableView`, `ProgressView`, then `Form`/`LabeledContent`; its
separately requested raw log uses a native scroll view and selectable monospaced text.
It has no automatic inspection or log load, cache-derived details/logs, cards, toolbar
replicas, or progress dashboard. Build setup is a system sheet with a `Form` and document
picker; active work is an ordinary `ProgressView`; cache pruning and build execution have
explicit confirmation/recovery states.

This follows Apple’s [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and
[ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview)
guidance. Real-window visual validation remains a serialized integration task; this
source change was intentionally not used to start the engine or execute a build.
