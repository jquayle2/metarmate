import Foundation

// MARK: - Synoptic Data Service
// Fetches 5-minute ASOS/AWOS observations from Synoptic Data's Weather API.
// Provides higher-resolution data between standard hourly METARs.
// Free tier: 5,000 requests / 5M service units per month.
// Docs: https://docs.synopticdata.com/services/weather-api

actor SynopticService {
    static let shared = SynopticService()
    private let session = URLSession.shared
    private let baseURL = "https://api.synopticdata.com/v2/stations"

    // TODO: Replace with your actual Synoptic API token
    // Sign up at https://customer.synopticdata.com to get one (free tier available)
    private let token = "70c11dd558a54cec8e620ee1284676df"

    private init() {}

    // MARK: - Public API

    /// Fetch the most recent observation for an airport
    func fetchLatest(for icao: String) async throws -> SynopticObservation {
        let url = try buildURL(
            service: "latest",
            params: [
                "stid": icao,
                "vars": Self.aviationVars,
                "units": "english",
                "within": "60"
            ]
        )
        let response = try await fetch(url: url)
        guard let station = response.stations.first else {
            throw SynopticError.noData
        }
        return try parseLatest(station: station)
    }

    /// Fetch recent time series for trend analysis (default 6 hours)
    func fetchTimeSeries(for icao: String, recentMinutes: Int = 360) async throws -> [SynopticObservation] {
        let url = try buildURL(
            service: "timeseries",
            params: [
                "stid": icao,
                "vars": Self.aviationVars,
                "units": "english",
                "recent": "\(recentMinutes)"
            ]
        )
        let response = try await fetch(url: url)
        guard let station = response.stations.first else {
            throw SynopticError.noData
        }
        return try parseTimeSeries(station: station)
    }

    // MARK: - Aviation variable list

    private static let aviationVars = [
        "air_temp", "dew_point_temperature",
        "wind_speed", "wind_gust", "wind_direction",
        "visibility", "altimeter",
        "cloud_layer_1_code", "cloud_layer_2_code", "cloud_layer_3_code",
        "weather_condition", "sea_level_pressure"
    ].joined(separator: ",")

    // MARK: - Networking

    private func fetch(url: URL) async throws -> SynopticResponse {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw SynopticError.badResponse
        }

        guard http.statusCode == 200 else {
            throw SynopticError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SynopticAPIResponse.self, from: data)

        guard decoded.summary.responseCode == 1 else {
            throw SynopticError.apiError(decoded.summary.responseMessage)
        }

        return SynopticResponse(
            stations: decoded.station ?? [],
            units: decoded.units ?? [:]
        )
    }

    private func buildURL(service: String, params: [String: String]) throws -> URL {
        var components = URLComponents(string: "\(baseURL)/\(service)")!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        guard let url = components.url else { throw SynopticError.badURL }
        return url
    }

    // MARK: - Parsing (Latest)

    private func parseLatest(station: SynopticStation) throws -> SynopticObservation {
        let obs = station.observations

        // Latest service uses _value_1 keys
        let dateStr = obs["date_time"]?.latestString
        let date = dateStr.flatMap { Self.parseDate($0) } ?? Date()

        return SynopticObservation(
            stationId: station.stid,
            stationName: station.name,
            latitude: Double(station.latitude) ?? 0,
            longitude: Double(station.longitude) ?? 0,
            elevation: Double(station.elevation ?? "0") ?? 0,
            observationTime: date,
            temperature: obs["air_temp_value_1"]?.latestDouble,
            dewpoint: obs["dew_point_temperature_value_1"]?.latestDouble,
            windSpeed: obs["wind_speed_value_1"]?.latestDouble,
            windGust: obs["wind_gust_value_1"]?.latestDouble,
            windDirection: obs["wind_direction_value_1"]?.latestDouble.flatMap { Int($0) },
            visibility: obs["visibility_value_1"]?.latestDouble,
            altimeter: obs["altimeter_value_1"]?.latestDouble,
            seaLevelPressure: obs["sea_level_pressure_value_1"]?.latestDouble,
            weatherCondition: obs["weather_condition_value_1d"]?.latestString,
            cloudLayers: parseCloudsLatest(obs),
            isFromSynoptic: true
        )
    }

    // MARK: - Parsing (Time Series)

    private func parseTimeSeries(station: SynopticStation) throws -> [SynopticObservation] {
        let obs = station.observations

        // Time series uses _set_1 keys and parallel arrays
        guard let dateTimes = obs["date_time"]?.arrayStrings else {
            throw SynopticError.parseError("Missing date_time array")
        }

        let temps = obs["air_temp_set_1"]?.arrayDoubles
        let dewpoints = obs["dew_point_temperature_set_1"]?.arrayDoubles
        let windSpeeds = obs["wind_speed_set_1"]?.arrayDoubles
        let windGusts = obs["wind_gust_set_1"]?.arrayDoubles
        let windDirs = obs["wind_direction_set_1"]?.arrayDoubles
        let vis = obs["visibility_set_1"]?.arrayDoubles
        let alt = obs["altimeter_set_1"]?.arrayDoubles
        let slp = obs["sea_level_pressure_set_1"]?.arrayDoubles
        let wx = obs["weather_condition_set_1d"]?.arrayStrings

        var results: [SynopticObservation] = []

        for i in dateTimes.indices {
            guard let date = Self.parseDate(dateTimes[i]) else { continue }

            let temp: Double? = temps?[safe: i] ?? nil
            let dew: Double? = dewpoints?[safe: i] ?? nil
            let ws: Double? = windSpeeds?[safe: i] ?? nil
            let wg: Double? = windGusts?[safe: i] ?? nil
            let wd: Double? = windDirs?[safe: i] ?? nil
            let v: Double? = vis?[safe: i] ?? nil
            let a: Double? = alt?[safe: i] ?? nil
            let sp: Double? = slp?[safe: i] ?? nil
            let wxStr: String? = wx?[safe: i]

            results.append(SynopticObservation(
                stationId: station.stid,
                stationName: station.name,
                latitude: Double(station.latitude) ?? 0,
                longitude: Double(station.longitude) ?? 0,
                elevation: Double(station.elevation ?? "0") ?? 0,
                observationTime: date,
                temperature: temp,
                dewpoint: dew,
                windSpeed: ws,
                windGust: wg,
                windDirection: wd.flatMap { Int($0) },
                visibility: v,
                altimeter: a,
                seaLevelPressure: sp,
                weatherCondition: wxStr,
                cloudLayers: parseCloudAtIndex(obs, index: i),
                isFromSynoptic: true
            ))
        }

        return results
    }

    // MARK: - Cloud parsing helpers

    private func parseCloudsLatest(_ obs: [String: SynopticValue]) -> [SynopticCloudLayer] {
        var layers: [SynopticCloudLayer] = []
        for key in ["cloud_layer_1_code_value_1", "cloud_layer_2_code_value_1", "cloud_layer_3_code_value_1"] {
            if let code = obs[key]?.latestString, let layer = SynopticCloudLayer.from(code: code) {
                layers.append(layer)
            }
        }
        return layers
    }

    private func parseCloudAtIndex(_ obs: [String: SynopticValue], index: Int) -> [SynopticCloudLayer] {
        var layers: [SynopticCloudLayer] = []
        for key in ["cloud_layer_1_code_set_1", "cloud_layer_2_code_set_1", "cloud_layer_3_code_set_1"] {
            if let codes = obs[key]?.arrayStrings, let code = codes[safe: index],
               let layer = SynopticCloudLayer.from(code: code) {
                layers.append(layer)
            }
        }
        return layers
    }

    // MARK: - Date parsing

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated private static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }
}

