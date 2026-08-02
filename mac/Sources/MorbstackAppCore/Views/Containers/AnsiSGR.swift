// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A small, exact ANSI parser for the log viewer.
//
// Container output is full of escape sequences, and almost all of them are noise: a
// program clearing the screen, moving the cursor, or setting the terminal title has
// nothing to say to a scrollback view. What *is* worth keeping is colour — a red
// stack trace and a green "ready" line carry real information, and stripping them
// makes logs harder to read than they were in the terminal the program expected.
//
// So this parser keeps exactly three things — foreground colour, bold and dim — and
// swallows everything else without leaving fragments behind. That last part is the
// reason this is a real state machine rather than a regular expression: a half-parsed
// CSI sequence renders as `[0;32m` littered through the text, which looks broken in a
// way that stripping never does.
//
// Foundation only, no SwiftUI, no I/O: every function here is pure and directly
// testable. The mapping from `TrackBAnsiColor` to an on-screen colour lives in the
// view layer, where appearance belongs.

import Foundation

// MARK: - Colours

/// The sixteen colours an SGR foreground code can name.
///
/// Raw values are the standard indices, so `30 + rawValue` is the normal code and
/// `90 + rawValue - 8` the bright one — which is how the parser maps them back.
enum TrackBAnsiColor: Int, Hashable, Sendable, CaseIterable {
    case black = 0, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    /// The bright twin of a normal colour; bright colours map to themselves.
    var brightened: TrackBAnsiColor {
        rawValue < 8 ? TrackBAnsiColor(rawValue: rawValue + 8) ?? self : self
    }
}

// MARK: - Style

/// The parts of an SGR state the log viewer renders.
struct TrackBAnsiStyle: Hashable, Sendable {

    var color: TrackBAnsiColor?
    var bold: Bool = false
    var dim: Bool = false

    static let plain = TrackBAnsiStyle()

    var isPlain: Bool { self == .plain }

    /// Applies one already-split parameter list, in order.
    ///
    /// Taking the whole list rather than one code at a time is not a convenience: the
    /// extended-colour forms (`38;5;n` and `38;2;r;g;b`) consume the parameters that
    /// follow them, and a per-code loop would mistake `38;5;1` for "extended, then
    /// bright-ish 5, then red".
    mutating func apply(parameters: [Int]) {
        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            index += 1
            switch code {
            case 0:
                self = .plain
            case 1:
                bold = true
            case 2:
                dim = true
            case 22:
                bold = false
                dim = false
            case 30...37:
                color = TrackBAnsiColor(rawValue: code - 30)
            case 90...97:
                color = TrackBAnsiColor(rawValue: code - 90 + 8)
            case 39:
                color = nil
            case 38:
                // Extended foreground. `5;n` is the 256-colour cube, of which only the
                // first sixteen entries have a named equivalent; `2;r;g;b` is truecolour,
                // which this palette cannot represent. Either way the parameters must be
                // eaten so the rest of the list stays aligned.
                guard index < parameters.count else { return }
                let form = parameters[index]
                index += 1
                if form == 5 {
                    guard index < parameters.count else { return }
                    let value = parameters[index]
                    index += 1
                    if let named = TrackBAnsiColor(rawValue: value) { color = named }
                } else if form == 2 {
                    index = min(index + 3, parameters.count)
                }
            default:
                // Backgrounds, underline, inverse, fonts: understood well enough to be
                // skipped, which is all this viewer promises.
                continue
            }
        }
    }
}

// MARK: - Spans

/// A run of text sharing one style.
struct TrackBAnsiSpan: Hashable, Sendable {
    var text: String
    var style: TrackBAnsiStyle

    init(_ text: String, _ style: TrackBAnsiStyle = .plain) {
        self.text = text
        self.style = style
    }
}

// MARK: - Parser

enum TrackBAnsi {

    private static let escape: Character = "\u{1B}"
    private static let bell: Character = "\u{07}"

    /// Cheap pre-test so the common case — a line with no escapes at all — never walks
    /// the string twice. `0x1B` cannot appear inside a multi-byte UTF-8 sequence, so
    /// scanning the UTF-8 view is both correct and the fastest way to ask.
    static func containsEscape(_ input: String) -> Bool {
        input.utf8.contains(0x1B)
    }

