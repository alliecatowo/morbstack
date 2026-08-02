// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// An advisory whole-file lock held for as long as the object lives.
///
/// Morbstack uses this to make "only one `morbstackd` per `MORBSTACK_HOME`" a real
/// guarantee rather than a race. Probing the control socket and then unlinking it is
/// a classic time-of-check/time-of-use bug: two daemons starting at the same instant
/// both see "nothing is listening", both `unlink(2)` the socket path and both `bind`,
/// and whichever binds last silently hijacks the endpoint from the other.
///
/// `flock(2)` closes that window because the kernel serialises the acquisition. The
/// lock is attached to the open file description, so it is released automatically if
/// the process dies — a crashed daemon never leaves a lock file that needs cleaning
/// up by hand, which is why the lock file itself is deliberately never unlinked.
public final class FileLock {

    /// Path of the lock file.
    public let path: String

    private let lock = NSLock()
    private var fd: Int32 = -1

    /// Creates a lock for `path`. Nothing is opened until ``acquire()``.
    public init(path: String) {
        self.path = path
    }

    deinit {
        release()
    }

    /// `true` while this process holds the lock.
    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// Attempts to take the lock without blocking.
    ///
    /// - Returns: `true` when the lock is now held by this process, `false` when
    ///   another process holds it.
    /// - Throws: ``MorbError/io(_:)`` when the lock file cannot be opened, or when
    ///   `flock(2)` fails for a reason other than contention.
    @discardableResult
    public func acquire() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { return true }

        let opened = POSIXSocketSupport.retryOnInterrupt {
            open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        }
        guard opened >= 0 else {
            throw MorbError.io("could not open lock file \(path): \(String(cString: strerror(errno)))")
        }

        let result = POSIXSocketSupport.retryOnInterrupt { flock(opened, LOCK_EX | LOCK_NB) }
        if result != 0 {
            let code = errno
            Darwin.close(opened)
            // EWOULDBLOCK (== EAGAIN on Darwin) is the "someone else has it" answer;
            // anything else is a genuine failure the caller should hear about.
            if code == EWOULDBLOCK || code == EAGAIN { return false }
            throw MorbError.io("flock(\(path)) failed: \(String(cString: strerror(code)))")
        }

        // Record the owner pid so a human staring at the file can tell who has it.
        ftruncate(opened, 0)
        let stamp = Data("\(getpid())\n".utf8)
        _ = stamp.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return pwrite(opened, base, raw.count, 0)
        }

        fd = opened
        return true
    }

    /// Releases the lock, if held. Idempotent.
    ///
    /// The lock *file* is left in place on purpose: unlinking it would let a second
    /// process create a fresh file, lock that, and end up holding a different lock
    /// from a third process that opened the original inode.
    public func release() {
        lock.lock()
        let owned = fd
        fd = -1
        lock.unlock()
        guard owned >= 0 else { return }
        POSIXSocketSupport.retryOnInterrupt { flock(owned, LOCK_UN) }
        Darwin.close(owned)
    }
}
