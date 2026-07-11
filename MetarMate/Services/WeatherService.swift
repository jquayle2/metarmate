import Foundation
import os

// MARK: - Weather Service
// Fetches METAR and TAF data from aviationweather.gov (NOAA AviationWeather API)
actor WeatherService {
    static let shared = WeatherService()
    private let baseURL = "https://aviationweather.gov/api/data"
    private let session: URLSession

    private init() {
        // Explicit timeouts so a slow/unresponsive NOAA endpoint fails fast and we can
        // surface it (or fall back) in seconds, not the 60s URLSession default.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8    // seconds per request (idle-between-bytes)
        config.timeoutIntervalForResource = 15   // seconds total incl. retries
        config.waitsForConnectivity = false      // fail immediately if offline
        session = URLSession(configuration: config)
    }

    /// NOAA `ids=` candidate for a US identifier that isn't already a 4-letter ICAO.
    /// 3-char FAA LIDs — letters AND/OR digits (CMA, 36K, 1G4, 06C) — publish under a
    /// K-prefixed pseudo-ICAO (KCMA, K36K, K1G4). Returns nil when no normalization
    /// applies (already 4-char ICAO, or already K-prefixed). This is the fix for numeric
    /// LIDs that were mis-routed to advisory because the old gate required all-letters.
    static func noaaCandidate(for icao: String) -> String? {
        let u = icao.uppercased()
        guard u.count == 3, !u.hasPrefix("K"),
              u.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "K" + u
    }

    /// True for transient connection-level failures (timeout, connection lost, network
    /// dropped) that a quick retry on a fresh connection is likely to fix. Deliberately
    /// does NOT include a clean "no data" response — a station that genuinely reports
    /// nothing should fall through to advisory promptly, not retry-loop.
    private static func isTransient(_ error: Error) -> Bool {
        // Retryable HTTP statuses: 5xx server errors and 429 rate-limit. A 4xx (esp. 404
        // "no such product for this station") is NOT transient — it should fall to advisory
        // promptly rather than retry-loop.
        if case WeatherError.httpStatus(let code) = error {
            return code == 429 || (500...599).contains(code)
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable:
            return true
        default:
            return false
        }
    }

    // MARK: - METAR
    func fetchMetar(for icao: String) async throws -> Metar {
        let url = try buildURL(path: "metar", params: ["ids": icao, "format": "json", "hours": "2"])
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        let raw = try JSONDecoder().decode([RawMetar].self, from: data)
        guard let first = raw.first else { throw WeatherError.noData }
        return try MetarParser.parse(raw: first)
    }

    // Fetch METAR history for trend analysis (returns newest first).
    // Retries once on a transient connection/timeout error — the observed failure mode is
    // a single stalled connection (CFNetwork -1001) on a station that otherwise has data,
    // which a fresh request almost always recovers. This is the automatic version of the
    // manual "just load it again" workaround, and it prevents a full-reporting station
    // from being silently dumped into advisory on a one-off network hiccup.
    func fetchMetarHistory(for icao: String, hours: Int = 6) async throws -> [Metar] {
        let url = try buildURL(path: "metar", params: ["ids": icao, "format": "json", "hours": "\(hours)"])

        func attempt() async throws -> [Metar] {
            let (data, response) = try await session.data(from: url)
            try validateResponse(response)
            let raws = try JSONDecoder().decode([RawMetar].self, from: data)
            let parsed = raws.compactMap { try? MetarParser.parse(raw: $0) }
            return parsed
        }

        let start = DispatchTime.now()
        do {
            let parsed = try await attempt()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.info("[net] METAR history \(icao, privacy: .public) hours=\(hours) - \(String(format: "%.0f", ms), privacy: .public) ms, \(parsed.count, privacy: .public) obs")
            return parsed
        } catch let err where Self.isNoContent(err) {
            // 204: station has no METAR in the window. Clean empty result, not a failure.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.info("[net] METAR history \(icao, privacy: .public) no content (204) - \(String(format: "%.0f", ms), privacy: .public) ms")
            return []
        } catch let err where Self.isCancellation(err) {
            // Navigated away; not a failure, don't retry, don't count as fallback trigger.
            Log.net.info("[net] METAR history \(icao, privacy: .public) cancelled (navigated away)")
            throw err
        } catch {
            let ms1 = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            guard Self.isTransient(error) else {
                Log.net.error("[net] METAR history \(icao, privacy: .public) FAILED after \(String(format: "%.0f", ms1), privacy: .public) ms (non-transient, no retry) - \(String(describing: error), privacy: .public)")
                throw error
            }
            Log.net.warning("[net] METAR history \(icao, privacy: .public) transient failure after \(String(format: "%.0f", ms1), privacy: .public) ms - retrying once")
            let retryStart = DispatchTime.now()
            do {
                let parsed = try await attempt()
                let ms2 = Double(DispatchTime.now().uptimeNanoseconds - retryStart.uptimeNanoseconds) / 1_000_000
                Log.net.info("[net] METAR history \(icao, privacy: .public) RETRY OK - \(String(format: "%.0f", ms2), privacy: .public) ms, \(parsed.count, privacy: .public) obs")
                return parsed
            } catch {
                let ms2 = Double(DispatchTime.now().uptimeNanoseconds - retryStart.uptimeNanoseconds) / 1_000_000
                Log.net.error("[net] METAR history \(icao, privacy: .public) RETRY FAILED after \(String(format: "%.0f", ms2), privacy: .public) ms - \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    func fetchMetars(for icaos: [String]) async throws -> [String: Metar] {
        let ids = icaos.joined(separator: ",")
        let url = try buildURL(path: "metar", params: ["ids": ids, "format": "json", "hours": "2"])
        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(from: url)
            try validateResponse(response)
            let raws = try JSONDecoder().decode([RawMetar].self, from: data)
            var result: [String: Metar] = [:]
            for raw in raws {
                if let metar = try? MetarParser.parse(raw: raw) {
                    if let existing = result[metar.stationId] {
                        if metar.observationTime > existing.observationTime {
                            result[metar.stationId] = metar
                        }
                    } else {
                        result[metar.stationId] = metar
                    }
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.info("[net] batch METAR \(icaos.count, privacy: .public) req [\(ids, privacy: .public)] - \(String(format: "%.0f", ms), privacy: .public) ms, \(data.count, privacy: .public) bytes, \(result.count, privacy: .public) returned")
            return result
        } catch let err where Self.isNoContent(err) {
            // 204: none of the requested stations had a METAR in the window. Empty result.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.info("[net] batch METAR \(icaos.count, privacy: .public) req [\(ids, privacy: .public)] no content (204) - \(String(format: "%.0f", ms), privacy: .public) ms")
            return [:]
        } catch let err where Self.isCancellation(err) {
            Log.net.info("[net] batch METAR \(icaos.count, privacy: .public) cancelled (navigated away)")
            throw err
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.error("[net] batch METAR \(icaos.count, privacy: .public) req [\(ids, privacy: .public)] FAILED after \(String(format: "%.0f", ms), privacy: .public) ms - \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - TAF
    func fetchTaf(for icao: String) async throws -> Taf {
        let url = try buildURL(path: "taf", params: ["ids": icao, "format": "json"])
        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(from: url)
            try validateResponse(response)
            let raw = try JSONDecoder().decode([RawTaf].self, from: data)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.info("[net] TAF \(icao, privacy: .public) - \(String(format: "%.0f", ms), privacy: .public) ms, \(data.count, privacy: .public) bytes")
            guard let first = raw.first else { throw WeatherError.noData }
            return try TafParser.parse(raw: first)
        } catch let err where Self.isNoContent(err) {
            // 204: this station has no active TAF (common for GA fields). Not an error.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.info("[net] TAF \(icao, privacy: .public) no content (204, no active TAF) - \(String(format: "%.0f", ms), privacy: .public) ms")
            throw WeatherError.noContent
        } catch let err where Self.isCancellation(err) {
            Log.net.info("[net] TAF \(icao, privacy: .public) cancelled (navigated away)")
            throw err
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.net.error("[net] TAF \(icao, privacy: .public) FAILED after \(String(format: "%.0f", ms), privacy: .public) ms - \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Nearby stations with METAR
    func fetchNearbyMetars(latitude: Double, longitude: Double, radiusNm: Int = 50) async throws -> [Metar] {
        let url = try buildURL(path: "metar", params: [
            "bbox": "\(longitude - 1),\(latitude - 1),\(longitude + 1),\(latitude + 1)",
            "format": "json",
            "hours": "2"
        ])
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        let raws = try JSONDecoder().decode([RawMetar].self, from: data)
        return raws.compactMap { try? MetarParser.parse(raw: $0) }
    }

    // MARK: - Helpers
    private func buildURL(path: String, params: [String: String]) throws -> URL {
        var components = URLComponents(string: "\(baseURL)/\(path)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw WeatherError.invalidURL }
        return url
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.badResponse
        }
        // 204 No Content is NOAA's normal "this station has no product" response (e.g. a
        // GA field with no TAF, or no METAR in the window). It is NOT an error — callers
        // treat it as an empty result and fall to advisory if appropriate.
        if http.statusCode == 204 {
            throw WeatherError.noContent
        }
        guard http.statusCode == 200 else {
            // Carry the real status so callers can distinguish a genuine 404 (station has
            // no product — fall to advisory) from a 5xx/429 server hiccup (retryable).
            throw WeatherError.httpStatus(http.statusCode)
        }
    }

    /// URLSession task cancellation (-999) — happens when SwiftUI's .task is torn down as
    /// the user navigates away. Not a failure, not retryable, and should never trigger a
    /// fallback; callers filter it so it doesn't masquerade as an error in the logs.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// HTTP 204 No Content — station exists but has no product right now. Clean empty result.
    private static func isNoContent(_ error: Error) -> Bool {
        if case WeatherError.noContent = error { return true }
        return false
    }
}

// MARK: - Raw API response types (matching aviationweather.gov JSON)
// AnyCodable and RawMetar are defined in Utilities/SharedTypes.swift

struct RawTaf: Codable {
    let icaoId: String?
    let dbPopTime: String?
    let bulletinTime: String?
    let issueTime: String?
    let validTimeFrom: Int?
    let validTimeTo: Int?
    let rawTAF: String?
    let lat: Double?
    let lon: Double?
    let elev: Int?
    let name: String?
    let fcsts: [[String: AnyCodable]]?
}

// WeatherError moved to Utilities/SharedTypes.swift so MetarParser (which throws it) can be linked
// into the widget target without dragging this networking file along. AnyCodable also lives there.
