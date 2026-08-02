// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The "here is exactly what you are about to delete" sheet.
//
// Shared by the Disk screen's four prune buttons and the Volumes/Networks screens'
// "Remove Unused". A prune is irreversible, silent, and reported only as a byte count
// afterwards — the one moment a user can still change their mind is before it runs, and
// that moment deserves an itemised list rather than a yes/no alert.

import SwiftUI

struct TrackCConfirmSheet: View {

    let title: String
    let symbol: String
    /// One or two sentences on what the operation removes, in plain language.
    let explanation: String
    /// Everything that will be deleted.
    let items: [TrackCPruneItem]
    /// Near-misses that are deliberately spared, with the reason in each `detail`.
    var kept: [TrackCPruneItem] = []
    /// Bytes we can account for. A floor when `hasUnknownSizes`.
    let knownBytes: Int64
    /// `true` when at least one item's size was not reported.
    let hasUnknownSizes: Bool
    var confirmTitle: String = "Remove"
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var estimateLabel: String {
        if items.isEmpty { return "Nothing to remove" }
        if knownBytes == 0 && hasUnknownSizes { return "Reclaimed space not reported in advance" }
        return hasUnknownSizes
            ? "Frees at least \(Formatters.bytesString(knownBytes))"
            : "Frees \(Formatters.bytesString(knownBytes))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .frame(width: 460)
        .frame(minHeight: 260, idealHeight: 380, maxHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.space4) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.brand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Theme.space2) {
                Text(title)
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.pagePadding)
    }

    @ViewBuilder
    private var body_: some View {
        if items.isEmpty && kept.isEmpty {
            MorbEmptyState("Already clean", systemImage: "sparkles")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in row(item, spared: false) }
                    } header: {
                        sectionHeader("Will be removed", count: items.count, tone: .bad)
                    }
                }
                if !kept.isEmpty {
                    Section {
                        ForEach(kept) { item in row(item, spared: true) }
                    } header: {
                        sectionHeader("Kept", count: kept.count, tone: .running)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .environment(\.defaultMinListRowHeight, Theme.rowStandard - Theme.space2)
        }
    }

    private func sectionHeader(_ text: String, count: Int, tone: StatusTone) -> some View {
        HStack(spacing: Theme.space2) {
            Text(text).font(.caption.weight(.semibold))
            MorbChip("\(count)", rank: .status(tone), monospaced: true)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private func row(_ item: TrackCPruneItem, spared: Bool) -> some View {
        HStack(spacing: Theme.space3) {
            Image(systemName: spared ? "lock.fill" : "minus.circle")
                .font(.system(size: 10))
                .foregroundStyle(spared ? AnyShapeStyle(Theme.statusRunning) : AnyShapeStyle(.tertiary))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text(item.title)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.space3)
            Text(item.bytes.map(Formatters.bytesString) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(item.bytes == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        }
        .opacity(spared ? 0.75 : 1)
        .padding(.vertical, Theme.space1)
    }

    private var footer: some View {
        HStack(spacing: Theme.space4) {
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text(estimateLabel)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if hasUnknownSizes && !items.isEmpty {
                    Text("The engine does not report every size up front.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.space4)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, role: .destructive) {
                dismiss()
                onConfirm()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(items.isEmpty)
        }
        .padding(Theme.pagePadding)
    }
}
