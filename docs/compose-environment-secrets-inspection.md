# Compose environment and secrets inspection

**Status:** source implementation only. This is a declaration inspector for one person-selected
Compose YAML or `.env` document; it is not a Compose model evaluator, a secret manager, or a
second deployment system.

## User task and native presentation

Someone reviewing a saved Compose source needs to understand which service environment entries,
environment-file references, interpolation inputs, top-level secrets, and service grants are
declared—without turning source review into a dashboard, silently reading credential material, or
claiming a resolved container environment. The document sheet therefore uses the existing native
`Form` for provenance and scope, collapsed `DisclosureGroup`s for source metadata, and the
existing `ContentUnavailableView` before an explicitly opened `.env` document reveals text for
editing. The Compose YAML text editor remains a normal source editor; opening that document is an
explicit action. The inspector itself never copies a source value into its summary.

Apple sources consulted: [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets/),
[Forms](https://developer.apple.com/documentation/swiftui/form),
[DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup), and
[ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview).

## Docker Compose semantics represented

The view follows these Compose distinctions without attempting to resolve them:

- Service `environment` accepts map or array syntax. A service declaration has precedence over
  `env_file`, including when it is empty or undefined. A key with no assigned source value asks
  Compose to resolve it; the inspector reports that state, not the result. See the Compose
  [`environment` and `env_file` reference](https://docs.docker.com/reference/compose-file/services/#environment).
- A service `env_file` can name one or more files. Relative paths resolve from the Compose file's
  parent; later entries take precedence. The `required` and `format: raw` metadata is shown only
  when it is explicitly block-declared. Morbstack never opens those referenced files merely to
  render the summary. See [the `env_file` reference](https://docs.docker.com/reference/compose-file/services/#env_file).
- `$VAR` and `${VAR…}` source tokens outside single-quoted spans are reported as **possible**
  interpolation inputs. Compose's effective interpolation inputs normally have shell, explicit
  `--env-file`, and default `.env` precedence; this source view reads none of them. See
  [variable interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/).
- A top-level `secrets` entry defines a source; it does not grant a service access. A service's
  `secrets` entry is the explicit grant, shown separately as short or long source syntax. The
  summary can describe a declared `file`, `environment`, or `external` source and a long-syntax
  target, but never reads the secret file or host variable. See [Compose secrets](https://docs.docker.com/reference/compose-file/secrets/)
  and [service secret grants](https://docs.docker.com/reference/compose-file/services/#secrets).

The conservative scanner deliberately recognizes only ordinary block-style YAML. Inline
collections, aliases, merge keys, includes, `extends`, interpolation outcomes, and cross-file
declarations remain the bundled Compose client's responsibility. Its unavailable/ambiguous labels
are intentional: a source editor is safer than a misleading partial Compose implementation.

## Execution boundary

The separate reviewed-project commands execute the bundled Compose client with a temporary empty
Docker configuration, Morbstack's local socket, no inherited host environment, and
`COMPOSE_DISABLE_ENV_FILE=1`. This avoids reading an ambient context, credentials, Keychain data,
or a default `.env` just because someone opened a source document. Explicit service `env_file` and
`file:` secret paths remain Compose source references and are named in the operation review; their
contents are not inspected or copied by Morbstack. An `environment:` secret requires a host
variable, so it is unavailable to that deliberately isolated operation. A project that needs
unattended source-driven execution must use an explicit reviewed `file:` or `external:` secret
source instead.

This does not claim that the source is safe. Compose sources and their explicit includes, configs,
secrets, build contexts, and providers remain trusted input. It does not alter Docker, the VM,
Keychain, a selected source file, or the container environment until the person separately saves
or confirms a project operation.

## Evidence and remaining acceptance

The inspection model has focused source tests for block-style service environment entries,
`env_file` metadata, interpolation token names, top-level secret source metadata, and service
grants. This change intentionally ran no app, Docker/VM, Compose, or test workload. Real-window
light/dark/narrow, keyboard and VoiceOver, explicit `.env` reveal/hide, document save conflict,
source-operation review, and real Compose acceptance remain required under the visual-acceptance
playbook.
