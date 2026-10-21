import Foundation

// MARK: - "Right now" beside a borrowed TAF (D#16)
// This field's current METAR beside the TAF station's. Warn-never-reassure: say something only when
// conditions here are worse; when either report is missing or not current, say which and compare
// nothing. "Worse" uses the Forecast Deviation Strip thresholds (Oct 21): lower flight category,
// ceiling more than 300 ft lower, visibility more than 0.5 SM lower (ignored when both are above
// 5 SM), sustained or peak wind (gust, else sustained) more than 5 kt higher. A missing item is
// "not reported" and skips only that comparison; it never counts as better.

/// One place's conditions reduced to what "worse here" compares. nil / `.notReported` = missing.
struct ComparableConditions {
    enum Ceiling: Equatable {
        case feet(Int)
        case none          // stated clear, or only FEW/SCT
        case notReported
    }

    var category: FlightCategory?
    var ceiling: Ceiling
    var visibility: Visibility
    var sustainedKt: Int?
    var peakKt: Int?

    init(metar: Metar) {
        category = metar.flightCategory == .unknown ? nil : metar.flightCategory
        if let c = metar.ceilingFeet {
            ceiling = .feet(c)
        } else {
            // An empty cloud list is "clear" only when the report says so (CLR/SKC/NCD/NSC/CAVOK).
            let tokens = Set(metar.rawText.split(separator: " ").map(String.init))
            let statedClear = !tokens.isDisjoint(with: ["CLR", "SKC", "NCD", "NSC", "CAVOK"])
            ceiling = (!metar.clouds.isEmpty || statedClear) ? .none : .notReported
        }
        visibility = metar.visibility
        sustainedKt = metar.wind.isReported ? metar.wind.speed : nil
        peakKt = metar.wind.isReported ? (metar.wind.gust ?? metar.wind.speed) : nil
    }

    /// A TAF period: its clouds are what was forecast (empty = not forecast).
    init(forecast: TafForecast) {
        category = forecast.flightCategory == .unknown ? nil : forecast.flightCategory
        if let c = ForecastRules.ceilingFeet(forecast) {
            ceiling = .feet(c)
        } else {
            ceiling = forecast.clouds.isEmpty ? .notReported : .none
        }
        visibility = forecast.visibility
        sustainedKt = forecast.wind?.speed
        peakKt = forecast.wind.map { $0.gust ?? $0.speed }
    }
}

enum WorseHere {

    struct Result: Equatable {
        var isWorse: Bool { !reasons.isEmpty }
        let reasons: [String]              // e.g. "ceiling 2,000 ft lower"
        let notReportedHere: [String]      // "visibility", "ceiling", "wind"
        let notReportedThere: [String]
    }

    static func compare(here: ComparableConditions, there: ComparableConditions) -> Result {
        var reasons: [String] = []
        var missingHere: [String] = [], missingThere: [String] = []

        if let h = here.category, let t = there.category, severity(h) > severity(t) {
            reasons.append("\(h.rawValue) here, \(t.rawValue) there")
        }

        switch (here.ceiling, there.ceiling) {
        case (.notReported, _), (_, .notReported):
            if here.ceiling == .notReported { missingHere.append("ceiling") }
            if there.ceiling == .notReported { missingThere.append("ceiling") }
        case (.feet(let h), .feet(let t)) where t - h > 300:
            reasons.append("ceiling \((t - h).formatted()) ft lower")
        case (.feet(let h), .none):
            reasons.append("ceiling \(h.formatted()) ft here, none there")
        default:
            break
        }

        switch (here.visibility.lowerBoundSM, there.visibility.lowerBoundSM) {
        case (let h?, let t?):
            if !(h > 5 && t > 5), t - h > 0.5 {
                reasons.append("visibility \(String(format: "%g", t - h)) SM lower")
            }
        default:
            if !here.visibility.isKnown { missingHere.append("visibility") }
            if !there.visibility.isKnown { missingThere.append("visibility") }
        }

        switch (here.sustainedKt, there.sustainedKt, here.peakKt, there.peakKt) {
        case (let hs?, let ts?, let hp?, let tp?):
            if hs - ts > 5 { reasons.append("wind \(hs - ts) kt stronger") }
            else if hp - tp > 5 { reasons.append("gusts \(hp - tp) kt stronger") }
        default:
            if here.sustainedKt == nil { missingHere.append("wind") }
            if there.sustainedKt == nil { missingThere.append("wind") }
        }

        return Result(reasons: reasons, notReportedHere: missingHere, notReportedThere: missingThere)
    }

