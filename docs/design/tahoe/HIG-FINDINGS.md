# What Apple actually prescribes (macOS 26 Tahoe / Liquid Glass)

Verbatim-fetched from Apple sources in August 2026, not recalled. The HIG HTML pages return a
JavaScript shell to fetchers; the content below came from the underlying DocC JSON endpoints
(`/tutorials/data/design/human-interface-guidelines/<page>.json`) and from WWDC session transcripts.

**There is no standalone Liquid Glass HIG page** — `.../human-interface-guidelines/liquid-glass`
is a 404. Liquid Glass guidance lives inside **Materials**. The most macOS-specific source that
exists is WWDC25 session 310, "Build an AppKit app with the new design."

## The hard prohibitions — these are the ones we were violating

- **"Don't use Liquid Glass in the content layer."** Glass forms a *functional* layer for controls
  and navigation floating above content. Putting it in the content layer "can result in unnecessary
  complexity and a confusing visual hierarchy." Use standard materials for app backgrounds.
- **Never glass on glass.** "Stacking Liquid Glass elements on top of each other can quickly make
  the interface feel cluttered." When placing elements on glass, use fills/transparency/vibrancy
  instead of a second glass layer.
- **Not on tables or lists.** "Consider this tableview: making it Liquid Glass would make it compete
  with other elements and muddy the hierarchy. So keep it in the content layer instead."
- **Use it sparingly.** "Limit these effects to the most important functional elements in your app."
- **Don't tint everything.** "When every element is tinted, nothing stands out… If you want to imbue
  color into your app, do it in the content layer instead." (Directly supports our ruling that brand
  indigo belongs on content, not system chrome.)
- **Don't fake glass with a solid fill** — an opaque fill "breaks the visual character."
- **Custom glass must live in a `GlassEffectContainer`** — "glass can not sample other glass," so
  neighbouring glass in different containers behaves inconsistently.

## Migration gotcha that likely applies to us

> "The legacy sidebar material is no longer necessary. If you're using an `NSVisualEffectView` to
> display that material inside of your sidebar, **it will prevent the glass material from showing
> through**. You should remove these visual effect views."

If any hand-applied material sits in our sidebar, it is *blocking* the system glass rather than
producing it.

## Window and structure

- Apple's blessed layout, verbatim: **"Consider using split views to build sidebar layouts with an
  inspector panel."** → `NavigationSplitView` + `.inspector(isPresented:content:)`.
- **"Avoid creating custom window UI."**
- Sidebars "float above the window's content" as glass; **inspectors use edge-to-edge glass beside
  the content** — they are deliberately different treatments.
- Content **should extend beneath the sidebar**: `backgroundExtensionEffect()`.
- Windows with toolbars now use a **larger corner radius** and **can clip content near the edges**.
- Split views: **prefer the thin divider (1pt)**; set sensible min/max pane sizes.
- Avoid putting critical actions at the **bottom** of a window or sidebar (our engine-status footer
  is worth re-examining against this).
- Sidebar: **no more than two levels of hierarchy**; icons follow the **system accent** by default.

## Inspector reveal: what the ~350ms actually is (2026-08-07, corrected)

> **This section previously concluded "a measured platform floor, not a Morbstack bug" and said
> the reveal was unfixable. That conclusion was wrong, and it was wrong for an instructive
> reason: the instrument measured how much work the transition does, and the symptom was about
> whether any of that work lands in one unbroken block. Those are different quantities and
> Instruments' Time Profiler cannot tell them apart. The numbers below supersede it.**

Reported against `ContainersRootView`: closing the trailing inspector slides; opening it stalls
and pops in place.

### The measurement error

Instruments (Time Profiler, real signed build, PID-attached) reported an "unbroken run of
main-thread samples" of ~335–490ms at each toggle and this was read as a ~350ms *block* before
the first animated frame. It is not a block. It is the animation running.

Two instruments on the *same* clicks separate them:

