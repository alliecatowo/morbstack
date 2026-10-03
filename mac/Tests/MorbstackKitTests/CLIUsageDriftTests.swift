// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The guard for `morb`'s five feature-module usage strings
// (mac/Sources/Morb{Migrate,MCP,Bench,Scan,Export}/*.swift). Each module hand-writes
// a `usage`/`printUsage()` string literal describing its own `--flag` surface, and
// nothing checked it against what the module's own argument parser actually accepts.
//
// `MigrateCLI` is the clearest case: its four `validate(commandArguments, flags:
// [...], options: [...])` call sites already declare that surface as real Swift
// data — a `Set<String>` literal, right next to a `usage` literal that repeats the
// same information by hand, with nothing keeping the two in step. The other four
// modules parse arguments ad hoc (a `switch`/`case "--flag":`, or an `== "--flag"`
// comparison) rather than through a shared `validate` helper, but the same
// asymmetry exists: the parser's own quoted string literals are real data; the
// usage text is prose that merely claims to describe them.
//
// This mirrors `ShellCompletionDriftTests`' approach, and for the same reason:
// these are internal `enum` command routers inside library targets, so there is a
// real parser to compare against, but no test-visible symbol to import it as (the
// `flags:`/`options:` arguments and the `case` literals are local to a function
// body, not a declaration a test target could read via reflection). What is left,
// same as that file, is reading the source text a person reads. Both sides are
// parsed out of the same file mechanically, and a shape the parser stops using
// fails loudly — not vacuously — rather than silently reporting zero drift.
//
// HOW EACH MODULE'S TWO SIDES ARE DERIVED
//
//   MorbMigrate  parser: the bare names inside `flags: [...]` / `options: [...]`
//                array literals in MigrateCLI.swift.
//                usage:  the `--flag` tokens under the "Image options:", "Plan
//                options:", "Volume options:", "Verify options:" headings of its
//                usage text. (`run`'s own flags live in RunImagesCommand.swift's
//                separate parser and are deliberately out of scope here, the same
//                way "Run options (images only):" is deliberately excluded below.)
//
//   MorbMCP, MorbBench, MorbExport
//                parser: every quoted string literal in the module's source whose
//                *entire* content is `--flag` (optionally `--flag=`) — e.g. `case
//                "--dry-run":` or `argument.hasPrefix("--allow=")`. This
//                deliberately excludes longer strings that merely mention a flag in
//                prose, like `"--check was passed more than once"`, because the
//                regex requires the closing quote to follow the flag immediately.
//                usage:  the `--flag` tokens anywhere in the module's whole `usage`/
//                `text` triple-quoted literal (verified flag-clean outside its
//                Options list for these three modules).
//
//   MorbScan     parser: same literal-scan as above.
//                usage:  restricted to the "Options:" section of its usage text,
//                because the closing paragraph separately mentions the *global*
//                `--json` flag (`main.swift`'s, not `ScanCLI`'s own), which the
//                whole-literal scan used for the other three would wrongly treat as
//                an undeclared ScanCLI flag.
//
// `help`/`--help`/`-h` is excluded from every parser-side set: it is the universal
// subcommand alias every module accepts, never documented as a `--flag` in an
// Options list, so keeping it would fail every module permanently rather than
// catch real drift.

import XCTest

final class CLIUsageDriftTests: XCTestCase {

    // MARK: - MorbMigrate

    func testMigrateUsageMatchesValidatedFlags() throws {
        let path = "mac/Sources/MorbMigrate/MigrateCLI.swift"
        let source = try file(path)

        let declared = try migrateValidatedFlags(source, file: path)

        var usage: Set<String> = []
        for header in ["Image options:", "Plan options:", "Volume options:", "Verify options:"] {
            usage.formUnion(try flagsInUsageSection(source, header: header, file: path))
        }

        assertSameFlags(
            declaredByParser: declared, declaredByUsage: usage, module: "morb migrate",
            parserLocation: "\(path)'s `validate(flags:, options:)` calls",
            usageLocation: "\(path)'s Image/Plan/Volume/Verify options sections")
    }

    // MARK: - MorbMCP

