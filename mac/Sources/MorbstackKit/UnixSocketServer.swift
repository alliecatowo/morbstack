// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// Shared low-level helpers for unix-domain sockets.
///
/// These wrap the handful of BSD socket calls Morbstack needs while retrying on
/// `EINTR`, which the daemon will hit whenever a signal source fires.
public enum POSIXSocketSupport {

    /// The usable capacity of `sockaddr_un.sun_path` on Darwin (104 bytes, NUL included).
    public static let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Builds a `sockaddr_un` for `path`.
    ///
    /// - Throws: ``MorbError/io(_:)`` if the path does not fit in `sun_path`.
    public static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bytes = Array(path.utf8)
        guard bytes.count < sunPathCapacity else {
            throw MorbError.io("socket path too long (\(bytes.count) >= \(sunPathCapacity)): \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    /// Runs `body`, retrying while it fails with `EINTR`.
    @discardableResult
    public static func retryOnInterrupt(_ body: () -> Int32) -> Int32 {
        while true {
            let result = body()
            if result < 0 && errno == EINTR { continue }
            return result
        }
    }

    /// `read(2)` with `EINTR` retry.
    public static func readSome(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        while true {
            let n = Darwin.read(fd, buffer, count)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    /// Writes the whole of `data`, retrying on short writes and `EINTR`.
    ///
    /// - Returns: `true` when every byte was written.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written: Int = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                while true {
                    let n = Darwin.write(fd, base, raw.count)
                    if n < 0 && errno == EINTR { continue }
                    return n
                }
            }
            if written <= 0 { return false }
            remaining = remaining.dropFirst(written)
        }
        return true
    }

    /// Stops writes to `fd` from raising `SIGPIPE`, so they return `EPIPE` instead.
    ///
    /// Every descriptor Morbstack writes to belongs to something that can vanish at
    /// any moment — a `docker` client hitting Ctrl-C, a guest that rebooted. The
    /// default disposition of `SIGPIPE` is to terminate the process, which would turn
    /// a routine disconnect into a dead daemon.
    public static func suppressSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Marks `fd` non-blocking (or blocking) via `F_SETFL`.
    public static func setNonBlocking(_ fd: Int32, _ enabled: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        let updated = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
        _ = fcntl(fd, F_SETFL, updated)
    }
}

/// A unix-domain socket listener that hands accepted file descriptors to a callback.
///
/// The listener owns the socket file: it unlinks a stale path before binding and
/// removes it again on ``stop()``. Accepted descriptors become the callback's
/// responsibility — the server never closes them.
///
/// "Owns" is enforced rather than assumed. ``stop()`` compares the inode currently at
/// `path` with the one this server bound; if some other process has replaced the
/// socket in the meantime, the file is left alone. Unlinking blindly would delete a
/// live daemon's endpoint and leave its clients with a path that no longer exists.
///
/// This does *not* make the unlink-then-bind sequence in ``start()`` race-free — that
/// requires an out-of-band lock, which the daemon takes with ``FileLock`` before it
/// ever gets here.
public final class UnixSocketServer {

    /// The filesystem path the listener is bound to.
    public let path: String

    /// Invoked on the server's queue for every accepted connection, with an owned fd.
    public var onConnection: ((Int32) -> Void)?

    private let queue: DispatchQueue
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var running = false
    private let lock = NSLock()

    /// Identity of the socket file this server created, used to avoid unlinking a
    /// path that now belongs to somebody else.
    private var boundDevice: dev_t?
    private var boundInode: ino_t?

    /// Creates a listener. Nothing is bound until ``start()`` is called.
    ///
    /// - Parameters:
    ///   - path: Filesystem path for the socket.
    ///   - queue: Queue on which the accept loop and ``onConnection`` run.
    public init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    deinit {
        stop()
    }

    /// Binds, `chmod`s to `0600` and starts accepting.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        // Remove a socket left behind by a crashed daemon. A live daemon would have
        // failed to bind anyway, so `morbstackd` refuses to start twice by probing
        // the socket first (see Daemon.swift).
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MorbError.io("socket(AF_UNIX) failed: \(String(cString: strerror(errno)))")
        }

        var address = try POSIXSocketSupport.makeAddress(path: path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                POSIXSocketSupport.retryOnInterrupt { Darwin.bind(fd, generic, length) }
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MorbError.io("bind(\(path)) failed: \(message)")
        }

        guard chmod(path, 0o600) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            unlink(path)
            throw MorbError.io("chmod(\(path)) failed: \(message)")
        }

        guard POSIXSocketSupport.retryOnInterrupt({ listen(fd, 64) }) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            unlink(path)
            throw MorbError.io("listen(\(path)) failed: \(message)")
        }

        POSIXSocketSupport.setNonBlocking(fd, true)
        listenFD = fd

        var bound = stat()
        if stat(path, &bound) == 0 {
            boundDevice = bound.st_dev
            boundInode = bound.st_ino
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainAccepts()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        acceptSource = source
        running = true
        source.resume()
    }

    /// Stops accepting, closes the listening socket and unlinks the socket file —
    /// but only if the file at `path` is still the one this server bound.
    public func stop() {
        lock.lock()
        let source = acceptSource
        let wasRunning = running
        let device = boundDevice
        let inode = boundInode
        acceptSource = nil
        listenFD = -1
        running = false
        boundDevice = nil
        boundInode = nil
        lock.unlock()

        guard wasRunning else { return }
        source?.cancel()  // cancel handler closes the fd

        guard let device, let inode else { return }
        var current = stat()
        guard stat(path, &current) == 0,
              current.st_dev == device,
              current.st_ino == inode
        else { return }  // somebody else's socket now: leave it alone
        unlink(path)
    }

    /// Accepts every pending connection; the read source is edge-ish, so we loop.
    private func drainAccepts() {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        guard fd >= 0 else { return }

        while true {
            let client = POSIXSocketSupport.retryOnInterrupt { Darwin.accept(fd, nil, nil) }
            if client < 0 {
                // EAGAIN/EWOULDBLOCK simply means we drained the backlog.
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            // Accepted sockets do not inherit O_NONBLOCK on Darwin, but be explicit.
            POSIXSocketSupport.setNonBlocking(client, false)
            POSIXSocketSupport.suppressSIGPIPE(client)
            if let handler = onConnection {
                handler(client)
            } else {
                Darwin.close(client)
            }
        }
    }
}
