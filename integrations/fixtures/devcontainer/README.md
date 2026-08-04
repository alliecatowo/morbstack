# Morbstack Dev Containers acceptance fixture

This fixture is deliberately tiny: it pulls the public Alpine Dev Containers
base image and writes one sentinel in `postCreateCommand`. It has no bind mount,
secret, Docker socket, or local build context, so a failure isolates Docker
discovery, image pull, container creation, or Dev Containers lifecycle rather
than a project-specific toolchain.

Run it only through [`docs/ecosystem-acceptance.md`](../../../docs/ecosystem-acceptance.md).
The evidence owner supplies a unique `--id-label`, verifies
`/tmp/morbstack-devcontainer-sentinel` equals `ready`, and removes only the
resources carrying that label.
