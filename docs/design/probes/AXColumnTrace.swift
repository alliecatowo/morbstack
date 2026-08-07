// AXColumnTrace — does a split-view column SLIDE or POP?
//
// The question UI-056 is actually about is a visual one, and every instrument
// used on it so far measured something else: Instruments measured how much
// main-thread work the transition does, which is not the same as whether the
// column interpolates. A column that animates smoothly over 300ms and a column
// that jumps to its final width in one frame can burn identical CPU.
//
// This reads the answer straight off the running window, from outside, through
// the accessibility API — no rebuild, no instrumentation, and it works on
// `dist/Morbstack.app` while somebody else has it open.
//
// It presses a toolbar control by `AXIdentifier` (or toolbar index) and samples
// the geometry of a watched element as fast as the AX IPC allows. A slide shows
// a monotonic ramp of intermediate widths; a pop shows two widths and nothing
// between them.
//
//   swiftc -O AXColumnTrace.swift -o /tmp/axtrace
//   /tmp/axtrace MorbstackApp containers.inspector 1.2
//   /tmp/axtrace PerfProbe '#6' 1.2
//
// Requires the launching terminal to hold Accessibility permission, which it
// already needs for the AppleScript `AXPress` driving used elsewhere here.

import AppKit
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func identifier(_ element: AXUIElement) -> String? {
    attribute(element, kAXIdentifierAttribute as String) as? String
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute as String),
        let sizeValue = attribute(element, kAXSizeAttribute as String)
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

/// Depth-first search for the first descendant matching `match`.
func find(_ root: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if depth > 0 && match(root) { return root }
    guard depth < 24 else { return nil }
    for child in children(root) {
        if let hit = find(child, depth: depth + 1, match) { return hit }
    }
    return nil
}

/// Every leaf-ish element in the window, widest first. Used to pick something
/// worth watching when no identifier is supplied.
func geometryCandidates(_ root: AXUIElement) -> [(String, CGRect)] {
    var out: [(String, CGRect)] = []
    func walk(_ element: AXUIElement, _ path: String, _ depth: Int) {
        guard depth < 14 else { return }
        let role = attribute(element, kAXRoleAttribute as String) as? String ?? "?"
        let ident = identifier(element) ?? ""
        let name = "\(path)/\(role)\(ident.isEmpty ? "" : "[\(ident)]")"
        if let rect = frame(element) { out.append((name, rect)) }
        for child in children(element) { walk(child, name, depth + 1) }
    }
    walk(root, "", 0)
    return out
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: axtrace <process> <AXIdentifier|#toolbarIndex> [seconds] [--list]\n".utf8))
    exit(2)
}
let processName = args[1]
let target = args[2]
let duration = args.count > 3 ? Double(args[3]) ?? 1.2 : 1.2

// A bare `exec` of a bundle's binary — which is how `run-perf.sh` starts the
// probe, so its stdout is the report — is not registered with LaunchServices
// and never appears in `NSWorkspace.runningApplications`. Accept a PID too.
let pid: pid_t
if let literal = pid_t(processName) {
    pid = literal
} else if let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == processName || $0.executableURL?.lastPathComponent == processName
}) {
    pid = app.processIdentifier
} else {
    FileHandle.standardError.write(
        Data("no running process named \(processName) (try passing its pid)\n".utf8))
    exit(1)
}

let axApp = AXUIElementCreateApplication(pid)
guard let windows = attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement],
    let window = windows.first
else {
    FileHandle.standardError.write(Data("no AX window (is Accessibility granted?)\n".utf8))
    exit(1)
}

if args.contains("--list") {
    for (name, rect) in geometryCandidates(window).sorted(by: { $0.1.width > $1.1.width }).prefix(40)
    {
        print(String(format: "%7.1f x %7.1f  @%7.1f  %@", rect.width, rect.height, rect.minX, name))
    }
    exit(0)
}

