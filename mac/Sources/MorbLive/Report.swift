// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The PASS/FAIL ledger.
//
// Every check prints the moment it resolves — a live run against a real VM can wedge,
// and a harness that only prints at the end tells you nothing about *where* it wedged.
// The table at the bottom is a reprint, not the first sighting.

import Foundation

/// One resolved check.
struct CheckRow: Sendable {
    var name: String
    var passed: Bool
    /// The observed value, which is the whole point: "PASS" on its own is not evidence.
    var detail: String
}

/// Collects check results and renders the summary table.
///
/// `@unchecked Sendable` behind a lock because checks resolve on whichever thread the
/// stream reader happened to hand them back on.
final class Report: @unchecked Sendable {

    private let lock = NSLock()
    private var rows: [CheckRow] = []

    /// Records an outcome and prints it immediately.
    func record(_ name: String, _ passed: Bool, _ detail: String) {
        lock.lock()
        rows.append(CheckRow(name: name, passed: passed, detail: detail))
        lock.unlock()
        print("\(passed ? "PASS" : "FAIL")  \(name)  —  \(detail)")
        fflush(stdout)
    }

    /// Records `condition`, using `detail` either way: a failure is only actionable if
    /// it says what was actually seen.
    func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
        record(name, condition, detail())
    }

    func fail(_ name: String, _ detail: String) { record(name, false, detail) }

    /// A section heading in the live output. Not a row.
    func section(_ title: String) {
        print("")
        print("── \(title) " + String(repeating: "─", count: max(0, 60 - title.count)))
        fflush(stdout)
    }

    /// Free-form context printed under a section but not scored.
    func note(_ text: String) {
        print("      \(text)")
        fflush(stdout)
    }

    var snapshot: [CheckRow] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    var failureCount: Int { snapshot.filter { !$0.passed }.count }

    /// The summary table, column-aligned on the check name.
    func table() -> String {
        let rows = snapshot
        let width = rows.map(\.name.count).max() ?? 0
        var out = ""
        out += "RESULT  " + "CHECK".padding(toLength: width, withPad: " ", startingAt: 0) + "  OBSERVED\n"
        out += String(repeating: "=", count: width + 60) + "\n"
        for row in rows {
            let name = row.name.padding(toLength: width, withPad: " ", startingAt: 0)
            out += "\(row.passed ? "PASS" : "FAIL")    \(name)  \(row.detail)\n"
        }
        out += String(repeating: "=", count: width + 60) + "\n"
        let failed = rows.filter { !$0.passed }.count
        out += "\(rows.count) checks, \(rows.count - failed) passed, \(failed) failed\n"
        return out
    }
}

/// Shortens a value for the OBSERVED column without hiding that it was shortened.
func clip(_ text: String, _ limit: Int = 110) -> String {
    let flat = text
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\u{1B}", with: "␛")
    if flat.count <= limit { return flat }
    return String(flat.prefix(limit)) + "…(\(flat.count) chars)"
}
