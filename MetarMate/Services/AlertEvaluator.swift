import Foundation

// MARK: - Go / No-Go side
// Every trigger collapses to a binary side. lastFiredState on the model stores this raw
// string (GO / NO_GO) — never a raw measurement — so re-evaluations only act on a *change*
// of side, not on the absolute value.
enum GoNoGo: String {
    case go = "GO"
    case noGo = "NO_GO"
}

// MARK: - AlertDecision
// Pure result of evaluating one alert against one conditions snapshot. The evaluator does NOT
// fetch and does NOT post notifications — it reports what should happen. Step 4 owns fetching,
// firing the UNUserNotification, and persisting newSide back into lastFiredState.
struct AlertDecision {
    let shouldFire: Bool
    let newSide: GoNoGo
    let title: String?
    let body: String?

    static func noChange(_ side: GoNoGo) -> AlertDecision {
        AlertDecision(shouldFire: false, newSide: side, title: nil, body: nil)
    }
}

// MARK: - Deadbands
// A deadband is hysteresis to stop a value sitting on the limit from chattering side-to-side.
// It is deliberately SMALLER than the project's TrendThresholds (those answer "is this a
// trend?"; a deadband only answers "have we cleanly crossed the user's limit?").
//
//   wind / crosswind / gust : 2 kt   (brief-specified; below the 3 kt strong-wind trend step)
//   category                : 0.5    (half a category step; categories are already quantized,
//                                      so this just formalizes "a full category move is needed")
//   visibility              : 0.25 SM  <-- PROPOSED, sanity-check
//   ceiling                 : 100 ft   <-- PROPOSED, sanity-check
//
// PROPOSED vis/ceiling, anchored to Models/WeatherTrend.swift TrendThresholds:
//   - vis 0.25 SM == the tightest meaningful vis increment the app already uses (sub-LIFR).
//   - ceiling 100 ft == half the tightest meaningful ceiling increment (200 ft sub-IFR).
// Both are intentionally at/under that floor so the deadband debounces without swallowing a
// real crossing. Flagged for Jeff to confirm against the trend thresholds.
private enum Deadband {
    static let windKt = 2.0
    static let crosswindKt = 2.0
    static let gustKt = 2.0
    static let categoryStep = 0.5
    static let visibilitySM = 0.25
    static let ceilingFt = 100.0
}

// MARK: - AlertEvaluator
// @MainActor because the crosswind evaluator reads RunwayService (a @MainActor singleton over
// the bundled runways.json). The other three are pure computation; keeping the whole type on
// the main actor gives Step 4 one uniform call surface.
@MainActor
enum AlertEvaluator {

    // MARK: Crosswind
    // Picks the favored runway via RunwayService.bestRunway (which uses gust when present),
    // then compares the resulting crosswind component against the per-alert limit, falling
    // back to the register-defaulted global minimum (15 kt). Body shows sustained AND gust.
    static func evaluateCrosswind(_ alert: WeatherAlert,
                                  _ conditions: AlertConditions,
                                  previousSide: GoNoGo?) -> AlertDecision {
        // Variable / calm wind -> can't compute a meaningful crosswind; hold side, don't fire.
        guard let windDir = conditions.windDirection else {
            return .noChange(previousSide ?? .go)
        }

        let limit = Double(alert.crosswindLimitKt
            ?? UserDefaults.standard.integer(forKey: "globalCrosswindMinimumKt"))
        let gust = conditions.windGust.map(Double.init)

        guard let best = RunwayService.shared.bestRunway(for: alert.icao,
                                                          windDirection: windDir,
                                                          windSpeed: Double(conditions.windSpeed),
                                                          windGust: gust) else {
            // No runway data for this airport -> can't evaluate; hold side, don't fire.
            return .noChange(previousSide ?? .go)
        }

        // best.crosswind already reflects gust when a gust was supplied (worst case).
        let value = Double(best.crosswind)
        let newSide = side(value: value, limit: limit, deadband: Deadband.crosswindKt,
                           worseWhenHigher: true, previous: previousSide)

        let sustainedXw = crosswindComponent(windDir: windDir,
                                              speed: Double(conditions.windSpeed),
                                              runwayHeading: best.runwayEnd.heading)
        let gustXw: Int? = (conditions.windGust != nil) ? best.crosswind : nil
        let limitKt = Int(limit)
        let label = sourceLabel(conditions)

        let body: String
        if newSide == .noGo {
            var parts = "Rwy \(best.runwayEnd.ident): \(sustainedXw) kt crosswind"
            if let g = gustXw, g > sustainedXw { parts += ", \(g) kt in gusts" }
            body = "\(parts) — over your \(limitKt) kt limit. \(label)."
        } else {
            body = "Rwy \(best.runwayEnd.ident): crosswind back under \(limitKt) kt (\(sustainedXw) kt now). \(label)."
        }
        let title = (newSide == .noGo) ? "Crosswind — \(alert.icao)" : "Crosswind eased — \(alert.icao)"

        return decide(alert: alert, previous: previousSide, new: newSide, title: title, body: body)
    }

