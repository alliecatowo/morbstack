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

    /// The byte sequence one special key sends. `applicationCursorKeys` is the
    /// emulator's live DECCKM state — `SS3 A` versus `CSI A` is exactly the difference
    /// between arrows working and printing letters inside vim.
    static func bytes(for key: TerminalKey, applicationCursorKeys: Bool) -> Data {
        _ = (key, applicationCursorKeys)
        return Data()
    }

    /// The bytes for a typed character with modifiers: `control` folds to the C0 range
    /// (⌃C → 0x03, ⌃@ → 0x00), otherwise UTF-8. Returns nil for combinations that send
    /// nothing.
    static func bytes(forCharacter character: Character, control: Bool) -> Data? {
        _ = (character, control)
        return nil
    }

    /// A paste, fenced with `ESC [200~` … `ESC [201~` when the program asked for
    /// bracketed paste. CR-normalised: terminals paste `\r`, not `\n`.
    static func pasteData(_ text: String, bracketed: Bool) -> Data {
        _ = (text, bracketed)
        return Data()
    }
}