    private static func severity(_ c: FlightCategory) -> Int {
        switch c {
        case .vfr: return 0
        case .mvfr: return 1
        case .ifr: return 2
        case .lifr: return 3
        case .unknown: return -1
        }
    }
}

/// The "Right now" row: both reports with their ages, and either a comparison or which report
/// isn't current.
struct RightNow {
    let fieldId: String
    let stationId: String
    let field: Metar?
    let station: Metar?
    let notCurrent: [String]               // "KCDC report not current" — no comparison then
    let comparison: WorseHere.Result?

    static let worseText = "Conditions here are worse than at the TAF site"

    static func make(fieldId: String, field: Metar?, stationId: String, station: Metar?, at now: Date) -> RightNow {
        func isCurrent(_ m: Metar?) -> Bool {
            guard let m else { return false }
            if case .noCurrent = WidgetWeatherSnapshot.reportAge(observationTime: m.observationTime, at: now) { return false }
            return true
        }
        var notCurrent: [String] = []
        if !isCurrent(field) { notCurrent.append("\(fieldId) report not current") }
        if !isCurrent(station) { notCurrent.append("\(stationId) report not current") }
        var comparison: WorseHere.Result?
        if notCurrent.isEmpty, let field, let station {
            comparison = WorseHere.compare(here: ComparableConditions(metar: field), there: ComparableConditions(metar: station))
        }
        return RightNow(fieldId: fieldId, stationId: stationId, field: field, station: station,
                        notCurrent: notCurrent, comparison: comparison)
    }

    /// "Visibility not reported at KCDC" for each item a comparison had to skip.
    var notReportedLines: [String] {
        guard let comparison else { return [] }
        return comparison.notReportedHere.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) not reported at \(fieldId)" }
            + comparison.notReportedThere.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) not reported at \(stationId)" }
    }

    /// One report on the row: "ceiling 700 ft · vis 5 SM · wind 5 kt". Missing is "not reported".
    static func summary(_ m: Metar) -> String {
        let c = ComparableConditions(metar: m)
        let ceiling: String
        switch c.ceiling {
        case .feet(let ft):  ceiling = "ceiling \(ft.formatted()) ft"
        case .none:          ceiling = "no ceiling"
        case .notReported:   ceiling = "ceiling not reported"
        }
        let vis = m.visibility.displayNumber.map { "vis \($0) SM" } ?? "vis not reported"
        let wind: String
        if !m.wind.isReported { wind = "wind not reported" }
        else if m.wind.speed == 0 && m.wind.gust == nil { wind = "wind calm" }
        else { wind = "wind \(m.wind.speed)\(m.wind.gust.map { "G\($0)" } ?? "") kt" }
        return [ceiling, vis, wind].joined(separator: " · ")
    }

    /// The borrowed hero's subject, and the lead when this field is worse than the TAF's current
    /// period: ("KCDC (45 nm W)", ("KBCE", .ifr)) → "KBCE is IFR now. KCDC (45 nm W) forecasts …".
    /// No lead when this field's METAR isn't current or its category is unknown.
    static func heroLead(fieldId: String, field: Metar?, taf: Taf, source: TafSource, at now: Date)
        -> (stationLabel: String, fieldLead: (id: String, category: FlightCategory)?) {
        guard let field, field.flightCategory != .unknown, fieldWorseThanForecast(field: field, taf: taf, at: now) else {
            return (source.stationId, nil)
        }
        return ("\(source.stationId) (\(source.distanceNm) nm \(source.bearing))", (fieldId, field.flightCategory))
    }

    /// For the hero: is this field's current METAR worse than the TAF's period covering now?
    static func fieldWorseThanForecast(field: Metar?, taf: Taf, at now: Date) -> Bool {
        guard let field, let period = taf.currentForecast(at: now) else { return false }
        if case .noCurrent = WidgetWeatherSnapshot.reportAge(observationTime: field.observationTime, at: now) { return false }
        return WorseHere.compare(here: ComparableConditions(metar: field), there: ComparableConditions(forecast: period)).isWorse
    }
}
