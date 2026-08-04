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
  **Save Visible Build Log…** is available only after that exact selected record’s
  retained output is loaded. It freezes the already-loaded text before the native save
  panel opens, writes it atomically, and never re-runs `history logs` while saving. The
  `.log` preamble records the selected record, capture time, source command, no-log-filter
  scope, and whether the 4 MB retained prefix was truncated. It states that this is one
  Buildx record’s retained output—not complete builder, Docker, CI, or build history—and
  leaves the raw Buildx text unchanged after the preamble.
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
- **The active builder** is a separate, explicitly requested Buildx inspection. Its
  system sheet never calls `docker buildx ls`: Docker documents that command as listing
  every builder and node, and the bundled Buildx implementation loads each configured
  node to obtain its status. A modified app-owned configuration could therefore make a
  seemingly read-only inventory contact a remote endpoint. The sheet instead reports
  only `docker buildx inspect --timeout=10s`, without `--bootstrap`, from a History
  refresh or when the person chooses **Check Active Builder**. It offers one confirmed
  recovery command, `docker buildx use default`, in Morbstack's private Buildx configuration and local
  socket. Docker documents `use` as selecting the builder for later builds; Morbstack
  passes neither `--default` nor `--global`, and never lists/selects remote builders,
  creates/removes builders, starts a builder, inherits a shell Docker context, or uses
  Build Cloud. If someone has manually changed Morbstack's private configuration to
  select a remote builder, the explicit inspection can contact that one selected builder
  while obtaining its reported state; the app still never fans out to every stored
  builder. A successful reset refreshes the Buildx history and active-builder facts that
  the route displays.

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

Active-builder management follows the same task-shaped vocabulary: a secondary native
toolbar command opens a document-modal `Form` for scalar builder and node facts, while
an unqueried or failed check uses `ContentUnavailableView` with the next safe action.
The one state-changing local-default recovery has a native confirmation dialog and a
standard error/retry alert; simply opening the sheet has no Buildx side effect.

The completed-build Log tab remains a native selectable monospaced transcript. Its
contextual secondary-toolbar save command uses `NSSavePanel` for destination/replacement
semantics and a native retry alert only after an actual atomic-write failure; it has no
custom export dashboard, no save action before output exists, and no save-time builder
query.

This follows Apple’s [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets),
[Form](https://developer.apple.com/documentation/swiftui/form),
[ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and
[ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview)
guidance, plus Docker’s [builder inventory](https://docs.docker.com/reference/cli/docker/buildx/ls/),
[builder selection](https://docs.docker.com/reference/cli/docker/buildx/use/), and
[builder-management](https://docs.docker.com/build/builders/manage/) documentation.
Real-window visual validation remains a serialized integration task; this source change
was intentionally not used to start the engine, change a builder, or execute a build.
