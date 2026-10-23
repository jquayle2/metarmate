import Foundation
import os

// MARK: - Row weather
// What a list row (Nearest, Search, Recents) knows about its airport. Built from the shared fetch
// outcomes: "no product" is the only state that may say a station has nothing; a failure keeps the
// last good reading and retries; a row starts as loading, never as a terminal message.

enum RowReading {
    case metar(Metar)
    case advisory(AdvisoryWeather)

    var metar: Metar? { if case .metar(let m) = self { return m }; return nil }
    var advisory: AdvisoryWeather? { if case .advisory(let a) = self { return a }; return nil }
}

enum RowWeather {
    case loading                        // no outcome yet
    case loaded(RowReading)
    case noProduct                      // NOAA confirms no METAR (reporting station)
    case retrying(last: RowReading?)    // transient failure; retrying with backoff
    case failed(last: RowReading?)      // retries used up: last good reading (if any) + tap to retry

    /// The reading to show: the loaded one, or the last good one while retrying or failed.
    var reading: RowReading? {
        switch self {
        case .loaded(let r): return r
        case .retrying(let last), .failed(let last): return last
        case .loading, .noProduct: return nil
        }
    }

    var isLoaded: Bool { if case .loaded = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }

    /// The METAR today's AirportRowView may show: only while it's still current (not over the
    /// 75-min cutoff, D#4), so a stale last-good reading never shows its category color as current.
    func displayMetar(at now: Date) -> Metar? {
        guard let metar = reading?.metar else { return nil }
        if case .noCurrent = WidgetWeatherSnapshot.reportAge(observationTime: metar.observationTime, at: now) { return nil }
        return metar
    }

    var displayAdvisory: AdvisoryWeather? { reading?.advisory }
}

// MARK: - Loader
/// Loads weather for a list's rows and publishes the whole row map each time it changes:
/// 1. Rows start from fresh cache, else what they already show, else `.loading`.
/// 2. METARs for reporting stations and 3-char LIDs (36K→K36K) in one NOAA request, and estimates
///    for station-less airports in one Open-Meteo request, side by side; transient failures retry
///    2 s / 5 s / 15 s (only the failing rows), then `.failed(last:)`.
/// 3. A LID gets the estimate only once NOAA confirms its K-station has no METAR — never because a
///    METAR request failed.
/// Cancellation stops the load and leaves the rows as last published.
@MainActor
final class RowWeatherLoader {
    private let list: String
    private let airports: [Airport]
    private let publish: ([String: RowWeather]) -> Void
    private var rows: [String: RowWeather] = [:]
    private let cache = WeatherCache.shared

    private init(list: String, airports: [Airport], publish: @escaping ([String: RowWeather]) -> Void) {
        self.list = list
        self.airports = airports
        self.publish = publish
    }

    /// `current` is what the rows show now (kept while they refresh). `force` (pull-to-refresh)
    /// skips the fresh-cache seed so every row is fetched.
    static func load(list: String, airports: [Airport], current: [String: RowWeather], force: Bool,
                     publish: @escaping ([String: RowWeather]) -> Void) async {
        let loader = RowWeatherLoader(list: list, airports: airports, publish: publish)
        await loader.run(current: current, force: force)
    }

    private func run(current: [String: RowWeather], force: Bool) async {
        var toFetch: [Airport] = []
        for a in airports {
            if !force, let m = cache.freshMetar(for: a.icao) {
                rows[a.icao] = .loaded(.metar(m))
            } else if !force, let adv = cache.freshAdvisory(for: a.icao) {
                rows[a.icao] = .loaded(.advisory(adv))
            } else {
                rows[a.icao] = current[a.icao].flatMap { $0.reading != nil ? $0 : nil } ?? .loading
                toFetch.append(a)
            }
        }
        publish(rows)
        logRows("published before fetch")

        let metarAirports = toFetch.filter { $0.hasMetar || WeatherService.noaaCandidate(for: $0.icao) != nil }
        let advisoryOnly = toFetch.filter { !$0.hasMetar && WeatherService.noaaCandidate(for: $0.icao) == nil }
        do {
            async let metars: Void = loadMetars(metarAirports)
            async let advisories: Void = loadAdvisories(advisoryOnly)
            _ = try await (metars, advisories)
        } catch {
            Log.load.info("[rows] \(self.list, privacy: .public) load cancelled — rows left as last published")
            return
        }
        logRows("DONE")
    }

