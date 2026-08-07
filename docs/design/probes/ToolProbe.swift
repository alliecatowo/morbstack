// ToolProbe — stock SwiftUI, zero Morbstack code.
//
// Answers, in one binary, the questions this project keeps re-deriving:
//
//   1. Can the system search field be placed anywhere other than the window's
//      trailing edge on macOS 26, and what sits trailing of it?          (2026-08-06 round 1)
//   2. Can `.searchable` be made to render INSIDE the inspector pane?    (round 2)
//   3. Can the toolbar search field be made to render as a glyph?        (round 2)
//   4. Where does every macOS `ToolbarItemPlacement` actually land, and
//      what shares one glass capsule with what?                          (round 2)
//   5. Is the sidebar/inspector toggle asymmetry ours or the platform's?  (round 2)
//
// Build and capture with `./run-probe.sh`. Every variant is one declaration
// shape; nothing here imports or mimics Morbstack.
//
//   --variant <name>   which shape to render
//   --size WxH         window content size (default 1600x1000)
//   --closed           start with the inspector closed
//   --sidebar-closed   start with the sidebar collapsed
//   --light            light appearance

import AppKit
import SwiftUI

// MARK: - Variants

enum Variant: String, CaseIterable {
    // ---- round 1: where does search go, and what can follow it ----

    /// Search trailing (`.toolbar`), custom cluster declared before it.
    case trailing
    /// `.searchable(placement: .toolbarPrincipal)` — search in the centre region.
    case principal
    /// `.searchable(placement: .toolbar)` + `DefaultToolbarItem(kind: .search, placement: .principal)`.
    case defaultItemPrincipal
    /// `.searchable(placement: .toolbar)` + `.searchToolbarBehavior(.automatic)`.
    /// (`.minimize` is `@available(macOS, unavailable)`; this variant can only
    /// ever show what `.automatic` does. Kept so nobody retries it.)
    case minimize
    /// principal + `.searchToolbarBehavior(.automatic)`.
    case principalMinimize
    /// `ToolbarSpacer(.flexible, placement: .primaryAction)` between the groups.
    case flexibleSpacer
    /// Hand-rolled TextField at `.principal`, no `.searchable`. Shows what the
    /// forbidden custom control would look like — for contrast only.
    case customField
    /// principal search, inspector toggle declared LAST in the primary run.
    case principalToggleLast
    /// Everything in one `.automatic` run with a flexible spacer between the
    /// buttons and an explicit `DefaultToolbarItem(kind: .search)`.
    case automaticRun
    /// `.searchToolbarBehavior` driven by inspector state rather than width.
    case minimizeWithInspector
    /// principal search, all four command items mounted on the inspector content.
    case principalAllTrailing

    // ---- round 2: can search live inside the inspector pane? ----

    /// No `.searchable` on the root at all; the inspector's own content carries
    /// `.searchable(placement: .toolbar)`. If SwiftUI can render search inside a
    /// pane, this is the declaration that would do it.
    case inspectorToolbar
    /// Same, `.toolbarPrincipal`.
    case inspectorPrincipal
    /// Same, `.sidebar` — does `.sidebar` mean "the nearest pane" or
    /// "the NavigationSplitView sidebar"?
    case inspectorSidebar
    /// Same, `.automatic` — what does SwiftUI pick when asked from inside a pane?
    case inspectorAutomatic
    /// `.searchable(placement: .sidebar)` on the NavigationSplitView root.
    case sidebarPlacement
    /// `.searchable(placement: .sidebar)` declared on the detail column (the
    /// table), not the root. Xcode's filter-inside-the-pane shape, if reachable.
    case detailSidebarPlacement
    /// `.searchable(placement: .automatic)` on the root.
    case automaticPlacement

    // ---- round 2: can the toolbar search field be made a glyph? ----

    /// `.searchable(placement: .toolbar)` with the search item explicitly placed
    /// in the macOS accessory bar (the second row under the toolbar).
    case searchAccessoryBar
    /// Explicit search item boxed in by flexible spacers on both sides — does
    /// the field yield its width to them?
    case searchSquashed
    /// Ten primary items plus search: force the system to run out of room and
    /// see what its own collapsed search presentation looks like.
    case crowded

    // ---- round 2: grammar ----

