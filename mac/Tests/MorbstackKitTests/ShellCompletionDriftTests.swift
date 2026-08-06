// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The guard for integrations/shell/. Those four files (`_morb`, `morb.bash`,
// `morb.fish`, `morb.1`) hand-declare `morb`'s command surface, and nothing used
// to check them against the CLI. They drifted by seven whole commands — `disk`,
// `ports`, `diagnose`, `service`, `install-cli`, `uninstall-cli`, `export` — and
// `debug`'s description promised "Open a toolbox shell in a container, even a
// distroless one" while the implementation says, in main.swift's own words, that
// it "does not open a shell yet". That is exactly what CLAUDE.md §1.8 forbids,
// and it shipped because a file nobody executes cannot fail.
//
// So: derive the truth from the parser, and fail the build on any disagreement.
//
// HOW THE TRUTH IS DERIVED, and why it is source text rather than a symbol.
//
// `morb` is an executable target built from top-level code in main.swift. There
// is no importable command table: the parser IS a `switch command { case "…": }`
// over string literals, and a test target cannot link a top-level-code
// executable to reach it. Running the built binary is not an option either —
// most of these commands boot a VM, delete a disk, or install into the user's
// home directory, and only `--help` is safe to invoke, which would make this
// test a check of the help text against itself.
//
// What is left is reading main.swift. That is a real coupling and it is stated
// here rather than hidden: these tests parse two things out of the file,
//
//   1. the dispatch labels — lines that begin `case "` at column zero, which is
//      unique to the top-level `switch command` (every nested switch in the file
//      is indented), and
//   2. the COMMANDS: block of the `usage` string literal,
//
// and they fail loudly, not vacuously, if either shape stops being found. Both
// are then compared against what each shell file declares. A command added to
// the parser without being added to the help text, to all three completions and
// to the man page cannot reach a green build.

import XCTest

final class ShellCompletionDriftTests: XCTestCase {

    // MARK: - The two views of the command surface, both from main.swift

    /// Every command the top-level dispatch switch accepts.
    private func parserCommands(_ source: String) throws -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        guard let switchIndex = lines.firstIndex(where: { $0 == "switch command {" }) else {
            throw Drift("`switch command {` is no longer at column zero in main.swift; this test can no longer see the parser's command table and must be rewritten, not deleted")
        }

