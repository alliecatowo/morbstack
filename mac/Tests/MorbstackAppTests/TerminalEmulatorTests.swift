// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// The screen model, driven the way a container drives it: bytes in, cells out.
//
// `TerminalEmulator` is the piece of the container terminal that consumes wholly
// untrusted input, so this file is split in two. The first half is the VT/xterm
// contract `docs/exec.md` claims — cursor addressing, erase, scroll regions, the
// alternate screen, SGR, charsets, wide characters, the replies programs block on. The
// second half, `TerminalEmulatorHostileInputTests`, is the security contract: what a
// malicious container must *not* be able to make this class do.

import Foundation
import XCTest

@testable import MorbstackAppCore

// MARK: - Helpers

extension TerminalEmulator {

    fileprivate func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    /// The visible screen as plain text, one string per row, trailing blanks trimmed.
    fileprivate var screenLines: [String] {
        (0..<rows).map { plainText(ofLine: scrollbackLineCount + $0) }
    }

    fileprivate var scrollbackLines: [String] {
        (0..<scrollbackLineCount).map { plainText(ofLine: $0) }
    }

    fileprivate func cell(row: Int, column: Int) -> TerminalCell {
        line(at: scrollbackLineCount + row)[column]
    }
}

// MARK: - The VT contract

final class TerminalEmulatorTests: XCTestCase {

