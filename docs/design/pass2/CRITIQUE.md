# CRITIQUE — archived second-pass visual evidence

> **Image note (2026-08-05):** the screenshots this document referenced lived in
> `mac/dist/shots/`, `docs/img/` or `artifacts/visual/` and have been removed. The
> first was offscreen `MorbShots` output, which `docs/design/DECISIONS.md` §6 retired
> as *not* visual evidence — it cannot composite the toolbar, inspector or glass. The
> others were dated captures of superseded builds. The findings stand as written; the
> images are recoverable from git history if a specific one is ever needed.


> **Historical record — nonbinding.** These notes describe the pre-migration app from
> synthetic renders. They explain the custom-web-dashboard failure modes but cannot
> prescribe a replacement or accept a native route. Current review follows the
> [native macOS playbook](../NATIVE-MACOS-PLAYBOOK.md), the
> [HIG coverage audit](../HIG-COVERAGE-AUDIT.md), and real-window inspection.

Source: the ten 2× production renders in `/Users/allie/Develop/morbstack/dist/shots/` plus
`REPORT.md`. Everything below is something visible in those files. Where `REPORT.md` already
concedes a problem I say so, because a conceded problem that is still shipping is still a problem.

The verdict up front: **this is a competent web dashboard that has been compiled into a Mac
binary.** Nothing in these ten images could not have been built in Electron, and several things
would have been *easier* in Electron. That is the whole of the user's complaint, and it is
correct.

---

## 0. The one finding that explains most of the others

**There is no toolbar. Anywhere. In any screenshot.**

Look at the top 80pt of `containers-list-light`, `images-light`, `stacks-dark`, `hero-disk-light`.
Each one paints a title ("Containers", "Images", "Stacks", "Disk"), a subtitle
("8 running · 11 total"), a search field, and one to three buttons — *inside the content view*,
as ordinary SwiftUI. There is no titlebar. There are no traffic lights in frame. There is no
separator between chrome and content except in Disk, where there isn't one either.

Consequences, all of them visible:

- The window has no identity as a window. It reads as a browser viewport.
- Four screens invent four different header layouts. Containers: title+subtitle left, search +
  segmented + destructive button right. Images: title+subtitle left, search + one button right,
  then a *second* full-width bar below it for the pull field. Stacks: title+subtitle left,
  nothing right. Disk: title+subtitle left, one button right. There is no shared chrome, so
  there is no rhythm.
- Every affordance in that strip is hand-rolled: the search field is a custom rounded rect with a
  magnifier glyph, not `.searchable`; "All / Running" is a custom two-cell control that looks
  like a segmented `Picker` but is not one; "Prune stopped 3" is a capsule with a red trash glyph
  and an embedded count.
- Zero of macOS 26's toolbar behaviour is available: no `.toolbar(id:)` customisation, no
  overflow at narrow widths, no `ToolbarSpacer` grouping, no automatic Liquid Glass on toolbar
  items, no keyboard focus order, no ⌘F wiring for the search field.

Fixing this one thing fixes roughly a third of the list below for free, because the system draws
the replacement correctly.

---

## 1. The sidebar is a painted rectangle

- **It is opaque.** Light: a flat near-white slab. Dark: a flat near-black slab. A real macOS
  sidebar is `NSVisualEffectMaterial.sidebar` — translucent, picking up the desktop behind the
  window. This single property is the strongest "native / not native" signal on the whole screen
  and Morbstack is on the wrong side of it. (Verified available: `NSVisualEffectMaterialSidebar`,
  macOS 10.11+, and free via a real `NavigationSplitView` sidebar column on 26.)
- **Selection is grey.** In `images-light` the selected "Images" row is a light-grey rounded rect;
  in `stacks-dark` it is a dark-grey one. macOS 26 draws sidebar selection as an accent-tinted
  capsule. Grey selection means the selected row currently has *less* visual presence than the
  unselected count badges sitting 200pt to its right.
- **There is one selection state, not two.** macOS distinguishes focused selection (accent) from
  unfocused (grey). Morbstack's container list uses the same grey rounded rect as the sidebar, so
  in the two-pane Containers screen you cannot tell which pane owns the keyboard.
- **Rows are ~44pt tall.** macOS sidebar rows are 28–32. The sidebar is 40% taller than it needs
  to be and holds eight items in 1250pt of height.
- **The icons are the giveaway.** `shippingbox`, `square.3.layers.3d`, `square.on.square`,
  `externaldrive`, `globe`, `hammer`, a wheel, `clock` — eight SF Symbols at identical weight,
  identical size, identical monochrome grey, with no tint, no hierarchical rendering, no palette
  rendering. This is what the symbol picker gives you if you take the first plausible hit for each
  noun. Mail, Finder, Reminders and Xcode all tint their sidebar glyphs. Morbstack does not.
  The Kubernetes wheel is also visibly a different stroke weight from its neighbours and breaks
  the optical alignment of the icon column.
