// ToolProbe — stock SwiftUI, zero Morbstack code.
// Answers: can the system search field be placed anywhere other than the
// window's trailing edge on macOS 26, and if so what sits trailing of it?
//
// Variant selected with `--variant <name>`; window size with `--size WxH`.

import AppKit
import SwiftUI

// MARK: - Variants

enum Variant: String, CaseIterable {
    /// Current Morbstack shape: system search trailing, custom cluster before it.
    case trailing
    /// `.searchable(placement: .toolbarPrincipal)` — search in the centre region.
    case principal
    /// `.searchable(placement: .toolbar)` + `DefaultToolbarItem(kind: .search, placement: .principal)`.
    case defaultItemPrincipal
    /// `.searchable(placement: .toolbar)` + `.searchToolbarBehavior(.minimize)`.
    case minimize
    /// principal + minimize together.
    case principalMinimize
    /// `ToolbarSpacer(.flexible, placement: .primaryAction)` between the two groups.
    case flexibleSpacer
    /// Hand-rolled TextField in `ToolbarItem(placement: .principal)`, no `.searchable`.
    case customField
    /// principal search, and the inspector toggle declared LAST in the primary run.
    case principalToggleLast
    /// EVERYTHING in one placement run (`.automatic`): buttons, an explicit
    /// `DefaultToolbarItem(kind: .search)`, and `ToolbarSpacer(.flexible)`
    /// between them. Retests the "spacers are inert" result without the
    /// confound of items living in different placement runs.
    case automaticRun
    /// `.searchToolbarBehavior` driven by inspector state rather than width.
    case minimizeWithInspector
    /// principal search, and ALL four command items mounted on the inspector
    /// content so the whole cluster lands in the inspector's toolbar region.
    case principalAllTrailing
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
    @State private var selection: Int?
    private let rows = (0..<40).map(Row.init(id:))

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(0..<8, id: \.self) { i in
                    Label("Row \(i)", systemImage: "circle").tag(i)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            Table(rows, selection: $selection) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Driver") { _ in Text("local") }
                TableColumn("Size") { _ in Text("128 MB") }
            }
            .inspector(isPresented: $showsInspector) {
                Form {
                    LabeledContent("Variant", value: variant.rawValue)
                    LabeledContent("Query", value: query.isEmpty ? "—" : query)
                }
                .formStyle(.grouped)
                .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
                .toolbar { trailingCluster }
                .modifier(
                    SearchModifier(
                        variant: variant, query: $query, showsInspector: showsInspector))
            }
        }
        .navigationTitle("Probe")
        .toolbar { leadingAndCentre }
    }

    // Two visually distinct groups plus the inspector toggle, matching the
    // Morbstack shape: a destructive glyph, a share glyph, a create glyph, then
    // the toggle.
    @ToolbarContentBuilder
    private var trailingCluster: some ToolbarContent {
        if variant == .principalAllTrailing {
            ToolbarItem(id: "probe.trash", placement: .primaryAction) {
                Button(role: .destructive) { } label: { Image(systemName: "trash") }
            }
            ToolbarItem(id: "probe.share", placement: .primaryAction) {
                Button { } label: { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem(id: "probe.create", placement: .primaryAction) {
            Button { } label: { Image(systemName: "plus") }
        }
        if variant == .principalToggleLast || variant == .principalAllTrailing {
            ToolbarItem(id: "probe.inspector", placement: .primaryAction) {
                Button { showsInspector.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
            }
        } else {
            ToolbarItem(id: "probe.inspector", placement: .automatic) {
                Button { showsInspector.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var leadingAndCentre: some ToolbarContent {
        if variant == .principalAllTrailing {
            // Nothing on the root toolbar: every command lives on the
            // inspector's toolbar so the cluster is one island.
            ToolbarItem(id: "probe.none", placement: .principal) { EmptyView() }
        } else if variant == .automaticRun {
            // One placement run, nothing else: two buttons, a flexible spacer,
            // then the system search item — the arrangement that would put the
            // pills left of a centred search if spacers act inside a run.
            ToolbarItem(id: "probe.trash", placement: .automatic) {
                Button(role: .destructive) { } label: { Image(systemName: "trash") }
            }
            ToolbarItem(id: "probe.share", placement: .automatic) {
                Button { } label: { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarSpacer(.flexible, placement: .automatic)
            DefaultToolbarItem(kind: .search, placement: .automatic)
        } else {
            ToolbarItem(id: "probe.trash", placement: .primaryAction) {
                Button(role: .destructive) { } label: { Image(systemName: "trash") }
            }
            ToolbarItem(id: "probe.share", placement: .primaryAction) {
                Button { } label: { Image(systemName: "square.and.arrow.up") }
            }
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
}

/// Keeps every `.searchable` spelling in one place so the variants differ by
/// exactly one modifier.
struct SearchModifier: ViewModifier {
    let variant: Variant
    @Binding var query: String
    let showsInspector: Bool

    func body(content: Content) -> some View {
        switch variant {
        case .customField:
            content
        case .automaticRun:
            // The search item is positioned by the explicit `DefaultToolbarItem`
            // declared in the same run; `.searchable` only supplies it.
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        // `SearchToolbarBehavior.minimize` is `@available(macOS, unavailable)`
        // in the macOS 26.4 SDK — it does not compile here at all. `.automatic`
        // is the only value macOS accepts, so these three variants can only
        // show what `.automatic` does.
        case .minimizeWithInspector:
            content
                .searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
                .searchToolbarBehavior(.automatic)
        case .principal, .principalToggleLast, .principalAllTrailing:
            content.searchable(text: $query, placement: .toolbarPrincipal, prompt: "Name, driver")
        case .principalMinimize:
            content
                .searchable(text: $query, placement: .toolbarPrincipal, prompt: "Name, driver")
                .searchToolbarBehavior(.automatic)
        case .minimize:
            content
                .searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
                .searchToolbarBehavior(.automatic)
        default:
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        }
    }
}

// MARK: - App

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
}

@main
struct ToolProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ProbeContent(variant: ProbeArgs.variant)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1600, height: 1000)
    }
}
