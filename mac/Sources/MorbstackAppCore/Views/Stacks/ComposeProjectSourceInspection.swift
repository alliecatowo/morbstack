// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deliberately non-evaluating view of one explicitly selected Compose source file.
// This is not a Compose parser and never determines an effective environment. It
// reports only conservative, block-style source declarations. It does not interpolate,
// follow includes, open an env/secret file, access Keychain, or read inherited values.

import Foundation

struct ComposeProjectSourceInspection: Equatable {

    struct EnvironmentDeclaration: Identifiable, Equatable {
        enum ValueDisposition: Equatable {
            case empty
            case set
            case redacted
        }

        let key: String
        let line: Int
        let valueDisposition: ValueDisposition
        let isPotentiallySensitive: Bool

        var id: String { "\(line):\(key)" }
    }

    /// A service-level `environment:` declaration. The inspector deliberately records
    /// only whether source text supplied a value; it never surfaces that value or
    /// claims the resulting container environment after Compose precedence.
    struct ServiceEnvironmentDeclaration: Identifiable, Equatable {
        enum ValueSource: Equatable {
            case declaredInSource
            case requiresComposeResolution
        }

        let service: String
        let key: String
        let line: Int
        let valueSource: ValueSource
        let isPotentiallySensitive: Bool

        var id: String { "\(service):\(line):\(key)" }
    }

    /// A service `env_file:` reference. `path` is source text, never a filesystem
    /// lookup. `required` and `format` are retained only when their block syntax is
    /// explicit, so no default or effective-result claim is made here.
    struct EnvironmentFileDeclaration: Identifiable, Equatable {
        let service: String
        let path: String?
        let line: Int
        let required: Bool?
        let format: String?

        var id: String { "\(service):\(line):\(path ?? "unknown")" }
    }

    /// A lexical `$VAR` or `${VAR…}` token outside a single-quoted source span. The
    /// declaration can still be in an unsupported YAML construct, so it is explicitly
    /// a possible interpolation input rather than an effective-value assertion.
    struct InterpolationReference: Identifiable, Equatable {
        let name: String
        let line: Int
        let isPotentiallySensitive: Bool

        var id: String { "\(line):\(name)" }
    }

    struct SecretDeclaration: Identifiable, Equatable {
        enum Source: Equatable {
            case file(path: String?)
            case environment(variable: String?)
            case external
            case notDeclared
            case ambiguous
        }

        let name: String
        let line: Int
        let source: Source

        var id: String { "\(line):\(name)" }
    }

    /// An explicit service grant. Compose's top-level declaration does not grant
    /// access by itself; this reports only a recognized service `secrets:` entry.
    struct SecretGrant: Identifiable, Equatable {
        enum Syntax: Equatable {
            case short
            case long
        }

        let service: String
        let secretName: String?
        let line: Int
        let syntax: Syntax
        let target: String?

        var id: String { "\(service):\(line):\(secretName ?? "unknown")" }
    }

    let environmentDeclarations: [EnvironmentDeclaration]
    let serviceEnvironmentDeclarations: [ServiceEnvironmentDeclaration]
    let environmentFileDeclarations: [EnvironmentFileDeclaration]
    let interpolationReferences: [InterpolationReference]
    let secretDeclarations: [SecretDeclaration]
    let secretGrants: [SecretGrant]

    static func inspect(text: String, sourceKind: ComposeProjectSourceKind) -> Self {
        switch sourceKind {
        case .projectEnvironment:
            Self(
                environmentDeclarations: environmentDeclarations(in: text),
                serviceEnvironmentDeclarations: [],
                environmentFileDeclarations: [],
                interpolationReferences: interpolationReferences(in: text),
                secretDeclarations: [],
                secretGrants: [])
        case .composeYAML:
            let lines = sourceLines(in: text)
            Self(
                environmentDeclarations: [],
                serviceEnvironmentDeclarations: serviceEnvironmentDeclarations(in: lines),
                environmentFileDeclarations: environmentFileDeclarations(in: lines),
                interpolationReferences: interpolationReferences(in: text),
                secretDeclarations: topLevelSecretDeclarations(in: lines),
                secretGrants: secretGrants(in: lines))
        }
    }

    private static func environmentDeclarations(in text: String) -> [EnvironmentDeclaration] {
        text.components(separatedBy: .newlines).enumerated().compactMap { offset, sourceLine in
            var line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { return nil }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard isEnvironmentName(key) else { return nil }

            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isPotentiallySensitive = looksSensitive(key: key)
            let disposition: EnvironmentDeclaration.ValueDisposition
            if value.isEmpty {
                disposition = .empty
            } else if isPotentiallySensitive {
                disposition = .redacted
            } else {
                disposition = .set
            }
            return EnvironmentDeclaration(
                key: key,
                line: offset + 1,
                valueDisposition: disposition,
                isPotentiallySensitive: isPotentiallySensitive)
        }
    }

