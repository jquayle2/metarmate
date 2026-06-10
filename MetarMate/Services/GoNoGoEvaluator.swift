import Foundation

// MARK: - Verdict
// Pure result of testing one MinimumsProfile against one AlertConditions snapshot. The engine
// does NOT fetch and does NOT post notifications — Step 4 owns fetching, firing the
// UNUserNotification, and persisting newSide back into AirportWatch.lastSide.
struct Verdict {
    let shouldFire: Bool
    let newSide: Side
    let failingFactors: [String]   // human-readable reasons that drove a NO_GO (notification body)
    let sourceLabel: String        // "via live ASOS, 18:53Z" / "via METAR, 18:53Z"
}

// MARK: - Deadbands
// Hysteresis margins that stop a value sitting on a limit from chattering side-to-side.
//
//   wind / crosswind / gust : 2 kt   (SETTLED)
//   category                : 0.5    (SETTLED — half a category step; categories are already
//                                     quantized so this just formalizes "a full step is needed")
//   visibility / ceiling    : HELD   (see below — pending Jeff sign-off)
//
// The vis/ceiling deadbands are intentionally functions of the limit, not flat constants, so a
// scaled / category-breakpoint approach can drop in without changing any call site. The interim
// bodies below are flat placeholders (the project's TAF-verification tolerances) ONLY so the
// engine builds — they are NOT the finalized values.
private enum Deadband {
    static let windKt = 2.0
    static let crosswindKt = 2.0
    static let gustKt = 2.0
    static let categoryStep = 0.5

    // HELD — PENDING JEFF SIGN-OFF (Part D). Interim = TAF-verification tolerance, flat.
    static func visibilitySM(forLimit limit: Double) -> Double { 0.5 }
    static func ceilingFt(forLimit limit: Double) -> Double { 300 }
}

// MARK: - GoNoGoEvaluator
// @MainActor because the crosswind factor reads RunwayService (a @MainActor singleton over the
// bundled runways.json). All other factors are pure arithmetic.
@MainActor
enum GoNoGoEvaluator {

