//
//  WeatherStory.swift
//  MetarMate
//
//  Pure derivation functions for the TAF adaptive hero (limitingFactor) and the METAR
//  History pressure-trend card (pressureTrend). Foundation-only — no SwiftUI — mirroring
//  the WeatherTrend.swift convention (enum + static func) so these stay independently
//  testable. Threshold values are restated from Theme.swift's ColorRules (visibility 5 SM,
//  ceiling 3000 ft — the VFR/MVFR line) rather than imported, since ColorRules lives in a
//  SwiftUI file; keep the two in lockstep if either changes.
//

import Foundation

// MARK: - Limiting Factor (TAF hero)

enum LimitingFactorKind {
    case wind, ceiling, visibility
}

struct LimitingFactor {
    let kind: LimitingFactorKind
    let category: FlightCategory   // == period.flightCategory verbatim, never re-derived
    let windDirectionDeg: Int?     // nil if variable/calm
    let windSpeedKt: Int?          // nil = wind not forecast (never "Calm")
    let windGustKt: Int?
    let ceilingFeet: Int?          // nil = no ceiling or not forecast — see `ceiling`
    let ceiling: CeilingStatus
    let visibility: Visibility
    /// Compact ceiling value: feet, "CLR" only for a stated clear sky, "NO CIG" with FEW/SCT
    /// (F18), "—" when the sky isn't forecast (audit #16).
    let ceilingText: String
}

enum ForecastRules {

    /// Ceiling in feet AGL for a TAF period — lowest BKN/OVC/VV layer, nil if none.
    /// Mirrors the existing tafCeilingFeet in WeatherDetailView.swift exactly.
    static func ceilingFeet(_ period: TafForecast) -> Int? {
        period.ceiling.feet
    }

    /// TAF wind worth a Pilot Note, on the METAR card's thresholds: sustained >= 20 kt or a gust
    /// >= 15 kt; a warning at sustained >= 25 or gust >= 20. Strong steady wind counts, not just
    /// gusts (audit #19). nil when the wind isn't notable or wasn't forecast.
    static func notableWind(_ wind: Wind?) -> (gust: Int?, isWarning: Bool)? {
        guard let wind, wind.isReported else { return nil }
        let gust = wind.gust.flatMap { $0 > wind.speed ? $0 : nil }
        let gustAtLeast = { (kt: Int) in gust.map { $0 >= kt } == true }
        guard wind.speed >= 20 || gustAtLeast(15) else { return nil }
        return (gust, wind.speed >= 25 || gustAtLeast(20))
    }

    /// Periods whose wind gets a TAF Pilot Note: the remaining prevailing periods AND the
    /// remaining TEMPO/PROB/BECMG overlays (`TEMPO 30035G50KT` had no wind mention, audit #19).
    static func windNotePeriods(_ taf: Taf, now: Date) -> [TafForecast] {
        (taf.remainingTimeline(at: now) + taf.remainingOverlays(at: now))
            .filter { notableWind($0.wind) != nil }
    }

