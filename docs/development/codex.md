# Codex workflow

This repository keeps its Codex setup deliberately small and reviewable. The root
[`AGENTS.md`](../../AGENTS.md) is the working agreement, and the project config only sets
the local subagent concurrency limit. Personal model preferences, permissions, credentials,
and connected accounts stay in the user's Codex configuration.

## Source of truth

For visible macOS work, read these documents in order:

1. [Native macOS design documentation](../design/README.md)
2. [Native macOS playbook](../design/NATIVE-MACOS-PLAYBOOK.md)
3. [HIG coverage audit](../design/HIG-COVERAGE-AUDIT.md)

The playbook identifies the evidence standard; the coverage audit maps user tasks to Apple
HIG and framework sources. Treat those documents as the route-level decision record rather
than creating a second visual-system guide.

Two repository skills make that workflow easy to invoke from Codex:

- `$morbstack-native-macos` maps a SwiftUI/AppKit change to its Apple semantics and native
  system pattern.
- `$morbstack-visual-acceptance` runs the evidence sequence for a visible route or window
  frame change.

Codex discovers checked-in skills from `.agents/skills`. Start a new Codex session after
adding or materially changing a skill if it is not listed yet.

## Delivery loop

1. State the person's task and the interaction semantics before choosing a view.
2. Read the relevant Apple HIG/API and select the system container, control, menu, or
   accessibility behavior it provides.
3. Keep data, error, and lifecycle behavior accurate for the daemon; make fixture-only
   behavior explicit in the fixture launch path.
4. Perform focused static and unit checks while editing.
5. Assign one integration owner to serialize heavyweight builds, package assembly, test
   suites, and app launches once source work has settled.
6. Record the HIG/API choices, safe interaction results, and evidence with the affected
   route.

The regular commands are:

```sh
mise trust && mise install       # first checkout only
mise run build-mac               # Swift host binaries
mise run test                    # Swift and Rust suites
git diff --check                 # every handoff
```

Use the smallest command that proves the change. `mise run app` assembles and signs an
application bundle, while `mise run run-daemon` starts a long-running development daemon;
assign both to the integration lane when several agents are active.

## Native-window evidence

The app frame is composed by macOS, so validation uses complementary layers:

| Layer | Purpose | Command or surface |
| --- | --- | --- |
| Deterministic fixture invariants | Verify fixture relationships and route data without visual claims | `cd mac && swift run MorbShots` |
| Fixture route liveness | Exercise real light and dark windows without starting a VM | `mise run shots-live` |
| XCUITest | Drive accessibility identifiers, keyboard/focus behavior, and attach screenshots from the real bundled app | `mise run app`, then `mkdir -p dist/xcui && XCODE_DERIVED_DATA="$(mktemp -d -t morbstack-xcui)"; MORBSTACK_APP_PATH="$PWD/dist/Morbstack.app" xcodebuild -project mac/UITests/MorbstackUITests.xcodeproj -scheme MorbstackUITests -derivedDataPath "$XCODE_DERIVED_DATA" -destination 'platform=macOS' -resultBundlePath "$PWD/dist/xcui/MorbstackUITests.xcresult" test` |
| Computer Use | Review the WindowServer-composited full window and UX in context | Launch `dist/Morbstack.app` or the fixture app and use Computer Use |

The XCUITest harness is documented beside its sources in
[`mac/UITests/README.md`](../../mac/UITests/README.md). Use `--tour-fixtures` for safe,
deterministic UI content. For final acceptance, inspect light and dark appearances at normal
and narrow widths; cover sidebar, toolbar, table or outline selection, inspector, search,
keyboard focus, menus, unavailable states, and safe confirmation paths. Computer Use is the
authoritative full-window UX review because it sees the actual titlebar, traffic lights,
toolbar, sidebars, materials, and transitions.

On a new Mac, macOS must authorize Xcode Helper under **Privacy & Security > Accessibility**
before an XCUITest can enable automation. If macOS asks for administrator authentication, let
the person complete it; do not replace the blocked test with an offscreen image. This local
permission is documented in the harness README and is intentionally not stored in repository
configuration.

## Subagent roles

Delegate independent, bounded work by responsibility:

- a route owner maps HIG semantics and implements one resource workflow;
- a functionality owner traces a daemon/API behavior and its tests;
- an evidence owner owns the serialized build, XCUITest, and Computer Use pass;
- the primary agent integrates cross-cutting changes and keeps the decision record current.

This keeps expensive commands serialized while allowing research, source review, focused
tests, and independent route work to progress in parallel. The project cap permits three
subagents alongside the primary agent.

## Optional integrations

Use an integration when it supplies live context that the repository cannot provide. Keep
authentication and account authorization in user-level Codex settings; this repository stores
no secrets or account configuration.

- Official OpenAI developer documentation can be enabled with:

  ```sh
  codex mcp add openaiDeveloperDocs --url https://developers.openai.com/mcp
  ```

  Restart Codex after adding it. Use it for current Codex configuration and OpenAI API
  guidance.
- Enable the Computer Use plugin in the Codex desktop app and grant its macOS Screen
  Recording and Accessibility permissions before a real-window review. Limit app access to
  the Morbstack process for that review.
- Add GitHub, issue tracker, or design connectors only when a task needs that live system;
  each connector's account authorization remains user-managed.

See the [Codex manual](https://developers.openai.com/codex/codex-manual.md) for current
configuration, skills, MCP, and Computer Use behavior.
