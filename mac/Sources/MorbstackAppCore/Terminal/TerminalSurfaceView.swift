// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// The terminal surface: an AppKit view that draws `TerminalEmulator`'s grid and turns
// keyboard/mouse/scroll input into wire bytes and viewport-size callbacks.
//
// Content, not chrome (DECISIONS.md §3): this view paints its own background edge to
// edge and never sits behind Liquid Glass or a material. Everything measurable without
// AppKit — palette math, selection-range math, grid-size-from-view-size, and the
// keystroke-to-bytes decision — is factored into pure static functions below the view
// class so `TerminalSurfaceViewTests` can exercise them without a window server.

import AppKit
import CoreText

// MARK: - Pure helpers (testable without a window server)

/// One point in unified scrollback-then-screen line addressing plus column, the
/// coordinate system a mouse click and a selection both live in.
struct TerminalSelectionPoint: Equatable, Comparable {
    var line: Int
    var column: Int

    static func < (lhs: TerminalSelectionPoint, rhs: TerminalSelectionPoint) -> Bool {
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }
}

/// An anchor/extent pair as the mouse left them; order is drag direction, not
/// document order — `normalized` recovers document order for text extraction.
struct TerminalSelectionRange: Equatable {
    var anchor: TerminalSelectionPoint
    var extent: TerminalSelectionPoint

    var normalized: (start: TerminalSelectionPoint, end: TerminalSelectionPoint) {
        anchor <= extent ? (anchor, extent) : (extent, anchor)
    }
}

/// sRGB components in 0...1, kept independent of `NSColor` so palette math is a pure
/// function a test can call without a graphics context.
struct TerminalRGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
}

enum TerminalPalette {

    /// ANSI 0–15 resolved for the given appearance, 16–231 the xterm 6×6×6 cube,
    /// 232–255 the grayscale ramp — the whole indexed space SGR can name.
    static func components(forIndex index: UInt8, dark: Bool) -> TerminalRGBA {
        switch index {
        case 0...15:
            return (dark ? ansi16Dark : ansi16Light)[Int(index)]
        case 16...231:
            let value = Int(index) - 16
            let red = value / 36
            let green = (value / 6) % 6
            let blue = value % 6
            return TerminalRGBA(red: cubeLevel(red), green: cubeLevel(green), blue: cubeLevel(blue))
        default:
            let step = Int(index) - 232
            let level = Double(8 + step * 10) / 255.0
            return TerminalRGBA(red: level, green: level, blue: level)
        }
    }

    private static func cubeLevel(_ component: Int) -> Double {
        component == 0 ? 0 : Double(55 + component * 40) / 255.0
    }

    /// Terminal.app-ish values: distinct from the light table so bright yellow/white
    /// don't wash out on a light background, per the design brief's "not pure #f00
    /// neon" instruction.
    private static let ansi16Dark: [TerminalRGBA] = [
        rgb(0x00, 0x00, 0x00), rgb(0xC9, 0x1B, 0x00), rgb(0x00, 0xC2, 0x00), rgb(0xC7, 0xC4, 0x00),
        rgb(0x02, 0x25, 0xC7), rgb(0xCA, 0x30, 0xC7), rgb(0x00, 0xC5, 0xC7), rgb(0xC7, 0xC7, 0xC7),
        rgb(0x68, 0x68, 0x68), rgb(0xFF, 0x6E, 0x67), rgb(0x5F, 0xFA, 0x68), rgb(0xFF, 0xFC, 0x67),
        rgb(0x68, 0x71, 0xFF), rgb(0xFF, 0x77, 0xFF), rgb(0x60, 0xFD, 0xFF), rgb(0xFF, 0xFF, 0xFF)
    ]

