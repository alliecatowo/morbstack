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
//
// # Untrusted input
//
// Every byte reaching `feed` is attacker-controlled if the container is. The parser is
// therefore written so that no sequence can (a) allocate without a bound, (b) index
// outside the grid, or (c) put bytes the container chose onto the pasteboard or into a
// reply. Specifically:
//
// * Every parameter, intermediate, and string accumulator has a hard cap; a sequence
//   that exceeds it is discarded, not truncated-and-executed.
// * Every cursor write clamps to the live grid before touching storage.
// * The only bytes ever written to `onOutput` are fixed literals and the emulator's own
//   cursor coordinates. Nothing the container sent is echoed back.
// * `OSC 52` — the clipboard read/write sequence — is **explicitly and permanently
//   ignored**. A container must not be able to read or overwrite the person's
//   pasteboard. See `handleOperatingSystemCommand`.
// * Mouse tracking modes (1000–1006) are accepted and discarded rather than
//   implemented, so no cursor movement over the window is ever reported into the guest.

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

    /// The OSC 0/2 window title, if the program set one. Always passed through
    /// ``TerminalCharacterTables/sanitizedWindowTitle(_:)`` first — this string is
    /// attacker-controlled and ends up in window chrome.
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
    /// limit given to `init`. Always 0 on the alternate screen: a full-screen program
    /// must not be able to push the shell's history away, and the primary buffer's own
    /// scrollback is preserved untouched until it comes back.
    var scrollbackLineCount: Int { isAlternateScreen ? 0 : scrollback.count }

    init(columns: Int, rows: Int, scrollbackLimit: Int = 10_000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = max(0, scrollbackLimit)
        screen = Self.blankGrid(columns: self.columns, rows: self.rows)
        scrollBottom = self.rows - 1
        rebuildTabStops()
    }

    /// Unified line addressing: indices `0..<scrollbackLineCount` are scrollback,
    /// `scrollbackLineCount..<scrollbackLineCount+rows` the live screen. Rows are
    /// always exactly `columns` cells wide.
    func line(at index: Int) -> [TerminalCell] {
        let history = scrollbackLineCount
        if index < history {
            return index >= 0 ? scrollback[index] : Array(repeating: .blank, count: columns)
        }
        let row = index - history
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
        guard !data.isEmpty else { return }
        for byte in data { consume(byte) }
        flushGeneration()
    }

    /// Resizes the grid without reflow (columns truncate or pad; xterm behaves the
    /// same way). Shrinking rows pushes top lines into scrollback so the prompt stays
    /// put; growing pulls them back.
    func resize(columns newColumns: Int, rows newRows: Int) {
        let targetColumns = max(1, newColumns)
        let targetRows = max(1, newRows)
        guard targetColumns != columns || targetRows != rows else { return }

        if targetColumns != columns {
            for index in screen.indices { screen[index] = Self.fit(screen[index], to: targetColumns) }
            for index in scrollback.indices { scrollback[index] = Self.fit(scrollback[index], to: targetColumns) }
            savedPrimaryScreen = savedPrimaryScreen?.map { Self.fit($0, to: targetColumns) }
            columns = targetColumns
        }

        if targetRows != rows {
            resizeRows(to: targetRows)
            savedPrimaryScreen = savedPrimaryScreen.map { Self.fitRowCount($0, to: targetRows, columns: columns) }
            rows = targetRows
        }

        // xterm resets the scroll region on a resize; leaving a stale DECSTBM behind is
        // how a shrunk window ends up scrolling a two-line strip forever.
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(max(cursorRow, 0), rows - 1)
        cursorCol = min(max(cursorCol, 0), columns - 1)
        pendingWrap = false
        rebuildTabStops()
        markDirty()
        flushGeneration()
    }

    private func resizeRows(to targetRows: Int) {
        if targetRows < rows {
            let removeCount = rows - targetRows
            // Trim from below the cursor first so the prompt keeps its place; only push
            // lines off the top once there is nothing spare underneath.
            let spareBelow = max(0, rows - 1 - cursorRow)
            let trimBottom = min(removeCount, spareBelow)
            if trimBottom > 0 { screen.removeLast(trimBottom) }
            let trimTop = removeCount - trimBottom
            for _ in 0..<trimTop {
                let removed = screen.removeFirst()
                if !isAlternateScreen { pushScrollback(removed) }
                cursorRow = max(0, cursorRow - 1)
            }
        } else {
            var addCount = targetRows - rows
            if !isAlternateScreen {
                let pulled = min(addCount, scrollback.count)
                for _ in 0..<pulled {
                    screen.insert(scrollback.removeLast(), at: 0)
                    cursorRow += 1
                }
                addCount -= pulled
            }
            for _ in 0..<addCount { screen.append(Self.blankRow(columns: columns)) }
        }
    }

    // MARK: Storage (implementation detail)

    private let scrollbackLimit: Int
    private var screen: [[TerminalCell]]
    private var scrollback: [[TerminalCell]] = []
    /// The primary buffer, parked while the alternate screen is up.
    private var savedPrimaryScreen: [[TerminalCell]]?

    private var style = TerminalCellStyle.plain
    private var pendingWrap = false
    private var autoWrap = true
    private var originMode = false
    private var insertMode = false
    private var scrollTop = 0
    private var scrollBottom = 0
    private var tabStops: [Bool] = []

    private var usingG1 = false
    private var g0IsGraphics = false
    private var g1IsGraphics = false

    /// The last printed scalar, for `CSI b` (REP).
    private var lastPrintedScalar: Unicode.Scalar?

    private var dirty = false

    private struct SavedCursor {
        var row = 0
        var col = 0
        var style = TerminalCellStyle.plain
        var originMode = false
        var g0IsGraphics = false
        var g1IsGraphics = false
        var usingG1 = false
    }

    private var savedCursor = SavedCursor()
    private var savedCursorAcrossAlternate: SavedCursor?

    private static func blankGrid(columns: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: blankRow(columns: columns), count: rows)
    }

    private static func blankRow(columns: Int) -> [TerminalCell] {
        Array(repeating: TerminalCell.blank, count: columns)
    }

    private static func fit(_ row: [TerminalCell], to width: Int) -> [TerminalCell] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: TerminalCell.blank, count: width - row.count)
    }

    private static func fitRowCount(_ grid: [[TerminalCell]], to count: Int, columns: Int) -> [[TerminalCell]] {
        if grid.count == count { return grid }
        if grid.count > count { return Array(grid.suffix(count)) }
        return grid + Array(repeating: blankRow(columns: columns), count: count - grid.count)
    }

    private func markDirty() { dirty = true }

    private func flushGeneration() {
        guard dirty else { return }
        dirty = false
        generation &+= 1
    }

    private func rebuildTabStops() {
        tabStops = (0..<columns).map { $0 % 8 == 0 && $0 != 0 }
    }

    private func pushScrollback(_ row: [TerminalCell]) {
        guard scrollbackLimit > 0 else { return }
        scrollback.append(row)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
    }

    /// The cell an erase writes: blank, but carrying the current background so a
    /// coloured `clear` paints the region rather than punching a hole in it (BCE).
    private var eraseCell: TerminalCell {
        TerminalCell(character: nil, style: TerminalCellStyle(background: style.background))
    }

    // MARK: - Parser

    private enum ParserState {
        case ground
        case escape
        /// `ESC #` — DEC private two-character sequences.
        case escapeHash
        /// `ESC ( ` / `) ` / `* ` / `+ ` — the character-set designators.
        case charsetDesignator
        case csi
        case operatingSystemCommand
        /// DCS/APC/PM/SOS payload: consumed to its terminator and discarded, so a
        /// program's inline data never leaks onto the screen as text.
        case stringPayload
        /// Inside an OSC or string payload, having just seen `ESC` — the next byte
        /// decides whether that was the `ST` terminator or a stray escape.
        case stringPayloadEscape(returningTo: StringKind)
    }

    private enum StringKind { case osc, other }

    private var parserState = ParserState.ground

    /// Hard caps. A sequence longer than its cap is abandoned rather than truncated:
    /// executing the front half of something a container sent deliberately over-long is
    /// exactly the behaviour an attacker would be probing for.
    private static let parameterByteLimit = 128
    private static let stringByteLimit = 4096

    private var csiPrefix: UInt8?
    private var csiParameterBytes: [UInt8] = []
    private var csiIntermediateBytes: [UInt8] = []
    private var csiOverflowed = false
    private var stringBuffer: [UInt8] = []
    private var stringOverflowed = false
    private var charsetSlot: UInt8 = UInt8(ascii: "(")

    private var utf8Buffer: [UInt8] = []
    private var utf8Remaining = 0

    private func consume(_ byte: UInt8) {
        // A partial UTF-8 sequence has priority over everything except its own
        // abandonment: continuation bytes (0x80–0xBF) are never controls, and any other
        // byte here means the guest truncated a sequence mid-way.
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Buffer.append(byte)
                utf8Remaining -= 1
                if utf8Remaining == 0 { completeUTF8Scalar() }
                return
            }
            utf8Buffer.removeAll(keepingCapacity: true)
            utf8Remaining = 0
            printScalar("\u{FFFD}")
        }

        switch parserState {
        case .ground:
            groundByte(byte)
        case .escape:
            escapeByte(byte)
        case .escapeHash:
            parserState = .ground
            if byte == UInt8(ascii: "8") { screenAlignmentTest() }
        case .charsetDesignator:
            parserState = .ground
            designateCharset(slot: charsetSlot, final: byte)
        case .csi:
            csiByte(byte)
        case .operatingSystemCommand:
            stringByte(byte, kind: .osc)
        case .stringPayload:
            stringByte(byte, kind: .other)
        case .stringPayloadEscape(let kind):
            if byte == UInt8(ascii: "\\") {
                finishString(kind: kind)
            } else {
                // Not `ST`. Put the escape back into the payload and keep consuming;
                // this is the tolerant reading and it cannot run anything.
                appendStringByte(0x1B)
                parserState = kind == .osc ? .operatingSystemCommand : .stringPayload
                stringByte(byte, kind: kind)
            }
        }
    }

    // MARK: Ground

    private func groundByte(_ byte: UInt8) {
        switch byte {
        case 0x07: onBell?()
        case 0x08: backspace()
        case 0x09: horizontalTab()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: carriageReturn()
        case 0x0E: usingG1 = true
        case 0x0F: usingG1 = false
        case 0x1B: beginEscape()
        case 0x00...0x1F, 0x7F:
            // Every other C0 and DEL is deliberately inert. NUL in particular is used as
            // padding by some programs and must never print a glyph.
            break
        default:
            beginUTF8(byte)
        }
    }

    private func beginUTF8(_ byte: UInt8) {
        if byte < 0x80 {
            printScalar(Unicode.Scalar(byte))
            return
        }
        if byte & 0xE0 == 0xC0 { utf8Buffer = [byte]; utf8Remaining = 1; return }
        if byte & 0xF0 == 0xE0 { utf8Buffer = [byte]; utf8Remaining = 2; return }
        if byte & 0xF8 == 0xF0 { utf8Buffer = [byte]; utf8Remaining = 3; return }
        printScalar("\u{FFFD}")
    }

    private func completeUTF8Scalar() {
        let bytes = utf8Buffer
        utf8Buffer.removeAll(keepingCapacity: true)
        guard let scalar = Self.decodeUTF8(bytes) else {
            printScalar("\u{FFFD}")
            return
        }
        printScalar(scalar)
    }

    /// Decodes one already-length-checked UTF-8 sequence, rejecting the overlong and
    /// surrogate encodings that let the same scalar be written more than one way.
    static func decodeUTF8(_ bytes: [UInt8]) -> Unicode.Scalar? {
        var value: UInt32
        let minimum: UInt32
        switch bytes.count {
        case 2: value = UInt32(bytes[0] & 0x1F); minimum = 0x80
        case 3: value = UInt32(bytes[0] & 0x0F); minimum = 0x800
        case 4: value = UInt32(bytes[0] & 0x07); minimum = 0x10000
        default: return nil
        }
        for byte in bytes.dropFirst() {
            guard byte & 0xC0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        guard value >= minimum else { return nil }
        return Unicode.Scalar(value)
    }

    // MARK: Escape

    private func beginEscape() {
        parserState = .escape
        csiPrefix = nil
        csiParameterBytes.removeAll(keepingCapacity: true)
        csiIntermediateBytes.removeAll(keepingCapacity: true)
        csiOverflowed = false
    }

    private func escapeByte(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            parserState = .csi
        case UInt8(ascii: "]"):
            parserState = .operatingSystemCommand
            stringBuffer.removeAll(keepingCapacity: true)
            stringOverflowed = false
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            // DCS / SOS / PM / APC. Consumed and discarded — none of them carry anything
            // this terminal implements, and letting the payload fall through to `print`
            // would spray a program's private data across the screen.
            parserState = .stringPayload
            stringBuffer.removeAll(keepingCapacity: true)
            stringOverflowed = false
        case UInt8(ascii: "#"):
            parserState = .escapeHash
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            charsetSlot = byte
            parserState = .charsetDesignator
        case UInt8(ascii: "7"):
            parserState = .ground
            saveCursor()
        case UInt8(ascii: "8"):
            parserState = .ground
            restoreCursor()
        case UInt8(ascii: "D"):
            parserState = .ground
            index()
        case UInt8(ascii: "E"):
            parserState = .ground
            carriageReturn()
            index()
        case UInt8(ascii: "H"):
            parserState = .ground
            if cursorCol >= 0, cursorCol < tabStops.count { tabStops[cursorCol] = true }
        case UInt8(ascii: "M"):
            parserState = .ground
            reverseIndex()
        case UInt8(ascii: "c"):
            parserState = .ground
            fullReset()
        default:
            // `ESC =` / `ESC >` (keypad modes) and everything else unimplemented: consume
            // the introducer and return to ground rather than printing the final byte.
            parserState = .ground
        }
    }

    private func designateCharset(slot: UInt8, final: UInt8) {
        let isGraphics = final == UInt8(ascii: "0")
        switch slot {
        case UInt8(ascii: "("): g0IsGraphics = isGraphics
        case UInt8(ascii: ")"): g1IsGraphics = isGraphics
        default: break   // G2/G3 are designable but unreachable without SS2/SS3 locking.
        }
    }

    // MARK: String payloads (OSC, DCS, APC, PM, SOS)

    private func appendStringByte(_ byte: UInt8) {
        guard !stringOverflowed else { return }
        guard stringBuffer.count < Self.stringByteLimit else {
            stringOverflowed = true
            stringBuffer.removeAll(keepingCapacity: false)
            return
        }
        stringBuffer.append(byte)
    }

    private func stringByte(_ byte: UInt8, kind: StringKind) {
        switch byte {
        case 0x07:
            // BEL terminates an OSC (the xterm convention). Inside a DCS it is not a
            // terminator, but treating it as one there only ends a payload early, which
            // is strictly safer than continuing to swallow bytes.
            finishString(kind: kind)
        case 0x1B:
            parserState = .stringPayloadEscape(returningTo: kind)
        case 0x18, 0x1A:
            // CAN / SUB abort the sequence outright.
            stringBuffer.removeAll(keepingCapacity: true)
            stringOverflowed = false
            parserState = .ground
        default:
            appendStringByte(byte)
        }
    }

    private func finishString(kind: StringKind) {
        let payload = stringBuffer
        let overflowed = stringOverflowed
        stringBuffer.removeAll(keepingCapacity: true)
        stringOverflowed = false
        parserState = .ground
        guard kind == .osc, !overflowed else { return }
        handleOperatingSystemCommand(payload)
    }

    /// The OSC allow-list. Everything not named here is discarded in silence.
    ///
    /// **`OSC 52` is not implemented and must not be.** It is the clipboard
    /// read/write sequence: a container that can print four bytes could otherwise
    /// replace what the person is about to paste into a shell on their own machine,
    /// or — with the read form — exfiltrate the pasteboard's current contents through
    /// its own stdout. Falling into the `default` branch below is the whole defence
    /// and the reason this is an allow-list rather than a deny-list.
    private func handleOperatingSystemCommand(_ payload: [UInt8]) {
        guard let separator = payload.firstIndex(of: UInt8(ascii: ";")) else { return }
        let code = String(decoding: payload[..<separator], as: UTF8.self)
        let body = String(decoding: payload[(separator + 1)...], as: UTF8.self)
        switch code {
        case "0", "2":
            // 0 sets icon name and window title, 2 the window title alone; this app has
            // no icon name, so both mean the same thing here. 1 (icon name only) is
            // deliberately absent — it must not move the window title.
            let sanitized = TerminalCharacterTables.sanitizedWindowTitle(body)
            title = sanitized.isEmpty ? nil : sanitized
        default:
            break
        }
    }

    // MARK: CSI

    private func csiByte(_ byte: UInt8) {
        switch byte {
        case 0x3C...0x3F:   // `<` `=` `>` `?` — private-parameter prefix, first byte only
            if csiParameterBytes.isEmpty && csiPrefix == nil {
                csiPrefix = byte
            } else {
                csiOverflowed = true
            }
        case 0x30...0x3B:   // digits, `:`, `;`
            if csiParameterBytes.count < Self.parameterByteLimit {
                csiParameterBytes.append(byte)
            } else {
                csiOverflowed = true
            }
        case 0x20...0x2F:   // intermediates
            if csiIntermediateBytes.count < 4 {
                csiIntermediateBytes.append(byte)
            } else {
                csiOverflowed = true
            }
        case 0x40...0x7E:   // final byte
            parserState = .ground
            if !csiOverflowed { dispatchCSI(final: byte) }
        case 0x18, 0x1A:
            parserState = .ground
        case 0x1B:
            beginEscape()
        default:
            // A C0 control embedded in a CSI is executed in place, which is what real
            // terminals do and what keeps a `\r` inside a prompt escape from being lost.
            if byte < 0x20 { groundByte(byte) }
        }
    }

    /// Splits the accumulated parameter bytes into `;`-separated parameters, each of
    /// which is its own `:`-separated sub-parameter list. An omitted value is `nil` so
    /// each command can apply its own default.
    private func csiParameters() -> [[Int?]] {
        guard !csiParameterBytes.isEmpty else { return [] }
        let text = String(decoding: csiParameterBytes, as: UTF8.self)
        return text.split(separator: ";", omittingEmptySubsequences: false).map { parameter in
            parameter.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        }
    }

    private func value(_ parameters: [[Int?]], _ index: Int, default fallback: Int) -> Int {
        guard index < parameters.count, let first = parameters[index].first, let value = first else {
            return fallback
        }
        return value
    }

    private func dispatchCSI(final: UInt8) {
        let parameters = csiParameters()

        if csiPrefix == UInt8(ascii: "?") {
            switch final {
            case UInt8(ascii: "h"): setDECPrivateModes(parameters, enabled: true)
            case UInt8(ascii: "l"): setDECPrivateModes(parameters, enabled: false)
            case UInt8(ascii: "n"): deviceStatusReport(parameters, extended: true)
            default: break
            }
            return
        }
        if csiPrefix == UInt8(ascii: ">") {
            // Secondary device attributes. A fixed literal; nothing from the guest.
            if final == UInt8(ascii: "c") { reply("\u{1B}[>0;10;0c") }
            return
        }
        guard csiPrefix == nil else { return }

        switch final {
        case UInt8(ascii: "@"): insertCharacters(value(parameters, 0, default: 1))
        case UInt8(ascii: "A"): moveCursor(rowDelta: -value(parameters, 0, default: 1))
        case UInt8(ascii: "B"): moveCursor(rowDelta: value(parameters, 0, default: 1))
        case UInt8(ascii: "C"): moveCursor(columnDelta: value(parameters, 0, default: 1))
        case UInt8(ascii: "D"): moveCursor(columnDelta: -value(parameters, 0, default: 1))
        case UInt8(ascii: "E"):
            moveCursor(rowDelta: value(parameters, 0, default: 1))
            setCursor(column: 0)
        case UInt8(ascii: "F"):
            moveCursor(rowDelta: -value(parameters, 0, default: 1))
            setCursor(column: 0)
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            setCursor(column: value(parameters, 0, default: 1) - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            setCursor(row: value(parameters, 0, default: 1) - 1, column: value(parameters, 1, default: 1) - 1)
        case UInt8(ascii: "I"): tabForward(value(parameters, 0, default: 1))
        case UInt8(ascii: "J"): eraseInDisplay(value(parameters, 0, default: 0))
        case UInt8(ascii: "K"): eraseInLine(value(parameters, 0, default: 0))
        case UInt8(ascii: "L"): insertLines(value(parameters, 0, default: 1))
        case UInt8(ascii: "M"): deleteLines(value(parameters, 0, default: 1))
        case UInt8(ascii: "P"): deleteCharacters(value(parameters, 0, default: 1))
        case UInt8(ascii: "S"): scrollUp(value(parameters, 0, default: 1))
        case UInt8(ascii: "T"): scrollDown(value(parameters, 0, default: 1))
        case UInt8(ascii: "X"): eraseCharacters(value(parameters, 0, default: 1))
        case UInt8(ascii: "Z"): tabBackward(value(parameters, 0, default: 1))
        case UInt8(ascii: "b"): repeatLastCharacter(value(parameters, 0, default: 1))
        case UInt8(ascii: "c"):
            // Primary device attributes: "a VT220 with ANSI colour". A fixed literal.
            reply("\u{1B}[?62;22c")
        case UInt8(ascii: "d"): setCursor(row: value(parameters, 0, default: 1) - 1)
        case UInt8(ascii: "g"): clearTabStops(value(parameters, 0, default: 0))
        case UInt8(ascii: "h"): setANSIModes(parameters, enabled: true)
        case UInt8(ascii: "l"): setANSIModes(parameters, enabled: false)
        case UInt8(ascii: "m"): applySGR(parameters)
        case UInt8(ascii: "n"): deviceStatusReport(parameters, extended: false)
        case UInt8(ascii: "r"): setScrollRegion(parameters)
        case UInt8(ascii: "s"): saveCursor()
        case UInt8(ascii: "u"): restoreCursor()
        default: break
        }
    }

    /// The only path from this class back to the process. Callers pass fixed literals
    /// and coordinates the emulator computed itself — never a substring of the input.
    private func reply(_ text: String) {
        onOutput?(Data(text.utf8))
    }

    private func deviceStatusReport(_ parameters: [[Int?]], extended: Bool) {
        switch value(parameters, 0, default: 0) {
        case 5 where !extended:
            reply("\u{1B}[0n")
        case 6:
            let row = (originMode ? cursorRow - scrollTop : cursorRow) + 1
            let column = cursorCol + 1
            reply(extended ? "\u{1B}[?\(row);\(column);1R" : "\u{1B}[\(row);\(column)R")
        default:
            break
        }
    }

    // MARK: Modes

    private func setANSIModes(_ parameters: [[Int?]], enabled: Bool) {
        for index in parameters.indices {
            switch value(parameters, index, default: -1) {
            case 4: insertMode = enabled          // IRM
            default: break                        // LNM (20) and the rest are inert here.
            }
        }
    }

    private func setDECPrivateModes(_ parameters: [[Int?]], enabled: Bool) {
        for index in parameters.indices {
            switch value(parameters, index, default: -1) {
            case 1:
                applicationCursorKeys = enabled
            case 6:
                originMode = enabled
                setCursor(row: 0, column: 0)
            case 7:
                autoWrap = enabled
                pendingWrap = false
            case 25:
                cursorVisible = enabled
                markDirty()
            case 47:
                setAlternateScreen(enabled, restoringCursor: false)
            case 1047:
                setAlternateScreen(enabled, restoringCursor: false)
            case 1048:
                enabled ? saveCursor() : restoreCursor()
            case 1049:
                setAlternateScreen(enabled, restoringCursor: true)
            case 2004:
                bracketedPaste = enabled
            default:
                // Mouse reporting (1000–1006), focus reporting (1004), synchronised
                // output (2026), DECCOLM (3), reverse video (5): accepted and ignored.
                // Ignoring a mouse mode is a deliberate non-feature, not an oversight —
                // nothing about pointer position is ever reported into the guest.
                break
            }
        }
    }

    private func setAlternateScreen(_ enabled: Bool, restoringCursor: Bool) {
        guard enabled != isAlternateScreen else { return }
        if enabled {
            if restoringCursor { savedCursorAcrossAlternate = currentCursorState() }
            savedPrimaryScreen = screen
            isAlternateScreen = true
            screen = Self.blankGrid(columns: columns, rows: rows)
            cursorRow = 0
            cursorCol = 0
        } else {
            screen = savedPrimaryScreen ?? Self.blankGrid(columns: columns, rows: rows)
            savedPrimaryScreen = nil
            isAlternateScreen = false
            if restoringCursor, let saved = savedCursorAcrossAlternate {
                apply(saved)
                savedCursorAcrossAlternate = nil
            }
        }
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, columns - 1)
        markDirty()
    }

    // MARK: SGR

    private func applySGR(_ parameters: [[Int?]]) {
        guard !parameters.isEmpty else {
            style = .plain
            return
        }
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            let code = parameter.first.flatMap { $0 } ?? 0

            // The colon form carries its own sub-parameters (`38:2::r:g:b`) and consumes
            // no further `;` parameters; the semicolon form reaches forward into them.
            if (code == 38 || code == 48 || code == 58), parameter.count > 1 {
                if let colour = Self.colour(fromSubParameters: Array(parameter.dropFirst())) {
                    assignColour(colour, code: code)
                }
                index += 1
                continue
            }
            if code == 38 || code == 48 || code == 58 {
                var consumed = 0
                if let colour = Self.colour(fromParameters: parameters, startingAfter: index, consumed: &consumed) {
                    assignColour(colour, code: code)
                }
                index += 1 + consumed
                continue
            }

            applySimpleSGR(code)
            index += 1
        }
    }

    private func assignColour(_ colour: TerminalCellStyle.Color, code: Int) {
        switch code {
        case 38: style.foreground = colour
        case 48: style.background = colour
        default: break   // 58 is the underline colour; not rendered, so not stored.
        }
    }

    private func applySimpleSGR(_ code: Int) {
        switch code {
        case 0: style = .plain
        case 1: style.bold = true
        case 2: style.dim = true
        case 3: style.italic = true
        case 4: style.underline = true
        case 7: style.inverse = true
        case 9: style.strikethrough = true
        case 21, 22: style.bold = false; style.dim = false
        case 23: style.italic = false
        case 24: style.underline = false
        case 27: style.inverse = false
        case 29: style.strikethrough = false
        case 30...37: style.foreground = .indexed(UInt8(code - 30))
        case 39: style.foreground = nil
        case 40...47: style.background = .indexed(UInt8(code - 40))
        case 49: style.background = nil
        case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
        case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
        default: break
        }
    }

    /// `38:5:n` / `38:2::r:g:b` / `38:2:r:g:b` — the colon form, where the whole colour
    /// lives inside one parameter's sub-parameters.
    static func colour(fromSubParameters subParameters: [Int?]) -> TerminalCellStyle.Color? {
        guard let selector = subParameters.first.flatMap({ $0 }) else { return nil }
        let rest = Array(subParameters.dropFirst())
        switch selector {
        case 5:
            guard let index = rest.first.flatMap({ $0 }), (0...255).contains(index) else { return nil }
            return .indexed(UInt8(index))
        case 2:
            // The ITU form interposes an (almost always empty) colour-space id before
            // the components, so accept both 3 and 4 remaining sub-parameters.
            let components = rest.count >= 4 ? Array(rest.dropFirst()) : rest
            guard components.count >= 3,
                  let red = components[0], let green = components[1], let blue = components[2],
                  (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue)
            else { return nil }
            return .rgb(UInt8(red), UInt8(green), UInt8(blue))
        default:
            return nil
        }
    }

    /// `38;5;n` / `38;2;r;g;b` — the semicolon form, which reaches into the parameters
    /// that follow. `consumed` reports how many of them were eaten.
    static func colour(fromParameters parameters: [[Int?]], startingAfter index: Int, consumed: inout Int) -> TerminalCellStyle.Color? {
        func parameter(_ offset: Int) -> Int? {
            let position = index + offset
            guard position < parameters.count else { return nil }
            return parameters[position].first.flatMap { $0 }
        }
        guard let selector = parameter(1) else { return nil }
        switch selector {
        case 5:
            guard let value = parameter(2), (0...255).contains(value) else { consumed = 1; return nil }
            consumed = 2
            return .indexed(UInt8(value))
        case 2:
            guard let red = parameter(2), let green = parameter(3), let blue = parameter(4),
                  (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue)
            else { consumed = 1; return nil }
            consumed = 4
            return .rgb(UInt8(red), UInt8(green), UInt8(blue))
        default:
            consumed = 1
            return nil
        }
    }

    // MARK: Cursor

    private var effectiveTop: Int { originMode ? scrollTop : 0 }
    private var effectiveBottom: Int { originMode ? scrollBottom : rows - 1 }

    private func currentCursorState() -> SavedCursor {
        SavedCursor(
            row: cursorRow, col: cursorCol, style: style, originMode: originMode,
            g0IsGraphics: g0IsGraphics, g1IsGraphics: g1IsGraphics, usingG1: usingG1)
    }

    private func apply(_ saved: SavedCursor) {
        cursorRow = min(max(saved.row, 0), rows - 1)
        cursorCol = min(max(saved.col, 0), columns - 1)
        style = saved.style
        originMode = saved.originMode
        g0IsGraphics = saved.g0IsGraphics
        g1IsGraphics = saved.g1IsGraphics
        usingG1 = saved.usingG1
        pendingWrap = false
        markDirty()
    }

    private func saveCursor() { savedCursor = currentCursorState() }
    private func restoreCursor() { apply(savedCursor) }

    private func moveCursor(rowDelta: Int = 0, columnDelta: Int = 0) {
        if rowDelta != 0 {
            // Cursor movement never scrolls: it stops at the region edge.
            let lowerBound = cursorRow >= scrollTop ? scrollTop : 0
            let upperBound = cursorRow <= scrollBottom ? scrollBottom : rows - 1
            cursorRow = min(max(cursorRow + rowDelta, lowerBound), upperBound)
        }
        if columnDelta != 0 {
            cursorCol = min(max(cursorCol + columnDelta, 0), columns - 1)
        }
        pendingWrap = false
        markDirty()
    }

    private func setCursor(row: Int? = nil, column: Int? = nil) {
        if let row {
            cursorRow = min(max(effectiveTop + row, effectiveTop), effectiveBottom)
        }
        if let column {
            cursorCol = min(max(column, 0), columns - 1)
        }
        pendingWrap = false
        markDirty()
    }

    private func backspace() {
        if pendingWrap {
            pendingWrap = false
        } else if cursorCol > 0 {
            cursorCol -= 1
        }
        markDirty()
    }

    private func carriageReturn() {
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    private func lineFeed() {
        index()
    }

    private func index() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
        pendingWrap = false
        markDirty()
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
        pendingWrap = false
        markDirty()
    }

    // MARK: Tabs

    private func horizontalTab() {
        tabForward(1)
    }

    private func tabForward(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<min(count, columns) {
            var next = cursorCol + 1
            while next < columns, !tabStops[next] { next += 1 }
            cursorCol = min(next, columns - 1)
        }
        pendingWrap = false
        markDirty()
    }

    private func tabBackward(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<min(count, columns) {
            var previous = cursorCol - 1
            while previous > 0, !tabStops[previous] { previous -= 1 }
            cursorCol = max(previous, 0)
        }
        pendingWrap = false
        markDirty()
    }

    private func clearTabStops(_ mode: Int) {
        switch mode {
        case 0:
            if cursorCol >= 0, cursorCol < tabStops.count { tabStops[cursorCol] = false }
        case 3:
            tabStops = Array(repeating: false, count: columns)
        default:
            break
        }
    }

    // MARK: Scrolling

    private func scrollUp(_ count: Int) {
        guard count > 0, scrollTop <= scrollBottom else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        let effective = min(count, regionHeight)
        for _ in 0..<effective {
            let removed = screen.remove(at: scrollTop)
            screen.insert(Self.blankRow(columns: columns), at: scrollBottom)
            // Only the primary screen with a region anchored at the top produces
            // history: a program scrolling a sub-region, or anything on the alternate
            // screen, is repainting, not appending output.
            if !isAlternateScreen, scrollTop == 0 { pushScrollback(removed) }
        }
        markDirty()
    }

    private func scrollDown(_ count: Int) {
        guard count > 0, scrollTop <= scrollBottom else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        let effective = min(count, regionHeight)
        for _ in 0..<effective {
            screen.remove(at: scrollBottom)
            screen.insert(Self.blankRow(columns: columns), at: scrollTop)
        }
        markDirty()
    }

    private func setScrollRegion(_ parameters: [[Int?]]) {
        let top = value(parameters, 0, default: 1) - 1
        let bottom = value(parameters, 1, default: rows) - 1
        guard top >= 0, bottom < rows, top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        // DECSTBM homes the cursor, honouring origin mode.
        cursorRow = effectiveTop
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    // MARK: Erase and edit

    private func eraseInDisplay(_ mode: Int) {
        let blank = eraseCell
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows { screen[row] = Array(repeating: blank, count: columns) }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { screen[row] = Array(repeating: blank, count: columns) }
        case 2:
            for row in 0..<rows { screen[row] = Array(repeating: blank, count: columns) }
        case 3:
            scrollback.removeAll(keepingCapacity: false)
        default:
            return
        }
        pendingWrap = false
        markDirty()
    }

    private func eraseInLine(_ mode: Int) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        let blank = eraseCell
        switch mode {
        case 0:
            for column in cursorCol..<columns { screen[cursorRow][column] = blank }
        case 1:
            for column in 0...min(cursorCol, columns - 1) { screen[cursorRow][column] = blank }
        case 2:
            screen[cursorRow] = Array(repeating: blank, count: columns)
        default:
            return
        }
        pendingWrap = false
        markDirty()
    }

    private func eraseCharacters(_ count: Int) {
        guard count > 0, cursorRow < rows else { return }
        let blank = eraseCell
        let end = min(cursorCol + count, columns)
        guard cursorCol < end else { return }
        for column in cursorCol..<end { screen[cursorRow][column] = blank }
        markDirty()
    }

    private func insertCharacters(_ count: Int) {
        guard count > 0, cursorRow < rows else { return }
        let blank = eraseCell
        var row = screen[cursorRow]
        let effective = min(count, columns - cursorCol)
        guard effective > 0 else { return }
        row.removeSubrange((columns - effective)..<columns)
        row.insert(contentsOf: Array(repeating: blank, count: effective), at: cursorCol)
        screen[cursorRow] = row
        markDirty()
    }

    private func deleteCharacters(_ count: Int) {
        guard count > 0, cursorRow < rows else { return }
        let blank = eraseCell
        var row = screen[cursorRow]
        let effective = min(count, columns - cursorCol)
        guard effective > 0 else { return }
        row.removeSubrange(cursorCol..<(cursorCol + effective))
        row.append(contentsOf: Array(repeating: blank, count: effective))
        screen[cursorRow] = row
        markDirty()
    }

    private func insertLines(_ count: Int) {
        guard count > 0, cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let effective = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<effective {
            screen.remove(at: scrollBottom)
            screen.insert(Self.blankRow(columns: columns), at: cursorRow)
        }
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    private func deleteLines(_ count: Int) {
        guard count > 0, cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let effective = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<effective {
            screen.remove(at: cursorRow)
            screen.insert(Self.blankRow(columns: columns), at: scrollBottom)
        }
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    private func screenAlignmentTest() {
        for row in 0..<rows {
            screen[row] = Array(repeating: TerminalCell(character: "E"), count: columns)
        }
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        markDirty()
    }

    private func fullReset() {
        screen = Self.blankGrid(columns: columns, rows: rows)
        scrollback.removeAll(keepingCapacity: false)
        savedPrimaryScreen = nil
        savedCursorAcrossAlternate = nil
        savedCursor = SavedCursor()
        isAlternateScreen = false
        style = .plain
        cursorRow = 0
        cursorCol = 0
        cursorVisible = true
        applicationCursorKeys = false
        bracketedPaste = false
        autoWrap = true
        originMode = false
        insertMode = false
        pendingWrap = false
        usingG1 = false
        g0IsGraphics = false
        g1IsGraphics = false
        scrollTop = 0
        scrollBottom = rows - 1
        title = nil
        lastPrintedScalar = nil
        rebuildTabStops()
        markDirty()
    }

    // MARK: Printing

    private func repeatLastCharacter(_ count: Int) {
        guard let scalar = lastPrintedScalar, count > 0 else { return }
        // Bounded by one screenful: `CSI 65535 b` must not become 65535 writes.
        for _ in 0..<min(count, columns * rows) { printScalar(scalar, isRepeat: true) }
    }

    private func printScalar(_ scalar: Unicode.Scalar, isRepeat: Bool = false) {
        let substituted = (usingG1 ? g1IsGraphics : g0IsGraphics)
            ? TerminalCharacterTables.decSpecialGraphics(scalar)
            : scalar

        let width = TerminalCharacterTables.cellWidth(of: substituted)
        if width == 0 {
            appendCombining(substituted)
            return
        }
        if !isRepeat { lastPrintedScalar = scalar }

        if pendingWrap {
            carriageReturn()
            index()
            pendingWrap = false
        }
        // A double-width glyph never straddles the right margin: it wraps first, or —
        // with autowrap off — it is dropped rather than half-drawn into the last column.
        if width == 2, cursorCol == columns - 1 {
            guard autoWrap else { return }
            screen[cursorRow][cursorCol] = eraseCell
            carriageReturn()
            index()
        }
        guard cursorRow >= 0, cursorRow < rows, cursorCol >= 0, cursorCol < columns else { return }

        if insertMode { insertCharacters(width) }

        screen[cursorRow][cursorCol] = TerminalCell(character: Character(substituted), style: style)
        if width == 2, cursorCol + 1 < columns {
            screen[cursorRow][cursorCol + 1] = TerminalCell(character: nil, style: style, isWidePlaceholder: true)
        }

        cursorCol += width
        if cursorCol >= columns {
            cursorCol = columns - 1
            pendingWrap = autoWrap
        }
        markDirty()
    }

    /// A zero-width mark joins the cell the cursor just left, not a cell of its own.
    private func appendCombining(_ scalar: Unicode.Scalar) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        var column = pendingWrap ? cursorCol : cursorCol - 1
        if column >= 0, column < columns, screen[cursorRow][column].isWidePlaceholder { column -= 1 }
        guard column >= 0, column < columns, let existing = screen[cursorRow][column].character else { return }
        let combined = String(existing) + String(scalar)
        // `Character(String)` traps unless the string is exactly one grapheme cluster,
        // and a container can absolutely send a mark that does not combine with what is
        // there. Dropping it is correct; crashing the app is not.
        guard combined.count == 1, let merged = combined.first else { return }
        screen[cursorRow][column].character = merged
        markDirty()
    }
}
