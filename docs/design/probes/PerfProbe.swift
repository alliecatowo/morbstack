// PerfProbe — stock SwiftUI, zero Morbstack code, one question:
//
//   What, exactly, costs the several hundred milliseconds of blocked main thread
//   when a `NavigationSplitView` column is toggled? (UI-056)
//
// `ToolProbe.swift` established THAT the cost exists. This binary exists to
// SUBTRACT: every ingredient of the window shape is an independent axis, so a
// variant can be built with a toolbar and without one, with 500 rows and with
// five, with a ranged `.inspectorColumnWidth` and a fixed one, and the numbers
// compared directly.
//
// ## How the number is measured
//
// A `Timer` on the main run loop in `.common` mode at 2ms with zero tolerance.
// A timer cannot fire while the main thread is inside a synchronous AppKit
// layout pass, so the largest gap between consecutive ticks after a toggle IS
// the unbroken main-thread block. This is the same quantity Instruments reported
// for the earlier round (an unbroken run of samples on the main thread), read
// directly and cheaply enough to run a whole matrix.
//
// A smooth animation produces no gap larger than a frame (~8–17ms); a block
// produces one gap of the block's whole length. The two are unambiguous.
//
//   --perf key=value,key=value…   the shape (see PerfConfig)
//   --cycles N                    toggles to perform (default 8)
//   --settle S                    seconds to wait after launch (default 3.5)
//   --size WxH                    window content size (default 1600x1000)
//   --resize                      resize sweep instead of column toggles
//   --hold                        never exit; print gaps live (for AXPress runs)
//   --light                       light appearance

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Stall meter

/// Records main-run-loop tick times and reports the largest unbroken gap that
/// follows each marked event. Nothing here touches the view tree.
final class Bench: @unchecked Sendable {
    static let shared = Bench()

    /// Set by the view once it is on screen.
    var toggleInspector: (() -> Void)?
    var toggleSidebar: (() -> Void)?

    private var ticks: [Double] = []
    private var frames: [Double] = []
    private var events: [(name: String, at: Double)] = []
    private var timer: Timer?
    private var displayLink: CADisplayLink?
    private var live = false
    private var lastPrinted = 0

    private let tick = 0.002
    /// A gap this big or bigger is not a dropped frame, it is a block.
    private let blockFloor = 0.030

    func start(live: Bool) {
        self.live = live
        ticks.reserveCapacity(400_000)
        frames.reserveCapacity(40_000)
        let t = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks.append(CACurrentMediaTime())
            if self.live { self.drainLive() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Frame delivery, independently of the tick meter. A display link fires
        // once per display refresh ON THE MAIN THREAD, so a callback that never
        // arrives is a frame the window could not have drawn. This is the
        // quantity the earlier round did not measure: an animation can be
        // starved of frames without any single long block.
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(onFrame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        frames.append(CACurrentMediaTime())
    }

    /// In `--hold` mode there is nobody to call `report()`, so print blocks as
    /// they are observed. This is the mode an external AXPress driver reads.
    private func drainLive() {
        while lastPrinted + 1 < ticks.count {
            let gap = ticks[lastPrinted + 1] - ticks[lastPrinted]
            if gap >= blockFloor {
                print(
                    String(
                        format: "BLOCK at=%.3f ms=%.1f", ticks[lastPrinted], gap * 1000))
                fflush(stdout)
            }
            lastPrinted += 1
        }
    }

    func mark(_ name: String) {
        let now = CACurrentMediaTime()
        events.append((name, now))
        // CPU burnt by the transition, sampled the same way `axpress-cost.sh`
        // samples the shipped app from outside. Keeping both numbers side by
        // side is the whole point: CPU says how much work the transition does,
        // `lead` says whether any of it lands in one unbroken block. The
        // earlier round only ever had the first, and read it as the second.
        let index = events.count - 1
        let cpu0 = Self.cpuSeconds()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.cpu[index] = Self.cpuSeconds() - cpu0
        }
        if live {
            print(String(format: "MARK %@ at=%.3f", name, now))
            fflush(stdout)
        }
    }

    private var cpu: [Int: Double] = [:]

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + sys
    }

    /// The window after an event in which its cost must show up. Generous: the
    /// block observed so far always starts within a few ms of the state change.
    private let window = 1.4
    /// How long the reveal animation itself is given. Frame delivery is judged
    /// over this, because that is the interval a person actually watches.
    private let animation = 0.6