    private static let ansi16Light: [TerminalRGBA] = [
        rgb(0x00, 0x00, 0x00), rgb(0xC4, 0x1A, 0x16), rgb(0x00, 0x74, 0x00), rgb(0xC4, 0xA0, 0x00),
        rgb(0x02, 0x25, 0xC7), rgb(0xA0, 0x0C, 0xA0), rgb(0x31, 0x84, 0x95), rgb(0xC7, 0xC7, 0xC7),
        rgb(0x68, 0x68, 0x68), rgb(0xD6, 0x36, 0x2E), rgb(0x1D, 0xBE, 0x1D), rgb(0xB0, 0xA0, 0x00),
        rgb(0x3B, 0x4B, 0xDE), rgb(0xC9, 0x00, 0xC9), rgb(0x00, 0xAE, 0xAE), rgb(0xA0, 0xA0, 0xA0)
    ]

    private static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> TerminalRGBA {
        TerminalRGBA(red: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0)
    }
}

extension TerminalRGBA {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// One run of cells sharing an identical style, the unit a line is drawn in — one
/// `CTLine` and one background rect per run, not per cell (per-cell `CTLine` creation
/// is the thing the design brief calls out as too slow).
struct TerminalStyleRun: Equatable {
    var startColumn: Int
    var columnCount: Int
    var text: String
    var style: TerminalCellStyle
}

enum TerminalLineLayout {

    /// Groups a screen line into style runs. Wide placeholders extend the run's column
    /// span (so its background still paints) but contribute no character — the glyph
    /// before them overflows into that column on its own.
    static func runs(for cells: [TerminalCell]) -> [TerminalStyleRun] {
        var result: [TerminalStyleRun] = []
        for (column, cell) in cells.enumerated() {
            if var last = result.last, last.style == cell.style {
                last.columnCount += 1
                if !cell.isWidePlaceholder { last.text.append(cell.character ?? " ") }
                result[result.count - 1] = last
            } else {
                var text = ""
                if !cell.isWidePlaceholder { text.append(cell.character ?? " ") }
                result.append(TerminalStyleRun(startColumn: column, columnCount: 1, text: text, style: cell.style))
            }
        }
        return result
    }
}

enum TerminalSelectionText {

    /// The selected text, newline-joined, built from `plainText(ofLine:)` slices —
    /// accepted drift: a line's plain text drops wide-placeholder columns, so a
    /// selection anchored past a wide character on the same line can be off by one.
    /// Noted as a known limitation rather than solved here.
    static func selectedText(range: TerminalSelectionRange, columns: Int, plainText: (Int) -> String) -> String {
        let (start, end) = range.normalized
        if start.line == end.line {
            return substring(plainText(start.line), from: start.column, to: end.column)
        }
        var parts: [String] = []
        parts.append(substring(plainText(start.line), from: start.column, to: columns))
        if end.line - start.line > 1 {
            for line in (start.line + 1)..<end.line {
                parts.append(plainText(line))
            }
        }
        parts.append(substring(plainText(end.line), from: 0, to: end.column))
        return parts.joined(separator: "\n")
    }

    static func substring(_ text: String, from: Int, to: Int) -> String {
        let characters = Array(text)
        let clampedFrom = max(0, min(from, characters.count))
        let clampedTo = max(0, min(to, characters.count))
        guard clampedFrom < clampedTo else { return "" }
        return String(characters[clampedFrom..<clampedTo])
    }

    private static let separators = Set("`~!@#$%^&*()=+[]{}\\|;:'\",.<>/?")

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || separators.contains(character)
    }

    /// Double-click word bounds: split on whitespace and common shell/path separators,
    /// end exclusive.
    static func wordBoundaries(in line: String, atColumn column: Int) -> (start: Int, end: Int) {
        let characters = Array(line)
        guard !characters.isEmpty else { return (0, 0) }
        let index = min(max(column, 0), characters.count - 1)
        if isSeparator(characters[index]) { return (index, index + 1) }
        var start = index
        while start > 0, !isSeparator(characters[start - 1]) { start -= 1 }
        var end = index
        while end < characters.count - 1, !isSeparator(characters[end + 1]) { end += 1 }
        return (start, end + 1)
    }
}