    // MARK: Flight category
    // GO/NO_GO line defaults to the IFR boundary: VFR/MVFR = GO, IFR/LIFR = NO_GO.
    // AVIATION JUDGMENT (flagged): whether MVFR should count as GO or NO_GO is Jeff's call.
    static func evaluateCategory(_ alert: WeatherAlert,
                                 _ conditions: AlertConditions,
                                 previousSide: GoNoGo?) -> AlertDecision {
        guard let ordinal = categoryOrdinal(conditions.flightCategory) else {
            return .noChange(previousSide ?? .go)   // unknown category -> can't evaluate
        }
        let ifrBoundary = 2.0   // VFR=0, MVFR=1, IFR=2, LIFR=3
        let newSide = side(value: ordinal, limit: ifrBoundary, deadband: Deadband.categoryStep,
                           worseWhenHigher: true, previous: previousSide)

        let cat = conditions.flightCategory.rawValue
        let label = sourceLabel(conditions)
        let title = (newSide == .noGo) ? "Conditions worsened — \(alert.icao)"
                                       : "Conditions improved — \(alert.icao)"
        let body = "Now \(cat). \(label)."
        return decide(alert: alert, previous: previousSide, new: newSide, title: title, body: body)
    }

    // MARK: Threshold (wind / gust / visibility / ceiling)
    // NO_GO when ANY configured limit is breached. Each metric carries its own deadband, and
    // hysteresis is applied to the aggregate: from GO, any single metric breaching by its
    // deadband -> NO_GO; from NO_GO, ALL metrics must clear by their deadband -> GO.
    static func evaluateThreshold(_ alert: WeatherAlert,
                                  _ conditions: AlertConditions,
                                  previousSide: GoNoGo?) -> AlertDecision {
        var metrics: [ThresholdMetric] = []
        if let lim = alert.windLimitKt {
            metrics.append(.init(name: "wind", value: Double(conditions.windSpeed),
                                 limit: Double(lim), deadband: Deadband.windKt,
                                 worseWhenHigher: true, unit: "kt"))
        }
        if let lim = alert.gustLimitKt {
            // No gust reported -> treat as the sustained wind for gust-limit purposes.
            let g = Double(conditions.windGust ?? conditions.windSpeed)
            metrics.append(.init(name: "gust", value: g, limit: Double(lim),
                                 deadband: Deadband.gustKt, worseWhenHigher: true, unit: "kt"))
        }
        if let lim = alert.visLimitSM {
            metrics.append(.init(name: "visibility", value: conditions.visibilitySM,
                                 limit: lim, deadband: Deadband.visibilitySM,
                                 worseWhenHigher: false, unit: "SM"))
        }
        if let lim = alert.ceilingLimitFt {
            // No ceiling (clear/FEW/SCT) -> effectively unlimited; use a high sentinel so a
            // ceiling limit is never "breached" by clear skies.
            let ceil = Double(conditions.ceilingFeet ?? 99_000)
            metrics.append(.init(name: "ceiling", value: ceil, limit: Double(lim),
                                 deadband: Deadband.ceilingFt, worseWhenHigher: false, unit: "ft"))
        }

        guard !metrics.isEmpty else { return .noChange(previousSide ?? .go) }

        let anyBreachedHard = metrics.contains { $0.breachesWorse() }   // past limit + deadband
        let allCleared = metrics.allSatisfy { $0.clears() }            // inside limit - deadband
        let newSide: GoNoGo
        switch previousSide {
        case .go:   newSide = anyBreachedHard ? .noGo : .go
        case .noGo: newSide = allCleared ? .go : .noGo
        case nil:   newSide = metrics.contains { $0.breachesBare() } ? .noGo : .go
        }

        let label = sourceLabel(conditions)
        let breached = metrics.filter { $0.breachesBare() }
        let title = (newSide == .noGo) ? "Weather limit — \(alert.icao)"
                                       : "Back within limits — \(alert.icao)"
        let body: String
        if newSide == .noGo, !breached.isEmpty {
            body = breached.map { $0.describe() }.joined(separator: ", ") + ". \(label)."
        } else {
            body = "All limits clear. \(label)."
        }
        return decide(alert: alert, previous: previousSide, new: newSide, title: title, body: body)
    }