    private static func serviceEnvironmentDeclarations(in lines: [SourceLine]) -> [ServiceEnvironmentDeclaration] {
        services(in: lines).flatMap { service in
            directMappings(in: service, lines: lines)
                .filter { $0.key == "environment" }
                .flatMap { environmentNode in
                    environmentEntries(for: environmentNode, service: service.key, lines: lines)
                }
        }
    }

    private static func environmentEntries(
        for node: MappingNode,
        service: String,
        lines: [SourceLine]
    ) -> [ServiceEnvironmentDeclaration] {
        let childIndent = directChildIndent(of: node, lines: lines)
        guard let childIndent else { return [] }

        return lines[node.index + 1..<node.endIndex].compactMap { line in
            guard line.indentation == childIndent else { return nil }
            if let item = line.listItem {
                let itemText = scalar(item)
                guard !itemText.isEmpty else { return nil }
                if let separator = itemText.firstIndex(of: "=") {
                    let key = String(itemText[..<separator]).trimmingCharacters(in: .whitespaces)
                    guard isEnvironmentName(key) else { return nil }
                    return ServiceEnvironmentDeclaration(
                        service: service,
                        key: key,
                        line: line.number,
                        valueSource: .declaredInSource,
                        isPotentiallySensitive: looksSensitive(key: key))
                }
                guard isEnvironmentName(itemText) else { return nil }
                return ServiceEnvironmentDeclaration(
                    service: service,
                    key: itemText,
                    line: line.number,
                    valueSource: .requiresComposeResolution,
                    isPotentiallySensitive: looksSensitive(key: itemText))
            }
            guard let mapping = line.mapping, isEnvironmentName(mapping.key) else { return nil }
            return ServiceEnvironmentDeclaration(
                service: service,
                key: mapping.key,
                line: line.number,
                valueSource: valueRequiresResolution(mapping.value)
                    ? .requiresComposeResolution
                    : .declaredInSource,
                isPotentiallySensitive: looksSensitive(key: mapping.key))
        }
    }

    private static func environmentFileDeclarations(in lines: [SourceLine]) -> [EnvironmentFileDeclaration] {
        services(in: lines).flatMap { service in
            directMappings(in: service, lines: lines)
                .filter { $0.key == "env_file" }
                .flatMap { node in
                    environmentFileEntries(for: node, service: service.key, lines: lines)
                }
        }
    }

    private static func environmentFileEntries(
        for node: MappingNode,
        service: String,
        lines: [SourceLine]
    ) -> [EnvironmentFileDeclaration] {
        if !node.value.isEmpty {
            return [EnvironmentFileDeclaration(
                service: service,
                path: sourceScalar(node.value),
                line: node.line,
                required: nil,
                format: nil)]
        }
        guard let childIndent = directChildIndent(of: node, lines: lines) else { return [] }

        var declarations: [EnvironmentFileDeclaration] = []
        var index = node.index + 1
        while index < node.endIndex {
            let line = lines[index]
            guard line.indentation == childIndent else {
                index += 1
                continue
            }
            if let item = line.listItem {
                let itemEnd = nextItemEnd(startingAt: index, parentEnd: node.endIndex, indentation: childIndent, lines: lines)
                if let mapping = mapping(in: item), mapping.key == "path" {
                    let details = nestedMappings(startingAt: index, endingAt: itemEnd, lines: lines)
                    declarations.append(EnvironmentFileDeclaration(
                        service: service,
                        path: sourceScalar(mapping.value),
                        line: line.number,
                        required: boolValue(details["required"]),
                        format: sourceScalar(details["format"] ?? "")))
                } else {
                    if let path = sourceScalar(item) {
                        declarations.append(EnvironmentFileDeclaration(
                            service: service,
                            path: path,
                            line: line.number,
                            required: nil,
                            format: nil))
                    }
                }
                index = itemEnd
                continue
            }
            if let mapping = line.mapping, mapping.key == "path" {
                declarations.append(EnvironmentFileDeclaration(
                    service: service,
                    path: sourceScalar(mapping.value),
                    line: line.number,
                    required: nil,
                    format: nil))
            }
            index += 1
        }
        return declarations
    }

    private static func topLevelSecretDeclarations(in lines: [SourceLine]) -> [SecretDeclaration] {
        topLevelMappings(named: "secrets", lines: lines).flatMap { secretsNode in
            blockEntries(in: secretsNode, lines: lines).map { declaration in
                SecretDeclaration(
                    name: declaration.key,
                    line: declaration.line,
                    source: secretSource(for: declaration, lines: lines))
            }
        }
    }

