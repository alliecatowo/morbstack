# Morbstack

Morbstack is a native macOS Docker operations app: Swift/AppKit and SwiftUI in `mac/`, a
Rust guest init in `guest/morbinit/`, and build tasks in `mise.toml`.

## Start here

- Read [CLAUDE.md](CLAUDE.md) **first**, whatever agent you are. It is the
  operational source of truth: the codesign/entitlement rule, the `~/.docker`
  credential-helper hang, the 104-byte socket path limit, daemon lifecycle
  discipline, and which build lane is safe to hold. This file stays the
  design/workflow agreement; the split is deliberate — "what should the UI be"
  here, "how do I run it without breaking the machine" there.
- Read [docs/design/README.md](docs/design/README.md) for every visible app change. Its
  playbook and HIG coverage audit are the binding design and evidence standards.
- Keep app behavior truthful to the daemon and Docker API. Place pure logic in testable
  models; use deterministic fixtures only for explicitly fixture-backed validation.
- Use `mise.toml` as the source of truth for build tasks. `docs/build.md` explains their
  prerequisites and effects.

## Native macOS work

Begin each UI task with the user task and its platform semantics: navigation, hierarchy,
record selection, search, command, editing, progress, confirmation, or unavailable state.
Read the matching Apple HIG and framework documentation, then implement with the system
container or control. The normal app vocabulary is `NavigationSplitView`, `Table`,
`Form`, `LabeledContent`, `.inspector`, `.searchable`, `Menu`, `ContentUnavailableView`,
and Swift Charts when time-series data answers a real question.

Use `$morbstack-native-macos` for a route-level implementation or review, and
`$morbstack-visual-acceptance` for real-window validation.

## Verification and collaboration

- Keep a changed route's semantic choice, Apple sources, behavior checks, and visual
  evidence together in its handoff or the HIG coverage audit.
- Run focused checks first, then let one evidence owner serialize expensive Swift builds,
  test runs, bundle assembly, and app launches. Other agents can inspect code, add focused
  tests, and run static checks in parallel.
- Validate native-window changes with the fixture app, XCUITest accessibility/screenshot
  evidence, and a Computer Use review of the actual full window. Follow
  [docs/development/codex.md](docs/development/codex.md) for the current commands.
- Give every subagent a bounded file or behavior scope and return a concise evidence-based
  handoff. The integrating agent owns cross-cutting changes and the serialized validation
  lane.

Before handoff, run `git diff --check` and the smallest relevant verification command.
