# Debug toolbox contract

`morb debug` deliberately has a **read-only planning surface**, not a shell.
It is the foundation for an isolated toolbox that can diagnose a distroless or
otherwise shell-less container without pretending that `docker exec` solves
that problem.

## Current commands

```console
morb debug check [--manifest <path>]
morb debug [plan] <container>
```

`morb debug check` reads one local asset-manifest descriptor, if present. By
default its location is
`~/.morbstack/data/debug-toolbox/asset-manifest.json` (or the matching path
below `MORBSTACK_HOME`). `--manifest <path>` selects a different local file for
an offline diagnostic. Neither form creates a directory, opens the Docker
socket, starts the daemon, pulls an image, or accesses a network.

The descriptor is deliberately **untrusted declarative policy**, not proof that
an image is present or safe. `check` reports one of these asset states:

- `absent` — no descriptor exists at the selected local path.
- `invalid` — it cannot be read or decoded, or it fails the structural schema
  or compatibility validation.
- `expired` — its declared provenance-policy expiry is in the past.
- `declared-but-unverified` — it is structurally valid and current, but no
  image digest, image-index platform, certificate, signature, or provenance
  bundle has been verified.

All four states leave the toolbox unavailable and exit with status `2`.

`check` also returns a static, machine-readable **future acquisition and
rollback contract**. It identifies the next safe disposition for the observed
descriptor and lists the required transaction stages. This is deliberately a
preview: it does not request network consent, contact a registry or Docker,
inspect/import/pull/remove/tag an image, write a receipt, or activate anything.
Its `available` value is always `false`.

### Asset-manifest v1

The future acquisition flow may write one v1 descriptor after explicit user
consent. It must contain a digest-pinned image reference, the same image digest
separately, a `linux/arm64` platform declaration, a Sigstore verification
policy, and an ISO-8601 UTC policy expiry. The values below are inert example
values, not a shipped or approved toolbox asset:

```json
{
  "schema_version": 1,
  "asset_id": "morbstack-debug-toolbox",
  "image_reference": "ghcr.io/morbstack/debug-toolbox@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "image_digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "platforms": [
    { "os": "linux", "architecture": "arm64" }
  ],
  "provenance": {
    "method": "sigstore",
    "issuer": "https://token.actions.githubusercontent.com",
    "identity": "https://github.com/morbstack/morbstack/.github/workflows/release.yml@refs/heads/main",
    "bundle_digest": "sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
  },
  "valid_through": "2030-01-01T00:00:00Z"
}
```

This structural pass intentionally does **not** inspect a local Docker image,
resolve an OCI index, validate the `linux/arm64` entry, retrieve anything, or
verify the declared Sigstore bundle/certificate/identity. It therefore never
removes `verified_pinned_toolbox_asset` from the readiness gate. This keeps a
convenient local manifest from becoming a confused authorization mechanism.

### Future acquisition and rollback transaction

The future implementation must use the same ordered transaction, regardless of
whether candidate bytes come from an explicitly consented registry download or
another separately disclosed import mechanism:

1. Show the exact digest, selected source, registry/network effect, retention,
   and update policy, then obtain fresh explicit consent. Transport never counts
   as verification.
2. Put the candidate image/index and Sigstore material in a private staging
   location. The active toolbox remains unchanged.
3. Verify the staged local bytes resolve to the manifest's exact digest; verify
   its `linux/arm64` platform; then verify the declared Sigstore bundle, issuer,
   signer identity, and policy expiry.
4. Write a private verification receipt containing the verified digest, platform,
   policy expiry, verifier version, and disclosed source. Publish that receipt
   and the candidate together atomically only after all verification passes.
5. Keep the preceding verified asset until the replacement is known usable. A
   rollback must re-check the retained asset's receipt and policy expiry before
   it becomes active again.

If any stage fails or is interrupted, clean up only that staged candidate and
record whether cleanup succeeded. The implementation must never fall back to an
expired, unsigned, tag-only, or merely declared asset, and it must never delete
or replace the prior verified asset before the new candidate is completely
verified. A successful pull/import/copy, or a receipt file by itself, is not a
toolbox session and cannot open a terminal.

`morb debug <container>` (also spelled `morb debug plan <container>`) makes one
read-only Docker Engine request, after the same default local descriptor check:

```text
GET /containers/{id-or-name}/json
```

It extracts a redacted target summary—identity, image reference/ID, and
state—then records both the request made and the actions deliberately not
performed. It does not retain or print environment variables, labels, process
arguments, mounts, or credentials from the inspect document.

Both forms exit with status `2` while a toolbox cannot safely be offered. This
is an intentional unavailable result, not a partially working shell.

## Why an ordinary exec is not this feature

An exec session requires an executable already inside the target image. It
cannot help a distroless image that has no shell or diagnostic tools, and the
current client only collects complete exec output; it cannot safely relay a
live terminal. Docker itself treats its `docker debug` toolbox as a separate
tool-rich environment rather than a synonym for `docker exec`.

Morbstack must not suggest an exec command as a workaround for the toolbox
feature. A person may use their normal Docker tooling for a container they
already know contains a suitable executable, but that is a different operation
with different security and failure semantics.

## Execution gate

No `run` action or native-app Debug button may be added until every requirement
below is implemented and independently verified against a real engine:

1. **Verified immutable toolbox asset.** The read-only v1 descriptor above is
   only the schema/provenance-policy foundation. A local toolbox image still
   needs inspection by its pinned digest, platform/index validation, and actual
   provenance/signature/certificate/identity verification before it is allowed
   into a target's namespaces.
2. **Consented acquisition and update policy.** `morb debug check` now exposes
   the required non-executing transaction/rollback contract. An implementation
   still needs the separately announced, user-approved acquisition controller,
   private staging/receipt storage, real byte/provenance verification, atomic
   activation, cleanup, and retained-asset rollback behavior. `morb debug` must
   never silently pull, import, refresh, or activate it.
3. **Isolated session policy.** The helper-container lifecycle must define the
   exact PID, network, filesystem/mount, user, capability, secret, and
   namespace boundaries. It must include cancellation, cleanup, and visible
   handling for a failed cleanup. The target container remains unmodified.
4. **Interactive terminal bridge.** A full-duplex stdin/stdout/stderr and TTY
   relay needs terminal-resize, disconnect, cancellation, and exit-status
   semantics. Capturing a completed Engine exec response is not sufficient.
5. **Truthful progress and recovery.** The command and any native UI must show
   the selected asset/provenance, the exact requested isolation, network
   consent, helper lifecycle progress, and cleanup result. No target state may
   be implied when it was not achieved.

The Engine API's container-inspect endpoint supports the current planner. The
future executor will require separately scoped, mutating Docker API calls only
after the preceding contract exists.

## Sources

- [Docker Engine API: inspect a container](https://docs.docker.com/reference/api/engine/version/v1.46/#tag/Container/operation/ContainerInspect)
- [Docker Debug CLI](https://docs.docker.com/reference/cli/docker/debug/)

These sources describe Docker's interfaces and toolbox behavior. They do not
authorize Morbstack to copy Docker's image, network, or privilege policy; this
document defines Morbstack's stricter execution gate.
