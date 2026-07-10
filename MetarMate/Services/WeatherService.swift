import Foundation

// MARK: - Weather Service
// Fetches METAR and TAF data from aviationweather.gov (NOAA AviationWeather API)
actor WeatherService {
    static let shared = WeatherService()
    private let baseURL = "https://aviationweather.gov/api/data"
    private let session = URLSession.shared

    private init() {}

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

    // MARK: - METAR
    func fetchMetar(for icao: String) async throws -> Metar {
        let url = try buildURL(path: "metar", params: ["ids": icao, "format": "json", "hours": "2"])
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        let raw = try JSONDecoder().decode([RawMetar].self, from: data)
        guard let first = raw.first else { throw WeatherError.noData }
        return try MetarParser.parse(raw: first)
    }

    // Fetch METAR history for trend analysis (returns newest first)
    func fetchMetarHistory(for icao: String, hours: Int = 6) async throws -> [Metar] {
        let url = try buildURL(path: "metar", params: ["ids": icao, "format": "json", "hours": "\(hours)"])
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        let raws = try JSONDecoder().decode([RawMetar].self, from: data)
        return raws.compactMap { try? MetarParser.parse(raw: $0) }
    }

    func fetchMetars(for icaos: [String]) async throws -> [String: Metar] {
        let ids = icaos.joined(separator: ",")
        let url = try buildURL(path: "metar", params: ["ids": ids, "format": "json", "hours": "2"])
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
        return result
    }

    // MARK: - TAF
    func fetchTaf(for icao: String) async throws -> Taf {
        let url = try buildURL(path: "taf", params: ["ids": icao, "format": "json"])
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        let raw = try JSONDecoder().decode([RawTaf].self, from: data)
        guard let first = raw.first else { throw WeatherError.noData }
        return try TafParser.parse(raw: first)
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherError.badResponse
        }
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