- **Count badges are web notification pills** — grey filled capsules with a number. SwiftUI's
  `.badge()` on a `List` row renders the macOS convention (plain secondary text, right-aligned).
- **The footer is a bespoke welded-on status block.** "Engine running / 8 of 11 running" with a
  dot, above a hairline, pinned to the bottom of the sidebar. Not a macOS pattern. This belongs in
  the toolbar or the menu bar extra, and the space belongs to the sidebar.

## 2. Six pill treatments, no system

Count the capsule variants on `hero-containers-dark` alone:

1. Filled-tinted status pill — `running · healthy · up 12d`, green fill, green text, capsule.
2. Outlined chip with a leading glyph — `CREATED / 1 week ago`, two-line, bordered, rounded-rect.
3. Lavender monospace port chip — `5432 → 5432/tcp`, filled, radius ~4.
4. Grey count badge — the `8` next to Containers, capsule.
5. Grey bordered button — `Stop`, `Restart`, rounded-rect radius ~6.
6. Coloured fraction pill — `3/4` amber, `5/5` green, capsule.
7. Neutral service badge — `shopfront`, `postgres`, `api`, capsule.

Seven treatments, at least four radii, three fill strategies (tinted, neutral, outlined), and no
rule that says which means what. A user cannot learn this vocabulary because there isn't one.

## 3. Purple means five different things

`REPORT.md` records the fix that replaced `Color.accentColor` with `Theme.accent` — a good fix,
correctly reasoned. But the result is that one indigo now carries: the brand (icon, Start Engine),
hyperlinks (`Open` in the Ports table — actually that one is *blue*, a sixth colour), palette
selection, chart series 1, port chips, the compose-project badge in the detail header, and the
"Values hidden" toggle. When a colour is applied to seven unrelated roles it stops carrying
information. `REPORT.md` notes the compose-service badge was demoted to neutral for exactly this
reason; the same surgery was needed six more times and stopped after one.

## 4. Contrast is handled by vibes, not by a policy

`REPORT.md`, verbatim on its own past state: several values "were all one step too dim — several
under 3:1. Each raised a step." "Raised a step" is not a contrast policy; it is a nudge until it
looked OK on one display. Still visibly failing in the current shots:

- `hero-disk-light`: the VM disk image path `/Users/ada/.morbstack/data/disk.img` is rendered at
  roughly 30% grey on white. Nowhere near 4.5:1, and it is a value the user may need to copy.
- `engine-stopped-light`: the footer "Morbstack runs Docker in a lightweight virtual machine." is
  lighter still.
- `command-palette-dark`: the footer hint row (`↑↓ navigate ⏎ run esc close · 11 results`) at 11pt
  grey on the dark slab.
- `menubar-popover-dark`: the section headers `RUNNING`, `PUBLISHED PORTS` and the `+3 more in the
  main window` line.

## 5. Literal markdown is being rendered as UI copy

