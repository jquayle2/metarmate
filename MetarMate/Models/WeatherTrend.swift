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

// MARK: - Aviation-aware trend helpers
// These use operationally meaningful thresholds instead of raw percentages.
// A ceiling dropping from 30,000 to 25,000 doesn't matter.
// A ceiling dropping from 2,000 to 1,200 absolutely matters.

private enum TrendThresholds {
    // Ceiling: only flag changes that cross or approach flight category boundaries
    // VFR > 3000, MVFR 1000-3000, IFR 500-1000, LIFR < 500
    static func ceilingTrend(old: Int?, new: Int?) -> TrendDirection {
        let oldFt = old ?? 99900
        let newFt = new ?? 99900

        // Both above 5000 — nobody cares
        if oldFt > 5000 && newFt > 5000 { return .steady }

        // Both are "no ceiling" (clear/FEW/SCT only)
        if oldFt >= 99000 && newFt >= 99000 { return .steady }

        let delta = newFt - oldFt

        // When ceilings are lower, smaller changes matter more
        let threshold: Int
        if min(oldFt, newFt) < 1000 {
            threshold = 200   // sub-IFR: 200ft matters
        } else if min(oldFt, newFt) < 3000 {
            threshold = 500   // MVFR range: 500ft matters
        } else {
            threshold = 1000  // VFR: need 1000ft change to care
        }

        if abs(delta) < threshold { return .steady }
        return delta > 0 ? .improving : .deteriorating
    }

    // Visibility: only flag changes that cross or approach category boundaries
    // VFR > 5, MVFR 3-5, IFR 1-3, LIFR < 1
    static func visibilityTrend(old: Double, new: Double) -> TrendDirection {
        // Both 6+ SM — great vis, don't care about small changes
        if old >= 6.0 && new >= 6.0 { return .steady }

        let delta = new - old

        // When vis is low, smaller changes matter more
        let threshold: Double
        if min(old, new) < 1.0 {
            threshold = 0.25  // sub-LIFR: quarter mile matters
        } else if min(old, new) < 3.0 {
            threshold = 0.5   // IFR range: half mile matters
        } else if min(old, new) < 5.0 {
            threshold = 1.0   // MVFR range: 1 mile matters
        } else {
            threshold = 2.0   // VFR: need 2 mile change to care
        }

        if abs(delta) < threshold { return .steady }
        return delta > 0 ? .improving : .deteriorating
    }

    // Wind: flag when operationally significant
    // Light winds < 10kt — most pilots don't care about changes
    // Moderate 10-20kt — changes of 5+ kt matter
    // Strong > 20kt — any increase matters
    static func windTrend(old: Int, new: Int) -> TrendDirection {
        let delta = new - old

        // Both light and calm — doesn't matter
        if old <= 10 && new <= 10 { return .steady }

        // Threshold scales with wind speed
        let threshold: Int
        if max(old, new) > 20 {
            threshold = 3    // strong winds: 3kt change matters
        } else {
            threshold = 5    // moderate winds: 5kt change matters
        }

        if abs(delta) < threshold { return .steady }
        // For wind, increasing = deteriorating
        return delta > 0 ? .deteriorating : .improving
    }
}

// MARK: - Rate of Change (actual numeric deltas over observation window)
struct RateOfChange: Codable {
    var ceilingDeltaFt: Int?        // positive = rising, negative = falling, nil = no ceiling either end
    var visibilityDeltaSM: Double   // positive = improving
    var windDeltaKt: Int            // positive = increasing (using peak speed/gust)
    var spanHours: Double           // observation window in hours

    // Human-readable delta strings
    var ceilingChangeText: String {
        guard let delta = ceilingDeltaFt else { return "—" }
        if delta == 0 { return "No change" }
        let sign = delta > 0 ? "+" : ""
        return "\(sign)\(delta.formatted()) ft"
    }

    var visibilityChangeText: String {
        if abs(visibilityDeltaSM) < 0.1 { return "No change" }
        let sign = visibilityDeltaSM > 0 ? "+" : ""
        return "\(sign)\(String(format: "%g", visibilityDeltaSM)) SM"
    }

