// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Docker proxy's per-connection relay: framed on the way in, raw on the way out.

import Darwin
import Dispatch
import Foundation

/// What the proxy decided about one framed request.
enum DockerRequestAdmission {
    /// Relay the request unchanged.
    case forward
    /// Relay unchanged and watch the matching response with this bounded observer.
    case forwardObserving(DockerPortLeaseResponseObserver)
    /// Relay `request` in place of what the client sent, and keep every byte of the
    /// response private until `hold.associate` has accepted the created container.
    case forwardRewritten(request: Data, hold: DockerHeldCreate)
    /// Refuse: answer the client directly and end the connection.
    case reject(statusCode: Int, reason: String, message: String)
}

/// The two callbacks a held create needs once its response has been framed.
struct DockerHeldCreate {
    let associate: (String) -> Bool
    let abandon: (String) -> Void
}

/// Per-request policy for a framed Docker connection.
///
/// Implemented by ``DockerProxy``. Keeping it behind a protocol is what makes the
/// framing testable: a test can drive a real relay over `socketpair(2)`s with a
/// policy that records what it was asked about, which is exactly the assertion the
/// original keep-alive bug needed and did not have.
protocol DockerRequestAdmissionPolicy: AnyObject {
    /// Whether this request's body must be read into memory before a verdict.
    func requiresBodyInspection(_ head: HTTPRequestHead) -> Bool

    /// The verdict. `body` is the decoded entity body, non-nil exactly when
    /// ``requiresBodyInspection(_:)`` returned `true` for this head.
    func admit(_ request: DockerRequestFramer.Request, body: Data?) -> DockerRequestAdmission

    /// A request was refused before it reached the Engine.
    func requestWasRefused(_ message: String)

    /// The connection could not be framed and was torn down.
    func framingFailed(_ description: String)
}

/// A Docker API connection whose client-to-guest direction is framed request by
/// request, until the Engine actually hijacks it.
///
/// # Why not ``FDRelay``
///
/// `FDRelay` splices both directions as opaque bytes. That is right for a hijacked
/// `exec` and wrong for everything before it: because the `docker` CLI pings and then
/// reuses the connection, an inspection performed only at connection setup never saw
/// a single `POST /containers/create` in normal use. This class keeps the raw splice
/// for the response direction, where it is needed and where nothing is decided, and
/// replaces it on the request direction with real HTTP/1.1 framing.
///
/// # Preserved behaviour
///
/// The half-close, backpressure and cancellation semantics are deliberately identical
/// to `FDRelay`'s, because those were paid for with bugs:
///
/// * each direction is a blocking worker with one fixed 64 KiB buffer, so the kernel
///   applies backpressure instead of a `DispatchIO` queue growing without bound;
/// * end of stream on one direction shuts down only the *write* half of the other
///   descriptor, so `docker exec` closing stdin still reads its output;
/// * ``cancel()`` shuts descriptors down rather than closing them under a blocked
///   syscall, and the last worker out performs the single close;
/// * the completion handler runs exactly once, on the caller's queue.
///
/// # Hijack
///
/// A request that may take the connection over (`attach`, `exec` start, a BuildKit
/// `session`, anything carrying `Upgrade`) is forwarded, and then the request worker
/// pauses while the response worker reads the reply's head. `101`, or a `2xx` with
/// Docker's raw/multiplexed stream content type, means the connection is no longer
/// HTTP: from that point both directions splice raw, exactly as before. Anything else
/// resumes framing, so nominating a candidate that turns out not to hijack is free.
final class DockerFramedRelay {

    /// Largest request body Morbstack will read into memory to inspect it.
    ///
    /// This is a refusal threshold, not a relay limit: bodies the proxy does not need
    /// to inspect stream through untouched at any size. A `containers/create`
    /// document larger than this is refused rather than waved through, because
    /// "too big to check" must not mean "not checked" — that was the original defect.
    static let maximumInspectableBodyBytes = 4 << 20