    /// One numbered button in every macOS-available placement, so the regions
    /// can be read straight off a capture.
    case placementMap
    /// Capsule grouping: adjacency, `ToolbarSpacer(.fixed)`, `(.flexible)`, and
    /// `sharedBackgroundVisibility(.hidden)` side by side.
    case groupingRules
    /// Nothing but the two toggles, so the sidebar/inspector edges can be
    /// compared without any other item in the bar.
    case toggleSymmetry
    /// Four items, no spacer — the control for the spacer matrix below.
    case spacerNone
    /// Four items with `ToolbarSpacer(.fixed)` at its DEFAULT placement
    /// (`.automatic`) between the second and third — the exact spelling three
    /// shipped routes use.
    case spacerFixedDefault
    /// Same, but the spacer is declared `placement: .primaryAction`, matching
    /// the items around it.
    case spacerFixedPrimary
    /// Same, `.flexible` at `.primaryAction`.
    case spacerFlexPrimary
    /// Same, but the split is made with `sharedBackgroundVisibility(.hidden)`.
    case spacerSharedHidden
    /// The inspector toggle drops its own glass while the inspector is open,
    /// mirroring what `NavigationSplitView` does for the sidebar toggle.
    case absorbedToggle
    /// Two `ToolbarItemGroup`s in the same placement run — does a group get its
    /// own glass capsule the way `NSToolbarItemGroup` does in Finder?
    case groupPair
    /// Two `ToolbarItemGroup`s with a `ToolbarSpacer(.fixed)` between them.
    case groupPairSpacer
    /// A `Menu` next to plain buttons: does a menu share the capsule?
    case menuInRun

    // ---- round 3: search as a glyph, with the machinery kept ----

    /// `.searchable` still declared (so ⌘F and the Find menu survive), the
    /// system's own search toolbar item removed with `.toolbar(removing: .search)`,
    /// and a plain `Button` with a `magnifyingglass` glyph put next to the
    /// inspector toggle. The glyph focuses the field via `.searchFocused`.
    case glyphOnly
    /// Same, but the search field is left at `.sidebar` so it has somewhere
    /// real to appear when focused.
    case glyphSidebar
    /// `.toolbar(removing: .search)` applied INSIDE `.searchable` rather than
    /// outside it — modifier order is the obvious suspect when a removal is inert.
    case glyphRemoveInner
    /// The system search item pushed into each remaining macOS placement, to
    /// find one whose region is narrow enough that the system collapses the
    /// field to its own glyph without us sizing anything.
    case searchAtNavigation
    case searchAtStatus
    case searchAtDestructive
    case searchAtConfirmation
    /// The candidate design: `.searchable` is attached only while a search is
    /// actually running. At rest the toolbar carries a plain `magnifyingglass`
    /// Button next to the inspector toggle and NO field; clicking it attaches
    /// the system's own search field and focuses it. Nothing is imitated — the
    /// system still draws the field, we only decide when it exists.
    case glyphToggle

    // ---- round 4: what may the inspector's own content be? ----
    //
    // The question these answer is not about the toolbar at all: it is whether
    // the container the inspector's content uses paints chrome of its own over
    // the chrome the window already draws. Read the capture at the inspector's
    // leading divider (`pix … col <x>`): the window's own border tone is the
    // reference, and any column that reads brighter than it below the toolbar is
    // a second border being drawn by the content.

    /// Baseline: the inspector's content is a plain `Form`. What the window is
    /// supposed to look like.
    case inspectorForm
    /// The inspector's content is a `TabView` of `Tab`s at its default style.
    case inspectorTabView
    /// The same `TabView` with `.tabViewStyle(.grouped)` — macOS-only, macOS 15+.
    case inspectorTabViewGrouped
    /// The same `TabView` with `.tabViewStyle(.sidebarAdaptable)`.
    case inspectorTabViewSidebarAdaptable
    /// The shape Apple's own inspectors use: a segmented `Picker` at the top of
    /// the pane and the selected view below it. No tab container at all.
    case inspectorPickerPanes

    // ---- round 4: what orders the trailing run? ----

    /// Five numbered items in the one trailing run, declared across the two
    /// toolbar modifiers the routes actually use (the root's and the inspector
    /// content's), alternating `.primaryAction` and `.automatic`:
    ///
    ///   root:      1 primaryAction · 2 automatic
    ///   inspector: 3 automatic · 4 primaryAction · 5 primaryAction
    ///
    /// If the rendered order is 1 2 3 4 5, order is declaration order and the two
    /// placements do not sort against each other. Anything else and they do.
    case runOrder
}

