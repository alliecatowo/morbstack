import SwiftUI

// UI-051. Search is a magnifying glass in the trailing toolbar group, next to the
// inspector toggle — not a field pinned across the inspector's column.
//
// Everything here is stock SwiftUI. There is no hand-built search control, no
// `NSViewRepresentable`, and no imitation of a system behaviour: when a search is
// running the field is the system's own `.searchable` field, with its own prompt,
// clear button, focus ring and Escape handling. The only thing this file decides is
// *when* that modifier is attached.
//
// Why it has to be decided at all, established with `docs/design/probes/ToolProbe.swift`
// against the macOS 26.4 SDK on 2026-08-06 — do not re-derive:
//
//   * `.searchToolbarBehavior(.minimize)`, the collapse-to-a-glyph behaviour, is
//     `@available(macOS, unavailable)`. It does not compile. (SDK swiftinterface,
//     `SearchToolbarBehavior.minimize`.)
//   * `.toolbar(removing: .search)` is inert for a `.searchable`-supplied item, in
//     either modifier order. The field stays.
//   * `DefaultToolbarItem(kind: .search, placement:)` cannot move or resize the field:
//     `.navigation`, `.status`, `.destructiveAction`, `.confirmationAction`,
//     `.accessoryBar(id:)` and flexible spacers on both sides all produced a
//     byte-identical 333pt field at the window's trailing edge.
//   * `.searchable` declared on the inspector's own content does NOT render inside the
//     inspector — SwiftUI hoists it to the window toolbar. Same for `.toolbar`,
//     `.toolbarPrincipal`, `.sidebar` and `.automatic` from that position.
//   * The system does render search as a glyph in its own capsule — exactly what Finder
//     shows — but only when the toolbar has genuinely run out of room. There is no API
//     to ask for it.
//
// So the field cannot be made a glyph, but it can be made *absent*, and a plain
// `Button` with a `magnifyingglass` symbol is a first-class toolbar item that the
// system draws in the same glass capsule as its neighbours. That is this design.
//
// Applying the modifier conditionally is safe for view identity: a `ViewModifier`
// branches around its own `content`, which SwiftUI resolves to the same underlying
// view in both branches. Verified with an `.onAppear` counter in the probe — it still
// read 1 after a search was activated, so no child `@State` is reset.

/// The trailing-group search glyph.
///
/// Declared by every searchable route immediately before its inspector toggle, so the
/// two view controls sit together at the window's trailing edge, inside the inspector's
/// column. Activating it attaches `RouteSearchModifier`'s `.searchable` and focuses it.
struct RouteSearchToolbarItem: ToolbarContent {
    /// `<route>.search`, matching `docs/design/ACCESSIBILITY-IDENTIFIERS.md`: a toolbar
    /// control reuses its `ToolbarItem(id:)` string verbatim as its identifier.
    let id: String
    /// What the route filters, for the help tag — "Filter images", "Filter volumes".
    let subject: String
    @Binding var isActive: Bool

    var body: some ToolbarContent {
        ToolbarItem(id: id, placement: .primaryAction) {
            Button {
                isActive = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityIdentifier(id)
            .accessibilityLabel("Search \(subject)")
            .help("Search \(subject)")
        }
    }
}

/// Attaches the system search field while a search is running, and takes it away again
/// when the query is empty and the field loses focus.
///
/// The field is `.toolbar`-placed, which is where the HIG puts it on macOS: *"Put a
/// search field at the trailing side of the toolbar for many common uses… particularly
/// apps with split views that need to search across multiple columns of information"*
/// (HIG, Search fields, iPadOS/macOS). It is only ever on screen while someone is
/// actually searching, which is the state Finder's expanded field is in too.
struct RouteSearchModifier: ViewModifier {
    @Binding var isActive: Bool
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        conditionallySearchable(content)
            .searchFocused($focused)
            .onChange(of: isActive) { _, active in
                // One turn of the runloop: the field has to exist before it can take
                // focus, and it is created by this same state change.
                guard active else { return }
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: focused) { _, isFocused in
                // Leaving an empty field puts the glyph back. A non-empty query keeps
                // the field on screen, because the list is still filtered and hiding
                // the reason would be a lie about what the table is showing.
                if !isFocused && text.isEmpty { isActive = false }
            }
    }

    @ViewBuilder
    private func conditionallySearchable(_ content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, placement: .toolbar, prompt: prompt)
        } else {
            content
        }
    }
}

extension View {
    /// Route search: a glyph at rest, the system's own field while searching.
    ///
    /// Applied at the same place the unconditional `.searchable` used to be — on the
    /// inspector's content — so the search scope is unchanged.
    func routeSearchable(
        isActive: Binding<Bool>,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        modifier(RouteSearchModifier(isActive: isActive, text: text, prompt: prompt))
    }
}