    var windChangeText: String {
        if windDeltaKt == 0 { return "No change" }
        let sign = windDeltaKt > 0 ? "+" : ""
        return "\(sign)\(windDeltaKt) kt"
    }

    var spanText: String {
        spanHours < 1.5 ? "~1 hr" : "~\(Int(spanHours)) hrs"
    }
}

// MARK: - Observed Trend (derived from METAR history)
struct ObservedTrend: Codable {
    var visibility: TrendDirection
    var ceiling: TrendDirection
    var wind: TrendDirection
    var overall: TrendDirection
    var summaryText: String
    var metarCount: Int
    var rateOfChange: RateOfChange?

    static func derive(from metars: [Metar]) -> ObservedTrend {
        guard metars.count >= 2 else {
            return ObservedTrend(
                visibility: .unknown, ceiling: .unknown,
                wind: .unknown, overall: .unknown,
                summaryText: "Not enough observations for trend analysis.",
                metarCount: metars.count,
                rateOfChange: nil
            )
        }

        // metars come newest first from API — oldest is last
        let newest = metars.first!
        let oldest = metars.last!

        let visTrend = TrendThresholds.visibilityTrend(old: oldest.visibility, new: newest.visibility)
        let ceilTrend = TrendThresholds.ceilingTrend(old: oldest.ceilingFeet, new: newest.ceilingFeet)

        let oldWind = oldest.wind.gust ?? oldest.wind.speed
        let newWind = newest.wind.gust ?? newest.wind.speed
        let windTrend = TrendThresholds.windTrend(old: oldWind, new: newWind)

        let overall = deriveOverall(visibility: visTrend, ceiling: ceilTrend, wind: windTrend)

        let hoursSpan = newest.observationTime.timeIntervalSince(oldest.observationTime) / 3600
        let hoursText = hoursSpan < 1.5 ? "the past hour" : "the past \(Int(hoursSpan)) hours"
        let summary = "Conditions have been \(overall.rawValue.lowercased()) over \(hoursText) (\(metars.count) observations)."

        // Compute rate of change deltas (newest - oldest)
        let ceilDelta: Int?
        if let oldCeil = oldest.ceilingFeet, let newCeil = newest.ceilingFeet {
            ceilDelta = newCeil - oldCeil
        } else if oldest.ceilingFeet == nil && newest.ceilingFeet == nil {
            ceilDelta = 0
        } else {
            ceilDelta = nil  // ceiling appeared or disappeared
        }

        let roc = RateOfChange(
            ceilingDeltaFt: ceilDelta,
            visibilityDeltaSM: newest.visibility - oldest.visibility,
            windDeltaKt: newWind - oldWind,
            spanHours: hoursSpan
        )

        return ObservedTrend(
            visibility: visTrend, ceiling: ceilTrend,
            wind: windTrend, overall: overall,
            summaryText: summary,
            metarCount: metars.count,
            rateOfChange: roc
        )
    }