/// The viewport math behind `onViewportSizeChange`: how many whole columns/rows of a
/// monospaced grid fit a view size once the content inset is subtracted. Floors, never
/// goes below the 2×2 floor a degenerate window would otherwise hand the emulator.
func terminalGridSize(viewSize: CGSize, cellSize: CGSize, contentInset: CGFloat) -> (columns: Int, rows: Int) {
    guard cellSize.width > 0, cellSize.height > 0 else { return (2, 2) }
    let usableWidth = max(0, viewSize.width - contentInset * 2)
    let usableHeight = max(0, viewSize.height - contentInset * 2)
    let columns = max(2, Int(floor(usableWidth / cellSize.width)))
    let rows = max(2, Int(floor(usableHeight / cellSize.height)))
    return (columns, rows)
}

/// A view point (already view-local, origin top-left under `isFlipped`) to the unified
/// line/column it addresses.
func terminalSelectionPoint(
    atViewPoint point: CGPoint,
    contentInset: CGFloat,
    cellSize: CGSize,
    firstVisibleLine: Int,
    rows: Int,
    columns: Int
) -> TerminalSelectionPoint {
    guard cellSize.width > 0, cellSize.height > 0 else {
        return TerminalSelectionPoint(line: firstVisibleLine, column: 0)
    }
    let rowFloat = (point.y - contentInset) / cellSize.height
    let row = min(max(Int(floor(rowFloat)), 0), max(rows - 1, 0))
    let columnFloat = (point.x - contentInset) / cellSize.width
    let column = min(max(Int(floor(columnFloat)), 0), columns)
    return TerminalSelectionPoint(line: firstVisibleLine + row, column: column)
}

/// Which viewport scroll, if any, a keyDown should perform instead of forwarding to
/// the process — Shift+PageUp/PageDown, and only on the primary screen (scrollback is
/// meaningless, and disabled, on the alternate screen).
enum TerminalViewportScroll: Equatable {
    case up, down
}

func terminalViewportScroll(forKeyCode keyCode: UInt16, shift: Bool, isAlternateScreen: Bool) -> TerminalViewportScroll? {
    guard shift, !isAlternateScreen else { return nil }
    switch keyCode {
    case TerminalKeyCode.pageUp: return .up
    case TerminalKeyCode.pageDown: return .down
    default: return nil
    }
}

/// The standard ANSI-keyboard virtual key codes (Carbon `HIToolbox/Events.h`'s
/// `kVK_*` constants). These identify physical keys, not typed characters, so they are
/// stable across keyboard layouts — exactly what arrow/function/editing keys need.
enum TerminalKeyCode {
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74
    static let pageDown: UInt16 = 0x79
    static let help: UInt16 = 0x72 // Insert on keyboards without a dedicated key.
    static let forwardDelete: UInt16 = 0x75
    static let escape: UInt16 = 0x35
    static let tab: UInt16 = 0x30
    static let `return`: UInt16 = 0x24
    static let keypadEnter: UInt16 = 0x4C
    static let delete: UInt16 = 0x33 // Backspace.
    static let f1: UInt16 = 0x7A
    static let f2: UInt16 = 0x78
    static let f3: UInt16 = 0x63
    static let f4: UInt16 = 0x76
    static let f5: UInt16 = 0x60
    static let f6: UInt16 = 0x61
    static let f7: UInt16 = 0x62
    static let f8: UInt16 = 0x64
    static let f9: UInt16 = 0x65
    static let f10: UInt16 = 0x6D
    static let f11: UInt16 = 0x67
    static let f12: UInt16 = 0x6F
}

