import Testing
import Foundation
@testable import MetarMate

// The shared VerdictEngine (app + widget): structured failing lines, profile labels, the
// bare-limit display rule, and the runway math the widget runs without RunwayService.
@MainActor
struct VerdictEngineTests {

    let now = Date(timeIntervalSince1970: 1792770660)   // Oct 23, 2026 15:51Z

    /// VFR day starter's limits: xwind 12, gust 20, vis 6, ceiling 3000, VFR, sustained 20.
    var vfrDay: VerdictLimits {
        GoNoGoEvaluator.limits(for: MinimumsProfile.builtInStarters().first { $0.builtInKey == "vfrDay" }!)
    }

    /// One runway, 12/30, true headings 120/300.
    let rwy12_30 = [RunwayEnd(ident: "12", heading: 120, length: nil, width: nil, surface: nil),
                    RunwayEnd(ident: "30", heading: 300, length: nil, width: nil, surface: nil)]

    func conditions(dir: Int? = 300, speed: Int? = 6, gust: Int? = nil, vis: Double? = 10,
                    ceiling: CeilingStatus = .none, cat: FlightCategory = .vfr) -> AlertConditions {
        var c = AlertConditions(windDirection: dir, windSpeed: speed, windGust: gust,
                                ceilingFeet: ceiling.feet, visibilitySM: vis, flightCategory: cat,
                                source: .metar, timestamp: now.addingTimeInterval(-600))
        c.ceiling = ceiling
        return c
    }