// MARK: - Content

struct Row: Identifiable {
    let id: Int
    var name: String { "item-\(id)" }
}

struct ProbeContent: View {
    let variant: Variant
    @State private var query = ""
    @State private var showsInspector = !CommandLine.arguments.contains("--closed")
    @State private var columnVisibility: NavigationSplitViewVisibility =
        CommandLine.arguments.contains("--sidebar-closed") ? .detailOnly : .all
    @State private var selection: Int?
    @FocusState private var searchFocused: Bool
    @State private var searchActive = false
    @State private var pane = 0
    private let rows = (0..<40).map(Row.init(id:))

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                ForEach(0..<8, id: \.self) { i in
                    Label("Row \(i)", systemImage: "circle").tag(i)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationTitle("Probe")
        .toolbar { leadingAndCentre }
        .modifier(RootSearchModifier(variant: variant, query: $query))
        .modifier(
            ConditionalSearchModifier(
                active: variant == .glyphToggle && searchActive, query: $query))
        .searchFocused($searchFocused)
        .onAppear {
            guard CommandLine.arguments.contains("--focus-search") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                searchActive = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searchFocused = true }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let table = Table(rows, selection: $selection) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Driver") { _ in Text("local") }
            TableColumn("Size") { _ in Text("128 MB") }
        }
        .inspector(isPresented: $showsInspector) {
            inspectorContent
                .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
            .toolbar { trailingCluster }
            .modifier(InspectorSearchModifier(variant: variant, query: $query))
        }