    private static func deriveOverall(visibility: TrendDirection, ceiling: TrendDirection, wind: TrendDirection) -> TrendDirection {
        let critical = [visibility, ceiling]

        if critical.contains(.deteriorating) { return .deteriorating }
        if critical.allSatisfy({ $0 == .improving }) { return .improving }
        if critical.allSatisfy({ $0 == .steady || $0 == .unknown }) {
            if wind == .deteriorating { return .steady }
            return .steady
        }
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
        guard let taf = taf, let current = taf.currentForecast else {
            return ForecastTrend(
                visibility: .unknown, ceiling: .unknown,
                wind: .unknown, overall: .unknown,
                forecastCategory: nil,
                summaryText: "No TAF available for forecast trend."
            )
        }

        // Try to find the next period after current for forward-looking trend
        // If no next period, compare current METAR against the current TAF period
        let compareBlock = taf.forecasts.first(where: { $0.fromTime > current.fromTime }) ?? current
        let isForwardLooking = compareBlock.fromTime > current.fromTime

        let visTrend = TrendThresholds.visibilityTrend(
            old: metar.visibility,
            new: compareBlock.visibility ?? metar.visibility
        )

        let compareCeiling = ceilingFromClouds(compareBlock.clouds)
        let ceilTrend = TrendThresholds.ceilingTrend(old: metar.ceilingFeet, new: compareCeiling)

        let currentWind = metar.wind.gust ?? metar.wind.speed
        let nextWind = compareBlock.wind?.gust ?? compareBlock.wind?.speed ?? metar.wind.speed
        let windTrend = TrendThresholds.windTrend(old: currentWind, new: nextWind)

        let critical = [visTrend, ceilTrend]
        let overall: TrendDirection
        if critical.contains(.deteriorating) { overall = .deteriorating }
        else if critical.allSatisfy({ $0 == .improving }) { overall = .improving }
        else { overall = .steady }

        let timeframe = isForwardLooking ? "over the next few hours" : "for the current period"
        let summary = "Forecast expects conditions to be \(overall.rawValue.lowercased()) \(timeframe)."

        return ForecastTrend(
            visibility: visTrend, ceiling: ceilTrend,
            wind: windTrend, overall: overall,
            forecastCategory: compareBlock.flightCategory,
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
    var headline: String        // short, specific — surfaces the most important thing
    var summaryText: String     // supporting detail

    static func derive(metars: [Metar], taf: Taf?) -> WeatherTrend {
        let currentMetar = metars.first ?? metars[0]
        let observed = ObservedTrend.derive(from: metars)
        let forecast = ForecastTrend.derive(metar: currentMetar, taf: taf)

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

        // Headline: surface the single most operationally significant thing happening.
        // Priority: ceiling > visibility > wind. Forecast divergence noted when it conflicts.
        let headline = deriveHeadline(observed: observed, forecast: forecast)

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
            summary = "No significant changes observed or forecast."
        case (.steady, .improving):
            summary = "Conditions steady. Improvement expected ahead."
        case (.steady, .deteriorating):
            summary = "Conditions steady now but deterioration is forecast."
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
            headline: headline,
            summaryText: summary
        )
    }

    private static func deriveHeadline(observed: ObservedTrend, forecast: ForecastTrend) -> String {
        let roc = observed.rateOfChange

        // Ceiling is the most safety-critical — lead with it if it's moving
        if observed.ceiling == .deteriorating {
            if let delta = roc?.ceilingDeltaFt, abs(delta) > 0 {
                return "Ceiling Falling (\(delta.formatted()) ft)"
            }
            return "Ceiling Falling"
        }
        if observed.ceiling == .improving {
            if let delta = roc?.ceilingDeltaFt, abs(delta) > 0 {
                let sign = delta > 0 ? "+" : ""
                return "Ceiling Rising (\(sign)\(delta.formatted()) ft)"
            }
            return "Ceiling Rising"
        }

        // Visibility next
        if observed.visibility == .deteriorating {
            if let delta = roc.map({ $0.visibilityDeltaSM }), abs(delta) >= 0.5 {
                return "Visibility Decreasing (\(String(format: "%g", delta)) SM)"
            }
            return "Visibility Decreasing"
        }
        if observed.visibility == .improving {
            if let delta = roc.map({ $0.visibilityDeltaSM }), abs(delta) >= 0.5 {
                let sign = delta > 0 ? "+" : ""
                return "Visibility Increasing (\(sign)\(String(format: "%g", delta)) SM)"
            }
            return "Visibility Increasing"
        }

        // Wind — operationally significant even when flight category is VFR
        if observed.wind == .deteriorating {
            if let delta = roc?.windDeltaKt, delta > 0 {
                return "Wind Increasing (+\(delta) kt)"
            }
            return "Wind Increasing"
        }
        if observed.wind == .improving {
            return "Wind Decreasing"
        }

        // Forecast divergence — conditions are steady but something is coming
        if forecast.overall == .deteriorating {
            return "Deterioration Forecast"
        }
        if forecast.overall == .improving {
            return "Improvement Forecast"
        }

        return "Stable Conditions"
    }
}