- **In-process stall meter.** A `Timer` on the main run loop at 2ms in `.common` mode with zero
  tolerance. A timer cannot fire while the main thread is inside a synchronous AppKit layout
  pass, so the largest gap between consecutive ticks *is* the unbroken block.
- **External CPU delta.** Cumulative process CPU sampled with `ps` around each `AXPress`, which
  is the quantity Instruments was actually reporting.

On the same six real toolbar clicks on `PerfProbe`: CPU delta **400 / 290 / 300 / 290 / 290 /
340ms**, in-process block **0ms — no gap anywhere above 30ms.** Roughly 300ms of main-thread CPU
per toggle, spread across the animation's frames, none of it blocking. `docs/design/probes/`
holds both instruments (`PerfProbe.swift`, `axpress-cost.sh`).

### It is a one-time cost, not a per-open one

The earlier write-up's load-bearing claim was "It is every open, not a one-time warm-up", which
is what ruled out warming the column as a fix. With real `AXPress` clicks on a real bundled
window and the stall meter running, eight consecutive toggles produced exactly **one** block —
the first reveal, 307ms — and nothing above 30ms for the other seven. The magnitude of that
first reveal also decays as the machine warms: 523ms, then 362ms, then 92 / 61 / 47ms across
consecutive launches of the same binary. Any measurement of it that does not say how warm the
machine was is not comparable to any other.

**And it is only paid on the transition that first presents the column.** With
`start=open` — which is what all nine routes ship, `@State private var showsInspector = true` —
there is no block in either direction at all, because the column's AppKit backing is built
during window setup where it is invisible. That, not a direction-dependent platform floor, is
the whole of the "close is free on Containers, expensive in the probe" asymmetry: the probe was
launched `--closed`.

### The column slides, on the real app, in both directions

`docs/design/probes/AXColumnTrace.swift` reads the content column's width out of the running
window through the accessibility API — no rebuild, no instrumentation, works on
`dist/Morbstack.app` while somebody else has it open — and presses the toolbar control by
`AXIdentifier`. A pop shows two widths and nothing between them; a slide shows a ramp.

Four consecutive toggles on the real Containers route, alternating direction:

| Toggle | Direction | Intermediate widths | Ramp |
| --- | --- | --- | --- |
| 1 | open | 3 | 972 → 1101 → 1316 → 1364 → 1372 |
| 2 | close | 6 | 1372 → 1292 → 1243 → 1194 → 1144 → 1039 → 981 |
| 3 | open | 3 | 972 → 975 → 1284 → 1347 → 1372 |
| 4 | close | 2 | 1372 → 1047 → 984 → 972 |

Re-run on a freshly launched instance of the binary proven below to contain `caab2f9`, six
toggles, and this time the warm-up is visible in the geometry itself:

| Toggle | Direction | Intermediate widths | Slowest AX read |
| --- | --- | --- | --- |
| 1 | open | 1 | 476ms |
| 2 | close | 3 | 123ms |
| 3 | open | 2 | 123ms |
| 4 | close | 1 | 231ms |
| 5 | open | **7** | 60ms |
| 6 | close | **8** | 52ms |

The first reveal after launch draws one intermediate frame — which is very close to a pop, and is
almost certainly what was originally reported. By the fifth and sixth it draws seven and eight,
which is a clean slide. That is the same one-time cost the stall meter measures, read off the
window's own geometry instead: the symptom is real, it is first-open-only, and it goes away by
itself. "Opening pops" and "it reads as smooth now" are both true, of the same build, minutes
apart.

It interpolates. It slides. There is also **no direction asymmetry**: the same four toggles cost
340 / 250 / 230 / 230ms of CPU (and 270 / 250 / 250 / 340 for the next four). The previously
recorded "closing is free — 0 samples, confirmed twice" is not reproducible and was a sampling
artifact.

### Which binary each number came from, established rather than inferred

`dist/Morbstack.app` was built at 10:21:30 and `caab2f9` — the `TimelineView` consolidation —
was committed at 10:21:56, twenty-six seconds later. That ordering was read as "the bundle
predates the fix", which would have made every measurement above, and the GIF capture, stale.

