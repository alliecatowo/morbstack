// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The single source of truth the whole UI reads from.
//
// The design goal is that the window is *live*: a container you start in a terminal
// turns green here before you have finished switching apps, and nothing in the app
// polls to make that happen. That comes from `/events`, and it costs one idle socket.
//
// Each event does two things:
//
//   1. **Patches the one row it is about, immediately.** `container die` flips that
//      container to `exited` on the spot. No round trip, so the dot changes in the same
//      frame the event arrived in.
//   2. **Arms a debounced full refresh.** The optimistic patch is a guess — a good one,
//      but it does not know the new status prose, the exit code, or that the container
//      also lost its published ports. 500 ms later one `refreshAll` reconciles
//      everything against the engine. `docker compose up` on a ten-service stack fires
//      forty events in two seconds and still costs exactly one refresh.
//
// The one place that genuinely does poll is the engine's own state while it is *not*
// running: a stopped daemon has no event stream to subscribe to, and there is no push
// channel for "the VM finished booting". That loop runs only in the states where it is
// the only option, and stops the moment `/events` can take over.

import Foundation
import MorbstackKit
import Observation
import SwiftUI

// MARK: - Launch options

/// Developer fixture, route, appearance, and window-size switches parsed from
/// `CommandLine`. They make manual Computer Use review and future UI automation
/// repeatable without exposing fake visual evidence from an offscreen renderer.
struct LaunchOptions: Sendable, Equatable {

    /// `--tour-select <nav>` — the sidebar item to select at launch.
    var select: Nav?
    /// `--tour-container <name>` — a container to open in the detail pane once the
    /// first refresh has landed.
    var container: String?
    /// `--appearance dark|light` — forces an appearance regardless of the system's.
    var appearance: ColorScheme?
    /// `--window-size WxH` — the exact content size for the main window.
    var windowSize: CGSize?
    /// `--tour-dump-window` — print the app's window list two seconds after launch and
    /// exit.
    ///
    /// The only way to answer "did the app actually get a window?" from a script without
    /// a screen recording or an accessibility client. See ``MorbWindowDump``.
    var dumpWindow = false
    /// `--tour-dump-file <path>` — where to write that report, in addition to stdout.
    ///
    /// `open -n Morbstack.app --args …` is how the app is launched for real, and it
    /// discards the child's stdout, so a run started that way needs somewhere on disk to
    /// leave its evidence. `MORB_TOUR_DUMP_FILE` does the same job for a direct exec.
    var dumpFile: String?

    /// `--tour-capture <dir>` — exercise the real running window against fixtures and
    /// probe whether a trustworthy full-window capture is available, then exit.
    ///
    /// This is deliberately *not* a PNG source. `MorbShots` cannot represent window
    /// chrome, and an AppKit view cache cannot represent WindowServer-composited Tahoe
    /// materials. `LiveCapture` therefore records the unsupported route and fails
    /// rather than publishing a misleading image; see `Shots/LiveCapture.swift`.
    var tourCapture: String?

    /// `--tour-fixtures` — serve deterministic Docker data instead of dialing the real
    /// engine. This lets a real app window reach every review route without a running
    /// `morbstackd`.
    var tourFixtures = false

    static let none = LaunchOptions()

    /// `true` when the app was launched by the tour tooling rather than by a person.
    var isTour: Bool { select != nil || container != nil || windowSize != nil }

    /// Developer fixture launches must carry their provenance into the window chrome.
    /// Other developer switches still exercise the actual engine, so they intentionally
    /// do not receive this marker.
    var fixtureProvenance: FixtureProvenance? {
        tourFixtures ? .developerTour : nil
    }

