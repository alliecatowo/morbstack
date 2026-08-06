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

    // The tables below are xterm's, from "XTerm Control Sequences" (Thomas E. Dickey,
    // ctlseqs.txt) — sections "PC-Style Function Keys" for the arrows/editing keys and
    // "VT220-Style Function Keys" for F1–F12 — plus DEC STD 070's DECCKM (private mode
    // 1), which is what flips the cursor keys between CSI and SS3 introducers.
    //
    // Two byte-level notes that are easy to get wrong and expensive to get wrong:
    //   * F5–F12 skip the numbers 16 and 22. That is not a typo, it is the historical
    //     VT220 keypad numbering, and off-by-one here silently mis-reports keys.
    //   * Backspace sends DEL (0x7F), not BS (0x08). That is xterm's default
    //     `backarrowKey: false` and matches `stty erase ^?` on macOS and Linux.

    /// ESC, the introducer for every sequence below.
    private static let esc: UInt8 = 0x1B
    /// `ESC [` — CSI, the 7-bit control sequence introducer.
    private static let csi: [UInt8] = [0x1B, 0x5B]
    /// `ESC O` — SS3, the single-shift used for application-mode cursor and F1–F4.
    private static let ss3: [UInt8] = [0x1B, 0x4F]

    /// The byte sequence one special key sends. `applicationCursorKeys` is the
    /// emulator's live DECCKM state — `SS3 A` versus `CSI A` is exactly the difference
    /// between arrows working and printing letters inside vim.
    static func bytes(for key: TerminalKey, applicationCursorKeys: Bool) -> Data {
        /// Cursor and Home/End take SS3 under DECCKM and CSI otherwise; everything
        /// else is CSI regardless.
        func cursor(_ final: UInt8) -> Data {
            Data((applicationCursorKeys ? ss3 : csi) + [final])
        }
        /// The `CSI <number> ~` editing-keypad form.
        func tilde(_ number: Int) -> Data {
            Data(csi + Array(String(number).utf8) + [0x7E])
        }

        switch key {
        case .up: return cursor(0x41) // A
        case .down: return cursor(0x42) // B
        case .right: return cursor(0x43) // C
        case .left: return cursor(0x44) // D
        case .home: return cursor(0x48) // H
        case .end: return cursor(0x46) // F

        case .insert: return tilde(2)
        case .delete: return tilde(3) // forward delete, not backspace
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)

        case .escape: return Data([esc])
        case .tab: return Data([0x09]) // HT
        case .backTab: return Data(csi + [0x5A]) // CSI Z
        case .enter: return Data([0x0D]) // CR, never LF
        case .backspace: return Data([0x7F]) // DEL, see note above

        case .function(let n):
            // F1–F4 are SS3 P/Q/R/S; F5–F12 are CSI <n> ~ with 16 and 22 skipped.
            switch n {
            case 1: return Data(ss3 + [0x50]) // P
            case 2: return Data(ss3 + [0x51]) // Q
            case 3: return Data(ss3 + [0x52]) // R
            case 4: return Data(ss3 + [0x53]) // S
            case 5: return tilde(15)
            case 6: return tilde(17)
            case 7: return tilde(18)
            case 8: return tilde(19)
            case 9: return tilde(20)
            case 10: return tilde(21)
            case 11: return tilde(23)
            case 12: return tilde(24)
            default: return Data() // no such key on a VT220 keypad
            }
        }
    }

    /// The bytes for a typed character with modifiers: `control` folds to the C0 range
    /// (⌃C → 0x03, ⌃@ → 0x00), otherwise UTF-8. Returns nil for combinations that send
    /// nothing.
    static func bytes(forCharacter character: Character, control: Bool) -> Data? {
        let utf8 = Data(String(character).utf8)
        guard control else { return utf8.isEmpty ? nil : utf8 }

        // ⌃ with a non-ASCII character has no C0 meaning and sends nothing at all,
        // rather than leaking the bare character to the process.
        guard let ascii = character.asciiValue else { return nil }

        switch ascii {
        case 0x3F: return Data([0x7F]) // ⌃? → DEL
        case 0x2F: return Data([0x1F]) // ⌃/ → US, by convention rather than by masking
        case 0x20, 0x40...0x5F, 0x61...0x7A:
            // Space, @ A–Z [ \ ] ^ _, and a–z all fold by masking off the top three
            // bits: ⌃@ → 0x00, ⌃C → 0x03, ⌃[ → 0x1B (ESC), ⌃_ → 0x1F.
            return Data([ascii & 0x1F])
        default:
            // Digits and punctuation with no C0 counterpart send the plain character,
            // which is what xterm does for ⌃1.
            return utf8
        }
    }

    /// A paste, fenced with `ESC [200~` … `ESC [201~` when the program asked for
    /// bracketed paste. CR-normalised: terminals paste `\r`, not `\n`.
    static func pasteData(_ text: String, bracketed: Bool) -> Data {
        // A pasted line ending must arrive as CR. Feeding LF to a shell's line editor
        // is not the same keystroke and readline will not treat it as Enter.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")

        guard bracketed else { return Data(normalized.utf8) }

        var data = Data(csi + Array("200~".utf8))
        data.append(contentsOf: normalized.utf8)
        data.append(contentsOf: csi + Array("201~".utf8))
        return data
    }
}