It does not. A commit's timestamp is when the tree was committed, not when it was written, and
the question is answerable off the binary itself. `caab2f9` changed a signature —
`containerRow(_:)` became `containerRow(_:now:)` — and Swift mangles parameter labels into the
symbol:

```
$ nm -a dist/Morbstack.app/Contents/MacOS/MorbstackApp | grep -o 'containerRow33_[A-F0-9]*LL.\{0,6\}' | sort -u
containerRow33_0AE095D63ED5EA1B339865C74C78B832LLyQrAA   # MorbMenuBarContent.containerRow(_:)
containerRow33_95219CD9A478FDEE85F3F601A6341B43LL_3now   # ContainersRootView.containerRow(_:now:)
```

`ContainersRootView`'s symbol carries `_3now`. The bundle **contains** the consolidation; it was
built from the tree that was committed 26 seconds later. The second symbol is an unrelated
`containerRow(_:)` in `MorbMenuBar.swift`, which is what makes the pair look like two versions of
one function until the owning type is read off the mangling. Every real-app number in this
section is from that binary, and — checked separately — the only change to `mac/Sources` between
`caab2f9` and now that touches this route is comment text.

**This is the cheap check to reach for whenever "is the running app the code I think it is?"
comes up.** It beats reasoning from timestamps, and this project has twice reached the wrong
conclusion by reasoning from timestamps.

### A 2.9fps GIF cannot record a 250ms animation

`docs/gallery/containers-inspector-reveal.gif` was captured from that same (correct) binary and
read as showing the reveal still popping. It does not show that, because it cannot:

```
frames: 6 · total duration: 2.04s · every frame 34cs → 2.9fps
```

One frame every 340ms, against a transition the AX trace above measures at 150–250ms end to end.
The animation is over inside a single frame interval, so the capture can only ever hold "closed"
in one frame and "open" in the next — which reads as a pop no matter how smoothly the window
actually moved. `scripts/capture-gif.sh` is right to declare its measured rate rather than a
hoped-for one, but at this rate the honest reading of that file is *"this capture path cannot
resolve this motion"*, not *"the motion did not happen"*. Use `AXColumnTrace.swift` for reveal
timing; a GIF at screencapture's achievable rate is for showing what a route looks like, not for
adjudicating a sub-300ms transition.

### The subtraction matrix

Every ingredient varied independently against a minimum case, three interleaved reps per shape,
fresh process each (reps interleaved because a warming machine otherwise manufactures a
difference). `lead1` is the first reveal's block, `leadN` steady-state, `frames%` display-link
callbacks delivered during the animation on a 165Hz panel, `cpu` main-thread CPU per toggle.

| Shape | lead1 | leadN | frames% | cpu | Δcpu |
| --- | --- | --- | --- | --- | --- |
| minimum: `NavigationSplitView` + `Text` + `.inspector(Text)`, no toolbar | 84.8 | 0.0 | 88% | **181.3** | — |
| \+ one plain toolbar button on the root | 69.9 | 0.0 | 88% | 199.0 | +17.7 |
| \+ one plain toolbar button on the inspector's content | 64.3 | 33.4 | 86% | 193.5 | +12.2 |
| \+ a `Menu` | 0.0 | 0.0 | 95% | 192.3 | +11.0 |
| \+ the full route toolbar (menu, 3 buttons, spacer, toggle) | 36.0 | 0.0 | 95% | 196.6 | +15.3 |
| \+ `.searchable(placement: .toolbar)` | 49.6 | 0.0 | 96% | 196.6 | +15.3 |
| content column `List`, 5 rows | 34.4 | 0.0 | 94% | 205.4 | +24.1 |
| content column `List`, 500 rows | 67.9 | 0.0 | 74% | 241.6 | +60.3 |
| content column `Table`, 5 rows | 64.7 | 0.0 | 79% | 246.2 | +64.9 |
| content column `Table`, 500 rows | 74.0 | 38.7 | 60% | 265.5 | +84.2 |
| inspector content `Form`, 3 rows | 103.8 | 0.0 | 80% | 212.1 | +30.8 |
| inspector content `Form`, 30 rows | 161.9 | 36.4 | 69% | 240.3 | +59.0 |
| `.inspectorColumnWidth(min:ideal:max:)` | 69.1 | 0.0 | 90% | 194.3 | +13.0 |
| `.inspectorColumnWidth(400)` — a single fixed value | 86.7 | 0.0 | 88% | 197.4 | +16.1 |
| everything at once (the `inspectorForm` shape) | 107.5 | 32.2 | 57% | 289.9 | +108.6 |