    private func loadMetars(_ airports: [Airport]) async throws {
        guard !airports.isEmpty else { return }
        var rowFor: [String: Airport] = [:]   // NOAA id → row airport (KCMA → CMA)
        for a in airports { rowFor[WeatherService.noaaCandidate(for: a.icao) ?? a.icao.uppercased()] = a }
        var confirmedNoMetar: [Airport] = []   // LIDs whose K-station has no METAR: these get the estimate
        try await batchWithRetries("METAR", ids: Array(rowFor.keys), rowFor: rowFor,
                                   fetch: { try await WeatherService.shared.metarOutcomes(for: $0) }) { airport, outcome in
            switch outcome {
            case .loaded(let metar):
                self.rows[airport.icao] = .loaded(.metar(metar))
                self.cache.store(metar: metar, for: airport.icao)
            case .noProduct:
                if airport.hasMetar { self.rows[airport.icao] = .noProduct } else { confirmedNoMetar.append(airport) }
            case .failed:
                break
            }
        }
        try await loadAdvisories(confirmedNoMetar)
    }

    /// Estimates in one Open-Meteo request (was one request per airport — the 429 burst).
    private func loadAdvisories(_ airports: [Airport]) async throws {
        guard !airports.isEmpty else { return }
        let rowFor = Dictionary(airports.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
        try await batchWithRetries("ADVISORY", ids: Array(rowFor.keys), rowFor: rowFor,
                                   fetch: { ids in try await OpenMeteoService.shared.advisoryOutcomes(for: ids.compactMap { rowFor[$0] }) }) { airport, outcome in
            switch outcome {
            case .loaded(let advisory):
                self.rows[airport.icao] = .loaded(.advisory(advisory))
                self.cache.store(advisory: advisory, for: airport.icao)
            case .noProduct:
                self.rows[airport.icao] = .noProduct
            case .failed:
                break
            }
        }
    }

    /// Fetch a batch, then retry only the transiently failing ids per RetryPolicy (2 s / 5 s / 15 s,
    /// honoring Retry-After). `apply` handles loaded and no-product outcomes; failures become
    /// `.retrying(last:)` while a retry is pending and `.failed(last:)` once retries are used up.
    private func batchWithRetries<Value>(_ kind: String, ids: [String], rowFor: [String: Airport],
                                         fetch: ([String]) async throws -> [String: FetchOutcome<Value>],
                                         apply: (Airport, FetchOutcome<Value>) -> Void) async throws {
        var pending = ids
        var retry = 0
        while !pending.isEmpty {
            let outcomes = try await fetch(pending)
            var failing: [String] = []
            var retryAfter: TimeInterval = 0
            for id in pending {
                guard let airport = rowFor[id], let outcome = outcomes[id] else { continue }
                if case .failed(let failure) = outcome {
                    if failure.isTransient {
                        failing.append(id)
                        retryAfter = max(retryAfter, failure.retryAfter ?? 0)
                        rows[airport.icao] = .retrying(last: lastReading(airport))
                    } else {
                        rows[airport.icao] = .failed(last: lastReading(airport))
                    }
                } else {
                    apply(airport, outcome)
                }
            }
            publish(rows)
            guard !failing.isEmpty else { return }
            guard let wait = RetryPolicy.delay(beforeRetry: retry, retryAfter: retryAfter) else {
                for id in failing { if let a = rowFor[id] { rows[a.icao] = .failed(last: lastReading(a)) } }
                publish(rows)
                Log.load.warning("[rows] \(self.list, privacy: .public) \(kind, privacy: .public) retries used up for [\(failing.joined(separator: ","), privacy: .public)] — showing last reading + tap to retry")
                return
            }
            Log.load.info("[retry] \(self.list, privacy: .public) \(kind, privacy: .public) batch retry \(retry + 1, privacy: .public)/\(RetryPolicy.delays.count, privacy: .public) in \(Int(wait), privacy: .public)s for [\(failing.joined(separator: ","), privacy: .public)]")
            try await Task.sleep(for: .seconds(wait))
            retry += 1
            pending = failing
        }
    }

    /// The last good reading for a row: what it shows now, else the last cached value of any age.
    private func lastReading(_ airport: Airport) -> RowReading? {
        if let shown = rows[airport.icao]?.reading { return shown }
        if let m = cache.lastMetar(for: airport.icao) { return .metar(m) }
        if !airport.hasMetar, let adv = cache.lastAdvisory(for: airport.icao) { return .advisory(adv) }
        return nil
    }

    private func logRows(_ phase: String) {
        var counts: [String: [String]] = [:]
        for a in airports {
            let state: String
            switch rows[a.icao] ?? .loading {
            case .loading: state = "loading"
            case .loaded: state = "loaded"
            case .noProduct: state = "noProduct"
            case .retrying: state = "retrying"
            case .failed: state = "failed"
            }
            counts[state, default: []].append(a.icao)
        }
        let summary = counts.keys.sorted().map { "\($0)=[\(counts[$0]!.joined(separator: ","))]" }.joined(separator: " ")
        Log.load.info("[rows] \(self.list, privacy: .public) \(phase, privacy: .public): \(summary, privacy: .public)")
    }
}
