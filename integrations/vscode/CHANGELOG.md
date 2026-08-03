# Changelog

## 0.1.0

First release.

- Morbstack view container with four views: Containers (grouped by Compose
  project), Images, Volumes, Kubernetes.
- Container lifecycle: start, stop, restart, remove; start/stop every container
  in a Compose project.
- Follow container logs in an output channel, with stdcopy demultiplexing for
  non-TTY containers.
- Interactive shell in a container, implemented against the Engine API's exec
  endpoints over a hijacked stream. Does not require the `docker` CLI.
- Open a published port in the browser from the tree.
- Inspect containers, images and volumes as JSON documents.
- Prune stopped containers, dangling images and unused networks, optionally
  including unused volumes.
- Status bar item with the engine state and running-container count. Warns when
  `morb` reports published ports that could not be bound on the Mac.
- Start and stop the engine through the `morb` CLI.
- Live updates from the engine's `/events` stream, with a configurable
  fallback poll.
- Settings for socket path, `morb` path, grouping, refresh interval, shell,
  log tail length and the status bar item.