Read off it:

- **The toolbar is not the cost.** +11 to +18ms whatever is in it, and it makes no difference
  whether items are mounted on the route root or on the inspector's own content. Hypothesis
  rejected.
- **A ranged `.inspectorColumnWidth` costs nothing over a fixed one** — 194.3 vs 197.4ms, inside
  the noise. There is no constraint-solve penalty for the range, so the outermost-modifier fix
  on all nine routes stays exactly as it is. Hypothesis rejected.
- **The content column scales, mildly.** `List` 5 → 500 rows is +24 → +60; `Table` costs more
  than `List` at every size. Real, and it is where frame delivery degrades (94% → 60%), but it
  is a minority of the total.
- **62% of the cost is the minimum case.** A bare `NavigationSplitView` with a `Text` on both
  sides and no toolbar still spends 181ms of main-thread CPU presenting the column. *That* is
  the platform's own cost — but it is CPU spread across frames, it delivers 88% of a 165Hz
  panel, and it does not block.

**Conclusion.** `.inspector(isPresented:)`'s reveal costs ~180ms of main-thread CPU in the
minimum case and ~290ms in our shape, spread across the animation's frames. It blocks the main
thread exactly once per window, on whichever transition first presents the column, and the
routes already avoid paying that visibly by defaulting the inspector open. Nothing in the
content layer needs to change, and — this is the correction — nothing is broken.

## Toolbar — three regions with fixed semantics

Leading (back / sidebar toggle, then title — not customizable) · Center (common controls,
customizable, auto-collapses into a system overflow) · Trailing (inspector toggle, search, More,
primary action — always visible).

- **Aim for a maximum of three groups.** The only count Apple publishes.
- **`.primaryAction` resolves to the LEADING edge on macOS** (trailing on iOS) — easy to get wrong.
  `.principal` → center. `.navigation` → leading, ahead of the title. `.confirmationAction` →
  sheets, not the window toolbar.
- **Search goes at the trailing side of the toolbar** on macOS (or at the top of the sidebar when it
  filters navigation).
- **Reduce custom toolbar backgrounds and tinted controls** — they interfere with system effects.
- **Prefer system symbols without borders**; the glass section already provides the container.
- **Don't mix text and icon items that share a background**; keep labelled actions in their own group.
- **One primary action only**, trailing, `.prominent`.
- **Don't add an overflow menu manually.**
- Window titles: **under 15 characters**, and **never the app name** (so a "Morbstack" title or
  sidebar-header card is doubly wrong).
- **Every toolbar item must also exist as a menu-bar command.**
- Non-interactive toolbar items must opt out of glass or they read as buttons.
- Glass grouping is automatic; use `ToolbarSpacer` (SwiftUI) / `NSToolbarItemGroup` (AppKit) to
  control it, or `sharedBackgroundVisibility(_:)` to split one item onto its own glass.

## Scroll edge effect

- **Prefer the automatic style.** Only use one **when a scroll view sits behind floating elements** —
  "scroll edge effects aren't decorative."
- **One per view**; in split layouts each pane may have its own, kept at consistent heights.
- **Hard style is mostly macOS** — stronger boundary, good for pinned headers and unbacked controls.

## Concentricity

Fixed radius · capsule (half the height) · **concentric (parent radius − padding)**. On macOS,
Mini/Small/Medium controls stay rounded rectangles; **Large controls are capsules**. Use
`ConcentricRectangle` / `.rect(corners: .containerConcentric)`, with a fallback radius for
standalone use.

