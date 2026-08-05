// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Grammar checks for the identifiers a model hands this server.
//
// Every `id`/`reference` argument is interpolated into a Docker Engine API path
// (`/containers/{id}/json`, `/images/{reference}`), and an Engine API path is
// interpolated into an HTTP request line. `EngineClient.path` percent-encodes
// that path so no identifier can end the request line or start a query string —
// that is the load-bearing defence and it sits on the single call every request
// crosses. These checks are the second layer, and they buy two things the
// encoder cannot:
//
//   * `/` stays literal in a path (it is the path's structure, and image
//     references need it), so an unchecked container id like `x/json` still
//     reshapes which route the engine matches. Container ids and names cannot
//     contain `/`, so saying so here closes that.
//   * An agent that mistypes an identifier gets "this is not a container id"
//     rather than a 404 from a route it did not mean to call.

import Foundation

enum Identifier {

    /// Docker's own container name/id grammar: an optional leading `/` (which the
    /// engine emits on names in `/containers/json` and accepts back), then an
    /// alphanumeric, then alphanumerics, `_`, `.` or `-`.
    static func container(_ raw: String, field: String) throws -> String {
        try check(raw, field: field, limit: 255, allowLeadingSlash: true, extra: "_.-", label: "a container id or name")
    }

    /// An image reference: `name`, `name:tag`, `host:5000/org/name:tag`,
    /// `name@sha256:...`. Broader than ``container(_:field:)`` — `/`, `:` and `@`
    /// are all structural in a reference — but still no whitespace, no control
    /// characters, and nothing that could be read as a query or fragment.
    static func imageReference(_ raw: String, field: String) throws -> String {
        try check(raw, field: field, limit: 512, allowLeadingSlash: false, extra: "_.-:/@", label: "an image reference")
    }

    private static func check(
        _ raw: String, field: String, limit: Int, allowLeadingSlash: Bool, extra: String, label: String
    ) throws -> String {
        guard !raw.isEmpty else {
            throw ArgError.invalid(field, reason: "must not be empty; expected \(label)")
        }
        guard raw.utf8.count <= limit else {
            throw ArgError.invalid(field, reason: "is \(raw.utf8.count) bytes; \(label) is at most \(limit)")
        }
        var characters = Substring(raw)
        if allowLeadingSlash, characters.hasPrefix("/") { characters = characters.dropFirst() }
        guard let first = characters.first, first.isASCII, first.isLetter || first.isNumber else {
            throw ArgError.invalid(field, reason: "must start with a letter or digit; expected \(label)")
        }
        for character in characters {
            let isAllowed = character.isASCII
                && (character.isLetter || character.isNumber || extra.contains(character))
            guard isAllowed else {
                throw ArgError.invalid(
                    field,
                    reason: "contains \(describe(character)), which \(label) cannot; "
                        + "allowed characters are letters, digits, and `\(extra)`")
            }
        }
        return raw
    }

    /// Names the offending character without echoing a raw control byte back into
    /// the agent's transcript (or, by way of the tool result, into the audit log).
    private static func describe(_ character: Character) -> String {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return "an unsupported character"
        }
        if scalar.value < 0x20 || scalar.value == 0x7F || !scalar.isASCII {
            return String(format: "the character U+%04X", scalar.value)
        }
        return "`\(character)`"
    }
}