    struct Measurement {
        /// The first unbroken block after the event — the "pops instead of
        /// slides" cost, and the only thing the earlier round measured.
        var lead = 0.0
        /// The worst block AFTER that one, still inside the animation. This is
        /// frame starvation while the animation runs: invisible to a
        /// lead-block-only metric, and the thing a person sees as stutter.
        var post = 0.0
        /// Time lost to over-frame gaps across the whole window.
        var stall = 0.0
        /// Number of over-frame gaps.
        var hitches = 0
        /// Display-link callbacks actually delivered during the animation, and
        /// how many the display offered in the same interval.
        var framesSeen = 0
        var framesExpected = 0
        /// Process CPU burnt in the 0.9s after the event.
        var cpu = 0.0
    }

    func report(label: String) {
        print("")
        print("=== \(label) ===")
        print("event            lead(ms)  post(ms)  stall(ms)  hitches  frames    cpu(ms)")
        var byKind: [String: [Measurement]] = [:]
        for (index, event) in events.enumerated() {
            var m = analyse(from: event.at)
            m.cpu = cpu[index] ?? 0
            print(
                String(
                    format: "%-16s %8.1f %9.1f %10.1f %8d  %3d/%-3d %9.1f",
                    (event.name as NSString).utf8String!, m.lead * 1000, m.post * 1000,
                    m.stall * 1000, m.hitches, m.framesSeen, m.framesExpected, m.cpu * 1000))
            byKind[String(event.name.prefix(while: { $0 != "#" })), default: []].append(m)
        }
        print("")
        for (kind, values) in byKind.sorted(by: { $0.key < $1.key }) {
            print(
                String(
                    format:
                        "SUMMARY %@ n=%d lead=%.1fms post=%.1fms stall=%.1fms hitches=%.1f frames=%.0f%% cpu=%.1fms",
                    kind, values.count,
                    median(values.map(\.lead)) * 1000,
                    median(values.map(\.post)) * 1000,
                    median(values.map(\.stall)) * 1000,
                    median(values.map { Double($0.hitches) }),
                    100 * median(
                        values.map {
                            $0.framesExpected == 0
                                ? 0 : Double($0.framesSeen) / Double($0.framesExpected)
                        }),
                    median(values.map(\.cpu)) * 1000))
        }
        fflush(stdout)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func analyse(from start: Double) -> Measurement {
        var m = Measurement()
        var i = 0
        // Skip to the last tick at or before the event.
        while i + 1 < ticks.count && ticks[i + 1] <= start { i += 1 }
        var sawLead = false
        while i + 1 < ticks.count && ticks[i] <= start + window {
            let gap = ticks[i + 1] - ticks[i]
            if gap > 0.016 {
                m.hitches += 1
                m.stall += gap - tick
            }
            if gap >= blockFloor {
                if !sawLead {
                    m.lead = gap
                    sawLead = true
                } else if ticks[i] <= start + animation, gap > m.post {
                    m.post = gap
                }
            }
            i += 1
        }
        m.framesSeen = frames.count(where: { $0 >= start && $0 <= start + animation })
        // What the display offered: measured from the link's own steady-state
        // cadence over the quiet second before the event, so this adapts to
        // whatever refresh rate the panel is running at.
        let quiet = frames.count(where: { $0 >= start - 1.0 && $0 < start })
        m.framesExpected = Int((Double(quiet) * animation).rounded())
        return m
    }
}

// MARK: - Config

enum PerfDetail: String { case text, list5, list100, list500, table5, table40, table100, table500 }
enum PerfInspector: String { case none, text, form3, form30 }
enum PerfInspWidth: String { case none, range, fixed }
enum PerfToolbar: String {
    case none, btn1, btn3, menu1, menu1btn3, spacer3, toggle, full
}
enum PerfMount: String { case root, insp }
enum PerfSidebar: String { case text, list8 }
enum PerfToggle: String { case insp, sidebar }

/// How a list of rows that each show a once-a-second value gets its clock.
/// This is the axis the Morbstack change in `caab2f9` moved: from `per` (one
/// `TimelineView` inside every row) to `shared` (one around the whole list).
enum PerfRowClock: String {
    /// No clock at all — static rows.
    case none
    /// One `TimelineView(.periodic(by: 1))` wrapping the whole list, its date
    /// threaded into each row as a plain value.
    case shared
    /// One `TimelineView(.periodic(by: 1))` inside each row.
    case per
}

struct PerfConfig {
    var detail: PerfDetail = .table40
    var inspector: PerfInspector = .form3
    var inspWidth: PerfInspWidth = .none
    var toolbar: PerfToolbar = .none
    var mount: PerfMount = .insp
    var sidebar: PerfSidebar = .list8
    var search = false
    var title = true
    var toggle: PerfToggle = .insp
    var rowClock: PerfRowClock = .none
    /// Whether the toggled column is already presented when the window opens.
    /// The real routes default the inspector to OPEN; the earlier probe round
    /// launched it `--closed`. That difference was never varied, and it is the
    /// whole of the "close is free on Containers, expensive in the probe"
    /// asymmetry.
    var startOpen = false
    var label = ""