## Typography — the only page with hard macOS numbers

Default **13pt**, minimum 10pt, SF Pro, **no Dynamic Type on macOS**.

| Style | Weight | Size | Line height |
|---|---|---|---|
| Large Title | Regular | 26 | 32 |
| Title 1 | Regular | 22 | 26 |
| Title 2 | Regular | 17 | 22 |
| Title 3 | Regular | 15 | 20 |
| Headline | Bold | 13 | 16 |
| Body | Regular | 13 | 16 |
| Callout | Regular | 12 | 15 |
| Subheadline | Regular | 11 | 14 |
| Footnote | Regular | 10 | 13 |
| Caption 1 | Regular | 10 | 13 |
| Caption 2 | Medium | 10 | 13 |

**Avoid light weights** — Regular, Medium, Semibold, Bold only.

## App icon

Layered (background + foreground layers), **1024×1024**, authored in **Icon Composer**, vectors
preferred. **Do not bake in** specular highlights, drop shadows, bevels, blurs or glows — the system
generates them. Provide **unmasked** layers with clearly defined edges. Variants: default, dark,
clear light/dark, tinted light/dark; unspecified ones are generated.

## The honest gap

**Apple publishes almost no concrete numbers for macOS chrome** — no sidebar widths, toolbar
heights, control heights, corner radii, margins or grid. The only hard values anywhere are the
typography table, the 1pt split divider, the 35% clear-glass dimming layer, the 1024px icon canvas
and "max three toolbar groups."

That is deliberate: *"Prefer to use standard spacing metrics instead of overriding them"* and *"if
you use standard controls and don't hard-code their layout metrics, your app adopts changes to
shapes and sizes automatically."* **A spec that pins numbers is fighting the system.** Concentricity
is defined relationally, not as a constant. This is the strongest possible argument for our rule:
let the system draw it.

## macOS 27 (already in beta) — direction of travel

Sidebars **expand to the edges**; sidebar selection uses **semi-bold text** for emphasis; content
still flows behind; bordered toolbar items over the sidebar adopt glass; icons regain **accent
colour**. Worth designing with, not against.

## Sources

All fetched: HIG designing-for-macos · materials · toolbars · sidebars · split-views · windows ·
layout · typography · app-icons · icons · scroll-views · search-fields; Adopting Liquid Glass;
Applying Liquid Glass to Custom Views; SwiftUI Updates. Transcripts: WWDC25 219, 310 (most
macOS-specific), 323, 356; WWDC26 102, 269, 289.

## Community addendum (liquid-glass-skill, treated as reference not authority)

From github.com/haider-nawaz/liquid-glass-skill. These corroborate Apple's guidance above and add
macOS-specific gotchas worth testing rather than trusting blindly:

- **Glass buttons on macOS need `.tint(.clear)`** or they render incorrectly tinted. This is the
  same family as our hot-pink problem: an untinted glass button inherits the system accent. Apply
  `.tint(.clear)` for glass buttons; reserve explicit tint for the single prominent action.
- **Anything that paints its own background on navigation chrome BLOCKS glass.** Remove
  `.toolbarBackground(...)` and `.background(.ultraThinMaterial)` from navigation containers — glass
  handles it. This is the SwiftUI mirror of Apple's AppKit warning that an `NSVisualEffectView`
  inside a sidebar prevents the glass material showing through. If our chrome looks flat, suspect a
  background we are painting ourselves.
- **Use `WindowBackgroundShapeStyle.windowBackground` on macOS** rather than a `Material` for window
  and content backgrounds.
- **`.secondaryAction` is the macOS overflow placement.**
- Keep materials only on *content* backgrounds, never on navigation elements — consistent with
  Apple's "don't use Liquid Glass in the content layer" from the opposite direction: materials for
  content, glass for chrome, never swapped.

Note the skill is community-authored and iOS-leaning; where it conflicts with the Apple sources
above, Apple wins.
