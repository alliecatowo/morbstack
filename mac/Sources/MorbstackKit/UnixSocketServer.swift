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

/// A listening descriptor, with accept and close serialised against each other.
///
/// The serialisation is the point. A listener's `stop()` has to close the socket
/// *synchronously* (see ``TCPListener/stop()`` and ``UnixSocketServer/stop()``), and
/// a bare `close(2)` racing an in-flight `accept(2)` on the same number is the
/// classic descriptor-reuse bug: the accept lands on whatever the process opened
/// next. Funnelling both through one lock makes "closed" a state the accept loop
/// observes rather than a race it runs into.
///
/// Shared by ``TCPListener`` and ``UnixSocketServer`` so the two listener types
/// cannot drift on what `stop()` means: the descriptor is closed — and the port or
/// path free — by the time it returns.
final class POSIXListenSocket {

    /// How long a `stop()` waits for the accept source's cancel handler before
    /// closing the descriptor itself.
    ///
    /// Only reached if the listener's queue is wedged; the handler normally runs in
    /// well under a millisecond. The fallback exists so a stuck queue degrades into
    /// a late close rather than a descriptor — and a bound endpoint — leaked
    /// forever.
    static let cancelHandlerGrace: TimeInterval = 2

    private let lock = NSLock()
    private let fd: Int32
    private var closed = false

    /// Signalled exactly once, by whichever caller performs the close.
    let closedSignal = DispatchSemaphore(value: 0)

    init(_ fd: Int32) { self.fd = fd }

    /// Closes the socket if it is still open. Idempotent.
    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        Darwin.close(fd)
        closedSignal.signal()
    }

    /// One non-blocking `accept(2)`, or `-1` once the socket has been closed.
    func acceptOne() -> Int32 {
        acceptOneReportingErrno().fd
    }

    /// Like ``acceptOne()`` but also returns the `errno` of a failed accept, so a
    /// caller can tell descriptor exhaustion (`EMFILE`/`ENFILE`) from `EAGAIN`.
    func acceptOneReportingErrno() -> (fd: Int32, errorCode: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return (-1, EBADF) }
        let client = POSIXSocketSupport.retryOnInterrupt { Darwin.accept(fd, nil, nil) }
        return (client, client < 0 ? errno : 0)
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
    private var listenSocket: POSIXListenSocket?
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
        let bound = POSIXListenSocket(fd)
        listenSocket = bound

        var boundStat = stat()
        if stat(path, &boundStat) == 0 {
            boundDevice = boundStat.st_dev
            boundInode = boundStat.st_ino
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainAccepts()
        }
        source.setCancelHandler { [bound] in
            bound.close()
        }
        acceptSource = source
        running = true
        source.resume()
    }

    /// Stops accepting, closes the listening socket and unlinks the socket file —
    /// but only if the file at `path` is still the one this server bound.
    ///
    /// **Synchronous by contract**, mirroring ``TCPListener/stop()``: the descriptor
    /// is closed by the time this returns, not merely queued for the dispatch
    /// cancel handler to close later. A caller's very next act is often to bind the
    /// same path again (a daemon restart re-binds the control socket the previous
    /// instance just released), and the unlink below removes the *path* while an
    /// unwaited-for cancel handler could still hold the *descriptor* — leaking it,
    /// and leaving `stop()` meaning something different here than it does one file
    /// over. Cancel the source, wait for its handler to close the socket, and close
    /// it here if that wait runs out; ``POSIXListenSocket`` closes exactly once no
    /// matter which of the two paths gets there first.
    public func stop() {
        lock.lock()
        let source = acceptSource
        let bound = listenSocket
        let wasRunning = running
        let device = boundDevice
        let inode = boundInode
        acceptSource = nil
        listenSocket = nil
        running = false
        boundDevice = nil
        boundInode = nil
        lock.unlock()

        guard wasRunning, let bound else { return }
        source?.cancel()  // cancel handler closes the fd
        if bound.closedSignal.wait(timeout: .now() + POSIXListenSocket.cancelHandlerGrace)
            == .timedOut {
            // The listener's queue is not draining. Closing from here is still safe:
            // the accept loop takes the same lock the close does, so it cannot be
            // holding a descriptor this call is about to invalidate.
            bound.close()
        }

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
        let bound = listenSocket
        lock.unlock()
        guard let bound else { return }

        while true {
            let client = bound.acceptOne()
            if client < 0 {
                // EAGAIN/EWOULDBLOCK simply means we drained the backlog; -1 with
                // the socket closed means the listener was stopped.
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
