// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Everything in `TerminalSurfaceView.swift` that doesn't need a window server is
// factored into pure functions specifically so it lands here instead of behind a
// `ui-tour` screenshot: palette math, style-run grouping, selection-range math,
// grid-size-from-view-size, and the keystroke-to-bytes decision table.

import XCTest

@testable import MorbstackAppCore

final class TerminalSurfaceViewTests: XCTestCase {

    // MARK: Palette

    func testAnsi16LightAndDarkTablesDisagree() {
        // The whole point of an appearance-adaptive palette: bright white must not be
        // the same near-invisible value on both a white and a black background.
        let dark = TerminalPalette.components(forIndex: 15, dark: true)
        let light = TerminalPalette.components(forIndex: 15, dark: false)
        XCTAssertNotEqual(dark, light)
        XCTAssertGreaterThan(dark.red, 0.9) // still bright white on a dark background
        XCTAssertLessThan(light.red, 0.9) // darkened so it reads on a light background
    }

    func testXtermCubeIndex16IsBlack() {
        let components = TerminalPalette.components(forIndex: 16, dark: true)
        XCTAssertEqual(components, TerminalRGBA(red: 0, green: 0, blue: 0))
    }

    func testXtermCubeIndex231IsFullWhite() {
        // 231 = the (5,5,5) corner of the 6×6×6 cube, the brightest cube entry.
        let components = TerminalPalette.components(forIndex: 231, dark: true)
        XCTAssertEqual(components.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(components.green, 1.0, accuracy: 0.001)
        XCTAssertEqual(components.blue, 1.0, accuracy: 0.001)
    }

    func testGrayscaleRampEndpoints() {
        let first = TerminalPalette.components(forIndex: 232, dark: true)
        let last = TerminalPalette.components(forIndex: 255, dark: true)
        XCTAssertEqual(first.red, 8.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(last.red, 238.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(first.red, first.green)
        XCTAssertEqual(first.green, first.blue)
    }

    // MARK: Style runs

    func testRunsGroupIdenticallyStyledCellsAndSplitOnChange() {
        var bold = TerminalCellStyle.plain
        bold.bold = true
        let cells: [TerminalCell] = [
            TerminalCell(character: "a"),
            TerminalCell(character: "b"),
            TerminalCell(character: "c", style: bold)
        ]
        let runs = TerminalLineLayout.runs(for: cells)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].text, "ab")
        XCTAssertEqual(runs[0].columnCount, 2)
        XCTAssertEqual(runs[1].text, "c")
        XCTAssertEqual(runs[1].style.bold, true)
    }

    func testWidePlaceholderExtendsRunWidthButContributesNoCharacter() {
        let cells: [TerminalCell] = [
            TerminalCell(character: "\u{1F600}"), // an emoji occupying two columns
            TerminalCell(character: nil, isWidePlaceholder: true)
        ]
        let runs = TerminalLineLayout.runs(for: cells)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].columnCount, 2, "the placeholder's background column must still paint")
        XCTAssertEqual(runs[0].text, "\u{1F600}", "the placeholder contributes no character of its own")
    }

    func testBlankCellsRenderAsSpaces() {
        let runs = TerminalLineLayout.runs(for: [.blank, .blank])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "  ")
    }

    // MARK: Selection range math

    func testSelectionRangeNormalizesRegardlessOfDragDirection() {
        let forward = TerminalSelectionRange(
            anchor: TerminalSelectionPoint(line: 1, column: 2),
            extent: TerminalSelectionPoint(line: 3, column: 4))
        let backward = TerminalSelectionRange(
            anchor: TerminalSelectionPoint(line: 3, column: 4),
            extent: TerminalSelectionPoint(line: 1, column: 2))
        XCTAssertEqual(forward.normalized.start, backward.normalized.start)
        XCTAssertEqual(forward.normalized.end, backward.normalized.end)
    }

    func testSelectedTextSingleLineSlicesBetweenColumns() {
        let lines = ["the quick brown fox"]
        let range = TerminalSelectionRange(
            anchor: TerminalSelectionPoint(line: 0, column: 4),
            extent: TerminalSelectionPoint(line: 0, column: 9))
        let text = TerminalSelectionText.selectedText(range: range, columns: 80) { lines[$0] }
        XCTAssertEqual(text, "quick")
    }

    func testSelectedTextMultiLineJoinsWithNewlines() {
        let lines = ["first line", "middle line", "last line"]
        let range = TerminalSelectionRange(
            anchor: TerminalSelectionPoint(line: 0, column: 6),
            extent: TerminalSelectionPoint(line: 2, column: 4))
        let text = TerminalSelectionText.selectedText(range: range, columns: 80) { lines[$0] }
        XCTAssertEqual(text, "line\nmiddle line\nlast")
    }

    func testSelectAllStyleRangeClampsToLineLength() {
        // selectAll uses `columns` (the screen width) as the extent column; plain text
        // is almost always shorter, so the clamp must not crash or pad with junk.
        let lines = ["short"]
        let range = TerminalSelectionRange(
            anchor: TerminalSelectionPoint(line: 0, column: 0),
            extent: TerminalSelectionPoint(line: 0, column: 80))
        let text = TerminalSelectionText.selectedText(range: range, columns: 80) { lines[$0] }
        XCTAssertEqual(text, "short")
    }

    func testSubstringClampsOutOfRangeBounds() {
        XCTAssertEqual(TerminalSelectionText.substring("hello", from: 2, to: 100), "llo")
        XCTAssertEqual(TerminalSelectionText.substring("hello", from: -5, to: 2), "he")
        XCTAssertEqual(TerminalSelectionText.substring("hello", from: 5, to: 5), "")
    }

    func testWordBoundariesSplitOnWhitespaceAndSeparators() {
        let line = "cd /usr/local/bin && ls"
        // Column 5 lands inside "/usr/local/bin" — the whole path is the word, split
        // in this scheme on '/' as a separator.
        let bounds = TerminalSelectionText.wordBoundaries(in: line, atColumn: 5)
        XCTAssertEqual(String(Array(line)[bounds.start..<bounds.end]), "usr")
    }

    func testWordBoundariesOnASeparatorSelectsJustThatCharacter() {
        let line = "a && b"
        let bounds = TerminalSelectionText.wordBoundaries(in: line, atColumn: 3)
        XCTAssertEqual(bounds.start, 3)
        XCTAssertEqual(bounds.end, 4)
    }

    // MARK: Grid size from view size

    func testGridSizeFloorsToWholeCells() {
        let size = terminalGridSize(
            viewSize: CGSize(width: 100, height: 50),
            cellSize: CGSize(width: 9, height: 17),
            contentInset: 4)
        // Usable width 92 / 9 = 10.2 -> 10 columns; usable height 42 / 17 = 2.47 -> but
        // floored to 2, then held at the 2-row floor.
        XCTAssertEqual(size.columns, 10)
        XCTAssertEqual(size.rows, 2)
    }

    func testGridSizeNeverGoesBelowTheTwoByTwoFloor() {
        let size = terminalGridSize(
            viewSize: CGSize(width: 5, height: 5),
            cellSize: CGSize(width: 9, height: 17),
            contentInset: 4)
        XCTAssertEqual(size.columns, 2)
        XCTAssertEqual(size.rows, 2)
    }

    // MARK: View point to selection point

    func testSelectionPointFromViewCoordinateAccountsForInsetAndScrollback() {
        let point = terminalSelectionPoint(
            atViewPoint: CGPoint(x: 4 + 9 * 3.4, y: 4 + 17 * 2.9),
            contentInset: 4,
            cellSize: CGSize(width: 9, height: 17),
            firstVisibleLine: 100,
            rows: 24,
            columns: 80)
        XCTAssertEqual(point.column, 3)
        XCTAssertEqual(point.line, 102) // firstVisibleLine + row 2
    }

    func testSelectionPointClampsColumnToLineWidth() {
        let point = terminalSelectionPoint(
            atViewPoint: CGPoint(x: 10_000, y: 4),
            contentInset: 4,
            cellSize: CGSize(width: 9, height: 17),
            firstVisibleLine: 0,
            rows: 24,
            columns: 80)
        XCTAssertEqual(point.column, 80)
    }

    // MARK: Key code -> TerminalKey mapping

    func testArrowKeyCodesMapToArrowKeys() {
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.upArrow, shift: false), .up)
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.downArrow, shift: false), .down)
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.leftArrow, shift: false), .left)
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.rightArrow, shift: false), .right)
    }

    func testTabBecomesBackTabUnderShift() {
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.tab, shift: false), .tab)
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.tab, shift: true), .backTab)
    }

    func testReturnAndKeypadEnterBothMapToEnter() {
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.return, shift: false), .enter)
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.keypadEnter, shift: false), .enter)
    }

    func testFunctionKeyCodesMapToNumberedFunctionKeys() {
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.f1, shift: false), .function(1))
        XCTAssertEqual(terminalKey(forKeyCode: TerminalKeyCode.f12, shift: false), .function(12))
    }

    func testOrdinaryLetterKeyCodeIsNotASpecialKey() {
        // 0x00 is the 'A' key's virtual key code — a plain character, not a special key.
        XCTAssertNil(terminalKey(forKeyCode: 0x00, shift: false))
    }

    // MARK: Keystroke -> bytes decision table

    func testSpecialKeyRoutesThroughTerminalKeyEncoding() {
        // Whatever TerminalKeyEncoding.bytes(for:) returns (real implementation or the
        // current stub) is exactly what should come out here — this test asserts the
        // *routing*, not a hardcoded byte sequence that would drift from the real
        // encoder once it lands.
        let expected = TerminalKeyEncoding.bytes(for: .up, applicationCursorKeys: true)
        let actual = terminalKeyDownBytes(
            specialKey: .up, control: false, command: false,
            charactersIgnoringModifiers: nil, characters: nil, applicationCursorKeys: true)
        XCTAssertEqual(actual, expected)
    }

    func testCommandComboSendsNothingEvenForARecognizedSpecialKey() {
        // A Command combination is never terminal input in this view: ⌘C/⌘V/⌘A are
        // copy/paste/selectAll via performKeyEquivalent, and anything else Command
        // should stay silent rather than typing garbage.
        let bytes = terminalKeyDownBytes(
            specialKey: nil, control: false, command: true,
            charactersIgnoringModifiers: "k", characters: "k", applicationCursorKeys: false)
        XCTAssertNil(bytes)
    }

    func testControlLetterFoldsThroughCharacterEncoding() {
        let expected = TerminalKeyEncoding.bytes(forCharacter: "c", control: true)
        let actual = terminalKeyDownBytes(
            specialKey: nil, control: true, command: false,
            charactersIgnoringModifiers: "c", characters: nil, applicationCursorKeys: false)
        XCTAssertEqual(actual, expected)
    }

    func testPlainCharacterFallsThroughToUTF8() {
        let bytes = terminalKeyDownBytes(
            specialKey: nil, control: false, command: false,
            charactersIgnoringModifiers: "a", characters: "a", applicationCursorKeys: false)
        XCTAssertEqual(bytes, "a".data(using: .utf8))
    }

    func testNoCharacterAndNoSpecialKeyProducesNothing() {
        let bytes = terminalKeyDownBytes(
            specialKey: nil, control: false, command: false,
            charactersIgnoringModifiers: nil, characters: nil, applicationCursorKeys: false)
        XCTAssertNil(bytes)
    }

    // MARK: Shift+PageUp/PageDown viewport scrolling

    func testShiftPageUpAndPageDownScrollTheViewport() {
        XCTAssertEqual(
            terminalViewportScroll(forKeyCode: TerminalKeyCode.pageUp, shift: true, isAlternateScreen: false), .up)
        XCTAssertEqual(
            terminalViewportScroll(forKeyCode: TerminalKeyCode.pageDown, shift: true, isAlternateScreen: false), .down)
    }

    func testPlainPageUpWithoutShiftGoesToTheProcessInstead() {
        XCTAssertNil(terminalViewportScroll(forKeyCode: TerminalKeyCode.pageUp, shift: false, isAlternateScreen: false))
    }

    func testShiftPageUpIsDisabledOnTheAlternateScreen() {
        XCTAssertNil(terminalViewportScroll(forKeyCode: TerminalKeyCode.pageUp, shift: true, isAlternateScreen: true))
    }

    // MARK: Cell size measurement sanity

    func testMeasuredCellSizeIsPositive() {
        let size = TerminalSurfaceNSView.measuredCellSize()
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: The wire bytes themselves

    /// The tests above assert that `terminalKeyDownBytes` *routes* through
    /// `TerminalKeyEncoding`; these assert what that encoder actually emits. They are
    /// deliberately hardcoded sequences rather than round-trips through the same
    /// function under test — a table that agrees with itself proves nothing, and these
    /// bytes are a contract with every program running inside the container.

    private func bytes(_ key: TerminalKey, application: Bool = false) -> String {
        String(decoding: TerminalKeyEncoding.bytes(for: key, applicationCursorKeys: application), as: UTF8.self)
    }

    func testArrowKeysFollowDECCKM() {
        // The difference between arrows working in vim and printing letters.
        XCTAssertEqual(bytes(.up), "\u{1B}[A")
        XCTAssertEqual(bytes(.down), "\u{1B}[B")
        XCTAssertEqual(bytes(.right), "\u{1B}[C")
        XCTAssertEqual(bytes(.left), "\u{1B}[D")

        XCTAssertEqual(bytes(.up, application: true), "\u{1B}OA")
        XCTAssertEqual(bytes(.down, application: true), "\u{1B}OB")
        XCTAssertEqual(bytes(.right, application: true), "\u{1B}OC")
        XCTAssertEqual(bytes(.left, application: true), "\u{1B}OD")
    }

    func testHomeAndEndFollowDECCKMButPagingKeysDoNot() {
        XCTAssertEqual(bytes(.home), "\u{1B}[H")
        XCTAssertEqual(bytes(.end), "\u{1B}[F")
        XCTAssertEqual(bytes(.home, application: true), "\u{1B}OH")
        XCTAssertEqual(bytes(.end, application: true), "\u{1B}OF")

        // The VT220 tilde keys are not cursor keys; DECCKM must not touch them.
        for application in [false, true] {
            XCTAssertEqual(bytes(.insert, application: application), "\u{1B}[2~")
            XCTAssertEqual(bytes(.delete, application: application), "\u{1B}[3~")
            XCTAssertEqual(bytes(.pageUp, application: application), "\u{1B}[5~")
            XCTAssertEqual(bytes(.pageDown, application: application), "\u{1B}[6~")
        }
    }

    func testFunctionKeysUseTheHistoricalNumbering() {
        XCTAssertEqual(bytes(.function(1)), "\u{1B}OP")
        XCTAssertEqual(bytes(.function(4)), "\u{1B}OS")
        // The gaps at 16 and 22 are real; terminfo has carried them since the VT220.
        XCTAssertEqual(bytes(.function(5)), "\u{1B}[15~")
        XCTAssertEqual(bytes(.function(6)), "\u{1B}[17~")
        XCTAssertEqual(bytes(.function(10)), "\u{1B}[21~")
        XCTAssertEqual(bytes(.function(11)), "\u{1B}[23~")
        XCTAssertEqual(bytes(.function(12)), "\u{1B}[24~")
        XCTAssertTrue(TerminalKeyEncoding.bytes(for: .function(99), applicationCursorKeys: false).isEmpty)
    }

    func testReturnSendsCarriageReturnAndBackspaceSendsDEL() {
        // CR, not LF: the container's line discipline converts it. LF here breaks
        // `read -r` and several shells' line editing.
        XCTAssertEqual(TerminalKeyEncoding.bytes(for: .enter, applicationCursorKeys: false), Data([0x0D]))
        // DEL, not BS: what a Mac keyboard sends and what `stty erase` expects.
        XCTAssertEqual(TerminalKeyEncoding.bytes(for: .backspace, applicationCursorKeys: false), Data([0x7F]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(for: .tab, applicationCursorKeys: false), Data([0x09]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(for: .escape, applicationCursorKeys: false), Data([0x1B]))
        XCTAssertEqual(bytes(.backTab), "\u{1B}[Z")
    }

    func testControlFoldsLettersToTheC0Range() {
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "c", control: true), Data([0x03]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "C", control: true), Data([0x03]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "d", control: true), Data([0x04]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "z", control: true), Data([0x1A]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "a", control: true), Data([0x01]))
    }

    func testControlFoldsThePunctuationAndDigitAliases() {
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "@", control: true), Data([0x00]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: " ", control: true), Data([0x00]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "[", control: true), Data([0x1B]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "\\", control: true), Data([0x1C]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "?", control: true), Data([0x7F]))
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "6", control: true), Data([0x1E]))
    }

    func testAnUnmappedControlCombinationSendsTheLiteralCharacter() {
        // Swallowing it would silently eat a keystroke the person deliberately typed.
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "é", control: true), Data("é".utf8))
    }

    func testPlainCharacterEncodesAsUTF8() {
        XCTAssertEqual(TerminalKeyEncoding.bytes(forCharacter: "漢", control: false), Data("漢".utf8))
    }

    // MARK: Paste

    func testPasteNormalisesNewlinesToCarriageReturn() {
        let data = TerminalKeyEncoding.pasteData("one\ntwo\r\nthree", bracketed: false)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one\rtwo\rthree")
    }

    func testBracketedPasteIsFenced() {
        let data = TerminalKeyEncoding.pasteData("ls", bracketed: true)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\u{1B}[200~ls\u{1B}[201~")
    }

    /// The documented bracketed-paste escape: text carrying the *terminator* would close
    /// the fence early, and everything after it would reach the shell as typed input —
    /// i.e. a clipboard that can run a command. Clipboard contents are untrusted (they
    /// routinely come off a web page), so the payload is neutralised, not trusted.
    func testBracketedPasteStripsAnEmbeddedTerminator() {
        let hostile = "safe\u{1B}[201~\rrm -rf /\r"
        let data = TerminalKeyEncoding.pasteData(hostile, bracketed: true)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text, "\u{1B}[200~safe\rrm -rf /\r\u{1B}[201~")
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[201~").count - 1, 1, "exactly one terminator, at the end")
    }
}