// MARK: - Synoptic Observation Model

struct SynopticObservation: Identifiable, Sendable {
    var id: String { stationId + observationTime.ISO8601Format() }
    let stationId: String
    let stationName: String
    let latitude: Double
    let longitude: Double
    let elevation: Double         // feet
    let observationTime: Date
    let temperature: Double?      // Fahrenheit (units=english)
    let dewpoint: Double?         // Fahrenheit
    let windSpeed: Double?        // knots
    let windGust: Double?         // knots
    let windDirection: Int?       // degrees true
    let visibility: Double?       // statute miles
    let altimeter: Double?        // inHg
    let seaLevelPressure: Double? // mb
    let weatherCondition: String? // e.g. "RA", "SN", "FG"
    let cloudLayers: [SynopticCloudLayer]
    let isFromSynoptic: Bool

    /// Estimated flight category from visibility and ceiling
    nonisolated var estimatedCategory: FlightCategory {
        let ceiling = ceilingAGL
        let vis = visibility

        if let c = ceiling, c < 500 { return .lifr }
        if let v = vis, v < 1.0 { return .lifr }
        if let c = ceiling, c < 1000 { return .ifr }
        if let v = vis, v < 3.0 { return .ifr }
        if let c = ceiling, c < 3000 { return .mvfr }
        if let v = vis, v < 5.0 { return .mvfr }
        return .vfr
    }

    /// Ceiling in feet AGL (lowest BKN or OVC layer)
    nonisolated var ceilingAGL: Int? {
        cloudLayers
            .filter { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility }
            .map(\.altitude)
            .min()
    }

    /// Temperature in Celsius (converted from Fahrenheit)
    nonisolated var temperatureCelsius: Int? {
        temperature.map { Int(($0 - 32) * 5 / 9) }
    }

    /// Dewpoint in Celsius (converted from Fahrenheit)
    nonisolated var dewpointCelsius: Int? {
        dewpoint.map { Int(($0 - 32) * 5 / 9) }
    }

