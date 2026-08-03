// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// JSON-RPC 2.0 framing for `morb mcp serve`: one JSON object per line on stdin,
// one per line on stdout, nothing else ever touches stdout. Parsing and
// encoding are kept separate from the MCP method dispatch in Server.swift on
// purpose — this file has no idea what `tools/call` means, which is what makes
// it possible to unit test "does a truncated line produce a -32700" without
// standing up a whole server.

import Foundation

public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

/// A successfully parsed JSON-RPC request or notification.
///
/// `hasID` — not merely `id != nil` — is the fact that decides whether a reply
/// is ever sent. JSON-RPC 2.0 distinguishes a notification (the `id` member is
/// *absent*) from a request whose `id` happens to be JSON `null` (present, and
/// unusual, but still a request that gets a response). Collapsing those into
/// one optional would make "absent" and "present-but-null" indistinguishable.
public struct JSONRPCRequest {
    public var id: Any?
    public var hasID: Bool
    public var method: String
    public var params: [String: Any]?

    public var isNotification: Bool { !hasID }
}

public enum JSONRPCParseResult {
    case request(JSONRPCRequest)
    /// The line was not valid JSON, or not a JSON object at all. There is no id
    /// to cite, so per spec the reply (when the transport still wants one) uses
    /// `id: null`.
    case parseError(message: String)
    /// Valid JSON, but not a valid JSON-RPC 2.0 request: wrong/missing
    /// `jsonrpc`, missing/non-string `method`, or a malformed `params`. `id`
    /// and `hasID` are preserved from whatever was actually in the object, so
    /// the caller can still reply correctly if one was present.
    case invalidRequest(message: String, id: Any?, hasID: Bool)
}

public enum JSONRPCCodec {

    /// Parses one line of input. Never throws — every failure mode is a case
    /// of ``JSONRPCParseResult``, because a malformed line from a client is
    /// exactly the situation this exists to handle gracefully, not crash on.
    public static func parseLine(_ line: String) -> JSONRPCParseResult {
        guard let data = line.data(using: .utf8) else {
            return .parseError(message: "line is not valid UTF-8")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .parseError(message: "invalid JSON: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else {
            return .parseError(message: "top-level JSON value must be an object")
        }
        let hasID = dictionary.keys.contains("id")
        let id = dictionary["id"]
        guard (dictionary["jsonrpc"] as? String) == "2.0" else {
            return .invalidRequest(message: "missing or wrong `jsonrpc` version; expected \"2.0\"", id: id, hasID: hasID)
        }
        guard let method = dictionary["method"] as? String, !method.isEmpty else {
            return .invalidRequest(message: "missing or non-string `method`", id: id, hasID: hasID)
        }
        var params: [String: Any]?
        if let raw = dictionary["params"] {
            guard let dictionaryParams = raw as? [String: Any] else {
                return .invalidRequest(message: "`params` must be an object", id: id, hasID: hasID)
            }
            params = dictionaryParams
        }
        return .request(JSONRPCRequest(id: id, hasID: hasID, method: method, params: params))
    }

    /// Encodes a successful reply. `id` should be the request's own `id`
    /// (`NSNull()` for a JSON-`null` id, never Swift `nil` — a reply always
    /// carries an `id` member).
    public static func encodeResult(id: Any, result: Any) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Encodes an error reply. `id` is `NSNull()` when the request's id could
    /// not be determined (a parse error) or was never present.
    public static func encodeError(id: Any, code: Int, message: String, data: Any? = nil) -> String {
        var errorObject: [String: Any] = ["code": code, "message": message]
        if let data { errorObject["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id, "error": errorObject])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else {
            // Reachable only if a tool handler's own result contains something
            // JSONSerialization cannot encode — a bug in this codebase, not a
            // client error. Still must not crash a long-running stdio server
            // over one bad response.
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error: could not encode response"}}"#
        }
        return text
    }
}
