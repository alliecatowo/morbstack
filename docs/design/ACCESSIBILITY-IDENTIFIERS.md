# Accessibility identifiers — the automation naming convention

**Status:** binding for `mac/Sources/MorbstackAppCore/**` and `mac/UITests/**` (SP-8).
This document is the contract between the app and its XCUITest suite. It was written
while the codebase had **zero** `accessibilityIdentifier` sites, so the convention below
is the convention — there is no legacy scheme to migrate from and none may be invented
alongside it.

## 1. What an identifier is, and what it is not

`accessibilityIdentifier` is a **stable automation handle**: an invisible, unlocalized
string a test uses to address one element. It is not user-facing. It is never spoken by
VoiceOver, never displayed, and never localized.

`accessibilityLabel` is the opposite in every respect: it is **what VoiceOver speaks**,
it is user-facing product vocabulary, and it must be localizable. The repo has ~145
label sites and they stay exactly as they are.

The classic error is conflating the two. The rules that prevent it:

- An identifier must **never** be used as a label, and a label must never be derived
  from an identifier. A symbol-only button keeps its `.accessibilityLabel` regardless of
  whether it also has an identifier.
- Adding an identifier changes nothing about what assistive technology perceives.
  If an element reads badly in VoiceOver, the fix is its label, not its identifier.
- Tests use the identifier to **find** an element and the label/title/value to **assert
  what the user experiences**. `app.buttons["containers.options"]` locates the control;
  asserting its `label` is how a test proves the user-facing semantics are right.
  A test that only ever touches identifiers verifies nothing about the product's
  accessibility, which is why `testFixtureAccessibilityAudit` and the semantic
  assertions in the fixture suite remain label-driven.

## 2. Naming shape: route-scoped, dotted, lowerCamelCase segments

```
<scope>.<element>[.<qualifier>]
```

- **`<scope>`** is the sidebar route key — the `Nav` raw value: `containers`, `stacks`,
  `images`, `volumes`, `networks`, `builds`, `kubernetes`, `disk`, `migration` — or
  `app` for cross-route chrome (sidebar, fixture banner, command palette, settings,
  first-run setup).
- **`<element>`** names the control or surface: `pull`, `options`, `list`, `execSheet`.
  Segments are lowerCamelCase ASCII; the separator is `.`.
- **`<qualifier>`** narrows within a compound surface: `images.pullSheet.reference`,
  `containers.execSheet.run`. Depth is whatever disambiguates and no more; two or three
  segments cover almost everything.

**Why route-scoped and not flat-global:** XCUITest identifier queries are exact-match
string lookups against the whole application tree. The app has nine structurally
similar sidebar routes; Networks and Volumes both carry a trash-can "remove unused"
toolbar button, Images a third. A flat `removeUnused` forces every one of those routes
to fight over one name or invent ad-hoc suffixes; `networks.removeUnused` and
`volumes.removeUnused` both say exactly which remove they are, cost nothing at query
time, and make a bare grep of either string land on one call site. Two routes may
legitimately both have a "remove" that means different things — the scope segment is
what keeps that from ever being a collision.

**Why not type-prefixed** (`button.removeUnused`, `btnRemove`): the element type is
already the query axis in XCUITest (`app.buttons[…]`, `app.textFields[…]`); repeating
it in the string is noise, and it goes stale the moment a Menu becomes a Button.

**The toolbar rule:** the repo already names every toolbar control with a route-scoped
`ToolbarItem(id:)` customization ID (`containers.options`, `images.pull`,
`volumes.removeUnused`, …). A toolbar control's accessibility identifier is **that same
string, verbatim**. One control, one name, two systems reading it. Do not invent a
parallel `containers.toolbar.options` spelling — a second name for the same control is
exactly the drift this document exists to prevent. When a `ToolbarItem` hosts a control
whose identity changes with state (`containers.primaryLifecycle` is start/stop/unpause
depending on the selection), the identifier stays constant and the **label** carries
the state — that is the split from §1 working as intended.