    static func parse(_ args: [String]) -> PerfConfig {
        var cfg = PerfConfig()
        guard let i = args.firstIndex(of: "--perf"), i + 1 < args.count else { return cfg }
        cfg.label = args[i + 1]
        for pair in args[i + 1].split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1])
            switch key {
            case "detail": cfg.detail = PerfDetail(rawValue: value) ?? cfg.detail
            case "insp": cfg.inspector = PerfInspector(rawValue: value) ?? cfg.inspector
            case "inspw": cfg.inspWidth = PerfInspWidth(rawValue: value) ?? cfg.inspWidth
            case "tb": cfg.toolbar = PerfToolbar(rawValue: value) ?? cfg.toolbar
            case "mount": cfg.mount = PerfMount(rawValue: value) ?? cfg.mount
            case "sidebar": cfg.sidebar = PerfSidebar(rawValue: value) ?? cfg.sidebar
            case "search": cfg.search = value == "on"
            case "title": cfg.title = value == "on"
            case "toggle": cfg.toggle = PerfToggle(rawValue: value) ?? cfg.toggle
            case "rowclock": cfg.rowClock = PerfRowClock(rawValue: value) ?? cfg.rowClock
            case "start": cfg.startOpen = value == "open"
            default: break
            }
        }
        return cfg
    }
}

enum PerfArgs {
    static let args = CommandLine.arguments

    static func int(_ flag: String, _ fallback: Int) -> Int {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Int(args[i + 1]) else {
            return fallback
        }
        return v
    }

    static func double(_ flag: String, _ fallback: Double) -> Double {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Double(args[i + 1])
        else { return fallback }
        return v
    }

    static var size: NSSize {
        guard let i = args.firstIndex(of: "--size"), i + 1 < args.count else {
            return NSSize(width: 1600, height: 1000)
        }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return NSSize(width: 1600, height: 1000) }
        return NSSize(width: parts[0], height: parts[1])
    }

    static var hold: Bool { args.contains("--hold") }
    static var resize: Bool { args.contains("--resize") }
    static var scheme: ColorScheme { args.contains("--light") ? .light : .dark }
}

// MARK: - Rows

struct PerfRow: Identifiable {
    let id: Int
    var name: String { "item-\(id)" }
}

// MARK: - Toolbar

/// Every toolbar shape lives behind one modifier so it can be mounted on the
/// route root or on the inspector's own content without duplicating it.
struct PerfToolbarModifier: ViewModifier {
    let shape: PerfToolbar
    let search: Bool
    @Binding var query: String
    @Binding var showsInspector: Bool

    func body(content: Content) -> some View {
        content
            .modifier(PerfToolbarItemsModifier(shape: shape, showsInspector: $showsInspector))
            .modifier(PerfSearchableModifier(search: search, query: $query))
    }
}

struct PerfSearchableModifier: ViewModifier {
    let search: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if search {
            content.searchable(text: $query, placement: .toolbar, prompt: "Name, driver")
        } else {
            content
        }
    }
}

struct PerfToolbarItemsModifier: ViewModifier {
    let shape: PerfToolbar
    @Binding var showsInspector: Bool

    func body(content: Content) -> some View {
        if shape == .none {
            content
        } else {
            content.toolbar { items }
        }
    }

