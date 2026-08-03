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
