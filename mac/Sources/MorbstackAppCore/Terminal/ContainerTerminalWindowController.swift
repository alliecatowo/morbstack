// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// One terminal window per interactive exec session.
//
// A programmatic window controller rather than a SwiftUI scene on purpose: a terminal
// session dies with its socket, so the window must never be state-restored into a
// shell that no longer exists. `isRestorable = false` and a controller whose lifetime
// is the session's are the whole restoration story.
//
// Content, not chrome (DECISIONS.md §3): the window is a plain titled/closable/
// resizable/miniaturizable system window with no material, no glass, no custom chrome.
// Its content is the terminal surface's own background, edge to edge, plus — only
// while connecting, or once the session has nothing left to say — a plainly readable
// status message painted on that same background.

import AppKit

/// Opens and owns the terminal windows. `open(for:client:)` is the single entry point
/// the containers route calls; everything else here is this controller managing one
/// window's whole lifetime, from "Connecting…" through a live shell to teardown.
final class ContainerTerminalWindowController: NSWindowController, NSWindowDelegate {

    /// Opens a new terminal window for one running container. Every call opens its own
    /// window: several simultaneous shells into one container are legitimate. The
    /// static set is the only thing keeping the controller (and therefore the window
    /// and the session) alive — `windowWillClose` releases it.
    static func open(for container: ContainerSummary, client: DockerClient) {
        let controller = ContainerTerminalWindowController(container: container, client: client)
        activeControllers.insert(controller)
        controller.begin()
    }

    private static var activeControllers: Set<ContainerTerminalWindowController> = []
    private static let defaultContentSize = NSSize(width: 720, height: 420)

    private let container: ContainerSummary
    private let client: DockerClient

    private var emulator: TerminalEmulator?
    private var session: DockerExecPTYSession?
    private var contentView: TerminalWindowContentView?
    private var resolveTask: Task<Void, Never>?

    /// The window title before any OSC 0/2 program title is appended to it —
    /// "<name> — Terminal" while connecting, "<name> — <shell>" once resolved.
    private var baseTitle: String
    private var programTitle: String?

    private init(container: ContainerSummary, client: DockerClient) {
        self.container = container
        self.client = client
        baseTitle = "\(container.displayName) — Terminal"
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ContainerTerminalWindowController is constructed programmatically only.")
    }

    // MARK: Window setup