    func testMCPUsageMatchesParsedFlags() throws {
        let cliPath = "mac/Sources/MorbMCP/MCPCLI.swift"
        let permissionsPath = "mac/Sources/MorbMCP/Permissions.swift"
        let cli = try file(cliPath)
        let permissions = try file(permissionsPath)

        var declared = parserLongOptionLiterals(in: cli)
        declared.formUnion(parserLongOptionLiterals(in: permissions))
        declared.remove("help")

        let usageText = try tripleQuotedLiteral(
            in: cli, markerLine: "private static let usage = \"\"\"", file: cliPath)
        let usage = longOptionNames(in: usageText)

        assertSameFlags(
            declaredByParser: declared, declaredByUsage: usage, module: "morb mcp",
            parserLocation: "\(cliPath) and \(permissionsPath)'s argument parsing",
            usageLocation: "\(cliPath)'s `usage` literal")
    }

    // MARK: - MorbBench

    func testBenchUsageMatchesParsedFlags() throws {
        let path = "mac/Sources/MorbBench/BenchCLI.swift"
        let source = try file(path)

        var declared = parserLongOptionLiterals(in: source)
        declared.remove("help")

        let usageText = try tripleQuotedLiteral(in: source, markerLine: "let usage = \"\"\"", file: path)
        let usage = longOptionNames(in: usageText)

        assertSameFlags(
            declaredByParser: declared, declaredByUsage: usage, module: "morb bench",
            parserLocation: "\(path)'s `case`/comparison flag parsing",
            usageLocation: "\(path)'s `usage` literal")
    }

    // MARK: - MorbScan

    func testScanUsageMatchesParsedFlags() throws {
        let path = "mac/Sources/MorbScan/ScanCLI.swift"
        let source = try file(path)

        var declared = parserLongOptionLiterals(in: source)
        declared.remove("help")

        let usage = try flagsInUsageSection(source, header: "Options:", file: path)

        assertSameFlags(
            declaredByParser: declared, declaredByUsage: usage, module: "morb scan",
            parserLocation: "\(path)'s `case` flag parsing",
            usageLocation: "\(path)'s `Options:` section")
    }

    // MARK: - MorbExport

    func testExportUsageMatchesParsedFlags() throws {
        let path = "mac/Sources/MorbExport/ExportCLI.swift"
        let source = try file(path)

        var declared = parserLongOptionLiterals(in: source)
        declared.remove("help")

        let usageText = try tripleQuotedLiteral(in: source, markerLine: "let text = \"\"\"", file: path)
        let usage = longOptionNames(in: usageText)

        assertSameFlags(
            declaredByParser: declared, declaredByUsage: usage, module: "morb export",
            parserLocation: "\(path)'s `case` flag parsing",
            usageLocation: "\(path)'s usage text")
    }

    // MARK: - MorbMigrate-specific extraction