    /// Ceiling on a held (dynamic published-port) create response before the proxy
    /// stops waiting for it to be bounded.
    static let maximumHeldCreateResponseBytes = 192 * 1024

    private static let clientIndex = 0
    private static let guestIndex = 1

    private enum ResponseMode {
        case passthrough
        case observing(DockerPortLeaseResponseObserver)
        case decidingHijack
        case holdingCreate(DockerHeldCreate)
    }

    private enum Decision {
        case hijacked
        case resumeFraming
        case aborted
    }

    private let owned: RelayDescriptors
    private let queue: DispatchQueue
    private weak var policy: DockerRequestAdmissionPolicy?
    private let log: MorbLog

    /// Guards `mode`, `decision`, and the worker/termination bookkeeping.
    private let condition = NSCondition()
    private var mode: ResponseMode = .passthrough
    private var decision: Decision?
    private var cancellationRequested = false
    private var started = false
    private var terminal = false
    private var completedWorkers = 0
    private var completion: (() -> Void)?
    /// The observer still waiting for a verdict, so teardown can retire its lease.
    private var liveObserver: DockerPortLeaseResponseObserver?

    /// Serialises the two writers that can both target the client socket: the
    /// response pump, and the request worker answering a refusal.
    private let clientWriteLock = NSLock()

    private let framer: DockerRequestFramer

    init(
        clientFD: Int32,
        guestFD: Int32,
        queue: DispatchQueue,
        policy: DockerRequestAdmissionPolicy,
        log: MorbLog,
        completion: @escaping () -> Void
    ) {
        let descriptors = RelayDescriptors(clientFD, guestFD)
        self.owned = descriptors
        self.queue = queue
        self.policy = policy
        self.log = log
        self.completion = completion
        self.framer = DockerRequestFramer(
            source: RelayByteSource { buffer, capacity in
                guard let fd = descriptors.descriptor(DockerFramedRelay.clientIndex) else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: buffer, count: capacity)
            })

