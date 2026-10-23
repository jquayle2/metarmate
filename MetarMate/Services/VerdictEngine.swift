import Foundation

// MARK: - VerdictEngine
// The one go/no-go rule set, shared by the app (Alerts, notifications, detail screen) and the
// widget extension, so no two surfaces can disagree. Pure: no SwiftData, no bundle, no
// UserDefaults. The app's GoNoGoEvaluator resolves the profile and runway data and calls in here;
// the widget does the same from its App Group snapshot. METAR only (D#1).

// MARK: - Side
// The binary go/no-go state. Persisted on AirportWatch as a raw string and used as the
// hysteresis memory. Fire only happens on a GO<->NO_GO transition.
enum Side: String {
    case go = "GO"
    case noGo = "NO_GO"
}

// MARK: - Verdict
// Pure result of testing one set of limits against one AlertConditions snapshot. The engine
// does NOT fetch and does NOT post notifications — AlertPipeline owns fetching, firing the
// UNUserNotification, and persisting newSide back into AirportWatch.lastSide.
struct Verdict {
    /// GO / NO-GO, CHECK when a requested minimum can't be evaluated (D#2: never GO, never green),
    /// or no verdict at all when the METAR is over 75 min old (D#4).
    enum Outcome: Equatable { case go, noGo, check, noCurrent }

    let outcome: Outcome
    let shouldFire: Bool
    let newSide: Side?             // hysteresis memory to persist; nil = leave lastSide unchanged (CHECK / no current METAR)
    let failingFactors: [String]   // human-readable reasons that drove a NO_GO (notification body)
    var failingLines: [VerdictFactorLine] = []   // the same failures, structured for the detail screen and widgets
    let uncheckedFactors: [String] // why it's CHECK: "visibility not reported", "Variable wind: crosswind can't be confirmed"
    let notes: [String]            // qualifiers on a passing factor: "VRB, assuming full crosswind"
    let lateMinutes: Int?          // 65-75 min old: verdict shown, marked late (D#4)
    let reportAgeMinutes: Int      // observation age, always shown
    let sourceLabel: String        // "via live ASOS, 18:53Z" / "via METAR, 18:53Z"
}

/// One failing minimum as value against limit: "Crosswind Rwy 12 · 18 kt · limit 12 kt".
nonisolated struct VerdictFactorLine: Equatable, Sendable {
    let name: String    // "Crosswind Rwy 12"
    let value: String   // "18 kt"
    let limit: String   // "12 kt"
    var text: String { "\(name) \(value) · limit \(limit)" }
}

// MARK: - VerdictLimits
// A profile's minimums as plain values, so the widget (no SwiftData) can carry them in the App
// Group. nil = don't test the factor, as on MinimumsProfile; crosswind is always tested, so the
// app resolves the global floor into it before handing it over.
nonisolated struct VerdictLimits: Codable, Equatable, Sendable {
    var maxCrosswindKt: Int
    var maxGustKt: Int?
    var minVisibilitySM: Double?
    var minCeilingFt: Int?
    var minCategory: FlightCategory?
    var maxSustainedWindKt: Int?
}

/// The profile a verdict is judged against, as written to the App Group for the widget: its
/// display name, whether it's a starter (labeled as such, D#19), and its limits.
nonisolated struct VerdictProfileSnapshot: Codable, Equatable, Sendable {
    let name: String
    let isStarter: Bool
    let limits: VerdictLimits

    /// "vs VFR day starter" for a starter, "vs Night XC" for a custom profile.
    var againstLabel: String { isStarter ? "vs \(name) starter" : "vs \(name)" }
}

// MARK: - Runway math
// Runway data and the crosswind component, shared with RunwayService (which adds the bundled
// runways.json and the WMM declination) so the widget computes the identical component.
nonisolated struct Runway: Codable {
    let le: String
    let leHdg: Int
    let he: String
    let heHdg: Int
    let len: Int?
    let wid: Int?
    let sfc: String?
}

nonisolated struct RunwayEnd: Codable, Equatable, Sendable {
    let ident: String
    let heading: Int      // TRUE, as surveyed
    let length: Int?
    let width: Int?
    let surface: String?
}