/// Maps a physical key code (plus Shift, for Tab/BackTab) to the `TerminalKey` the
/// emulator's key encoding table understands. `nil` means "not a special key" — the
/// caller falls through to character input.
func terminalKey(forKeyCode keyCode: UInt16, shift: Bool) -> TerminalKey? {
    switch keyCode {
    case TerminalKeyCode.upArrow: return .up
    case TerminalKeyCode.downArrow: return .down
    case TerminalKeyCode.leftArrow: return .left
    case TerminalKeyCode.rightArrow: return .right
    case TerminalKeyCode.home: return .home
    case TerminalKeyCode.end: return .end
    case TerminalKeyCode.pageUp: return .pageUp
    case TerminalKeyCode.pageDown: return .pageDown
    case TerminalKeyCode.help: return .insert
    case TerminalKeyCode.forwardDelete: return .delete
    case TerminalKeyCode.escape: return .escape
    case TerminalKeyCode.tab: return shift ? .backTab : .tab
    case TerminalKeyCode.return, TerminalKeyCode.keypadEnter: return .enter
    case TerminalKeyCode.delete: return .backspace
    case TerminalKeyCode.f1: return .function(1)
    case TerminalKeyCode.f2: return .function(2)
    case TerminalKeyCode.f3: return .function(3)
    case TerminalKeyCode.f4: return .function(4)
    case TerminalKeyCode.f5: return .function(5)
    case TerminalKeyCode.f6: return .function(6)
    case TerminalKeyCode.f7: return .function(7)
    case TerminalKeyCode.f8: return .function(8)
    case TerminalKeyCode.f9: return .function(9)
    case TerminalKeyCode.f10: return .function(10)
    case TerminalKeyCode.f11: return .function(11)
    case TerminalKeyCode.f12: return .function(12)
    default: return nil
    }
}

/// The keyDown-to-bytes decision, factored out of `NSEvent` entirely so it is a pure
/// table a test can drive with plain values. Priority: a special key always wins (it
/// funnels through `TerminalKeyEncoding.bytes(for:applicationCursorKeys:)`, matching
/// arrows/Home/End/PageUp/PageDown/F-keys/Tab/BackTab/Escape/Delete/Return/Backspace);
/// then a Command combination sends nothing (⌘C/⌘V/⌘A are handled as
/// copy/paste/selectAll, not as terminal input — see the view's `performKeyEquivalent`);
/// then Control folds the ignoring-modifiers character to the C0 range; otherwise the
/// literal typed characters go out as UTF-8.
func terminalKeyDownBytes(
    specialKey: TerminalKey?,
    control: Bool,
    command: Bool,
    charactersIgnoringModifiers: String?,
    characters: String?,
    applicationCursorKeys: Bool
) -> Data? {
    if let specialKey {
        return TerminalKeyEncoding.bytes(for: specialKey, applicationCursorKeys: applicationCursorKeys)
    }
    if command { return nil }
    if control, let character = charactersIgnoringModifiers?.first {
        return TerminalKeyEncoding.bytes(forCharacter: character, control: true)
    }
    guard let characters, !characters.isEmpty else { return nil }
    return characters.data(using: .utf8)
}

// MARK: - View

/// The AppKit terminal surface: draws `TerminalEmulator`'s grid and turns input into
/// wire bytes. Owns no transport — `onInput` and `onViewportSizeChange` are the whole
/// outward interface, wired by `ContainerTerminalWindowController`.
final class TerminalSurfaceNSView: NSView {

    /// Bytes to send to the process: keystrokes, pastes, nothing else.
    var onInput: ((Data) -> Void)?
    /// Fired when the fitted column/row count changes, so the controller can resize
    /// the emulator and the PTY together.
    var onViewportSizeChange: ((Int, Int) -> Void)?

    /// 4pt on every edge, matching the design brief. Exposed statically so the window
    /// controller can size a window to a whole number of cells before any surface
    /// instance exists (during the "Connecting…" phase, before the shell is resolved).
    static let contentInset: CGFloat = 4

    private let emulator: TerminalEmulator
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFontCache: NSFont?
    private var boldItalicFontCache: NSFont?
    private let contentInset: CGFloat = TerminalSurfaceNSView.contentInset
    private let cellSize: CGSize

