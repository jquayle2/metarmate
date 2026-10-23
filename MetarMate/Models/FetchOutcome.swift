import Foundation
import os

// MARK: - Fetch outcome
// What one station's weather request came back with. The rule every caller follows: only a
// confirmed "no product" may trigger a fallback (advisory estimate, nearby TAF, "METAR unavailable").
// A failure means we don't know: keep the last reading, retry, never fall back. Cancellation (a
// .task torn down by navigation) is not an outcome at all: the outcome APIs throw CancellationError
// and the caller leaves its state as it was.
nonisolated enum FetchOutcome<Value> {
    case loaded(Value)
    case noProduct                 // HTTP 204, a 200 with an empty list, or a station missing from a 200 batch
    case failed(FetchFailure)

    var value: Value? { if case .loaded(let v) = self { return v }; return nil }
    var isNoProduct: Bool { if case .noProduct = self { return true }; return false }
}

extension FetchOutcome: Sendable where Value: Sendable {}

/// A request that didn't produce an answer. Never a reason to fall back.
nonisolated struct FetchFailure: Error {
    let underlying: Error
    let isTransient: Bool          // timeout, connection, offline, HTTP 429 / 5xx: worth retrying
    let retryAfter: TimeInterval?  // the server's Retry-After, when it sent one

    init(_ underlying: Error, retryAfter: TimeInterval? = nil) {
        self.underlying = underlying
        self.isTransient = FetchErrorKind(underlying) == .transient
        self.retryAfter = retryAfter
    }
}

/// The one classification of a thrown error, shared by the outcome APIs, retries and the request log.
nonisolated enum FetchErrorKind: Equatable {
    case noProduct, transient, failed, cancelled

    init(_ error: Error) {
        if error is CancellationError { self = .cancelled; return }
        if let failure = error as? FetchFailure { self = failure.isTransient ? .transient : .failed; return }
        switch error as? WeatherError {
        case .noContent, .noData: self = .noProduct; return
        case .httpStatus(let code): self = Self.isTransient(status: code) ? .transient : .failed; return
        default: break
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { self = .failed; return }
        switch ns.code {
        case NSURLErrorCancelled:
            self = .cancelled
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed, NSURLErrorResourceUnavailable,
             NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed:
            self = .transient
        default:
            self = .failed
        }
    }

    /// 429 rate limit and 5xx server errors are worth retrying; other 4xx are not.
    static func isTransient(status: Int) -> Bool { status == 429 || (500...599).contains(status) }
}

// MARK: - Retry
/// Backoff for transient failures: in the foreground retry after 2 s, 5 s, then 15 s, then stop. A
/// server Retry-After longer than the step is honored, capped at a minute. A value, so tests can
/// pass a `sleep` that records each wait instead of waiting.
nonisolated struct RetryPolicy: Sendable {
    let delays: [TimeInterval]
    var maxRetryAfter: TimeInterval = 60
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    static let foreground = RetryPolicy(delays: [2, 5, 15])

    /// The wait before retry `index` (0-based), or nil once the retries are used up.
    func delay(beforeRetry index: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        guard delays.indices.contains(index) else { return nil }
        return max(delays[index], min(retryAfter ?? 0, maxRetryAfter))
    }

    /// Run `attempt` again after each transient failure, per the delays above. Returns the first
    /// outcome that isn't a transient failure, or the last failure once retries are used up. Throws
    /// CancellationError if cancelled (including during a wait).
    func run<Value>(_ label: String,
                    _ attempt: () async throws -> FetchOutcome<Value>) async throws -> FetchOutcome<Value> {
        var index = 0
        while true {
            let outcome = try await attempt()
            guard case .failed(let failure) = outcome, failure.isTransient,
                  let wait = delay(beforeRetry: index, retryAfter: failure.retryAfter) else { return outcome }
            Log.load.info("[retry] \(label, privacy: .public) retry \(index + 1, privacy: .public)/\(delays.count, privacy: .public) in \(Int(wait), privacy: .public)s after \(FetchLog.classify(failure.underlying), privacy: .public)")
            try await sleep(wait)
            index += 1
        }
    }
}

// MARK: - No-product memory
/// Stations that recently gave a confirmed "no product" (204, empty, or missing from a 200 batch),
/// kept 10 min so list refreshes don't ask again. A failure is never stored here.
nonisolated struct NoProductMemory {
    static let ttl: TimeInterval = 600
    private var entries: [String: Date] = [:]

    func contains(_ id: String, at now: Date) -> Bool {
        guard let at = entries[id] else { return false }
        return now.timeIntervalSince(at) < Self.ttl
    }

    mutating func remember(_ id: String, at now: Date) { entries[id] = now }
    mutating func forget(_ id: String) { entries[id] = nil }
    mutating func removeAll() { entries.removeAll() }
}

// MARK: - Batch METAR outcomes
nonisolated enum MetarBatch {
    /// Each requested station's outcome from a 200 batch response: its newest parsed METAR; a
    /// failure when NOAA returned obs for it that didn't parse (we don't know what it says); otherwise
    /// no product (NOAA had nothing for it). `parsed` is every METAR that parsed, `unparseable` the
    /// station ids of obs that didn't.
    static func outcomes(requested: [String], parsed: [Metar], unparseable: Set<String>) -> [String: FetchOutcome<Metar>] {
        var newest: [String: Metar] = [:]
        for metar in parsed where newest[metar.stationId].map({ metar.observationTime > $0.observationTime }) ?? true {
            newest[metar.stationId] = metar
        }
        var result: [String: FetchOutcome<Metar>] = [:]
        for id in requested {
            if let metar = newest[id] {
                result[id] = .loaded(metar)
            } else if unparseable.contains(id) {
                result[id] = .failed(FetchFailure(WeatherError.parseError("no parseable METAR for \(id)")))
            } else {
                result[id] = .noProduct
            }
        }
        return result
    }
}