`hero-disk-light`, VM Disk Image section: *"Finder, \`ls -l\` and \`du --apparent-size\` all report
the apparent figure — the actual one is \`st_blocks × 512\`…"* — the backticks are on screen as
characters. This is an AI-authored string that was never proofed in situ, and it is the single
most literal piece of evidence for the user's "looks vibe coded" complaint. It is also two
sentences of explanatory prose where a Mac app would put a six-word footnote.

## 6. The empty state is a Tailwind component

`engine-stopped-light`: a 100pt lavender circle containing a 40pt indigo box glyph, a 20pt bold
headline, a 13pt grey two-line body, and a fully-rounded saturated-indigo pill button with white
bold text.

Every element of that is a web convention:

- **The tinted circle behind an icon** is a shadcn/Tailwind empty-state idiom. macOS does not do
  it. `ContentUnavailableView` (verified, macOS 14+) renders the native form: a large
  secondary-coloured symbol with no container, a title, a description, and actions.
- **The pill CTA.** Saturated fill, full rounding, white semibold label, ~44pt tall, sized to its
  text. That is an iOS/web primary button. macOS 26's prominent button is
  `.buttonStyle(.glassProminent)` (verified) at a system control size.
- The same tinted-circle-plus-glyph appears in `placeholder-builds` per `REPORT.md`, so it is a
  pattern, not a one-off.

## 7. Settings breaks macOS convention four ways at once

`settings-light`:

1. **There is a Save button.** And a Revert button. In a bottom bar. macOS Settings applies
   changes immediately; the entire Save/Revert/dirty-state concept does not exist there. This
   alone would get the screen rejected in review.
2. **The tab strip is not a toolbar.** A centred segmented control floating above a hairline,
   inside a rounded card. macOS Settings uses either a toolbar-tab `TabView` or a
   `NavigationSplitView` sidebar. `REPORT.md` concedes the strip in the shot is "a measured
   stand-in" because the real one rasterises blank — which is itself a signal that the real one is
   fighting AppKit.
3. **The sections are hand-built cards**, grey rounded rects with a 16pt padding, rather than
   `Form` + `.formStyle(.grouped)` (both verified). The slider rows reinvent, badly, exactly what
   grouped `LabeledContent` gives for free: the "1" and "8" endpoint ticks at 9pt grey are
   scaffolding the system would draw.
4. **The window is smaller than its content** and clips "Idle behaviour" mid-card. `REPORT.md`
   confirms this is the real window, not a crop.

Also: two full sentences of grey explanatory prose *inside* a settings card ("A cap, not an
allocation. The VM only takes the memory the guest actually touches…"). Good writing, wrong place
and wrong weight.

## 8. The command palette is a Raycast screenshot pasted over the app

`command-palette-dark`:

- **No scrim.** The window behind it is at full brightness and full contrast. A modal overlay with
  no dimming reads as a floating window someone forgot to attach.
- **Opaque slab + a big soft drop shadow.** No material, no vibrancy, no glass. This is the one
  surface in the entire app where Liquid Glass is unambiguously the right answer and it is the
  flattest thing on screen.
- **Eleven identical icons.** Every result row carries the same green "lines" glyph, because every
  result is "View logs of X". An icon column where every cell is identical is pure noise occupying
  32pt of the most valuable horizontal space in the UI.
- **The right edge jitters.** The `↩` glyph renders only on the selected row, so arrowing down
  makes the trailing edge jump. The "Container" type label also sits at a different x on the
  selected row than the others.
- **The leading `⌘` glyph in the search field** is decorative and actively misleading — it looks
  like a modifier you are supposed to press.

## 9. The menu bar extra is 1500pt tall for eight containers

`menubar-popover-dark`:

- **Opaque near-black card.** Should be popover material or, on 26, glass.
- **Rows are ~80pt tall** for two lines of 13/11pt text. A menu-bar extra row is 22–28pt. This is
  three times the correct density, which is why six ports and eight containers need a scroll view.
- **Inverted hierarchy.** `127.0.0.1:8123` is rendered bold, 15pt, monospaced — the largest,
  heaviest text in the popover. The container name above it is the same weight. The loudest thing
  on screen is a loopback address.
- **CPU percentages are not monospaced-digit.** `25.9%` and `6.1%` are right-aligned but their
  decimal points do not line up, so the column is unreadable as a column.
- **The four commands at the bottom** (Open Morbstack ⌘O, Prune…, Settings… ⌘,, Quit ⌘Q) are
  hand-drawn rows with right-aligned grey shortcut text. Correct instinct, but because they are
  not real menu items they get no hover highlight, no keyboard traversal, and no system styling.

## 10. Tables are `Table` in name only

`images-light`:

- **Eighteen red trash cans in a column.** Destructive colour used as decoration eighteen times.
  Plus eighteen `ⓘ` buttons beside them. Thirty-six controls competing with the data they act on.
  These belong in a context menu (`.contextMenu(forSelectionType:)` — verified) and a toolbar.
- **The "In use" column speaks two languages.** In-use rows get a green filled pill with a box
  glyph and a count; zero-use rows get bare grey `0`. The column cannot be scanned because half of
  it is a badge and half of it is text.
- **Status dots on images.** Green and grey dots in the leading edge of an *Images* table. Images
  do not have run states. This is the container vocabulary applied where it carries no meaning —
  and it is coloured green, which everywhere else in the app means "healthy running container".
- **No row banding, no column customisation, no multi-select, no sort persistence.** `REPORT.md`
  explains banding was removed because `.alternatingRowBackgrounds()` stripes the whole viewport.
  That is a real AppKit behaviour, and the answer is `.tableStyle(.inset)` with the modifier, or
  accepting the stripes at a taller window — not shipping an unbanded 18-row table.
- **The pull field is a form embedded in a table screen** — a full-width grey bar between the
  header and the column titles, with a `Pull` button rendered in a washed-out indigo that reads
  as disabled.

## 11. The container row is dense in the wrong direction

`hero-containers-dark`, a single row (`analytics-clickhouse-1`) carries: a status dot, a bold
name, a neutral service badge, a right-aligned elapsed time, an image:tag, a CPU percentage with a
9pt chip glyph, a memory figure with a 9pt memory glyph, and three lavender port chips. Eight
data points, four type sizes, three colours, ~66pt of height.

- Nothing in that row tells you which of the numbers matters. High ink, no hierarchy.
- The two 9pt inline glyphs are illegible at 1×. They are decoration priced as information.
- The port chips repeat down all eleven rows and become the loudest element in the list — a
  lavender ladder that out-shouts every container name.
- Group separators are full-bleed hairlines that stop short of the group header, so the left edge
  of the list is ragged.

## 12. Stacks: buttons at two levels, alignment at none

`stacks-dark`: each project card has three bordered buttons in its header (Up / Restart / Down)
and each service row has two more icon buttons at its trailing edge. Seven bordered controls per
card, all the same grey capsule, none differentiated by consequence — `Down` (destructive) looks
exactly like `Restart`. The disabled `Up` on the shopfront card is drawn at full capsule weight
with grey text, so it reads as broken rather than unavailable.

The four implicit columns (name/image, ports, uptime, actions) are not on a grid; they line up
between the two cards only because the content happens to be similar widths.

And, per `REPORT.md`, 45% of the window is empty because the cards do not grow. Three screens
share this (Networks, Volumes, Stacks) and the report is honest that no answer was chosen.

## 13. The log viewer is the best screen and still isn't Mac

`hero-logs-dark` is genuinely good — the ANSI renderer, the stderr wash, the amber timing
threshold, the gutter. Remaining problems:

- Its top strip is, again, painted content, not a toolbar. `Follow` and `Times` are toggle chips
  with glyphs; the trailing trash / copy / share are bare glyphs with no button affordance.
- **Green collision.** The `• 412 lines` live indicator uses the same green as "running". Green
  now means both "this container is healthy" and "this stream is attached".
- The stderr wash runs full-bleed *under the gutter*, so the timestamps inside the error region
  are the only ones that lose contrast — exactly the timestamps you want to read.
- The gutter timestamps are nearly the same size and value as DEBUG body text. The gutter must
  recede much harder than it does.
- No ⌘F find bar, no text selection affordance, no "jump to next error" despite the renderer
  already knowing where every error is.

## 14. There is no radius scale, no spacing scale, no density standard

Radii visible across the ten shots: ~4 (port chip), ~6 (buttons, search field), ~8 (cards,
selection), ~10 (palette rows), ~12 (palette), ~16 (settings window), 50% (status pills, CTA).
Seven values.

Row heights: 44 (sidebar), 66 (container), 24 (images table), 32 (stacks service), 60 (disk
legend), 80 (menu bar), 47 (palette). Seven values, none derived from another.

Two screens cannot share a rhythm they were never given.

## 15. No focus states exist

Not one of the ten screenshots shows a focus ring, a first-responder highlight, or a keyboard
affordance other than the palette's footer hints. For a developer tool — an audience that lives on
the keyboard, and OrbStack's core audience — this is a functional gap dressed as a visual one.

---

## What an Apple or OrbStack designer rejects in the first ten seconds

1. The missing titlebar / toolbar. Instant fail; it isn't a Mac window.
2. Save and Revert buttons in Settings.
3. The lavender-circle-plus-glyph empty state and the pill CTA.
4. Two different hand-rolled segmented controls, 200pt apart, on the same screen.
5. Eighteen red trash cans in a table column.
6. An opaque, un-scrimmed command palette with eleven identical icons.
7. Rendered backticks in shipped copy.

## What is genuinely good and must survive the rewrite

Stated plainly so nobody throws it away:

- **The ANSI log renderer.** Colour-coded methods, status codes, the amber >250ms threshold, the
  stderr wash, the traceback treatment. This is real craft and it is the app's best asset.
- **The Disk screen's information design.** "Where did it go" answered by a stacked bar with
  hatched reclaimable shares, then "what do I delete" answered by largest-images/largest-volumes.
  That is a designer's move, not a generator's.
- **Grouping containers by compose project** with a per-group health fraction.
- **The credential heuristic** — the key glyph on `SESSION_SECRET` / `POSTGRES_PASSWORD` and
  masked values by default.
- **The `+N more` overflow** in the menu bar port list, and the abbreviation of anonymous volume
  digests to twelve characters. Both show someone thought about the real data.
- **The honesty of `REPORT.md` itself.** The known-gaps list is accurate and unflattering, which
  is worth more than the screenshots it describes.

The problem is not that nobody was thinking. It is that all the thinking went into content and
none of it went into chrome, and chrome is what "native" is made of.
