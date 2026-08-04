# Stacks project-log scope

**Status:** audited 2026-08-03. No project-log transcript or project-log export is
currently implemented.

## Decision

Do not add **Save Visible Project Log…** to Stacks. The Stacks browser has no loaded
Compose-project transcript to freeze. It discovers a project only by grouping Docker
container summaries that share `com.docker.compose.project`; that label is membership
metadata, not a completed `docker compose logs` result or a log query.

Each service's existing **View Logs** action deliberately opens that one selected
container in Containers. There, the separate container-log document requests Docker's
latest 1,000 lines for that exact container, may follow new output, retains a bounded
10,000-line client scrollback, and labels its own visible-search, stream, tail/follow,
and retention scope when it is saved. A container transcript cannot truthfully be
renamed, copied, or exported as the project transcript: it says nothing about the
other service containers or replicas that happen to share the project label.

The source-editor's Compose validation and reviewed Compose-operation sheets also do
not provide a project log. They contain bounded, redacted diagnostics from one explicit
source-driven command and state that their output remains in that sheet; neither is
container runtime output.

Docker documents `docker compose logs` as a separate command that displays service
container output. Its `--tail`, `--follow`, `--timestamps`, `--since`, `--until`, and
service/index options define the meaning of a project-level result. Morbstack's Stacks
browser does not invoke that command or retain its output, so it must not imply that a
selected project has a current, complete, filtered, followed, or exportable aggregate.

## Native macOS behavior

The retained service-level **View Logs** handoff is the native, selected-record action:
it opens the existing long-text container-log document rather than adding a competing
log panel, card, toolbar replica, or empty project-log export command to the Stacks
inspector. The existing container transcript owns any `NSSavePanel` export because it
is the only loaded log document. No Stacks visual change or new control is required for
this decision.

## Requirements before a project-log export can exist

A future project-log feature must be an explicit Compose-log query with a recorded
source contract. Before enabling a save action it needs, at minimum:

- the exact selected project and source/configuration authority used for the query;
- the selected services and replica indices, including how containers that appear or
  disappear during follow are handled;
- each `docker compose logs` option (`--tail`, `--follow`, timestamps, time bounds,
  color/prefix treatment, and selected service/index) plus any separate client-side
  text filter, and whether any of them changed after the text was loaded;
- a bounded aggregate-retention policy that reports dropped output and never equates a
  current client snapshot with all project, Docker, or CI history; and
- a frozen, already-loaded document whose preamble discloses those facts before a
  standard `NSSavePanel` atomically writes it. Saving must not issue another log query.

Consulted: Apple’s [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/),
[file management](https://developer.apple.com/design/human-interface-guidelines/file-management),
[toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and
[`NSSavePanel`](https://developer.apple.com/documentation/appkit/nssavepanel), plus
Docker’s [`docker compose logs`](https://docs.docker.com/reference/cli/docker/compose/logs/)
reference. The source audit did not run a Compose command, open the app, or create a
new visual-acceptance result. Any future project-log implementation requires the
serialized fixture-window/XCUITest/Computer Use acceptance path.
