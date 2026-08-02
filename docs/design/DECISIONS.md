# Design decisions (architect rulings)

## -1. BLOCKING FOR THE COHERENCE PASS: fix the screenshot harness before judging any screen

`Shots/ShotRenderer.swift` builds a **`.borderless`** offscreen `NSWindow` and rasterises it with
`displayIgnoringOpacity`, and `ShotWindow` does not wrap content in a `NavigationSplitView`.
Consequence, verified experimentally by UI-1: **`.toolbar { }`, `.navigationTitle`,
`.navigationSubtitle` and `.inspector(isPresented:)` render as literally nothing** — not a degraded
fallback, simply absent — because a borderless window has no titlebar/toolbar surface to composite
into.

This is severe for three reasons:
1. Adopting real toolbars is the **highest-value change in the rewrite** (see §0), and our only
   verification loop is blind to it.
2. Every rewritten screen will look *headerless* in `dist/shots`, i.e. WORSE than the shipping app,
   so the screenshots misrepresent the product to reviewers.
3. It silently pressures agents into the wrong architecture — UI-1 already declined
   `.inspector(isPresented:)` for the containers split purely because it renders blank offscreen,
   which is optimising the product for the test rig.

**Fix it first, before re-rendering or judging anything:** give `ShotRenderer` a `.titled` window
(add `.fullSizeContentView` / unified-toolbar style as needed) and wrap scene content in a real
`NavigationSplitView` so toolbar and inspector surfaces exist. Then re-render everything and judge.

**Then revisit UI-1's deviation:** with a working harness, reconsider `.inspector(isPresented:)`
for the containers list→detail split per `pass2/REWRITE-PLAN.md` item 1.2. UI-1's fallback to
`HSplitView` was a reasonable call under a broken rig and is explicitly not a criticism — but the
rig, not the product, should have been the thing that changed.

## 0. Read `pass2/` too — and fix the toolbar first

A second, independent design review is in `docs/design/pass2/`. It was written without sight of
the first pass, so where the two agree you can be confident, and `pass2/COMPONENTS.md` §4 tables
the divergences. Its findings, in priority order:

1. **There is no toolbar anywhere.** Every screen paints its own title, subtitle, search field and
   buttons *inside the content view*, so there is no titlebar and the traffic lights sit on bare
   background. This single fact is the main reason the app reads as Electron, and it causes a large
   share of the other findings. Adopt real `.toolbar` / `.toolbar(id:)` with `ToolbarSpacer`; on
   macOS 26 that also glasses every toolbar control for free. **This is the highest-value change in
   the entire rewrite.**
2. The sidebar is an opaque painted rectangle with grey selection and eight identical monochrome
   symbols; a real macOS sidebar is translucent with a tinted selection capsule, and needs a
   distinct look for "focused pane" vs merely selected.
3. Settings breaks convention four ways: a Save/Revert pair (macOS Settings applies immediately),
   a segmented strip instead of a toolbar, hand-built cards instead of grouped `Form`, and a window
   smaller than its content.
4. Seven unrelated pill treatments, and one purple carrying seven roles at once (brand, links,
   chart series, palette selection, port chips, badges). A colour that means seven things means
   nothing — see rule 1 below.
5. Literal markdown backticks rendered as visible characters in the Disk screen copy. Cheapest fix
   in the plan and the most direct evidence of carelessness.

**SDK trap worth knowing before you go looking:** `glassEffect` and `GlassEffectContainer` live in
**SwiftUICore**, not SwiftUI — grepping `SwiftUI.swiftinterface` returns zero hits and will
convince you they do not exist. Also `GlassButtonStyle.init(_ glass:)` is 26.1 (not 26.0), and the
Scene modifier is `windowToolbarStyle`, not `toolbarStyle`. `pass2/SDK-LIQUID-GLASS.md` §7 lists
what could NOT be verified — do not use anything on that list.


Binding decisions that resolve conflicts between the design system and the pre-rewrite views.
Read this alongside IDENTITY.md and COMPONENTS.md. Where this file and older code disagree,
this file wins.

## 1. Status colours: the Theme is authoritative, not the old screenshots

`Theme.status*` is the single source of truth. The pre-rewrite views rendered `paused` as amber;
the new Theme defines it as blue. **The Theme wins** — centralising these values is the entire
point of the design system, and a view that hardcodes a status colour is a bug regardless of
which hue it picks.

One requirement attached to that ruling: **status must never be conveyed by hue alone.** Paused
and restarting are semantically different (a deliberate hold versus a transient failure loop) and
must remain distinguishable for a colour-blind user and in a greyscale screenshot. So every status
carries a distinct SF Symbol as well as its colour, and the transient states may animate where the
static ones do not.

**RESOLVED — paused is SLATE** (`#4A5568` light / `#94A3B8` dark). This was measured, not chosen by
taste: against `selectionFill`, the current blue sits at ΔE 10.7 light and only **8.0 dark**, close
enough that a paused chip misreads as a selected row. Slate moves that to 13.0 / 12.5 while keeping
dot contrast at 7.53 / 6.50, both comfortably past 4.5:1. Teal scored marginally better but
collides with `seriesTeal` in the categorical palette and reads wrong for "held."

Note the counterintuitive part, because it will come up again: `selectionFill` is a *chromatic* pale
violet, so moving a status colour toward neutral **increases** separation from selection rather than
reducing it. Desaturating is the right instinct here, not the wrong one.

Open, minor: the categorical series still has violet sitting close to indigo. `Theme.seriesRose` is
already near where magenta should go, so adopting rose in violet's slot is likely a one-line change.

Superseded by the above: `pass2/COMPONENTS.md` §4 lists `statusPaused` as "investigate" and
`pass2/IDENTITY.md` §2.2 specifies amber. This file wins.

## 2. Deployment target stays `.macOS(.v15)` — do not bump it

`Package.swift` declares `.macOS(.v15)` while every Liquid Glass API is `macOS 26.0`. This is
**correct and deliberate**, not an oversight:

- `MorbGlass.swift` gates the glass path behind a single `if #available(macOS 26, *)` branch and
  falls back to `Material` below that. The app therefore builds and runs on macOS 15 and looks
  right on 26.
- Raising the target to 26 would drop every user on macOS 15 to gain nothing, since the fallback
  already exists.

Do not "fix" the mismatch by bumping the platform, and do not add a second availability branch
anywhere else — route all glass through `MorbGlass` so there is exactly one place that knows the
version rule.

## 3. Where glass belongs

Sanctioned: sidebar, menu-bar popover, command palette, inspector panes, floating chrome and
toolbars. Forbidden: behind the log viewport, behind dense tables, and behind any scrolling
content region where legibility of small text matters more than depth. Translucency under a
10,000-line log is the single fastest way to make a tool feel like a demo.
