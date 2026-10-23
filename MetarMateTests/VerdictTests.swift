import Testing
import Foundation
@testable import MetarMate

// Go/no-go verdict: tri-state factors and CHECK (D#2, audit #4), VRB worst case (D#3, #5),
// staleness (D#4, #7), unknown sky (#6), unknown wind direction / no runway data (Jeff, Oct 23),
// and the alert firing rules around CHECK (Jeff, Oct 23).
@MainActor
struct VerdictTests {

    let now = Date(timeIntervalSince1970: 1792770660)   // Oct 23, 2026 15:51Z

    /// "VFR day" starter: xwind 12, gust 20, vis 6, ceiling 3000, VFR, sustained 20.
    var vfrDay: MinimumsProfile { MinimumsProfile.builtInStarters().first { $0.builtInKey == "vfrDay" }! }

    /// A METAR-sourced snapshot that passes VFR day everywhere unless overridden. KZZZ has no
    /// runway data; pass a real ICAO to the evaluator when the crosswind component matters.
    func conditions(dir: Int? = 300, variable: Bool = false, speed: Int? = 6, gust: Int? = nil,
                    vis: Double? = 10, ceiling: CeilingStatus = .none, cat: FlightCategory = .vfr,
                    minutesAgo: Double = 10) -> AlertConditions {
        var c = AlertConditions(windDirection: dir, windSpeed: speed, windGust: gust,
                                ceilingFeet: ceiling.feet, visibilitySM: vis, flightCategory: cat,
                                source: .metar, timestamp: now.addingTimeInterval(-minutesAgo * 60))
        c.windIsVariable = variable
        c.ceiling = ceiling
        return c
    }

    func eval(_ c: AlertConditions, profile: MinimumsProfile? = nil, previous: Side? = nil,
              wasInCheck: Bool = false, icao: String = "KZZZ") -> Verdict {
        GoNoGoEvaluator.evaluate(profile ?? vfrDay, c, previousSide: previous, wasInCheck: wasInCheck,
                                 icao: icao, now: now)
    }

    // MARK: - #4 / D#2: unevaluated minimum -> CHECK, never GO

    @Test func baselinePassesIsGo() {
        let v = eval(conditions())
        #expect(v.outcome == .go)
        #expect(v.newSide == .go)
    }