nonisolated struct RunwayResult {
    let runwayEnd: RunwayEnd
    let crosswind: Int
    let headwind: Int
    let isLeft: Bool
}

nonisolated enum RunwayMath {
    /// Numeric runway designator without the L/C/R position suffix ("12L" → "12").
    static func runwayNumber(_ ident: String) -> String {
        String(ident.prefix(while: { $0.isNumber }))
    }

    /// Display ident: the bare number when parallel runways share it (12L/12R have an
    /// identical heading, so identical crosswind), else the full ident.
    static func displayIdent(_ end: RunwayEnd, among ends: [RunwayEnd]) -> String {
        let number = runwayNumber(end.ident)
        let count = ends.filter { runwayNumber($0.ident) == number }.count
        return count > 1 ? number : end.ident
    }

    /// Rotate a TRUE bearing into the MAGNETIC frame using a pre-computed declination
    /// (east is least / subtract east), normalized to [0, 360).
    static func magnetic(_ trueDeg: Double, declination: Double) -> Double {
        let m = trueDeg - declination
        return (m.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Crosswind/headwind for every runway end. `windGust` (when present) is used as the
    /// effective speed. Wind and headings are TRUE and rotated by the same declination, so the
    /// components don't depend on it; it's applied so every intermediate is in the magnetic frame.
    static func crosswinds(_ ends: [RunwayEnd], windDirection: Int, windSpeed: Double, windGust: Double?,
                           declination: Double = 0) -> [RunwayResult] {
        let effectiveSpeed = windGust ?? windSpeed
        let windMag = magnetic(Double(windDirection), declination: declination)
        return ends.map { end in
            let heading = magnetic(Double(end.heading), declination: declination)
            let angle = (windMag - heading) * .pi / 180.0
            let xw = abs(Int(round(effectiveSpeed * sin(angle))))
            let hw = Int(round(effectiveSpeed * cos(angle)))
            let left: Bool = {
                let diff = ((windMag - heading).truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                return diff > 0 && diff < 180
            }()
            return RunwayResult(runwayEnd: end, crosswind: xw, headwind: hw, isLeft: left)
        }
    }

    /// Strict "a is the better runway than b" ordering, matching the pilot's preference:
    /// a usable headwind beats a tailwind/zero; then least crosswind; then most headwind.
    static func preferred(_ a: RunwayResult, _ b: RunwayResult) -> Bool {
        let aLand = a.headwind > 0, bLand = b.headwind > 0
        if aLand != bLand { return aLand }
        if a.crosswind != b.crosswind { return a.crosswind < b.crosswind }
        return a.headwind > b.headwind
    }

    static func bestRunway(_ ends: [RunwayEnd], windDirection: Int, windSpeed: Double, windGust: Double?,
                           declination: Double = 0) -> RunwayResult? {
        crosswinds(ends, windDirection: windDirection, windSpeed: windSpeed, windGust: windGust,
                   declination: declination)
            .min(by: preferred)
    }
}

// MARK: - Deadbands
// Hysteresis margins that stop a value sitting on a limit from chattering side-to-side.
//
//   wind / crosswind / gust : 2 kt   (SETTLED)
//   category                : 0.5    (SETTLED — half a category step; categories are already
//                                     quantized so this just formalizes "a full step is needed")
//   visibility / ceiling    : limit-keyed ladder (APPROVED — see below)
//
// Vis/ceiling deadbands scale with the band the limit sits in, because a flat margin is too
// coarse near IFR minimums and noise-level at high VFR values. Anchored to the project's
// TrendThresholds ladder and TAF-verification tolerances (±0.5 SM / ±300 ft land in the mid
// bands), set at ~half the trend step so they debounce without masking a real crossing.
private enum Deadband {
    static let windKt = 2.0
    static let crosswindKt = 2.0
    static let gustKt = 2.0
    static let categoryStep = 0.5

    static func visibilitySM(forLimit limit: Double) -> Double {
        switch limit {
        case ...1.0:  return 0.25   // ≤ 1 SM: tight near IFR/LIFR minimums
        case ...5.0:  return 0.5    // 1–5 SM: IFR–MVFR (TAF-verif anchor)
        default:      return 1.0    // > 5 SM: VFR-cautious
        }
    }

    static func ceilingFt(forLimit limit: Double) -> Double {
        switch limit {
        case ..<1000: return 200    // < 1000 ft: IFR/LIFR
        case ..<3000: return 300    // 1000–3000 ft: MVFR (TAF-verif anchor)
        default:      return 500    // ≥ 3000 ft: VFR
        }
    }
}

enum VerdictEngine {

    /// Pure evaluation. `runways` are the field's runway ends (TRUE headings); empty = no runway
    /// data. Each requested minimum passes, fails, or can't be evaluated: any failure is NO-GO;
    /// otherwise any unevaluated minimum is CHECK (D#2), never GO. Crosswind is always tested.
    /// `previousSide` applies the hysteresis deadbands; screens pass nil (bare limits) so every
    /// surface shows the same verdict for the same report, and only notifications use hysteresis.
    /// `wasInCheck`: the previous evaluation of this watch was CHECK (AlertPipeline keeps it). It
    /// stops a repeat CHECK notification and any "Back within your minimums" out of CHECK.
    static func evaluate(_ limits: VerdictLimits,
                         _ conditions: AlertConditions,
                         runways: [RunwayEnd],
                         previousSide: Side? = nil,
                         wasInCheck: Bool = false,
                         now: Date = Date()) -> Verdict {

        // Staleness (D#4, shared 65/75-minute rule): over 75 min there is no verdict at all.
        let age = WidgetWeatherSnapshot.reportAge(observationTime: conditions.timestamp, at: now)
        let ageMinutes = max(0, Int(now.timeIntervalSince(conditions.timestamp) / 60))
        if case .noCurrent = age {
            return Verdict(outcome: .noCurrent, shouldFire: false, newSide: nil, failingFactors: [],
                           uncheckedFactors: [], notes: [], lateMinutes: nil,
                           reportAgeMinutes: ageMinutes, sourceLabel: sourceLabel(conditions))
        }
        let lateMinutes: Int? = { if case .late(let m) = age { return m } else { return nil } }()

        var factors: [Factor] = []
        var unchecked: [String] = []
        var notes: [String] = []
        func cantCheck(_ reason: String) { if !unchecked.contains(reason) { unchecked.append(reason) } }
        func kt(_ v: Double) -> String { "\(Int(v)) kt" }

        // 1. Crosswind — ALWAYS tested (global minimum is a safety floor even when the profile
        // sets no crosswind limit).
        let crosswindLimit = Double(limits.maxCrosswindKt)
        if let windSpd = conditions.windSpeed {
            // The crosswind component can't exceed the total wind: the gust, else the speed.
            let peak = Double(conditions.windGust ?? windSpd)
            if conditions.windIsVariable {
                // D#3: VRB is evaluated worst case, a direct crosswind at the peak. Within the
                // limit it passes ("VRB, assuming full crosswind"); over it, CHECK — not NO-GO.
                if peak > crosswindLimit {
                    cantCheck("Variable wind: crosswind can't be confirmed")
                } else {
                    factors.append(Factor(
                        label: "crosswind (VRB)", value: peak, limit: crosswindLimit,
                        deadband: Deadband.crosswindKt, worseWhenHigher: true,
                        failureText: "variable wind \(Int(peak)) kt over \(Int(crosswindLimit)) kt crosswind",
                        line: VerdictFactorLine(name: "Crosswind (VRB)", value: kt(peak), limit: kt(crosswindLimit))))
                    notes.append("VRB, assuming full crosswind")
                }
            } else if let windDir = conditions.windDirection,
                      let best = RunwayMath.bestRunway(runways, windDirection: windDir,
                                                       windSpeed: Double(windSpd),
                                                       windGust: conditions.windGust.map(Double.init)) {
                let xw = Double(best.crosswind)   // already gust-based when a gust was supplied
                // Collapse parallel runways to the bare number (12L/12R share a heading, hence an
                // identical crosswind — the L/R pick is arbitrary), matching the detail view.
                let ident = RunwayMath.displayIdent(best.runwayEnd, among: runways)
                factors.append(Factor(
                    label: "crosswind Rwy \(ident)",
                    value: xw, limit: crosswindLimit, deadband: Deadband.crosswindKt,
                    worseWhenHigher: true,
                    failureText: "Rwy \(ident) crosswind \(Int(xw)) kt over \(Int(crosswindLimit)) kt",
                    line: VerdictFactorLine(name: "Crosswind Rwy \(ident)", value: kt(xw), limit: kt(crosswindLimit))))
            } else {
                // No component: direction not reported (`///25KT`) or no runway data. Jeff, Oct 23:
                // passes when the whole wind is within the limit, otherwise CHECK.
                let reason = conditions.windDirection == nil ? "wind direction not reported" : "no runway data"
                if peak > crosswindLimit {
                    cantCheck("crosswind: \(reason)")
                } else {
                    factors.append(Factor(
                        label: "crosswind", value: peak, limit: crosswindLimit,
                        deadband: Deadband.crosswindKt, worseWhenHigher: true,
                        failureText: "wind \(Int(peak)) kt over \(Int(crosswindLimit)) kt crosswind",
                        line: VerdictFactorLine(name: "Crosswind", value: kt(peak), limit: kt(crosswindLimit))))
                }
            }
        } else {
            cantCheck("wind not reported")
        }

        // 2. Sustained wind — nil ≠ calm; a requested limit with no wind is CHECK.
        if let lim = limits.maxSustainedWindKt {
            if let windSpd = conditions.windSpeed {
                let v = Double(windSpd)
                factors.append(Factor(
                    label: "wind", value: v, limit: Double(lim), deadband: Deadband.windKt,
                    worseWhenHigher: true,
                    failureText: "wind \(Int(v)) kt over \(lim) kt",
                    line: VerdictFactorLine(name: "Wind", value: kt(v), limit: "\(lim) kt")))
            } else {
                cantCheck("wind not reported")
            }
        }

        // 3. Gust — no gust reported falls back to sustained (a steady 30 kt is worse than a
        // 25 kt gust limit and should still fail it).
        if let lim = limits.maxGustKt {
            if let effective = conditions.windGust ?? conditions.windSpeed {
                let v = Double(effective)
                factors.append(Factor(
                    label: "gust", value: v, limit: Double(lim), deadband: Deadband.gustKt,
                    worseWhenHigher: true,
                    failureText: "gusts \(Int(v)) kt over \(lim) kt",
                    line: VerdictFactorLine(name: "Gust", value: kt(v), limit: "\(lim) kt")))
            } else {
                cantCheck("wind not reported")
            }
        }

        // 4. Visibility (lower is worse) — never a substituted number; missing is CHECK.
        if let lim = limits.minVisibilitySM {
            if let v = conditions.visibilitySM {
                factors.append(Factor(
                    label: "visibility", value: v, limit: lim,
                    deadband: Deadband.visibilitySM(forLimit: lim), worseWhenHigher: false,
                    failureText: "visibility \(fmt(v)) SM under \(fmt(lim)) SM",
                    line: VerdictFactorLine(name: "Visibility", value: "\(Visibility.milesText(v)) SM",
                                            limit: "\(Visibility.milesText(lim)) SM")))
            } else {
                cantCheck("visibility not reported")
            }
        }

        // 5. Ceiling (lower is worse) — no ceiling (clear/FEW/SCT) can't fail a ceiling minimum;
        // a ceiling that wasn't reported is not "no ceiling" (audit #6): CHECK.
        if let lim = limits.minCeilingFt {
            switch conditions.ceiling {
            case .feet(let ceilingFt):
                let v = Double(ceilingFt)
                factors.append(Factor(
                    label: "ceiling", value: v, limit: Double(lim),
                    deadband: Deadband.ceilingFt(forLimit: Double(lim)), worseWhenHigher: false,
                    failureText: "ceiling \(Int(v)) ft under \(lim) ft",
                    line: VerdictFactorLine(name: "Ceiling", value: "\(ceilingFt.formatted()) ft",
                                            limit: "\(lim.formatted()) ft")))
            case .none:
                break
            case .notReported:
                cantCheck("ceiling not reported")
            }
        }

        // 6. Flight category — limits.minCategory is the WORST acceptable; fail when current is
        // worse (higher ordinal). Unknown category: CHECK.
        if let minCat = limits.minCategory, let minOrd = categoryOrdinal(minCat) {
            if let curOrd = categoryOrdinal(conditions.flightCategory) {
                factors.append(Factor(
                    label: "category", value: curOrd, limit: minOrd, deadband: Deadband.categoryStep,
                    worseWhenHigher: true,
                    failureText: "\(conditions.flightCategory.rawValue) below \(minCat.rawValue) minimum",
                    line: VerdictFactorLine(name: "Category", value: conditions.flightCategory.rawValue,
                                            limit: minCat.rawValue),
                    floor: 0))   // VFR (0) is the best possible ordinal — see hardClear() below
            } else {
                cantCheck("flight category not reported")
            }
        }

        // Aggregate with hysteresis over the factors that WERE evaluated: from GO, any factor
        // hard-failing -> NO_GO; from NO_GO, ALL must hard-clear to leave it; with no prior side,
        // classify against the bare limits. A known failure is NO-GO whatever else is missing;
        // otherwise anything unevaluated is CHECK.
        let failing: Bool
        switch previousSide {
        case .go:   failing = factors.contains { $0.hardFail() }
        case .noGo: failing = !factors.allSatisfy { $0.hardClear() }
        case nil:   failing = factors.contains { $0.bareFail() }
        }
        let outcome: Verdict.Outcome = failing ? .noGo : (unchecked.isEmpty ? .go : .check)

        // Firing:
        //  - GO <-> NO_GO transitions fire, as before; a first evaluation fires only if NO_GO.
        //  - Into CHECK from GO: one neutral notification ("Can't confirm your minimums"), not
        //    repeated while it stays CHECK (warn-never-reassure: a pilot told GO shouldn't keep
        //    relying on it silently). From NO_GO or a first evaluation, CHECK is silent.
        //  - Out of CHECK into GO: silent — never "Back within your minimums" (D#2, Jeff Oct 23).
        let newSide: Side?
        let shouldFire: Bool
        switch outcome {
        case .check:
            newSide = nil
            shouldFire = previousSide == .go && !wasInCheck
        case .go:
            newSide = .go
            shouldFire = !wasInCheck && previousSide == .noGo
        case .noGo:
            newSide = .noGo
            shouldFire = previousSide != .noGo
        case .noCurrent:
            newSide = nil
            shouldFire = false
        }
        let failed = (outcome == .noGo) ? factors.filter { $0.bareFail() } : []

        return Verdict(outcome: outcome,
                       shouldFire: shouldFire,
                       newSide: newSide,
                       failingFactors: failed.map(\.failureText),
                       failingLines: failed.map(\.line),
                       uncheckedFactors: unchecked,
                       notes: outcome == .go ? notes : [],
                       lateMinutes: lateMinutes,
                       reportAgeMinutes: ageMinutes,
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
    let line: VerdictFactorLine
    // Theoretical best-case bound for quantized scales (e.g. category ordinal 0 = VFR). Only
    // set for factors whose value can bottom out at a known floor; nil means "no floor, unbounded
    // like wind/vis/ceiling" so their hardClear math is untouched.
    var floor: Double? = nil

    // Past the limit at all (no deadband) — first-eval baseline and the failing-factor list.
    func bareFail() -> Bool { worseWhenHigher ? value > limit : value < limit }
    // Past the limit by the full deadband — flips GO -> NO_GO.
    func hardFail() -> Bool { worseWhenHigher ? value > limit + deadband : value < limit - deadband }
    // Inside the limit by the full deadband — required (for ALL factors) to flip NO_GO -> GO.
    //
    // When the limit already sits at (or within a deadband of) the floor, "limit - deadband" asks
    // for a value below the floor, which is impossible — e.g. a VFR (ordinal 0) minimum with a 0.5
    // deadband would require ordinal < -0.5 forever, permanently stranding the watch on NO-GO even
    // once conditions are genuinely fine. In that case, sitting at the floor IS as clear as it can
    // get, so treat it as satisfied.
    func hardClear() -> Bool {
        if worseWhenHigher {
            if let floor, limit - deadband <= floor { return value <= floor }
            return value < limit - deadband
        }
        return value > limit + deadband
    }
}
