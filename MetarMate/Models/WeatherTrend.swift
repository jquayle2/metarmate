import Foundation

// MARK: - Trend Direction
enum TrendDirection: String, Codable {
    case improving = "Improving"
    case steady = "Steady"
    case deteriorating = "Deteriorating"
    case unknown = "Unknown"

    var systemImage: String {
        switch self {
        case .improving: return "arrow.up.circle.fill"
        case .steady: return "equal.circle.fill"
        case .deteriorating: return "arrow.down.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

// MARK: - Weather Trend
struct WeatherTrend: Codable {
    var visibility: TrendDirection
    var ceiling: TrendDirection
    var wind: TrendDirection
    var overall: TrendDirection

    var overallCategory: FlightCategory?
    var summaryText: String

    // Derive from a METAR + TAF pair
    nonisolated static func derive(metar: Metar, taf: Taf?) -> WeatherTrend {
        guard let taf = taf, let current = taf.currentForecast,
              let next = taf.forecasts.first(where: { $0.fromTime > current.fromTime }) else {
            return WeatherTrend(visibility: .unknown, ceiling: .unknown,
                                wind: .unknown, overall: .unknown,
                                overallCategory: metar.flightCategory,
                                summaryText: "No TAF available for trend analysis.")
        }

        let visibilityTrend = trendFor(current: current.visibility ?? metar.visibility,
                                       next: next.visibility ?? metar.visibility,
                                       higherIsBetter: true)

        let currentCeiling = Double(current.clouds.first(where: {
            $0.coverage == .broken || $0.coverage == .overcast })?.altitude ?? 999) * 100
        let nextCeiling = Double(next.clouds.first(where: {
            $0.coverage == .broken || $0.coverage == .overcast })?.altitude ?? 999) * 100
        let ceilingTrend = trendFor(current: currentCeiling, next: nextCeiling, higherIsBetter: true)

        let currentWind = Double(current.wind?.speed ?? metar.wind.speed)
        let nextWind = Double(next.wind?.speed ?? metar.wind.speed)
        let windTrend = trendFor(current: currentWind, next: nextWind, higherIsBetter: false)

        let overallTrends = [visibilityTrend, ceilingTrend]
        let overall: TrendDirection
        if overallTrends.allSatisfy({ $0 == .improving }) { overall = .improving }
        else if overallTrends.allSatisfy({ $0 == .deteriorating }) { overall = .deteriorating }
        else { overall = .steady }

        let summary = "Conditions expected to be \(overall.rawValue.lowercased()) over the next few hours."

        return WeatherTrend(visibility: visibilityTrend, ceiling: ceilingTrend,
                            wind: windTrend, overall: overall,
                            overallCategory: next.flightCategory,
                            summaryText: summary)
    }

    private static func trendFor(current: Double, next: Double, higherIsBetter: Bool) -> TrendDirection {
        let delta = next - current
        let threshold = current * 0.1
        if abs(delta) < threshold { return .steady }
        let improving = higherIsBetter ? delta > 0 : delta < 0
        return improving ? .improving : .deteriorating
    }
}
