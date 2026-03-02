import Foundation

// MARK: - Open-Meteo Service
// Fetches advisory weather for airports that lack official AWOS/ASOS reporting.
// Uses the free Open-Meteo API (no key required, CC BY 4.0).
// Data is for situational awareness only — not certified aviation weather.

actor OpenMeteoService {
    static let shared = OpenMeteoService()
    private let session = URLSession.shared
    private let base = "https://api.open-meteo.com/v1/forecast"

    private init() {}

    func fetchAdvisory(for airport: Airport) async throws -> AdvisoryWeather {
        guard let url = buildURL(airport: airport) else { throw OpenMeteoError.badURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenMeteoError.badResponse
        }

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return buildAdvisory(airport: airport, response: decoded)
    }

    // MARK: - URL builder

    private func buildURL(airport: Airport) -> URL? {
        let hourlyVars = [
            "temperature_2m", "dewpoint_2m", "wind_speed_10m",
            "wind_gusts_10m", "wind_direction_10m", "cloud_cover",
            "precipitation", "visibility", "surface_pressure"
        ].joined(separator: ",")

        let currentVars = [
            "temperature_2m", "dewpoint_2m", "relative_humidity_2m",
            "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m",
            "cloud_cover", "precipitation", "precipitation_probability",
            "surface_pressure", "visibility"
        ].joined(separator: ",")

        var c = URLComponents(string: base)!
        c.queryItems = [
            .init(name: "latitude",         value: String(airport.latitude)),
            .init(name: "longitude",        value: String(airport.longitude)),
            .init(name: "current",          value: currentVars),
            .init(name: "hourly",           value: hourlyVars),
            .init(name: "past_hours",       value: "6"),
            .init(name: "forecast_hours",   value: "6"),
            .init(name: "wind_speed_unit",  value: "kn"),
            .init(name: "temperature_unit", value: "celsius"),
            .init(name: "timeformat",       value: "unixtime"),
            .init(name: "timezone",         value: "UTC"),
        ]
        return c.url
    }

    // MARK: - Model assembly

    private func buildAdvisory(airport: Airport, response: OpenMeteoResponse) -> AdvisoryWeather {
        let c = response.current
        let h = response.hourly

        let now = Date()
        let sixHoursAgo = now.addingTimeInterval(-6 * 3600)

        // Split hourly array into past (history) and future (forecast) buckets
        var historySlots: [HourlySlot] = []
        var forecastSlots: [HourlySlot] = []

        if let times = h.time {
            for (i, t) in times.enumerated() {
                let slotDate = Date(timeIntervalSince1970: Double(t))
                let slot = HourlySlot(
                    time:        slotDate,
                    tempC:       h.temperature_2m?[safe: i] ?? c.temperature_2m,
                    dewC:        h.dewpoint_2m?[safe: i],
                    windKt:      h.wind_speed_10m?[safe: i] ?? c.wind_speed_10m,
                    gustKt:      h.wind_gusts_10m?[safe: i],
                    windDir:     h.wind_direction_10m?[safe: i],
                    cloudPct:    h.cloud_cover?[safe: i] ?? c.cloud_cover,
                    precipMm:    h.precipitation?[safe: i] ?? 0,
                    visKm:       (h.visibility?[safe: i]).map { $0 / 1000.0 },
                    pressHpa:    h.surface_pressure?[safe: i]
                )
                if slotDate <= now && slotDate >= sixHoursAgo {
                    historySlots.append(slot)
                } else if slotDate > now {
                    forecastSlots.append(slot)
                }
            }
        }

        let trends = deriveTrends(history: historySlots)
        let forecast = forecastSlots.prefix(6).map { slot in
            AdvisoryForecastHour(
                time: slot.time, temperatureC: slot.tempC, dewpointC: slot.dewC,
                windSpeedKt: slot.windKt, windGustKt: slot.gustKt,
                windDirectionDeg: slot.windDir, cloudCoverPercent: slot.cloudPct,
                precipitationMm: slot.precipMm, visibilityKm: slot.visKm,
                pressureHpa: slot.pressHpa
            )
        }

        return AdvisoryWeather(
            airport:                   airport,
            fetchTime:                 Date(),
            temperatureC:              c.temperature_2m,
            dewpointC:                 c.dewpoint_2m,
            windSpeedKt:               c.wind_speed_10m,
            windGustKt:                c.wind_gusts_10m,
            windDirectionDeg:          c.wind_direction_10m,
            cloudCoverPercent:         c.cloud_cover,
            precipitationMm:           c.precipitation,
            precipitationProbability:  c.precipitation_probability,
            pressureHpa:               c.surface_pressure,
            visibilityKm:              c.visibility.map { $0 / 1000.0 },
            trends:                    trends,
            forecast:                  Array(forecast)
        )
    }

    // MARK: - Trend derivation from 6h history

    private func deriveTrends(history: [HourlySlot]) -> AdvisoryTrends? {
        guard history.count >= 2 else { return nil }
        let first = history.first!
        let last  = history.last!

        let pressureDelta: Double? = zip(first.pressHpa, last.pressHpa).map { $1 - $0 }
        let windDelta: Double      = last.windKt - first.windKt
        let tdFirst: Double?       = first.dewC.map { first.tempC - $0 }
        let tdLast:  Double?       = last.dewC.map  { last.tempC  - $0 }
        let tdDelta: Double?       = zip(tdFirst, tdLast).map { $1 - $0 }
        let visDelta: Double?      = zip(first.visKm, last.visKm).map { $1 - $0 }

        return AdvisoryTrends(
            pressure:          pressureTrend(delta: pressureDelta),
            windSpeed:         windTrend(delta: windDelta),
            tdSpread:          tdSpreadTrend(delta: tdDelta),
            visibility:        visTrend(delta: visDelta),
            pressureDeltaHpa:  pressureDelta,
            windDeltaKt:       windDelta,
            tdSpreadDeltaC:    tdDelta,
            visibilityDeltaKm: visDelta
        )
    }

    // Trend helpers — aviation-meaningful thresholds

    private func pressureTrend(delta: Double?) -> TrendDirection {
        guard let d = delta else { return .unknown }
        if d > 1.0  { return .improving }      // rising ≥ 1 hPa = improving
        if d < -1.0 { return .deteriorating }  // falling ≥ 1 hPa = deteriorating
        return .steady
    }

    private func windTrend(delta: Double) -> TrendDirection {
        if delta > 5.0  { return .deteriorating }   // +5 kt = worse
        if delta < -5.0 { return .improving }        // -5 kt = better
        return .steady
    }

    private func tdSpreadTrend(delta: Double?) -> TrendDirection {
        guard let d = delta else { return .unknown }
        if d > 2.0  { return .improving }      // spread widening = drying out
        if d < -2.0 { return .deteriorating }  // spread narrowing = moistening
        return .steady
    }

    private func visTrend(delta: Double?) -> TrendDirection {
        guard let d = delta else { return .unknown }
        if d > 1.0  { return .improving }      // +1 km
        if d < -1.0 { return .deteriorating }  // -1 km
        return .steady
    }
}

