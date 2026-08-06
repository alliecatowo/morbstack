// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Keystrokes to wire bytes, the xterm way. Pure functions so every mapping — arrows
// under DECCKM, ⌃C, a bracketed paste — is a table a test can read back.

import Foundation

/// The non-character keys the terminal view forwards.
enum TerminalKey: Equatable, Sendable {
    case up, down, left, right
    case home, end, pageUp, pageDown
    case insert
    /// Forward delete (the DEL key), not backspace.
    case delete
    case escape
    case tab
    /// Shift-tab.
    case backTab
    case enter
    case backspace
    /// F1–F12.
    case function(Int)
}

enum TerminalKeyEncoding {

    private static let escape: UInt8 = 0x1B

    /// The byte sequence one special key sends. `applicationCursorKeys` is the
    /// emulator's live DECCKM state — `SS3 A` versus `CSI A` is exactly the difference
    /// between arrows working and printing letters inside vim.
    static func bytes(for key: TerminalKey, applicationCursorKeys: Bool) -> Data {
        switch key {
        // The cursor and Home/End cluster is the whole point of DECCKM: under it the
        // introducer is `SS3` (`ESC O`), otherwise `CSI` (`ESC [`). The final byte is
        // identical either way.
        case .up: return cursorSequence("A", applicationCursorKeys)
        case .down: return cursorSequence("B", applicationCursorKeys)
        case .right: return cursorSequence("C", applicationCursorKeys)
        case .left: return cursorSequence("D", applicationCursorKeys)
        case .home: return cursorSequence("H", applicationCursorKeys)
        case .end: return cursorSequence("F", applicationCursorKeys)

        // The editing/paging keys are VT220 tilde sequences and are *not* affected by
        // DECCKM — a common bug, and the reason these are a separate branch.
        case .insert: return tildeSequence(2)
        case .delete: return tildeSequence(3)
        case .pageUp: return tildeSequence(5)
        case .pageDown: return tildeSequence(6)

        case .escape: return Data([escape])
        case .tab: return Data([0x09])
        case .backTab: return csi("Z")
        // CR, not LF. A terminal in its normal (ICRNL) configuration sends carriage
        // return for Return; the line discipline in the container turns it into a
        // newline. Sending `\n` here makes some shells and every `read -r` misbehave.
        case .enter: return Data([0x0D])
        // DEL (0x7F), not BS (0x08) — what macOS keyboards send and what the default
        // `stty erase` inside a Linux container expects.
        case .backspace: return Data([0x7F])

        case .function(let number): return functionKey(number)
        }
    }

    /// The bytes for a typed character with modifiers: `control` folds to the C0 range
    /// (⌃C → 0x03, ⌃@ → 0x00), otherwise UTF-8. Returns nil for combinations that send
    /// nothing.
    static func bytes(forCharacter character: Character, control: Bool) -> Data? {
        guard control else {
            let utf8 = Data(String(character).utf8)
            return utf8.isEmpty ? nil : utf8
        }
        if let folded = controlByte(for: character) { return Data([folded]) }
        // An unmapped Control combination (⌃é, ⌃F1) is not an error and not a NUL — the
        // literal character is what xterm sends, and swallowing it would silently eat a
        // keystroke the person deliberately typed.
        let utf8 = Data(String(character).utf8)
        return utf8.isEmpty ? nil : utf8
    }

    /// A paste, fenced with `ESC [200~` … `ESC [201~` when the program asked for
    /// bracketed paste. CR-normalised: terminals paste `\r`, not `\n`.
    static func pasteData(_ text: String, bracketed: Bool) -> Data {
        let normalized = normalizeNewlines(text)
        guard bracketed else { return Data(normalized.utf8) }
        // Security: a paste whose own bytes contain the bracketed-paste *terminator*
        // would close the fence early and hand the remainder to the shell as typed
        // input — the documented bracketed-paste escape. The payload is neutralised by
        // removing the terminator rather than by trusting the clipboard, because
        // clipboard contents are as untrusted as anything else that came off a web page.
        let fenced = normalized.replacingOccurrences(of: "\u{1B}[201~", with: "")
        return csi("200~") + Data(fenced.utf8) + csi("201~")
    }

    // MARK: Sequence builders

    private static func csi(_ tail: String) -> Data {
        Data([escape, UInt8(ascii: "[")]) + Data(tail.utf8)
    }

    private static func ss3(_ tail: String) -> Data {
        Data([escape, UInt8(ascii: "O")]) + Data(tail.utf8)
    }

    private static func cursorSequence(_ final: String, _ applicationCursorKeys: Bool) -> Data {
        applicationCursorKeys ? ss3(final) : csi(final)
    }

    private static func tildeSequence(_ number: Int) -> Data {
        csi("\(number)~")
    }

    /// F1–F4 are `SS3 P`…`SS3 S` (the VT100 PF keys); F5–F12 are tilde sequences with
    /// the historical gaps at 16 and 22 that every real terminfo entry carries.
    private static func functionKey(_ number: Int) -> Data {
        switch number {
        case 1: return ss3("P")
        case 2: return ss3("Q")
        case 3: return ss3("R")
        case 4: return ss3("S")
        case 5: return tildeSequence(15)
        case 6: return tildeSequence(17)
        case 7: return tildeSequence(18)
        case 8: return tildeSequence(19)
        case 9: return tildeSequence(20)
        case 10: return tildeSequence(21)
        case 11: return tildeSequence(23)
        case 12: return tildeSequence(24)
        default: return Data()
        }
    }

    // MARK: Control folding

    /// The C0 fold. Letters are case-insensitive (⇧⌃C is still 0x03); the punctuation
    /// and digit aliases are xterm's, and they matter — ⌃[ is the only way to type
    /// Escape on some layouts and ⌃? is the erase character.
    private static func controlByte(for character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return ascii - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return ascii - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"):
            return 0x00
        case UInt8(ascii: "["), UInt8(ascii: "3"):
            return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"):
            return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"):
            return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"):
            return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "7"), UInt8(ascii: "/"):
            return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"):
            return 0x7F
        default:
            return nil
        }
    }

    /// CRLF and LF both become a bare CR: a terminal has no notion of a line feed on
    /// input, and a pasted `\n` would reach the shell as ⌃J rather than as Return.
    static func normalizeNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
    }
}
