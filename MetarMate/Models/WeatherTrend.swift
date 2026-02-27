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

// MARK: - Shared trend comparison
private func trendFor(old: Double, new: Double, higherIsBetter: Bool) -> TrendDirection {
    let threshold = max(abs(old) * 0.1, 1.0)
    let delta = new - old
    if abs(delta) < threshold { return .steady }
    let improving = higherIsBetter ? delta > 0 : delta < 0
    return improving ? .improving : .deteriorating
}

// MARK: - Observed Trend (derived from METAR history)
struct ObservedTrend: Codable {
    var visibility: TrendDirection
    var ceiling: TrendDirection
    var wind: TrendDirection
    var overall: TrendDirection
    var summaryText: String
    var metarCount: Int

    static func derive(from metars: [Metar]) -> ObservedTrend {
        guard metars.count >= 2 else {
            return ObservedTrend(
                visibility: .unknown, ceiling: .unknown,
                wind: .unknown, overall: .unknown,
                summaryText: "Not enough observations for trend analysis.",
                metarCount: metars.count
            )
        }

        // metars come newest first from API — oldest is last
        let newest = metars.first!
        let oldest = metars.last!

        // Visibility trend
        let visTrend = trendFor(
            old: oldest.visibility,
            new: newest.visibility,
            higherIsBetter: true
        )

        // Ceiling trend — use ceiling in feet, treat nil (no ceiling) as 99900
        let oldCeiling = Double(oldest.ceilingFeet ?? 99900)
        let newCeiling = Double(newest.ceilingFeet ?? 99900)
        let ceilTrend = trendFor(old: oldCeiling, new: newCeiling, higherIsBetter: true)

        // Wind trend — compare effective wind (use gust if present)
        let oldWind = Double(oldest.wind.gust ?? oldest.wind.speed)
        let newWind = Double(newest.wind.gust ?? newest.wind.speed)
        let windTrend = trendFor(old: oldWind, new: newWind, higherIsBetter: false)

        // Overall: weight visibility and ceiling more heavily than wind
        let overall = deriveOverall(visibility: visTrend, ceiling: ceilTrend, wind: windTrend)

        let hoursSpan = newest.observationTime.timeIntervalSince(oldest.observationTime) / 3600
        let hoursText = hoursSpan < 1.5 ? "the past hour" : "the past \(Int(hoursSpan)) hours"
        let summary = "Conditions have been \(overall.rawValue.lowercased()) over \(hoursText) (\(metars.count) observations)."

        return ObservedTrend(
            visibility: visTrend, ceiling: ceilTrend,
            wind: windTrend, overall: overall,
            summaryText: summary,
            metarCount: metars.count
        )
    }

    private static func deriveOverall(visibility: TrendDirection, ceiling: TrendDirection, wind: TrendDirection) -> TrendDirection {
        let critical = [visibility, ceiling]

        if critical.contains(.deteriorating) { return .deteriorating }
        if critical.allSatisfy({ $0 == .improving }) { return .improving }
        if critical.allSatisfy({ $0 == .steady || $0 == .unknown }) { return .steady }

        // Mixed — one improving, one steady
        if critical.contains(.improving) && !critical.contains(.deteriorating) { return .improving }

        return .steady
    }
}

// MARK: - Forecast Trend (derived from current METAR vs TAF)
struct ForecastTrend: Codable {
    var visibility: TrendDirection
    var ceiling: TrendDirection
    var wind: TrendDirection
    var overall: TrendDirection
    var forecastCategory: FlightCategory?
    var summaryText: String

    static func derive(metar: Metar, taf: Taf?) -> ForecastTrend {
        guard let taf = taf, let current = taf.currentForecast,
              let next = taf.forecasts.first(where: { $0.fromTime > current.fromTime }) else {
            return ForecastTrend(
                visibility: .unknown, ceiling: .unknown,
                wind: .unknown, overall: .unknown,
                forecastCategory: nil,
                summaryText: "No TAF available for forecast trend."
            )
        }

        // Compare current conditions to next TAF period
        let visTrend = trendFor(
            old: metar.visibility,
            new: next.visibility ?? metar.visibility,
            higherIsBetter: true
        )

        let currentCeiling = Double(metar.ceilingFeet ?? 99900)
        let nextCeiling = Double(ceilingFromClouds(next.clouds) ?? 99900)
        let ceilTrend = trendFor(old: currentCeiling, new: nextCeiling, higherIsBetter: true)

        let currentWind = Double(metar.wind.gust ?? metar.wind.speed)
        let nextWind = Double(next.wind?.gust ?? next.wind?.speed ?? metar.wind.speed)
        let windTrend = trendFor(old: currentWind, new: nextWind, higherIsBetter: false)

        let critical = [visTrend, ceilTrend]
        let overall: TrendDirection
        if critical.contains(.deteriorating) { overall = .deteriorating }
        else if critical.allSatisfy({ $0 == .improving }) { overall = .improving }
        else { overall = .steady }

        let summary = "Forecast expects conditions to be \(overall.rawValue.lowercased()) over the next few hours."

        return ForecastTrend(
            visibility: visTrend, ceiling: ceilTrend,
            wind: windTrend, overall: overall,
            forecastCategory: next.flightCategory,
            summaryText: summary
        )
    }

    private static func ceilingFromClouds(_ clouds: [CloudLayer]) -> Int? {
        clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
            .map { $0.altitude * 100 }
    }
}

// MARK: - Combined Weather Trend (wraps both)
struct WeatherTrend: Codable {
    var observed: ObservedTrend
    var forecast: ForecastTrend
    var overall: TrendDirection
    var summaryText: String

    static func derive(metars: [Metar], taf: Taf?) -> WeatherTrend {
        let currentMetar = metars.first ?? metars[0]
        let observed = ObservedTrend.derive(from: metars)
        let forecast = ForecastTrend.derive(metar: currentMetar, taf: taf)

        // Overall: if both agree, use that; if they disagree, lean toward the worse signal
        let overall: TrendDirection
        if observed.overall == forecast.overall {
            overall = observed.overall
        } else if observed.overall == .deteriorating || forecast.overall == .deteriorating {
            overall = .deteriorating
        } else if observed.overall == .improving && forecast.overall == .steady {
            overall = .improving
        } else if observed.overall == .steady && forecast.overall == .improving {
            overall = .improving
        } else {
            overall = .steady
        }

        let summary: String
        switch (observed.overall, forecast.overall) {
        case (.improving, .improving):
            summary = "Conditions are improving and forecast agrees."
        case (.deteriorating, .deteriorating):
            summary = "Conditions are deteriorating and expected to continue."
        case (.deteriorating, .improving):
            summary = "Conditions have been deteriorating but forecast shows improvement ahead."
        case (.improving, .deteriorating):
            summary = "Conditions have been improving but forecast shows deterioration ahead."
        case (.steady, .steady):
            summary = "Conditions are steady with no significant changes expected."
        case (.steady, .improving):
            summary = "Conditions are steady with improvement expected."
        case (.steady, .deteriorating):
            summary = "Conditions are steady but deterioration is expected."
        case (.improving, .steady):
            summary = "Conditions have been improving and are expected to stabilize."
        case (.deteriorating, .steady):
            summary = "Conditions have been deteriorating but are expected to stabilize."
        default:
            summary = "Trend data is limited."
        }

        return WeatherTrend(
            observed: observed,
            forecast: forecast,
            overall: overall,
            summaryText: summary
        )
    }
}
