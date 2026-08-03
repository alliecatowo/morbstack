---
name: morbstack-visual-acceptance
description: Validate a Morbstack macOS UI change in the real app window with deterministic fixtures, XCUITest accessibility/screenshot evidence, and Computer Use. Use after changes to SwiftUI/AppKit window chrome, navigation, tables, inspectors, forms, toolbars, menus, search, settings, or visual interaction behavior.
---

# Morbstack visual acceptance

Use this after source work has settled. It validates semantics and UX through the actual macOS
window instead of treating an offscreen view image as a full-window result.

## Evidence sequence

1. Run `git diff --check` and the smallest focused test for the changed behavior.
2. Verify deterministic fixture relationships with `cd mac && swift run MorbShots`. Treat the
   result as fixture/invariant evidence.
3. Use `mise run shots-live` to prove fixture-route liveness in real light and dark windows.
4. Assign one evidence owner to assemble the app and run the macOS UI test host:

   ```sh
   mise run app
   mkdir -p dist/xcui
   MORBSTACK_APP_PATH="$PWD/dist/Morbstack.app" xcodebuild \
     -project mac/UITests/MorbstackUITests.xcodeproj \
     -scheme MorbstackUITests \
     -destination 'platform=macOS' \
     -resultBundlePath "$PWD/dist/xcui/MorbstackUITests.xcresult" test
   ```

   Review the attached XCUITest screenshots and semantic assertions. The harness launches the
   bundled app using `--tour-fixtures`; its source-level guide is `mac/UITests/README.md`.
5. Launch the fixture app for a Computer Use review. Inspect the full WindowServer-composited
   frame in light and dark appearances at 1440x900 and a narrow supported size. Exercise safe
   sidebar collapse/reveal, toolbar overflow, table/outline sort and selection, inspector,
   search and unavailable states, keyboard focus, menus, and confirmation presentation.
6. Record command results, dimensions/appearances, route interactions, HIG exceptions, and any
   issue found. Fix issues and repeat the affected layers before acceptance.

## Review focus

Confirm that the real window has a unified system frame, the sidebar and inspector retain
native transitions, resource rows behave as selectable/sortable macOS data, and actions have
clear labels, keyboard/focus behavior, and truthful safe outcomes. Use the HIG coverage audit
as the route checklist; Computer Use supplies the final visual and interaction judgment.
