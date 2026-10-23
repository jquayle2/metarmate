import Foundation

// MARK: - Verdict
// Pure result of testing one MinimumsProfile against one AlertConditions snapshot. The engine
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
    let uncheckedFactors: [String] // why it's CHECK: "visibility not reported", "Variable wind: crosswind can't be confirmed"
    let notes: [String]            // qualifiers on a passing factor: "VRB, assuming full crosswind"
    let lateMinutes: Int?          // 65-75 min old: verdict shown, marked late (D#4)
    let reportAgeMinutes: Int      // observation age, always shown
    let sourceLabel: String        // "via live ASOS, 18:53Z" / "via METAR, 18:53Z"
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

// MARK: - GoNoGoEvaluator
// @MainActor because the crosswind factor reads RunwayService (a @MainActor singleton over the
// bundled runways.json). All other factors are pure arithmetic.
@MainActor
enum GoNoGoEvaluator {

    /// Pure evaluation. `icao` is the runway-lookup key for the crosswind factor (not carried by
    /// AlertConditions/MinimumsProfile). Each requested minimum passes, fails, or can't be
    /// evaluated: any failure is NO-GO; otherwise any unevaluated minimum is CHECK (D#2), never
    /// GO. Crosswind is always tested, against maxCrosswindKt ?? the global floor.
    /// `wasInCheck`: the previous evaluation of this watch was CHECK (AlertPipeline keeps it). It
    /// stops a repeat CHECK notification and any "Back within your minimums" out of CHECK.
    static func evaluate(_ profile: MinimumsProfile,
                         _ conditions: AlertConditions,
                         previousSide: Side?,
                         wasInCheck: Bool = false,
                         icao: String,
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

        // 1. Crosswind — ALWAYS tested (global minimum is a safety floor even when the profile
        // sets no crosswind limit).
        let crosswindLimit = Double(profile.maxCrosswindKt
            ?? UserDefaults.standard.integer(forKey: "globalCrosswindMinimumKt"))
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
                        failureText: "variable wind \(Int(peak)) kt over \(Int(crosswindLimit)) kt crosswind"))
                    notes.append("VRB, assuming full crosswind")
                }
            } else if let windDir = conditions.windDirection,
                      let best = RunwayService.shared.bestRunway(for: icao,
                                                                 windDirection: windDir,
                                                                 windSpeed: Double(windSpd),
                                                                 windGust: conditions.windGust.map(Double.init)) {
                let xw = Double(best.crosswind)   // already gust-based when a gust was supplied
                // Collapse parallel runways to the bare number (12L/12R share a heading, hence an
                // identical crosswind — the L/R pick is arbitrary), matching the detail view.
                let ident = RunwayService.shared.displayIdent(best.runwayEnd, icao: icao)
                factors.append(Factor(
                    label: "crosswind Rwy \(ident)",
                    value: xw, limit: crosswindLimit, deadband: Deadband.crosswindKt,
                    worseWhenHigher: true,
                    failureText: "Rwy \(ident) crosswind \(Int(xw)) kt over \(Int(crosswindLimit)) kt"))
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
                        failureText: "wind \(Int(peak)) kt over \(Int(crosswindLimit)) kt crosswind"))
                }
            }
        } else {
            cantCheck("wind not reported")
        }

        // 2. Sustained wind — nil ≠ calm; a requested limit with no wind is CHECK.
        if let lim = profile.maxSustainedWindKt {
            if let windSpd = conditions.windSpeed {
                let v = Double(windSpd)
                factors.append(Factor(
                    label: "wind", value: v, limit: Double(lim), deadband: Deadband.windKt,
                    worseWhenHigher: true,
                    failureText: "wind \(Int(v)) kt over \(lim) kt"))
            } else {
                cantCheck("wind not reported")
            }
        }

        // 3. Gust — no gust reported falls back to sustained (a steady 30 kt is worse than a
        // 25 kt gust limit and should still fail it).
        if let lim = profile.maxGustKt {
            if let effective = conditions.windGust ?? conditions.windSpeed {
                let v = Double(effective)
                factors.append(Factor(
                    label: "gust", value: v, limit: Double(lim), deadband: Deadband.gustKt,
                    worseWhenHigher: true,
                    failureText: "gusts \(Int(v)) kt over \(lim) kt"))
            } else {
                cantCheck("wind not reported")
            }
        }

        // 4. Visibility (lower is worse) — never a substituted number; missing is CHECK.
        if let lim = profile.minVisibilitySM {
            if let v = conditions.visibilitySM {
                factors.append(Factor(
                    label: "visibility", value: v, limit: lim,
                    deadband: Deadband.visibilitySM(forLimit: lim), worseWhenHigher: false,
                    failureText: "visibility \(fmt(v)) SM under \(fmt(lim)) SM"))
            } else {
                cantCheck("visibility not reported")
            }
        }

        // 5. Ceiling (lower is worse) — no ceiling (clear/FEW/SCT) can't fail a ceiling minimum;
        // a ceiling that wasn't reported is not "no ceiling" (audit #6): CHECK.
        if let lim = profile.minCeilingFt {
            switch conditions.ceiling {
            case .feet(let ceilingFt):
                let v = Double(ceilingFt)
                factors.append(Factor(
                    label: "ceiling", value: v, limit: Double(lim),
                    deadband: Deadband.ceilingFt(forLimit: Double(lim)), worseWhenHigher: false,
                    failureText: "ceiling \(Int(v)) ft under \(lim) ft"))
            case .none:
                break
            case .notReported:
                cantCheck("ceiling not reported")
            }
        }

        // 6. Flight category — profile.minCategory is the WORST acceptable; fail when current is
        // worse (higher ordinal). Unknown category: CHECK.
        if let minCat = profile.minCategory, let minOrd = categoryOrdinal(minCat) {
            if let curOrd = categoryOrdinal(conditions.flightCategory) {
                factors.append(Factor(
                    label: "category", value: curOrd, limit: minOrd, deadband: Deadband.categoryStep,
                    worseWhenHigher: true,
                    failureText: "\(conditions.flightCategory.rawValue) below \(minCat.rawValue) minimum",
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
        let failingText = (outcome == .noGo) ? factors.filter { $0.bareFail() }.map(\.failureText) : []

        return Verdict(outcome: outcome,
                       shouldFire: shouldFire,
                       newSide: newSide,
                       failingFactors: failingText,
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