    /// Parses the switches out of an argument vector.
    ///
    /// Unknown arguments are ignored rather than rejected: macOS itself appends things
    /// like `-NSDocumentRevisionsDebugMode` when launching from Xcode, and an app that
    /// refused to start over an argument it did not recognise would be maddening.
    init(arguments: [String] = CommandLine.arguments) {
        var index = 1
        func nextValue() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            switch arguments[index] {
            case "--tour-select":
                if let raw = nextValue() { select = Nav(rawValue: raw) }
            case "--tour-container":
                if let name = nextValue() { container = name }
            case "--appearance":
                switch nextValue()?.lowercased() {
                case "dark": appearance = .dark
                case "light": appearance = .light
                default: break
                }
            case "--window-size":
                if let raw = nextValue() { windowSize = Self.parseSize(raw) }
            case "--tour-dump-window":
                dumpWindow = true
            case "--tour-dump-file":
                if let path = nextValue() { dumpFile = path }
            case "--tour-capture":
                if let path = nextValue() { tourCapture = path }
            case "--tour-fixtures":
                tourFixtures = true
            default:
                break
            }
            index += 1
        }
    }

    /// `1280x800` → `CGSize(width: 1280, height: 800)`. Accepts `×` too, because that
    /// is what you get when the value came from a document rather than a shell.
    static func parseSize(_ raw: String) -> CGSize? {
        let parts = raw.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" })
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width >= 480, height >= 360
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// The explicit provenance carried by a developer fixture launch.
///
/// Fixture clients deliberately report a reachable synthetic engine so the ordinary
/// collection and inspector paths can be exercised without touching a person's Docker
/// engine. That transport convenience must never surface as a claim about the person's
/// actual engine, so window and sidebar chrome read from this separate provenance value.
struct FixtureProvenance: Sendable, Equatable {
    static let developerTour = FixtureProvenance(
        windowTitle: "Morbstack — Fixture Data",
        footerTitle: "Fixture Data",
        detail: "Developer fixtures — not connected to a Docker Engine.",
        accessibilityLabel: "Fixture data. Not connected to a Docker Engine.")

    let windowTitle: String
    let footerTitle: String
    let detail: String
    let accessibilityLabel: String
}

// MARK: - Model

@MainActor
@Observable
final class AppModel {

    // MARK: Published state

    var engine: EngineStatus = .unknown
    var containers: [ContainerSummary] = []
    var images: [ImageSummary] = []
    var volumes: [VolumeSummary] = []
    var networks: [NetworkSummary] = []
    var disk: DiskUsage?
    var buildCache: [BuildCacheRecord] = []
    /// Completed builds reported by Buildx for Morbstack's active builder. This is
    /// separate from `/system/df` cache records and remains empty until its own
    /// read-only query succeeds.
    var buildHistory: [BuildxHistoryRecord] = []
    var buildHistoryState: BuildxHistoryLoadState = .idle

    var selection: Nav = .containers
    var selectedContainerID: String?

    /// The shared host folders and whether the guest has them.
    ///
    /// Read by the status footer's warning chip, by the Settings pane, and by the
    /// container Overview tab, which needs it to tell a working bind mount from one
    /// pointing at a folder the VM cannot see.
    var fileSharing = MorbShareSurface.Report(shares: [], source: .config)

    /// Rosetta, as far as the host and the guest agree.
    ///
    /// Seeded from the host probe at launch so the Settings row and the Images screen's
    /// amd64 advice say something true with the engine stopped, then refined by the
    /// daemon once there is one.
    var rosetta: MorbRosettaState = TrackERosettaHost.localState(enabledInConfig: true)

    /// `true` while a refresh is in flight, for the toolbar's progress affordance.
    var isRefreshing = false
    /// `true` while an engine lifecycle command is running — the start button's spinner.
    var isEngineBusy = false
    /// Containers with a lifecycle command in flight, so their row can show a spinner
    /// and their buttons can disable without freezing the rest of the list.
    var busyContainerIDs: Set<String> = []
    /// The last thing that went wrong, for a dismissible banner. `nil` when all is well.
    var lastError: String?
    /// `true` once `bootstrap()` has produced an answer — until then the UI shows a
    /// quiet loading state rather than briefly claiming the engine is stopped.
    var hasLoaded = false

    /// A request from the menu bar or the command palette that the detail pane for this
    /// container switch to its Logs tab.
    ///
    /// Modelled as a one-shot request rather than as "the selected tab" so that the
    /// detail view keeps owning its own tab state: "View logs of X" should land on Logs
    /// once, not pin every container the user subsequently clicks to the Logs tab.
    var logsTabRequest: String?

    // MARK: Collaborators

    @ObservationIgnored var client: DockerClient
    @ObservationIgnored var daemon: DaemonClient
    /// Kubernetes is a real daemon/API-backed client in ordinary launches. The only
    /// fixture instance is supplied by `forLaunch` for the explicit developer tour.
    @ObservationIgnored let kubernetes: any K8sClusterProviding
    @ObservationIgnored let launchOptions: LaunchOptions

    /// `nil` for ordinary launches. Fixture mode is a developer aid, never evidence of
    /// the user's local Docker state, even though it keeps the normal UI data paths
    /// available for deterministic review.
    var fixtureProvenance: FixtureProvenance? {
        launchOptions.fixtureProvenance
    }

    // MARK: Private

    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var engineWatchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?
    @ObservationIgnored private var pendingTourContainer: String?
    /// Image ids whose platform lookup is in flight, so arrowing down a list does not
    /// queue a second request for a row that is already being resolved.
    @ObservationIgnored private var architectureLookups: Set<String> = []
    /// Running-container ids whose exact `State.StartedAt` is being read. A list
    /// response gives only human-oriented status prose, so this one bounded inspect per
    /// running container supplies the fact required for local uptime ticking.
    @ObservationIgnored private var startedAtLookups: Set<String> = []

    init(
        client: DockerClient = DockerClient(),
        daemon: DaemonClient = DaemonClient(),
        kubernetes: (any K8sClusterProviding)? = nil,
        launchOptions: LaunchOptions = LaunchOptions()
    ) {
        self.client = client
        self.daemon = daemon
        self.kubernetes = kubernetes ?? K8sDaemonClient(daemon: daemon)
        self.launchOptions = launchOptions
        if let select = launchOptions.select { selection = select }
        pendingTourContainer = launchOptions.container
    }

    deinit {
        eventsTask?.cancel()
        engineWatchTask?.cancel()
        refreshDebounce?.cancel()
    }

    /// Builds the model for a real launch, choosing fixture-backed clients when
    /// `--tour-fixtures` was passed.
    ///
    /// Kept here rather than inline in `App.swift`'s `init()` so that file only ever
    /// needs this one call, regardless of which fixture types `--tour-fixtures` ends up
    /// wiring in. `ShotDockerClient`, `ShotDaemonClient`, `ShotFixtures`, and `ShotLogs`
    /// provide deterministic developer data to the real app window; see
    /// `Shots/ShotClients.swift` and `Shots/ShotFixtures.swift`.
    static func forLaunch(_ options: LaunchOptions) -> AppModel {
        guard options.tourFixtures else { return AppModel(launchOptions: options) }
        return AppModel(
            client: ShotDockerClient(logLines: ShotLogs.apiLog()),
            daemon: ShotDaemonClient(reporting: ShotFixtures.engineRunning),
            kubernetes: K8sFixtureClient(),
            launchOptions: options)
    }

    // MARK: - Lifecycle

    /// Works out what state the world is in and gets the app into it.
    ///
    /// Asks the daemon first and the Docker socket second, because the two failures look
    /// identical from the engine's side but mean different things to the user: no daemon
    /// is "press start", a daemon that is still booting is "wait a moment".
    func bootstrap() async {
        // `refreshEngine` owns the stopped→running edge, and a first call always
        // crosses it when the engine is up: it does the initial `refreshAll` and opens
        // the event stream. Repeating either here would mean two full refreshes on
        // every launch.
        await refreshEngine()
        hasLoaded = true
        if !engine.isRunning { startEngineWatch() }
    }

    /// Re-reads the shared-folder table and the Rosetta state.
    ///
    /// Cheap and rare: two control-socket round trips plus one small file read, run at
    /// launch, on every engine transition, and when Settings opens. Neither answer can
    /// change without a VM restart or a config edit, so there is nothing here worth
    /// polling for.
    func refreshFileSharing() async {
        let hostRosetta = RosettaSupport.state
        let enabledInConfig = (try? MorbConfig.load())?.rosetta ?? true

        let configured = MorbShareSurface.configuredShares(fromFile: MorbPaths.configFile)
        fileSharing = MorbShareSurface.report(configured: configured, live: await daemon.shares())

        // The host is authoritative about installation and the config about intent; a
        // live reply contributes only the two facts the guest alone has.
        // `MorbShareSurface.rosetta` encodes that precedence, and it matters right after
        // `morb rosetta install`: Rosetta is on the Mac, and the VM that is still running
        // booted without it. Anything the guest did not say stays `nil` — *unknown*, not
        // `false` — which is what stops the Settings row reporting Rosetta broken on a
        // machine whose only problem is a stopped engine.
        rosetta = MorbShareSurface.rosetta(
            host: hostRosetta,
            enabledInConfig: enabledInConfig,
            live: await daemon.rosetta(supported: hostRosetta != .notSupported))
    }

    /// The status footer's file-sharing warning, when there is one.
    var fileSharingChip: TrackEStatusChip? {
        TrackEShareStatus.chip(fileSharing, engineRunning: engine.isRunning)
    }

    /// Re-reads the daemon's status and reacts to a transition.
    ///
    /// This is the only place that decides whether the event stream should be running,
    /// which keeps "engine came up" and "engine went away" from being handled in three
    /// places that slowly disagree.
    func refreshEngine() async {
        let previous = engine
        engine = await daemon.status()

        if engine.isRunning, !previous.isRunning {
            await refreshAll()
            await refreshFileSharing()
            startEventStream()
            stopEngineWatch()
        } else if !engine.isRunning, previous.isRunning {
            stopEventStream()
            clearEngineData()
            await refreshFileSharing()
            startEngineWatch()
        } else if !hasLoaded {
            // The first call, on an engine that did not change state. Both edges above
            // fetch the sharing table; this covers the launch-into-a-stopped-engine case,
            // which is the one where Settings is most likely to be opened next.
            await refreshFileSharing()
        }
    }

    /// Drops everything that described a now-gone engine.
    ///
    /// Leaving the last known containers on screen after the VM stopped would be a lie
    /// the user can click on.
    private func clearEngineData() {
        containers = []
        images = []
        volumes = []
        networks = []
        disk = nil
        buildCache = []
        buildHistory = []
        buildHistoryState = .idle
        selectedContainerID = nil
        busyContainerIDs.removeAll()
        startedAtLookups.removeAll()
    }

    // MARK: - Refresh

    /// Re-reads every collection the UI shows.
    ///
    /// The four list endpoints go out concurrently — they are independent, and doing
    /// them in series makes a refresh visibly stutter on a busy engine. Disk usage is
    /// deliberately *not* included: `/system/df` walks every layer and can take tens of
    /// seconds on a large store, so it is fetched only when the Disk screen is actually
    /// being looked at.
    func refreshAll() async {
        guard engine.isRunning else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let containersResult = fetch { try await self.client.listContainers(all: true) }
        async let imagesResult = fetch { try await self.client.listImages() }
        async let volumesResult = fetch { try await self.client.listVolumes() }
        async let networksResult = fetch { try await self.client.listNetworks() }

        let (newContainers, newImages, newVolumes, newNetworks) =
            await (containersResult, imagesResult, volumesResult, networksResult)

        if let newContainers {
            containers = sortForDisplay(preservingStartedAt(in: newContainers))
            resolveStartedAt(for: containers)
        }
        if let newImages { images = newImages }
        if let newVolumes { volumes = newVolumes }
        if let newNetworks { networks = newNetworks }

        resolvePendingTourContainer()

        if selection == .disk || disk != nil {
            await refreshDisk()
        }
    }

    /// Fills in one image's platform, if it is not already known.
    ///
    /// Called when a row is selected. `GET /images/json` reports a platform only for
    /// images pulled from a multi-arch index, so this covers the rest — locally built
    /// images especially — without inspecting every row of every refresh.
    ///
    /// Silent on failure. A missing architecture badge is a blank cell; an error banner
    /// over a click that was only meant to select a row would be absurd.
    func resolveArchitecture(for id: String) async {
        guard engine.isRunning else { return }
        guard let index = images.firstIndex(where: { $0.id == id }),
              images[index].architecture == nil,
              !architectureLookups.contains(id)
        else { return }

        architectureLookups.insert(id)
        defer { architectureLookups.remove(id) }

        guard let architecture = try? await client.imageArchitecture(id: id) else { return }
        // Re-find the row: the list may have been replaced by a refresh while the
        // request was in flight, and writing back to a stale index would badge the
        // wrong image.
        guard let current = images.firstIndex(where: { $0.id == id }) else { return }
        images[current].architecture = architecture
    }

    /// Re-reads `docker system df`.
    func refreshDisk() async {
        guard engine.isRunning else { return }
        if let usage = await fetch({ try await self.client.diskUsage() }) {
            disk = usage
        }
    }

    /// Re-reads the BuildKit cache record list, the same endpoint `refreshDisk()` uses.
    /// Kept separate so the Builds screen does not pay for a fetch nobody but it wants.
    func refreshBuildCache() async {
        guard engine.isRunning else { return }
        if let records = await fetch({ try await self.client.buildCacheRecords() }) {
            buildCache = records
        }
    }

    /// Re-reads Buildx's completed-build history for its active Morbstack builder.
    ///
    /// This is a separate client command rather than a Docker Engine API call. Its
    /// failure must not imply that the engine is down: a bundled Buildx version can be
    /// missing history support while normal Docker operations are healthy, so the
    /// Builds route renders this state locally instead of replacing the app-wide engine
    /// status or inventing records from cache layers.
    func refreshBuildHistory() async {
        guard engine.isRunning else { return }
        buildHistoryState = .loading
        do {
            buildHistory = try await BuildxHistoryClient.list(socketPath: MorbPaths.dockerSocket.path)
            buildHistoryState = .loaded
        } catch {
            buildHistory = []
            buildHistoryState = .unavailable(MorbErrorMessage.text(for: error))
        }
    }

    /// Runs one engine call, folding its failure into the model rather than throwing.
    ///
    /// Views cannot `catch`, and a failed refresh is not an exceptional condition — the
    /// engine stopping underneath the app is an ordinary Tuesday. An unreachable error
    /// downgrades the engine state, which flips the whole UI to the start screen;
    /// anything else surfaces as a banner and leaves the last good data in place.
    private func fetch<T: Sendable>(_ body: @Sendable () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch let error as DockerClientError where error.isUnreachable {
            if engine.isRunning {
                engine = EngineStatus(
                    state: "stopped", vmState: "not running", version: engine.version, reachable: false)
                stopEventStream()
                clearEngineData()
                startEngineWatch()
            }
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Running containers first, then everything else, each alphabetically.
    ///
    /// Docker returns creation order, which puts the thing you just started at the top
    /// one minute and in the middle the next. Sorting by state keeps what matters
    /// visible and keeps rows from jumping around as containers cycle.
    private func sortForDisplay(_ list: [ContainerSummary]) -> [ContainerSummary] {
        list.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// `/containers/json` does not include `State.StartedAt`. Retain exact inspect
    /// values across ordinary list refreshes, but only while the same record remains
    /// running; a stop/restart must obtain a new start instant rather than reusing an
    /// old one.
    private func preservingStartedAt(in fresh: [ContainerSummary]) -> [ContainerSummary] {
        let known = Dictionary(
            uniqueKeysWithValues: containers.compactMap { container in
                guard container.isRunning, let startedAt = container.startedAt else { return nil }
                return (container.id, startedAt)
            })

        return fresh.map { container in
            var container = container
            if container.isRunning { container.startedAt = known[container.id] }
            return container
        }
    }

    /// Hydrates only missing start instants. This is not a polling loop: after a
    /// successful inspect, `TimelineView` advances the displayed elapsed time locally;
    /// another inspect happens only for a newly running/restarted record or after a
    /// previous inspect failed.
    private func resolveStartedAt(for summaries: [ContainerSummary]) {
        let unresolved = summaries.filter {
            $0.isRunning && $0.startedAt == nil && !startedAtLookups.contains($0.id)
        }

        for summary in unresolved {
            let id = summary.id
            let client = client
            startedAtLookups.insert(id)

            Task { [weak self, client] in
                let inspect = try? await client.inspectContainer(id: id)
                let startedAt = inspect.flatMap { TrackBInspectDetails(json: $0)?.startedAt }

                guard let self else { return }
                self.startedAtLookups.remove(id)
                guard let startedAt,
                      startedAt.timeIntervalSince1970 > 0,
                      let index = self.containers.firstIndex(where: { $0.id == id }),
                      self.containers[index].isRunning
                else { return }
                self.containers[index].startedAt = startedAt
            }
        }
    }

    // MARK: - Container actions

    /// Performs a lifecycle action and keeps the row honest while it happens.
    func containerAction(_ action: ContainerAction, id: String) async {
        guard !busyContainerIDs.contains(id) else { return }
        busyContainerIDs.insert(id)
        defer { busyContainerIDs.remove(id) }

        do {
            switch action {
            case .start: try await client.startContainer(id: id)
            case .stop: try await client.stopContainer(id: id)
            case .restart: try await client.restartContainer(id: id)
            case .pause: try await client.pauseContainer(id: id)
            case .unpause: try await client.unpauseContainer(id: id)
            case .remove: try await client.removeContainer(id: id)
            }
        } catch {
            lastError = error.localizedDescription
            // The optimistic patch below must not run: the container is in whatever
            // state it was already in, and claiming otherwise would leave a green dot
            // over a container that failed to start.
            await refreshAll()
            return
        }

        applyOptimisticPatch(action, id: id)
        scheduleReconcile()
    }

    /// Moves a row to the state the action is about to produce.
    ///
    /// Only ever a guess, and always corrected by the reconcile 500 ms later — but it
    /// is the difference between a UI that responds to a click and one that waits.
    private func applyOptimisticPatch(_ action: ContainerAction, id: String) {
        guard let index = containers.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case .remove:
            containers.remove(at: index)
            if selectedContainerID == id { selectedContainerID = nil }
        case .start:
            containers[index].state = "running"
            containers[index].status = "Up less than a second"
            // `start` is optimistic. Do not turn the host clock into claimed Docker
            // state; the next inspect or engine event provides the actual start time.
            containers[index].startedAt = nil
        case .unpause:
            containers[index].state = "running"
            containers[index].status = "Up less than a second"
        case .stop:
            containers[index].state = "exited"
            containers[index].status = "Exited (0) just now"
            containers[index].ports = []
            containers[index].startedAt = nil
        case .pause:
            containers[index].state = "paused"
            containers[index].status = "Up (Paused)"
        case .restart:
            containers[index].state = "restarting"
            containers[index].status = "Restarting"
            containers[index].startedAt = nil
        }
    }

    // MARK: - Local image run

    /// Creates and starts exactly one container from an image already present in this
    /// model's local Engine inventory. The selected immutable image ID—not a mutable
    /// tag—is the only image input. No pull or image inspect happens here.
    ///
    /// A create or start reply can race a client disconnect, and Docker's documented
    /// start statuses include cases such as "already started" that must not be treated
    /// as a disposable failed container. Once create returns an ID, Morbstack never
    /// deletes it automatically; the result directs the person to Containers instead.
    func runLocalImage(
        imageID: String,
        requestedName: String?,
        progress: (LocalImageRunProgress) -> Void
    ) async throws -> LocalImageRunResult {
        guard engine.isRunning else {
            throw DockerClientError.engineUnreachable("the engine is not running")
        }
        guard images.contains(where: { $0.id == imageID }) else {
            throw LocalImageRunError.imageIsNoLongerLocal
        }

        let name = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = (name?.isEmpty == false) ? name : nil

        progress(.creating)
        let containerID: String
        do {
            containerID = try await client.createLocalImageContainer(
                imageID: imageID,
                requestedName: normalizedName)
        } catch let createError as DockerClientError {
            // A non-2xx response means Docker rejected this create. A transport or
            // reachability failure has no returned ID and may have crossed the socket
            // boundary, so it must be reported as unknown without a destructive follow-up.
            if case .http = createError { throw createError }
            throw LocalImageRunError.createOutcomeUnknown(message: createError.localizedDescription)
        } catch {
            throw LocalImageRunError.createOutcomeUnknown(message: MorbErrorMessage.text(for: error))
        }

        progress(.starting)
        do {
            try await client.startContainer(id: containerID)
        } catch {
            throw LocalImageRunError.startNotConfirmed(
                containerID: containerID,
                message: MorbErrorMessage.text(for: error))
        }

        // The start response is the source of truth for this result. Refreshing is a
        // convenience for the surrounding tables; its independent failure must not
        // change a successful start into a false failure result.
        await refreshAll()
        return LocalImageRunResult(containerID: containerID, requestedName: normalizedName)
    }

    /// Navigates to a container whose identity was returned by a successful Engine
    /// create/start result. The caller never guesses a name or a status.
    func showContainer(id: String) {
        selection = .containers
        selectedContainerID = id
    }

    // MARK: - Engine actions

    /// Starts, stops or suspends the VM.
    func engineAction(_ action: EngineAction) async {
        guard !isEngineBusy else { return }
        isEngineBusy = true
        defer { isEngineBusy = false }

        // Reflect the intent immediately. `daemon.start()` can legitimately take the
        // better part of a minute — VM boot plus dockerd — and a button that looks
        // inert for that long reads as broken.
        switch action {
        case .start: engine = EngineStatus(state: "starting", vmState: "starting", version: engine.version, reachable: true)
        case .stop: engine.state = "stopping"
        case .suspend: engine.state = "pausing"
        }

        do {
            switch action {
            case .start: try await daemon.start()
            case .stop: try await daemon.stop()
            case .suspend: try await daemon.suspend()
            }
        } catch {
            lastError = error.localizedDescription
        }

        await refreshEngine()
        // A `start` that reported success but has not yet flipped to `running` is the
        // normal case — dockerd is still coming up inside the guest. The watch loop
        // takes it from here.
        if !engine.isRunning { startEngineWatch() }
    }

    // MARK: - Events

    /// Subscribes to `/events` and keeps the model in step with the engine.
    func startEventStream() {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            guard let self else { return }
            // The task inherits this actor, so `handle` runs on the main actor with no
            // hop — which is what makes a patch land in the same frame as the event.
            // The `for try await` still suspends, so the main actor is released while
            // the stream is idle; the socket read itself is on the client's own thread.
            let stream = self.client.events()
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    self.handle(event)
                }
                // A clean end means the engine closed the stream, which in practice
                // means it went away. Confirming with the daemon rather than assuming
                // avoids flipping the UI to "stopped" over a transient hiccup.
                await self.handleEventStreamEnd()
            } catch {
                if !Task.isCancelled { await self.handleEventStreamEnd() }
            }
        }
    }

    private func stopEventStream() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    private func handleEventStreamEnd() async {
        eventsTask = nil
        await refreshEngine()
        // `refreshEngine` restarts the stream only on a stopped→running edge; if the
        // engine is still up, the stream simply dropped and needs re-establishing.
        if engine.isRunning, eventsTask == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if engine.isRunning { startEventStream() }
        }
    }

    /// Applies one engine event.
    private func handle(_ event: DockerEvent) {
        switch event.type {
        case "container":
            if patchContainer(with: event) {
                scheduleReconcile()
            }
        case "image", "volume", "network":
            // Nothing here is worth a bespoke patch: these lists are small, change
            // rarely, and have no per-row state a stale entry would misrepresent.
            scheduleReconcile()
        default:
            break
        }
    }

    /// Updates the single row an event is about.
    ///
    /// - Returns: `true` when the event was worth reconciling for. A `create` for a
    ///   container we have never heard of returns `true` without patching anything —
    ///   the refresh is what will add the row.
    @discardableResult
    private func patchContainer(with event: DockerEvent) -> Bool {
        guard event.isContainerLifecycle else { return false }
        let id = event.actorID
        guard let index = containers.firstIndex(where: { $0.id == id }) else {
            // Unknown container: either brand new, or one that was removed while we
            // were not looking. Either way the reconcile sorts it out.
            return true
        }

        let action = event.action
        switch action {
        case "start", "restart":
            containers[index].state = "running"
            containers[index].startedAt = event.time
        case "unpause":
            containers[index].state = "running"
        case "die", "stop", "kill":
            containers[index].state = "exited"
            if let code = event.attributes["exitCode"] {
                containers[index].status = "Exited (\(code)) just now"
            }
            containers[index].ports = []
            containers[index].startedAt = nil
        case "pause":
            containers[index].state = "paused"
        case "destroy":
            containers.remove(at: index)
            if selectedContainerID == id { selectedContainerID = nil }
        case "rename":
            if let name = event.attributes["name"] {
                containers[index].displayName = name
                containers[index].names = [name]
            }
        default:
            // `health_status: unhealthy` and friends: the status prose carries the
            // health, and that is what `ContainerSummary.isUnhealthy` reads.
            if action.hasPrefix("health_status") {
                let verdict = action.contains("unhealthy") ? "unhealthy" : "healthy"
                containers[index].status = "Up (\(verdict))"
            }
        }
        return true
    }

    /// Coalesces event-driven refreshes into at most one every 500 ms.
    ///
    /// `compose up` on a real stack produces a burst of forty events; without this the
    /// app would issue forty full refreshes, each of which is four HTTP round trips.
    private func scheduleReconcile() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refreshAll()
        }
    }

    // MARK: - Engine watch

    /// Polls the daemon while the engine is *not* usable.
    ///
    /// The only loop in the app, and it exists because there is nothing to subscribe to:
    /// a stopped daemon has no socket, and a booting one has no event stream until
    /// dockerd is listening. It runs at 2 s — fast enough that "start" feels answered,
    /// slow enough to be invisible — and cancels itself the instant `/events` can do
    /// the job instead.
    private func startEngineWatch() {
        guard engineWatchTask == nil else { return }
        engineWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let stillWatching = await self.tickEngineWatch()
                if !stillWatching { return }
            }
        }
    }

    /// One iteration of the watch. Returns `false` when the loop should end.
    private func tickEngineWatch() async -> Bool {
        // Do not fight an in-flight `start`/`stop`: the daemon is single-threaded over
        // its control socket, and a status request queued behind a 60-second boot just
        // makes the boot look slower.
        guard !isEngineBusy else { return true }
        await refreshEngine()
        if engine.isRunning {
            engineWatchTask = nil
            return false
        }
        return true
    }

    private func stopEngineWatch() {
        engineWatchTask?.cancel()
        engineWatchTask = nil
    }

    // MARK: - Tour support

    /// Opens the container named by `--tour-container`, once it exists.
    ///
    /// Deferred rather than resolved at launch because the containers list is not
    /// populated until the first refresh returns, which is after the window is already
    /// on screen. Matches on name first and on an id prefix second, so both
    /// `--tour-container web` and `--tour-container 3f2a91` work.
    private func resolvePendingTourContainer() {
        guard let wanted = pendingTourContainer else { return }
        let match = containers.first { candidate in
            candidate.names.contains(wanted)
                || candidate.displayName == wanted
                || candidate.id.hasPrefix(wanted)
        }
        guard let match else { return }
        pendingTourContainer = nil
        selection = launchOptions.select ?? .containers
        selectedContainerID = match.id
    }

    // MARK: - Derived

    /// The containers list grouped into compose projects, for the Stacks screen.
    var composeGroups: [ComposeGroup] { containers.groupedByComposeProject() }

    /// The currently selected container, if it still exists.
    var selectedContainer: ContainerSummary? {
        guard let selectedContainerID else { return nil }
        return containers.first { $0.id == selectedContainerID }
    }

    var runningCount: Int { containers.filter(\.isRunning).count }

    /// A one-line summary for the menu bar and the sidebar footer.
    var summaryLine: String {
        guard engine.isRunning else { return engine.headline }
        return "\(runningCount) of \(containers.count) running"
    }

    /// Clears the error banner.
    func dismissError() { lastError = nil }

    /// Asks the detail pane for `id` to show its Logs tab.
    ///
    /// Backs `TrackDAppBridge.showLogs`, which `App.swift` installs at launch.
    func requestLogsTab(for id: String) { logsTabRequest = id }

    /// Consumes a pending Logs-tab request for `id`, if there is one.
    ///
    /// Returns `true` exactly once per request, so a detail view that is rebuilt for an
    /// unrelated reason does not keep snapping itself back to Logs.
    func consumeLogsTabRequest(for id: String) -> Bool {
        guard logsTabRequest == id else { return false }
        logsTabRequest = nil
        return true
    }
}