// The control to press.
let button: AXUIElement?
if target.hasPrefix("#") {
    let index = Int(target.dropFirst()) ?? 1
    let toolbar = find(window) { attribute($0, kAXRoleAttribute as String) as? String == "AXToolbar" }
    let items = toolbar.map(children) ?? []
    button = index - 1 < items.count ? items[index - 1] : nil
} else {
    button = find(window) { identifier($0) == target }
}
guard let button else {
    FileHandle.standardError.write(Data("no control matching \(target)\n".utf8))
    exit(1)
}

// What to watch: the widest scroll area in the window. When the inspector
// column changes width the content column must change width to match, so its
// width is a faithful readout of the divider's position — and unlike the
// inspector itself it exists in both states, so there is no identity change to
// confuse the trace.
guard
    let watched = geometryCandidates(window)
        .filter({ $0.0.contains("AXScrollArea") || $0.0.contains("AXTable") || $0.0.contains("AXList") })
        .max(by: { $0.1.width < $1.1.width })
else {
    FileHandle.standardError.write(Data("nothing to watch in this window\n".utf8))
    exit(1)
}
let watchedName = watched.0
guard
    let watchedElement = find(window, { element in
        guard let rect = frame(element) else { return false }
        return abs(rect.width - watched.1.width) < 0.5 && abs(rect.minX - watched.1.minX) < 0.5
            && (attribute(element, kAXRoleAttribute as String) as? String).map({
                ["AXScrollArea", "AXTable", "AXList", "AXOutline"].contains($0)
            }) == true
    })
else {
    FileHandle.standardError.write(Data("could not re-resolve the watched element\n".utf8))
    exit(1)
}

FileHandle.standardError.write(
    Data("watching \(watchedName) (\(Int(watched.1.width))pt wide)\n".utf8))

var samples: [(Double, CGFloat)] = []
samples.reserveCapacity(4000)
let start = CFAbsoluteTimeGetCurrent()

// Sample for a beat before the press so the resting width is on the record.
while CFAbsoluteTimeGetCurrent() - start < 0.25 {
    if let rect = frame(watchedElement) { samples.append((CFAbsoluteTimeGetCurrent() - start, rect.width)) }
}
let pressedAt = CFAbsoluteTimeGetCurrent() - start
AXUIElementPerformAction(button, kAXPressAction as CFString)
while CFAbsoluteTimeGetCurrent() - start < duration {
    if let rect = frame(watchedElement) { samples.append((CFAbsoluteTimeGetCurrent() - start, rect.width)) }
}

// Report: how many DISTINCT widths were observed between the resting width and
// the settled one. Two means it popped. Many means it slid.
let widths = samples.map(\.1)
let first = widths.first ?? 0
let last = widths.last ?? 0
let distinct = Set(widths.map { ($0 * 2).rounded() / 2 })
let intermediate = distinct.filter { $0 != first && $0 != last }

// An AX read is synchronous IPC serviced on the target's main run loop, so a
// long gap between samples means the TARGET was blocked, not that this process
// was slow. Reporting it is what separates "the width did not change" from "we
// could not see the width change" — two readings of the same flat trace.
var maxSampleGap = 0.0
var maxSampleGapAt = 0.0
for i in 1..<max(samples.count, 1) where samples[i].0 - samples[i - 1].0 > maxSampleGap {
    maxSampleGap = samples[i].0 - samples[i - 1].0
    maxSampleGapAt = samples[i - 1].0
}

print(String(format: "pressed at %.3fs · %d samples over %.2fs", pressedAt, samples.count, duration))
print(
    String(
        format: "slowest AX read: %.1fms at %.3fs (target main thread unresponsive that long)",
        maxSampleGap * 1000, maxSampleGapAt))
print(String(format: "width %.1f -> %.1f · %d distinct widths · %d intermediate",
             first, last, distinct.count, intermediate.count))
print(intermediate.isEmpty
    ? "VERDICT: POP — the column jumped straight to its final width"
    : "VERDICT: SLIDE — \(intermediate.count) intermediate widths were drawn")
print("")
print("trace (only where the width changes):")
var previous = first
for (time, width) in samples where abs(width - previous) > 0.4 {
    print(String(format: "  %6.3fs  %8.1f", time, width))
    previous = width
}
