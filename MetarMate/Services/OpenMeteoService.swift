import Foundation

// MARK: - Open-Meteo Service
// Fetches advisory weather for airports that lack official METAR stations.
// Uses the free Open-Meteo API (no key required).
// Data is for situational awareness only — not certified aviation weather.

actor OpenMeteoService {
    static let shared = OpenMeteoService()
    private let session = URLSession.shared
    private let base = "https://api.open-meteo.com/v1/forecast"

    private init() {}

    func fetchAdvisory(for airport: Airport) async throws -> AdvisoryWeather {
        var components = URLComponents(string: base)!
        components.queryItems = [
            .init(name: "latitude",           value: String(airport.latitude)),
            .init(name: "longitude",          value: String(airport.longitude)),
            .init(name: "current",            value: [
                "temperature_2m",
                "dewpoint_2m",
                "relative_humidity_2m",
                "wind_speed_10m",
                "wind_gusts_10m",
                "wind_direction_10m",
                "cloud_cover",
                "precipitation",
                "precipitation_probability",
                "surface_pressure",
                "visibility"
            ].joined(separator: ",")),
            .init(name: "wind_speed_unit",    value: "kn"),
            .init(name: "temperature_unit",   value: "celsius"),
            .init(name: "forecast_days",      value: "1"),
        ]

        guard let url = components.url else { throw OpenMeteoError.badURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenMeteoError.badResponse
        }

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let c = decoded.current

        return AdvisoryWeather(
            airport:                  airport,
            fetchTime:                Date(),
            temperatureC:             c.temperature_2m,
            dewpointC:                c.dewpoint_2m,
            windSpeedKt:              c.wind_speed_10m,
            windGustKt:               c.wind_gusts_10m,
            windDirectionDeg:         c.wind_direction_10m,
            cloudCoverPercent:        c.cloud_cover,
            precipitationMm:          c.precipitation,
            precipitationProbability: c.precipitation_probability,
            pressureHpa:              c.surface_pressure,
            visibilityKm:             c.visibility.map { $0 / 1000.0 }
        )
    }
}

// MARK: - Errors
enum OpenMeteoError: LocalizedError {
    case badURL, badResponse

    var errorDescription: String? {
        switch self {
        case .badURL:      return "Could not build Open-Meteo request URL."
        case .badResponse: return "Open-Meteo returned an unexpected response."
        }
    }
}

// MARK: - Response models
private struct OpenMeteoResponse: Decodable, Sendable {
    let current: CurrentBlock
}

private struct CurrentBlock: Decodable, Sendable {
    let temperature_2m: Double
    let dewpoint_2m: Double?
    let relative_humidity_2m: Int?
    let wind_speed_10m: Double
    let wind_gusts_10m: Double?
    let wind_direction_10m: Int?
    let cloud_cover: Int
    let precipitation: Double
    let precipitation_probability: Int?
    let surface_pressure: Double?
    let visibility: Double?
}
