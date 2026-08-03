// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What the command palette can actually do.
//
// The command list is rebuilt from `AppModel` on every keystroke rather than cached:
// it is a few hundred structs holding closures, building it is far cheaper than the
// fuzzy ranking that follows, and a cache would be one more thing that can show a
// container which exited four seconds ago.

import AppKit
import Foundation
import MorbstackKit
import Observation
import SwiftUI

// MARK: - Activity

/// The palette's status line, used by the commands that outlive the keystroke that
/// started them — today that means `pull`, which streams progress for minutes.
///
/// `@MainActor` makes it implicitly `Sendable`, which is what lets `pull`'s progress
/// callback (invoked on the client's own thread) post into it.
@MainActor
@Observable
final class TrackDPaletteActivity {

    var status: String?
    var isBusy = false

    nonisolated func post(_ text: String, busy: Bool = true) {
        Task { @MainActor in
            self.status = text
            self.isBusy = busy
        }
    }

    nonisolated func finish(_ text: String?) {
        Task { @MainActor in
            self.status = text
            self.isBusy = false
        }
    }

    func clear() {
        status = nil
        isBusy = false
    }
}

// MARK: - Command

/// Everything a command needs to do its job.
struct PaletteContext {
    let model: AppModel
    let activity: TrackDPaletteActivity
    /// Closes the palette. Long-running commands deliberately do not call it, so their
    /// progress stays visible.
    let dismiss: () -> Void
}

/// One row in the palette.
struct PaletteCommand: Identifiable {

    /// The kind of thing this command acts on. It guides default ranking when the query
    /// is empty; results remain globally ranked instead of being visually badged.
    enum Kind: String {
        case container = "Container"
        case stack = "Stack"
        case image = "Image"
        case navigate = "Go to"
        case engine = "Engine"
        case general = "Morbstack"
    }

    let id: String
    /// The matched text. Keep it front-loaded with the distinguishing word — people
    /// type the container name, not the verb.
    let title: String
    var subtitle: String?
    var symbol: String
    var kind: Kind
    /// Extra text that participates in matching but is not highlighted, for the
    /// synonyms nobody should have to guess ("rm" for remove, "ps" for containers).
    var keywords: String = ""
    var isDestructive: Bool = false
    let run: @MainActor (PaletteContext) -> Void
}

// MARK: - Builder

@MainActor
enum PaletteCommandBuilder {

