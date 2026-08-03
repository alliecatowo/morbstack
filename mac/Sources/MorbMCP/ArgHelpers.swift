// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Argument extraction for tool handlers. `tools/call` arguments arrive as an
// untyped JSON object (see JSONRPC.swift), and every handler needs the same
// three things from it: a required field that fails clearly when absent, an
// optional field with a default, and a bounded integer that clamps rather than
// rejects (a `duration_seconds` of 9999 should behave like the cap, not error
// out — the whole point of a cap is that the call still succeeds).

import Foundation
import MorbFeatures

enum ArgError: Error, CustomStringConvertible {
    case missing(String)
    case wrongType(String, expected: String)

    var description: String {
        switch self {
        case .missing(let field): return "missing required argument `\(field)`"
        case .wrongType(let field, let expected): return "argument `\(field)` must be \(expected)"
        }
    }
}

enum Args {
    static func requireString(_ arguments: [String: Any], _ field: String) throws -> String {
        guard let value = JSONRead.string(arguments, field) else {
            if arguments[field] != nil { throw ArgError.wrongType(field, expected: "a string") }
            throw ArgError.missing(field)
        }
        return value
    }

    static func optionalString(_ arguments: [String: Any], _ field: String) -> String? {
        JSONRead.string(arguments, field)
    }

    static func requireStringArray(_ arguments: [String: Any], _ field: String) throws -> [String] {
        guard let raw = arguments[field] else { throw ArgError.missing(field) }
        guard let array = raw as? [Any], let strings = array as? [String], !strings.isEmpty else {
            throw ArgError.wrongType(field, expected: "a non-empty array of strings")
        }
        return strings
    }

    static func optionalStringArray(_ arguments: [String: Any], _ field: String) -> [String] {
        JSONRead.strings(arguments, field)
    }

    static func optionalBool(_ arguments: [String: Any], _ field: String, default defaultValue: Bool) -> Bool {
        JSONRead.bool(arguments, field) ?? defaultValue
    }

    static func optionalStringMap(_ arguments: [String: Any], _ field: String) -> [String: String] {
        guard let dictionary = JSONRead.dictionary(arguments, field) else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in dictionary {
            if let string = value as? String { out[key] = string }
            else if let number = value as? NSNumber { out[key] = number.stringValue }
        }
        return out
    }

    /// A bounded integer: defaults when absent, clamps to `[minimum, maximum]`
    /// rather than erroring, since the bound exists to protect the server (an
    /// unbounded `tail` or `duration_seconds` could pin the process reading a
    /// live stream), not to police the caller.
    static func boundedInt(
        _ arguments: [String: Any], _ field: String, default defaultValue: Int, minimum: Int, maximum: Int
    ) -> Int {
        let raw = JSONRead.int(arguments, field) ?? defaultValue
        return Swift.min(Swift.max(raw, minimum), maximum)
    }
}