    /// Every bare flag name inside a `flags: [...]` or `options: [...]` array
    /// literal anywhere in `source` — e.g. `flags: ["all", "dry-run", "yes"]`
    /// contributes `all`, `dry-run`, `yes`.
    private func migrateValidatedFlags(_ source: String, file: String) throws -> Set<String> {
        var found: Set<String> = []
        var sawAny = false
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("flags: [") || trimmed.hasPrefix("options: [") else { continue }
            sawAny = true
            for literal in quotedLiterals(in: trimmed) { found.insert(literal) }
        }
        guard sawAny else {
            throw Drift(
                "no `flags: [...]` / `options: [...]` array literal was found in \(file); "
                    + "this test can no longer see the parser's declared flag data and must be rewritten, not deleted")
        }
        guard found.count > 3 else {
            throw Drift(
                "only \(found.count) flag(s) were parsed out of \(file)'s validate() calls, which cannot be right; "
                    + "the parsing in this test has stopped matching the source")
        }
        return found
    }

    // MARK: - Shared extraction for the ad hoc parsers

    /// Every quoted string literal in `source` whose *entire* content is a long
    /// option — `--flag` or `--flag=` (the latter from a `hasPrefix("--flag=")`
    /// check) — with the leading `--` and any trailing `=` stripped. Requiring the
    /// closing quote to follow immediately is what keeps this from matching a
    /// longer message that merely mentions a flag, like `"--check was passed more
    /// than once"`: Swift string literals cannot contain an unescaped `"`, so the
    /// pattern only matches when the flag *is* the whole literal.
    private func parserLongOptionLiterals(in source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #""(--[A-Za-z][A-Za-z0-9-]*=?)""#) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: Set<String> = []
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let group = Range(match.range(at: 1), in: source) else { return }
            var name = String(source[group]).dropFirst(2)  // strip "--"
            if name.hasSuffix("=") { name = name.dropLast() }
            found.insert(String(name))
        }
        return found
    }

    /// Every `--flag` token appearing anywhere in a line of prose (not a Swift
    /// string literal — usage text is a single triple-quoted block), with the
    /// leading `--` stripped.
    private func longOptionNames(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"--[a-z][a-z0-9-]*"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: Set<String> = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let group = Range(match.range, in: text) else { return }
            found.insert(String(text[group].dropFirst(2)))
        }
        return found
    }

    /// The `--flag` tokens between a `header` line (matched exactly after
    /// trimming) and the next blank line.
    private func flagsInUsageSection(_ source: String, header: String, file: String) throws -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            throw Drift("could not find a `\(header)` heading in \(file)'s usage text")
        }
        var flags: Set<String> = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            flags.formUnion(longOptionNames(in: line))
        }
        guard !flags.isEmpty else {
            throw Drift("no `--flag` tokens were found under \(file)'s `\(header)` heading")
        }
        return flags
    }

    /// The text of a triple-quoted Swift string literal, given the exact trimmed
    /// content of the line that opens it (e.g. `let usage = """`). Used instead of
    /// a name-based lookup because more than one triple-quoted literal can exist in
    /// the same file (MCPCLI.swift also has `profileTemplate`), so the declaration
    /// itself is the only unambiguous anchor.
    private func tripleQuotedLiteral(in source: String, markerLine: String, file: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == markerLine }) else {
            throw Drift("could not find the line `\(markerLine)` in \(file); this test can no longer locate its usage literal")
        }
        guard let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"\"\"" }) else {
            throw Drift("could not find the closing `\"\"\"` for \(file)'s usage literal opened at `\(markerLine)`")
        }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    // MARK: - Assertion

    private func assertSameFlags(
        declaredByParser: Set<String>, declaredByUsage: Set<String>, module: String,
        parserLocation: String, usageLocation: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for missing in declaredByParser.subtracting(declaredByUsage).sorted() {
            XCTFail(
                "`\(module) --\(missing)` is accepted by \(parserLocation) but is not documented in "
                    + "\(usageLocation). Add it there, or remove it from the parser if it should not exist.",
                file: file, line: line)
        }
        for extra in declaredByUsage.subtracting(declaredByParser).sorted() {
            XCTFail(
                "\(usageLocation) documents `\(module) --\(extra)`, which \(parserLocation) does not accept. "
                    + "Either the flag was removed from the parser, or it was never implemented — "
                    + "CLAUDE.md §1.8 forbids documenting behaviour the implementation does not have.",
                file: file, line: line)
        }
    }

    // MARK: - Plumbing

    private struct Drift: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIUsageDriftTests.swift -> MorbstackKitTests/
            .deletingLastPathComponent()  // MorbstackKitTests -> Tests/
            .deletingLastPathComponent()  // Tests -> mac/
            .deletingLastPathComponent()  // mac -> repo root
    }

    private func file(_ path: String) throws -> String {
        let url = repoRoot.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Every path this test reads is tracked in git and always present in a
            // checkout. If one cannot be read, it was deleted or renamed, and
            // skipping would let exactly the drift this test exists to catch
            // through as a green run.
            throw Drift("\(path) could not be read; this test's whole purpose is comparing against it")
        }
        return text
    }

    /// Every `"…"` on one line of Swift source. Used only on `flags: [...]` /
    /// `options: [...]` lines, which hold plain quoted identifiers with no escapes
    /// or interpolation.
    private func quotedLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        for character in line {
            if character == "\"" {
                if let value = current { literals.append(value); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(character)
            }
        }
        return literals
    }
}
