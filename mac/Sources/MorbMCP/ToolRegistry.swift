// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Assembles the read-only and mutating tool sets into the one registry
// Server.swift and MCPCLI.swift both consult: `tools/list`/`tools/call` need it
// to dispatch by name, `morb mcp permissions` needs it to enumerate every tool
// and guard a profile can mention, and `morb mcp init` needs it to write a
// template that actually lists what exists.

import Foundation

enum ToolRegistry {
    /// Every tool, read-only first (the order `tools/list` and `permissions`
    /// present them in, since that is the order a new user should read them).
    static let all: [ToolSpec] = ReadOnlyTools.all + MutatingTools.all

    static let byName: [String: ToolSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static func tool(named name: String) -> ToolSpec? { byName[name] }

    static var permissionSubjects: [PermissionSubject] { all.map(\.permissionSubject) }

    static var knownKeys: Set<String> { knownPermissionKeys(subjects: permissionSubjects) }
}