// MARK: - Internal helper for hourly array slots
private struct HourlySlot {
    let time:     Date
    let tempC:    Double
    let dewC:     Double?
    let windKt:   Double
    let gustKt:   Double?
    let windDir:  Int?
    let cloudPct: Int
    let precipMm: Double
    let visKm:    Double?
    let pressHpa: Double?
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
    let hourly:  HourlyBlock
}

private struct CurrentBlock: Decodable, Sendable {
    let temperature_2m:            Double
    let dewpoint_2m:               Double?
    let relative_humidity_2m:      Int?
    let wind_speed_10m:            Double
    let wind_gusts_10m:            Double?
    let wind_direction_10m:        Int?
    let cloud_cover:               Int
    let precipitation:             Double
    let precipitation_probability: Int?
    let surface_pressure:          Double?
    let visibility:                Double?
}

private struct HourlyBlock: Decodable, Sendable {
    let time:              [Int]?
    let temperature_2m:    [Double]?
    let dewpoint_2m:       [Double]?
    let wind_speed_10m:    [Double]?
    let wind_gusts_10m:    [Double]?
    let wind_direction_10m:[Int]?
    let cloud_cover:       [Int]?
    let precipitation:     [Double]?
    let visibility:        [Double]?
    let surface_pressure:  [Double]?
}

// MARK: - Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Optional zip helper
private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a = a, let b = b else { return nil }
    return (a, b)
}
