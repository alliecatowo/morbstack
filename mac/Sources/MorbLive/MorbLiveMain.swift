// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `MorbLive` — the app's data layer, run against a real engine.
//
// Everything under `MorbstackAppCore` that talks to Docker has, until now, only been
// verified by unit tests against synthetic bytes. That proves the parser handles the
// bytes we *imagined*; it says nothing about the bytes a real dockerd sends, which
// arrive split across reads at arbitrary offsets, framed three different ways depending
// on the endpoint, and interleaved with keep-alives. This executable closes that gap:
// it drives `DockerClient` and `DaemonClient` against ~/.morbstack/run/docker.sock with
// a live workload in front of them and prints PASS/FAIL with the observed value for
// every assertion.
//
// It is an executable and not a test target on purpose. `swift test` runs on machines
// with no VM; a check that needs a booted guest belongs behind a deliberate command.
//
// Fixtures are expected to exist already — scripts/live-app-check.sh creates them —
// with one exception: the events check has to *cause* an event, so it starts and stops
// the `-exit` fixture itself.
//
// `@testable` is how this reaches `DockerClient`: the data layer is internal to
// `MorbstackAppCore` and there is no reason to make the whole Docker surface public for
// a dev-only harness. Debug builds enable testing by default, and this target is never
// built for release.

import Darwin
import Foundation
import MorbstackKit

@testable import MorbstackAppCore

@main
enum MorbLive {

    /// A hard ceiling on the whole run, in seconds. `MORBLIVE_BUDGET` overrides.
    ///
    /// Every check already has its own deadline, but "a blocking `read(2)` never
    /// returns" is precisely the class of bug this harness exists to catch, and a
    /// harness that hangs while looking for a hang reports nothing at all. `_exit`
    /// rather than `exit`: the point is to leave *now*, not to run atexit handlers that
    /// may themselves be parked on the same socket.
    static func armWatchdog(_ seconds: TimeInterval) {
        let thread = Thread {
            Thread.sleep(forTimeInterval: seconds)
            FileHandle.standardError.write(
                Data("\nMorbLive: watchdog fired after \(Int(seconds))s — a check is wedged\n".utf8))
            _exit(2)
        }
        thread.name = "morblive.watchdog"
        thread.start()
    }

    /// Fixture names, all sharing a prefix so teardown can be exact rather than a
    /// pattern match against whatever else the user has running.
    struct Fixtures {
        var prefix: String
        /// The host port the web fixture publishes. Matches `MORBLIVE_PORT` in
        /// scripts/live-app-check.sh, so a second fixture namespace can use a second
        /// port rather than colliding with the first.
        var port: Int = 18080
        var web: String { "\(prefix)-web" }
        var logger: String { "\(prefix)-logger" }
        var exit: String { "\(prefix)-exit" }
        var volume: String { "\(prefix)-vol" }
        var composeProject: String { prefix }
    }

    static func main() async {
        let budget = ProcessInfo.processInfo.environment["MORBLIVE_BUDGET"].flatMap(TimeInterval.init) ?? 300
        armWatchdog(budget)

        let report = Report()
        let prefix = ProcessInfo.processInfo.environment["MORBLIVE_PREFIX"] ?? "morbshot"
        let port = ProcessInfo.processInfo.environment["MORBLIVE_PORT"].flatMap(Int.init) ?? 18080
        let fixtures = Fixtures(prefix: prefix, port: port)
        let socketPath =
            ProcessInfo.processInfo.environment["MORBLIVE_SOCKET"] ?? MorbPaths.dockerSocket.path

        print("MorbLive — live data-layer check")
        print("socket: \(socketPath)")
        print("budget: \(Int(budget))s")
        print("fixtures: \(fixtures.web), \(fixtures.logger), \(fixtures.exit), \(fixtures.volume)")

        let docker = DockerClient(socketPath: socketPath)

        await checkDaemon(report)
        let containers = await checkContainers(report, docker, fixtures)
        await checkImages(report, docker, socketPath)
        await checkVolumes(report, docker, fixtures)
        await checkNetworks(report, docker, socketPath)
        await checkDiskUsage(report, docker)
        await checkInspect(report, docker, containers, fixtures)
        await checkLogs(report, docker, containers, fixtures)
        await checkStats(report, docker, containers, fixtures, socketPath)
        await checkEvents(report, docker, containers, fixtures)

        report.section("Summary")
        print("")
        print(report.table())
        exit(report.failureCount == 0 ? 0 : 1)
    }

