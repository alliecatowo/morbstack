// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deterministic Docker world for fixture-backed app runs and data diagnostics.
//
// Everything here is built to the shape the engine actually returns — 64-hex container
// ids, `sha256:`-prefixed image ids, Compose labels, and inspect documents that take the
// same Docker-client path as a live run.  The fixtures are intentionally presentation
// independent: they support live-window review and future UI tests, but never emulate a
// view hierarchy or macOS chrome.
//
// Ages are relative to "now" so date formatting remains natural in an interactive
// fixture window; identities and quantities stay stable enough for invariant checks.

import Foundation

enum ShotFixtures {

    // MARK: - Clock

    private static let now = Date()

    private static func ago(minutes: Double = 0, hours: Double = 0, days: Double = 0) -> Date {
        now.addingTimeInterval(-(minutes * 60 + hours * 3600 + days * 86_400))
    }

    /// RFC 3339 with nine fractional digits, the way the engine stamps inspect documents.
    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: date)
        // `2026-08-02T04:11:07Z` → `2026-08-02T04:11:07.412938174Z`
        return whole.replacingOccurrences(of: "Z", with: ".412938174Z")
    }

    // MARK: - Identifiers

    /// A stable 64-hex container id derived from a seed, so ids look like ids and never
    /// change between runs.
    private static func containerID(_ seed: String) -> String {
        hex(seed: seed, length: 64)
    }

    private static func imageID(_ seed: String) -> String {
        "sha256:" + hex(seed: seed, length: 64)
    }

    /// A deterministic hex string. A tiny xorshift rather than a hash function so the
    /// output is identical on every platform and every run.
    private static func hex(seed: String, length: Int) -> String {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        for byte in seed.utf8 {
            state ^= UInt64(byte)
            state = state &* 0x0100_0000_01B3
        }
        var out = ""
        out.reserveCapacity(length)
        while out.count < length {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            out += String(format: "%016lx", state)
        }
        return String(out.prefix(length))
    }

    // MARK: - Containers

    /// Eleven containers: nine across two Compose projects, one standalone container in
    /// a crash loop, and one paused.  Together they cover the operational states a
    /// caller needs to exercise: running, unhealthy, exited, restarting, and paused.
    static let containers: [ContainerSummary] = [
        make(
            name: "shopfront-web-1",
            image: "nginx:1.27-alpine",
            state: "running",
            status: "Up 3 days",
            project: "shopfront",
            service: "web",
            ports: [
                port(host: 8080, container: 80),
                port(host: 8443, container: 443),
            ],
            created: ago(days: 3.1)),
        make(
            name: "shopfront-api-1",
            image: "shopfront/api:2.11.4",
            state: "running",
            status: "Up 3 days (healthy)",
            project: "shopfront",
            service: "api",
            ports: [port(host: 3001, container: 3000)],
            created: ago(days: 3.1)),
        make(
            name: "shopfront-worker-1",
            image: "shopfront/api:2.11.4",
            state: "running",
            status: "Up 47 minutes",
            project: "shopfront",
            service: "worker",
            ports: [],
            created: ago(days: 3.1)),
        make(
            name: "shopfront-redis-1",
            image: "redis:7.4-alpine",
            state: "running",
            status: "Up 3 days",
            project: "shopfront",
            service: "redis",
            ports: [port(host: 6379, container: 6379)],
            created: ago(days: 3.1)),
        make(
            name: "shopfront-postgres-1",
            image: "postgres:16.4-alpine",
            state: "running",
            status: "Up 12 days (healthy)",
            project: "shopfront",
            service: "postgres",
            ports: [port(host: 5432, container: 5432)],
            created: ago(days: 12.4)),
        make(
            name: "analytics-grafana-1",
            image: "grafana/grafana:11.2.0",
            state: "running",
            status: "Up 6 hours",
            project: "analytics",
            service: "grafana",
            ports: [port(host: 3000, container: 3000)],
            created: ago(hours: 6.2)),
        make(
            name: "analytics-clickhouse-1",
            image: "clickhouse/clickhouse-server:24.8",
            state: "running",
            status: "Up 6 hours (healthy)",
            project: "analytics",
            service: "clickhouse",
            ports: [
                port(host: 8123, container: 8123),
                port(host: 9000, container: 9000),
                port(host: nil, container: 9009),
            ],
            created: ago(hours: 6.2)),
        make(
            name: "analytics-vector-1",
            image: "timberio/vector:0.40.0-alpine",
            state: "running",
            status: "Up 6 hours",
            project: "analytics",
            service: "vector",
            ports: [port(host: 8686, container: 8686)],
            created: ago(hours: 6.2)),
        make(
            name: "analytics-etl-1",
            image: "analytics/etl:0.9.3",
            state: "exited",
            status: "Exited (0) 2 hours ago",
            project: "analytics",
            service: "etl",
            ports: [],
            created: ago(hours: 8.5)),
        make(
            name: "registry-mirror",
            image: "registry:2.8.3",
            state: "restarting",
            status: "Restarting (1) 14 seconds ago (unhealthy)",
            project: nil,
            service: nil,
            ports: [port(host: 5001, container: 5000)],
            created: ago(days: 1.2)),
        make(
            name: "legacy-jenkins",
            image: "jenkins/jenkins:2.462-lts",
            state: "paused",
            status: "Up 9 days (Paused)",
            project: nil,
            service: nil,
            ports: [
                port(host: 8090, container: 8080),
                port(host: 50_000, container: 50_000),
            ],
            created: ago(days: 9.3)),
        // Kubernetes' own dockershim containers, named exactly the way a kubelet
        // names them. They exist so the Containers route's collapsed
        // Kubernetes-Managed group is a fixture-visible surface: any machine with
        // the bundled cluster enabled has rows like these.
        make(
            name: "k8s_coredns_coredns-7f9c69d9d8-4wqxr_kube-system_1c1c86b5-90a4-4e6f-a2d8-6a70428f6a9f_0",
            image: "rancher/mirrored-coredns-coredns:1.11.1",
            state: "running",
            status: "Up 2 days",
            project: nil,
            service: nil,
            ports: [],
            created: ago(days: 2.1),
            kubernetesManaged: true),
        make(
            name: "k8s_POD_coredns-7f9c69d9d8-4wqxr_kube-system_1c1c86b5-90a4-4e6f-a2d8-6a70428f6a9f_0",
            image: "registry.k8s.io/pause:3.10",
            state: "running",
            status: "Up 2 days",
            project: nil,
            service: nil,
            ports: [],
            created: ago(days: 2.1),
            kubernetesManaged: true),
    ]

    private static func make(
        name: String,
        image: String,
        state: String,
        status: String,
        project: String?,
        service: String?,
        ports: [PortMapping],
        created: Date,
        kubernetesManaged: Bool = false
    ) -> ContainerSummary {
        ContainerSummary(
            id: containerID(name),
            names: [name],
            displayName: name,
            image: image,
            state: state,
            status: status,
            composeProject: project,
            composeService: service,
            ports: ports,
            createdAt: created,
            isKubernetesManaged: kubernetesManaged)
    }

    private static func port(host: Int?, container: Int, proto: String = "tcp") -> PortMapping {
        PortMapping(
            hostIP: host == nil ? nil : "0.0.0.0",
            hostPort: host,
            containerPort: container,
            proto: proto)
    }

    /// Looks a container up by name. Traps rather than returning `nil`: every call site
    /// is a literal in this file, so a miss is a typo and should stop fixture use
    /// immediately rather than silently hiding inconsistent data.
    static func container(_ name: String) -> ContainerSummary {
        guard let found = containers.first(where: { $0.displayName == name }) else {
            fatalError("no fixture container named \(name)")
        }
        return found
    }

    // MARK: - Images

    /// Every image a machine running the fixture containers would actually have.
    ///
    /// In particular, an image referenced by a container must also be present here. The
    /// fixture diagnostics assert that relationship rather than relying on a rendered
    /// surface to expose an inconsistent data set.
    static let images: [ImageSummary] = [
        image("postgres:16.4-alpine", size: 274_853_888, created: ago(days: 21), using: 1),
        image("clickhouse/clickhouse-server:24.8", size: 1_143_996_416, created: ago(days: 9), using: 1),
        image("grafana/grafana:11.2.0", size: 612_368_384, created: ago(days: 9), using: 1),
        image("shopfront/api:2.11.4", size: 421_527_552, created: ago(days: 3.1), using: 2),
        image("node:22-alpine", size: 168_820_736, created: ago(days: 16), using: 0),
        image("nginx:1.27-alpine", size: 51_249_152, created: ago(days: 6), using: 1),
        image("redis:7.4-alpine", size: 41_156_608, created: ago(days: 6), using: 1),
        image("timberio/vector:0.40.0-alpine", size: 128_974_848, created: ago(days: 11), using: 1),
        image("analytics/etl:0.9.3", size: 342_884_352, created: ago(days: 5), using: 1),
        image("jenkins/jenkins:2.462-lts", size: 1_492_869_120, created: ago(days: 24), using: 1),
        image("registry:2.8.3", size: 25_690_112, created: ago(days: 30), using: 1),
        image("traefik:v3.1", size: 179_306_496, created: ago(days: 12), using: 0),
        image("python:3.12-slim", size: 130_023_424, created: ago(days: 28), using: 0),
        image("alpine:3.20", size: 8_413_184, created: ago(days: 34), using: 0),
        image("busybox:1.36", size: 4_509_696, created: ago(days: 61), using: 0),
        image("hello-world:latest", size: 20_480, created: ago(days: 112), using: 0),
        // Referenced by the kubelet-managed fixture containers; the fixture
        // diagnostics require every referenced image to have a tagged record.
        image("rancher/mirrored-coredns-coredns:1.11.1", size: 71_303_168, created: ago(days: 57), using: 1),
        image("registry.k8s.io/pause:3.10", size: 514_048, created: ago(days: 57), using: 1),
        image(nil, size: 1_121_976_320, created: ago(days: 2), using: 0, seed: "dangling-a"),
        image(nil, size: 779_845_632, created: ago(hours: 20), using: 0, seed: "dangling-b"),
    ]

    private static func image(
        _ tag: String?, size: Int64, created: Date, using: Int, seed: String? = nil
    ) -> ImageSummary {
        ImageSummary(
            id: imageID(seed ?? tag ?? "?"),
            repoTags: tag.map { [$0] } ?? ["<none>:<none>"],
            size: size,
            createdAt: created,
            containersUsing: using)
    }

    // MARK: - Volumes

    static let volumes: [VolumeSummary] = [
        volume("shopfront_pgdata", size: 2_411_724_800, refCount: 1),
        volume("shopfront_uploads", size: 3_221_225_472, refCount: 1),
        volume("shopfront_redis_appendonly", size: 18_874_368, refCount: 1),
        volume("analytics_clickhouse_data", size: 1_889_465_344, refCount: 1),
        volume("analytics_clickhouse_logs", size: 268_435_456, refCount: 1),
        volume("analytics_grafana_storage", size: 96_468_992, refCount: 1),
        volume("morb_registry_data", size: 1_073_741_824, refCount: 1),
        volume("jenkins_home", size: 1_402_994_688, refCount: 0),
        volume("jenkins_docker_certs", size: 4_194_304, refCount: 0),
        volume("pgdata_backup_2026_07", size: 1_932_735_283, refCount: 0),
        volume(hex(seed: "anon-vol-1", length: 64), size: 641_728_512, refCount: 0),
        volume(hex(seed: "anon-vol-2", length: 64), size: 212_860_928, refCount: 0),
        volume(hex(seed: "anon-vol-3", length: 64), size: 88_080_384, refCount: 0),
    ]

    private static func volume(_ name: String, size: Int64, refCount: Int) -> VolumeSummary {
        VolumeSummary(
            name: name,
            driver: "local",
            mountpoint: "/var/lib/docker/volumes/\(name)/_data",
            size: size,
            refCount: refCount)
    }

    // MARK: - Networks

    static let networks: [NetworkSummary] = [
        network("bridge", driver: "bridge", containers: 2),
        network("host", driver: "host", containers: 0),
        network("none", driver: "null", containers: 0),
        network("shopfront_default", driver: "bridge", containers: 5),
        network("shopfront_edge", driver: "bridge", containers: 2),
        network("analytics_default", driver: "bridge", containers: 4),
        network("analytics_internal", driver: "bridge", containers: 2),
        network("morb-ingress", driver: "bridge", containers: 1),
        network("kind", driver: "bridge", containers: 0),
    ]

    private static func network(_ name: String, driver: String, containers: Int) -> NetworkSummary {
        NetworkSummary(
            id: hex(seed: "net-" + name, length: 64),
            name: name,
            driver: driver,
            scope: driver == "host" ? "local" : "local",
            containers: containers)
    }

    static func networkInspection(id: String) -> NetworkInspection? {
        guard let network = networks.first(where: { $0.id == id }) else { return nil }
        let members = containers.prefix(network.containers).map { container in
            NetworkInspection.Member(
                id: container.id,
                name: container.displayName,
                endpointID: hex(seed: "endpoint-\(network.id)-\(container.id)", length: 64),
                macAddress: nil,
                ipv4Address: nil,
                ipv6Address: nil,
                aliases: [])
        }
        // Only the two Compose-default fixtures have Compose metadata. Giving the
        // Docker-managed `bridge` network a made-up `com.docker.compose.project=bridge`
        // label would defeat fixture mode's purpose: it must exercise the actual inspect
        // shape without inventing a plausible story around it.
        let defaultSuffix = "_default"
        let composeProject = network.name.hasSuffix(defaultSuffix)
            ? String(network.name.dropLast(defaultSuffix.count))
            : nil
        let labels: [NetworkInspection.KeyValue] = composeProject.map {
            [
                .init(key: "com.docker.compose.network", value: "default"),
                .init(key: "com.docker.compose.project", value: $0),
            ]
        } ?? []
        return NetworkInspection(
            id: network.id,
            name: network.name,
            driver: network.driver,
            scope: network.scope,
            enableIPv6: false,
            isInternal: network.name.contains("internal"),
            isAttachable: false,
            isIngress: false,
            isConfigOnly: false,
            configFrom: nil,
            ipamDriver: network.driver == "bridge" ? "default" : nil,
            ipamConfigurations: network.driver == "bridge"
                ? [.init(
                    subnet: "172.28.0.0/16",
                    gateway: "172.28.0.1",
                    ipRange: nil,
                    auxiliaryAddresses: [])]
                : [],
            options: network.driver == "bridge"
                ? [.init(key: "com.docker.network.bridge.enable_icc", value: "true")]
                : [],
            labels: labels,
            members: members)
    }

    // MARK: - Disk

    /// Derived from the lists above rather than typed out beside them.
    ///
    /// The totals derive from the individual records. A hand-written aggregate that
    /// disagrees with its source collection is a bad fixture regardless of the consumer,
    /// so `FixtureDiagnostics` verifies those relationships directly.
    ///
    /// The two figures that *are* invented are the ones the engine reports and no list
    /// can reproduce: build-cache bytes and the cache share of reclaimable storage.
    static let disk: DiskUsage = {
        let imagesTotal = images.reduce(Int64(0)) { $0 + $1.size }
        let volumesTotal = volumes.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let containersTotal: Int64 = 1_356_857_344
        let buildCacheTotal: Int64 = 3_607_101_440

        let danglingBytes = images
            .filter(\.isDangling)
            .reduce(Int64(0)) { $0 + $1.size }
        let unusedVolumeBytes = volumes
            .filter(\.isUnused)
            .reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        // A conservative count-weighted estimate for stopped containers.
        let stoppedShare = Double(containers.filter { !$0.isRunning }.count)
            / Double(max(1, containers.count))
        let containerBytes = Int64(Double(containersTotal) * stoppedShare)
        let cacheReclaimable: Int64 = 1_593_835_520

        return DiskUsage(
            // Shared base layers are counted once, so what is on disk is meaningfully
            // less than the sum of the image sizes — the point the footnote makes.
            layersSize: Int64(Double(imagesTotal) * 0.74),
            imagesTotal: imagesTotal,
            volumesTotal: volumesTotal,
            buildCacheTotal: buildCacheTotal,
            containersTotal: containersTotal,
            reclaimable: danglingBytes + unusedVolumeBytes + containerBytes + cacheReclaimable)
    }()

    // MARK: - Build cache

    static let buildCache: [BuildCacheRecord] = [
        BuildCacheRecord(
            id: "a3f9c2e1b8d4f6a2", description: "RUN pip install -r requirements.txt",
            type: "regular", size: 412_090_368, inUse: true, shared: false,
            createdAt: Date(timeIntervalSinceNow: -3 * 86_400), lastUsedAt: Date(timeIntervalSinceNow: -3_600),
            usageCount: 6),
        BuildCacheRecord(
            id: "c7b1d4e9a2f8c3b6", description: "COPY . /app",
            type: "regular", size: 89_128_960, inUse: true, shared: false,
            createdAt: Date(timeIntervalSinceNow: -3 * 86_400), lastUsedAt: Date(timeIntervalSinceNow: -3_600),
            usageCount: 6),
        BuildCacheRecord(
            id: "f2e8a6c4b9d1e7f3", description: "docker-image://docker.io/library/node:22-alpine",
            type: "source.local", size: 46_137_344, inUse: true, shared: true,
            createdAt: Date(timeIntervalSinceNow: -9 * 86_400), lastUsedAt: Date(timeIntervalSinceNow: -3_600),
            usageCount: 14),
        BuildCacheRecord(
            id: "9d4b6a1c8e3f2d7a", description: "RUN npm run build",
            type: "regular", size: 1_207_959_552, inUse: false, shared: false,
            createdAt: Date(timeIntervalSinceNow: -6 * 86_400), lastUsedAt: Date(timeIntervalSinceNow: -2 * 86_400),
            usageCount: 3),
        BuildCacheRecord(
            id: "5e1a7c3f9b2d6e4a", description: "RUN apt-get update && apt-get install -y build-essential",
            type: "regular", size: 318_767_104, inUse: false, shared: false,
            createdAt: Date(timeIntervalSinceNow: -21 * 86_400), lastUsedAt: Date(timeIntervalSinceNow: -14 * 86_400),
            usageCount: 2),
        BuildCacheRecord(
            id: "b8c2e6a4d9f1b7c3", description: "mount cache /root/.cache/go-build",
            type: "exec.cachemount", size: 892_338_176, inUse: false, shared: false,
            createdAt: Date(timeIntervalSinceNow: -12 * 86_400), lastUsedAt: Date(timeIntervalSinceNow: -5 * 86_400),
            usageCount: 8),
    ]

    // MARK: - Engine

    static let engineRunning = EngineStatus(
        state: "running", vmState: "running", version: "0.4.2", reachable: true)

    static let engineStopped = EngineStatus(
        state: "stopped", vmState: "not running", version: nil, reachable: false)

    // MARK: - Stats

    /// A believable CPU/memory series for a container.
    ///
    /// Deterministic: a fixed pseudo-random walk with a per-container seed, so every run
    /// draws the same sparkline. Shaped rather than uniform — a slow sine plus jitter
    /// plus the occasional spike — because a flat band of noise reads as a broken chart
    /// and a clean sine reads as a fake one.
    static func stats(
        for name: String,
        cpuBase: Double,
        cpuSwing: Double,
        memBase: Int64,
        memSwing: Int64,
        memLimit: Int64,
        count: Int = 60
    ) -> [StatsSample] {
        var state = UInt64(truncatingIfNeeded: name.utf8.reduce(7) { $0 &* 31 &+ Int($1) })
        func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 10_000) / 10_000
        }

        var samples: [StatsSample] = []
        for index in 0..<count {
            let phase = Double(index) / Double(count) * .pi * 3.1
            let wave = (sin(phase) + 1) / 2
            let jitter = next() - 0.5
            let spike = next() > 0.94 ? next() * 0.8 : 0

            let cpu = max(0.2, cpuBase + cpuSwing * (wave * 0.7 + jitter * 0.5 + spike))
            let memWave = wave * 0.6 + next() * 0.4
            let mem = memBase + Int64(Double(memSwing) * memWave)

            samples.append(
                StatsSample(
                    cpuPercent: cpu,
                    memBytes: mem,
                    memLimit: memLimit,
                    ts: ago(minutes: Double(count - index) * (2.0 / 60.0))))
        }
        return samples
    }

    /// The per-container time series available to fixture-backed runs.  The data is
    /// useful to chart/accessibility tests but is not rendered by this module.
    static let statsByContainer: [(name: String, samples: [StatsSample])] = [
        ("shopfront-web-1", stats(for: "web", cpuBase: 1.2, cpuSwing: 6, memBase: 24_117_248, memSwing: 8_388_608, memLimit: 2_147_483_648)),
        ("shopfront-api-1", stats(for: "api", cpuBase: 8, cpuSwing: 34, memBase: 268_435_456, memSwing: 96_468_992, memLimit: 1_073_741_824)),
        ("shopfront-worker-1", stats(for: "worker", cpuBase: 22, cpuSwing: 48, memBase: 402_653_184, memSwing: 121_634_816, memLimit: 1_073_741_824)),
        ("shopfront-redis-1", stats(for: "redis", cpuBase: 0.6, cpuSwing: 3, memBase: 12_582_912, memSwing: 3_145_728, memLimit: 536_870_912)),
        ("shopfront-postgres-1", stats(for: "postgres", cpuBase: 3, cpuSwing: 14, memBase: 184_549_376, memSwing: 41_943_040, memLimit: 2_147_483_648)),
        ("analytics-grafana-1", stats(for: "grafana", cpuBase: 2, cpuSwing: 9, memBase: 96_468_992, memSwing: 20_971_520, memLimit: 1_073_741_824)),
        // A wide memory swing on purpose: this is the container the Stats tab is
        // photographed on, and a database whose resident set moves by 400 MB inside a
        // 4 GiB limit draws a chart indistinguishable from a ruled line.
        ("analytics-clickhouse-1", stats(for: "clickhouse", cpuBase: 12, cpuSwing: 61, memBase: 1_181_116_006, memSwing: 1_073_741_824, memLimit: 4_294_967_296)),
        ("analytics-vector-1", stats(for: "vector", cpuBase: 4, cpuSwing: 11, memBase: 58_720_256, memSwing: 12_582_912, memLimit: 536_870_912)),
    ]

    // MARK: - Inspect documents

    /// A full, pretty-printed inspect document for one fixture container.
    ///
    /// Pretty-printed by `JSONSerialization` exactly the way `DockerClient
    /// .inspectContainer(id:)` does it, so the Inspect tab's line count, colouring and
    /// search behave identically to the live app's.
    static func inspectJSON(for container: ContainerSummary) -> String {
        let object = inspectObject(for: container)
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func inspectObject(for container: ContainerSummary) -> [String: Any] {
        let running = container.state == "running"
        let started = container.createdAt.addingTimeInterval(4)
        let finished = container.state == "exited" ? ago(hours: 2) : nil

        var state: [String: Any] = [
            "Status": container.state,
            "Running": running,
            "Paused": container.state == "paused",
            "Restarting": container.state == "restarting",
            "OOMKilled": false,
            "Dead": false,
            "Pid": running ? 12_884 : 0,
            "ExitCode": container.state == "exited" ? 0 : (container.state == "restarting" ? 1 : 0),
            "Error": "",
            "StartedAt": rfc3339(started),
            "FinishedAt": finished.map(rfc3339) ?? "0001-01-01T00:00:00Z",
        ]
        if let health = health(for: container) {
            state["Health"] = [
                "Status": health,
                "FailingStreak": health == "unhealthy" ? 4 : 0,
                "Log": [],
            ]
        }

        var labels: [String: String] = [
            "org.opencontainers.image.vendor": "Morbstack demo fixtures",
        ]
        if let project = container.composeProject, let service = container.composeService {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service
            labels["com.docker.compose.version"] = "2.29.2"
            labels["com.docker.compose.config-hash"] = hex(seed: project + service, length: 64)
            labels["com.docker.compose.project.working_dir"] = "/Users/ada/src/\(project)"
        }

        var networks: [String: Any] = [:]
        for name in networkNames(for: container) {
            networks[name] = [
                "NetworkID": hex(seed: "net-" + name, length: 64),
                "EndpointID": hex(seed: "ep-" + name + container.displayName, length: 64),
                "Gateway": "172.19.0.1",
                "IPAddress": "172.19.0.\(2 + abs(container.displayName.hashValue % 40))",
                "IPPrefixLen": 16,
                "MacAddress": "02:42:ac:13:00:0b",
                "Aliases": [container.composeService ?? container.displayName],
            ]
        }

        let (path, args) = commandLine(for: container)

        return [
            "Id": container.id,
            "Created": rfc3339(container.createdAt),
            "Path": path,
            "Args": args,
            "Name": "/" + container.displayName,
            "Image": imageID(container.image),
            "Platform": "linux/arm64",
            "RestartCount": container.state == "restarting" ? 27 : 0,
            "Driver": "overlay2",
            "State": state,
            "Config": [
                "Hostname": String(container.id.prefix(12)),
                "User": user(for: container),
                "Tty": false,
                "OpenStdin": false,
                "Image": container.image,
                "WorkingDir": workingDir(for: container),
                "Entrypoint": entrypoint(for: container),
                "Cmd": args,
                "Env": environment(for: container),
                "Labels": labels,
                "ExposedPorts": Dictionary(
                    uniqueKeysWithValues: container.ports.map { ("\($0.containerPort)/\($0.proto)", [String: Any]()) }),
            ],
            "HostConfig": [
                "NetworkMode": container.composeProject.map { $0 + "_default" } ?? "bridge",
                "RestartPolicy": [
                    "Name": container.state == "restarting" ? "always" : "unless-stopped",
                    "MaximumRetryCount": 0,
                ],
                "Memory": 0,
                "NanoCpus": 0,
                "Privileged": false,
                "ReadonlyRootfs": false,
            ],
            "Mounts": mounts(for: container),
            "NetworkSettings": [
                "Networks": networks,
                "Ports": Dictionary(
                    uniqueKeysWithValues: container.ports.map { mapping -> (String, Any) in
                        let key = "\(mapping.containerPort)/\(mapping.proto)"
                        guard let host = mapping.hostPort else { return (key, NSNull()) }
                        return (key, [["HostIp": "0.0.0.0", "HostPort": "\(host)"]])
                    }),
            ],
        ]
    }

    private static func health(for container: ContainerSummary) -> String? {
        if container.isUnhealthy { return "unhealthy" }
        if container.status.contains("(healthy)") { return "healthy" }
        return nil
    }

    private static func networkNames(for container: ContainerSummary) -> [String] {
        guard let project = container.composeProject else { return ["bridge"] }
        if container.composeService == "web" { return [project + "_default", "morb-ingress"] }
        return [project + "_default"]
    }

    private static func commandLine(for container: ContainerSummary) -> (String, [String]) {
        switch container.composeService ?? container.displayName {
        case "web": return ("/docker-entrypoint.sh", ["nginx", "-g", "daemon off;"])
        case "api": return ("docker-entrypoint.sh", ["node", "dist/server.js"])
        case "worker": return ("docker-entrypoint.sh", ["node", "dist/worker.js", "--queue", "orders"])
        case "redis": return ("docker-entrypoint.sh", ["redis-server", "--appendonly", "yes"])
        case "postgres": return ("docker-entrypoint.sh", ["postgres"])
        case "grafana": return ("/run.sh", [])
        case "clickhouse": return ("/entrypoint.sh", [])
        case "vector": return ("/usr/local/bin/vector", ["--config", "/etc/vector/vector.yaml"])
        case "etl": return ("python", ["-m", "etl.run", "--since", "2026-07-31T00:00:00Z"])
        case "registry-mirror": return ("/entrypoint.sh", ["/etc/docker/registry/config.yml"])
        default: return ("/usr/bin/tini", ["--", "/usr/local/bin/jenkins.sh"])
        }
    }

    private static func entrypoint(for container: ContainerSummary) -> [String] {
        [commandLine(for: container).0]
    }

    private static func workingDir(for container: ContainerSummary) -> String {
        switch container.composeService ?? container.displayName {
        case "api", "worker": return "/srv/app"
        case "etl": return "/opt/etl"
        case "legacy-jenkins": return "/var/jenkins_home"
        default: return ""
        }
    }

    private static func user(for container: ContainerSummary) -> String {
        switch container.composeService ?? container.displayName {
        case "api", "worker": return "node"
        case "postgres": return "postgres"
        case "legacy-jenkins": return "jenkins"
        default: return ""
        }
    }

    /// Environment blocks with the mix a real container has: baseline PATH entries,
    /// service configuration, and deliberately fake credentials for redaction behavior.
    private static func environment(for container: ContainerSummary) -> [String] {
        let base = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
        switch container.composeService ?? container.displayName {
        case "web":
            return base + [
                "NGINX_VERSION=1.27.1",
                "NJS_VERSION=0.8.5",
                "PKG_RELEASE=1",
                "UPSTREAM_API=http://api:3000",
                "TLS_CERT_PATH=/etc/nginx/certs/shopfront.crt",
            ]
        case "api":
            return base + [
                "NODE_VERSION=22.7.0",
                "NODE_ENV=production",
                "PORT=3000",
                "DATABASE_URL=postgres://shopfront:hunter2@postgres:5432/shopfront",
                "REDIS_URL=redis://redis:6379/0",
                "SESSION_SECRET=9c1f4b7ae2d84f0fa61c3d5e77b2a094",
                "STRIPE_API_KEY=sk_live_51Nq8fLK2mQpZ3xVb7YdT",
                "OTEL_EXPORTER_OTLP_ENDPOINT=http://vector:4317",
                "LOG_LEVEL=info",
            ]
        case "worker":
            return base + [
                "NODE_ENV=production",
                "QUEUE_NAME=orders",
                "QUEUE_CONCURRENCY=8",
                "REDIS_URL=redis://redis:6379/1",
                "DATABASE_URL=postgres://shopfront:hunter2@postgres:5432/shopfront",
                "SENTRY_AUTH_TOKEN=sntrys_7f3c9a12b8e4",
            ]
        case "redis":
            return base + ["REDIS_VERSION=7.4.0", "REDIS_DOWNLOAD_SHA=a3d1c1f0"]
        case "postgres":
            return base + [
                "PG_MAJOR=16",
                "PG_VERSION=16.4",
                "POSTGRES_DB=shopfront",
                "POSTGRES_USER=shopfront",
                "POSTGRES_PASSWORD=hunter2",
                "PGDATA=/var/lib/postgresql/data",
            ]
        case "grafana":
            return base + [
                "GF_PATHS_DATA=/var/lib/grafana",
                "GF_SECURITY_ADMIN_PASSWORD=grafana-admin",
                "GF_INSTALL_PLUGINS=grafana-clickhouse-datasource",
            ]
        case "clickhouse":
            return base + [
                "CLICKHOUSE_DB=events",
                "CLICKHOUSE_USER=analytics",
                "CLICKHOUSE_PASSWORD=ch-analytics-2026",
                "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1",
            ]
        default:
            return base + ["LANG=C.UTF-8", "TZ=Etc/UTC"]
        }
    }

    private static func mounts(for container: ContainerSummary) -> [[String: Any]] {
        func volumeMount(_ name: String, _ destination: String, readOnly: Bool = false) -> [String: Any] {
            [
                "Type": "volume",
                "Name": name,
                "Source": "/var/lib/docker/volumes/\(name)/_data",
                "Destination": destination,
                "Driver": "local",
                "Mode": "z",
                "RW": !readOnly,
                "Propagation": "",
            ]
        }
        func bindMount(_ source: String, _ destination: String, readOnly: Bool = true) -> [String: Any] {
            [
                "Type": "bind",
                "Source": source,
                "Destination": destination,
                "Mode": readOnly ? "ro" : "rw",
                "RW": !readOnly,
                "Propagation": "rprivate",
            ]
        }

        switch container.composeService ?? container.displayName {
        case "web":
            return [
                bindMount("/Users/ada/src/shopfront/nginx/nginx.conf", "/etc/nginx/nginx.conf"),
                bindMount("/Users/ada/src/shopfront/nginx/certs", "/etc/nginx/certs"),
            ]
        case "postgres":
            return [volumeMount("shopfront_pgdata", "/var/lib/postgresql/data")]
        case "redis":
            return [volumeMount("shopfront_redis_appendonly", "/data")]
        case "clickhouse":
            return [volumeMount("analytics_clickhouse_data", "/var/lib/clickhouse")]
        case "grafana":
            return [
                volumeMount("analytics_grafana_storage", "/var/lib/grafana"),
                bindMount("/Users/ada/src/analytics/grafana/provisioning", "/etc/grafana/provisioning"),
            ]
        case "vector":
            return [bindMount("/Users/ada/src/analytics/vector.yaml", "/etc/vector/vector.yaml")]
        case "legacy-jenkins":
            return [volumeMount("jenkins_home", "/var/jenkins_home")]
        default:
            return []
        }
    }

    /// `containers`, in the order the app itself would show them after a refresh.
    static let displayOrderedContainers: [ContainerSummary] = displayOrdered(containers)

    /// A predictable grouping useful to callers that need a stable fixture order:
    /// running first, then everything else, each alphabetically.
    private static func displayOrdered(_ list: [ContainerSummary]) -> [ContainerSummary] {
        list.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

}
