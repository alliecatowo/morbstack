---
name: morbstack-native-macos
description: Implement or review Morbstack's SwiftUI/AppKit interface using Apple-native macOS and Liquid Glass semantics. Use for any change to app windows, navigation, sidebars, tables, outlines, inspectors, forms, toolbars, menus, search, empty states, charts, settings, or visible interaction behavior in `mac/Sources/MorbstackAppCore`.
---

# Morbstack native macOS

Work from the user task to the Apple interaction pattern, then use the system component that
already supplies its behavior, accessibility, appearance, and platform adaptation.

## Decision workflow

1. Read `docs/design/README.md`, then the relevant row in
   `docs/design/HIG-COVERAGE-AUDIT.md`. Read the linked Apple HIG/API before changing the
   route.
2. State the user task and identify its semantics: top-level navigation, hierarchy,
   collection selection, record detail, command, search, input, progress, confirmation,
   unavailable state, or data-over-time question.
3. Select the native pattern that owns that semantic. The normal choices are:
   - `NavigationSplitView` with sidebar `List` for app navigation;
   - `Table` for operational records and an outline representation for genuine hierarchy;
   - `.inspector` with `Form` and `LabeledContent` for selected-record metadata;
   - toolbar `ToolbarItem`s, `Menu`, commands, keyboard shortcuts, and context menus for
     actions;
   - `.searchable`, native selection/focus, and `ContentUnavailableView` for collection
     discovery and empty/search states;
   - `Form` with standard controls for settings and scoped input;
   - `ProgressView` for real work and Swift Charts only when data supports a temporal or
     comparative question.
4. Bind the view to truthful daemon/Docker data and give every state a useful, safe next
   action. Keep destructive work in a clear confirmation flow.
5. Use the system window and content surfaces. Let navigation and controls receive Tahoe's
   system treatment; use a custom Liquid Glass effect only for a control absent from the
   platform vocabulary and record that exception in the HIG audit.
6. Verify keyboard, focus, accessible names/help, light and dark appearances, narrow-window
   toolbar behavior, and the route's real data/fixture behavior. Hand off the HIG sources,
   semantic choice, exception (if any), and evidence.

## Route handoff

Record the user task, Apple sources consulted, native choice, data/action behavior,
accessibility checks, and visual-validation result in the route handoff or HIG coverage audit.
Use `$morbstack-visual-acceptance` for the evidence pass after the implementation settles.
