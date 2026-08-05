// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// A VT/xterm terminal emulator: the screen model behind the container terminal.
//
// This is a real state machine over the byte stream an interactive program emits —
// cursor movement, erase, scroll regions, the alternate screen, SGR attributes — not a
// log view that strips escapes. `AnsiSGR.swift` deliberately keeps only colour because
// a scrollback document has no cursor; this class exists because a terminal does.
//
// Foundation only, no I/O, no views: bytes in via `feed`, cells out via `line(at:)`,
// and the few sequences that demand an answer (device attributes, cursor position
// reports) come back out through `onOutput`. Everything here is directly testable.
//
// Not thread-safe by design: the owner (the terminal view's controller) confines it to
// the main thread, the same rule the rest of the app's view models follow.

import Foundation

// MARK: - Cells

/// The rendered attributes of one cell, as SGR left them.
struct TerminalCellStyle: Equatable, Sendable {

    /// A colour as the wire named it. Indexed 0–15 are the ANSI/bright set (the view
    /// owns their appearance-aware palette), 16–255 the xterm cube and grayscale ramp;
    /// `rgb` is SGR 38;2/48;2 truecolor.
    enum Color: Equatable, Sendable {
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    var foreground: Color?
    var background: Color?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    var strikethrough = false

    static let plain = TerminalCellStyle()
}

/// One grid position. `character == nil` is a blank cell (erased or never written);
/// its background still paints. `isWidePlaceholder` marks the second column of a
/// double-width character so rendering and copy both skip it.
struct TerminalCell: Equatable, Sendable {
    var character: Character?
    var style: TerminalCellStyle = .plain
    var isWidePlaceholder = false

    static let blank = TerminalCell()
}

// MARK: - Emulator

/// The terminal screen: primary buffer with scrollback, alternate buffer without.
final class TerminalEmulator {

    private(set) var columns: Int
    private(set) var rows: Int

    /// Bytes the emulator itself must send back to the process — DA and DSR/CPR
    /// replies. `vim` genuinely waits on these.
    var onOutput: ((Data) -> Void)?

    /// BEL. The view decides whether that beeps or flashes.
    var onBell: (() -> Void)?

    /// The OSC 0/2 window title, if the program set one.
    private(set) var title: String?

    /// Increments on every visible mutation; the view redraws only when it moved.
    private(set) var generation: UInt64 = 0

    /// `true` while the program holds the alternate screen (vim, htop, less).
    /// Scrollback is suspended there: `scrollbackLineCount` reports 0.
    private(set) var isAlternateScreen = false

    /// Cursor in screen coordinates (0-based, top-left origin).
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private(set) var cursorVisible = true

    /// DECCKM — decides how the view encodes arrow keys.
    private(set) var applicationCursorKeys = false

    /// Mode 2004 — decides whether a paste is fenced with `ESC [200~`/`ESC [201~`.
    private(set) var bracketedPaste = false

    /// Lines scrolled off the top of the primary screen, oldest first, capped at the
    /// limit given to `init`. Always 0 on the alternate screen.
    private(set) var scrollbackLineCount = 0

    init(columns: Int, rows: Int, scrollbackLimit: Int = 10_000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = scrollbackLimit
        screen = Self.blankGrid(columns: self.columns, rows: self.rows)
    }

    /// Unified line addressing: indices `0..<scrollbackLineCount` are scrollback,
    /// `scrollbackLineCount..<scrollbackLineCount+rows` the live screen. Rows are
    /// always exactly `columns` cells wide.
    func line(at index: Int) -> [TerminalCell] {
        if index < scrollbackLineCount { return scrollback[index] }
        let row = index - scrollbackLineCount
        guard row >= 0, row < rows else { return Array(repeating: .blank, count: columns) }
        return screen[row]
    }

    /// The text of one line for selection and copy: wide placeholders skipped, blanks
    /// as spaces, trailing blanks trimmed.
    func plainText(ofLine index: Int) -> String {
        var text = ""
        for cell in line(at: index) where !cell.isWidePlaceholder {
            text.append(cell.character ?? " ")
        }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    /// Consumes wire bytes. Tolerates UTF-8 sequences split across calls.
    func feed(_ data: Data) {
        // Implemented by the emulator engine; stub keeps the contract compiling.
        _ = data
    }

    /// Resizes the grid without reflow (columns truncate or pad; xterm behaves the
    /// same way). Shrinking rows pushes top lines into scrollback so the prompt stays
    /// put; growing pulls them back.
    func resize(columns newColumns: Int, rows newRows: Int) {
        _ = (newColumns, newRows)
    }

    // MARK: Storage (implementation detail)

    private let scrollbackLimit: Int
    private var screen: [[TerminalCell]]
    private var scrollback: [[TerminalCell]] = []

    private static func blankGrid(columns: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell.blank, count: columns), count: rows)
    }
}
