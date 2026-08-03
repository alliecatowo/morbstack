# Compose source validation boundary

**Status:** source implementation only. It has no real-file, bundled-client, or
real-window acceptance evidence yet.

## User task and native presentation

A person who has opened one Compose YAML document may ask whether that saved source
passes Docker Compose's configuration checks without deploying it. This is a command
with a separate trust review, not a project browser, YAML form builder, deployment
flow, or environment preview.

The Stacks editor supplies the normal macOS document workflow: an explicit Open-panel
selection, a source-fidelity `TextEditor`, explicit Save/Revert/Close, and a dirty
discard confirmation. The symbol-only toolbar command and standard **Compose** menu
item are available only for the saved, person-selected `.yaml`/`.yml` document. A
document-modal sheet presents the separate review in an automatic system `Form` and
starts nothing until the person selects **Validate**. While work is active, an
indeterminate system `ProgressView` represents the actual unquantified process and a
native, noneditable AppKit `NSTextView` streams selectable monospaced diagnostic text.
It is not custom terminal chrome, a dashboard card, or a fake validation result.

Sources consulted: Apple's [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[Forms](https://developer.apple.com/documentation/swiftui/form),
[Text input and output](https://developer.apple.com/documentation/swiftui/text-input-and-output),
and [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators).
The Stacks outline uses the system `Table(children:)` with
[`BorderedTableStyle`](https://developer.apple.com/documentation/swiftui/borderedtablestyle)
as a narrow native hypothesis for Tahoe's repeated inset empty-row bands. It adds no
custom table or selection styling and remains pending a current-bundle Computer Use
review.

## Exact execution contract

Docker documents [`docker compose config`](https://docs.docker.com/reference/cli/docker/compose/config/)
as parsing, resolving, and rendering the model; `--quiet` validates only and does not
print the model. The bundled Compose executable is invoked directly, with the same
Compose `config --quiet` semantics, rather than putting an extra Docker-CLI parent
between Morbstack and the process it needs to cancel:

```text
<bundled docker-compose> --project-directory <selected parent> -f <selected source> \
  config --quiet --no-interpolate --no-env-resolution --no-path-resolution
```

It begins only after the separate review is accepted. Before launch, the app
revalidates that the selected URL is still a regular, non-symlink YAML file and that
its coordinated on-disk bytes exactly equal the document snapshot the person reviewed.
It will not write an unsaved buffer to a temporary file or validate a changed/replaced
source by surprise.

The child receives an empty, temporary `HOME` and `DOCKER_CONFIG`, a direct
`DOCKER_HOST=unix://…` pointing to Morbstack's socket, and a narrow environment
whitelist. In particular it sets `COMPOSE_DISABLE_ENV_FILE=1`,
`COMPOSE_ANSI=never`, `COMPOSE_PROGRESS=plain`, and `COMPOSE_MENU=0`; it does not
inherit the user's Docker context/configuration, credential helpers, Keychain access,
shell variables, `COMPOSE_ENV_FILES`, proxy variables, Git configuration, Git prompt,
or SSH agent. Docker documents that `COMPOSE_DISABLE_ENV_FILE=1` disables the default
project `.env` file, while `--no-interpolate`, `--no-env-resolution`, and
`--no-path-resolution` respectively suppress interpolation, service env-file
resolution, and path resolution. See Docker's [predefined Compose variables](https://docs.docker.com/compose/how-tos/environment-variables/envvars/)
and [`config` options](https://docs.docker.com/reference/cli/docker/compose/config/).

The operation does not invoke `up`, `create`, `deploy`, `build`, `pull`,
`--resolve-image-digests`, or any lifecycle action. Docker's trust-model documentation
states that providers run on `up`, `down`, or `stop`, not this `config` command.

## Trust and result boundaries

Compose treats a Compose file as trusted input. Its [trust model](https://docs.docker.com/compose/trust-model/)
specifically warns that `include`, `extends`, `env_file`, `label_file`, and
`secrets`/`configs` `file:` references can load data beyond the selected source,
including remote or symlink-mediated sources. The review names this boundary and asks
the person to trust every referenced source. The app neither presents resolved model
output nor claims it has inspected the full dependency chain.

Standard output and standard error are drained continuously to avoid a malformed
document blocking on a full pipe. Only the first 256 KiB is retained and displayed;
the sheet explicitly marks truncation. The direct Compose client has a 15-second
deadline. Cancel and timeout send termination to that exact process and escalate after
two seconds only if it remains running. A result says **Cancellation Requested** rather
than claiming all externally launched helpers are stopped: Morbstack directly owns the
Compose process, not an arbitrary helper it might create while resolving an untrusted
reference. Launch, source-change, missing-bundle, nonzero-exit, cancellation, timeout,
and diagnostic-truncation outcomes remain distinct.

## Evidence still required

- Real saved and externally changed YAML source; dirty/revert and Open-panel focus.
- Valid, malformed, long-running, cancelled, timed-out, and over-256-KiB diagnostics
  against the bundled Compose client with no deployment action.
- A controlled untrusted-reference exercise that confirms the review/limitations are
  accurately worded and that no ambient Docker or user credential configuration leaks.
- Latest-bundle light/dark, narrow-width, keyboard/focus, VoiceOver, increased
  contrast/reduced-transparency, XCUITest, and Computer Use evidence for the editor,
  review, result text view, menu command, and bordered Stacks outline.
