// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The two sections that exist in the sidebar before they exist in the product.
//
// They are in the sidebar deliberately: Builds and Kubernetes are the two things people
// come to a Docker Desktop replacement expecting, and finding out on day three that
// neither is there is worse than being told on day one. So the copy states the
// milestone and stops — no marketing verbs, no "coming soon!", no fake screenshot.

import AppKit
import SwiftUI

struct PlaceholderView: View {

    let nav: Nav

    @State private var copied = false

    var body: some View {
        TrackDEmptyState(symbol: nav.symbol, title: nav.title, message: copy) {
            VStack(spacing: 12) {
                TrackDBadge(text: milestone, symbol: "signpost.right", tone: .accent)
                roadmapAffordance
            }
        }
    }

    // MARK: Copy

    /// One honest sentence per section. If a line here stops being true, the feature
    /// shipped and this file should have lost a case.
    private var copy: String {
        switch nav {
        case .builds:
            return "BuildKit history lands in M2."
        case .kubernetes:
            return "k3s one-toggle Kubernetes lands in M2."
        default:
            return "\(nav.title) is not part of this build yet."
        }
    }

    private var milestone: String {
        switch nav {
        case .builds, .kubernetes: return "Milestone M2"
        default: return "Not scheduled"
        }
    }

    // MARK: Roadmap

    /// A button when this build can find the roadmap, and the path when it cannot.
    ///
    /// Morbstack has no published docs site yet, so there is no URL to link to that is
    /// guaranteed to resolve — and a button that opens a 404 is worse than no button.
    @ViewBuilder
    private var roadmapAffordance: some View {
        if let file = TrackDLinks.roadmapFile() {
            Button {
                NSWorkspace.shared.open(file)
            } label: {
                Label("Read the roadmap", systemImage: "map")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        } else {
            Button {
                trackDCopy("docs/roadmap.md")
                copied = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .contentTransition(.symbolEffect(.replace))
                    Text("docs/roadmap.md")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Copy the path to the roadmap in the Morbstack repository")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
    }
}