    /// Which of wind/ceiling/visibility is this period's limiting factor — whichever is
    /// closest to, or furthest past, its VFR/MVFR category boundary. Ties resolve
    /// visibility, then ceiling, then wind (per the design spec).
    static func limitingFactor(for period: TafForecast) -> LimitingFactor {
        let vis = period.visibility
        let ceilFt = ceilingFeet(period)

        // Severity is a 0...1+ scale normalized to the VFR/MVFR boundary (5 SM / 3000 ft,
        // matching ColorRules.visibilityColor/ceilingColor) — 0 at/above the boundary,
        // increasing as conditions worsen past it. Not clamped above 1 so a badly-past-LIFR
        // period still outranks a barely-past-MVFR one on the same axis. .greaterThan(6) reads off
        // its floor (6) -> severity 0 -> never the limiting factor; .unknown -> 0.
        let visSeverity: Double = vis.lowerBoundSM.map { max(0, (5.0 - $0) / 5.0) } ?? 0
        let ceilSeverity: Double = ceilFt.map { max(0, (3000.0 - Double($0)) / 3000.0) } ?? 0

        // Wind has no VFR-axis threshold in ColorRules (it isn't part of the category axis),
        // so this onset is a judgment call, not derived — 10 kt effective (gust-or-speed),
        // scaled over the next 10 kt. Isolated here; easy to retune after a real look.
        let windSeverity: Double = {
            guard let wind = period.wind else { return 0 }
            let effective = Double(wind.gust ?? wind.speed)
            return max(0, (effective - 10) / 10)
        }()

        let winner: LimitingFactorKind
        if visSeverity >= ceilSeverity && visSeverity >= windSeverity {
            winner = .visibility
        } else if ceilSeverity >= windSeverity {
            winner = .ceiling
        } else {
            winner = .wind
        }

        return LimitingFactor(
            kind: winner,
            category: period.flightCategory,
            windDirectionDeg: (period.wind?.isVariable == true) ? nil : period.wind?.direction,
            windSpeedKt: period.wind?.speed,
            windGustKt: period.wind?.gust,
            ceilingFeet: ceilFt,
            ceiling: period.ceiling,
            visibility: vis,
            ceilingText: {
                switch period.ceiling {
                case .feet(let f):  return f.formatted()
                case .none:         return period.clouds.contains { $0.coverage == .few || $0.coverage == .scattered } ? "NO CIG" : "CLR"
                case .notReported:  return "—"
                }
            }()
        )
    }
}

// MARK: - Pressure Trend (METAR History)

enum PressureState {
    case falling, steady, rising
}

struct PressureTrend {
    let currentAltimeter: Double   // inHg, most recent sample
    let deltaInHg: Double          // signed, current - reference; TRUE delta, never scaled
    let spanHours: Double          // actual elapsed hours the delta was computed over
    let state: PressureState
    let isRapid: Bool              // state == .falling and the rate crosses the rapid line
    let sparklineValues: [Double]  // oldest-first altimeter readings
}

enum HistoryRules {

    /// pressureTrend(metars) — metars newest-first (matches WeatherViewModel.metarHistory).
    /// Returns nil if fewer than 2 samples exist (no trend is knowable).
    static func pressureTrend(from metars: [Metar]) -> PressureTrend? {
        // Only reports that carry an altimeter: a missing one is not 29.92, and treating it as one
        // faked a "falling rapidly" trend (audit #8).
        let reported = metars.compactMap { m in m.altimeter.map { (m, $0) } }
        guard reported.count >= 2 else { return nil }
        let sorted = reported.sorted { $0.0.observationTime > $1.0.observationTime }  // defensive re-sort
        let current = sorted[0]
        let targetTime = current.0.observationTime.addingTimeInterval(-3 * 3600)

        // Closest sample AT OR BEFORE the 3-hr-ago mark; falls back to the oldest available
        // sample if history doesn't span 3 hrs yet. Either way, report the TRUE delta/span —
        // never extrapolated to a fixed 3-hr-equivalent number, which would amplify a short
        // window's noise into a misleadingly larger delta.
        let reference = sorted.first(where: { $0.0.observationTime <= targetTime }) ?? sorted.last!

        let spanHours = current.0.observationTime.timeIntervalSince(reference.0.observationTime) / 3600
        guard spanHours > 0 else { return nil }   // duplicate-timestamp guard

        let delta = current.1 - reference.1
        let ratePerHour = delta / spanHours

        let state: PressureState
        if delta <= -0.03 { state = .falling }
        else if delta >= 0.03 { state = .rising }
        else { state = .steady }

        // Rapid: 0.05 inHg/hr sustained fall. METAR pressure-tendency remarks are a 3-hr WMO/
        // FAA convention; a naive 0.06 inHg/3hr (~0.02/hr) is too twitchy against ordinary
        // hourly rounding noise between obs, so the rapid line sits meaningfully higher to
        // catch a real frontal passage while rejecting noise. Isolated, retunable constant.
        let isRapid = state == .falling && ratePerHour <= -0.05

        return PressureTrend(
            currentAltimeter: current.1,
            deltaInHg: delta,
            spanHours: spanHours,
            state: state,
            isRapid: isRapid,
            sparklineValues: sorted.reversed().map { $0.1 }
        )
    }
}