    /// Audit #4's example: the vis sensor drops out while NO-GO for 2 SM. It was a GO and a "Back
    /// within your minimums" notification; now CHECK, silent, lastSide left at NO_GO.
    @Test func visibilityDropoutWhileNoGoIsCheckNotGo() {
        let v = eval(conditions(vis: nil), previous: .noGo)
        #expect(v.outcome == .check)
        #expect(!v.shouldFire)
        #expect(v.newSide == nil)
        #expect(v.uncheckedFactors == ["visibility not reported"])
        #expect(AlertPipeline.body(for: v, icao: "KVGT", profile: vfrDay)
                    .hasPrefix("Can't confirm your minimums at KVGT (vs VFR day starter): visibility not reported."))
    }

    /// GO -> CHECK sends one neutral notification and doesn't repeat while it stays CHECK.
    @Test func goToCheckNotifiesOnce() {
        let first = eval(conditions(vis: nil), previous: .go)
        #expect(first.outcome == .check && first.shouldFire)
        #expect(AlertPipeline.title(for: first, icao: "KVGT") == "CHECK — KVGT")
        let again = eval(conditions(vis: nil), previous: .go, wasInCheck: true)
        #expect(again.outcome == .check && !again.shouldFire)
    }

    /// Out of CHECK into GO is silent, whatever lastSide was: never "Back within your minimums".
    @Test(arguments: [Side.go, Side.noGo])
    func checkToGoIsSilent(_ previous: Side) {
        let v = eval(conditions(), previous: previous, wasInCheck: true)
        #expect(v.outcome == .go && !v.shouldFire && v.newSide == .go)
    }

    /// A real NO_GO -> GO (every factor evaluated) still says "Back within".
    @Test func realNoGoToGoStillFires() {
        let v = eval(conditions(), previous: .noGo)
        #expect(v.outcome == .go && v.shouldFire)
    }

    /// CHECK -> NO_GO after a GO fires the NO-GO.
    @Test func checkToNoGoAfterGoFires() {
        let v = eval(conditions(vis: 2), previous: .go, wasInCheck: true)
        #expect(v.outcome == .noGo && v.shouldFire)
    }

    /// A known failure is NO-GO even with another field missing; the missing one is still named.
    @Test func knownFailureBeatsCheck() {
        let v = eval(conditions(vis: 2, ceiling: .notReported))
        #expect(v.outcome == .noGo)
        #expect(v.failingFactors.contains { $0.contains("visibility") })
        #expect(v.uncheckedFactors == ["ceiling not reported"])
    }

    @Test func missingWindIsCheck() {
        let v = eval(conditions(dir: nil, speed: nil))
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["wind not reported"])
    }

    @Test func unknownCategoryIsCheck() {
        #expect(eval(conditions(cat: .unknown)).uncheckedFactors == ["flight category not reported"])
    }

    // MARK: - #6: unknown sky

    @Test func unknownSkyIsCheckNotUnlimited() {
        let v = eval(conditions(ceiling: .notReported))
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["ceiling not reported"])
    }

    @Test func noCeilingPassesCeilingMinimum() {
        #expect(eval(conditions(ceiling: .none)).outcome == .go)
        #expect(eval(conditions(ceiling: .feet(2500), cat: .mvfr)).outcome == .noGo)
    }

    // MARK: - #5 / D#3: VRB worst case

    /// Audit #5: `VRB22G32KT` was GO with the default profile. Worst case 32 kt direct crosswind
    /// exceeds 12 kt: CHECK, "Variable wind: crosswind can't be confirmed" (not NO-GO).
    @Test func vrbOverLimitIsCheck() {
        let v = eval(conditions(dir: nil, variable: true, speed: 22, gust: 32),
                     profile: MinimumsProfile(name: "xw only", maxCrosswindKt: 12))
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["Variable wind: crosswind can't be confirmed"])
    }

    @Test func vrbWithinLimitIsGoAssumingFullCrosswind() {
        let v = eval(conditions(dir: nil, variable: true, speed: 5))
        #expect(v.outcome == .go)
        #expect(v.notes == ["VRB, assuming full crosswind"])
    }

    // MARK: - Unknown direction / no runway data (Jeff, Oct 23): bounded by the total wind

    @Test func unknownDirectionWithinLimitPasses() {
        #expect(eval(conditions(dir: nil, speed: 8), icao: "KVGT").outcome == .go)
    }

    /// `///25KT`: can't compute a component, and 25 kt could exceed 12: CHECK.
    @Test func unknownDirectionOverLimitIsCheck() {
        let v = eval(conditions(dir: nil, speed: 25), profile: MinimumsProfile(name: "xw", maxCrosswindKt: 12),
                     icao: "KVGT")
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["crosswind: wind direction not reported"])
    }

    /// No runway data (KZZZ): the gust, else the speed, bounds the crosswind.
    @Test func noRunwayDataBoundedByTotalWind() {
        #expect(eval(conditions(dir: 270, speed: 10)).outcome == .go)
        let v = eval(conditions(dir: 270, speed: 10, gust: 18), profile: MinimumsProfile(name: "xw", maxCrosswindKt: 15))
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["crosswind: no runway data"])
    }

    // MARK: - #7 / D#4: staleness, shared 65/75 rule

    @Test func lateReportKeepsVerdictMarkedLate() {
        let v = eval(conditions(minutesAgo: 68))
        #expect(v.outcome == .go)
        #expect(v.lateMinutes == 68)
        #expect(AlertPipeline.body(for: v, icao: "KVGT", profile: vfrDay).hasSuffix("METAR late: 68 min old."))
    }

    /// A 3-hour-old VFR METAR kept a green GO. Over 75 min: no verdict, nothing fires, lastSide kept.
    @Test func staleReportHasNoVerdict() {
        let v = eval(conditions(minutesAgo: 180), previous: .noGo)
        #expect(v.outcome == .noCurrent)
        #expect(!v.shouldFire)
        #expect(v.newSide == nil)
        #expect(v.reportAgeMinutes == 180)
        #expect(eval(conditions(minutesAgo: 75)).outcome == .go)    // 75 is late, not stale
        #expect(eval(conditions(minutesAgo: 76)).outcome == .noCurrent)
    }

    // MARK: - D#19: starter label

    @Test func starterVerdictNamesTheProfile() {
        let v = eval(conditions(vis: 2), previous: .go)
        #expect(AlertPipeline.body(for: v, icao: "KVGT", profile: vfrDay).hasPrefix("NO-GO (vs VFR day starter):"))
        let own = MinimumsProfile(name: "Mine", minVisibilitySM: 3)
        #expect(AlertPipeline.body(for: v, icao: "KVGT", profile: own).hasPrefix("NO-GO:"))
    }
}
