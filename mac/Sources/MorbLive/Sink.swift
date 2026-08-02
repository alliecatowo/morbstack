// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Draining an `AsyncThrowingStream` with a deadline, without losing what arrived.
//
// The obvious spelling — wrap `for try await` in a `Task` and cancel it — throws away
// every item collected so far, because the cancelled task's `value` is a
// `CancellationError` rather than the array. A stream check that times out having
// received nine of the ten lines it wanted needs to *say* nine, so the items land in a
// shared box as they arrive and the deadline only decides when to stop waiting.

import Foundation

/// A thread-safe accumulator for stream items.
final class Sink<T: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var items: [T] = []
    private var failure: Error?

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func setFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    var snapshot: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

/// Reads `stream` into a fresh sink until `until` is satisfied or `timeout` elapses.
///
/// - Returns: the sink, whatever happened. Ask it what it got.
@discardableResult
func drain<T: Sendable>(
    _ stream: AsyncThrowingStream<T, Error>,
    until: @escaping @Sendable ([T]) -> Bool,
    timeout: TimeInterval
) async -> Sink<T> {
    let sink = Sink<T>()
    await drain(stream, into: sink, until: until, timeout: timeout)
    return sink
}

/// The same, into a sink the caller already holds — used when something else has to
/// watch the items land (the events check starts a container mid-stream).
func drain<T: Sendable>(
    _ stream: AsyncThrowingStream<T, Error>,
    into sink: Sink<T>,
    until: @escaping @Sendable ([T]) -> Bool,
    timeout: TimeInterval
) async {
    let reader = Task.detached {
        do {
            for try await item in stream {
                sink.append(item)
                if until(sink.snapshot) { break }
            }
        } catch is CancellationError {
            // The deadline below cancelled us; not a stream failure.
        } catch {
            sink.setFailure(error)
        }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if until(sink.snapshot) { break }
        if sink.error != nil { break }
        if reader.isCancelled { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // Cancelling the task terminates the `AsyncThrowingStream`, which fires
    // `onTermination`, which shuts the socket down and unblocks the reader thread. That
    // chain is the only thing that stops a `follow=1` log stream, so awaiting the task
    // afterwards is safe rather than a hang.
    reader.cancel()
    _ = await reader.result
}