    @ToolbarContentBuilder
    private var items: some ToolbarContent {
        if shape == .menu1 || shape == .menu1btn3 || shape == .full {
            ToolbarItem(id: "perf.menu", placement: .primaryAction) {
                Menu {
                    Button("One") {}
                    Button("Two") {}
                    Divider()
                    Button("Three") {}
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
            }
        }
        if shape == .btn1 {
            ToolbarItem(id: "perf.a", placement: .primaryAction) {
                Button {} label: { Image(systemName: "a.circle") }
            }
        }
        if shape == .btn3 || shape == .menu1btn3 || shape == .spacer3 || shape == .full {
            ToolbarItem(id: "perf.a", placement: .primaryAction) {
                Button {} label: { Image(systemName: "a.circle") }
            }
            ToolbarItem(id: "perf.b", placement: .primaryAction) {
                Button {} label: { Image(systemName: "b.circle") }
            }
            ToolbarItem(id: "perf.c", placement: .primaryAction) {
                Button {} label: { Image(systemName: "c.circle") }
            }
        }
        if shape == .spacer3 || shape == .full {
            ToolbarSpacer(.fixed)
        }
        if shape == .toggle || shape == .full {
            ToolbarItem(id: "perf.inspector", placement: .primaryAction) {
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .accessibilityIdentifier("perf.inspector")
            }
        }
    }
}

// MARK: - Inspector width

struct PerfInspectorWidthModifier: ViewModifier {
    let width: PerfInspWidth

    func body(content: Content) -> some View {
        switch width {
        case .none: content
        case .range: content.inspectorColumnWidth(min: 340, ideal: 400, max: 520)
        case .fixed: content.inspectorColumnWidth(400)
        }
    }
}

// MARK: - Inspector presentation

struct PerfInspectorModifier: ViewModifier {
    let cfg: PerfConfig
    @Binding var showsInspector: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if cfg.inspector == .none {
            content
        } else {
            content.inspector(isPresented: $showsInspector) {
                PerfInspectorContent(kind: cfg.inspector)
                    .modifier(
                        PerfMountedToolbar(
                            cfg: cfg, on: .insp, query: $query, showsInspector: $showsInspector)
                    )
                    // Outermost on the inspector's content, exactly as the routes
                    // declare it (see ContainersRootView).
                    .modifier(PerfInspectorWidthModifier(width: cfg.inspWidth))
            }
        }
    }
}

/// Applies the toolbar only when this is the configured mount point.
struct PerfMountedToolbar: ViewModifier {
    let cfg: PerfConfig
    let on: PerfMount
    @Binding var query: String
    @Binding var showsInspector: Bool

    func body(content: Content) -> some View {
        if cfg.mount == on {
            content.modifier(
                PerfToolbarModifier(
                    shape: cfg.toolbar, search: cfg.search, query: $query,
                    showsInspector: $showsInspector))
        } else {
            content
        }
    }
}

struct PerfInspectorContent: View {
    let kind: PerfInspector