    @Test func failingLinesCarryValueAndLimit() {
        let v = VerdictEngine.evaluate(vfrDay, conditions(dir: 200, speed: 18, vis: 4, ceiling: .feet(1200), cat: .mvfr),
                                       runways: rwy12_30, now: now)
        #expect(v.outcome == .noGo)
        #expect(v.failingLines.map(\.text) == [
            "Rwy 12 crosswind 18 kt · limit 12 kt",
            "Visibility 4 SM · limit 6 SM",
            "Ceiling 1,200 ft · limit 3,000 ft",
            "Category MVFR · limit VFR",
        ])
        #expect(v.failingFactors.count == v.failingLines.count)   // notification text unchanged
    }

    @Test func fractionalVisibilityLine() {
        let v = VerdictEngine.evaluate(vfrDay, conditions(vis: 0.25), runways: rwy12_30, now: now)
        #expect(v.failingLines.map(\.text) == ["Visibility 1/4 SM · limit 6 SM"])
    }

    @Test func goAndCheckHaveNoFailingLines() {
        #expect(VerdictEngine.evaluate(vfrDay, conditions(), runways: rwy12_30, now: now).failingLines.isEmpty)
        let check = VerdictEngine.evaluate(vfrDay, conditions(vis: nil), runways: rwy12_30, now: now)
        #expect(check.outcome == .check && check.failingLines.isEmpty)
    }

    /// No runway data with wind over the crosswind limit: CHECK, never a guessed component.
    @Test func noRunwaysStrongWindIsCheck() {
        let v = VerdictEngine.evaluate(vfrDay, conditions(dir: 200, speed: 18), runways: [], now: now)
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["crosswind: no runway data"])
    }

    /// Screens use bare limits. 13 kt crosswind vs a 12 kt limit is inside the 2 kt deadband, so a
    /// watch that was GO keeps notifying GO, but every screen shows NO-GO for the same report.
    @Test func screensUseBareLimitsNotHysteresis() {
        let c = conditions(dir: 210, speed: 13)   // direct crosswind on 12/30
        #expect(VerdictEngine.evaluate(vfrDay, c, runways: rwy12_30, previousSide: .go, now: now).outcome == .go)
        #expect(VerdictEngine.evaluate(vfrDay, c, runways: rwy12_30, now: now).outcome == .noGo)
    }

    /// The app path (RunwayService, magnetic frame) and the engine fed the same runways (true
    /// frame, no declination) agree at a real field, so the widget gets the app's verdict.
    @Test(arguments: [(250, 18, 25), (160, 12, nil), (70, 22, 30), (340, 9, nil)] as [(Int, Int, Int?)])
    func appAndWidgetPathsAgree(_ dir: Int, _ speed: Int, _ gust: Int?) {
        let profile = MinimumsProfile.builtInStarters().first { $0.builtInKey == "vfrDay" }!
        let c = conditions(dir: dir, speed: speed, gust: gust)
        let app = GoNoGoEvaluator.evaluate(profile, c, previousSide: nil, icao: "KLAS", now: now)
        let shared = VerdictEngine.evaluate(vfrDay, c, runways: RunwayService.shared.runways(for: "KLAS"), now: now)
        #expect(!RunwayService.shared.runways(for: "KLAS").isEmpty)
        #expect(app.outcome == shared.outcome)
        #expect(app.failingLines == shared.failingLines)
    }

    /// Rotating wind and runway by the same declination leaves every component unchanged.
    @Test func declinationDoesNotChangeComponents() {
        for dir in stride(from: 0, to: 360, by: 10) {
            let a = RunwayMath.crosswinds(rwy12_30, windDirection: dir, windSpeed: 17, windGust: 26, declination: 0)
            let b = RunwayMath.crosswinds(rwy12_30, windDirection: dir, windSpeed: 17, windGust: 26, declination: 11.4)
            #expect(a.map(\.crosswind) == b.map(\.crosswind))
            #expect(a.map(\.headwind) == b.map(\.headwind))
            #expect(a.map(\.isLeft) == b.map(\.isLeft))
        }
    }

    @Test func profileLabels() {
        #expect(VerdictProfileSnapshot(name: "VFR day", isStarter: true, limits: vfrDay).againstLabel == "vs VFR day starter")
        #expect(VerdictProfileSnapshot(name: "Night XC", isStarter: false, limits: vfrDay).againstLabel == "vs Night XC")
    }

    // MARK: - VerdictDisplay: one wording and color rule for every surface

    func shown(_ c: AlertConditions, minutesAgo: Double = 10) -> VerdictDisplay {
        var c = c
        c.timestamp = now.addingTimeInterval(-minutesAgo * 60)
        let v = VerdictEngine.evaluate(vfrDay, c, runways: rwy12_30, now: now)
        return VerdictDisplay(v, profile: VerdictProfileSnapshot(name: "VFR day", isStarter: true, limits: vfrDay))
    }

    @Test func currentGoAndNoGoAreColored() {
        let go = shown(conditions())
        #expect(go.headline == "GO" && go.tone == .go && go.against == "vs VFR day starter")
        #expect(go.status.hasPrefix("via METAR, ") && go.status.hasSuffix(" · 10 min ago"))
        let noGo = shown(conditions(vis: 4))
        #expect(noGo.headline == "NO-GO" && noGo.tone == .noGo)
        #expect(noGo.lines == ["Visibility 4 SM · limit 6 SM"])
    }

    /// D#4: 65–75 min keeps the verdict but drops green/red.
    @Test func lateVerdictIsNeutral() {
        let late = shown(conditions(), minutesAgo: 68)
        #expect(late.headline == "GO" && late.tone == .neutral && late.isLate)
        #expect(late.status == "METAR late: 68 min old")
        #expect(shown(conditions(vis: 4), minutesAgo: 70).tone == .neutral)
    }

    @Test func noCurrentHasNoVerdict() {
        let stale = shown(conditions(vis: 4), minutesAgo: 130)
        #expect(stale.headline == "No current METAR" && stale.tone == .neutral && stale.lines.isEmpty)
        #expect(stale.status == "Last report 2 h 10 min ago")
    }

    @Test func checkIsNeutralWithReasons() {
        let check = shown(conditions(vis: nil))
        #expect(check.headline == "CHECK" && check.tone == .neutral)
        #expect(check.lines == ["Visibility not reported"])
        // A known failure plus something missing: NO-GO, listing both.
        #expect(shown(conditions(vis: 4, ceiling: .notReported)).lines
                    == ["Visibility 4 SM · limit 6 SM", "Ceiling not reported"])
    }
}