    /// Builds the full command list for the current state.
    ///
    /// `query` is passed in because one command depends on it: an image reference that
    /// is not on disk yet can only be offered as "pull this exact string".
    static func commands(model: AppModel, query: String) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        out += containerCommands(model)
        out += imageCommands(model)
        out += dynamicPullCommand(model, query: query)
        out += navigationCommands(model)
        out += engineCommands(model)
        out += generalCommands(model)
        return out
    }

    // MARK: Containers

    private static func containerCommands(_ model: AppModel) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        for container in model.containers {
            let name = container.displayName
            let origin = container.composeProject.map { "\($0) · " } ?? ""

            out.append(
                PaletteCommand(
                    id: "container.open.\(container.id)",
                    title: "Open \(name)",
                    subtitle: "\(origin)\(container.image)",
                    symbol: "shippingbox",
                    kind: .container,
                    keywords: "\(name) \(container.image) \(container.shortID) inspect show reveal"
                ) { context in
                    TrackDAppBridge.reveal(containerID: container.id, in: context.model)
                    context.dismiss()
                })

            out.append(
                PaletteCommand(
                    id: "container.logs.\(container.id)",
                    title: "View logs of \(name)",
                    subtitle: container.status,
                    symbol: "text.alignleft",
                    kind: .container,
                    keywords: "\(name) logs tail output stdout stderr"
                ) { context in
                    TrackDAppBridge.reveal(containerID: container.id, in: context.model, showingLogs: true)
                    context.dismiss()
                })

            // `remove` is deliberately absent: a destructive action one Return away from
            // a fuzzy match is how people delete the wrong database. It lives in the
            // container list, behind a confirmation.
            let lifecycle = container.availableActions.filter { $0 != .remove }
            for action in lifecycle {
                out.append(
                    PaletteCommand(
                        id: "container.\(action.rawValue).\(container.id)",
                        title: "\(action.title) \(name)",
                        subtitle: container.status,
                        symbol: action.symbol,
                        kind: .container,
                        keywords: "\(name) \(action.rawValue) \(container.shortID)"
                    ) { context in
                        context.activity.post("\(action.title) \(name)…")
                        Task { @MainActor in
                            await context.model.containerAction(action, id: container.id)
                            context.activity.finish(nil)
                        }
                        context.dismiss()
                    })
            }
        }
        return out
    }

    // MARK: Images

    private static func imageCommands(_ model: AppModel) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        for image in model.images {
            guard let reference = image.repoTags.first, !image.isDangling else { continue }
            let size = Formatters.bytesString(image.size)

            out.append(
                PaletteCommand(
                    id: "image.pull.\(image.id)",
                    title: "Pull \(reference)",
                    subtitle: "Update the local copy · \(size)",
                    symbol: "arrow.down.circle",
                    kind: .image,
                    keywords: "\(reference) pull update fetch download registry"
                ) { context in
                    pull(reference, context: context)
                })

            out.append(
                PaletteCommand(
                    id: "image.remove.\(image.id)",
                    title: "Remove \(reference)",
                    subtitle: image.containersUsing > 0
                        ? "In use by \(image.containersUsing) container\(image.containersUsing == 1 ? "" : "s")"
                        : "Frees \(size)",
                    symbol: "trash",
                    kind: .image,
                    keywords: "\(reference) remove delete rmi \(image.shortID)",
                    isDestructive: true
                ) { context in
                    context.activity.post("Removing \(reference)…")
                    Task { @MainActor in
                        do {
                            try await context.model.client.removeImage(id: image.id)
                            context.activity.finish("Removed \(reference)")
                            await context.model.refreshAll()
                        } catch {
                            context.activity.finish("Could not remove \(reference): \(MorbErrorMessage.text(for: error))")
                        }
                    }
                })
        }
        return out
    }

    /// "Pull `<whatever you typed>`", offered when the query looks like a reference the
    /// user could plausibly mean and no local image already carries that tag.
    private static func dynamicPullCommand(_ model: AppModel, query: String) -> [PaletteCommand] {
        let reference = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.count >= 3,
            !reference.contains(where: \.isWhitespace),
            reference.allSatisfy(isReferenceCharacter),
            !model.images.contains(where: { $0.repoTags.contains(reference) })
        else { return [] }

        return [
            PaletteCommand(
                id: "image.pull.literal",
                title: "Pull \(reference)",
                subtitle: "From the registry",
                symbol: "arrow.down.circle.dotted",
                kind: .image,
                keywords: "pull \(reference)"
            ) { context in
                pull(reference, context: context)
            }
        ]
    }

    private static func isReferenceCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "._-/:@".contains(character)
    }

    /// Starts a pull and keeps the palette open so its progress is visible.
    private static func pull(_ reference: String, context: PaletteContext) {
        context.activity.post("Pulling \(reference)…")
        let activity = context.activity
        let model = context.model
        Task { @MainActor in
            do {
                try await model.client.pull(ref: reference) { line in
                    activity.post(line)
                }
                activity.finish("Pulled \(reference)")
                await model.refreshAll()
            } catch {
                activity.finish("Pull failed: \(MorbErrorMessage.text(for: error))")
            }
        }
    }

    // MARK: Navigation

    private static func navigationCommands(_ model: AppModel) -> [PaletteCommand] {
        Nav.allCases.map { nav in
            PaletteCommand(
                id: "nav.\(nav.rawValue)",
                title: nav.title,
                subtitle: "⌘\(nav.shortcutIndex)",
                symbol: nav.symbol,
                kind: .navigate,
                keywords: "go to open section \(nav.rawValue)"
            ) { context in
                context.model.selection = nav
                TrackDAppBridge.revealMainWindow()
                context.dismiss()
            }
        }
    }

    // MARK: Engine

    private static func engineCommands(_ model: AppModel) -> [PaletteCommand] {
        var actions: [EngineAction] = []
        if model.engine.isRunning {
            actions = [.suspend, .stop]
        } else if model.engine.state == "suspended" {
            actions = [.start, .stop]
        } else {
            actions = [.start]
        }

        return actions.map { action in
            let (title, symbol, keywords): (String, String, String) = {
                switch action {
                case .start: return ("Start engine", "play.fill", "start boot up vm resume engine")
                case .stop: return ("Stop engine", "stop.fill", "stop shutdown halt vm engine")
                case .suspend: return ("Free engine memory", "moon.zzz.fill", "suspend pause sleep vm engine")
                }
            }()
            return PaletteCommand(
                id: "engine.\(action.rawValue)",
                title: title,
                subtitle: model.engine.headline,
                symbol: symbol,
                kind: .engine,
                keywords: keywords
            ) { context in
                context.activity.post("\(title)…")
                Task { @MainActor in
                    await context.model.engineAction(action)
                    context.activity.finish(nil)
                }
                context.dismiss()
            }
        }
    }

    // MARK: General

    private static func generalCommands(_ model: AppModel) -> [PaletteCommand] {
        let socket = MorbPaths.dockerSocket.path

        return [
            PaletteCommand(
                id: "general.context",
                title: "Copy docker context command",
                subtitle: "docker context create morbstack …",
                symbol: "terminal",
                kind: .general,
                keywords: "docker context cli terminal shell copy socket"
            ) { context in
                MorbPasteboard.copy(TrackDLinks.dockerContextCommand(socketPath: socket))
                context.activity.finish("Copied — paste it into a terminal")
                context.dismiss()
            },

            PaletteCommand(
                id: "general.dockerhost",
                title: "Copy DOCKER_HOST export",
                subtitle: "export DOCKER_HOST=unix://…",
                symbol: "text.badge.plus",
                kind: .general,
                keywords: "docker host env environment variable export shell copy"
            ) { context in
                MorbPasteboard.copy(TrackDLinks.dockerHostExport(socketPath: socket))
                context.activity.finish("Copied")
                context.dismiss()
            },

            PaletteCommand(
                id: "general.socket",
                title: "Copy engine socket path",
                subtitle: socket,
                symbol: "point.3.filled.connected.trianglepath.dotted",
                kind: .general,
                keywords: "socket path unix docker.sock copy"
            ) { context in
                MorbPasteboard.copy(socket)
                context.activity.finish("Copied")
                context.dismiss()
            },

            PaletteCommand(
                id: "general.refresh",
                title: "Refresh everything",
                subtitle: "Re-read containers, images, volumes and networks",
                symbol: "arrow.clockwise",
                kind: .general,
                keywords: "refresh reload update sync"
            ) { context in
                Task { @MainActor in await context.model.refreshAll() }
                context.dismiss()
            },

            PaletteCommand(
                id: "general.logs",
                title: "Open logs folder",
                subtitle: MorbPaths.logsDirectory.path,
                symbol: "folder",
                kind: .general,
                keywords: "logs folder finder daemon console troubleshoot"
            ) { context in
                NSWorkspace.shared.open(MorbPaths.logsDirectory)
                context.dismiss()
            },
        ]
    }
}
