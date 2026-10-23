import Foundation
import os

// MARK: - Logging
// Centralized logging for MetarMate. Uses os.Logger so output is filterable in the
// Xcode console (and Console.app) by subsystem/category. To see only these logs in
// Xcode, type "MetarMate" in the console filter bar, or filter by one of the
// categories below (e.g. "net", "load", "asos").
//
// Categories:
//   .net   raw network fetches (URL, HTTP status, byte count, elapsed ms)
//   .load  WeatherViewModel load flow (routing, fallback decisions, totals)
//   .asos  Synoptic/ASOS boost fetches
//   .app   general app lifecycle / misc
enum Log {
    private static let subsystem = "com.jeffquayle.MetarMate"

    static let net  = Logger(subsystem: subsystem, category: "net")
    static let load = Logger(subsystem: subsystem, category: "load")
    static let asos = Logger(subsystem: subsystem, category: "asos")
    static let app  = Logger(subsystem: subsystem, category: "app")
}

// MARK: - Timing helper
// Wrap an async throwing operation, log how long it took, and re-throw any error.
// Usage:
//   let metars = try await timed("METAR history \(icao)", log: Log.net) {
//       try await weatherService.fetchMetarHistory(for: icao, hours: 6)
//   }
@discardableResult
func timed<T>(
    _ label: String,
    log: Logger = Log.app,
    _ operation: () async throws -> T
) async rethrows -> T {
    let start = DispatchTime.now()
    do {
        let result = try await operation()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        log.info("[timing] \(label, privacy: .public) - \(String(format: "%.0f", ms), privacy: .public) ms")
        return result
    } catch {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        log.error("[timing] \(label, privacy: .public) FAILED after \(String(format: "%.0f", ms), privacy: .public) ms - \(String(describing: error), privacy: .public)")
        throw error
    }
}

// MARK: - Non-throwing timing helper
@discardableResult
func timedNonThrowing<T>(
    _ label: String,
    log: Logger = Log.app,
    _ operation: () async -> T
) async -> T {
    let start = DispatchTime.now()
    let result = await operation()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    log.info("[timing] \(label, privacy: .public) - \(String(format: "%.0f", ms), privacy: .public) ms")
    return result
}

// MARK: - Per-request fetch log (diagnostics)
// One `[req]` line per network request: what was asked for, which stations, who asked (file and
// function, captured at the call site), HTTP status, URLError code, duration, how many requests
// were in flight, and the outcome in the same words everywhere:
//   ok                  200 with a product
//   noProduct(204)      NOAA's "no product for this station"
//   noProduct(empty)    200 with an empty list (also "no product")
//   transient(...)      timeout / connection / offline, or HTTP 429 / 5xx — worth retrying
//   cancelled           URLError -999 or CancellationError (a .task torn down) — not a result
//   failed(...)         anything else (4xx, bad response, decode)
// Logging only: nothing here changes what a caller does with the result. Lines are .debug.
nonisolated enum FetchLog {
    private static let state = OSAllocatedUnfairLock(initialState: (next: 0, inflight: 0))

    /// "SearchView.swift:loadHistoryMetars()" from a call site's #fileID and #function.
    static func caller(_ file: String, _ function: String) -> String {
        "\(file.split(separator: "/").last.map(String.init) ?? file):\(function)"
    }

    /// Run one request and log it. Returns exactly what `operation` returns; rethrows its error.
    static func request(_ kind: String, ids: String, caller: String,
                        _ operation: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        let (id, inflight) = state.withLock { s -> (Int, Int) in
            s.next += 1; s.inflight += 1
            return (s.next, s.inflight)
        }
        let start = DispatchTime.now()
        defer { state.withLock { $0.inflight -= 1 } }
        do {
            let (data, response) = try await operation()
            let status = (response as? HTTPURLResponse)?.statusCode
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            log(id: id, kind: kind, ids: ids, caller: caller, status: status.map(String.init) ?? "-",
                urlError: "-", start: start, bytes: data.count, inflight: inflight,
                outcome: classify(status: status, data: data) + (retryAfter.map { " retryAfter=\($0)" } ?? ""))
            return (data, response)
        } catch {
            let ns = error as NSError
            log(id: id, kind: kind, ids: ids, caller: caller, status: "-",
                urlError: ns.domain == NSURLErrorDomain ? String(ns.code) : "-", start: start, bytes: 0,
                inflight: inflight, outcome: classify(error))
            throw error
        }
    }

    static func classify(status: Int?, data: Data) -> String {
        guard let status else { return "failed(no HTTP response)" }
        switch status {
        case 200:
            let body = String(decoding: data.prefix(8), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return body == "[]" ? "noProduct(empty)" : "ok"
        case 204: return "noProduct(204)"
        default: return FetchErrorKind.isTransient(status: status) ? "transient(http \(status))" : "failed(http \(status))"
        }
    }

    /// The outcome words for a thrown error: FetchErrorKind's class, with the code that decided it.
    static func classify(_ error: Error) -> String {
        let underlying = (error as? FetchFailure)?.underlying ?? error
        let detail: String = {
            if case WeatherError.noContent = underlying { return "204" }
            if case WeatherError.noData = underlying { return "empty" }
            if case WeatherError.httpStatus(let code) = underlying { return "http \(code)" }
            let ns = underlying as NSError
            if ns.domain == NSURLErrorDomain { return "urlerr \(ns.code)" }
            return String(describing: underlying)
        }()
        switch FetchErrorKind(error) {
        case .cancelled: return "cancelled"
        case .noProduct: return "noProduct(\(detail))"
        case .transient: return "transient(\(detail))"
        case .failed:    return "failed(\(detail))"
        }
    }

    /// The outcome words for a fetch outcome (e.g. the field's own TAF request).
    static func classify<T>(_ outcome: FetchOutcome<T>) -> String {
        switch outcome {
        case .loaded: return "ok"
        case .noProduct: return "noProduct"
        case .failed(let failure): return classify(failure)
        }
    }

    private static func log(id: Int, kind: String, ids: String, caller: String, status: String, urlError: String,
                            start: DispatchTime, bytes: Int, inflight: Int, outcome: String) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let line = "[req #\(id)] \(kind) ids=\(ids) caller=\(caller) status=\(status) urlerr=\(urlError) ms=\(String(format: "%.0f", ms)) bytes=\(bytes) inflight=\(inflight) outcome=\(outcome)"
        // .debug for every outcome: one line per request is high volume. In Console.app turn on
        // Action > Include Debug Messages to see them.
        Log.net.debug("\(line, privacy: .public)")
    }
}
