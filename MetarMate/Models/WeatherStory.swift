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
    let windSpeedKt: Int
    let windGustKt: Int?
    let ceilingFeet: Int?          // nil = unlimited
    let visibility: Visibility
}

enum ForecastRules {

    /// Ceiling in feet AGL for a TAF period — lowest BKN/OVC/VV layer, nil if none.
    /// Mirrors the existing tafCeilingFeet in WeatherDetailView.swift exactly.
    static func ceilingFeet(_ period: TafForecast) -> Int? {
        period.clouds
            .filter { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility }
            .map { $0.altitude * 100 }
            .min()
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
            windSpeedKt: period.wind?.speed ?? 0,
            windGustKt: period.wind?.gust,
            ceilingFeet: ceilFt,
            visibility: vis
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
        guard metars.count >= 2 else { return nil }
        let sorted = metars.sorted { $0.observationTime > $1.observationTime }  // defensive re-sort
        let current = sorted[0]
        let targetTime = current.observationTime.addingTimeInterval(-3 * 3600)

        // Closest sample AT OR BEFORE the 3-hr-ago mark; falls back to the oldest available
        // sample if history doesn't span 3 hrs yet. Either way, report the TRUE delta/span —
        // never extrapolated to a fixed 3-hr-equivalent number, which would amplify a short
        // window's noise into a misleadingly larger delta.
        let reference = sorted.first(where: { $0.observationTime <= targetTime }) ?? sorted.last!

        let spanHours = current.observationTime.timeIntervalSince(reference.observationTime) / 3600
        guard spanHours > 0 else { return nil }   // duplicate-timestamp guard

        let delta = current.altimeter - reference.altimeter
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
            currentAltimeter: current.altimeter,
            deltaInHg: delta,
            spanHours: spanHours,
            state: state,
            isRapid: isRapid,
            sparklineValues: sorted.reversed().map { $0.altimeter }
        )
    }
}