    private static func secretSource(for declaration: MappingNode, lines: [SourceLine]) -> SecretDeclaration.Source {
        let fields = directMappings(in: declaration, lines: lines)
        var sources: [SecretDeclaration.Source] = []
        for field in fields {
            switch field.key {
            case "file":
                sources.append(.file(path: sourceScalar(field.value)))
            case "environment":
                sources.append(.environment(variable: sourceScalar(field.value)))
            case "external":
                sources.append(.external)
            default:
                continue
            }
        }
        switch sources.count {
        case 0: return .notDeclared
        case 1: return sources[0]
        default: return .ambiguous
        }
    }

    private static func secretGrants(in lines: [SourceLine]) -> [SecretGrant] {
        services(in: lines).flatMap { service in
            directMappings(in: service, lines: lines)
                .filter { $0.key == "secrets" }
                .flatMap { node in
                    secretGrants(for: node, service: service.key, lines: lines)
                }
        }
    }

    private static func secretGrants(
        for node: MappingNode,
        service: String,
        lines: [SourceLine]
    ) -> [SecretGrant] {
        guard let childIndent = directChildIndent(of: node, lines: lines) else { return [] }
        var grants: [SecretGrant] = []
        var index = node.index + 1
        while index < node.endIndex {
            let line = lines[index]
            guard line.indentation == childIndent, let item = line.listItem else {
                index += 1
                continue
            }
            let itemEnd = nextItemEnd(startingAt: index, parentEnd: node.endIndex, indentation: childIndent, lines: lines)
            if let mapping = mapping(in: item), mapping.key == "source" {
                let details = nestedMappings(startingAt: index, endingAt: itemEnd, lines: lines)
                grants.append(SecretGrant(
                    service: service,
                    secretName: sourceScalar(mapping.value),
                    line: line.number,
                    syntax: .long,
                    target: sourceScalar(details["target"] ?? "")))
            } else {
                guard let name = sourceScalar(item), !name.hasPrefix("{") else {
                    index = itemEnd
                    continue
                }
                grants.append(SecretGrant(
                    service: service,
                    secretName: name,
                    line: line.number,
                    syntax: .short,
                    target: nil))
            }
            index = itemEnd
        }
        return grants
    }

    private static func interpolationReferences(in text: String) -> [InterpolationReference] {
        var references: [InterpolationReference] = []
        var seen = Set<String>()
        for (offset, sourceLine) in text.components(separatedBy: .newlines).enumerated() {
            for name in interpolationNames(in: sourceLine) {
                let identity = "\(offset + 1):\(name)"
                guard seen.insert(identity).inserted else { continue }
                references.append(InterpolationReference(
                    name: name,
                    line: offset + 1,
                    isPotentiallySensitive: looksSensitive(key: name)))
            }
        }
        return references
    }

    /// This intentionally small lexer follows Compose's source-level distinction that
    /// single-quoted values are literal. YAML collection and include semantics remain
    /// the Compose client's responsibility, so a result is a possible input only.
    private static func interpolationNames(in sourceLine: String) -> [String] {
        let characters = Array(sourceLine)
        var names: [String] = []
        var index = 0
        var isSingleQuoted = false
        var isDoubleQuoted = false
        var isEscaped = false

        while index < characters.count {
            let character = characters[index]
            if isSingleQuoted {
                if character == "'" {
                    if index + 1 < characters.count, characters[index + 1] == "'" {
                        index += 2
                        continue
                    }
                    isSingleQuoted = false
                }
                index += 1
                continue
            }
            if isDoubleQuoted {
                if isEscaped {
                    isEscaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    isEscaped = true
                    index += 1
                    continue
                }
                if character == "\"" {
                    isDoubleQuoted = false
                    index += 1
                    continue
                }
            } else if character == "'" {
                isSingleQuoted = true
                index += 1
                continue
            } else if character == "\"" {
                isDoubleQuoted = true
                index += 1
                continue
            } else if character == "#", index == 0 || characters[index - 1].isWhitespace {
                break
            }

            guard character == "$", index + 1 < characters.count else {
                index += 1
                continue
            }
            if characters[index + 1] == "$" {
                index += 2
                continue
            }
            let nameStart: Int
            if characters[index + 1] == "{" {
                nameStart = index + 2
            } else {
                nameStart = index + 1
            }
            guard nameStart < characters.count, isEnvironmentNameStart(characters[nameStart]) else {
                index += 1
                continue
            }
            var nameEnd = nameStart + 1
            while nameEnd < characters.count, isEnvironmentNameContinuation(characters[nameEnd]) {
                nameEnd += 1
            }
            names.append(String(characters[nameStart..<nameEnd]))
            index = nameEnd
        }
        return names
    }