    /// The cell size a not-yet-created surface will use, computed from the same font
    /// metrics `init` derives it from. The window controller needs this to compute an
    /// initial column/row count from a window's content size before the emulator (and
    /// hence the surface) exists.
    static func measuredCellSize() -> CGSize {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let ascent = font.ascender
        let descent = -font.descender
        let leading = font.leading
        let height = ceil(ascent + descent + leading)
        let width = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private var lastDrawnGeneration: UInt64 = .max
    private var lastColumns = 0
    private var lastRows = 0

    /// Lines scrolled up from the live screen. 0 means pinned to the bottom.
    private var scrollOffsetLines = 0

    private var selectionAnchor: TerminalSelectionPoint?
    private var selectionExtent: TerminalSelectionPoint?
    private var isDraggingSelection = false

    init(emulator: TerminalEmulator) {
        self.emulator = emulator
        cellSize = Self.measuredCellSize()
        super.init(frame: .zero)
        setAccessibilityIdentifier("containers.terminal.surface")
        setAccessibilityRole(.textArea)
        setAccessibilityElement(true)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceNSView is constructed programmatically only.")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(redrawForKeyChange), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(redrawForKeyChange), name: NSWindow.didResignKeyNotification, object: window)
        updateGridSizeIfNeeded()
    }

    @objc private func redrawForKeyChange() {
        setNeedsDisplay(bounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setNeedsDisplay(bounds)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        setNeedsDisplay(bounds)
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        setNeedsDisplay(bounds)
        return result
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSizeIfNeeded()
    }

    private func updateGridSizeIfNeeded() {
        let size = terminalGridSize(viewSize: bounds.size, cellSize: cellSize, contentInset: contentInset)
        guard size.columns != lastColumns || size.rows != lastRows else { return }
        lastColumns = size.columns
        lastRows = size.rows
        onViewportSizeChange?(size.columns, size.rows)
        setNeedsDisplay(bounds)
    }

    /// Called by the controller after anything that might have moved the emulator's
    /// `generation`. Redraws only when it actually moved, and resets the scroll offset
    /// out of scrollback the moment the alternate screen takes over (scrollback is
    /// meaningless there). Otherwise a nonzero offset is left untouched on purpose: new
    /// output while scrolled up must not yank the view back to live (see the class doc
    /// on `scrollOffsetLines`); it drifts with the live edge instead of jumping to it.
    func refresh() {
        if emulator.isAlternateScreen, scrollOffsetLines != 0 {
            scrollOffsetLines = 0
        }
        guard emulator.generation != lastDrawnGeneration else { return }
        lastDrawnGeneration = emulator.generation
        setNeedsDisplay(visibleRect)
    }

    func bell() {
        NSSound.beep()
    }

    // MARK: Line addressing

    private var totalLineCount: Int { emulator.scrollbackLineCount + emulator.rows }

    private func firstVisibleLineIndex() -> Int {
        let total = totalLineCount
        let lastShown = max(0, total - 1 - scrollOffsetLines)
        return max(0, lastShown - emulator.rows + 1)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let firstLine = firstVisibleLineIndex()
        let selectionRange = selectionAnchor.flatMap { anchor in
            selectionExtent.map { TerminalSelectionRange(anchor: anchor, extent: $0) }
        }

        for row in 0..<emulator.rows {
            let lineIndex = firstLine + row
            guard lineIndex >= 0, lineIndex < totalLineCount else { continue }
            let originY = contentInset + CGFloat(row) * cellSize.height
            guard originY + cellSize.height >= dirtyRect.minY, originY <= dirtyRect.maxY else { continue }
            drawLine(
                emulator.line(at: lineIndex),
                lineIndex: lineIndex,
                originY: originY,
                dark: dark,
                context: context,
                selection: selectionRange)
        }

        drawCursor(firstLine: firstLine, dark: dark, context: context)
        drawScrollIndicator()
    }

    private func drawLine(
        _ cells: [TerminalCell],
        lineIndex: Int,
        originY: CGFloat,
        dark: Bool,
        context: CGContext,
        selection: TerminalSelectionRange?
    ) {
        let selectedColumns = selectedColumnRange(forLine: lineIndex, selection: selection)
        for run in TerminalLineLayout.runs(for: cells) {
            let originX = contentInset + CGFloat(run.startColumn) * cellSize.width
            let width = CGFloat(run.columnCount) * cellSize.width
            let rect = CGRect(x: originX, y: originY, width: width, height: cellSize.height)

            var (foreground, background) = resolvedColors(for: run.style, dark: dark)
            if run.style.inverse { swap(&foreground, &background) }

            background.setFill()
            rect.fill()

            if let selectedColumns {
                let overlapStart = max(selectedColumns.lowerBound, run.startColumn)
                let overlapEnd = min(selectedColumns.upperBound, run.startColumn + run.columnCount)
                if overlapStart < overlapEnd {
                    let selRect = CGRect(
                        x: contentInset + CGFloat(overlapStart) * cellSize.width,
                        y: originY,
                        width: CGFloat(overlapEnd - overlapStart) * cellSize.width,
                        height: cellSize.height)
                    NSColor.selectedTextBackgroundColor.setFill()
                    selRect.fill()
                }
            }

            guard !run.text.isEmpty else { continue }
            var drawColor = foreground
            if run.style.dim { drawColor = drawColor.withAlphaComponent(0.6) }
            let runFont = resolvedFont(bold: run.style.bold, italic: run.style.italic)
            drawText(run.text, font: runFont, color: drawColor, origin: CGPoint(x: originX, y: originY), context: context)

            if run.style.underline {
                let underlineY = originY + font.ascender - font.underlinePosition
                let thickness = max(1, font.underlineThickness)
                CGRect(x: originX, y: underlineY, width: width, height: thickness).fill(using: drawColor)
            }
            if run.style.strikethrough {
                let strikeY = originY + font.ascender - font.xHeight * 0.5
                CGRect(x: originX, y: strikeY, width: width, height: max(1, font.underlineThickness)).fill(using: drawColor)
            }
        }
    }

    private func resolvedColors(for style: TerminalCellStyle, dark: Bool) -> (foreground: NSColor, background: NSColor) {
        let foreground = style.foreground.map { color($0, dark: dark) } ?? NSColor.textColor
        let background = style.background.map { color($0, dark: dark) } ?? NSColor.textBackgroundColor
        return (foreground, background)
    }

    private func color(_ value: TerminalCellStyle.Color, dark: Bool) -> NSColor {
        switch value {
        case .indexed(let index):
            return TerminalPalette.components(forIndex: index, dark: dark).nsColor
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0, alpha: 1)
        }
    }

    private func resolvedFont(bold: Bool, italic: Bool) -> NSFont {
        switch (bold, italic) {
        case (false, false): return font
        case (true, false): return boldFont
        case (false, true):
            if let cached = italicFontCache { return cached }
            let made = Self.obliqueFont(base: font)
            italicFontCache = made
            return made
        case (true, true):
            if let cached = boldItalicFontCache { return cached }
            let made = Self.obliqueFont(base: boldFont)
            boldItalicFontCache = made
            return made
        }
    }

    /// SF Mono (the system monospaced font) has no true italic face, so an oblique
    /// variant is synthesized via a text-matrix skew — the same trick Terminal.app's
    /// own monospaced-font rendering relies on.
    private static func obliqueFont(base: NSFont) -> NSFont {
        let converted = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        if converted != base { return converted }
        let skew = AffineTransform(m11: 1, m12: 0, m21: CGFloat(tan(14 * Double.pi / 180)), m22: 1, tX: 0, tY: 0)
        return NSFont(descriptor: base.fontDescriptor, textTransform: skew) ?? base
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, origin: CGPoint, context: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + font.ascender)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A filled cursor inverts the cell it sits on (paints the block in the cell's own
    /// foreground, then redraws the character in the cell's own background) so the
    /// character underneath stays legible instead of being papered over; a hollow
    /// cursor only outlines, leaving the cell exactly as `drawLine` already drew it.
    private func drawCursor(firstLine: Int, dark: Bool, context: CGContext) {
        guard scrollOffsetLines == 0, emulator.cursorVisible else { return }
        let row = emulator.cursorRow
        guard row >= 0, row < emulator.rows else { return }
        let cells = emulator.line(at: emulator.scrollbackLineCount + row)
        let cell = emulator.cursorCol >= 0 && emulator.cursorCol < cells.count ? cells[emulator.cursorCol] : .blank

        var (foreground, background) = resolvedColors(for: cell.style, dark: dark)
        if cell.style.inverse { swap(&foreground, &background) }

        let originX = contentInset + CGFloat(emulator.cursorCol) * cellSize.width
        let originY = contentInset + CGFloat(row) * cellSize.height
        let rect = CGRect(x: originX, y: originY, width: cellSize.width, height: cellSize.height)

        let isKeyAndFirstResponder = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        if isKeyAndFirstResponder {
            foreground.setFill()
            rect.fill()
            if let character = cell.character, !cell.isWidePlaceholder {
                let runFont = resolvedFont(bold: cell.style.bold, italic: cell.style.italic)
                drawText(String(character), font: runFont, color: background, origin: CGPoint(x: originX, y: originY), context: context)
            }
        } else {
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            foreground.setStroke()
            path.stroke()
        }
    }

    private func drawScrollIndicator() {
        guard scrollOffsetLines > 0 else { return }
        let text = "\(scrollOffsetLines) lines"
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        let size = attributed.size()
        let origin = CGPoint(x: bounds.width - size.width - contentInset, y: contentInset * 0.5)
        attributed.draw(at: origin)
    }

    private func selectedColumnRange(forLine lineIndex: Int, selection: TerminalSelectionRange?) -> Range<Int>? {
        guard let selection else { return nil }
        let (start, end) = selection.normalized
        guard lineIndex >= start.line, lineIndex <= end.line else { return nil }
        let lowerBound = lineIndex == start.line ? start.column : 0
        let upperBound = lineIndex == end.line ? end.column : emulator.columns
        guard lowerBound < upperBound else { return nil }
        return lowerBound..<upperBound
    }

    // MARK: Accessibility

    /// Recomputed on every accessibility request rather than cached — the visible
    /// screen's plain text is cheap to join and the alternative is a staleness bug.
    /// `NSAccessibility`'s requirements are method-style (`accessibilityValue()`, not a
    /// stored property), so this overrides the protocol requirement directly.
    override func accessibilityValue() -> Any? {
        (0..<emulator.rows)
            .map { emulator.plainText(ofLine: emulator.scrollbackLineCount + $0) }
            .joined(separator: "\n")
    }

    // MARK: Mouse / selection

    private var hasSelection: Bool {
        guard let anchor = selectionAnchor, let extent = selectionExtent else { return false }
        return anchor != extent
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let firstLine = firstVisibleLineIndex()
        let clicked = terminalSelectionPoint(
            atViewPoint: point, contentInset: contentInset, cellSize: cellSize,
            firstVisibleLine: firstLine, rows: emulator.rows, columns: emulator.columns)

        switch event.clickCount {
        case 2:
            let text = emulator.plainText(ofLine: clicked.line)
            let bounds = TerminalSelectionText.wordBoundaries(in: text, atColumn: clicked.column)
            selectionAnchor = TerminalSelectionPoint(line: clicked.line, column: bounds.start)
            selectionExtent = TerminalSelectionPoint(line: clicked.line, column: bounds.end)
        case 3:
            selectionAnchor = TerminalSelectionPoint(line: clicked.line, column: 0)
            selectionExtent = TerminalSelectionPoint(line: clicked.line, column: emulator.columns)
        default:
            if event.modifierFlags.contains(.shift), selectionAnchor != nil {
                selectionExtent = clicked
            } else {
                selectionAnchor = clicked
                selectionExtent = clicked
            }
        }
        isDraggingSelection = true
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection else { return }
        let point = convert(event.locationInWindow, from: nil)
        let firstLine = firstVisibleLineIndex()
        selectionExtent = terminalSelectionPoint(
            atViewPoint: point, contentInset: contentInset, cellSize: cellSize,
            firstVisibleLine: firstLine, rows: emulator.rows, columns: emulator.columns)
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSelection = false
        // A click without a drag clears the selection; word/line selection from a
        // multi-click already produced anchor != extent, so it survives this check.
        if let anchor = selectionAnchor, anchor == selectionExtent {
            selectionAnchor = nil
            selectionExtent = nil
            setNeedsDisplay(bounds)
        }
    }

    // MARK: Scrolling / paging

    override func scrollWheel(with event: NSEvent) {
        guard !emulator.isAlternateScreen else { return }
        guard cellSize.height > 0 else { return }
        let delta = Int((event.scrollingDeltaY / cellSize.height).rounded())
        guard delta != 0 else { return }
        setScrollOffset(scrollOffsetLines + delta)
    }

    private func setScrollOffset(_ value: Int) {
        let clamped = min(max(value, 0), emulator.scrollbackLineCount)
        guard clamped != scrollOffsetLines else { return }
        scrollOffsetLines = clamped
        setNeedsDisplay(bounds)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let control = event.modifierFlags.contains(.control)
        let command = event.modifierFlags.contains(.command)

        if let scroll = terminalViewportScroll(forKeyCode: event.keyCode, shift: shift, isAlternateScreen: emulator.isAlternateScreen) {
            let page = max(1, emulator.rows - 1)
            setScrollOffset(scrollOffsetLines + (scroll == .up ? page : -page))
            return
        }

        let special = terminalKey(forKeyCode: event.keyCode, shift: shift)
        guard let data = terminalKeyDownBytes(
            specialKey: special,
            control: control,
            command: command,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            characters: event.characters,
            applicationCursorKeys: emulator.applicationCursorKeys),
            !data.isEmpty
        else { return }
        onInput?(data)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            // Never sends 0x03 for ⌘C — ⌃C is the interrupt. A copy with nothing
            // selected is silently a no-op, not a beep.
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Edit actions

    /// `copy(_:)`/`selectAll(_:)` aren't declared anywhere above `NSObject` — they're
    /// the informal action-method contract the Edit menu and the responder chain use,
    /// so implementing them (no `override`) is what makes them reachable at all.
    @objc func copy(_ sender: Any?) {
        guard let anchor = selectionAnchor, let extent = selectionExtent, anchor != extent else { return }
        let range = TerminalSelectionRange(anchor: anchor, extent: extent)
        let text = TerminalSelectionText.selectedText(range: range, columns: emulator.columns, plainText: emulator.plainText(ofLine:))
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Loses dead-key/IME composition — a plain `NSPasteboard` string round-trip, not
    /// `NSTextInputClient`. Acceptable for v1; noted as a known limitation.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        onInput?(TerminalKeyEncoding.pasteData(text, bracketed: emulator.bracketedPaste))
    }

    @objc override func selectAll(_ sender: Any?) {
        let total = totalLineCount
        guard total > 0 else { return }
        selectionAnchor = TerminalSelectionPoint(line: 0, column: 0)
        selectionExtent = TerminalSelectionPoint(line: total - 1, column: emulator.columns)
        setNeedsDisplay(bounds)
    }
}

extension TerminalSurfaceNSView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return hasSelection
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)): return true
        default: return true
        }
    }
}

private extension CGRect {
    func fill(using color: NSColor) {
        color.setFill()
        NSBezierPath(rect: self).fill()
    }
}