    // MARK: TAF change (PROVISIONAL semantic — see flag)
    // The locked evaluator signature passes only observed AlertConditions (no Taf), so this
    // cannot do a true forecast-vs-forecast diff. Provisional meaning: fire when OBSERVED
    // conditions cross the IFR boundary *inside* the alert's [tafWindowStart, tafWindowEnd]
    // watch window — i.e. "tell me if it actually goes bad during my planned window." Outside
    // the window the alert is inert (GO, no fire). FLAGGED: if Jeff wants real TAF-forecast
    // alerting, the signature/AlertConditions must carry forecast data (a Step 3 follow-up).
    static func evaluateTafChange(_ alert: WeatherAlert,
                                  _ conditions: AlertConditions,
                                  previousSide: GoNoGo?) -> AlertDecision {
        // Outside the watch window -> inert.
        if let start = alert.tafWindowStart, conditions.timestamp < start {
            return .noChange(previousSide ?? .go)
        }
        if let end = alert.tafWindowEnd, conditions.timestamp > end {
            return .noChange(previousSide ?? .go)
        }
        guard let ordinal = categoryOrdinal(conditions.flightCategory) else {
            return .noChange(previousSide ?? .go)
        }
        let ifrBoundary = 2.0
        let newSide = side(value: ordinal, limit: ifrBoundary, deadband: Deadband.categoryStep,
                           worseWhenHigher: true, previous: previousSide)
        let label = sourceLabel(conditions)
        let title = (newSide == .noGo) ? "Window conditions worsened — \(alert.icao)"
                                       : "Window conditions improved — \(alert.icao)"
        let body = "Now \(conditions.flightCategory.rawValue) during your watch window. \(label)."
        return decide(alert: alert, previous: previousSide, new: newSide, title: title, body: body)
    }

    // MARK: - Hysteresis core
    // Computes the new side with a deadband. `worseWhenHigher` flips the comparison so the
    // same logic serves "higher is worse" (wind, gust, crosswind, category ordinal) and
    // "lower is worse" (visibility, ceiling). With no prior side, classify against the bare
    // limit (deadband only governs RE-crossing).
    private static func side(value: Double, limit: Double, deadband: Double,
                             worseWhenHigher: Bool, previous: GoNoGo?) -> GoNoGo {
        let m = worseWhenHigher ? value : -value
        let lim = worseWhenHigher ? limit : -limit
        switch previous {
        case .go:   return m > lim + deadband ? .noGo : .go
        case .noGo: return m < lim - deadband ? .go : .noGo
        case nil:   return m > lim ? .noGo : .go
        }
    }

    // Turns a side change into a fire/no-fire decision, honoring the alert's direction filter.
    // No prior side (first evaluation / freshly created alert) establishes a baseline silently
    // — it never fires, even if conditions are already bad. PRODUCT NOTE (flagged): creating an
    // alert during already-bad weather will not instantly fire; it arms for the next change.
    private static func decide(alert: WeatherAlert, previous: GoNoGo?, new: GoNoGo,
                               title: String, body: String) -> AlertDecision {
        guard let previous, previous != new else {
            return AlertDecision(shouldFire: false, newSide: new, title: nil, body: nil)
        }
        let worsening = (previous == .go && new == .noGo)
        let improving = (previous == .noGo && new == .go)
        let allowed: Bool
        switch alert.alertDirection ?? .both {
        case .worsening: allowed = worsening
        case .improving: allowed = improving
        case .both:      allowed = worsening || improving
        }
        return AlertDecision(shouldFire: allowed, newSide: new,
                             title: allowed ? title : nil,
                             body: allowed ? body : nil)
    }

    // MARK: - Helpers
    private static func crosswindComponent(windDir: Int, speed: Double, runwayHeading: Int) -> Int {
        let angle = Double(windDir - runwayHeading) * .pi / 180
        return abs(Int((speed * sin(angle)).rounded()))
    }

    private static func categoryOrdinal(_ cat: FlightCategory) -> Double? {
        switch cat {
        case .vfr:     return 0
        case .mvfr:    return 1
        case .ifr:     return 2
        case .lifr:    return 3
        case .unknown: return nil
        }
    }

    private static func sourceLabel(_ c: AlertConditions) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        let z = f.string(from: c.timestamp)
        switch c.source {
        case .asos:  return "via live ASOS, \(z)"
        case .metar: return "via METAR, \(z)"
        }
    }
}

// MARK: - Threshold metric helper
private struct ThresholdMetric {
    let name: String
    let value: Double
    let limit: Double
    let deadband: Double
    let worseWhenHigher: Bool
    let unit: String

    // Past the limit at all (no deadband) — used for the first-eval baseline and the body list.
    func breachesBare() -> Bool {
        worseWhenHigher ? value > limit : value < limit
    }
    // Past the limit by the full deadband — used to flip GO -> NO_GO.
    func breachesWorse() -> Bool {
        worseWhenHigher ? value > limit + deadband : value < limit - deadband
    }
    // Inside the limit by the full deadband — used to flip NO_GO -> GO.
    func clears() -> Bool {
        worseWhenHigher ? value < limit - deadband : value > limit + deadband
    }
    func describe() -> String {
        let v = (unit == "SM") ? String(format: "%.1f", value) : String(Int(value.rounded()))
        let l = (unit == "SM") ? String(format: "%.1f", limit) : String(Int(limit.rounded()))
        let rel = worseWhenHigher ? "over" : "under"
        return "\(name) \(v) \(unit) (\(rel) \(l) \(unit))"
    }
}
