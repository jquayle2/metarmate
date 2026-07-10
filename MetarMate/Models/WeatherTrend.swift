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
    var ceilingDeltaFt: Int?
    var visibilityDeltaSM: Double?   // nil = fewer than two samples reported visibility
    var windDeltaKt: Int
    var spanHours: Double

    // Endpoints for "from → to" display
    var oldCeilingFt: Int?
    var newCeilingFt: Int?
    var oldVisibilitySM: Double?   // nil = endpoint didn't report visibility
    var newVisibilitySM: Double?
    var oldWindKt: Int          // sustained
    var newWindKt: Int
    var oldGustKt: Int?
    var newGustKt: Int?

    var spanText: String {
        spanHours < 1.5 ? "~1 hr" : "~\(Int(spanHours)) hrs"
    }

    // "5 → 20 kt (+15)" style — only shown when there's a meaningful change
    var windQuantitativeText: String {
        var parts: [String] = []
        let sustainedDelta = newWindKt - oldWindKt
        if abs(sustainedDelta) >= 3 || oldWindKt != newWindKt {
            let sign = sustainedDelta > 0 ? "+" : ""
            parts.append("Sustained: \(oldWindKt) → \(newWindKt) kt (\(sign)\(sustainedDelta))")
        }
        if let og = oldGustKt, let ng = newGustKt {
            let gDelta = ng - og
            let sign = gDelta > 0 ? "+" : ""
            parts.append("Gust: \(og) → \(ng) kt (\(sign)\(gDelta))")
        } else if oldGustKt == nil, let ng = newGustKt {
            parts.append("Gust: none → \(ng) kt")
        } else if let og = oldGustKt, newGustKt == nil {
            parts.append("Gust: \(og) kt → none")
        }
        return parts.joined(separator: "\n")
    }

    var visibilityQuantitativeText: String? {
        guard let delta = visibilityDeltaSM, let oldV = oldVisibilitySM, let newV = newVisibilitySM,
              abs(delta) >= 0.1 else { return nil }
        let sign = delta > 0 ? "+" : ""
        let oldStr = oldV >= 10 ? "10+" : String(format: "%g", oldV)
        let newStr = newV >= 10 ? "10+" : String(format: "%g", newV)
        return "\(oldStr) → \(newStr) SM (\(sign)\(String(format: "%g", delta)))"
    }

    var ceilingQuantitativeText: String? {
        guard let delta = ceilingDeltaFt, abs(delta) > 0 else { return nil }
        let sign = delta > 0 ? "+" : ""
        if let old = oldCeilingFt, let new = newCeilingFt {
            return "\(old.formatted()) → \(new.formatted()) ft (\(sign)\(delta.formatted()))"
        }
        if oldCeilingFt == nil, let new = newCeilingFt {
            return "Ceiling formed at \(new.formatted()) ft"
        }
        if let old = oldCeilingFt, newCeilingFt == nil {
            return "Ceiling cleared (was \(old.formatted()) ft)"
        }
        return nil
    }

    // Simple change text for steady conditions (no pill shown if truly no change)
    var windChangeText: String {
        if windDeltaKt == 0 && oldGustKt == newGustKt { return "No change" }
        let sign = windDeltaKt > 0 ? "+" : ""
        return "\(sign)\(windDeltaKt) kt"
    }

    var hasWindChange: Bool { windDeltaKt != 0 || oldGustKt != newGustKt }
    var hasVisibilityChange: Bool { if let d = visibilityDeltaSM { return abs(d) >= 0.1 } else { return false } }
    var hasCeilingChange: Bool { ceilingDeltaFt != nil && ceilingDeltaFt != 0 }
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

        // Visibility trend/delta use the newest and oldest samples that actually reported
        // visibility (metars are newest-first). Filter, never substitute a placeholder.
        let visReported = metars.filter { $0.visibilityReported }
        let visTrend: TrendDirection = visReported.count >= 2
            ? TrendThresholds.visibilityTrend(old: visReported.last!.visibility, new: visReported.first!.visibility)
            : .unknown
        let ceilTrend = TrendThresholds.ceilingTrend(old: oldest.ceilingFeet, new: newest.ceilingFeet)

        let oldWindSustained = oldest.wind.speed
        let newWindSustained = newest.wind.speed
        let oldWind = oldest.wind.gust ?? oldest.wind.speed
        let newWind = newest.wind.gust ?? newest.wind.speed
        let windTrend = TrendThresholds.windTrend(old: oldWind, new: newWind)

        let overall = deriveOverall(visibility: visTrend, ceiling: ceilTrend, wind: windTrend)

        let hoursSpan = newest.observationTime.timeIntervalSince(oldest.observationTime) / 3600
        let hoursText = hoursSpan < 1.5 ? "the past hour" : "the past \(Int(hoursSpan)) hours"

        // Summary reflects what's actually moving, not just overall consensus
        let summary: String
        let activeChanges = [visTrend, ceilTrend, windTrend].filter { $0 != .steady && $0 != .unknown }
        if activeChanges.isEmpty {
            summary = "No significant changes over \(hoursText) (\(metars.count) obs)."
        } else {
            summary = "\(metars.count) observations over \(hoursText)."
        }

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
            visibilityDeltaSM: visReported.count >= 2 ? visReported.first!.visibility - visReported.last!.visibility : nil,
            windDeltaKt: newWindSustained - oldWindSustained,
            spanHours: hoursSpan,
            oldCeilingFt: oldest.ceilingFeet,
            newCeilingFt: newest.ceilingFeet,
            oldVisibilitySM: visReported.last?.visibility,
            newVisibilitySM: visReported.first?.visibility,
            oldWindKt: oldWindSustained,
            newWindKt: newWindSustained,
            oldGustKt: oldest.wind.gust,
            newGustKt: newest.wind.gust
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

        // Only compare visibility when the METAR actually reported it — the `?? metar.visibility`
        // fallback must not lean on the 0.0 placeholder.
        let visTrend: TrendDirection = metar.visibilityReported
            ? TrendThresholds.visibilityTrend(old: metar.visibility, new: compareBlock.visibility ?? metar.visibility)
            : .unknown

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
        // If wind is the dominant story, reflect it in the summary
        let windIsSignificant = observed.wind != .steady && observed.overall == .steady
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
            summary = windIsSignificant ? "Ceiling and visibility steady. Wind is the main story." : "No significant changes observed or forecast."
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

        // Detect mixed conditions — some improving, some deteriorating
        let trends = [observed.ceiling, observed.visibility, observed.wind]
        let hasDeterioration = trends.contains(.deteriorating)
        let hasImprovement = trends.contains(.improving)

        if hasDeterioration && hasImprovement {
            var parts: [String] = []
            if observed.ceiling == .improving { parts.append("Ceiling rising") }
            if observed.visibility == .improving { parts.append("Visibility improving") }
            if observed.wind == .improving { parts.append("Wind easing") }
            if observed.ceiling == .deteriorating { parts.append("Ceiling falling") }
            if observed.visibility == .deteriorating { parts.append("Visibility dropping") }
            if observed.wind == .deteriorating { parts.append("Wind increasing") }
            return "Mixed — \(parts.joined(separator: ", "))"
        }

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
            if let delta = roc?.visibilityDeltaSM, abs(delta) >= 0.5 {
                return "Visibility Decreasing (\(String(format: "%g", delta)) SM)"
            }
            return "Visibility Decreasing"
        }
        if observed.visibility == .improving {
            if let delta = roc?.visibilityDeltaSM, abs(delta) >= 0.5 {
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