        if variant == .detailSidebarPlacement {
            table.searchable(text: $query, placement: .sidebar, prompt: "Name, driver")
        } else {
            table
        }
    }

    /// Round 4. Every variant except the two `TabView` ones gets the plain form,
    /// so every earlier capture is unaffected by this addition.
    @ViewBuilder
    private var inspectorContent: some View {
        switch variant {
        case .inspectorTabView:
            inspectorTabs
        case .inspectorTabViewGrouped:
            inspectorTabs.tabViewStyle(.grouped)
        case .inspectorTabViewSidebarAdaptable:
            inspectorTabs.tabViewStyle(.sidebarAdaptable)
        case .inspectorPickerPanes:
            VStack(spacing: 0) {
                Picker("Pane", selection: $pane) {
                    Text("Overview").tag(0)
                    Text("Logs").tag(1)
                    Text("Files").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.top, 8)
                inspectorForm
            }
        default:
            inspectorForm
        }
    }

    private var inspectorForm: some View {
        Form {
            LabeledContent("Variant", value: variant.rawValue)
            LabeledContent("Query", value: query.isEmpty ? "—" : query)
            LabeledContent("Inspector", value: showsInspector ? "open" : "closed")
            // Identity canary: `.onAppear` fires once per view identity. If
            // attaching `.searchable` conditionally rebuilds the subtree, this
            // count goes to 2 and every child @State in the route was reset.
            IdentityCanary()
        }
        .formStyle(.grouped)
    }

    private var inspectorTabs: some View {
        TabView {
            Tab("Overview", systemImage: "info.circle") { inspectorForm }
            Tab("Logs", systemImage: "text.alignleft") { inspectorForm }
            Tab("Files", systemImage: "folder") { inspectorForm }
        }
    }

    // Two visually distinct groups plus the inspector toggle, matching the
    // Morbstack shape: a destructive glyph, a share glyph, a create glyph, then
    // the toggle.
    @ToolbarContentBuilder
    private var trailingCluster: some ToolbarContent {
        if variant == .runOrder {
            ToolbarItem(id: "probe.r3", placement: .automatic) {
                Button {} label: { Image(systemName: "3.circle") }
            }
            ToolbarItem(id: "probe.r4", placement: .primaryAction) {
                Button {} label: { Image(systemName: "4.circle") }
            }
            ToolbarItem(id: "probe.r5", placement: .primaryAction) {
                Button {} label: { Image(systemName: "5.circle") }
            }
        }
        if variant == .principalAllTrailing {
            ToolbarItem(id: "probe.trash", placement: .primaryAction) {
                Button(role: .destructive) {} label: { Image(systemName: "trash") }
            }
            ToolbarItem(id: "probe.share", placement: .primaryAction) {
                Button {} label: { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarSpacer(.fixed)
        }
        if variant != .placementMap && variant != .groupingRules && variant != .toggleSymmetry
            && !isSpacerMatrix && variant != .groupPair && variant != .groupPairSpacer
            && variant != .menuInRun && !isGlyphSearch && !isSearchPlacementSweep
            && variant != .glyphToggle && variant != .runOrder
        {
            ToolbarItem(id: "probe.create", placement: .primaryAction) {
                Button {} label: { Image(systemName: "plus") }
            }
        }
        if variant == .absorbedToggle {
            // `sharedBackgroundVisibility(.hidden)` is Apple's named API for
            // taking an item out of the shared glass. Driving it from the
            // inspector's own state is the closest stock spelling of what
            // NavigationSplitView does for the sidebar toggle for free.
            ToolbarItem(id: "probe.inspector", placement: .primaryAction) {
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
            }
            .sharedBackgroundVisibility(showsInspector ? .hidden : .automatic)
        } else if variant == .placementMap || variant == .groupingRules
            || variant == .toggleSymmetry || variant == .principalToggleLast
            || variant == .principalAllTrailing || isSpacerMatrix
            || variant == .groupPair || variant == .groupPairSpacer || variant == .menuInRun
            || isGlyphSearch || isSearchPlacementSweep || variant == .glyphToggle
            || variant == .runOrder
        {
            ToolbarItem(id: "probe.inspector", placement: .primaryAction) {
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
            }
        } else {
            ToolbarItem(id: "probe.inspector", placement: .automatic) {
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
            }
        }
    }

    /// Split into independent `if`s rather than one `switch`: a switch over
    /// twenty-odd branches of distinct opaque ToolbarContent types blows the
    /// type-checker's budget outright ("unable to type-check in reasonable
    /// time"). Each `if` is its own optional branch and costs nothing.
    @ToolbarContentBuilder
    private var leadingAndCentre: some ToolbarContent {
        groupA
        groupB
    }

    @ToolbarContentBuilder
    private var groupA: some ToolbarContent {
        if variant == .placementMap { placementMapItems }
        if variant == .groupingRules { groupingRuleItems }
        if variant == .crowded { crowdedItems }
        if isSpacerMatrix { spacerMatrixItems }
        if variant == .groupPair || variant == .groupPairSpacer { groupPairItems }
        if variant == .menuInRun { menuRunItems }
        if isGlyphSearch { glyphSearchItems }
        if isSearchPlacementSweep { searchPlacementSweepItems }
        if variant == .glyphToggle { glyphToggleItems }
        if variant == .runOrder { runOrderRootItems }
    }

    /// Declared on the ROOT's toolbar. See `Variant.runOrder`.
    @ToolbarContentBuilder
    private var runOrderRootItems: some ToolbarContent {
        ToolbarItem(id: "probe.r1", placement: .primaryAction) {
            Button {} label: { Image(systemName: "1.circle") }
        }
        ToolbarItem(id: "probe.r2", placement: .automatic) {
            Button {} label: { Image(systemName: "2.circle") }
        }
    }

    @ToolbarContentBuilder
    private var glyphToggleItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .primaryAction) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        ToolbarItem(id: "probe.share", placement: .primaryAction) {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
        }
        if !searchActive {
            ToolbarItem(id: "probe.search", placement: .primaryAction) {
                Button {
                    searchActive = true
                    DispatchQueue.main.async { searchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
    }

    private var isSearchPlacementSweep: Bool {
        switch variant {
        case .searchAtNavigation, .searchAtStatus, .searchAtDestructive, .searchAtConfirmation:
            return true
        default:
            return false
        }
    }

    @ToolbarContentBuilder
    private var searchPlacementSweepItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .primaryAction) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        if variant == .searchAtNavigation {
            DefaultToolbarItem(kind: .search, placement: .navigation)
        }
        if variant == .searchAtStatus {
            DefaultToolbarItem(kind: .search, placement: .status)
        }
        if variant == .searchAtDestructive {
            DefaultToolbarItem(kind: .search, placement: .destructiveAction)
        }
        if variant == .searchAtConfirmation {
            DefaultToolbarItem(kind: .search, placement: .confirmationAction)
        }
    }

    private var isGlyphSearch: Bool {
        variant == .glyphOnly || variant == .glyphSidebar || variant == .glyphRemoveInner
    }

    /// The shape the user asked for: a magnifying-glass Button sitting with the
    /// other trailing commands, and no system search field in the bar. The
    /// Button is stock SwiftUI — the system draws its glass — but the *search*
    /// still comes from `.searchable`, which is what keeps ⌘F alive.
    @ToolbarContentBuilder
    private var glyphSearchItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .primaryAction) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        ToolbarItem(id: "probe.share", placement: .primaryAction) {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
        }
        ToolbarItem(id: "probe.search", placement: .primaryAction) {
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
        }
    }

    @ToolbarContentBuilder
    private var groupPairItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {} label: { Image(systemName: "a.circle") }
            Button {} label: { Image(systemName: "b.circle") }
        }
        if variant == .groupPairSpacer { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {} label: { Image(systemName: "c.circle") }
            Button {} label: { Image(systemName: "d.circle") }
        }
    }

    @ToolbarContentBuilder
    private var menuRunItems: some ToolbarContent {
        ToolbarItem(id: "probe.mA", placement: .primaryAction) {
            Button {} label: { Image(systemName: "a.circle") }
        }
        ToolbarItem(id: "probe.mMenu", placement: .primaryAction) {
            Menu {
                Button("One") {}
                Button("Two") {}
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        ToolbarItem(id: "probe.mB", placement: .primaryAction) {
            Button {} label: { Image(systemName: "b.circle") }
        }
    }

    private var isSpacerMatrix: Bool {
        switch variant {
        case .spacerNone, .spacerFixedDefault, .spacerFixedPrimary, .spacerFlexPrimary,
            .spacerSharedHidden:
            return true
        default:
            return false
        }
    }

    /// Four identical items in one `.primaryAction` run, split five different
    /// ways. Capture all five and diff the x-ranges: whichever spelling
    /// produces two capsules is the one that actually separates a group.
    @ToolbarContentBuilder
    private var spacerMatrixItems: some ToolbarContent {
        ToolbarItem(id: "probe.sA", placement: .primaryAction) {
            Button {} label: { Image(systemName: "a.circle") }
        }
        ToolbarItem(id: "probe.sB", placement: .primaryAction) {
            Button {} label: { Image(systemName: "b.circle") }
        }
        if variant == .spacerFixedDefault { ToolbarSpacer(.fixed) }
        if variant == .spacerFixedPrimary { ToolbarSpacer(.fixed, placement: .primaryAction) }
        if variant == .spacerFlexPrimary { ToolbarSpacer(.flexible, placement: .primaryAction) }
        if variant == .spacerSharedHidden {
            ToolbarItem(id: "probe.sC", placement: .primaryAction) {
                Button {} label: { Image(systemName: "c.circle") }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "probe.sC", placement: .primaryAction) {
                Button {} label: { Image(systemName: "c.circle") }
            }
        }
        ToolbarItem(id: "probe.sD", placement: .primaryAction) {
            Button {} label: { Image(systemName: "d.circle") }
        }
    }

    @ToolbarContentBuilder
    private var groupB: some ToolbarContent {
        if variant == .automaticRun { automaticRunItems }
        if variant == .searchSquashed { searchSquashedItems }
        if variant == .searchAccessoryBar { searchAccessoryBarItems }
        if usesStandardItems { standardItems }
    }

    /// Everything that is not one of the purpose-built arrangements above.
    private var usesStandardItems: Bool {
        switch variant {
        case .placementMap, .groupingRules, .toggleSymmetry, .crowded,
            .principalAllTrailing, .automaticRun, .searchSquashed, .searchAccessoryBar,
            .spacerNone, .spacerFixedDefault, .spacerFixedPrimary, .spacerFlexPrimary,
            .spacerSharedHidden, .groupPair, .groupPairSpacer, .menuInRun,
            .glyphOnly, .glyphSidebar, .glyphRemoveInner,
            .searchAtNavigation, .searchAtStatus, .searchAtDestructive, .searchAtConfirmation,
            .glyphToggle:
            return false
        default:
            return true
        }
    }

    @ToolbarContentBuilder
    private var automaticRunItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .automatic) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        ToolbarItem(id: "probe.share", placement: .automatic) {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
        }
        ToolbarSpacer(.flexible, placement: .automatic)
        DefaultToolbarItem(kind: .search, placement: .automatic)
    }

    @ToolbarContentBuilder
    private var searchSquashedItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .primaryAction) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        ToolbarSpacer(.flexible, placement: .primaryAction)
        DefaultToolbarItem(kind: .search, placement: .primaryAction)
        ToolbarSpacer(.flexible, placement: .primaryAction)
    }

    @ToolbarContentBuilder
    private var searchAccessoryBarItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .primaryAction) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        DefaultToolbarItem(kind: .search, placement: .accessoryBar(id: "probe.accessory"))
    }

    @ToolbarContentBuilder
    private var standardItems: some ToolbarContent {
        ToolbarItem(id: "probe.trash", placement: .primaryAction) {
            Button(role: .destructive) {} label: { Image(systemName: "trash") }
        }
        ToolbarItem(id: "probe.share", placement: .primaryAction) {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
        }
        if variant == .flexibleSpacer {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        } else {
            ToolbarSpacer(.fixed)
        }
        if variant == .defaultItemPrincipal {
            DefaultToolbarItem(kind: .search, placement: .principal)
        }
        if variant == .customField {
            ToolbarItem(id: "probe.customSearch", placement: .principal) {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
        }
    }

    /// Ten items in the primary run, so the toolbar runs out of room and the
    /// system has to decide what to do with the search field.
    @ToolbarContentBuilder
    private var crowdedItems: some ToolbarContent {
        ToolbarItem(id: "probe.c1", placement: .primaryAction) {
            Button {} label: { Image(systemName: "1.circle") }
        }
        ToolbarItem(id: "probe.c2", placement: .primaryAction) {
            Button {} label: { Image(systemName: "2.circle") }
        }
        ToolbarItem(id: "probe.c3", placement: .primaryAction) {
            Button {} label: { Image(systemName: "3.circle") }
        }
        ToolbarItem(id: "probe.c4", placement: .primaryAction) {
            Button {} label: { Image(systemName: "4.circle") }
        }
        ToolbarItem(id: "probe.c5", placement: .primaryAction) {
            Button {} label: { Image(systemName: "5.circle") }
        }
        ToolbarItem(id: "probe.c6", placement: .primaryAction) {
            Button {} label: { Image(systemName: "6.circle") }
        }
        ToolbarItem(id: "probe.c7", placement: .primaryAction) {
            Button {} label: { Image(systemName: "7.circle") }
        }
        ToolbarItem(id: "probe.c8", placement: .primaryAction) {
            Button {} label: { Image(systemName: "8.circle") }
        }
        ToolbarItem(id: "probe.c9", placement: .primaryAction) {
            Button {} label: { Image(systemName: "9.circle") }
        }
        ToolbarItem(id: "probe.c10", placement: .primaryAction) {
            Button {} label: { Image(systemName: "10.circle") }
        }
    }

    /// One numbered glyph per macOS-available placement. Read the capture and
    /// the numbers tell you which region each placement resolves to.
    ///
    ///   1 navigation · 2 principal · 3 automatic · 4 primaryAction
    ///   5 secondaryAction · 6 status · 7 destructiveAction
    ///   8 cancellationAction · 9 confirmationAction · 10 accessoryBar
    @ToolbarContentBuilder
    private var placementMapItems: some ToolbarContent {
        ToolbarItem(id: "probe.p1", placement: .navigation) {
            Button {} label: { Image(systemName: "1.circle") }
        }
        ToolbarItem(id: "probe.p2", placement: .principal) {
            Button {} label: { Image(systemName: "2.circle") }
        }
        ToolbarItem(id: "probe.p3", placement: .automatic) {
            Button {} label: { Image(systemName: "3.circle") }
        }
        ToolbarItem(id: "probe.p4", placement: .primaryAction) {
            Button {} label: { Image(systemName: "4.circle") }
        }
        ToolbarItem(id: "probe.p5", placement: .secondaryAction) {
            Button {} label: { Image(systemName: "5.circle") }
        }
        ToolbarItem(id: "probe.p6", placement: .status) {
            Button {} label: { Image(systemName: "6.circle") }
        }
        ToolbarItem(id: "probe.p7", placement: .destructiveAction) {
            Button {} label: { Image(systemName: "7.circle") }
        }
        ToolbarItem(id: "probe.p8", placement: .cancellationAction) {
            Button {} label: { Image(systemName: "8.circle") }
        }
        ToolbarItem(id: "probe.p9", placement: .confirmationAction) {
            Button {} label: { Image(systemName: "9.circle") }
        }
        ToolbarItem(id: "probe.p10", placement: .accessoryBar(id: "probe.map")) {
            Button {} label: { Image(systemName: "10.circle") }
        }
    }

    /// Four adjacent pairs in one placement run, separated four different ways,
    /// so the capture shows exactly what makes one capsule and what makes two.
    ///
    ///   A B   — nothing between them
    ///   C | D — ToolbarSpacer(.fixed)
    ///   E   F — ToolbarSpacer(.flexible)
    ///   G H   — H carries sharedBackgroundVisibility(.hidden)
    @ToolbarContentBuilder
    private var groupingRuleItems: some ToolbarContent {
        ToolbarItem(id: "probe.gA", placement: .primaryAction) {
            Button {} label: { Image(systemName: "a.circle") }
        }
        ToolbarItem(id: "probe.gB", placement: .primaryAction) {
            Button {} label: { Image(systemName: "b.circle") }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "probe.gC", placement: .primaryAction) {
            Button {} label: { Image(systemName: "c.circle") }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(id: "probe.gD", placement: .primaryAction) {
            Button {} label: { Image(systemName: "d.circle") }
        }
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(id: "probe.gE", placement: .primaryAction) {
            Button {} label: { Image(systemName: "e.circle") }
        }
        ToolbarItem(id: "probe.gF", placement: .primaryAction) {
            Button {} label: { Image(systemName: "f.circle") }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "probe.gG", placement: .primaryAction) {
            Button {} label: { Image(systemName: "g.circle") }
        }
    }
}

/// `.searchable` declared on the NavigationSplitView root.
struct RootSearchModifier: ViewModifier {
    let variant: Variant
    @Binding var query: String

    func body(content: Content) -> some View {
        switch variant {
        // Variants whose search is declared elsewhere (inspector, detail) or
        // not at all.
        case .customField, .placementMap, .groupingRules, .toggleSymmetry,
            .inspectorToolbar, .inspectorPrincipal, .inspectorSidebar, .inspectorAutomatic,
            .detailSidebarPlacement, .spacerNone, .spacerFixedDefault, .spacerFixedPrimary,
            .spacerFlexPrimary, .spacerSharedHidden, .absorbedToggle,
            .groupPair, .groupPairSpacer, .menuInRun,
            // Round 4 asks about the inspector's content container, not about
            // search; leaving search off keeps those captures to one variable.
            .inspectorForm, .inspectorTabView, .inspectorTabViewGrouped,
            .inspectorTabViewSidebarAdaptable, .inspectorPickerPanes, .runOrder:
            content
        case .automaticRun, .searchSquashed, .searchAccessoryBar:
            // The item is positioned by the explicit `DefaultToolbarItem`
            // declared in the toolbar; `.searchable` only supplies it.
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        // `SearchToolbarBehavior.minimize` is `@available(macOS, unavailable)`
        // in the macOS 26.4 SDK — it does not compile here at all. `.automatic`
        // is the only value macOS accepts, so these variants can only show what
        // `.automatic` does. Verified against the SDK swiftinterface, not recalled.
        case .minimizeWithInspector, .minimize:
            content
                .searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
                .searchToolbarBehavior(.automatic)
        case .principal, .principalToggleLast, .principalAllTrailing:
            content.searchable(text: $query, placement: .toolbarPrincipal, prompt: "Name, driver")
        case .principalMinimize:
            content
                .searchable(text: $query, placement: .toolbarPrincipal, prompt: "Name, driver")
                .searchToolbarBehavior(.automatic)
        case .sidebarPlacement:
            content.searchable(text: $query, placement: .sidebar, prompt: "Name, driver")
        case .glyphOnly:
            // `.toolbar(removing: .search)` drops the system's search item from
            // the bar. Does `.searchable` still install ⌘F and the Find menu?
            content
                .searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
                .toolbar(removing: .search)
        case .glyphSidebar:
            content
                .searchable(text: $query, placement: .sidebar, prompt: "Name, driver")
        case .glyphRemoveInner:
            content
                .toolbar(removing: .search)
                .searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        case .searchAtNavigation, .searchAtStatus, .searchAtDestructive, .searchAtConfirmation:
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        case .glyphToggle:
            content
        case .automaticPlacement:
            content.searchable(text: $query, placement: .automatic, prompt: "Name, driver")
        case .trailing, .defaultItemPrincipal, .flexibleSpacer, .crowded:
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        }
    }
}

/// `.searchable` attached only while a search is running. Applying a stock
/// modifier conditionally is not a custom control: the system still draws the
/// field, the prompt, the clear button and the focus ring.
struct ConditionalSearchModifier: ViewModifier {
    let active: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if active {
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        } else {
            content
        }
    }
}

