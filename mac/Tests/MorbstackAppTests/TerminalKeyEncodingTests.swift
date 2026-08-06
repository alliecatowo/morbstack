// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// The anchor for the whole terminal input path: every assertion here is a hardcoded
// byte sequence, never a value re-derived from the encoder under test.
//
// This file exists because `TerminalSurfaceViewTests` deliberately tests *routing* —
// it compares `terminalKeyDownBytes(...)` against `TerminalKeyEncoding.bytes(...)`,
// which holds for every implementation including one that returns `Data()`. That is a
// legitimate test of the decision table, but it cannot stand alone: for several days
// all three `TerminalKeyEncoding` functions were stubs returning empty values and the
// suite stayed green. Pinning the literals here is what makes the routing test mean
// something.
//
// Byte sequences are taken from "XTerm Control Sequences" (Thomas E. Dickey,
// ctlseqs.txt), sections "PC-Style Function Keys" and "VT220-Style Function Keys",
// plus DEC STD 070 for DECCKM (private mode 1). Where xterm and the VT220 disagree the
// comment says which one we follow and why.
//
// If a change here is deliberate, it must come with the xterm citation that justifies
// it. Do not "fix" a failure by reading the new value out of the implementation.

import XCTest

@testable import MorbstackAppCore

final class TerminalKeyEncodingTests: XCTestCase {

    /// Renders `Data` as an escaped ASCII string so a failure message is readable —
    /// `ESC[A` rather than `5 bytes`. Deliberately not used to build expectations.
    private func describe(_ data: Data) -> String {
        data.map { byte in
            switch byte {
            case 0x1B: return "ESC"
            case 0x0D: return "CR"
            case 0x0A: return "LF"
            case 0x09: return "HT"
            case 0x7F: return "DEL"
            case 0x20: return "SP"
            case 0x21...0x7E: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02X", byte)
            }
        }.joined()
    }

