// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// The three pure lookups the emulator needs on every printable scalar, kept out of the
// state machine so each is a table a test can read back directly: how many cells a
// scalar occupies, whether it is a mark that belongs to the cell before it, and the DEC
// special-graphics substitution that turns `qqqk` into a box corner.
//
// Also here: the sanitiser every string that arrives from the guest passes through
// before it can reach a window title. That is a security boundary, not a formatting
// nicety — see `sanitizedWindowTitle`.

import Foundation

enum TerminalCharacterTables {

    // MARK: Width

    /// Cells a scalar occupies: 0 for a mark that attaches to the previous cell, 2 for
    /// an East Asian wide or emoji-presentation scalar, 1 otherwise.
    ///
    /// Approximated from Unicode block ranges rather than the full UAX #11 tables. The
    /// gap is real and recorded in `docs/exec.md`: an unusual scalar just inside a block
    /// boundary can be measured one cell wrong, which shifts the rest of that line until
    /// the program repaints it. It cannot corrupt the grid — every write is clamped to
    /// the row — and it cannot desynchronise the parser.
    static func cellWidth(of scalar: Unicode.Scalar) -> Int {
        if isCombining(scalar) { return 0 }
        return isWide(scalar) ? 2 : 1
    }

    /// A nonspacing/enclosing mark, a joiner, or a variation selector — anything that
    /// modifies the cell already written rather than claiming one of its own.
    static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Zero-width space/joiner cluster and the bidi controls, none of which advance
        // the cursor in a cell grid.
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0xFEFF:
            return true
        // Variation selectors, including the supplement plane block.
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    /// The wide ranges an interactive Linux userland actually produces: CJK, Hangul,
    /// fullwidth forms, and the emoji planes.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,          // Hangul Jamo initial consonants
             0x2E80...0x303E,          // CJK radicals … CJK symbols (excluding U+303F)
             0x3041...0x33FF,          // Hiragana … CJK compatibility
             0x3400...0x4DBF,          // CJK extension A
             0x4E00...0x9FFF,          // CJK unified ideographs
             0xA000...0xA4CF,          // Yi
             0xA960...0xA97F,          // Hangul Jamo extended-A
             0xAC00...0xD7A3,          // Hangul syllables
             0xF900...0xFAFF,          // CJK compatibility ideographs
             0xFE10...0xFE19,          // Vertical forms
             0xFE30...0xFE6F,          // CJK compatibility forms
             0xFF00...0xFF60,          // Fullwidth forms
             0xFFE0...0xFFE6,          // Fullwidth signs
             0x1F300...0x1F64F,        // Misc symbols and pictographs, emoticons
             0x1F900...0x1F9FF,        // Supplemental symbols and pictographs
             0x20000...0x2FFFD,        // CJK extension B and beyond
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: DEC special graphics

    /// The line-drawing substitution for `ESC ( 0` / `SO`. Only 0x5F–0x7E is remapped;
    /// every other byte passes through as itself, which is what the charset actually
    /// specifies.
    static func decSpecialGraphics(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x5F, scalar.value <= 0x7E else { return scalar }
        let index = Int(scalar.value - 0x5F)
        return decGraphicsTable[index]
    }

    private static let decGraphicsTable: [Unicode.Scalar] = [
        " ", "◆", "▒", "␉", "␌", "␍", "␊", "°",   // 0x5F … 0x66
        "±", "␤", "␋", "┘", "┐", "┌", "└", "┼",   // 0x67 … 0x6E
        "⎺", "⎻", "─", "⎼", "⎽", "├", "┤", "┴",   // 0x6F … 0x76
        "┬", "│", "≤", "≥", "π", "≠", "£", "·"    // 0x77 … 0x7E
    ]

    // MARK: Untrusted-string sanitising

    /// The only place a string from inside the container is allowed to become UI text.
    ///
    /// A container that can run a shell can write any bytes it likes into `OSC 0`/`OSC 2`,
    /// and this app puts that string in an `NSWindow` title. Three things are stripped,
    /// each for a concrete reason:
    ///
    /// * **C0, C1 and DEL.** A newline or a `\r` in a window title corrupts the title bar
    ///   and, worse, any log line or accessibility announcement that later interpolates
    ///   it. An `ESC` would let a title re-enter a terminal that echoed it back.
    /// * **Bidi and other invisible formatting controls.** These reorder rendered text
    ///   without changing its bytes, which is the whole Trojan Source technique: a title
    ///   can be made to *read* as one thing while being another.
    /// * **Length.** Capped at 128 characters. An unbounded title is a cheap way to make
    ///   the window server lay out a megabyte of text on the main thread on every OSC.
    ///
    /// The result is never shown alone: the window's own `<name> — <shell>` prefix always
    /// precedes it, so a container cannot make its window impersonate a different one.
    static func sanitizedWindowTitle(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(min(raw.count, titleCharacterLimit))
        for scalar in raw.unicodeScalars {
            guard result.count < titleCharacterLimit else { break }
            switch scalar.value {
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                continue
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static let titleCharacterLimit = 128
}