/// `.searchable` declared on the inspector's own content — the central question
/// of round 2. If SwiftUI can render a search field inside a pane, one of these
/// four spellings is where it would appear.
struct InspectorSearchModifier: ViewModifier {
    let variant: Variant
    @Binding var query: String

    func body(content: Content) -> some View {
        switch variant {
        case .inspectorToolbar:
            content.searchable(text: $query, placement: .toolbar, prompt: "In inspector")
        case .inspectorPrincipal:
            content.searchable(text: $query, placement: .toolbarPrincipal, prompt: "In inspector")
        case .inspectorSidebar:
            content.searchable(text: $query, placement: .sidebar, prompt: "In inspector")
        case .inspectorAutomatic:
            content.searchable(text: $query, placement: .automatic, prompt: "In inspector")
        default:
            content
        }
    }
}

/// Counts how many times this subtree has been created. Read it off the capture.
struct IdentityCanary: View {
    @State private var appearances = 0

    var body: some View {
        LabeledContent("Appearances", value: "\(appearances)")
            .onAppear { appearances += 1 }
    }
}

// MARK: - App

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--test-cmdf") {
            // Synthesize ⌘F in-process and hand it to the window. This needs no
            // Accessibility permission and no keyboard driving: it asks the real
            // responder chain the exact question "is ⌘F bound to anything here?".
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 })
                else { print("no window"); exit(1) }
                print("before: firstResponder = \(type(of: window.firstResponder))")
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "f", charactersIgnoringModifiers: "f",
                    isARepeat: false, keyCode: 3)!
                let handled = window.performKeyEquivalent(with: event)
                print("performKeyEquivalent(cmd-F) = \(handled)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    print("after:  firstResponder = \(type(of: window.firstResponder))")
                    exit(0)
                }
            }
        }
        if CommandLine.arguments.contains("--dump-menu") {
            // Walk the real main menu and print every key equivalent. This is
            // how we check that ⌘F survived a change without needing to drive
            // the keyboard: the menu is the system's own record of the command.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                func walk(_ menu: NSMenu, _ path: String) {
                    for item in menu.items {
                        let key = item.keyEquivalent
                        let mods = item.keyEquivalentModifierMask
                        var flags = ""
                        if mods.contains(.command) { flags += "cmd-" }
                        if mods.contains(.shift) { flags += "shift-" }
                        if mods.contains(.option) { flags += "opt-" }
                        if !key.isEmpty {
                            print("\(path) > \(item.title)  [\(flags)\(key)] enabled=\(item.isEnabled)")
                        }
                        if let sub = item.submenu { walk(sub, path + " > " + item.title) }
                    }
                }
                if let main = NSApp.mainMenu { walk(main, "") }
                exit(0)
            }
        }
        let size = ProbeArgs.size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 })
            else { return }
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: 60, y: 120))
            window.title = "Probe"
        }
    }
}

enum ProbeArgs {
    static var variant: Variant {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--variant"), i + 1 < args.count,
            let v = Variant(rawValue: args[i + 1])
        else { return .trailing }
        return v
    }

    static var size: NSSize {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--size"), i + 1 < args.count else {
            return NSSize(width: 1600, height: 1000)
        }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return NSSize(width: 1600, height: 1000) }
        return NSSize(width: parts[0], height: parts[1])
    }

    static var scheme: ColorScheme {
        CommandLine.arguments.contains("--light") ? .light : .dark
    }
}

@main
struct ToolProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ProbeContent(variant: ProbeArgs.variant)
                .preferredColorScheme(ProbeArgs.scheme)
        }
        .defaultSize(width: 1600, height: 1000)
    }
}