    /// Pure evaluation. `icao` is the runway-lookup key for the crosswind factor (not carried by
    /// AlertConditions/MinimumsProfile). GO iff every tested factor passes; nil factors are
    /// skipped — except crosswind, which always tests against maxCrosswindKt ?? the global floor.
    static func evaluate(_ profile: MinimumsProfile,
                         _ conditions: AlertConditions,
                         previousSide: Side?,
                         icao: String) -> Verdict {

        var factors: [Factor] = []

        // 1. Crosswind — ALWAYS tested (global minimum is a safety floor even when the profile
        // sets no crosswind limit). Skipped only when wind is variable/calm or the airport has
        // no runway data, since the component can't be computed then.
        let crosswindLimit = Double(profile.maxCrosswindKt
            ?? UserDefaults.standard.integer(forKey: "globalCrosswindMinimumKt"))
        if let windDir = conditions.windDirection,
           let best = RunwayService.shared.bestRunway(for: icao,
                                                       windDirection: windDir,
                                                       windSpeed: Double(conditions.windSpeed),
                                                       windGust: conditions.windGust.map(Double.init)) {
            let xw = Double(best.crosswind)   // already gust-based when a gust was supplied
            factors.append(Factor(
                label: "crosswind Rwy \(best.runwayEnd.ident)",
                value: xw, limit: crosswindLimit, deadband: Deadband.crosswindKt,
                worseWhenHigher: true,
                failureText: "Rwy \(best.runwayEnd.ident) crosswind \(Int(xw)) kt over \(Int(crosswindLimit)) kt"))
        }

        // 2. Sustained wind
        if let lim = profile.maxSustainedWindKt {
            let v = Double(conditions.windSpeed)
            factors.append(Factor(
                label: "wind", value: v, limit: Double(lim), deadband: Deadband.windKt,
                worseWhenHigher: true,
                failureText: "wind \(Int(v)) kt over \(lim) kt"))
        }

        // 3. Gust — no gust reported falls back to sustained (a steady 30 kt is worse than a
        // 25 kt gust limit and should still fail it).
        if let lim = profile.maxGustKt {
            let v = Double(conditions.windGust ?? conditions.windSpeed)
            factors.append(Factor(
                label: "gust", value: v, limit: Double(lim), deadband: Deadband.gustKt,
                worseWhenHigher: true,
                failureText: "gusts \(Int(v)) kt over \(lim) kt"))
        }

        // 4. Visibility (lower is worse)
        if let lim = profile.minVisibilitySM {
            let v = conditions.visibilitySM
            factors.append(Factor(
                label: "visibility", value: v, limit: lim,
                deadband: Deadband.visibilitySM(forLimit: lim), worseWhenHigher: false,
                failureText: "visibility \(fmt(v)) SM under \(fmt(lim)) SM"))
        }

        // 5. Ceiling (lower is worse) — no ceiling (clear/FEW/SCT) is effectively unlimited, so
        // a high sentinel ensures clear skies never fail a ceiling minimum.
        if let lim = profile.minCeilingFt {
            let v = Double(conditions.ceilingFeet ?? 99_000)
            factors.append(Factor(
                label: "ceiling", value: v, limit: Double(lim),
                deadband: Deadband.ceilingFt(forLimit: Double(lim)), worseWhenHigher: false,
                failureText: "ceiling \(Int(v)) ft under \(lim) ft"))
        }

        // 6. Flight category — profile.minCategory is the WORST acceptable; fail when current is
        // worse (higher ordinal). Skipped if current category is unknown (can't compare).
        if let minCat = profile.minCategory,
           let minOrd = categoryOrdinal(minCat),
           let curOrd = categoryOrdinal(conditions.flightCategory) {
            factors.append(Factor(
                label: "category", value: curOrd, limit: minOrd, deadband: Deadband.categoryStep,
                worseWhenHigher: true,
                failureText: "\(conditions.flightCategory.rawValue) below \(minCat.rawValue) minimum"))
        }

        // Aggregate side with hysteresis: from GO, any factor hard-failing -> NO_GO; from NO_GO,
        // ALL factors must hard-clear -> GO; with no prior side, classify against the bare limits.
        let newSide: Side
        switch previousSide {
        case .go:   newSide = factors.contains { $0.hardFail() } ? .noGo : .go
        case .noGo: newSide = factors.allSatisfy { $0.hardClear() } ? .go : .noGo
        case nil:   newSide = factors.contains { $0.bareFail() } ? .noGo : .go
        }

        // Fire only on a GO<->NO_GO transition. No prior side establishes a baseline silently.
        let shouldFire = (previousSide != nil) && (previousSide != newSide)
        let failing = (newSide == .noGo) ? factors.filter { $0.bareFail() }.map(\.failureText) : []

        return Verdict(shouldFire: shouldFire,
                       newSide: newSide,
                       failingFactors: failing,
                       sourceLabel: sourceLabel(conditions))
    }

    // MARK: - Helpers
    private static func categoryOrdinal(_ cat: FlightCategory) -> Double? {
        switch cat {
        case .vfr:     return 0
        case .mvfr:    return 1
        case .ifr:     return 2
        case .lifr:    return 3
        case .unknown: return nil
        }
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

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

// MARK: - Factor
// One tested minimum. `worseWhenHigher` lets the same hysteresis math serve "higher is worse"
// (wind, gust, crosswind, category ordinal) and "lower is worse" (visibility, ceiling).
private struct Factor {
    let label: String
    let value: Double
    let limit: Double
    let deadband: Double
    let worseWhenHigher: Bool
    let failureText: String

    // Past the limit at all (no deadband) — first-eval baseline and the failing-factor list.
    func bareFail() -> Bool { worseWhenHigher ? value > limit : value < limit }
    // Past the limit by the full deadband — flips GO -> NO_GO.
    func hardFail() -> Bool { worseWhenHigher ? value > limit + deadband : value < limit - deadband }
    // Inside the limit by the full deadband — required (for ALL factors) to flip NO_GO -> GO.
    func hardClear() -> Bool { worseWhenHigher ? value < limit - deadband : value > limit + deadband }
}