**Dynamic collections:** a row identifier is the scope plus `row` plus the record's
**engine-facing reference** — the value a `docker` CLI command would accept to address
the record: `containers.row.shopfront-api-1` (the unique container name),
`volumes.row.shopfront_pgdata`, `networks.row.morb-ingress`,
`images.row.postgres:16.3`. Docker enforces uniqueness of these per daemon, so they are
identity, not presentation. Never a formatted display string, never a truncated digest
a test cannot reproduce, and never the array index, which reorders. Everything before
the final dynamic segment must be a compile-time literal.

## 3. What gets an identifier, and what does not

An identifier goes on what a test needs to **act on** or **assert about**; nothing else.

**Gets one:**

- Controls a test operates: toolbar buttons and menus (= their `ToolbarItem` id),
  sheet/confirmation buttons, form fields in sheets, rows in lists and tables,
  segmented scopes, the buttons inside empty-state views.
- State a test asserts: status/count text that summarizes a route, empty-state
  containers (`containers.empty.noContainers`), progress/busy indicators that gate a
  test's next step, the fixture provenance banner (`app.fixtureBanner`).
- Anything **symbol-only or duplicated**. This is mandatory, not optional: a toolbar of
  SF-Symbol buttons where two routes show identical trash cans is the case that makes
  identifiers load-bearing. If two elements with the same visible text or glyph can
  coexist on screen and mean different things, both carry identifiers.

**Does not get one:**

- Ordinary `Text` content, captions, help text, section headers, decorative images.
  An identifier on every `Text` is noise that rots the moment copy changes.
- Layout containers (`HStack`, `Form`, `Section`) — identify the semantic element, not
  the scaffolding around it.
- **System-owned chrome the app does not draw:** menu-bar items from
  `SidebarCommands()`/`InspectorCommands()`, the `.searchable` toolbar field, window
  controls, save panels, the standard Cancel of a `confirmationDialog`. Tests address
  these by their system semantics (`app.menuItems["Hide Sidebar"]`,
  `app.searchFields.firstMatch`), which is a **feature**: it proves the app kept the
  system behavior. Per `DECISIONS.md` §1, if the system draws it, the system names it —
  and an identifier is never an excuse to replace a system control with a custom one
  that is easier to tag.
- Unique, stably-titled controls that a semantic query already finds unambiguously
  *may* skip an identifier; add one the moment the title is dynamic, duplicated, or a
  test needs it while it is off-screen in toolbar overflow.

## 4. Stability contract

Identifiers are an API. The consumers are the XCUITest suite and any future automation.

- **May not change them:** copy edits, localization, visual redesign, symbol swaps,
  moving a control between toolbar placements, refactoring a view into subviews. If the
  control still means the same thing, it keeps its name.
- **May change them:** a change to what the control *does or means* — at which point the
  old name is wrong and keeping it would be the lie. Renaming an identifier and updating
  every test that queries it is **one change**; a PR that renames an identifier without
  touching `mac/UITests/**` is either incomplete or renaming something it shouldn't.
- Identifiers are never derived from localized or user-visible strings, never
  concatenated from display text, and never reused for a different element after
  removal.
- New interactive surfaces land **with** their identifiers; that is part of the
  definition of done for UI work, the same way the `ToolbarItem(id:)` already is.

## 5. Relationship to the existing XCUITest suite

`mac/UITests/MorbstackFixtureUITests/` predates identifiers and queries by system
semantics alone — visible titles, labels, and element types. The convention does not
overturn that; it splits it:

- Queries that **assert user-facing semantics** stay semantic. "The View menu exposes
  Hide Sidebar", "an unmatched search shows `No Results`", "the remove confirmation
  says what is kept" — these are the product contract and must keep failing if a label
  regresses. Rewriting them to identifiers would make the suite blind to exactly the
  regressions it exists to catch.
- Queries that merely **address** an element before acting on or inspecting it move to
  identifiers: selecting a specific fixture row instead of the first `staticText` that
  happens to contain the name, disambiguating the two inspector toggles, finding a
  sheet's primary button without `firstMatch`. `firstMatch` against a generic type is
  the smell the identifier replaces.
- The accessibility audit (`performAccessibilityAudit`) is unaffected by identifiers by
  design — identifiers are invisible to it. It gets *more* precise only through labels,
  which is the correct pressure.

Fixture tests may hard-code fixture references in row identifiers
(`containers.row.shopfront-api-1`) because `ShotFixtures` is deterministic;
live-engine automation must derive references from the engine, not hard-code them.