    private func begin() {
        let cellSize = TerminalSurfaceNSView.measuredCellSize()
        let inset = TerminalSurfaceNSView.contentInset

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = baseTitle
        window.delegate = self
        // Size memory only — a dead session must never be resurrected into, so the
        // window itself is not restorable.
        window.setFrameAutosaveName("MorbContainerTerminal")
        window.isRestorable = false
        window.minSize = NSSize(
            width: 20 * cellSize.width + inset * 2,
            height: 5 * cellSize.height + inset * 2)
        self.window = window

        showConnecting()
        window.makeKeyAndOrderFront(nil)

        resolveTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await TerminalShellResolution.resolve(client: self.client, containerID: self.container.id)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .found(let shell):
                self.presentTerminal(shell: shell)
            case .noShell(let probed):
                self.presentNoShell(probed: probed)
            case .failed(let message):
                self.presentFailed(message: message)
            }
        }
    }

    // MARK: Connecting / error presentations

    private func showConnecting() {
        let message = Self.messageView(
            text: "Connecting to \(container.displayName)…",
            textColor: .secondaryLabelColor,
            selectable: false)
        window?.contentView = message
    }

    private func presentNoShell(probed: [String]) {
        _ = probed // Named in the copy generically; the specific candidates aren't user-facing.
        let text = """
            This container has neither /bin/bash nor /bin/sh, so there is no shell to attach.
            Its image likely ships no tools at all — a distroless build. A debug toolbox that \
            brings its own shell is planned on top of this terminal (see morb debug); it does \
            not exist yet.
            """
        presentUnattachable(text: text)
    }

    private func presentFailed(message: String) {
        var text = message
        if !container.isRunning {
            text += "\nThe container must be running to open a terminal."
        }
        presentUnattachable(text: text)
    }

    private func presentUnattachable(text: String) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let messageField = Self.messageView(text: text, textColor: .labelColor, selectable: true)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeButtonPressed))
        closeButton.setAccessibilityIdentifier("containers.terminal.close")
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        messageField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(messageField)
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            messageField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageField.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -16),
            messageField.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            messageField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            closeButton.topAnchor.constraint(equalTo: messageField.bottomAnchor, constant: 16),
            closeButton.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])

        window?.contentView = container
    }

    private static func messageView(text: String, textColor: NSColor, selectable: Bool) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = textColor
        field.alignment = .center
        field.isSelectable = selectable
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.preferredMaxLayoutWidth = 420
        return field
    }

    @objc private func closeButtonPressed() {
        window?.close()
    }

    // MARK: Live terminal

    private func presentTerminal(shell: String) {
        baseTitle = "\(container.displayName) — \(shell)"
        updateWindowTitle()

        let contentSize = window?.contentView?.bounds.size ?? Self.defaultContentSize
        let cellSize = TerminalSurfaceNSView.measuredCellSize()
        let grid = terminalGridSize(viewSize: contentSize, cellSize: cellSize, contentInset: TerminalSurfaceNSView.contentInset)

        let emulator = TerminalEmulator(columns: grid.columns, rows: grid.rows, scrollbackLimit: 10_000)
        self.emulator = emulator

        let surface = TerminalSurfaceNSView(emulator: emulator)
        surface.setAccessibilityLabel("Terminal for \(container.displayName)")

        let content = TerminalWindowContentView(surfaceView: surface)
        self.contentView = content
        window?.contentView = content
        window?.makeFirstResponder(surface)

        let session = DockerExecPTYSession(
            client: client,
            options: DockerExecPTYSession.Options(
                containerID: container.id,
                command: [shell],
                tty: true,
                initialColumns: grid.columns,
                initialRows: grid.rows))
        self.session = session

        // The emulator's own replies (DA/DSR/CPR) have to go straight back down the
        // same pipe the keyboard uses, or programs that wait on them — vim chief among
        // them — hang forever.
        emulator.onOutput = { [weak session] data in session?.send(data) }
        emulator.onBell = { [weak surface] in surface?.bell() }

        session.onOutput = { [weak self, weak emulator, weak surface] data in
            emulator?.feed(data)
            self?.applyProgramTitleIfChanged()
            surface?.refresh()
        }
        session.onStarted = { [weak self] in self?.clearConnectingStatus() }
        session.onTermination = { [weak self] reason in self?.tearDown(reason: reason) }

        surface.onInput = { [weak session] data in session?.send(data) }
        surface.onViewportSizeChange = { [weak emulator, weak session] columns, rows in
            emulator?.resize(columns: columns, rows: rows)
            session?.resize(columns: columns, rows: rows)
        }

        session.start()
    }

    /// There is no explicit "connected" signal to show; the status view is simply the
    /// terminal surface replacing the "Connecting…" placeholder, which already
    /// happened in `presentTerminal`. `onStarted` exists for exactly the reverse case —
    /// clearing any status this controller shows above the surface — but v1 has none
    /// to clear, so this is a no-op kept for the wiring's symmetry with `tearDown`.
    private func clearConnectingStatus() {}

    private func applyProgramTitleIfChanged() {
        guard let emulator, emulator.title != programTitle else { return }
        programTitle = emulator.title
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        if let programTitle, !programTitle.isEmpty {
            window?.title = "\(baseTitle) — \(programTitle)"
        } else {
            window?.title = baseTitle
        }
    }

    // MARK: Teardown

    private func tearDown(reason: DockerExecPTYSession.TerminationReason) {
        contentView?.surfaceView.onInput = nil

        let statusText: String?
        switch reason {
        case .exited(let code):
            switch code {
            case .some(0): statusText = "The shell exited."
            case .some(let status): statusText = "The shell exited with status \(status)."
            case .none: statusText = "The session ended; Docker did not report an exit status."
            }
        case .containerStopped:
            statusText = "The container stopped, which ended this session."
        case .transportFailure(let message):
            statusText = message
        case .closedByUser:
            // The window is already going away; nothing to show.
            statusText = nil
        }

        if let statusText {
            contentView?.showStatusBar(text: statusText)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        resolveTask?.cancel()
        session?.close()
        Self.activeControllers.remove(self)
    }
}

/// The live-session window content: the terminal surface, plus — once the session has
/// ended — a thin status bar pinned to the bottom, on the terminal's own background.
private final class TerminalWindowContentView: NSView {

    let surfaceView: TerminalSurfaceNSView
    private var statusField: NSTextField?

    private static let statusBarHeight: CGFloat = 22

    init(surfaceView: TerminalSurfaceNSView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        addSubview(surfaceView)
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalWindowContentView is constructed programmatically only.")
    }

    func showStatusBar(text: String) {
        if let statusField {
            statusField.stringValue = text
        } else {
            let field = NSTextField(labelWithString: text)
            field.textColor = .secondaryLabelColor
            field.font = .systemFont(ofSize: 11)
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.isBezeled = false
            field.setAccessibilityIdentifier("containers.terminal.status")
            addSubview(field)
            statusField = field
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let barHeight = statusField == nil ? 0 : Self.statusBarHeight
        surfaceView.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight)
        statusField?.frame = NSRect(x: 8, y: 0, width: bounds.width - 16, height: barHeight)
    }
}
