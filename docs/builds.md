# Builds

Morbstack's Builds route has two deliberately separate pieces of Docker state:

- **BuildKit cache records** come from Docker Engine's `GET /system/df`. They are a
  shared cache graph, not individual completed builds. The native table lets a person
  search, sort, inspect, and copy an actual cache-record ID. Docker Engine exposes only
  an engine-wide unused-cache cleanup (`POST /build/prune`), so the app never pretends
  it can delete one reviewed record.
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

The app currently does **not** report a durable build history through Docker Engine:
`/system/df` cache records do not identify a completed build, its logs, duration, or
produced tag. Docker documents that this information is instead Buildx history metadata
(`docker buildx history ls`, `inspect`, and `logs`), with records scoped to the active
builder ([history list](https://docs.docker.com/reference/cli/docker/buildx/history/ls/)).
Morbstack does not yet adopt that separate history store/API, so the route labels its
cache state honestly rather than synthesizing a history from shared layers.

## Native macOS semantics

The route is one sortable `Table` for cache records, standard `.searchable` discovery,
and an optional `.inspector` with a `Form`/`LabeledContent` detail view. Build setup is a
system sheet with a `Form` and document picker; active work is an ordinary
`ProgressView`; cache pruning and build execution have explicit confirmation/recovery
states. It introduces no app-specific cards, toolbar replicas, or progress dashboard.

This follows Apple’s [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and
[ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview)
guidance. Real-window visual validation remains a serialized integration task; this
source change was intentionally not used to start the engine or execute a build.
