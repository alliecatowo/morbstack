# Inspector pattern decision

**Status:** binding route-level decision record. 2026-08-03.

## Decision

An inspector is a contextual trailing column for the selected record. It is not a
second dashboard or an independently navigable workspace. Morbstack uses SwiftUI's
system `.inspector` and `inspectorColumnWidth(min:ideal:max:)`; it does not imitate an
inspector with an `HStack`, overlay, hand-drawn panel, custom material, or geometry
animation. The system owns presentation, resizing, persistence, focus, and compact
adaptation.

The native content boundary is deliberate:

| Need | Native container | Not appropriate |
| --- | --- | --- |
| Selected record's compact facts and safe commands | `Form`, `Section`, `LabeledContent`, standard `Button`/`Menu` | Cards, custom property grids, embedded dashboard widgets |
| A bounded collection of facts with no independent selection | `ForEach` in a `Form` section | A `List` that suggests a second selection model |
| Peer records that can be selected or navigated independently | `List` or `Table` in the primary content area | An inspector-only pseudo-list |
| Long read-only logs, raw inspect JSON, or diagnostics | Selectable monospaced `Text` in a `ScrollView` | A `Form`, a cramped card, or an editable `TextEditor` |
| Explicit, user-initiated editing of Compose/YAML or `.env` text | `TextEditor` in a dedicated editor sheet/window | An inspector field that silently edits runtime state |
| Alternative representations of the *same selected record* | Labelled `TabView` tabs, only when each tab is a peer destination | Tabs used as commands, filter chips, or a substitute for hierarchy |

This follows the platform model: [SwiftUI inspectors](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)) provide a contextual column; [forms](https://developer.apple.com/documentation/swiftui/form) group related controls and data with macOS-native alignment; [tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) are navigation, not actions; [TextEditor](https://developer.apple.com/documentation/swiftui/texteditor) is for editable long-form text; and [Text input and output](https://developer.apple.com/documentation/swiftui/text-input-and-output) distinguishes read-only `Text` from entry controls.

## Layout and type rules

- Let `Form` use `.automatic` by default. Use `.columns` only for a route where its
  labels and values remain legible at the inspector's minimum width; it is not a global
  style.
- Preserve the current, route-specific system inspector ranges until real-window
  evidence disproves them: Containers `340…520` (ideal `400`), Images `340…460` (ideal
  `400`), and Stacks `340…520` (ideal `400`). These are usability hypotheses, not a
  visual grid; users may resize the column.
- Most values use normal system text. Apply monospaced text only to values whose shape
  matters: IDs, digests, paths, commands, port mappings, and raw logs/JSON. Those
  values must remain selectable, have an appropriate line limit/truncation strategy,
  and provide copy or disclosure when the full value matters. Do not make every form
  value monospaced merely because the app operates Docker.
- Do not force a long value into a narrow form label/value row. Use middle truncation
  for identifiers and paths where prefix and suffix distinguish the value; use a
  dedicated scrollable representation for multi-line diagnostic content.
- A tab may show a representation, not trigger an operation. Keep visible text labels
  and the default system tab treatment. If tabs do not remain clear at the minimum
  width, move the secondary representation to an intentional sheet or detail route;
  do not solve it with custom segmented controls or smaller type.
- The right column follows [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/): comfortable density, user-resizable
  information, familiar keyboard behavior, and system materials/chrome. No custom
  content background or glass panel is permitted to make a crowded form appear styled.

## Route assessment

### Containers

Keep the selected-container inspector as a system inspector at `340/400/520`. The
Overview is a `Form` with factual sections. Logs and Inspect are intentionally separate
long-text representations inside the selected-record `TabView`; they use selectable,
scrollable monospaced text rather than a form. Stats earns a tab only when it presents a
truthful, useful native chart or an unavailable state—never a decorative mini-dashboard.

Environment entries need a safety boundary. Runtime values are not automatically safe
to expose because names and values can contain credentials. Keep values masked by
default; reveal is per row and explicit. Treat copy of a masked/sensitive value as a
confirmation point: a follow-up implementation must require explicit reveal or an
equivalent clearly-labelled acknowledgement before copying that value. A secret-looking
key uses an icon and descriptive accessibility help, but iconography must not be the
only cue.

### Images

Keep the selected-image inspector as a compact `Form` at `340/400/460`. Repository,
digest, architecture, tags, archive/run/remove actions, and other selected-image facts
belong together without tabs. Long digests and tag collections must be validated in the
real inspector at its minimum width. If they are unreadable, change the relevant
system-container presentation or disclose a full selectable value; do not introduce
summary cards or a second visual system.

### Stacks

Keep project and service facts in the system inspector at `340/400/520`. A column form
is acceptable only while it passes the minimum-width evidence gate. Project actions
remain a standard `Menu`; ports, paths, and source metadata are factual values with
selection and middle truncation as needed. Compose/YAML and `.env` editing is an
explicit source-editor task and remains in its `TextEditor` editor surface, not in the
selected-record inspector.

## Required acceptance evidence for an inspector change

For every affected route, record the matching Apple source, chosen semantic container,
and all of the following evidence in the HIG coverage audit or handoff:

1. A real app-window Computer Use review in light and dark appearance, including the
   inspector at its minimum, ideal, and user-expanded widths. Confirm the window
   toolbar, sidebar, inspector toggles, and resizable system chrome remain intact.
2. XCUITest/accessibility evidence that selection opens the contextual inspector,
   visible controls have useful labels/help, form order is sensible by keyboard, and
   tabs are reachable and named as destinations.
3. Long identifier/path/tag cases proving labels and values neither overlap nor clip
   misleadingly, and proving that full machine values can be selected or copied.
4. A long logs/JSON case proving it scrolls and selects independently of factual form
   content; a Compose/YAML edit case proving editing is clearly explicit and has its
   own save/cancel semantics.
5. An environment/secret case proving values are not exposed by default, reveal is
   explicit, sensitive copying is deliberate, and accessibility text communicates the
   state without relying on the icon.
6. Verification of reduced transparency, increased contrast, keyboard-only navigation,
   and destructive-action confirmation, following the
   [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility).

## Implementation guardrail

Before changing an inspector, read the matching Apple HIG/API documentation and this
record, then write a route-specific semantic decision. A visual complaint is not a
license to add custom panels, pills, cards, colors, or a design-system wrapper. First
determine whether the content is a selected fact, peer record, long read-only document,
or explicit editor; then use the corresponding system container above.
