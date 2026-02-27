import Foundation

// MARK: - Weather Service
// Fetches METAR and TAF data from aviationweather.gov (NOAA AviationWeather API)
actor WeatherService {
    static let shared = WeatherService()
    private let baseURL = "https://aviationweather.gov/api/data"
    private let session = URLSession.shared

    private init() {}

    // MARK: - METAR
    func fetchMetar(for icao: String) async throws -> Metar {
        let url = try buildURL(path: "metar", params: ["ids": icao, "format": "json", "hours": "2"])
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        let raw = try JSONDecoder().decode([RawMetar].self, from: data)
        guard let first = raw.first else { throw WeatherError.noData }
        return try MetarParser.parse(raw: first)
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
                result[metar.stationId] = metar
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
struct RawMetar: Codable {
    let metar_id: Int?
    let icaoId: String?
    let receiptTime: String?
    let obsTime: Int?
    let reportTime: String?
    let temp: Double?
    let dewp: Double?
    let wdir: String?
    let wspd: Int?
    let wgst: Int?
    let visib: String?
    let altim: Double?
    let rawOb: String?
    let clouds: [[String: AnyCodable]]?
    let wxString: String?
    let flightCategory: String?
}

struct RawTaf: Codable {
    let tafId: Int?
    let icaoId: String?
    let dbPopTime: String?
    let bulletinTime: String?
    let issueTime: String?
    let validTimeFrom: Int?
    let validTimeTo: Int?
    let rawTAF: String?
    let fcsts: [[String: AnyCodable]]?
}

// MARK: - Error types
enum WeatherError: LocalizedError {
    case invalidURL
    case badResponse
    case noData
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .badResponse: return "Server returned an error"
        case .noData: return "No weather data available"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}

// MARK: - AnyCodable helper
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let bool as Bool: try container.encode(bool)
        default: try container.encodeNil()
        }
    }
}
