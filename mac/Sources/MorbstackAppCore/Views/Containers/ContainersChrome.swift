// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Container-specific implementations that have no shared visual language: an ANSI
// palette for terminal output, the All/Running filter, and a stock AppKit search field
// embedded in inspector documents. The palette represents terminal data, not app
// branding; all surrounding controls and surfaces are system-owned.

import AppKit
import SwiftUI

// MARK: - Palette

enum ContainerLogPalette {

    /// A colour that resolves differently in light and dark.
    ///
    /// The AppKit dynamic provider is used rather than two SwiftUI `Color`s behind a
    /// `colorScheme` check because it also does the right thing in the parts of the
    /// window SwiftUI does not own — menus, popovers, and the vibrancy behind a
    /// material sidebar all ask AppKit, not the environment.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// The sixteen ANSI foregrounds, tuned per appearance.
    ///
    /// Terminal palettes are designed for dark backgrounds, and pasting one onto white
    /// gives unreadable yellow and near-invisible bright-white. The light column is
    /// therefore darkened to hold roughly 4.5:1 against the light log surface, and the
    /// dark column brightened for the same reason in reverse.
    ///
    /// Not restyled as part of this pass: the ANSI palette is the terminal's contract
    /// with the program that wrote the bytes, not a Morbstack UI colour.
    static func ansi(_ color: TrackBAnsiColor) -> Color {
        switch color {
        case .black:
            return adaptive(light: NSColor(calibratedWhite: 0.20, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.45, alpha: 1))
        case .red:
            return adaptive(light: NSColor(calibratedRed: 0.72, green: 0.11, blue: 0.09, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.38, alpha: 1))
        case .green:
            return adaptive(light: NSColor(calibratedRed: 0.11, green: 0.47, blue: 0.16, alpha: 1),
                            dark: NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.50, alpha: 1))
        case .yellow:
            return adaptive(light: NSColor(calibratedRed: 0.56, green: 0.40, blue: 0.02, alpha: 1),
                            dark: NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.35, alpha: 1))
        case .blue:
            return adaptive(light: NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.78, alpha: 1),
                            dark: NSColor(calibratedRed: 0.48, green: 0.68, blue: 1.00, alpha: 1))
        case .magenta:
            return adaptive(light: NSColor(calibratedRed: 0.60, green: 0.14, blue: 0.60, alpha: 1),
                            dark: NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.95, alpha: 1))
        case .cyan:
            return adaptive(light: NSColor(calibratedRed: 0.05, green: 0.44, blue: 0.50, alpha: 1),
                            dark: NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.90, alpha: 1))
        case .white:
            return adaptive(light: NSColor(calibratedWhite: 0.35, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.85, alpha: 1))
        case .brightBlack:
            return adaptive(light: NSColor(calibratedWhite: 0.42, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.60, alpha: 1))
        case .brightRed:
            return adaptive(light: NSColor(calibratedRed: 0.82, green: 0.18, blue: 0.14, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.50, alpha: 1))
        case .brightGreen:
            return adaptive(light: NSColor(calibratedRed: 0.16, green: 0.56, blue: 0.20, alpha: 1),
                            dark: NSColor(calibratedRed: 0.60, green: 1.00, blue: 0.62, alpha: 1))
        case .brightYellow:
            return adaptive(light: NSColor(calibratedRed: 0.64, green: 0.47, blue: 0.05, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.50, alpha: 1))
        case .brightBlue:
            return adaptive(light: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.88, alpha: 1),
                            dark: NSColor(calibratedRed: 0.62, green: 0.78, blue: 1.00, alpha: 1))
        case .brightMagenta:
            return adaptive(light: NSColor(calibratedRed: 0.70, green: 0.22, blue: 0.70, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.70, blue: 1.00, alpha: 1))
        case .brightCyan:
            return adaptive(light: NSColor(calibratedRed: 0.09, green: 0.52, blue: 0.58, alpha: 1),
                            dark: NSColor(calibratedRed: 0.62, green: 0.94, blue: 1.00, alpha: 1))
        case .brightWhite:
            return adaptive(light: NSColor(calibratedWhite: 0.15, alpha: 1),
                            dark: NSColor(calibratedWhite: 1.00, alpha: 1))
        }
    }
}

// MARK: - Scope

/// The All / Running filter.
enum ContainerScope: String, CaseIterable, Identifiable {
    case all, running

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        }
    }
}

/// A real `NSSearchField` for searches scoped to a document inside the inspector.
///
/// The main container collection uses SwiftUI's toolbar `.searchable`, which is the
/// correct window-wide search affordance. A logs, JSON, or environment search is scoped
/// to content already selected in that window. Registering a second toolbar search with
/// the same window would be semantically wrong and makes the system toolbar crowded, so
/// this bridge intentionally hosts AppKit's stock search control instead of drawing one.
struct DocumentSearchField: View {

    @Binding var text: String
    var prompt: String = "Search"
    var width: CGFloat = 220
    /// Optional trailing caption, e.g. a match count.
    var caption: String?
    /// The automation identifier for the embedded `NSSearchField`, per
    /// docs/design/ACCESSIBILITY-IDENTIFIERS.md. `nil` leaves the field unset rather
    /// than clobbering it with an empty string.
    var identifier: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            NativeSearchField(text: $text, prompt: prompt, identifier: identifier)
                .frame(width: width)
            if let caption, !text.isEmpty {
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct NativeSearchField: NSViewRepresentable {
        @Binding var text: String
        let prompt: String
        let identifier: String?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSSearchField {
            let field = NSSearchField()
            field.placeholderString = prompt
            field.sendsSearchStringImmediately = true
            field.delegate = context.coordinator
            if let identifier { field.setAccessibilityIdentifier(identifier) }
            return field
        }

        func updateNSView(_ field: NSSearchField, context: Context) {
            if field.stringValue != text { field.stringValue = text }
            if field.placeholderString != prompt { field.placeholderString = prompt }
            if let identifier { field.setAccessibilityIdentifier(identifier) }
        }

        static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
            field.delegate = nil
        }

        final class Coordinator: NSObject, NSSearchFieldDelegate {
            private var parent: NativeSearchField

            init(_ parent: NativeSearchField) {
                self.parent = parent
            }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSSearchField else { return }
                parent.text = field.stringValue
            }
        }
    }
}
