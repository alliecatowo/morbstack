// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// Bounds on established published-port relays.
///
/// Every relay pins two blocking threads and two descriptors, and every one
/// also holds a guest stream-dial slot. Without a ceiling a single LAN peer
/// (or local script) can exhaust threads, descriptors and the guest's dial
/// cap for every other published port.
public final class ConnectionAdmission {

    public static let defaultMaxTotal = 384
    public static let defaultMaxPerSource = 64
    /// A relay that moves no bytes for this long is torn down.
    public static let defaultIdleTimeout: TimeInterval = 30 * 60

    private let maxTotal: Int
    private let maxPerSource: Int
    private let lock = NSLock()
    private var total = 0
    private var perSource: [String: Int] = [:]
    private var refusalLogged = false

    public init(
        maxTotal: Int = ConnectionAdmission.defaultMaxTotal,
        maxPerSource: Int = ConnectionAdmission.defaultMaxPerSource
    ) {
        self.maxTotal = maxTotal
        self.maxPerSource = maxPerSource
    }

    /// Claims a slot for `source`. Returns `nil` when over a limit; otherwise a
    /// ticket whose ``Ticket/release()`` must be called exactly once (extra
    /// calls are ignored).
    public func admit(source: String) -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard total < maxTotal, perSource[source, default: 0] < maxPerSource else {
            return nil
        }
        total += 1
        perSource[source, default: 0] += 1
        return Ticket(admission: self, source: source)
    }

    /// True only for the first refusal of a burst, so refusals log once.
    public func shouldLogRefusal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !refusalLogged
        refusalLogged = true
        return first
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    fileprivate func release(source: String) {
        lock.lock()
        total = max(0, total - 1)
        let remaining = perSource[source, default: 0] - 1
        if remaining <= 0 { perSource.removeValue(forKey: source) } else { perSource[source] = remaining }
        if total == 0 { refusalLogged = false }
        lock.unlock()
    }

    public final class Ticket {
        private let admission: ConnectionAdmission
        private let source: String
        private let lock = NSLock()
        private var released = false

        fileprivate init(admission: ConnectionAdmission, source: String) {
            self.admission = admission
            self.source = source
        }

        public func release() {
            lock.lock()
            let already = released
            released = true
            lock.unlock()
            if !already { admission.release(source: source) }
        }

        deinit { release() }
    }

    /// The peer address of an accepted socket, as a printable key (port
    /// dropped). Unknown peers share one bucket rather than bypassing the cap.
    public static func sourceKey(fd: Int32) -> String {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &length)
            }
        }
        guard result == 0 else { return "unknown" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let named = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return named == 0 ? String(cString: host) : "unknown"
    }
}

/// Process-wide descriptor limit handling.
public enum FileDescriptorLimit {

    /// macOS refuses an `RLIMIT_NOFILE` soft limit above `OPEN_MAX`.
    public static let target: rlim_t = 10_240

    /// Raises the soft `RLIMIT_NOFILE` toward ``target``. launchd jobs start at
    /// 256, and every published-port relay needs two descriptors.
    /// Returns the soft limit in effect afterwards.
    @discardableResult
    public static func raise() -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        let desired = min(target, limit.rlim_max)
        if limit.rlim_cur < desired {
            var raised = rlimit(rlim_cur: desired, rlim_max: limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { return desired }
        }
        return limit.rlim_cur
    }
}

/// Which Docker-published endpoints a guest lease request may claim.
///
/// The guest lease channel (vsock 2382) is reachable by any guest process, so
/// a lease is granted only when an existing container's `HostConfig` actually
/// publishes the requested endpoint.
public enum GuestLeaseAuthorization {

    /// Whether the inspect document of one container publishes `request`.
    /// Returns the full container id when it does.
    public static func publisher(
        inspectJSON: Data,
        request: GuestPortLease.Request
    ) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: inspectJSON) as? [String: Any],
              let id = root["Id"] as? String,
              let hostConfig = root["HostConfig"] as? [String: Any]
        else { return nil }
        let key = "\(request.containerPort)/\(request.transport.rawValue)"

        if let bindings = (hostConfig["PortBindings"] as? [String: Any])?[key] as? [[String: Any]] {
            for binding in bindings {
                let ip = (binding["HostIp"] as? String) ?? ""
                let port = (binding["HostPort"] as? String) ?? ""
                if ipMatches(ip, request.hostIP), portMatches(port, request.hostPort) { return id }
            }
        }
        // `-P`: dockerd picks an ephemeral host port at start, so only the
        // container port is knowable ahead of time.
        if hostConfig["PublishAllPorts"] as? Bool == true,
           let config = root["Config"] as? [String: Any],
           let exposed = config["ExposedPorts"] as? [String: Any],
           exposed[key] != nil,
           request.hostPort >= 1024 {
            return id
        }
        return nil
    }

    static func ipMatches(_ configured: String, _ requested: String) -> Bool {
        let wildcards: Set<String> = ["", "0.0.0.0", "::"]
        if wildcards.contains(configured) { return true }
        return configured == requested
    }

    static func portMatches(_ configured: String, _ requested: Int) -> Bool {
        if configured.isEmpty || configured == "0" { return requested >= 1024 }
        if let single = Int(configured) { return single == requested }
        let parts = configured.split(separator: "-")
        if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
            return (low...max(low, high)).contains(requested)
        }
        return false
    }

    /// Ids of containers worth inspecting (created, running or restarting).
    public static func candidateContainers(listJSON: Data, limit: Int = 128) -> (all: [String], live: Set<String>) {
        guard let items = try? JSONSerialization.jsonObject(with: listJSON) as? [[String: Any]] else {
            return ([], [])
        }
        var ids: [String] = []
        for item in items {
            guard let id = item["Id"] as? String else { continue }
            let state = (item["State"] as? String)?.lowercased() ?? ""
            if ["created", "running", "restarting"].contains(state) { ids.append(id) }
        }
        return (Array(ids.prefix(limit)), Set(ids))
    }
}
