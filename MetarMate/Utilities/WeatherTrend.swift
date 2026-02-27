import Foundation

// MARK: - Weather Trend
enum WeatherTrend: String {
    case improving = "improving"
    case deteriorating = "deteriorating"
    case steady = "steady"
    case unknown = "unknown"

    var spokenDescription: String { rawValue }
}

// MARK: - Trend Derivation
struct WeatherTrendAnalyzer {

    /// Derive trend by comparing current METAR flight category against the TAF's near-future forecast.
    /// Looks ahead up to 3 hours in the TAF to find a meaningful change.
    static func derive(metar: Metar, taf: Taf?) -> WeatherTrend {
        guard let taf = taf, taf.isValid else { return .unknown }

        let now = Date()
        let lookAheadWindow = now.addingTimeInterval(3 * 3600)

        // Find the forecast period that covers ~1-3 hours from now
        let futurePeriods = taf.forecasts.filter { forecast in
            forecast.fromTime > now && forecast.fromTime <= lookAheadWindow &&
            forecast.type != .tempo && forecast.type != .prob30 && forecast.type != .prob40
        }

        guard let futureForecast = futurePeriods.first else { return .steady }

        let currentRank = categoryRank(metar.flightCategory)
        let futureRank = categoryRank(futureForecast.flightCategory)

        if futureRank > currentRank {
            return .deteriorating
        } else if futureRank < currentRank {
            return .improving
        } else {
            return .steady
        }
    }

    // Higher rank = worse conditions
    private static func categoryRank(_ category: FlightCategory) -> Int {
        switch category {
        case .vfr:     return 0
        case .mvfr:    return 1
        case .ifr:     return 2
        case .lifr:    return 3
        case .unknown: return -1
        }
    }
}