        var commands: Set<String> = []
        var sawDefault = false
        for line in lines[switchIndex...] {
            if line == "default:" { sawDefault = true; break }
            guard line.hasPrefix("case \"") else { continue }
            // `case "start", "stop", "suspend", "resume":` -> four commands.
            for literal in quotedLiterals(in: line) { commands.insert(literal) }
        }
        guard sawDefault else {
            throw Drift("the top-level `switch command` in main.swift no longer ends in a column-zero `default:`; this test can no longer bound the parser's command table")
        }
        guard commands.count > 10 else {
            throw Drift("only \(commands.count) dispatch cases were found in main.swift, which cannot be right; the parsing in this test has stopped matching the source")
        }
        return commands
    }

    /// Every command `morb --help` lists, with the description it prints, parsed
    /// out of the COMMANDS: block of main.swift's `usage` literal.
    private func helpCommands(_ source: String) throws -> [String: String] {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "    COMMANDS:"),
              let end = lines[start...].firstIndex(of: "    SUBCOMMANDS:")
        else {
            throw Drift("could not find the `COMMANDS:` … `SUBCOMMANDS:` block in main.swift's usage text; this test can no longer read the help table")
        }

        var descriptions: [String: String] = [:]
        var pendingName: String?
        for line in lines[(start + 1)..<end] {
            let indent = line.prefix(while: { $0 == " " }).count
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }

            if indent == 6 {
                // `  status       Show daemon and VM state`, or a bare name whose
                // description is wrapped onto the next line.
                let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let name = String(parts[0])
                if parts.count == 2 {
                    descriptions[name] = parts[1].trimmingCharacters(in: .whitespaces)
                    pendingName = nil
                } else {
                    pendingName = name
                }
            } else if indent > 6, let name = pendingName {
                descriptions[name] = body
                pendingName = nil
            }
        }
        guard descriptions.count > 10 else {
            throw Drift("only \(descriptions.count) commands were parsed out of main.swift's COMMANDS: block, which cannot be right; the parsing in this test has stopped matching the source")
        }
        return descriptions
    }

    // MARK: - What each shell file declares

    /// The `commands=( 'name:description' … )` array at the top of `_morb`.
    private func zshCommands(_ source: String) throws -> [String: String] {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "    commands=("),
              let end = lines[start...].firstIndex(of: "    )")
        else {
            throw Drift("could not find the top-level `commands=(` array in _morb")
        }

        var declared: [String: String] = [:]
        for line in lines[(start + 1)..<end] {
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("#") { continue }
            guard body.hasPrefix("'"), body.hasSuffix("'"), body.count > 2 else {
                throw Drift("_morb's commands array has an entry this test cannot parse (expected a single-quoted 'name:description'): \(body)")
            }
            // zsh has no escape for ' inside '…'; the idiom is to close, emit an
            // escaped quote, and reopen: 'Morbstack'\''s'.
            let inner = String(body.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw Drift("_morb's commands array entry has no `name:description` colon: \(inner)")
            }
            declared[String(parts[0])] = String(parts[1])
        }
        return declared
    }

    /// The `local commands="…"` word list in `morb.bash`. Bash completion offers
    /// no descriptions, so only names are declared there.
    private func bashCommands(_ source: String) throws -> Set<String> {
        guard let line = source.components(separatedBy: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("local commands=\"")
        }) else {
            throw Drift("could not find the `local commands=\"…\"` list in morb.bash")
        }
        guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
            throw Drift("morb.bash's `local commands=` line is not a quoted word list: \(line)")
        }
        return Set(line[line.index(after: open)..<close].split(separator: " ").map(String.init))
    }

    /// The `complete -c morb -n __fish_use_subcommand -a NAME -d 'DESC'` lines.
    private func fishCommands(_ source: String) throws -> [String: String] {
        var declared: [String: String] = [:]
        for line in source.components(separatedBy: "\n") {
            guard line.hasPrefix("complete -c morb -n __fish_use_subcommand ") else { continue }
            guard let name = value(after: " -a ", in: line),
                  let description = singleQuoted(after: " -d ", in: line)
            else {
                throw Drift("could not parse a top-level fish completion line: \(line)")
            }
            declared[name] = description
        }
        guard !declared.isEmpty else {
            throw Drift("no `__fish_use_subcommand` completion lines were found in morb.fish")
        }
        return declared
    }

    /// The `.It Cm NAME` entries inside the man page's COMMANDS section. A
    /// command may have several entries (`.It Cm k8s Cm enable`); only the first
    /// `Cm` token is the top-level command.
    private func manPageCommands(_ source: String) throws -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: ".Sh COMMANDS"),
              let end = lines[start...].firstIndex(of: ".Sh OPTIONS")
        else {
            throw Drift("could not find the `.Sh COMMANDS` … `.Sh OPTIONS` range in morb.1")
        }
        var declared: Set<String> = []
        for line in lines[start..<end] where line.hasPrefix(".It Cm ") {
            let rest = line.dropFirst(".It Cm ".count).trimmingCharacters(in: .whitespaces)
            guard let first = rest.split(separator: " ").first else { continue }
            declared.insert(String(first))
        }
        guard !declared.isEmpty else {
            throw Drift("no `.It Cm` entries were found in morb.1's COMMANDS section")
        }
        return declared
    }

    // MARK: - The checks

    func testHelpTextListsExactlyTheCommandsTheParserDispatches() throws {
        let source = try mainSwift()
        let parser = try parserCommands(source)
        let help = try helpCommands(source)

        assertSameCommands(
            declared: Set(help.keys), expected: parser,
            declaredBy: "the COMMANDS: block of `morb --help`",
            fixHint: "add it to the `usage` literal in mac/Sources/morb/main.swift")
    }

    func testZshCompletionDeclaresTheRealCommandSurface() throws {
        let source = try mainSwift()
        let declared = try zshCommands(try file("integrations/shell/_morb"))

        assertSameCommands(
            declared: Set(declared.keys), expected: try parserCommands(source),
            declaredBy: "integrations/shell/_morb",
            fixHint: "add a 'name:description' entry to the `commands=(` array in integrations/shell/_morb")
        assertSameDescriptions(declared: declared, expected: try helpCommands(source), in: "integrations/shell/_morb")
    }

    func testBashCompletionDeclaresTheRealCommandSurface() throws {
        let declared = try bashCommands(try file("integrations/shell/morb.bash"))

        assertSameCommands(
            declared: declared, expected: try parserCommands(try mainSwift()),
            declaredBy: "integrations/shell/morb.bash",
            fixHint: "add it to the `local commands=\"…\"` word list in integrations/shell/morb.bash")
    }

    func testFishCompletionDeclaresTheRealCommandSurface() throws {
        let source = try mainSwift()
        let declared = try fishCommands(try file("integrations/shell/morb.fish"))

        assertSameCommands(
            declared: Set(declared.keys), expected: try parserCommands(source),
            declaredBy: "integrations/shell/morb.fish",
            fixHint: "add a `complete -c morb -n __fish_use_subcommand -a NAME -d 'DESC'` line to integrations/shell/morb.fish")
        assertSameDescriptions(declared: declared, expected: try helpCommands(source), in: "integrations/shell/morb.fish")
    }

    func testManPageDocumentsTheRealCommandSurface() throws {
        let declared = try manPageCommands(try file("integrations/shell/morb.1"))

        assertSameCommands(
            declared: declared, expected: try parserCommands(try mainSwift()),
            declaredBy: "integrations/shell/morb.1",
            fixHint: "add an `.It Cm NAME` entry to the COMMANDS section of integrations/shell/morb.1")
    }

    /// Completions can also drift by *inventing* a flag — offering `--recursive`
    /// for a parser that has never heard of it, which is worse than offering
    /// nothing because the shell makes it look supported. Every long option any
    /// of the three files offers must appear verbatim somewhere in the CLI's own
    /// sources.
    ///
    /// This is a containment check and only catches that direction: a flag the
    /// parser gained and the completions never learned about will not fail here.
    /// Nothing in the sources declares a per-command flag list a test could
    /// compare against, and inventing one would only move the drift.
    func testCompletionsDoNotOfferFlagsTheCLIDoesNotHave() throws {
        var cliSources = try mainSwift()
        for module in ["MorbMCP", "MorbMigrate", "MorbBench", "MorbScan", "MorbExport"] {
            let directory = repoRoot.appendingPathComponent("mac/Sources/\(module)")
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for name in contents where name.hasSuffix(".swift") {
                cliSources += try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            }
        }

        for path in ["integrations/shell/_morb", "integrations/shell/morb.bash", "integrations/shell/morb.fish"] {
            // Comment lines are prose — install instructions mention things like
            // `pkg-config --variable=completionsdir` that are nothing to do with
            // morb's own flags. Only what the shell actually offers is checked.
            let code = try file(path)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            for flag in longOptions(in: code).sorted() where !cliSources.contains(flag) {
                XCTFail(
                    "\(path) offers `\(flag)`, which appears nowhere in mac/Sources/morb or the feature modules "
                        + "it dispatches to. Either the flag was invented, or it was renamed in Swift and the "
                        + "completion was not updated.")
            }
        }
    }

    // MARK: - Assertions

    private func assertSameCommands(
        declared: Set<String>, expected: Set<String>, declaredBy: String, fixHint: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for missing in expected.subtracting(declared).sorted() {
            XCTFail(
                "`morb \(missing)` is dispatched by mac/Sources/morb/main.swift but \(declaredBy) does not "
                    + "declare it. Fix: \(fixHint).",
                file: file, line: line)
        }
        for extra in declared.subtracting(expected).sorted() {
            XCTFail(
                "\(declaredBy) declares `morb \(extra)`, which mac/Sources/morb/main.swift does not dispatch. "
                    + "Either the command was removed from the parser, or it was never there.",
                file: file, line: line)
        }
    }

    /// Descriptions are compared verbatim, and deliberately so. `debug`'s entry
    /// read "Open a toolbox shell in a container, even a distroless one" for
    /// months while `debug` opened nothing — a §1.8 violation living in a file
    /// no build step read. Byte equality with the help text is the only version
    /// of this check that would have caught it.
    private func assertSameDescriptions(
        declared: [String: String], expected: [String: String], in path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (name, description) in declared.sorted(by: { $0.key < $1.key }) {
            guard let want = expected[name] else { continue }  // reported by assertSameCommands
            XCTAssertEqual(
                description, want,
                "\(path) describes `morb \(name)` differently from `morb --help`.\n"
                    + "  completion: \(description)\n"
                    + "  main.swift: \(want)\n"
                    + "  These must match verbatim so a description can never promise behaviour the CLI does not have.",
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
            .deletingLastPathComponent()  // ShellCompletionDriftTests.swift -> MorbstackKitTests/
            .deletingLastPathComponent()  // MorbstackKitTests -> Tests/
            .deletingLastPathComponent()  // Tests -> mac/
            .deletingLastPathComponent()  // mac -> repo root
    }

    private func mainSwift() throws -> String {
        try file("mac/Sources/morb/main.swift")
    }

    private func file(_ path: String) throws -> String {
        let url = repoRoot.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Not an XCTSkip: `mac/Sources/morb/main.swift` and the four files in
            // integrations/shell are all tracked in git and always present in a
            // checkout. If one cannot be read, it was deleted or renamed, and
            // skipping would let exactly the drift this test exists to catch
            // through as a green run.
            throw Drift("\(path) could not be read; this test's whole purpose is comparing against it")
        }
        return text
    }

    /// Every `"…"` on one line of Swift source. Only used on `case` labels, which
    /// hold plain identifiers with no escapes or interpolation.
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

    /// Long options as a shell file writes them: `--json`, `-l json` in fish is
    /// handled by the caller's own parsing and deliberately not included here,
    /// because fish's `-l name` form spells the flag without its dashes.
    private func longOptions(in text: String) -> Set<String> {
        var found: Set<String> = []
        var index = text.startIndex
        while let range = text.range(of: "--", range: index..<text.endIndex) {
            var end = range.upperBound
            while end < text.endIndex, text[end].isLowercase || text[end].isNumber || text[end] == "-" {
                end = text.index(after: end)
            }
            let candidate = String(text[range.lowerBound..<end])
            // `--` alone, or a trailing dash from prose like "read-only --".
            if candidate.count > 2, !candidate.hasSuffix("-") { found.insert(candidate) }
            index = end == range.upperBound ? text.index(after: range.upperBound) : end
        }
        return found
    }

    private func value(after token: String, in line: String) -> String? {
        guard let range = line.range(of: token) else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }

    /// A `'…'` argument, honouring fish's `\'` escape inside single quotes.
    private func singleQuoted(after token: String, in line: String) -> String? {
        guard let range = line.range(of: token + "'") else { return nil }
        var result = ""
        var index = range.upperBound
        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                let next = line.index(after: index)
                guard next < line.endIndex else { return nil }
                result.append(line[next])
                index = line.index(after: next)
                continue
            }
            if character == "'" { return result }
            result.append(character)
            index = line.index(after: index)
        }
        return nil
    }
}