    private func makeEmulator(columns: Int = 20, rows: Int = 5, scrollback: Int = 100) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: scrollback)
    }

    // MARK: Plain text and the cursor

    func testPlainTextLandsOnTheFirstRow() {
        let emulator = makeEmulator()
        emulator.feed("hello")
        XCTAssertEqual(emulator.screenLines.first, "hello")
        XCTAssertEqual(emulator.cursorRow, 0)
        XCTAssertEqual(emulator.cursorCol, 5)
    }

    func testCarriageReturnAndLineFeedAreSeparateMovements() {
        let emulator = makeEmulator()
        emulator.feed("ab\r\ncd")
        XCTAssertEqual(Array(emulator.screenLines.prefix(2)), ["ab", "cd"])
        XCTAssertEqual(emulator.cursorRow, 1)

        // A bare LF keeps the column, exactly as a terminal without ONLCR does.
        let bare = makeEmulator()
        bare.feed("ab\ncd")
        XCTAssertEqual(Array(bare.screenLines.prefix(2)), ["ab", "  cd"])
    }

    func testBackspaceMovesWithoutErasing() {
        let emulator = makeEmulator()
        emulator.feed("abc\u{08}")
        XCTAssertEqual(emulator.cursorCol, 2)
        XCTAssertEqual(emulator.screenLines.first, "abc")
        emulator.feed("X")
        XCTAssertEqual(emulator.screenLines.first, "abX")
    }

    func testCursorPositionAddressesOneBasedCoordinates() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[3;5Hx")
        XCTAssertEqual(emulator.screenLines[2], "    x")
    }

    func testCursorMovementStopsAtTheEdgesInsteadOfScrolling() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[100A\u{1B}[100D")
        XCTAssertEqual(emulator.cursorRow, 0)
        XCTAssertEqual(emulator.cursorCol, 0)
        emulator.feed("\u{1B}[100B\u{1B}[100C")
        XCTAssertEqual(emulator.cursorRow, emulator.rows - 1)
        XCTAssertEqual(emulator.cursorCol, emulator.columns - 1)
        XCTAssertEqual(emulator.scrollbackLineCount, 0, "cursor movement must never produce history")
    }

    func testTabsLandOnEightColumnStops() {
        let emulator = makeEmulator(columns: 30)
        emulator.feed("a\tb\tc")
        XCTAssertEqual(emulator.screenLines.first, "a       b       c")
    }

    func testBackTabReturnsToThePreviousStop() {
        let emulator = makeEmulator(columns: 30)
        emulator.feed("\u{1B}[20G\u{1B}[Zx")
        XCTAssertEqual(emulator.cursorCol, 17)
    }

    // MARK: Wraparound

    func testDeferredWrapKeepsTheLastColumnUsable() {
        let emulator = makeEmulator(columns: 4, rows: 3)
        emulator.feed("abcd")
        // The pending-wrap rule: after filling the row the cursor sits *on* the last
        // column, not past it, and the next row is still untouched.
        XCTAssertEqual(emulator.cursorRow, 0)
        XCTAssertEqual(emulator.cursorCol, 3)
        XCTAssertEqual(emulator.screenLines[1], "")

        emulator.feed("e")
        XCTAssertEqual(Array(emulator.screenLines.prefix(2)), ["abcd", "e"])
    }

    func testAutowrapOffOverwritesTheLastColumn() {
        let emulator = makeEmulator(columns: 4, rows: 3)
        emulator.feed("\u{1B}[?7labcdef")
        XCTAssertEqual(emulator.screenLines[0], "abcf")
        XCTAssertEqual(emulator.screenLines[1], "")
    }

    // MARK: Erase

    func testEraseInLineModes() {
        let emulator = makeEmulator(columns: 10)
        emulator.feed("abcdefghij\u{1B}[1;5H\u{1B}[0K")
        XCTAssertEqual(emulator.screenLines[0], "abcd")

        emulator.feed("\u{1B}[2;1Habcdefghij\u{1B}[2;5H\u{1B}[1K")
        XCTAssertEqual(emulator.screenLines[1], "     fghij")

        emulator.feed("\u{1B}[2K")
        XCTAssertEqual(emulator.screenLines[1], "")
    }

    func testEraseInDisplayBelowAndAbove() {
        let emulator = makeEmulator(columns: 4, rows: 4)
        emulator.feed("aaaa\r\nbbbb\r\ncccc\r\ndddd")
        emulator.feed("\u{1B}[2;3H\u{1B}[0J")
        XCTAssertEqual(emulator.screenLines, ["aaaa", "bb", "", ""])

        emulator.feed("\u{1B}[1;1H\u{1B}[2J")
        XCTAssertEqual(emulator.screenLines, ["", "", "", ""])
    }

    func testEraseInDisplayThreeClearsScrollback() {
        let emulator = makeEmulator(columns: 4, rows: 2)
        emulator.feed("one\r\ntwo\r\nthree\r\n")
        XCTAssertGreaterThan(emulator.scrollbackLineCount, 0)
        emulator.feed("\u{1B}[3J")
        XCTAssertEqual(emulator.scrollbackLineCount, 0)
    }

    func testEraseCharacterBlanksInPlaceWithoutShifting() {
        let emulator = makeEmulator(columns: 8)
        emulator.feed("abcdefgh\u{1B}[1;3H\u{1B}[2X")
        XCTAssertEqual(emulator.screenLines[0], "ab  efgh")
    }

    // MARK: Insert and delete

    func testInsertAndDeleteCharacters() {
        let emulator = makeEmulator(columns: 8)
        emulator.feed("abcdefgh\u{1B}[1;3H\u{1B}[2@")
        XCTAssertEqual(emulator.screenLines[0], "ab  cdef")

        emulator.feed("\u{1B}[1;3H\u{1B}[2P")
        XCTAssertEqual(emulator.screenLines[0], "abcdef")
    }

    func testInsertAndDeleteLines() {
        let emulator = makeEmulator(columns: 4, rows: 4)
        emulator.feed("aaaa\r\nbbbb\r\ncccc\r\ndddd")
        emulator.feed("\u{1B}[2;1H\u{1B}[1L")
        XCTAssertEqual(emulator.screenLines, ["aaaa", "", "bbbb", "cccc"])

        emulator.feed("\u{1B}[2;1H\u{1B}[1M")
        XCTAssertEqual(emulator.screenLines, ["aaaa", "bbbb", "cccc", ""])
    }

    // MARK: Scrolling and scrollback

    func testScrollingOffTheTopFillsScrollback() {
        let emulator = makeEmulator(columns: 6, rows: 2)
        emulator.feed("one\r\ntwo\r\nthree\r\nfour")
        XCTAssertEqual(emulator.screenLines, ["three", "four"])
        XCTAssertEqual(emulator.scrollbackLines, ["one", "two"])
        XCTAssertEqual(emulator.line(at: 0).count, 6, "history rows keep the grid width")
    }

    func testScrollbackIsCappedAtTheConfiguredLimit() {
        let emulator = makeEmulator(columns: 6, rows: 2, scrollback: 3)
        for index in 0..<20 { emulator.feed("l\(index)\r\n") }
        XCTAssertEqual(emulator.scrollbackLineCount, 3)
        // The cap trims the oldest, so the newest history is what survives. The final
        // `\r\n` leaves `l19` on screen, which makes `l18` the youngest history line.
        XCTAssertEqual(emulator.scrollbackLines, ["l16", "l17", "l18"])
        XCTAssertEqual(emulator.screenLines.first, "l19")
    }

    func testScrollRegionConfinesScrollingAndProducesNoHistory() {
        let emulator = makeEmulator(columns: 4, rows: 4)
        emulator.feed("aaaa\r\nbbbb\r\ncccc\r\ndddd")
        // Region rows 2–3 (1-based), then park on its last row and index.
        emulator.feed("\u{1B}[2;3r\u{1B}[3;1H\n")
        XCTAssertEqual(emulator.screenLines, ["aaaa", "cccc", "", "dddd"])
        XCTAssertEqual(emulator.scrollbackLineCount, 0, "a sub-region scroll is a repaint, not output")
    }

    func testReverseIndexAtTheRegionTopScrollsDown() {
        let emulator = makeEmulator(columns: 4, rows: 4)
        emulator.feed("aaaa\r\nbbbb\r\ncccc\r\ndddd")
        emulator.feed("\u{1B}[1;1H\u{1B}M")
        XCTAssertEqual(emulator.screenLines, ["", "aaaa", "bbbb", "cccc"])
    }

    func testOriginModeAddressesRelativeToTheRegion() {
        let emulator = makeEmulator(columns: 4, rows: 4)
        emulator.feed("\u{1B}[2;3r\u{1B}[?6h\u{1B}[1;1Hx")
        XCTAssertEqual(emulator.screenLines[1], "x", "row 1 in origin mode is the region's top row")
    }

    // MARK: Alternate screen

    func testAlternateScreenPreservesAndRestoresThePrimaryBuffer() {
        let emulator = makeEmulator(columns: 6, rows: 3)
        emulator.feed("shell\r\nprompt")
        emulator.feed("\u{1B}[?1049h")
        XCTAssertTrue(emulator.isAlternateScreen)
        XCTAssertEqual(emulator.screenLines, ["", "", ""])

        emulator.feed("vim")
        XCTAssertEqual(emulator.screenLines[0], "vim")

        emulator.feed("\u{1B}[?1049l")
        XCTAssertFalse(emulator.isAlternateScreen)
        XCTAssertEqual(Array(emulator.screenLines.prefix(2)), ["shell", "prompt"])
        XCTAssertEqual(emulator.cursorRow, 1, "1049 restores the cursor it saved")
    }

    func testAlternateScreenSuspendsScrollbackAndKeepsThePrimaryHistory() {
        let emulator = makeEmulator(columns: 6, rows: 2)
        emulator.feed("one\r\ntwo\r\nthree\r\n")
        let history = emulator.scrollbackLineCount
        XCTAssertGreaterThan(history, 0)

        emulator.feed("\u{1B}[?1049h")
        XCTAssertEqual(emulator.scrollbackLineCount, 0, "a full-screen program has no scrollback")
        emulator.feed("a\r\nb\r\nc\r\nd\r\n")
        XCTAssertEqual(emulator.scrollbackLineCount, 0, "and cannot push history into one")

        emulator.feed("\u{1B}[?1049l")
        XCTAssertEqual(emulator.scrollbackLineCount, history, "the shell's history comes back untouched")
    }

    // MARK: SGR

    func testBasicAndBrightColours() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[31ma\u{1B}[92mb\u{1B}[0mc")
        XCTAssertEqual(emulator.cell(row: 0, column: 0).style.foreground, .indexed(1))
        XCTAssertEqual(emulator.cell(row: 0, column: 1).style.foreground, .indexed(10))
        XCTAssertNil(emulator.cell(row: 0, column: 2).style.foreground)
    }

    func testAttributeSetAndReset() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[1;3;4;7;9ma\u{1B}[22;23;24;27;29mb")
        let bold = emulator.cell(row: 0, column: 0).style
        XCTAssertTrue(bold.bold && bold.italic && bold.underline && bold.inverse && bold.strikethrough)
        let plain = emulator.cell(row: 0, column: 1).style
        XCTAssertFalse(plain.bold || plain.italic || plain.underline || plain.inverse || plain.strikethrough)
    }

    func testIndexedAndTruecolorInSemicolonForm() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[38;5;208ma\u{1B}[48;2;10;20;30mb")
        XCTAssertEqual(emulator.cell(row: 0, column: 0).style.foreground, .indexed(208))
        XCTAssertEqual(emulator.cell(row: 0, column: 1).style.background, .rgb(10, 20, 30))
    }

    func testIndexedAndTruecolorInColonForm() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[38:5:208ma\u{1B}[38:2::10:20:30mb\u{1B}[38:2:1:2:3mc")
        XCTAssertEqual(emulator.cell(row: 0, column: 0).style.foreground, .indexed(208))
        XCTAssertEqual(emulator.cell(row: 0, column: 1).style.foreground, .rgb(10, 20, 30))
        XCTAssertEqual(emulator.cell(row: 0, column: 2).style.foreground, .rgb(1, 2, 3))
    }

    func testSGRWithNoParametersResets() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[1;31m\u{1B}[ma")
        XCTAssertEqual(emulator.cell(row: 0, column: 0).style, .plain)
    }

    func testEraseKeepsTheCurrentBackground() {
        let emulator = makeEmulator(columns: 4, rows: 2)
        emulator.feed("\u{1B}[41m\u{1B}[2J")
        XCTAssertEqual(emulator.cell(row: 0, column: 0).style.background, .indexed(1))
        XCTAssertNil(emulator.cell(row: 0, column: 0).character)
    }

    // MARK: Charsets

    func testDECSpecialGraphicsDrawsBoxCharacters() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}(0lqqk\u{1B}(Bx")
        XCTAssertEqual(emulator.screenLines[0], "┌──┐x")
    }

    func testShiftOutAndShiftInSwitchBetweenDesignatedSets() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B})0a\u{0E}q\u{0F}b")
        XCTAssertEqual(emulator.screenLines[0], "a─b")
    }

    // MARK: Unicode

    func testUTF8SplitAcrossFeedsStillDecodes() {
        let emulator = makeEmulator()
        let bytes = Array("é".utf8)
        emulator.feed(Data([bytes[0]]))
        emulator.feed(Data([bytes[1]]))
        XCTAssertEqual(emulator.screenLines[0], "é")
    }

    func testCombiningMarkJoinsThePreviousCell() {
        let emulator = makeEmulator()
        emulator.feed("e\u{0301}x")
        XCTAssertEqual(emulator.cursorCol, 2, "a combining mark claims no cell of its own")
        XCTAssertEqual(emulator.screenLines[0], "éx")
    }

    func testWideCharacterOccupiesTwoCells() {
        let emulator = makeEmulator()
        emulator.feed("漢a")
        XCTAssertEqual(emulator.cursorCol, 3)
        XCTAssertTrue(emulator.cell(row: 0, column: 1).isWidePlaceholder)
        XCTAssertNil(emulator.cell(row: 0, column: 1).character)
        XCTAssertEqual(emulator.screenLines[0], "漢a", "plain text skips the placeholder column")
    }

    func testWideCharacterWrapsRatherThanStraddlingTheMargin() {
        let emulator = makeEmulator(columns: 3, rows: 3)
        emulator.feed("ab漢")
        XCTAssertEqual(emulator.screenLines[0], "ab")
        XCTAssertEqual(emulator.screenLines[1], "漢")
    }

    func testInvalidUTF8BecomesAReplacementCharacterNotAGap() {
        let emulator = makeEmulator()
        emulator.feed(Data([0xC3, 0x28]))   // truncated two-byte sequence, then '('
        XCTAssertEqual(emulator.screenLines[0], "\u{FFFD}(")
    }

    // MARK: Replies

    func testPrimaryAndSecondaryDeviceAttributes() {
        let emulator = makeEmulator()
        var replies = Data()
        emulator.onOutput = { replies.append($0) }
        emulator.feed("\u{1B}[c\u{1B}[>c")
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1B}[?62;22c\u{1B}[>0;10;0c")
    }

    func testDeviceStatusAndCursorPositionReports() {
        let emulator = makeEmulator()
        var replies = Data()
        emulator.onOutput = { replies.append($0) }
        emulator.feed("\u{1B}[3;7H\u{1B}[5n\u{1B}[6n")
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1B}[0n\u{1B}[3;7R")
    }

    func testBellIsReportedWithoutPrinting() {
        let emulator = makeEmulator()
        var bells = 0
        emulator.onBell = { bells += 1 }
        emulator.feed("a\u{07}b")
        XCTAssertEqual(bells, 1)
        XCTAssertEqual(emulator.screenLines[0], "ab")
    }

    // MARK: Modes the view reads

    func testApplicationCursorKeysTracksDECCKM() {
        let emulator = makeEmulator()
        XCTAssertFalse(emulator.applicationCursorKeys)
        emulator.feed("\u{1B}[?1h")
        XCTAssertTrue(emulator.applicationCursorKeys)
        emulator.feed("\u{1B}[?1l")
        XCTAssertFalse(emulator.applicationCursorKeys)
    }

    func testBracketedPasteTracksMode2004() {
        let emulator = makeEmulator()
        XCTAssertFalse(emulator.bracketedPaste)
        emulator.feed("\u{1B}[?2004h")
        XCTAssertTrue(emulator.bracketedPaste)
        emulator.feed("\u{1B}[?2004l")
        XCTAssertFalse(emulator.bracketedPaste)
    }

    func testCursorVisibilityTracksDECTCEM() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[?25l")
        XCTAssertFalse(emulator.cursorVisible)
        emulator.feed("\u{1B}[?25h")
        XCTAssertTrue(emulator.cursorVisible)
    }

    // MARK: Save, restore, reset

    func testSaveAndRestoreCursorCarriesStyleAndPosition() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[2;3H\u{1B}[31m\u{1B}7\u{1B}[1;1H\u{1B}[0m\u{1B}8x")
        XCTAssertEqual(emulator.cell(row: 1, column: 2).character, "x")
        XCTAssertEqual(emulator.cell(row: 1, column: 2).style.foreground, .indexed(1))
    }

    func testScreenAlignmentTestFillsTheGrid() {
        let emulator = makeEmulator(columns: 3, rows: 2)
        emulator.feed("\u{1B}#8")
        XCTAssertEqual(emulator.screenLines, ["EEE", "EEE"])
    }

    func testFullResetClearsEverything() {
        let emulator = makeEmulator(columns: 4, rows: 2)
        emulator.feed("a\r\nb\r\nc\r\n\u{1B}[?1h\u{1B}[?2004h\u{1B}]0;t\u{07}")
        emulator.feed("\u{1B}c")
        XCTAssertEqual(emulator.screenLines, ["", ""])
        XCTAssertEqual(emulator.scrollbackLineCount, 0)
        XCTAssertFalse(emulator.applicationCursorKeys)
        XCTAssertFalse(emulator.bracketedPaste)
        XCTAssertNil(emulator.title)
    }

    // MARK: Generation

    func testGenerationAdvancesOnlyWhenSomethingChanged() {
        let emulator = makeEmulator()
        let start = emulator.generation
        emulator.feed("a")
        XCTAssertGreaterThan(emulator.generation, start)

        let afterWrite = emulator.generation
        emulator.feed("\u{1B}[?1h")   // a mode change the screen does not show
        XCTAssertEqual(emulator.generation, afterWrite)
    }

    // MARK: Resize

    func testResizeTruncatesAndPadsColumnsWithoutReflow() {
        let emulator = makeEmulator(columns: 10, rows: 2)
        emulator.feed("abcdefghij")
        emulator.resize(columns: 5, rows: 2)
        XCTAssertEqual(emulator.screenLines[0], "abcde", "no reflow: the tail is dropped, not wrapped")
        XCTAssertEqual(emulator.line(at: emulator.scrollbackLineCount).count, 5)

        emulator.resize(columns: 8, rows: 2)
        XCTAssertEqual(emulator.line(at: emulator.scrollbackLineCount).count, 8)
        XCTAssertEqual(emulator.screenLines[0], "abcde")
    }

    func testShrinkingRowsPushesTopLinesIntoScrollback() {
        let emulator = makeEmulator(columns: 6, rows: 4)
        emulator.feed("one\r\ntwo\r\nthree\r\nfour")
        XCTAssertEqual(emulator.cursorRow, 3)
        emulator.resize(columns: 6, rows: 2)
        XCTAssertEqual(emulator.screenLines, ["three", "four"])
        XCTAssertEqual(emulator.scrollbackLines, ["one", "two"])
        XCTAssertEqual(emulator.cursorRow, 1, "the prompt keeps its place")
    }

    func testGrowingRowsPullsScrollbackBack() {
        let emulator = makeEmulator(columns: 6, rows: 2)
        emulator.feed("one\r\ntwo\r\nthree\r\nfour")
        XCTAssertEqual(emulator.scrollbackLines, ["one", "two"])
        emulator.resize(columns: 6, rows: 4)
        XCTAssertEqual(emulator.screenLines, ["one", "two", "three", "four"])
        XCTAssertEqual(emulator.scrollbackLineCount, 0)
    }

    func testResizeResetsTheScrollRegion() {
        let emulator = makeEmulator(columns: 4, rows: 6)
        emulator.feed("\u{1B}[2;3r")
        emulator.resize(columns: 4, rows: 3)
        // With a stale region the next index would scroll a two-line strip; with the
        // region reset, output reaches the bottom row.
        emulator.feed("\u{1B}[3;1Hx")
        XCTAssertEqual(emulator.screenLines[2], "x")
    }

    func testResizeToTheSameSizeIsANoOp() {
        let emulator = makeEmulator(columns: 8, rows: 3)
        emulator.feed("hi")
        let generation = emulator.generation
        emulator.resize(columns: 8, rows: 3)
        XCTAssertEqual(emulator.generation, generation)
    }

    func testDegenerateSizesAreClampedNotAccepted() {
        let emulator = makeEmulator(columns: 8, rows: 3)
        emulator.resize(columns: 0, rows: -4)
        XCTAssertEqual(emulator.columns, 1)
        XCTAssertEqual(emulator.rows, 1)
        emulator.feed("abc")   // must not trap
        XCTAssertEqual(emulator.screenLines.count, 1)
    }

    // MARK: Line addressing

    func testLineAtOutOfRangeIndexReturnsABlankRowRatherThanTrapping() {
        let emulator = makeEmulator(columns: 5, rows: 2)
        XCTAssertEqual(emulator.line(at: -1).count, 5)
        XCTAssertEqual(emulator.line(at: 9_999).count, 5)
    }
}

// MARK: - The security contract

/// Everything a container sends is attacker-controlled. These are the properties that
/// must hold for input chosen to break them, not for input a well-behaved program sends.
final class TerminalEmulatorHostileInputTests: XCTestCase {

    private func makeEmulator(columns: Int = 20, rows: Int = 5) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 50)
    }

    // MARK: OSC 52 — the clipboard

    func testOSC52IsIgnoredEntirely() {
        let emulator = makeEmulator()
        var replies = Data()
        emulator.onOutput = { replies.append($0) }

        // The write form: base64 for "owned".
        emulator.feed("\u{1B}]52;c;b3duZWQ=\u{07}")
        // The read form, which asks the terminal to send the pasteboard back.
        emulator.feed("\u{1B}]52;c;?\u{07}")

        XCTAssertTrue(replies.isEmpty, "OSC 52 must never produce a reply — that is the exfiltration path")
        XCTAssertNil(emulator.title, "OSC 52 must not be mistaken for a title sequence")
        XCTAssertEqual(emulator.screenLines.joined(), "", "and its payload must not print")
    }

    func testUnknownOSCCodesAreDiscardedWithoutPrintingTheirPayload() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]7;file:///root\u{1B}\\\u{1B}]777;notify;hi\u{07}")
        XCTAssertEqual(emulator.screenLines.joined(), "")
        XCTAssertNil(emulator.title)
    }

    // MARK: Window title

    func testTitleIsAcceptedFromOSC0AndOSC2() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]0;first\u{07}")
        XCTAssertEqual(emulator.title, "first")
        emulator.feed("\u{1B}]2;second\u{1B}\\")
        XCTAssertEqual(emulator.title, "second")
    }

    func testOSC1SetsTheIconNameOnlyAndMustNotMoveTheWindowTitle() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]2;real\u{07}\u{1B}]1;icon\u{07}")
        XCTAssertEqual(emulator.title, "real")
    }

    func testTitleStripsControlCharacters() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]0;a\u{0A}b\u{0D}c\u{07}")
        XCTAssertEqual(emulator.title, "abc", "a newline in a window title corrupts anything that logs it")
    }

    func testTitleStripsBidiOverridesUsedToDisguiseText() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]0;safe\u{202E}gnp.exe\u{07}")
        XCTAssertEqual(emulator.title, "safegnp.exe")
    }

    /// Two bounds stack here, and both matter. A title under the OSC accumulator's
    /// 4096-byte cap is accepted and *truncated* to 128 characters; one over that cap is
    /// abandoned entirely by the test below. This covers the first.
    func testTitleIsLengthCapped() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]0;\(String(repeating: "x", count: 1_000))\u{07}")
        XCTAssertEqual(emulator.title?.count, TerminalCharacterTables.titleCharacterLimit)
    }

    func testAnOverlongOSCIsAbandonedRatherThanAppliedInPart() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]0;kept\u{07}")
        emulator.feed("\u{1B}]0;\(String(repeating: "y", count: 20_000))\u{07}")
        XCTAssertEqual(emulator.title, "kept", "a sequence past the cap is discarded, not truncated and executed")
        XCTAssertEqual(emulator.screenLines.joined(), "", "and its payload never reaches the screen")
    }

    // MARK: Replies never echo the guest's own bytes

    func testRepliesAreFixedLiteralsAndCursorCoordinatesOnly() {
        let emulator = makeEmulator()
        var replies = Data()
        emulator.onOutput = { replies.append($0) }
        // A DA request carrying a payload, and a DSR with an unsupported selector.
        emulator.feed("\u{1B}[1234;5678c")
        emulator.feed("\u{1B}[99n")
        emulator.feed("\u{1B}[?99n")
        let text = String(decoding: replies, as: UTF8.self)
        XCTAssertFalse(text.contains("1234"))
        XCTAssertFalse(text.contains("5678"))
        XCTAssertFalse(text.contains("99"))
    }

    // MARK: Bounds

    func testEnormousParameterValuesCannotIndexOutsideTheGrid() {
        let emulator = makeEmulator(columns: 8, rows: 4)
        for sequence in [
            "\u{1B}[999999;999999H", "\u{1B}[999999A", "\u{1B}[999999B",
            "\u{1B}[999999C", "\u{1B}[999999D", "\u{1B}[999999G", "\u{1B}[999999d",
            "\u{1B}[999999@", "\u{1B}[999999P", "\u{1B}[999999X",
            "\u{1B}[999999L", "\u{1B}[999999M", "\u{1B}[999999S", "\u{1B}[999999T",
            "\u{1B}[999999I", "\u{1B}[999999Z", "\u{1B}[999999b"
        ] {
            emulator.feed(sequence)
            emulator.feed("x")
        }
        XCTAssertLessThan(emulator.cursorRow, emulator.rows)
        XCTAssertLessThan(emulator.cursorCol, emulator.columns)
        XCTAssertEqual(emulator.line(at: emulator.scrollbackLineCount).count, 8)
    }

    func testAnInvertedScrollRegionIsRejected() {
        let emulator = makeEmulator(columns: 4, rows: 4)
        emulator.feed("\u{1B}[4;2r")   // bottom above top
        emulator.feed("a\r\nb\r\nc\r\nd\r\ne")
        // The region stayed full-screen, so this behaves like ordinary output.
        XCTAssertEqual(emulator.screenLines, ["b", "c", "d", "e"])
    }

    func testAnOverlongParameterListIsDiscardedRatherThanExecuted() {
        let emulator = makeEmulator(columns: 8, rows: 4)
        emulator.feed("\u{1B}[31mred")
        let parameters = Array(repeating: "1", count: 400).joined(separator: ";")
        emulator.feed("\u{1B}[\(parameters)m")
        XCTAssertEqual(
            emulator.cell(row: 0, column: 0).style.foreground, .indexed(1),
            "the over-long SGR was dropped whole; it did not partially apply")
        emulator.feed("x")
        XCTAssertEqual(emulator.screenLines[0], "redx", "and its parameter bytes never printed")
    }

    func testRepeatIsBoundedByOneScreenful() {
        let emulator = makeEmulator(columns: 8, rows: 4)
        emulator.feed("a\u{1B}[4294967295b")
        XCTAssertLessThan(emulator.cursorRow, emulator.rows)
        XCTAssertLessThanOrEqual(emulator.scrollbackLineCount, 50)
    }

    // MARK: Payloads that must not reach the screen

    func testDeviceControlStringPayloadIsSwallowed() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}Pq#0;2;0;0;0#0~~@@vv@@~~@@~~$\u{1B}\\after")
        XCTAssertEqual(emulator.screenLines[0], "after", "a DCS payload is data, not text")
    }

    func testApplicationProgramCommandPayloadIsSwallowed() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}_anything at all\u{1B}\\ok")
        XCTAssertEqual(emulator.screenLines[0], "ok")
    }

    func testAnUnterminatedStringDoesNotGrowWithoutBound() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}]0;")
        for _ in 0..<50 { emulator.feed(String(repeating: "z", count: 10_000)) }
        emulator.feed("\u{07}")
        XCTAssertNil(emulator.title, "the accumulator hit its cap and abandoned the sequence")
        emulator.feed("back")
        XCTAssertEqual(emulator.screenLines[0], "back", "and the parser recovered to ground")
    }

    // MARK: Malformed input recovers rather than wedging the parser

    func testAnEscapeInsideACSIRestartsTheSequence() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[31\u{1B}[1;1Hx")
        XCTAssertEqual(emulator.screenLines[0], "x")
    }

    func testCancelBytesAbortASequenceInProgress() {
        let emulator = makeEmulator()
        emulator.feed("\u{1B}[31\u{18}ok")
        XCTAssertEqual(emulator.screenLines[0], "ok")
        emulator.feed("\u{1B}]0;partial\u{1A}")
        XCTAssertNil(emulator.title)
    }

    func testAPartialUTF8SequenceInterruptedByAnEscapeDoesNotSwallowIt() {
        let emulator = makeEmulator()
        emulator.feed(Data([0xE6]))            // start of a three-byte sequence
        emulator.feed("\u{1B}[1;3Hx")          // …abandoned by a real escape
        XCTAssertEqual(emulator.cell(row: 0, column: 2).character, "x")
    }

    func testALoneContinuationByteDoesNotDesynchroniseTheStream() {
        let emulator = makeEmulator()
        emulator.feed(Data([0x80, 0x80]))
        emulator.feed("ok")
        XCTAssertEqual(emulator.screenLines[0], "\u{FFFD}\u{FFFD}ok")
    }

    func testOverlongAndSurrogateEncodingsAreRejected() {
        // C0 80 is an overlong NUL; ED A0 80 is a UTF-8-encoded surrogate half.
        XCTAssertNil(TerminalEmulator.decodeUTF8([0xC0, 0x80]))
        XCTAssertNil(TerminalEmulator.decodeUTF8([0xED, 0xA0, 0x80]))
        XCTAssertEqual(TerminalEmulator.decodeUTF8([0xC3, 0xA9]), "é" as Unicode.Scalar)
    }

    func testACombiningMarkThatCannotJoinIsDroppedRatherThanTrapping() {
        let emulator = makeEmulator()
        // A mark with no base character in front of it, and one after a wide placeholder.
        emulator.feed("\u{0301}")
        emulator.feed("漢\u{0301}")
        XCTAssertEqual(emulator.cursorCol, 2)
    }

    /// A soak over pseudo-random bytes. The assertion is not about what appears — it is
    /// that no input sequence traps, hangs, or leaves the grid ragged.
    func testRandomByteSoakKeepsEveryInvariant() {
        let emulator = TerminalEmulator(columns: 24, rows: 8, scrollbackLimit: 64)
        var seed: UInt64 = 0x5DEECE66D
        func nextByte() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8((seed >> 33) & 0xFF)
        }
        for _ in 0..<200 {
            var chunk = Data()
            for _ in 0..<512 { chunk.append(nextByte()) }
            // Salt with the introducers, so the fuzz spends real time inside the
            // escape/CSI/OSC branches rather than almost always in ground.
            chunk.append(contentsOf: Array("\u{1B}[\u{1B}]\u{1B}P;?0123456789m".utf8))
            emulator.feed(chunk)

            XCTAssertGreaterThanOrEqual(emulator.cursorRow, 0)
            XCTAssertLessThan(emulator.cursorRow, emulator.rows)
            XCTAssertGreaterThanOrEqual(emulator.cursorCol, 0)
            XCTAssertLessThan(emulator.cursorCol, emulator.columns)
            XCTAssertLessThanOrEqual(emulator.scrollbackLineCount, 64)
            for row in 0..<emulator.rows {
                XCTAssertEqual(emulator.line(at: emulator.scrollbackLineCount + row).count, 24)
            }
            if let title = emulator.title {
                XCTAssertLessThanOrEqual(title.count, TerminalCharacterTables.titleCharacterLimit)
            }
        }
    }

    /// The same soak, interleaved with resizes — the combination that historically finds
    /// off-by-one grid corruption.
    func testResizeUnderLoadKeepsTheGridRectangular() {
        let emulator = TerminalEmulator(columns: 20, rows: 6, scrollbackLimit: 32)
        var seed: UInt64 = 12_345
        for step in 0..<120 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let columns = 1 + Int((seed >> 20) % 40)
            let rows = 1 + Int((seed >> 40) % 20)
            emulator.feed("line \(step) \(String(repeating: "#", count: step % 30))\r\n")
            emulator.feed("\u{1B}[?1049\(step % 2 == 0 ? "h" : "l")")
            emulator.resize(columns: columns, rows: rows)
            XCTAssertEqual(emulator.columns, columns)
            XCTAssertEqual(emulator.rows, rows)
            XCTAssertLessThan(emulator.cursorRow, emulator.rows)
            XCTAssertLessThan(emulator.cursorCol, emulator.columns)
            for index in 0..<(emulator.scrollbackLineCount + emulator.rows) {
                XCTAssertEqual(emulator.line(at: index).count, columns)
            }
        }
    }
}
