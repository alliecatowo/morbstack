# Native macOS design documentation

**Status:** binding documentation index for the Tahoe/Liquid Glass migration.

Morbstack's product UI is a native macOS operations application. The operating system
owns the window frame, titlebar, toolbar, sidebar, inspector, selection, focus,
materials, default spacing, and control treatment. Product code owns truthful Docker and
engine data, task-specific labels, and safe actions. It does not own a second visual
system.

## Read these in this order

1. [Native macOS playbook](NATIVE-MACOS-PLAYBOOK.md) — the implementation standard and
   acceptance bar.
2. [HIG coverage audit](HIG-COVERAGE-AUDIT.md) — the required semantic decision matrix,
   route inventory, and evidence gate.
3. [Table semantics audit](TABLE-SEMANTICS-AUDIT.md) — the current task-shaped decision
   for every `Table`/`TableColumn` use in the app.
4. [Inspector pattern decision](INSPECTOR-PATTERN-DECISION.md) — the selected-record
   inspector, form, tab, source-editor, and long-text decision record.
5. [Tahoe HIG findings](tahoe/HIG-FINDINGS.md) — supporting research notes. When a note
   and an Apple source conflict, Apple wins.
6. [SDK Liquid Glass reference](SDK-LIQUID-GLASS.md) — an API/availability field note;
   validate a declaration against the SDK and current Apple documentation before use.

## Decision records

Narrower rulings, each binding on its own subject. They resolve one question and stop.

| Record | Decides |
| --- | --- |
| [DECISIONS.md](DECISIONS.md) | the standing native-macOS rulings, binding wherever they resolve an ambiguity in the two documents above |
| [INSPECTOR-PATTERN-DECISION.md](INSPECTOR-PATTERN-DECISION.md) | what an inspector is, and that it is not a second dashboard |
| [STACKS-PROJECT-LOG-DECISION.md](STACKS-PROJECT-LOG-DECISION.md) | not to add a project-log export to Stacks, and why |
| [ZERO-CONFIG-DISCOVERY.md](ZERO-CONFIG-DISCOVERY.md) | how a machine with no Docker at all finds Morbstack — ECO-1/ECO-2, proven live |
| [PATCH-FREE-PUBLISH-ALL.md](PATCH-FREE-PUBLISH-ALL.md) | that Morbstack ships **stock upstream `dockerd`** and serves `-P` through its own `--userland-proxy-path` hook (TECH-1) |
| [DNS-DECISION.md](DNS-DECISION.md) | the mechanism for container domains on macOS (SP-2). A mechanism only — no code, no licence to ship |
| [INERT-SUBSYSTEMS-DECISION.md](INERT-SUBSYSTEMS-DECISION.md) | the fate of each subsystem that existed but never ran (SP-5 / MOD-1) |
| [ENGINE-BUILD-DECISION.md](ENGINE-BUILD-DECISION.md) | **superseded** by PATCH-FREE-PUBLISH-ALL. Kept for its reasoning; there is no patched engine to build |

The following documents are preserved as **archived historical records**, not current
implementation instructions: `COMPONENTS.md`, `CRITIQUE.md`, the non-current portions of
`IDENTITY.md`, `REWRITE-PLAN.md`, and all of `pass2/`. They describe the earlier
Theme/`Design/**`/`Morb*` visual-system proposal and its diagnostic renders. The visual
system has been retired; it must not be restored through a compatibility wrapper, a
different token library, or one-off custom drawing. Their observations can explain a
past decision, but never override the two binding documents above.

## Required implementation review

Before changing any visible route, complete this checklist in the route handoff or the
HIG coverage audit.

- State the user task and each interaction in semantic terms: navigation, record
  selection, hierarchy, editing, search, command, confirmation, progress, chart, or
  unavailable state.
- Read the matching Apple HIG page and SwiftUI/AppKit API documentation. Choose the
  system component before writing layout code.
- Prefer direct `NavigationSplitView`, `Table`, `Form`, `LabeledContent`, `.inspector`,
  `.searchable`, `Menu`, `ContentUnavailableView`, `ProgressView`, `Chart`, and standard
  commands/shortcuts as appropriate. Record why an AppKit bridge is necessary before
  introducing one.
- Reject custom content backgrounds, materials, cards, pills/chips, hover states,
  toolbar replicas, selection styling, or brand-colored control surfaces. Liquid Glass
  is supplied by the system chrome; it is never a dense-content background.
- Verify the real WindowServer-composited app in light and dark appearance, normal and
  narrow widths, keyboard/focus navigation, table sort/selection/context menu,
  sidebar/inspector behavior, accessibility labels/help, reduced transparency/contrast
  and motion, and safe destructive confirmation. An offscreen SwiftUI/AppKit image
  cannot approve native window chrome.

## Primary Apple sources

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Windows](https://developer.apple.com/design/human-interface-guidelines/windows), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), and [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Forms](https://developer.apple.com/documentation/swiftui/form), [Tables](https://developer.apple.com/documentation/swiftui/table), [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), and [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Color](https://developer.apple.com/design/human-interface-guidelines/color), and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
