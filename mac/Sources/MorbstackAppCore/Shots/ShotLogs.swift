// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Four hundred lines of container output, with the escape sequences left in.
//
// Logs must parse ANSI instead of printing escapes or stripping semantics. This fixture
// therefore generates the sort of output a Node service emits: a build banner,
// structured prefixes, varied access status codes, debug chatter, and a stderr trace.
// It is test data only; it does not create or approve any rendered representation.
//
// Deterministic. The paths, statuses and timings come from a fixed pseudo-random walk
// so parser and fixture-data checks see the same sequence on every run.

import Foundation

enum ShotLogs {

    // MARK: - Escapes

    private static let reset = "\u{1B}[0m"
    private static let bold = "\u{1B}[1m"
    private static let dim = "\u{1B}[2m"

    private static func fg(_ code: Int) -> String { "\u{1B}[\(code)m" }

    private static let red = fg(31)
    private static let green = fg(32)
    private static let yellow = fg(33)
    private static let blue = fg(34)
    private static let magenta = fg(35)
    private static let cyan = fg(36)
    private static let grey = fg(90)
    private static let brightGreen = fg(92)
    private static let brightYellow = fg(93)
    private static let brightCyan = fg(96)

    // MARK: - Formatters

    /// Common Log Format's bracketed date, in the local zone so it agrees with the
    /// viewer's gutter rather than sitting an offset away from it.
    static let accessLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MMM/yyyy:HH:mm:ss ZZZ"
        return formatter
    }()

    // MARK: - Line source

    /// Roughly four hundred lines of `shopfront-api-1` output, oldest first.
    ///
    /// - Parameter now: the timestamp of the newest line; everything else is spaced
    ///   backwards from it.
    static func apiLog(now: Date = Date(), count: Int = 412) -> [LogLine] {
        var builder = Builder(count: count, now: now)

        builder.appendBanner()
        builder.appendSteadyState(until: count - 96)
        builder.appendWarnings()
        builder.appendSteadyState(until: count - 34)
        builder.appendTraceback()
        builder.appendRecovery()
        builder.appendSteadyState(until: count)

        return builder.finish()
    }

    // MARK: - Builder

    private struct Builder {

        let count: Int
        let now: Date
        var lines: [(String, StdStream)] = []
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        init(count: Int, now: Date) {
            self.count = count
            self.now = now
            lines.reserveCapacity(count)
        }

        mutating func random() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 100_000) / 100_000
        }

        mutating func pick<T>(_ options: [T]) -> T {
            options[Int(random() * Double(options.count)) % options.count]
        }

        mutating func out(_ text: String) { lines.append((text, .stdout)) }
        mutating func err(_ text: String) { lines.append((text, .stderr)) }

        // MARK: Sections

        /// The build tool's startup banner: the loudest, most colourful thing in a
        /// modern Node log and the reason the viewer bothers with bold at all.
        mutating func appendBanner() {
            out("")
            out("\(dim)> shopfront-api@2.11.4 start\(reset)")
            out("\(dim)> node dist/server.js\(reset)")
            out("")
            out("  \(bold)\(magenta)VITE\(reset) \(green)v5.4.2\(reset)  \(dim)ready in 431 ms\(reset)")
            out("")
            out("  \(green)➜\(reset)  \(bold)Local\(reset):   \(cyan)http://localhost:3000/\(reset)")
            out("  \(green)➜\(reset)  \(bold)Network\(reset): \(cyan)http://172.19.0.6:3000/\(reset)")
            out("  \(green)➜\(reset)  \(dim)press \(reset)\(bold)h\(reset)\(dim) + enter to show help\(reset)")
            out("")
            out("\(brightCyan)┌─────────────────────────────────────────────────────────┐\(reset)")
            out("\(brightCyan)│\(reset)  \(bold)shopfront-api\(reset)  \(dim)2.11.4\(reset)  ·  node \(green)v22.7.0\(reset)  ·  \(yellow)production\(reset)   \(brightCyan)│\(reset)")
            out("\(brightCyan)└─────────────────────────────────────────────────────────┘\(reset)")
            out("")
            out("\(blue)INFO \(reset) \(cyan)[config]\(reset)   loaded 41 keys from environment")
            out("\(blue)INFO \(reset) \(cyan)[db]\(reset)       connecting to postgres://shopfront@postgres:5432/shopfront")
            out("\(brightGreen)READY\(reset) \(cyan)[db]\(reset)       pool established \(dim)(min 2, max 20, ssl off)\(reset)")
            out("\(blue)INFO \(reset) \(cyan)[redis]\(reset)    connecting to redis://redis:6379/0")
            out("\(brightGreen)READY\(reset) \(cyan)[redis]\(reset)    connected, 0 keys in db0")
            out("\(blue)INFO \(reset) \(cyan)[migrate]\(reset)  schema at revision \(bold)20260731_1142_add_order_events\(reset)")
            out("\(blue)INFO \(reset) \(cyan)[otel]\(reset)     exporter → http://vector:4317 \(dim)(grpc)\(reset)")
            out("\(brightGreen)READY\(reset) \(cyan)[http]\(reset)     listening on 0.0.0.0:3000")
            out("")
        }

        /// Access-log and structured lines, until the buffer reaches `target`.
        mutating func appendSteadyState(until target: Int) {
            let paths = [
                "/api/products?page=1&limit=24",
                "/api/products/8f2c-lantern-brass",
                "/api/cart",
                "/api/cart/items",
                "/api/checkout/session",
                "/api/orders/recent",
                "/api/search?q=oak+shelf",
                "/api/health",
                "/api/collections/summer-2026",
                "/api/users/me",
                "/api/reviews/8f2c-lantern-brass",
                "/metrics",
            ]
            let methods = ["GET", "GET", "GET", "GET", "POST", "PUT", "DELETE"]
            let agents = [
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                "shopfront-web/2.11.4",
                "kube-probe/1.29",
                "curl/8.7.1",
                "Prometheus/2.53.1",
            ]

            while lines.count < target {
                let roll = random()
                if roll < 0.72 {
                    appendAccessLine(paths: paths, methods: methods, agents: agents)
                } else if roll < 0.84 {
                    appendStructuredLine()
                } else if roll < 0.92 {
                    appendDebugLine()
                } else if roll < 0.965 {
                    appendNginxLine(paths: paths, agents: agents)
                } else {
                    appendCacheLine()
                }
            }
        }

        mutating func appendAccessLine(paths: [String], methods: [String], agents: [String]) {
            let method = pick(methods)
            let path = pick(paths)
            let duration = random() * (path == "/api/checkout/session" ? 380 : 60) + 1.4
            let bytes = Int(random() * 18_000) + 120

            let statusRoll = random()
            let status: Int
            if statusRoll > 0.965 {
                status = pick([500, 502, 504])
            } else if statusRoll > 0.90 {
                status = pick([301, 304, 401, 404, 429])
            } else {
                status = method == "POST" ? 201 : 200
            }

            let statusColour: String
            switch status {
            case 200..<300: statusColour = green
            case 300..<400: statusColour = cyan
            case 400..<500: statusColour = yellow
            default: statusColour = red
            }

            let methodColour = method == "GET" ? blue : (method == "DELETE" ? red : magenta)
            let slow = duration > 250

            out(
                // Seven, not six: `DELETE` is exactly six characters, and padding it
                // to its own length ran the verb into the path.
                "\(bold)\(methodColour)\(method.padding(toLength: 7, withPad: " ", startingAt: 0))\(reset)"
                    + "\(path.padding(toLength: 42, withPad: " ", startingAt: 0)) "
                    + "\(bold)\(statusColour)\(status)\(reset) "
                    + "\(slow ? brightYellow : dim)\(String(format: "%6.1f", duration)) ms\(reset) "
                    + "\(dim)- \(bytes)  \"\(pick(agents))\"\(reset)")
        }

        mutating func appendNginxLine(paths: [String], agents: [String]) {
            let ip = "172.19.0.\(Int(random() * 40) + 2)"
            let path = pick(paths)
            let status = random() > 0.93 ? 404 : 200
            out(
                "\(grey)\(ip) - - [\(stamp())] \(reset)"
                    + "\"\(bold)GET\(reset) \(path) HTTP/1.1\" "
                    + "\(status == 200 ? green : yellow)\(status)\(reset) "
                    + "\(Int(random() * 9000) + 300) \(dim)\"-\" \"\(pick(agents))\"\(reset)")
        }

        /// A structured event line.
        ///
        /// The identifiers and amounts vary per line, so log filtering and copy/search
        /// consumers exercise realistic, nonrepeating records.
        mutating func appendStructuredLine() {
            let order = String(format: "ord_%04x%02x", Int(random() * 65_535), Int(random() * 255))
            let amount = Int(random() * 24_000) + 900
            let events: [(String, String, String)] = [
                (cyan + "[orders]" + reset, "order.created",
                 "id=\(order) total=£\(String(format: "%.2f", Double(amount) / 100)) items=\(Int(random() * 6) + 1)"),
                (cyan + "[cart]" + reset, "cart.merged",
                 "guest=ck_\(String(format: "%04x", Int(random() * 65_535))) user=usr_\(Int(random() * 9000) + 1000) items=\(Int(random() * 8) + 1)"),
                (cyan + "[stripe]" + reset, "payment.succeeded",
                 "intent=pi_3P\(String(format: "%04x", Int(random() * 65_535))) amount=\(amount) currency=gbp"),
                (cyan + "[search]" + reset, "index.refresh",
                 "docs=\(Int(random() * 4000) + 16_000) took=\(Int(random() * 300) + 40)ms"),
                (cyan + "[mail]" + reset, "queued",
                 "template=order_confirmation to=\(pick(["a***", "j***", "m***", "s***"]))@example.com"),
                (cyan + "[inventory]" + reset, "stock.decremented",
                 "sku=\(pick(["8f2c-lantern-brass", "31a9-oak-shelf", "c4e0-linen-throw"])) qty=\(Int(random() * 3) + 1) remaining=\(Int(random() * 60) + 4)"),
            ]
            let event = pick(events)
            out(
                "\(blue)INFO \(reset) \(event.0.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                    + "\(bold)\(event.1)\(reset) \(dim)\(event.2)\(reset)")
        }

        mutating func appendDebugLine() {
            let notes = [
                "sql SELECT \"products\".* FROM \"products\" WHERE \"visible\" = $1 LIMIT $2  [12.4ms]",
                "sql SELECT count(*) FROM \"order_items\" WHERE \"order_id\" = $1  [0.9ms]",
                "cache miss products:page:1:limit:24 → filling",
                "otel span http.server.request 41.2ms trace=8a1f2c0d9b",
                "gc scavenge 4.1ms heap=182.4 MB / 512.0 MB",
            ]
            out("\(dim)DEBUG \(pick(notes))\(reset)")
        }

        mutating func appendCacheLine() {
            out(
                "\(brightGreen)HIT  \(reset) \(cyan)[cache]\(reset)    "
                    + "\(dim)products:page:1:limit:24  \(reset)\(green)age 41s\(reset) \(dim)ttl 300s\(reset)")
        }

        /// A cluster of warnings, so the yellow band is visible as a band rather than a
        /// single line lost in four hundred.
        mutating func appendWarnings() {
            out("\(bold)\(yellow)WARN \(reset) \(cyan)[db]\(reset)       pool at 18/20 connections — queries are starting to queue")
            out("\(bold)\(yellow)WARN \(reset) \(cyan)[db]\(reset)       slow query 1284 ms \(dim)SELECT … FROM order_events WHERE created_at > $1\(reset)")
            out("\(bold)\(yellow)WARN \(reset) \(cyan)[stripe]\(reset)   retrying webhook delivery \(dim)(attempt 2 of 5, backoff 4s)\(reset)")
            out("\(yellow)WARN \(reset) \(cyan)[deprecation]\(reset) `req.session.cart` is deprecated, use `req.cart` — removal in 3.0")
            out("\(bold)\(yellow)WARN \(reset) \(cyan)[redis]\(reset)    command timeout after 250 ms, falling back to postgres")
        }

        /// The set piece: an unhandled rejection on stderr, red where the runtime
        /// colours it and stderr-washed everywhere else.
        mutating func appendTraceback() {
            err("")
            err("\(bold)\(red)/srv/app/dist/checkout/session.js:118\(reset)")
            err("      throw new PaymentGatewayError(`stripe refused: ${body.error.code}`);")
            err("      \(bold)\(red)^\(reset)")
            err("")
            err("\(bold)\(red)PaymentGatewayError\(reset): stripe refused: card_declined")
            err("    at createCheckoutSession (\(cyan)/srv/app/dist/checkout/session.js:118:13\(reset))")
            err("    at process.processTicksAndRejections (\(dim)node:internal/process/task_queues:95:5\(reset))")
            err("    at async POST /api/checkout/session (\(cyan)/srv/app/dist/http/routes.js:204:20\(reset))")
            err("    at async Object.handler (\(cyan)/srv/app/dist/http/server.js:71:7\(reset))")
            err("  \(dim)… 4 internal frames elided\(reset)")
            err("")
            err("\(yellow)  cause\(reset): StripeCardError: Your card was declined.")
            err("    \(dim)requestId  req_9Ha2LcQ4vTm0\(reset)")
            err("    \(dim)statusCode 402\(reset)")
            err("    \(dim)declineCode generic_decline\(reset)")
            err("")
            err("\(bold)\(red)[FATAL]\(reset) request aborted \(dim)trace=8a1f2c0d9b order=ord_8412d1\(reset)")
            err("")
        }

        mutating func appendRecovery() {
            out("\(bold)\(yellow)WARN \(reset) \(cyan)[checkout]\(reset) session ord_8412d1 rolled back, cart preserved")
            out("\(blue)INFO \(reset) \(cyan)[sentry]\(reset)   event 4f1c9d captured \(dim)(PaymentGatewayError)\(reset)")
            out("\(brightGreen)READY\(reset) \(cyan)[http]\(reset)     healthy again \(dim)— 1 error in the last 5 minutes\(reset)")
        }

        // MARK: Timestamps
        //
        // One clock, printed once.
        //
        // The fixture used to open every line with its own `HH:MM:SS.mmm`, run off a
        // hardcoded 04:02:11, while a consumer's timestamp column counted back from the
        // moment the fixture was generated. Winding the body clock to match made the
        // same timestamp appear twice and reduced the value of a separate time column.
        //
        // So the body clock is gone and the lines lead with their level — `INFO`,
        // `WARN`, `READY` — the way a service that knows its output is being collected
        // writes them. Time is the collector's job, which is exactly what the gutter is.
        // The nginx lines keep their bracketed Common Log Format stamp, because that is
        // the format, and one component logging differently from the rest is true of
        // every real stack.

        /// The instant the engine will stamp on the line that is about to be written.
        ///
        /// Must stay in step with `finish()`: `lines.count` is the index the next line
        /// will take, and both sides space the series 240 ms apart ending at `now`.
        var lineTime: Date {
            now.addingTimeInterval(-Double(count - lines.count) * 0.24)
        }

        /// The Common Log Format bracket an HTTP server writes.
        func stamp() -> String {
            ShotLogs.accessLogFormatter.string(from: lineTime)
        }

        // MARK: Output

        /// Numbers the lines and spaces their engine timestamps back from `now` at a
        /// steady 240 ms, which is about what a service under light load produces.
        func finish() -> [LogLine] {
            return lines.enumerated().map { index, entry in
                LogLine(
                    id: index,
                    text: entry.0,
                    stream: entry.1,
                    // `count`, not `total`: `lineTime` above cannot know how many lines
                    // the builders will actually emit, so both sides index off the
                    // requested count and the two clocks stay locked together.
                    timestamp: now.addingTimeInterval(-Double(count - index) * 0.24))
            }
        }
    }
}
