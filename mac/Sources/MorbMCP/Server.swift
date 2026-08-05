// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// MCP method dispatch and the deliberately small stdio transport used by
// `morb mcp serve`. The transport is newline-delimited JSON-RPC: stdin and
// stdout are never used for human-facing text, and individual inbound/outbound
// records are capped so a broken client cannot grow this process without bound.

import Foundation
import MorbstackKit

/// The protocol dispatcher. It is intentionally synchronous: Docker API calls in
/// the existing feature primitives are synchronous, and serial request processing
/// means audit records stay in the same order as the client transcript.
final class MCPServer {

    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let toolsPageSize = 20
    static let maximumMessageBytes = 1_048_576

    private let profile: PermissionProfile
    private let context: ToolContext
    private let audit: AuditLog
    private var hasInitialized = false

    init(profile: PermissionProfile, context: ToolContext, audit: AuditLog) {
        self.profile = profile
        self.context = context
        self.audit = audit
    }

    /// Handles one valid JSON-RPC request. `nil` means the request was a
    /// notification and therefore must not produce a JSON-RPC response.
    func handle(_ request: JSONRPCRequest) -> String? {
        // The MCP request methods below all have meaningful replies. Refusing to
        // run them as JSON-RPC notifications prevents a mutating call from being
        // fire-and-forget, while still honoring the standard MCP notifications.
        if request.isNotification {
            if request.method == "tools/call" { auditRejectedNotification(request) }
            return nil
        }

        if request.method == "initialize" {
            return initialize(request)
        }

        guard hasInitialized else {
            let message = "send `initialize` before calling MCP methods"
            // A `tools/call` rejected for arriving before the handshake is still an
            // attempt to run a tool, and the audit log's whole claim is that every
            // attempt reaches it — including the ones this server refused. Leaving
            // this one out would make "no record" mean either "never asked" or
            // "asked out of order", which is exactly the ambiguity an audit log
            // exists to remove.
            if request.method == "tools/call" {
                auditProtocolFailure(
                    tool: request.params?["name"] as? String ?? "<missing name>",
                    arguments: request.params?["arguments"] as? [String: Any] ?? [:],
                    message: message)
            }
            return error(request, code: JSONRPCErrorCode.invalidRequest, message: message)
        }

        switch request.method {
        case "ping":
            return result(request, [:])

        case "tools/list":
            return listTools(request)

        case "tools/call":
            return callTool(request)

        // Sent by most MCP clients immediately after initialization. It carries
        // no request/response semantics, so accepting it makes lifecycle handling
        // explicit while the early notification return above preserves its silence.
        case "notifications/initialized", "notifications/cancelled":
            return nil

        default:
            return error(request, code: JSONRPCErrorCode.methodNotFound,
                         message: "unknown MCP method `\(request.method)`")
        }
    }

    private func initialize(_ request: JSONRPCRequest) -> String? {
        guard !hasInitialized else {
            return error(request, code: JSONRPCErrorCode.invalidRequest,
                         message: "`initialize` may be called only once per MCP session")
        }
        guard let clientVersion = request.params?["protocolVersion"] as? String,
              !clientVersion.isEmpty
        else {
            return error(request, code: JSONRPCErrorCode.invalidParams,
                         message: "`initialize` requires a string `protocolVersion`")
        }

        // A client may advertise a newer protocol than this binary knows. The MCP
        // handshake permits the server to choose a supported version; prefer the
        // client's exact version when possible, otherwise use our newest one.
        let selectedVersion = Self.protocolVersions.contains(clientVersion)
            ? clientVersion : Self.protocolVersions[0]
        hasInitialized = true
        return result(request, [
            "protocolVersion": selectedVersion,
            "capabilities": [
                "tools": ["listChanged": false],
            ],
            "serverInfo": [
                "name": "morbstack",
                "version": MorbVersion.string,
            ],
            "instructions": "Morbstack MCP is read-only by default. Inspect tool descriptions and use `morb mcp permissions` before granting writes.",
        ])
    }

    private func listTools(_ request: JSONRPCRequest) -> String? {
        let start: Int
        if let cursor = request.params?["cursor"] {
            guard let text = cursor as? String, let parsed = Int(text),
                  parsed >= 0, parsed < ToolRegistry.all.count
            else {
                return error(request, code: JSONRPCErrorCode.invalidParams,
                             message: "`cursor` must be a page cursor returned by this server")
            }
            start = parsed
        } else {
            start = 0
        }

        let end = min(start + Self.toolsPageSize, ToolRegistry.all.count)
        let tools = ToolRegistry.all[start..<end].map { toolDescription($0) }
        var payload: [String: Any] = ["tools": tools]
        if end < ToolRegistry.all.count { payload["nextCursor"] = String(end) }
        return result(request, payload)
    }