    private func assertBytes(
        _ actual: Data, _ expected: [UInt8], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Array(actual), expected,
            "\(message) — got \(describe(actual)), want \(describe(Data(expected)))",
            file: file, line: line)
    }

    // MARK: Cursor keys under DECCKM

    // The single most load-bearing distinction in the file. With DECCKM set (which
    // vim, less and every readline program set on entry) an arrow key must introduce
    // with SS3, not CSI. Send `ESC[A` to vim in application mode and the user sees the
    // letter A appear instead of the cursor moving.

    func testUpArrowIsCSIAInNormalCursorMode() {
        assertBytes(
            TerminalKeyEncoding.bytes(for: .up, applicationCursorKeys: false),
            [0x1B, 0x5B, 0x41], "up arrow, DECCKM reset, must be ESC [ A")
    }

    func testUpArrowIsSS3AUnderApplicationCursorKeys() {
        assertBytes(
            TerminalKeyEncoding.bytes(for: .up, applicationCursorKeys: true),
            [0x1B, 0x4F, 0x41], "up arrow, DECCKM set, must be ESC O A")
    }

    func testAllFourArrowsUseTheABCDFinalsInNormalMode() {
        // The final byte order is A/B/C/D = up/down/right/left. Transposing right and
        // left here is a classic and very visible bug.
        assertBytes(TerminalKeyEncoding.bytes(for: .up, applicationCursorKeys: false), [0x1B, 0x5B, 0x41], "up")
        assertBytes(TerminalKeyEncoding.bytes(for: .down, applicationCursorKeys: false), [0x1B, 0x5B, 0x42], "down")
        assertBytes(TerminalKeyEncoding.bytes(for: .right, applicationCursorKeys: false), [0x1B, 0x5B, 0x43], "right")
        assertBytes(TerminalKeyEncoding.bytes(for: .left, applicationCursorKeys: false), [0x1B, 0x5B, 0x44], "left")
    }

    func testAllFourArrowsKeepTheSameFinalsUnderApplicationCursorKeys() {
        // DECCKM changes only the introducer; the final byte is unchanged.
        assertBytes(TerminalKeyEncoding.bytes(for: .up, applicationCursorKeys: true), [0x1B, 0x4F, 0x41], "up")
        assertBytes(TerminalKeyEncoding.bytes(for: .down, applicationCursorKeys: true), [0x1B, 0x4F, 0x42], "down")
        assertBytes(TerminalKeyEncoding.bytes(for: .right, applicationCursorKeys: true), [0x1B, 0x4F, 0x43], "right")
        assertBytes(TerminalKeyEncoding.bytes(for: .left, applicationCursorKeys: true), [0x1B, 0x4F, 0x44], "left")
    }

    func testHomeAndEndFollowTheCursorKeyIntroducer() {
        // xterm groups Home/End with the cursor keys: CSI H / CSI F normally, SS3 H /
        // SS3 F under DECCKM. (The VT220 `CSI 1~` / `CSI 4~` forms are a different
        // keyboard's Find/Select keys; xterm's PC-style table is what we target.)
        assertBytes(TerminalKeyEncoding.bytes(for: .home, applicationCursorKeys: false), [0x1B, 0x5B, 0x48], "home, CSI H")
        assertBytes(TerminalKeyEncoding.bytes(for: .end, applicationCursorKeys: false), [0x1B, 0x5B, 0x46], "end, CSI F")
        assertBytes(TerminalKeyEncoding.bytes(for: .home, applicationCursorKeys: true), [0x1B, 0x4F, 0x48], "home, SS3 H")
        assertBytes(TerminalKeyEncoding.bytes(for: .end, applicationCursorKeys: true), [0x1B, 0x4F, 0x46], "end, SS3 F")
    }

    // MARK: Editing keypad

    func testEditingKeypadUsesCSINumberTildeAndIgnoresDECCKM() {
        // Insert/Delete/PageUp/PageDown are `CSI <n> ~` in both cursor-key modes —
        // DECCKM governs the cursor keys only.
        for applicationCursorKeys in [false, true] {
            let mode = applicationCursorKeys ? "DECCKM set" : "DECCKM reset"
            assertBytes(
                TerminalKeyEncoding.bytes(for: .insert, applicationCursorKeys: applicationCursorKeys),
                [0x1B, 0x5B, 0x32, 0x7E], "insert must be ESC [ 2 ~ (\(mode))")
            assertBytes(
                TerminalKeyEncoding.bytes(for: .delete, applicationCursorKeys: applicationCursorKeys),
                [0x1B, 0x5B, 0x33, 0x7E], "forward delete must be ESC [ 3 ~ (\(mode))")
            assertBytes(
                TerminalKeyEncoding.bytes(for: .pageUp, applicationCursorKeys: applicationCursorKeys),
                [0x1B, 0x5B, 0x35, 0x7E], "page up must be ESC [ 5 ~ (\(mode))")
            assertBytes(
                TerminalKeyEncoding.bytes(for: .pageDown, applicationCursorKeys: applicationCursorKeys),
                [0x1B, 0x5B, 0x36, 0x7E], "page down must be ESC [ 6 ~ (\(mode))")
        }
    }

    // MARK: Control keys

    func testBackspaceSendsDELNotBS() {
        // xterm's default `backarrowKey: false`, and what `stty erase ^?` expects on
        // both macOS and Linux. Sending BS (0x08) here makes backspace print `^H` at
        // a bash prompt instead of deleting.
        assertBytes(
            TerminalKeyEncoding.bytes(for: .backspace, applicationCursorKeys: false),
            [0x7F], "backspace must be DEL")
    }

    func testForwardDeleteIsNotBackspace() {
        // Guards the one distinction the `TerminalKey` doc comment calls out.
        XCTAssertNotEqual(
            TerminalKeyEncoding.bytes(for: .delete, applicationCursorKeys: false),
            TerminalKeyEncoding.bytes(for: .backspace, applicationCursorKeys: false))
    }

    func testEnterSendsCarriageReturnNotLineFeed() {
        // A shell's line editor reads CR as "submit". LF is a different keystroke.
        assertBytes(
            TerminalKeyEncoding.bytes(for: .enter, applicationCursorKeys: false),
            [0x0D], "enter must be CR")
    }

    func testTabAndEscapeAreBareC0Bytes() {
        assertBytes(TerminalKeyEncoding.bytes(for: .tab, applicationCursorKeys: false), [0x09], "tab must be HT")
        assertBytes(TerminalKeyEncoding.bytes(for: .escape, applicationCursorKeys: false), [0x1B], "escape must be ESC")
    }

    func testBackTabIsCSIZ() {
        assertBytes(
            TerminalKeyEncoding.bytes(for: .backTab, applicationCursorKeys: false),
            [0x1B, 0x5B, 0x5A], "shift-tab must be ESC [ Z")
    }

    // MARK: Function keys

    func testF1ThroughF4UseSS3PQRS() {
        // The VT220 keeps F1–F4 on the SS3 introducer even in normal cursor-key mode.
        assertBytes(TerminalKeyEncoding.bytes(for: .function(1), applicationCursorKeys: false), [0x1B, 0x4F, 0x50], "F1 = SS3 P")
        assertBytes(TerminalKeyEncoding.bytes(for: .function(2), applicationCursorKeys: false), [0x1B, 0x4F, 0x51], "F2 = SS3 Q")
        assertBytes(TerminalKeyEncoding.bytes(for: .function(3), applicationCursorKeys: false), [0x1B, 0x4F, 0x52], "F3 = SS3 R")
        assertBytes(TerminalKeyEncoding.bytes(for: .function(4), applicationCursorKeys: false), [0x1B, 0x4F, 0x53], "F4 = SS3 S")
    }

    func testF5ThroughF12SkipTheNumbers16And22() {
        // The gaps are the whole reason this table cannot be computed from `n`. F5 is
        // 15, and the run breaks again between F10 (21) and F11 (23).
        let expected: [Int: [UInt8]] = [
            5: [0x31, 0x35], // 15
            6: [0x31, 0x37], // 17 — 16 is skipped
            7: [0x31, 0x38], // 18
            8: [0x31, 0x39], // 19
            9: [0x32, 0x30], // 20
            10: [0x32, 0x31], // 21
            11: [0x32, 0x33], // 23 — 22 is skipped
            12: [0x32, 0x34] // 24
        ]
        for (key, digits) in expected.sorted(by: { $0.key < $1.key }) {
            assertBytes(
                TerminalKeyEncoding.bytes(for: .function(key), applicationCursorKeys: false),
                [0x1B, 0x5B] + digits + [0x7E], "F\(key)")
        }
    }

    func testEveryFunctionKeyEncodingIsDistinct() {
        // Catches a table where two entries were copy-pasted to the same number, which
        // the per-key assertions above would each still pass individually if the wrong
        // literal were pasted into both.
        let encodings = (1...12).map { TerminalKeyEncoding.bytes(for: .function($0), applicationCursorKeys: false) }
        XCTAssertEqual(Set(encodings).count, 12)
    }

    func testFunctionKeyOutsideTheKeypadSendsNothing() {
        XCTAssertTrue(TerminalKeyEncoding.bytes(for: .function(13), applicationCursorKeys: false).isEmpty)
        XCTAssertTrue(TerminalKeyEncoding.bytes(for: .function(0), applicationCursorKeys: false).isEmpty)
    }

    func testNoSpecialKeyEncodesToEmptyExceptOutOfRangeFunctionKeys() {
        // A blanket guard against the exact regression this file was written for: a
        // stubbed encoder returning `Data()` for everything.
        let keys: [TerminalKey] = [
            .up, .down, .left, .right, .home, .end, .pageUp, .pageDown,
            .insert, .delete, .escape, .tab, .backTab, .enter, .backspace
        ] + (1...12).map { TerminalKey.function($0) }
        for key in keys {
            for applicationCursorKeys in [false, true] {
                XCTAssertFalse(
                    TerminalKeyEncoding.bytes(for: key, applicationCursorKeys: applicationCursorKeys).isEmpty,
                    "\(key) encoded to no bytes")
            }
        }
    }

    // MARK: Control-character folding

    func testControlLettersFoldIntoTheC0Range() {
        // ⌃C is 0x03 — the byte that makes the kernel's line discipline raise SIGINT.
        // This is the single most important keystroke in a container terminal.
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "c", control: true) ?? Data(), [0x03], "⌃C must be ETX")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "d", control: true) ?? Data(), [0x04], "⌃D must be EOT")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "z", control: true) ?? Data(), [0x1A], "⌃Z must be SUB")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "a", control: true) ?? Data(), [0x01], "⌃A must be SOH")
    }

    func testControlFoldingIsCaseInsensitive() {
        // charactersIgnoringModifiers hands us an uppercase letter when shift is also
        // held; ⇧⌃C must still be 0x03.
        XCTAssertEqual(
            TerminalKeyEncoding.bytes(forCharacter: "C", control: true),
            TerminalKeyEncoding.bytes(forCharacter: "c", control: true))
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "C", control: true) ?? Data(), [0x03], "⇧⌃C")
    }

    func testControlPunctuationCoversTheWholeC0Range() {
        // The non-letter foldings, which the `& 0x1F` mask handles and a letters-only
        // table would silently drop.
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "@", control: true) ?? Data(), [0x00], "⌃@ must be NUL")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: " ", control: true) ?? Data(), [0x00], "⌃Space must be NUL")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "[", control: true) ?? Data(), [0x1B], "⌃[ must be ESC")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "\\", control: true) ?? Data(), [0x1C], "⌃\\ must be FS (SIGQUIT)")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "]", control: true) ?? Data(), [0x1D], "⌃] must be GS")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "_", control: true) ?? Data(), [0x1F], "⌃_ must be US")
    }

    func testControlQuestionMarkAndSlashAreTheTwoExceptionsToMasking() {
        // Neither follows `& 0x1F`: ⌃? is DEL, and ⌃/ is US by convention.
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "?", control: true) ?? Data(), [0x7F], "⌃? must be DEL")
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "/", control: true) ?? Data(), [0x1F], "⌃/ must be US")
    }

    func testControlDigitSendsThePlainCharacter() {
        // ⌃1 has no C0 counterpart; xterm sends the digit.
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "1", control: true) ?? Data(), [0x31], "⌃1")
    }

    func testControlWithNonASCIISendsTheLiteralCharacter() {
        // ⌃ has no C0 mapping for a non-ASCII character. Swallowing it would silently
        // eat a keystroke the person deliberately typed, so the literal character is
        // what reaches the process — matching xterm and pinned independently in
        // TerminalSurfaceViewTests.testAnUnmappedControlCombinationSendsTheLiteralCharacter.
        assertBytes(
            TerminalKeyEncoding.bytes(forCharacter: "é", control: true) ?? Data(),
            [0xC3, 0xA9], "control-é falls through to the literal UTF-8 bytes")
        assertBytes(
            TerminalKeyEncoding.bytes(forCharacter: "😀", control: true) ?? Data(),
            [0xF0, 0x9F, 0x98, 0x80], "control-emoji falls through to the literal UTF-8 bytes")
    }

    func testPlainCharacterIsUTF8() {
        assertBytes(TerminalKeyEncoding.bytes(forCharacter: "a", control: false) ?? Data(), [0x61], "plain a")
        assertBytes(
            TerminalKeyEncoding.bytes(forCharacter: "é", control: false) ?? Data(),
            [0xC3, 0xA9], "é must be its two UTF-8 bytes")
        assertBytes(
            TerminalKeyEncoding.bytes(forCharacter: "😀", control: false) ?? Data(),
            [0xF0, 0x9F, 0x98, 0x80], "emoji must be its four UTF-8 bytes")
    }

    // MARK: Paste

    func testUnbracketedPasteIsJustTheText() {
        assertBytes(TerminalKeyEncoding.pasteData("ls", bracketed: false), [0x6C, 0x73], "ls")
    }

    func testBracketedPasteIsFencedWith200And201() {
        assertBytes(
            TerminalKeyEncoding.pasteData("ls", bracketed: true),
            [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC [ 200 ~
                + [0x6C, 0x73] // ls
                + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], // ESC [ 201 ~
            "bracketed paste fence")
    }

    func testPasteNormalizesLineEndingsToCarriageReturn() {
        // The reason a multi-line paste into a shell works at all. LF would leave the
        // line editor waiting; CRLF would submit each line twice.
        assertBytes(
            TerminalKeyEncoding.pasteData("a\nb", bracketed: false),
            [0x61, 0x0D, 0x62], "LF must become CR")
        assertBytes(
            TerminalKeyEncoding.pasteData("a\r\nb", bracketed: false),
            [0x61, 0x0D, 0x62], "CRLF must collapse to a single CR")
        assertBytes(
            TerminalKeyEncoding.pasteData("a\rb", bracketed: false),
            [0x61, 0x0D, 0x62], "a bare CR must survive unchanged")
    }

    func testPasteNormalizationAppliesInsideTheBracketedFence() {
        assertBytes(
            TerminalKeyEncoding.pasteData("a\nb", bracketed: true),
            [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
                + [0x61, 0x0D, 0x62]
                + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E],
            "normalisation must not be skipped when bracketed")
    }

    func testEmptyPasteIsEmptyUnbracketedButStillFencedWhenBracketed() {
        XCTAssertTrue(TerminalKeyEncoding.pasteData("", bracketed: false).isEmpty)
        assertBytes(
            TerminalKeyEncoding.pasteData("", bracketed: true),
            [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E, 0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E],
            "an empty bracketed paste still brackets")
    }

    func testPasteCarriesUTF8Through() {
        assertBytes(
            TerminalKeyEncoding.pasteData("é", bracketed: false), [0xC3, 0xA9], "é")
    }
}
