// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deliberately non-evaluating view of one explicitly selected Compose source file.
// This is not a Compose parser and never determines an effective environment. It
// reports only local source declarations that can be recognized without interpolation,
// includes, environment precedence, credentials, or file access beyond the selected
// document the editor already opened.

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

    struct SecretDeclaration: Identifiable, Equatable {
        let name: String
        let line: Int

        var id: String { "\(line):\(name)" }
    }

    let environmentDeclarations: [EnvironmentDeclaration]
    let secretDeclarations: [SecretDeclaration]

    static func inspect(text: String, sourceKind: ComposeProjectSourceKind) -> Self {
        switch sourceKind {
        case .projectEnvironment:
            Self(
                environmentDeclarations: environmentDeclarations(in: text),
                secretDeclarations: [])
        case .composeYAML:
            Self(
                environmentDeclarations: [],
                secretDeclarations: topLevelSecretDeclarations(in: text))
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

    /// Finds only a conventional block-style, top-level `secrets:` mapping. It avoids
    /// treating inner `file:`, `external:`, or service references as declarations and
    /// intentionally leaves inline or otherwise complex YAML to the source editor.
    private static func topLevelSecretDeclarations(in text: String) -> [SecretDeclaration] {
        var inTopLevelSecrets = false
        var declarationIndent: Int?
        var declarations: [SecretDeclaration] = []

        for (offset, sourceLine) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let indentation = sourceLine.prefix { $0 == " " || $0 == "\t" }.count
            if indentation == 0 {
                inTopLevelSecrets = trimmed == "secrets:"
                declarationIndent = nil
                continue
            }
            guard inTopLevelSecrets else { continue }

            if declarationIndent == nil {
                declarationIndent = indentation
            }
            guard indentation == declarationIndent,
                  let name = yamlMappingKey(in: trimmed)
            else { continue }
            declarations.append(SecretDeclaration(name: name, line: offset + 1))
        }
        return declarations
    }

    private static func yamlMappingKey(in line: String) -> String? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              !key.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
        else { return nil }
        return key
    }

    private static func isEnvironmentName(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
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
}