    /// Temp/dewpoint spread in Celsius
    nonisolated var tempDewpointSpread: Int? {
        guard let t = temperatureCelsius, let d = dewpointCelsius else { return nil }
        return t - d
    }

    /// Minutes since observation
    nonisolated var minutesOld: Int {
        Int(Date().timeIntervalSince(observationTime) / 60)
    }
}

// MARK: - Synoptic Cloud Layer

struct SynopticCloudLayer: Sendable {
    let coverage: CloudCoverage
    let altitude: Int    // feet AGL (hundreds)

    /// Parse Synoptic cloud code like "BKN050" or "OVC012"
    nonisolated static func from(code: String) -> SynopticCloudLayer? {
        guard code.count >= 6 else { return nil }
        let coverageStr = String(code.prefix(3))
        let altStr = String(code.suffix(code.count - 3))

        guard let coverage = CloudCoverage(rawValue: coverageStr),
              let altHundreds = Int(altStr) else { return nil }

        return SynopticCloudLayer(coverage: coverage, altitude: altHundreds * 100)
    }
}

// MARK: - Raw API Response Models

private struct SynopticAPIResponse: Decodable {
    let summary: SynopticSummary
    let station: [SynopticStation]?
    let units: [String: String]?

    enum CodingKeys: String, CodingKey {
        case summary = "SUMMARY"
        case station = "STATION"
        case units = "UNITS"
    }
}

private struct SynopticSummary: Decodable {
    let responseCode: Int
    let responseMessage: String

    enum CodingKeys: String, CodingKey {
        case responseCode = "RESPONSE_CODE"
        case responseMessage = "RESPONSE_MESSAGE"
    }
}

struct SynopticStation: Decodable, Sendable {
    let stid: String
    let name: String
    let latitude: String
    let longitude: String
    let elevation: String?
    let status: String?
    let observations: [String: SynopticValue]

    enum CodingKeys: String, CodingKey {
        case stid = "STID"
        case name = "NAME"
        case latitude = "LATITUDE"
        case longitude = "LONGITUDE"
        case elevation = "ELEVATION"
        case status = "STATUS"
        case observations = "OBSERVATIONS"
    }
}

// MARK: - Flexible value type for Synoptic JSON
// Synoptic returns different shapes depending on service:
//   Latest:     { "air_temp_value_1": { "value": 72.3, "date_time": "2026-..." } }
//   TimeSeries: { "air_temp_set_1": [72.3, 71.1, ...] }
//   Also:       { "date_time": ["2026-...", "2026-...", ...] }

enum SynopticValue: Decodable, Sendable {
    case singleObject(value: Double?, dateTime: String?)
    case arrayOfDoubles([Double?])
    case arrayOfStrings([String])
    case stringValue(String)
    case doubleValue(Double)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try as a single { "value": ..., "date_time": ... } object (Latest service)
        if let obj = try? container.decode(LatestValueObject.self) {
            self = .singleObject(value: obj.value, dateTime: obj.dateTime)
            return
        }

        // Try as array of strings (date_time arrays)
        if let arr = try? container.decode([String].self) {
            self = .arrayOfStrings(arr)
            return
        }

        // Try as array of optional doubles (time series numeric data)
        if let arr = try? container.decode([Double?].self) {
            self = .arrayOfDoubles(arr)
            return
        }

        // Try single string
        if let s = try? container.decode(String.self) {
            self = .stringValue(s)
            return
        }

        // Try single double
        if let d = try? container.decode(Double.self) {
            self = .doubleValue(d)
            return
        }

        self = .unknown
    }

    var latestDouble: Double? {
        switch self {
        case .singleObject(let v, _): return v
        case .doubleValue(let d): return d
        default: return nil
        }
    }

    var latestString: String? {
        switch self {
        case .singleObject(_, let dt): return dt
        case .stringValue(let s): return s
        default: return nil
        }
    }

    var arrayDoubles: [Double?]? {
        if case .arrayOfDoubles(let arr) = self { return arr }
        return nil
    }

    var arrayStrings: [String]? {
        if case .arrayOfStrings(let arr) = self { return arr }
        return nil
    }
}

private struct LatestValueObject: Decodable {
    let value: Double?
    let dateTime: String?

    enum CodingKeys: String, CodingKey {
        case value
        case dateTime = "date_time"
    }
}

// MARK: - Internal response wrapper

private struct SynopticResponse {
    let stations: [SynopticStation]
    let units: [String: String]
}

// MARK: - Errors

enum SynopticError: LocalizedError {
    case badURL
    case badResponse
    case httpError(Int)
    case apiError(String)
    case noData
    case parseError(String)
    case noToken

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid Synoptic API URL"
        case .badResponse: return "Bad response from Synoptic API"
        case .httpError(let code): return "Synoptic API HTTP error: \(code)"
        case .apiError(let msg): return "Synoptic API error: \(msg)"
        case .noData: return "No observation data returned"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .noToken: return "Synoptic API token not configured"
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