    private func toolDescription(_ tool: ToolSpec) -> [String: Any] {
        let baseDecision = profile.decide(tool.permissionSubject)
        var description = tool.summary
        if !baseDecision.allowed {
            description += "\n\nPermission: currently unavailable — \(baseDecision.explanation)"
        }
        if !tool.guards.isEmpty {
            let guards = tool.guards.map { "`\($0.key)`: \($0.description)" }.joined(separator: "\n")
            description += "\n\nSensitive argument grants:\n\(guards)"
        }
        return [
            "name": tool.name,
            "description": description,
            "inputSchema": tool.inputSchema,
            "annotations": [
                "readOnlyHint": tool.readOnly,
                "destructiveHint": tool.destructive,
            ],
        ]
    }

    private func callTool(_ request: JSONRPCRequest) -> String? {
        guard let name = request.params?["name"] as? String, !name.isEmpty else {
            auditProtocolFailure(
                tool: "<missing name>", arguments: request.params?["arguments"] as? [String: Any] ?? [:],
                message: "`tools/call` requires a non-empty string `name`")
            return error(request, code: JSONRPCErrorCode.invalidParams,
                         message: "`tools/call` requires a non-empty string `name`")
        }
        let arguments: [String: Any]
        if let rawArguments = request.params?["arguments"] {
            guard let decoded = rawArguments as? [String: Any] else {
                auditProtocolFailure(
                    tool: name, arguments: [:], message: "`tools/call.arguments` must be an object")
                return error(request, code: JSONRPCErrorCode.invalidParams,
                             message: "`tools/call.arguments` must be an object")
            }
            arguments = decoded
        } else {
            arguments = [:]
        }

        let started = Date()
        guard let tool = ToolRegistry.tool(named: name) else {
            let decision = PermissionDecision(
                allowed: false, allowedBy: nil, deniedBy: nil,
                explanation: "denied: no MCP tool named `\(name)` is registered")
            let toolResult = ToolCallResult.errorText("unknown Morbstack MCP tool `\(name)`")
            record(tool: name, decision: decision, arguments: arguments, started: started, result: toolResult)
            return result(request, toolCallPayload(toolResult))
        }

        let toolDecision = profile.decide(tool.permissionSubject)
        guard toolDecision.allowed else {
            let toolResult = ToolCallResult.errorText("tool `\(name)` is not allowed: \(toolDecision.explanation)")
            record(tool: name, decision: toolDecision, arguments: arguments, started: started, result: toolResult)
            return result(request, toolCallPayload(toolResult))
        }

        for guardSpec in tool.guards where guardSpec.appliesTo(arguments) {
            let guardDecision = profile.decideGuardKey(guardSpec.key)
            guard guardDecision.allowed else {
                let toolResult = ToolCallResult.errorText(
                    "tool `\(name)` requires the `\(guardSpec.key)` grant for these arguments: "
                        + guardDecision.explanation)
                record(tool: name, decision: guardDecision, arguments: arguments, started: started, result: toolResult)
                return result(request, toolCallPayload(toolResult))
            }
        }

        let toolResult = tool.handler(context, arguments)
        record(tool: name, decision: toolDecision, arguments: arguments, started: started, result: toolResult)
        return result(request, toolCallPayload(toolResult))
    }

    private func auditRejectedNotification(_ request: JSONRPCRequest) {
        let name = request.params?["name"] as? String ?? "<missing name>"
        let arguments = request.params?["arguments"] as? [String: Any] ?? [:]
        auditProtocolFailure(
            tool: name, arguments: arguments,
            message: "`tools/call` must be a JSON-RPC request with an id, not a notification")
    }

    private func auditProtocolFailure(tool: String, arguments: [String: Any], message: String) {
        let decision = PermissionDecision(allowed: false, allowedBy: nil, deniedBy: nil, explanation: "denied: \(message)")
        let toolResult = ToolCallResult.errorText(message)
        record(tool: tool, decision: decision, arguments: arguments, started: Date(), result: toolResult)
    }

    private func record(
        tool: String, decision: PermissionDecision, arguments: [String: Any], started: Date, result: ToolCallResult
    ) {
        let summary = result.content.compactMap { $0["text"] as? String }.joined(separator: " ")
        audit.recordToolCall(
            tool: tool, decision: decision, arguments: arguments,
            durationMS: Date().timeIntervalSince(started) * 1_000,
            ok: !result.isError, resultSummary: summary)
    }

    private func toolCallPayload(_ result: ToolCallResult) -> [String: Any] {
        ["content": result.content, "isError": result.isError]
    }

    private func result(_ request: JSONRPCRequest, _ payload: Any) -> String? {
        guard request.hasID else { return nil }
        let encoded = JSONRPCCodec.encodeResult(id: responseID(request), result: payload)
        return bound(encoded, request: request)
    }

    private func error(_ request: JSONRPCRequest, code: Int, message: String) -> String? {
        guard request.hasID else { return nil }
        let encoded = JSONRPCCodec.encodeError(id: responseID(request), code: code, message: message)
        return bound(encoded, request: request)
    }

    private func responseID(_ request: JSONRPCRequest) -> Any {
        request.id ?? NSNull()
    }