    private static func sourceLines(in text: String) -> [SourceLine] {
        text.components(separatedBy: .newlines).enumerated().compactMap { offset, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return SourceLine(number: offset + 1, text: text)
        }
    }

    private static func topLevelMappings(named name: String, lines: [SourceLine]) -> [MappingNode] {
        lines.indices.compactMap { index in
            guard lines[index].indentation == 0,
                  let mapping = lines[index].mapping,
                  mapping.key == name
            else { return nil }
            return MappingNode(
                key: mapping.key,
                value: mapping.value,
                line: lines[index].number,
                index: index,
                indentation: lines[index].indentation,
                endIndex: blockEnd(startingAt: index, parentIndentation: lines[index].indentation, lines: lines))
        }
    }

    private static func services(in lines: [SourceLine]) -> [MappingNode] {
        topLevelMappings(named: "services", lines: lines).flatMap { blockEntries(in: $0, lines: lines) }
    }

    private static func blockEntries(in node: MappingNode, lines: [SourceLine]) -> [MappingNode] {
        directMappings(in: node, lines: lines)
    }

    private static func directMappings(in node: MappingNode, lines: [SourceLine]) -> [MappingNode] {
        guard let childIndent = directChildIndent(of: node, lines: lines) else { return [] }
        return lines.indices.compactMap { index in
            guard index > node.index, index < node.endIndex,
                  lines[index].indentation == childIndent,
                  let mapping = lines[index].mapping
            else { return nil }
            return MappingNode(
                key: mapping.key,
                value: mapping.value,
                line: lines[index].number,
                index: index,
                indentation: lines[index].indentation,
                endIndex: blockEnd(startingAt: index, parentIndentation: lines[index].indentation, limit: node.endIndex, lines: lines))
        }
    }

    private static func directChildIndent(of node: MappingNode, lines: [SourceLine]) -> Int? {
        lines[node.index + 1..<node.endIndex]
            .filter { $0.indentation > node.indentation }
            .map(\.indentation)
            .min()
    }

    private static func blockEnd(
        startingAt index: Int,
        parentIndentation: Int,
        limit: Int? = nil,
        lines: [SourceLine]
    ) -> Int {
        let end = limit ?? lines.endIndex
        var cursor = index + 1
        while cursor < end {
            if lines[cursor].indentation <= parentIndentation { break }
            cursor += 1
        }
        return cursor
    }

    private static func nextItemEnd(
        startingAt index: Int,
        parentEnd: Int,
        indentation: Int,
        lines: [SourceLine]
    ) -> Int {
        var cursor = index + 1
        while cursor < parentEnd {
            if lines[cursor].indentation <= indentation { break }
            cursor += 1
        }
        return cursor
    }

    private static func nestedMappings(startingAt index: Int, endingAt end: Int, lines: [SourceLine]) -> [String: String] {
        var mappings: [String: String] = [:]
        for line in lines[index + 1..<end] {
            guard let mapping = line.mapping else { continue }
            mappings[mapping.key] = mapping.value
        }
        return mappings
    }

    private static func mapping(in text: String) -> (key: String, value: String)? {
        guard let separator = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func scalar(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result.removeFirst()
            result.removeLast()
        } else if result.hasPrefix("'") && result.hasSuffix("'") && result.count >= 2 {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    private static func sourceScalar(_ value: String) -> String? {
        let result = scalar(value)
        return result.isEmpty ? nil : result
    }

    private static func boolValue(_ value: String?) -> Bool? {
        switch scalar(value ?? "").lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func valueRequiresResolution(_ value: String) -> Bool {
        let normalized = scalar(value).lowercased()
        return normalized.isEmpty || normalized == "null" || normalized == "~"
    }

    private static func isEnvironmentName(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    private static func isEnvironmentNameStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isEnvironmentNameContinuation(_ character: Character) -> Bool {
        isEnvironmentNameStart(character) || character.isNumber
    }

    private static func looksSensitive(key: String) -> Bool {
        let lowered = key.lowercased()
        let markers = [
            "secret", "password", "passwd", "token", "apikey", "api_key",
            "access_key", "private_key", "credential", "auth", "session",
            "cookie", "database_url", "connection_string",
        ]
        return markers.contains { lowered.contains($0) }
    }

    private struct SourceLine {
        let number: Int
        let text: String

        var indentation: Int {
            text.prefix { $0 == " " || $0 == "\t" }.count
        }

        var trimmed: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var listItem: String? {
            guard trimmed.hasPrefix("-") else { return nil }
            let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }

        var mapping: (key: String, value: String)? {
            guard listItem == nil else { return nil }
            return ComposeProjectSourceInspection.mapping(in: trimmed)
        }
    }

    private struct MappingNode {
        let key: String
        let value: String
        let line: Int
        let index: Int
        let indentation: Int
        let endIndex: Int
    }
}