        for fd in [clientFD, guestFD] {
            POSIXSocketSupport.suppressSIGPIPE(fd)
            POSIXSocketSupport.setNonBlocking(fd, false)
        }
    }

    deinit {
        owned.shutdownAll()
        owned.close(0)
        owned.close(1)
    }

    func start() {
        condition.lock()
        guard !started, !terminal else {
            condition.unlock()
            return
        }
        started = true
        condition.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in runRequestSide() }
        DispatchQueue.global(qos: .userInitiated).async { [self] in runResponseSide() }
    }

    /// Tears the connection down early; the completion handler still fires once.
    func cancel() {
        condition.lock()
        guard !terminal else {
            condition.unlock()
            return
        }
        cancellationRequested = true
        let completeImmediately = !started
        if completeImmediately { terminal = true }
        condition.broadcast()
        condition.unlock()

        if completeImmediately {
            retireLiveObserver()
            owned.close(0)
            owned.close(1)
            deliverCompletion()
        } else {
            owned.shutdownAll()
        }
    }

    private var isCancellationRequested: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancellationRequested
    }

    // MARK: - Request side: framed

    private func runRequestSide() {
        defer { workerDidFinish() }

        while !isCancellationRequested {
            switch framer.nextHead() {
            case .endOfStream:
                // Every byte the client sent has reached the guest. Propagate the
                // half-close and let the response direction keep draining.
                if !isCancellationRequested { owned.shutdownWrite(Self.guestIndex) }
                return

            case .failed(let failure):
                reportFramingFailure(failure)
                return

            case .request(let request):
                switch handle(request) {
                case .continueFraming:
                    continue
                case .hijacked:
                    pumpClientToGuestRaw()
                    return
                case .stop:
                    return
                }
            }
        }
    }

    private enum RequestOutcome {
        case continueFraming
        case hijacked
        case stop
    }

    private func handle(_ request: DockerRequestFramer.Request) -> RequestOutcome {
        guard let policy else { return .stop }

        var headBytes = request.rawHead
        var body: Data?
        var rawBody: Data?

        if policy.requiresBodyInspection(request.head) {
            // The proxy has to read a body the client is withholding until it is told
            // to send it, so it answers the expectation itself and drops the header
            // rather than letting the Engine answer it a second time.
            if expectsContinue(request.head) {
                guard writeToClient(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else {
                    requestAbort()
                    return .stop
                }
                guard let stripped = HTTPRequestHeadRewriting.removingHeader(
                    named: "expect", in: headBytes)
                else {
                    return refuse(
                        statusCode: 500,
                        reason: "Internal Server Error",
                        message: "morbstack could not rewrite an Expect: 100-continue request head")
                }
                headBytes = stripped
            }

            switch framer.bufferBody(request.framing, limit: Self.maximumInspectableBodyBytes) {
            case .failure(.bodyTooLarge(let limit)):
                // Deliberately a refusal, not a bypass. The request is unread past
                // this point so the connection cannot continue, but a client that
                // gets a clear error is strictly better off than one whose bind
                // mounts silently resolved inside the guest.
                return refuse(
                    statusCode: 400,
                    reason: "Bad Request",
                    message: "morbstack refuses a container-create request larger than \(limit) bytes "
                        + "because it could not be admission-checked; split the request or file a bug "
                        + "if a legitimate create document is really this large")

            case .failure(let failure):
                reportFramingFailure(failure)
                return .stop

            case .success(let framed):
                rawBody = framed.raw
                body = framed.decoded
            }
        }

        let admission = policy.admit(request, body: body)

        switch admission {
        case .reject(let statusCode, let reason, let message):
            return refuse(statusCode: statusCode, reason: reason, message: message)

        case .forwardRewritten(let rewritten, let hold):
            // Arm the response side *before* the request can produce a response.
            setMode(.holdingCreate(hold))
            guard writeToGuest(rewritten) else {
                hold.abandon("the rewritten create request could not reach the guest Engine")
                requestAbort()
                return .stop
            }
            switch awaitDecision() {
            case .resumeFraming: return .continueFraming
            case .hijacked, .aborted: return .stop
            }

        case .forward, .forwardObserving:
            let isHijackCandidate = DockerHijackDetection.isHijackCandidate(request.head)
            if case .forwardObserving(let observer) = admission {
                setMode(.observing(observer))
            } else if isHijackCandidate {
                setMode(.decidingHijack)
            } else {
                setMode(.passthrough)
            }

            guard writeToGuest(headBytes) else {
                requestAbort()
                return .stop
            }
            if let rawBody {
                guard writeToGuest(rawBody) else {
                    requestAbort()
                    return .stop
                }
            } else if let failure = framer.streamBody(
                request.framing, to: RelayByteSink(write: { [weak self] buffer in
                    self?.writeToGuestBytes(buffer) ?? false
                }))
            {
                reportFramingFailure(failure)
                return .stop
            }

            guard isHijackCandidate, rawBody == nil else { return .continueFraming }
            if case .forwardObserving = admission { return .continueFraming }
            log.info("docker connection may be hijacked by \(request.head.method) \(request.head.target); awaiting the Engine's reply")
            switch awaitDecision() {
            case .hijacked: return .hijacked
            case .resumeFraming: return .continueFraming
            case .aborted: return .stop
            }
        }
    }

    private func expectsContinue(_ head: HTTPRequestHead) -> Bool {
        (head.headers["expect"] ?? "").lowercased().contains("100-continue")
    }

    /// Answers the client itself and ends the connection.
    ///
    /// Refusals always close: the rejected request's body may be partly unread, and
    /// injecting a response into a connection whose framing is no longer known is how
    /// a proxy corrupts the next exchange. `Connection: close` in the error says so.
    private func refuse(statusCode: Int, reason: String, message: String) -> RequestOutcome {
        policy?.requestWasRefused(message)
        _ = writeToClient(
            DockerEngineErrorResponse.bytes(
                statusCode: statusCode, reason: reason, message: message))
        owned.shutdownWrite(Self.clientIndex)
        requestAbort()
        return .stop
    }

    private func reportFramingFailure(_ failure: DockerRequestFramer.Failure) {
        switch failure {
        case .truncated, .sourceFailed, .sinkFailed:
            // An ordinary disconnect, not a protocol complaint.
            requestAbort()
        default:
            policy?.framingFailed(failure.description)
            _ = writeToClient(
                DockerEngineErrorResponse.bytes(
                    statusCode: 400,
                    reason: "Bad Request",
                    message: "morbstack could not frame this Docker API request: \(failure.description)"))
            owned.shutdownWrite(Self.clientIndex)
            requestAbort()
        }
    }

    /// The post-hijack splice: whatever the framer had already read, then a plain
    /// backpressured copy for the rest of the connection's life.
    private func pumpClientToGuestRaw() {
        let leftovers = framer.takePendingBytes()
        if !leftovers.isEmpty, !writeToGuest(leftovers) {
            requestAbort()
            return
        }

        guard let source = owned.descriptor(Self.clientIndex) else { return }
        var buffer = [UInt8](repeating: 0, count: FDRelay.copyBufferBytes)
        while !isCancellationRequested {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(source, into: base, count: raw.count)
            }
            if count > 0 {
                let wrote = buffer.withUnsafeBytes { raw -> Bool in
                    writeToGuestBytes(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
                if !wrote {
                    if !isCancellationRequested { requestAbort() }
                    return
                }
                continue
            }
            if count == 0 {
                if !isCancellationRequested { owned.shutdownWrite(Self.guestIndex) }
                return
            }
            if !isCancellationRequested { requestAbort() }
            return
        }
    }

    // MARK: - Response side: raw, with two narrow inspections

    private func runResponseSide() {
        defer {
            settleDecision(.aborted)
            retireLiveObserver()
            workerDidFinish()
        }

        var pendingHead = Data()
        var heldCreate = Data()
        var buffer = [UInt8](repeating: 0, count: FDRelay.copyBufferBytes)

        while !isCancellationRequested {
            guard let source = owned.descriptor(Self.guestIndex) else { return }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(source, into: base, count: raw.count)
            }

            if count == 0 {
                if !isCancellationRequested { owned.shutdownWrite(Self.clientIndex) }
                return
            }
            if count < 0 {
                if !isCancellationRequested { requestAbort() }
                return
            }

            switch currentMode() {
            case .passthrough:
                let wrote = buffer.withUnsafeBytes { raw -> Bool in
                    writeToClientBytes(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
                if !wrote {
                    if !isCancellationRequested { requestAbort() }
                    return
                }

            case .observing(let observer):
                // Same contract as FDRelay's observer hook: notified immediately
                // before the write, never able to alter or suppress a byte.
                observer.receive(Data(buffer[0..<count]))
                let wrote = buffer.withUnsafeBytes { raw -> Bool in
                    writeToClientBytes(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
                if !wrote {
                    if !isCancellationRequested { requestAbort() }
                    return
                }

            case .decidingHijack:
                pendingHead.append(contentsOf: buffer[0..<count])
                let wrote = buffer.withUnsafeBytes { raw -> Bool in
                    writeToClientBytes(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
                if !wrote {
                    if !isCancellationRequested { requestAbort() }
                    return
                }
                if let hijacked = evaluateHijack(&pendingHead) {
                    pendingHead = Data()
                    setMode(.passthrough)
                    settleDecision(hijacked ? .hijacked : .resumeFraming)
                    if hijacked { pumpGuestToClientRaw(); return }
                }

            case .holdingCreate(let hold):
                // Nothing is written to the client here: a dynamic published-port
                // create must have its lease associated before the client can learn
                // the container's identity.
                heldCreate.append(contentsOf: buffer[0..<count])
                switch completeHeldCreate(&heldCreate, hold: hold) {
                case .needMore:
                    if heldCreate.count > Self.maximumHeldCreateResponseBytes {
                        hold.abandon("the Engine sent an oversized create response")
                        failHeldCreate("morbstack could not verify the Docker Engine response for the dynamic port allocation")
                        return
                    }
                case .settled:
                    // Anything the Engine sent after the bounded create response
                    // belongs to the stream again and must not be swallowed.
                    if !heldCreate.isEmpty, !writeToClient(heldCreate) {
                        if !isCancellationRequested { requestAbort() }
                        return
                    }
                    heldCreate = Data()
                case .failed(let message):
                    failHeldCreate(message)
                    return
                }
            }
        }
    }

    /// After a confirmed hijack the response direction has nothing left to decide.
    private func pumpGuestToClientRaw() {
        guard let source = owned.descriptor(Self.guestIndex) else { return }
        var buffer = [UInt8](repeating: 0, count: FDRelay.copyBufferBytes)
        while !isCancellationRequested {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(source, into: base, count: raw.count)
            }
            if count > 0 {
                let wrote = buffer.withUnsafeBytes { raw -> Bool in
                    writeToClientBytes(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
                if !wrote {
                    if !isCancellationRequested { requestAbort() }
                    return
                }
                continue
            }
            if count == 0 {
                if !isCancellationRequested { owned.shutdownWrite(Self.clientIndex) }
                return
            }
            if !isCancellationRequested { requestAbort() }
            return
        }
    }

    /// `nil` while the response head is still incomplete.
    private func evaluateHijack(_ buffer: inout Data) -> Bool? {
        while true {
            let parsed: (head: HTTPResponseHead, consumed: Int)?
            do {
                parsed = try MinimalHTTP.parseHead(buffer)
            } catch {
                // An unparseable reply on a connection that already asked to be
                // upgraded is not something to keep framing. Splice.
                return true
            }
            guard let parsed else {
                return buffer.count > DockerRequestFramer.maximumHeadBytes ? true : nil
            }
            if DockerHijackDetection.confirmsHijack(parsed.head) { return true }
            if (100..<200).contains(parsed.head.statusCode) {
                // A `100 Continue` is not a verdict; keep looking for the real one.
                buffer.removeFirst(parsed.consumed)
                continue
            }
            return false
        }
    }

    private enum HeldCreateProgress {
        case needMore
        case settled
        case failed(String)
    }

    /// Frames one bounded create response, associates the lease, and only then
    /// releases a single byte of it to the client.
    private func completeHeldCreate(_ buffer: inout Data, hold: DockerHeldCreate) -> HeldCreateProgress {
        let parsed: (head: HTTPResponseHead, consumed: Int)?
        do {
            parsed = try MinimalHTTP.parseHead(buffer)
        } catch {
            hold.abandon("the Engine create response could not be parsed")
            return .failed("morbstack could not verify the Docker Engine response for the dynamic port allocation")
        }
        guard let parsed else { return .needMore }

        if (100..<200).contains(parsed.head.statusCode) {
            hold.abandon("the Engine sent an interim response to a bounded dynamic create")
            return .failed("morbstack could not verify the Docker Engine response for the dynamic port allocation")
        }
        guard !parsed.head.isChunked, let contentLength = parsed.head.contentLength,
              (0...(128 * 1024)).contains(contentLength)
        else {
            hold.abandon("the Engine sent an unbounded dynamic create response")
            return .failed("morbstack could not verify the Docker Engine response for the dynamic port allocation")
        }

        let responseLength = parsed.consumed + contentLength
        guard buffer.count >= responseLength else { return .needMore }
        let raw = Data(buffer.prefix(responseLength))
        let trailing = Data(buffer.dropFirst(responseLength))

        guard parsed.head.statusCode == 201 else {
            // A failed create owns no lease, but its own diagnosis is still the most
            // useful thing the client can be given.
            hold.abandon("Docker create returned HTTP \(parsed.head.statusCode)")
            guard writeToClient(raw) else { return .failed("") }
            setMode(.passthrough)
            buffer = trailing
            settleDecision(.resumeFraming)
            return .settled
        }

        let body = Data(raw.dropFirst(parsed.consumed))
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let containerID = object["Id"] as? String,
            !containerID.isEmpty
        else {
            hold.abandon("Docker create returned 201 without a usable container identity")
            return .failed("morbstack could not associate the dynamic published-port allocation with Docker's create response")
        }
        guard hold.associate(containerID) else {
            hold.abandon("Docker create returned an already-leased or unusable container identity")
            return .failed("morbstack could not retain the dynamic published-port allocation for Docker's created container")
        }

        guard writeToClient(raw) else { return .failed("") }
        setMode(.passthrough)
        buffer = trailing
        settleDecision(.resumeFraming)
        return .settled
    }

    private func failHeldCreate(_ message: String) {
        if !message.isEmpty {
            _ = writeToClient(
                DockerEngineErrorResponse.bytes(
                    statusCode: 500, reason: "Internal Server Error", message: message))
        }
        settleDecision(.aborted)
        requestAbort()
    }

    // MARK: - Mode and decision handshake

    private func currentMode() -> ResponseMode {
        condition.lock()
        defer { condition.unlock() }
        return mode
    }

    private func setMode(_ newMode: ResponseMode) {
        var installed: DockerPortLeaseResponseObserver?
        if case .observing(let observer) = newMode { installed = observer }

        condition.lock()
        let replaced = liveObserver
        liveObserver = installed
        mode = newMode
        condition.unlock()

        // A previous request's observer that never saw its verdict must retire its
        // provisional reservation rather than hold a host listener forever. The
        // observer itself treats that as `.unrecognized`.
        if let replaced, replaced !== installed { replaced.relayFinished() }
    }

    private func settleDecision(_ value: Decision) {
        condition.lock()
        if decision == nil { decision = value }
        condition.broadcast()
        condition.unlock()
    }

    private func awaitDecision() -> Decision {
        condition.lock()
        defer { condition.unlock() }
        while decision == nil && !cancellationRequested {
            condition.wait()
        }
        let settled = decision ?? .aborted
        decision = nil
        return settled
    }

    private func retireLiveObserver() {
        condition.lock()
        let observer = liveObserver
        liveObserver = nil
        condition.unlock()
        observer?.relayFinished()
    }

    // MARK: - Descriptor plumbing

    @discardableResult
    private func writeToClient(_ data: Data) -> Bool {
        data.withUnsafeBytes { writeToClientBytes($0) }
    }

    private func writeToClientBytes(_ bytes: UnsafeRawBufferPointer) -> Bool {
        clientWriteLock.lock()
        defer { clientWriteLock.unlock() }
        guard let fd = owned.descriptor(Self.clientIndex) else { return false }
        return Self.writeAll(fd, bytes)
    }

    @discardableResult
    private func writeToGuest(_ data: Data) -> Bool {
        data.withUnsafeBytes { writeToGuestBytes($0) }
    }

    private func writeToGuestBytes(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let fd = owned.descriptor(Self.guestIndex) else { return false }
        return Self.writeAll(fd, bytes)
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Fails both directions together, waking any blocked syscall without closing a
    /// descriptor another thread may be sitting in.
    private func requestAbort() {
        condition.lock()
        let shouldWake = !terminal && !cancellationRequested
        cancellationRequested = true
        condition.broadcast()
        condition.unlock()
        if shouldWake { owned.shutdownAll() }
    }

    private func workerDidFinish() {
        condition.lock()
        guard !terminal else {
            condition.unlock()
            return
        }
        completedWorkers += 1
        let completeNow = completedWorkers == 2
        if completeNow { terminal = true }
        condition.broadcast()
        condition.unlock()

        guard completeNow else { return }
        retireLiveObserver()
        owned.close(0)
        owned.close(1)
        deliverCompletion()
    }

    private func deliverCompletion() {
        queue.async { [self] in
            condition.lock()
            let handler = completion
            completion = nil
            condition.unlock()
            handler?()
        }
    }
}