    var body: some View {
        switch kind {
        case .none, .text:
            Text("inspector")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .form3:
            Form {
                LabeledContent("One", value: "1")
                LabeledContent("Two", value: "2")
                LabeledContent("Three", value: "3")
            }
            .formStyle(.grouped)
        case .form30:
            Form {
                ForEach(0..<30, id: \.self) { i in
                    LabeledContent("Field \(i)", value: "value \(i)")
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Detail

struct PerfDetailContent: View {
    let kind: PerfDetail
    let rowClock: PerfRowClock
    @Binding var selection: Int?

    var body: some View {
        switch kind {
        case .text:
            Text("detail")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .list5: list(5)
        case .list100: list(100)
        case .list500: list(500)
        case .table5: table(5)
        case .table40: table(40)
        case .table100: table(100)
        case .table500: table(500)
        }
    }

    /// The three clock shapes, all stock SwiftUI. `per` is the shape
    /// `ContainersRootView` shipped until 2026-08-07: every visible row holds
    /// its own `TimelineView` and therefore its own AttributeGraph
    /// subscription. `shared` is the shape it holds now: one clock for the
    /// list, its date passed down as a plain value.
    @ViewBuilder
    private func list(_ n: Int) -> some View {
        switch rowClock {
        case .none:
            List(selection: $selection) {
                ForEach(0..<n, id: \.self) { i in
                    PerfStaticRow(index: i).tag(i)
                }
            }
        case .shared:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List(selection: $selection) {
                    ForEach(0..<n, id: \.self) { i in
                        PerfClockedRow(index: i, now: context.date).tag(i)
                    }
                }
            }
        case .per:
            List(selection: $selection) {
                ForEach(0..<n, id: \.self) { i in
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        PerfClockedRow(index: i, now: context.date)
                    }
                    .tag(i)
                }
            }
        }
    }

    private func table(_ n: Int) -> some View {
        Table((0..<n).map(PerfRow.init(id:)), selection: $selection) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Driver") { _ in Text("local") }
            TableColumn("Size") { _ in Text("128 MB") }
        }
    }
}

/// A row with the same subview count as the clocked one, so the two differ only
/// in where the clock lives.
struct PerfStaticRow: View {
    let index: Int

    var body: some View {
        HStack {
            Image(systemName: "circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("item-\(index)")
                Text("running").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("—").font(.caption).monospacedDigit()
        }
    }
}

struct PerfClockedRow: View {
    let index: Int
    let now: Date

    var body: some View {
        HStack {
            Image(systemName: "circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("item-\(index)")
                Text("running").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(uptime).font(.caption).monospacedDigit()
        }
    }

    private var uptime: String {
        let seconds = Int(now.timeIntervalSince1970) % 3600
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Root

struct PerfContent: View {
    let cfg: PerfConfig
    @State private var showsInspector: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: Int?
    @State private var query = ""

    init(cfg: PerfConfig) {
        self.cfg = cfg
        // Default: start the toggled column hidden so toggle #1 is a reveal.
        // `start=open` is the shape the real routes ship.
        _showsInspector = State(initialValue: cfg.startOpen || cfg.toggle == .sidebar)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            PerfDetailContent(kind: cfg.detail, rowClock: cfg.rowClock, selection: $selection)
                .modifier(
                    PerfInspectorModifier(
                        cfg: cfg, showsInspector: $showsInspector, query: $query))
        }
        .modifier(PerfTitleModifier(on: cfg.title))
        .modifier(
            PerfMountedToolbar(
                cfg: cfg, on: .root, query: $query, showsInspector: $showsInspector)
        )
        .onAppear {
            Bench.shared.toggleInspector = { showsInspector.toggle() }
            Bench.shared.toggleSidebar = {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch cfg.sidebar {
        case .text:
            Text("sidebar")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        case .list8:
            List {
                ForEach(0..<8, id: \.self) { i in
                    Label("Row \(i)", systemImage: "circle")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        }
    }
}

struct PerfTitleModifier: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.navigationTitle("Perf") } else { content }
    }
}

// MARK: - App

final class PerfDelegate: NSObject, NSApplicationDelegate {
    private var cycles = PerfArgs.int("--cycles", 8)
    private var settle = PerfArgs.double("--settle", 3.5)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let size = PerfArgs.size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = Self.probeWindow() else { return }
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: 60, y: 120))
            window.title = "PerfProbe"
        }

        Bench.shared.start(live: PerfArgs.hold)
        guard !PerfArgs.hold else { return }

        if PerfArgs.resize {
            scheduleResizeSweep()
        } else {
            scheduleToggles()
        }
    }

    static func probeWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 300 }
    }

    /// One toggle every 1.6s. Odd toggles reveal, even toggles hide.
    private func scheduleToggles() {
        let cfg = PerfConfig.parse(CommandLine.arguments)
        let step = 1.6
        // If the column is already presented at launch, toggle #1 hides it.
        let startsPresented = cfg.startOpen || cfg.toggle == .sidebar
        for i in 0..<cycles {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle + step * Double(i)) {
                let revealing = (i % 2 == 0) != startsPresented
                let direction = revealing ? "reveal" : "hide"
                Bench.shared.mark("\(direction)#\(i / 2 + 1)")
                switch cfg.toggle {
                case .insp: Bench.shared.toggleInspector?()
                case .sidebar: Bench.shared.toggleSidebar?()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle + step * Double(cycles) + 0.6) {
            Bench.shared.report(label: cfg.label.isEmpty ? "default" : cfg.label)
            exit(0)
        }
    }

    /// Hypothesis D: is a plain width change equally expensive? 40 programmatic
    /// width steps at 16ms, measured with the same meter.
    private func scheduleResizeSweep() {
        let cfg = PerfConfig.parse(CommandLine.arguments)
        let steps = 40
        let base = PerfArgs.size
        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.016 * Double(i)) {
                guard let window = Self.probeWindow() else { return }
                if i == 0 { Bench.shared.mark("resize#1") }
                let delta = CGFloat((i % 20) * 8)
                window.setContentSize(NSSize(width: base.width - delta, height: base.height))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.016 * Double(steps) + 1.6) {
            Bench.shared.report(label: "resize " + cfg.label)
            exit(0)
        }
    }
}

@main
struct PerfProbeApp: App {
    @NSApplicationDelegateAdaptor(PerfDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            PerfContent(cfg: PerfConfig.parse(CommandLine.arguments))
                .preferredColorScheme(PerfArgs.scheme)
        }
        .defaultSize(width: 1600, height: 1000)
    }
}