    private func bound(_ response: String, request: JSONRPCRequest) -> String {
        guard response.utf8.count <= Self.maximumMessageBytes else {
            return JSONRPCCodec.encodeError(
                id: responseID(request), code: JSONRPCErrorCode.internalError,
                message: "response exceeded the \(Self.maximumMessageBytes)-byte MCP message limit")
        }
        return response
    }
}

/// A line reader that never buffers more than one bounded protocol record.
final class MCPStdioLineReader {

    enum ReadResult {
        case line(String)
        case tooLong
        case invalidUTF8
        case endOfFile
        case failure(String)
    }

    private let input: FileHandle
    private let maximumLineBytes: Int
    private let chunkSize = 8_192
    private var buffer = Data()
    private var discardingOversizeLine = false

    init(input: FileHandle = .standardInput, maximumLineBytes: Int = MCPServer.maximumMessageBytes) {
        self.input = input
        self.maximumLineBytes = maximumLineBytes
    }

    func next() -> ReadResult {
        while true {
            if discardingOversizeLine {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    buffer.removeSubrange(buffer.startIndex...newline)
                    discardingOversizeLine = false
                    return .tooLong
                }
                buffer.removeAll(keepingCapacity: true)
            } else if let newline = buffer.firstIndex(of: 0x0A) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumLineBytes else {
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return .tooLong
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return decode(line)
            } else if buffer.count > maximumLineBytes {
                discardingOversizeLine = true
                continue
            }

            let nextChunk: Data
            do {
                nextChunk = try input.read(upToCount: chunkSize) ?? Data()
            } catch {
                return .failure(error.localizedDescription)
            }
            if nextChunk.isEmpty {
                if discardingOversizeLine {
                    discardingOversizeLine = false
                    return .tooLong
                }
                guard !buffer.isEmpty else { return .endOfFile }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return line.count > maximumLineBytes ? .tooLong : decode(line)
            }
            buffer.append(nextChunk)
        }
    }

    private func decode(_ data: Data) -> ReadResult {
        let withoutCarriageReturn: Data
        if data.last == 0x0D {
            withoutCarriageReturn = Data(data.dropLast())
        } else {
            withoutCarriageReturn = data
        }
        guard let line = String(data: withoutCarriageReturn, encoding: .utf8) else {
            return .invalidUTF8
        }
        return .line(line)
    }
}

/// Owns stdout for `morb mcp serve`. No command usage, progress, or warning is
/// ever printed here; those go to stderr from `MCPCLI` so an MCP client can parse
/// stdout as a pure JSON-RPC stream.
final class MCPStdioServer {

    private let server: MCPServer
    private let reader: MCPStdioLineReader
    private let output: FileHandle
    private let errorOutput: FileHandle

    init(
        server: MCPServer,
        reader: MCPStdioLineReader = MCPStdioLineReader(),
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) {
        self.server = server
        self.reader = reader
        self.output = output
        self.errorOutput = errorOutput
    }

    func run() -> Int32 {
        while true {
            switch reader.next() {
            case .line(let line):
                handle(line)

            case .tooLong:
                write(JSONRPCCodec.encodeError(
                    id: NSNull(), code: JSONRPCErrorCode.parseError,
                    message: "incoming JSON-RPC message exceeded the \(MCPServer.maximumMessageBytes)-byte limit"))

            case .invalidUTF8:
                write(JSONRPCCodec.encodeError(
                    id: NSNull(), code: JSONRPCErrorCode.parseError,
                    message: "incoming JSON-RPC message is not valid UTF-8"))

            case .endOfFile:
                return 0

            case .failure(let message):
                errorOutput.write(Data(("morb mcp: stdin failed: \(message)\n").utf8))
                return 2
            }
        }
    }

    private func handle(_ line: String) {
        switch JSONRPCCodec.parseLine(line) {
        case .request(let request):
            if let response = server.handle(request) { write(response) }

        case .parseError(let message):
            write(JSONRPCCodec.encodeError(
                id: NSNull(), code: JSONRPCErrorCode.parseError, message: message))

        case .invalidRequest(let message, let id, let hasID):
            // Invalid JSON-RPC notifications intentionally remain silent. A parse
            // error is different because no notification status can be determined.
            guard hasID else { return }
            write(JSONRPCCodec.encodeError(
                id: id ?? NSNull(), code: JSONRPCErrorCode.invalidRequest, message: message))
        }
    }

    private func write(_ response: String) {
        // `MCPServer` bounds normal replies. Parser replies are all fixed, small
        // strings. Keep this final guard anyway so stdout is never made unbounded by
        // a future dispatcher path bypassing the common encoder.
        let payload: String
        if response.utf8.count <= MCPServer.maximumMessageBytes {
            payload = response
        } else {
            payload = JSONRPCCodec.encodeError(
                id: NSNull(), code: JSONRPCErrorCode.internalError,
                message: "server response exceeded the MCP message limit")
        }
        output.write(Data((payload + "\n").utf8))
    }
}