    /// Splits a line into styled runs.
    ///
    /// Adjacent runs with the same style are merged, so a line that sets the same colour
    /// three times still renders as one span — which matters, because each span becomes
    /// a separate attributed run downstream.
    static func spans(_ input: String) -> [TrackBAnsiSpan] {
        guard !input.isEmpty else { return [] }
        guard containsEscape(input) else { return [TrackBAnsiSpan(input)] }

        var spans: [TrackBAnsiSpan] = []
        var style = TrackBAnsiStyle.plain
        var pending = ""

        func flush() {
            guard !pending.isEmpty else { return }
            if var last = spans.last, last.style == style {
                last.text += pending
                spans[spans.count - 1] = last
            } else {
                spans.append(TrackBAnsiSpan(pending, style))
            }
            pending = ""
        }

        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == escape else {
                pending.append(character)
                index += 1
                continue
            }

            // A trailing lone ESC is a truncated sequence, not text: drop it.
            guard index + 1 < characters.count else { break }

            let introducer = characters[index + 1]
            switch introducer {
            case "[":
                let (parameters, isSGR, next) = scanCSI(characters, from: index + 2)
                if isSGR {
                    flush()
                    style.apply(parameters: parameters)
                }
                index = next
            case "]":
                index = scanString(characters, from: index + 2)
            case "P", "X", "^", "_":
                // DCS / SOS / PM / APC — all terminated the same way as OSC.
                index = scanString(characters, from: index + 2)
            default:
                // Two-character sequences: charset selection, RIS, index, save/restore.
                // Some of these take one more byte; consuming both is right for all of
                // the ones a program plausibly writes into a log.
                index += (introducer == "(" || introducer == ")" || introducer == "%") ? 3 : 2
            }
        }

        flush()
        return spans
    }

    /// The text with every escape sequence removed.
    ///
    /// Guaranteed to equal `spans(input).map(\.text).joined()`; used for search,
    /// copy and export, where styling is not wanted but exact text is.
    static func strip(_ input: String) -> String {
        guard containsEscape(input) else { return input }
        return spans(input).reduce(into: "") { $0 += $1.text }
    }

    // MARK: Scanners

    /// Reads a CSI sequence's parameter bytes and its final byte.
    ///
    /// Returns the numeric parameters, whether the sequence was an SGR (`m`) the caller
    /// should act on, and the index just past the sequence. A private-mode sequence
    /// (`ESC [ ? … m`) is reported as not-SGR: those set terminal modes, and applying
    /// their parameters as colours would be actively wrong.
    private static func scanCSI(
        _ characters: [Character], from start: Int
    ) -> (parameters: [Int], isSGR: Bool, next: Int) {
        var index = start
        var parameters: [Int] = []
        var current: Int?
        var sawDigit = false
        var isPrivate = false

        while index < characters.count {
            let character = characters[index]
            if let digit = character.wholeNumberValue, character.isASCII, character.isNumber {
                // Clamped so a pathological run of digits cannot overflow; no real
                // parameter exceeds three digits anyway.
                current = min((current ?? 0) * 10 + digit, 1_000_000)
                sawDigit = true
                index += 1
                continue
            }
            if character == ";" {
                parameters.append(current ?? 0)
                current = nil
                sawDigit = true
                index += 1
                continue
            }
            if character == ":" {
                // Sub-parameters (ITU-T T.416 colour syntax). Treated as separators so
                // `38:5:1` behaves like `38;5;1`.
                parameters.append(current ?? 0)
                current = nil
                index += 1
                continue
            }
            if "?<>=!".contains(character) {
                isPrivate = true
                index += 1
                continue
            }
            // Final byte.
            if let scalar = character.unicodeScalars.first,
               character.unicodeScalars.count == 1,
               (0x40...0x7E).contains(scalar.value) {
                if let current { parameters.append(current) }
                let isSGR = (character == "m") && !isPrivate
                // A bare `ESC[m` means `ESC[0m`.
                if isSGR && parameters.isEmpty && !sawDigit { parameters = [0] }
                return (parameters, isSGR, index + 1)
            }
            // Anything else means the sequence was malformed; stop where we are rather
            // than eating the rest of the line.
            return ([], false, index)
        }
        return ([], false, index)
    }

    /// Skips an OSC/DCS-style string, which ends at BEL or at `ESC \`.
    private static func scanString(_ characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count {
            if characters[index] == bell { return index + 1 }
            if characters[index] == escape {
                if index + 1 < characters.count, characters[index + 1] == "\\" { return index + 2 }
                // A bare ESC inside the string starts something new; hand it back.
                return index
            }
            index += 1
        }
        return index
    }
}