    // MARK: - Helpers

    /// Finds a fixture in a listing, or records the failure and returns nil.
    static func find(
        _ name: String, in containers: [ContainerSummary], _ report: Report, check: String
    ) -> ContainerSummary? {
        guard let match = containers.first(where: { $0.names.contains(name) }) else {
            report.fail(check, "fixture `\(name)` is not in the container list — is the workload up?")
            return nil
        }
        return match
    }

    /// Runs a binary and returns its stdout. Used only to cross-check `DaemonClient`
    /// against the CLI that is already known to work.
    static func capture(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "could not run \(executable.path): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The `morb` built alongside this harness.
    static var morbExecutable: URL? {
        if let override = ProcessInfo.processInfo.environment["MORB_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("morb")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    // MARK: - Daemon

    static func checkDaemon(_ report: Report) async {
        report.section("DaemonClient")

        let daemon = DaemonClient()
        let status = await daemon.status()
        report.expect(
            "daemon.reachable", status.reachable,
            "state=\(status.state) vmState=\(status.vmState) version=\(status.version ?? "nil")")
        report.expect(
            "daemon.running", status.isRunning,
            "isRunning=\(status.isRunning) (state=\(status.state))")

        guard let morb = morbExecutable else {
            report.fail("daemon.matchesCLI", "could not locate the `morb` binary next to MorbLive")
            return
        }
        let (code, output) = capture(morb, ["status", "--json"])
        guard code == 0,
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            report.fail("daemon.matchesCLI", "`morb status --json` exited \(code): \(clip(output))")
            return
        }
        // The CLI prints the raw daemon envelope; the interesting fields are one level in.
        let payload = (root["data"] as? [String: Any]) ?? root
        let cliState = payload["state"] as? String ?? "?"
        let cliVMState = payload["vm_state"] as? String ?? "?"
        let dockerReady = payload["docker_ready"] as? Bool ?? false

        // `DaemonClient` deliberately reports `starting` while the VM runs but dockerd
        // has not answered yet, so the comparison has to apply the same rule rather than
        // demand the strings match literally.
        let expectedState = (cliState == "running" && !dockerReady) ? "starting" : cliState
        report.expect(
            "daemon.matchesCLI", status.state == expectedState,
            "DaemonClient=\(status.state) morb=\(cliState) docker_ready=\(dockerReady) → expected \(expectedState)")
        report.expect(
            "daemon.vmStateMatches", status.vmState == cliVMState || cliVMState == "?",
            "DaemonClient=\(status.vmState) morb=\(cliVMState)")
    }

    // MARK: - Containers

    static func checkContainers(
        _ report: Report, _ docker: DockerClient, _ fixtures: Fixtures
    ) async -> [ContainerSummary] {
        report.section("listContainers")

        let containers: [ContainerSummary]
        do {
            containers = try await docker.listContainers(all: true)
        } catch {
            report.fail("listContainers", "threw \(error)")
            return []
        }

        let names = containers.flatMap(\.names).sorted()
        report.expect(
            "listContainers", !containers.isEmpty,
            "\(containers.count) containers: \(clip(names.joined(separator: ", ")))")

        for fixture in [fixtures.web, fixtures.logger, fixtures.exit] {
            let match = containers.first { $0.names.contains(fixture) }
            report.expect(
                "listContainers.\(fixture)", match != nil,
                match.map { "id=\($0.shortID) state=\($0.state) status=\($0.status) image=\($0.image)" }
                    ?? "missing")
        }

        // Compose attribution: the labels the engine carries, read back through the
        // wire→view-model mapping the sidebar depends on.
        if let web = containers.first(where: { $0.names.contains(fixtures.web) }) {
            report.expect(
                "compose.attribution",
                web.composeProject == fixtures.composeProject && web.composeService == "web",
                "project=\(web.composeProject ?? "nil") service=\(web.composeService ?? "nil")")
            report.expect(
                "compose.ports",
                web.ports.contains { $0.hostPort == fixtures.port && $0.containerPort == 80 },
                "ports=[\(web.ports.map(\.label).joined(separator: ", "))]")
        }

        let groups = containers.groupedByComposeProject()
        let project = groups.first { $0.project == fixtures.composeProject }
        report.expect(
            "compose.grouping", project != nil && (project?.containers.count ?? 0) >= 2,
            "groups=[\(groups.map { "\($0.title):\($0.containers.count)" }.joined(separator: ", "))]")
        report.expect(
            "compose.standaloneLast", groups.last?.project == nil || groups.allSatisfy { $0.project != nil },
            "last group = \(groups.last?.title ?? "none")")

        return containers
    }

    // MARK: - Images, volumes, networks

    static func checkImages(_ report: Report, _ docker: DockerClient, _ socketPath: String) async {
        report.section("listImages")
        do {
            let images = try await docker.listImages()
            let tags = images.flatMap(\.repoTags)
            report.expect(
                "listImages", !images.isEmpty,
                "\(images.count) images: \(clip(tags.joined(separator: ", ")))")
            report.expect(
                "listImages.sizes", images.allSatisfy { $0.size >= 0 } && images.contains { $0.size > 0 },
                "largest=\(images.map(\.size).max() ?? 0) bytes")
            report.expect(
                "listImages.sorted",
                zip(images, images.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt },
                "newest=\(images.first?.repoTags.first ?? "-") oldest=\(images.last?.repoTags.first ?? "-")")

            // Cross-check the count against a client that shares no code with this one.
            if let raw = try? RawEngine.array("/\(DockerClient.apiVersion)/images/json?all=0", socketPath: socketPath) {
                report.expect(
                    "listImages.matchesRaw", raw.count == images.count,
                    "DockerClient=\(images.count) raw=\(raw.count)")
            }
        } catch {
            report.fail("listImages", "threw \(error)")
        }
    }

    static func checkVolumes(_ report: Report, _ docker: DockerClient, _ fixtures: Fixtures) async {
        report.section("listVolumes")
        do {
            let volumes = try await docker.listVolumes()
            report.expect(
                "listVolumes", !volumes.isEmpty,
                "\(volumes.count) volumes: \(clip(volumes.map(\.name).joined(separator: ", ")))")
            let fixture = volumes.first { $0.name == fixtures.volume }
            report.expect(
                "listVolumes.\(fixtures.volume)", fixture != nil,
                fixture.map { "driver=\($0.driver) mountpoint=\($0.mountpoint)" } ?? "missing")
        } catch {
            report.fail("listVolumes", "threw \(error)")
        }
    }

    static func checkNetworks(_ report: Report, _ docker: DockerClient, _ socketPath: String) async {
        report.section("listNetworks")
        do {
            let networks = try await docker.listNetworks()
            let names = Set(networks.map(\.name))
            report.expect(
                "listNetworks", !networks.isEmpty,
                "\(networks.count) networks: \(clip(networks.map { "\($0.name)/\($0.driver)" }.joined(separator: ", ")))")
            report.expect(
                "listNetworks.builtins", names.isSuperset(of: ["bridge", "host", "none"]),
                "found \(names.sorted().joined(separator: ", "))")
            let bridge = networks.first { $0.name == "bridge" }
            report.expect(
                "listNetworks.attachments", (bridge?.containers ?? 0) >= 1,
                "bridge has \(bridge?.containers ?? -1) attached containers")

            // The bug this endpoint had: `GET /networks` answers `"Containers": null`
            // for every row, so a client that believes it reports zero attachments
            // everywhere and the Networks screen calls every live network *unused*. The
            // only cure is the per-network detail fetch, and the only way to prove the
            // fetch is really happening is to look at what the list endpoint said on its
            // own. Note rather than fail if the engine ever starts filling the summary
            // in: that would make the second round trip redundant, not wrong.
            let rawList = try RawEngine.array("/\(DockerClient.apiVersion)/networks", socketPath: socketPath)
            let rawBridge = rawList.first { $0["Name"] as? String == "bridge" }
            let listSaid = rawBridge?["Containers"] as? [String: Any]
            if listSaid == nil {
                report.expect(
                    "listNetworks.detailFetched", (bridge?.containers ?? 0) >= 1,
                    "GET /networks says Containers=null for bridge; DockerClient reports "
                        + "\(bridge?.containers ?? -1) — the per-network detail fetch is doing the work")
            } else {
                report.note(
                    "GET /networks filled the attachment map in itself (\(listSaid?.count ?? 0) entries) "
                        + "— the detail fetch is redundant on this engine, not wrong")
            }

            // And the detail endpoint's own count is the ground truth to match.
            if let id = rawBridge?["Id"] as? String,
               let detail = try? RawEngine.object(
                "/\(DockerClient.apiVersion)/networks/\(id)", socketPath: socketPath) {
                let truth = (detail["Containers"] as? [String: Any])?.count ?? -1
                report.expect(
                    "listNetworks.matchesRaw", bridge?.containers == truth,
                    "DockerClient=\(bridge?.containers ?? -1) GET /networks/\(String(id.prefix(12)))=\(truth)")
            }
        } catch {
            report.fail("listNetworks", "threw \(error)")
        }
    }

    static func checkDiskUsage(_ report: Report, _ docker: DockerClient) async {
        report.section("diskUsage")
        do {
            let usage = try await docker.diskUsage()
            report.expect(
                "diskUsage", usage.layersSize > 0,
                "layers=\(usage.layersSize) images=\(usage.imagesTotal) volumes=\(usage.volumesTotal) "
                    + "cache=\(usage.buildCacheTotal) containers=\(usage.containersTotal) "
                    + "reclaimable=\(usage.reclaimable) total=\(usage.total)")
            report.expect(
                "diskUsage.nonNegative",
                [usage.imagesTotal, usage.volumesTotal, usage.buildCacheTotal, usage.containersTotal,
                 usage.reclaimable].allSatisfy { $0 >= 0 },
                "all six figures ≥ 0")
            report.expect(
                "diskUsage.reclaimableBounded", usage.reclaimable <= usage.total,
                "reclaimable=\(usage.reclaimable) total=\(usage.total)")
        } catch {
            report.fail("diskUsage", "threw \(error)")
        }
    }

    static func checkInspect(
        _ report: Report, _ docker: DockerClient, _ containers: [ContainerSummary], _ fixtures: Fixtures
    ) async {
        report.section("inspectContainer")
        guard let web = find(fixtures.web, in: containers, report, check: "inspectContainer") else { return }
        do {
            let text = try await docker.inspectContainer(id: web.id)
            let head = String(text.prefix(200))
            report.expect(
                "inspectContainer", text.contains("\"Id\"") && text.contains(web.id),
                clip(head, 200))
            report.expect(
                "inspectContainer.pretty", text.contains("\n") && text.hasPrefix("{"),
                "\(text.count) chars, \(text.components(separatedBy: "\n").count) lines")
            let tty = await docker.containerHasTTY(id: web.id)
            report.expect("inspectContainer.tty", tty == false, "Config.Tty=\(tty) (expected false)")
        } catch {
            report.fail("inspectContainer", "threw \(error)")
        }
    }

    // MARK: - Logs

    static func checkLogs(
        _ report: Report, _ docker: DockerClient, _ containers: [ContainerSummary], _ fixtures: Fixtures
    ) async {
        report.section("logs(follow: true)")
        guard let logger = find(fixtures.logger, in: containers, report, check: "logs") else { return }

        let wanted = 10
        let sink = await drain(
            docker.logs(id: logger.id, follow: true, tail: 500),
            until: { $0.count >= wanted },
            timeout: 45)
        let lines = sink.snapshot

        report.expect(
            "logs.received", lines.count >= wanted,
            "\(lines.count) lines in 45s\(sink.error.map { ", error: \($0)" } ?? "")")
        guard !lines.isEmpty else { return }

        for (index, line) in lines.prefix(wanted).enumerated() {
            report.note("\(index): [\(line.stream)] \(clip(line.text, 80))")
        }

        // The whole reason stdcopy exists. If the 8-byte headers survived into the text,
        // they show up as NUL and other C0 bytes right where a line begins.
        let control = CharacterSet(charactersIn: "\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}")
        let dirty = lines.filter { $0.text.rangeOfCharacter(from: control) != nil }
        report.expect(
            "logs.demuxClean", dirty.isEmpty,
            dirty.isEmpty
                ? "no C0 header bytes in \(lines.count) lines"
                : "\(dirty.count) lines carry header garbage, first: \(clip(dirty[0].text, 60))")

        let ansi = lines.filter { $0.text.contains("\u{1B}[") }
        report.expect(
            "logs.ansiSurvives", !ansi.isEmpty,
            ansi.isEmpty
                ? "no ESC[ sequence in any of \(lines.count) lines"
                : "\(ansi.count)/\(lines.count) lines carry SGR, first: \(clip(ansi[0].text, 60))")

        // Two streams proves the demuxer really is in multiplexed mode rather than
        // passing bytes through and getting lucky.
        let streams = Set(lines.map(\.stream))
        report.expect(
            "logs.stderrDemuxed", streams.contains(.stderr),
            "streams seen: \(streams.map { "\($0)" }.sorted().joined(separator: "+")) "
                + "(stdout=\(lines.filter { $0.stream == .stdout }.count) "
                + "stderr=\(lines.filter { $0.stream == .stderr }.count))")

        report.expect(
            "logs.timestamps", lines.allSatisfy { $0.timestamp != nil },
            "\(lines.filter { $0.timestamp != nil }.count)/\(lines.count) lines carry a parsed timestamp; "
                + "first=\(lines[0].timestamp.map(ISO8601DateFormatter().string) ?? "nil")")

        // The fixture numbers its ticks. Contiguity is the assertion that catches bytes
        // dropped or duplicated at a chunk boundary, which no unit test can stage.
        let ticks = lines.compactMap { line -> Int? in
            guard let range = line.text.range(of: "tick ") else { return nil }
            return Int(line.text[range.upperBound...].prefix(while: \.isNumber))
        }
        let contiguous = zip(ticks, ticks.dropFirst()).allSatisfy { $1 == $0 + 1 }
        report.expect(
            "logs.noByteLoss", ticks.count >= 2 && contiguous,
            "tick sequence \(ticks.map(String.init).joined(separator: ","))")

        // The fixture also emits one line far larger than a single read, so reassembly
        // across reads is exercised rather than assumed.
        let long = lines.filter { $0.text.contains("long ") }
        if let sample = long.first {
            let payload = sample.text.drop(while: { $0 != "x" })
            report.expect(
                "logs.longLineIntact",
                payload.count == LiveWorkload.longLineLength && payload.allSatisfy { $0 == "x" },
                "\(payload.count) filler chars (expected \(LiveWorkload.longLineLength)), "
                    + "uniform=\(payload.allSatisfy { $0 == "x" })")
        } else {
            report.note("no long line in this window — increase the log wait to exercise reassembly")
        }
    }

    // MARK: - Stats

    static func checkStats(
        _ report: Report, _ docker: DockerClient, _ containers: [ContainerSummary],
        _ fixtures: Fixtures, _ socketPath: String
    ) async {
        report.section("stats(id:)")
        guard let logger = find(fixtures.logger, in: containers, report, check: "stats") else { return }

        // Ground truth for the CPU bound, from a client that shares no code with the one
        // under test.
        var cores = 1
        if let info = try? RawEngine.object("/\(DockerClient.apiVersion)/info", socketPath: socketPath),
           let ncpu = info["NCPU"] as? Int {
            cores = max(1, ncpu)
        }
        report.note("guest reports \(cores) CPUs")

        // Is the first-sample trap real on *this* engine? This reads the document a
        // `stream=1` response opens with, using a client that shares no code with the one
        // under test. Not `stream=0`: dockerd answers the one-shot form with a
        // second, properly-based reading, so it cannot show the baseline at all.
        var primingPercent: Double?
        do {
            let raw = try RawEngine.firstStreamedObject(
                "/\(DockerClient.apiVersion)/containers/\(logger.id)/stats?stream=1",
                socketPath: socketPath)
            let precpu = raw["precpu_stats"] as? [String: Any]
            let previousSystem = (precpu?["system_cpu_usage"] as? Double) ?? 0
            report.expect(
                "stats.enginePrimesSample0", previousSystem == 0,
                "document 0 of stats?stream=1 has precpu_stats.system_cpu_usage="
                    + "\(precpu?["system_cpu_usage"] == nil ? "absent" : "\(previousSystem)")"
                    + " — a baseline, not a reading")

            // What that document would have claimed, had it been yielded: the container's
            // whole lifetime divided by the host's whole accumulated CPU time, wearing a
            // one-second reading's clothes.
            let cpu = raw["cpu_stats"] as? [String: Any]
            let total = ((cpu?["cpu_usage"] as? [String: Any])?["total_usage"] as? Double) ?? 0
            let system = (cpu?["system_cpu_usage"] as? Double) ?? 0
            if previousSystem == 0, system > 0 {
                let naive = total / system * Double(cores) * 100
                primingPercent = naive
                report.note(
                    "sample 0 would have reported \(String(format: "%.4f", naive))% "
                        + "(\(String(format: "%.1f", total / 1e9))s of container CPU over "
                        + "\(String(format: "%.0f", system / 1e9))s of host CPU)")
            }
        } catch {
            report.fail("stats.enginePrimesSample0", "could not read document 0: \(error)")
        }

        // Latency to the *first* sample is the observable proof that the baseline was
        // dropped. The engine answers a stats stream immediately and then resamples once
        // a second, so a client that yields document 0 produces a first sample in well
        // under a quarter second, and a client that drops it cannot beat about one.
        let firstProbe = Date()
        let firstSink = await drain(docker.stats(id: logger.id), until: { $0.count >= 1 }, timeout: 15)
        let firstLatency = Date().timeIntervalSince(firstProbe)
        report.expect(
            "stats.dropsSample0", !firstSink.snapshot.isEmpty && firstLatency >= 0.4,
            firstSink.snapshot.isEmpty
                ? "no sample within 15s\(firstSink.error.map { " — \($0)" } ?? "")"
                : "first sample after \(String(format: "%.2f", firstLatency))s "
                    + "(≥0.4s means the baseline document was swallowed rather than yielded)")

        let wanted = 3
        let sink = await drain(
            docker.stats(id: logger.id),
            until: { $0.count >= wanted },
            timeout: 30)
        let samples = sink.snapshot

        report.expect(
            "stats.samples", samples.count >= wanted,
            "\(samples.count) samples in 30s\(sink.error.map { ", error: \($0)" } ?? "")")
        guard !samples.isEmpty else { return }

        for (index, sample) in samples.prefix(wanted).enumerated() {
            report.note(
                "\(index): cpu=\(String(format: "%.3f", sample.cpuPercent))% "
                    + "mem=\(sample.memBytes) limit=\(sample.memLimit) "
                    + "memFraction=\(String(format: "%.4f", sample.memFraction)) ts=\(sample.ts)")
        }

        let ceiling = 100.0 * Double(cores)
        let bad = samples.filter { !$0.cpuPercent.isFinite || $0.cpuPercent < 0 || $0.cpuPercent > ceiling }
        report.expect(
            "stats.cpuFinite", bad.isEmpty,
            bad.isEmpty
                ? "all \(samples.count) samples in 0…\(Int(ceiling))%, values="
                    + samples.map { String(format: "%.3f", $0.cpuPercent) }.joined(separator: ", ")
                : "out of range: \(bad.map { "\($0.cpuPercent)" }.joined(separator: ", "))")

        report.expect(
            "stats.memPositive", samples.allSatisfy { $0.memBytes > 0 },
            "memBytes=" + samples.map { "\($0.memBytes)" }.joined(separator: ", "))
        report.expect(
            "stats.memLimit", samples.allSatisfy { $0.memLimit > 0 && $0.memBytes <= $0.memLimit },
            "limit=\(samples[0].memLimit) usage≤limit="
                + "\(samples.allSatisfy { $0.memBytes <= $0.memLimit })")

        // Docker resamples once a second; identical timestamps across samples would mean
        // the same JSON document was decoded twice.
        let stamps = Set(samples.map(\.ts))
        report.expect(
            "stats.distinctSamples", stamps.count == samples.count,
            "\(stamps.count) distinct read timestamps across \(samples.count) samples")
        report.expect(
            "stats.timestampParsed", samples.allSatisfy { $0.ts != .distantPast },
            "first read=\(samples[0].ts)")

        // The classic first-sample trap: `precpu_stats` is empty on sample one, so a
        // naive delta divides by a system total measured from zero and reports the
        // container's whole lifetime as if it happened in one interval.
        if samples.count >= 2 {
            report.expect(
                "stats.firstSampleSane", samples[0].cpuPercent <= ceiling,
                "sample0=\(String(format: "%.3f", samples[0].cpuPercent))% "
                    + "sample1=\(String(format: "%.3f", samples[1].cpuPercent))%")
        }

        // And the sharper form: whatever the first delivered sample is, it must not be
        // the lifetime average the baseline document would have produced. The two are
        // only equal if the baseline leaked through — a genuine interval reading landing
        // on that number to six decimal places does not happen.
        if let priming = primingPercent, let first = samples.first {
            report.expect(
                "stats.notALifetimeAverage", abs(first.cpuPercent - priming) > 1e-6,
                "first delivered=\(String(format: "%.6f", first.cpuPercent))% "
                    + "baseline would have been \(String(format: "%.6f", priming))%")
        }
    }

    // MARK: - Events

    static func checkEvents(
        _ report: Report, _ docker: DockerClient, _ containers: [ContainerSummary], _ fixtures: Fixtures
    ) async {
        report.section("events()")
        guard let target = find(fixtures.exit, in: containers, report, check: "events") else { return }

        let sink = Sink<DockerEvent>()
        let id = target.id

        // The stream has to be live *before* the action that should show up in it, so it
        // is drained on its own task and the lifecycle calls happen underneath.
        let reader = Task {
            await drain(
                docker.events(),
                into: sink,
                until: { events in
                    let mine = events.filter { $0.actorID == id }
                    return mine.contains { $0.action == "start" } && mine.contains { $0.action == "die" }
                },
                // Generous because the stop underneath takes the engine's full t=10 to
                // land; the predicate above ends this early on a healthy run, so the
                // number only decides how long a *broken* stream is given to prove it.
                timeout: 40)
        }

        // A beat for the socket to be accepted; without it the start can precede the
        // engine's first read and the event is genuinely never sent to us.
        try? await Task.sleep(nanoseconds: 750_000_000)

        let startedAt = Date()
        do {
            try await docker.startContainer(id: id)
            report.expect("events.startAction", true, "startContainer(\(target.shortID)) returned")
        } catch {
            report.fail("events.startAction", "startContainer threw \(error)")
        }

        // Give the start event its 5 s before asking for the stop, so the two deadlines
        // are measured separately rather than sharing one budget.
        let startDeadline = startedAt.addingTimeInterval(5)
        while Date() < startDeadline,
              !sink.snapshot.contains(where: { $0.actorID == id && $0.action == "start" }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let startLatency = Date().timeIntervalSince(startedAt)
        let sawStart = sink.snapshot.contains { $0.actorID == id && $0.action == "start" }
        report.expect(
            "events.start", sawStart,
            sawStart
                ? "container/start for \(target.shortID) after \(String(format: "%.2f", startLatency))s"
                : "no start event within 5s (\(sink.snapshot.count) events seen)")

        let stoppedAt = Date()
        do {
            try await docker.stopContainer(id: id)
        } catch {
            report.note("stopContainer threw \(error) — the fixture may have exited on its own")
        }

        // The grace period is measured from when the *stop returns*, not from when it was
        // issued. `/containers/{id}/stop?t=10` blocks until the container is actually
        // dead, and the fixture is `sleep`, which installs no SIGTERM handler — so as
        // PID 1 it ignores the term entirely and the engine has to wait out the full ten
        // seconds before the SIGKILL. Starting a five-second window before that call is
        // asking whether the event arrived before the thing that causes it happened; the
        // window closes with time to spare and the check fails on a healthy engine.
        let stopReturnedAt = Date()
        report.note(
            "stopContainer returned after \(String(format: "%.2f", stopReturnedAt.timeIntervalSince(stoppedAt)))s "
                + "(the fixture ignores SIGTERM, so the engine waits out t=10 and SIGKILLs)")

        let stopDeadline = stopReturnedAt.addingTimeInterval(5)
        while Date() < stopDeadline,
              !sink.snapshot.contains(where: { $0.actorID == id && $0.action == "die" }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stopLatency = Date().timeIntervalSince(stopReturnedAt)
        let sawDie = sink.snapshot.contains { $0.actorID == id && $0.action == "die" }
        report.expect(
            "events.stop", sawDie,
            sawDie
                ? "container/die for \(target.shortID) \(String(format: "%.2f", stopLatency))s after stop returned"
                : "no die event within 5s of the stop returning (\(sink.snapshot.count) events seen)")

        reader.cancel()
        _ = await reader.result

        let events = sink.snapshot
        report.note(
            "events: "
                + clip(events.map { "\($0.type)/\($0.action)" }.joined(separator: " "), 200))

        let allowed: Set<String> = ["container", "image", "volume", "network"]
        let strays = events.filter { !allowed.contains($0.type) }
        report.expect(
            "events.filtered", strays.isEmpty,
            strays.isEmpty
                ? "\(events.count) events, all within \(allowed.sorted().joined(separator: "/"))"
                : "unfiltered types: \(Set(strays.map(\.type)).sorted().joined(separator: ", "))")

        let now = Date()
        let skewed = events.filter { abs($0.time.timeIntervalSince(now)) > 300 }
        report.expect(
            "events.timestamps", skewed.isEmpty && !events.isEmpty,
            events.isEmpty
                ? "no events to check"
                : "\(events.count) events within ±5min of now; first=\(events[0].time)")

        let lifecycle = events.filter(\.isContainerLifecycle)
        report.expect(
            "events.lifecycleFlag", !lifecycle.isEmpty,
            "\(lifecycle.count)/\(events.count) events classified as container lifecycle")
    }
}

/// Facts about the fixtures that both the harness and the script have to agree on.
enum LiveWorkload {
    /// How many filler characters the logger's oversized line carries. Chosen larger
    /// than the 64 KiB read buffer's typical delivery size so the line is guaranteed to
    /// span reads, which is the case stdcopy reassembly gets wrong.
    static let longLineLength = 20_000
}
