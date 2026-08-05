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
}
