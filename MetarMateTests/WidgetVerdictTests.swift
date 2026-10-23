import Testing
import Foundation
@testable import MetarMate

// The widget's verdict (D#20): the App Group round-trip of its inputs, and that the widget path
// (raw METAR -> snapshot -> AlertConditions) reaches the same verdict as the app path (METAR ->
// AlertConditions) for the same report.
@MainActor
struct WidgetVerdictTests {

    let now = Date(timeIntervalSince1970: 1792770660)   // Oct 23, 2026 15:51Z

    var vfrDay: MinimumsProfile { MinimumsProfile.builtInStarters().first { $0.builtInKey == "vfrDay" }! }

    // MARK: - App Group round-trip

    @Test func profileRoundTrip() throws {
        let custom = MinimumsProfile(name: "Night XC", maxGustKt: 18, minVisibilitySM: 0.75,
                                     minCeilingFt: 3500, minFlightCategory: .mvfr)
        let written = GoNoGoEvaluator.snapshot(of: custom)
        #expect(written.limits.maxCrosswindKt == 15)   // no crosswind limit: the global floor travels with it
        let data = try JSONEncoder().encode(written)
        let read = try JSONDecoder().decode(VerdictProfileSnapshot.self, from: data)
        #expect(read == written)
        #expect(read.againstLabel == "vs Night XC")
        #expect(read.limits.minCategory == .mvfr && read.limits.minVisibilitySM == 0.75)
        #expect(read.limits.maxSustainedWindKt == nil)
    }

    /// Through the real App Group store: what the app writes is what the widget reads, and an
    /// unchanged write reports no change (so timelines aren't reloaded for nothing).
    @Test func appGroupStoreRoundTrip() {
        let profile = GoNoGoEvaluator.snapshot(of: vfrDay)
        WidgetDataManager.saveVerdictProfile(profile)
        #expect(WidgetDataManager.loadVerdictProfile() == profile)
        #expect(!WidgetDataManager.saveVerdictProfile(profile))

        let ends = RunwayService.shared.runways(for: "KDEN")
        #expect(!ends.isEmpty)
        WidgetDataManager.saveRunways(ends, icao: "kden")
        #expect(WidgetDataManager.loadRunways(icao: "KDEN") == ends)
        #expect(!WidgetDataManager.saveRunways(ends, icao: "KDEN"))
    }

    // MARK: - App path vs widget path

    struct Report: Sendable, CustomStringConvertible {
        let name: String
        let json: String
        var description: String { name }
    }

    static let reports: [Report] = [
        Report(name: "gusty NO-GO", json: #""rawOb":"METAR KDEN 231539Z 20012G26KT 10SM FEW100 15/M02 A3001","wdir":200,"wspd":12,"wgst":26,"visib":"10+","fltCat":"VFR","clouds":[{"cover":"FEW","base":10000}]"#),
        Report(name: "clear GO", json: #""rawOb":"METAR KDEN 231539Z 25008KT 10SM CLR 15/M02 A3001","wdir":250,"wspd":8,"visib":"10+","fltCat":"VFR","clouds":[{"cover":"CLR"}]"#),
        Report(name: "missing vis CHECK", json: #""rawOb":"METAR KDEN 231539Z 25008KT CLR 15/M02 A3001","wdir":250,"wspd":8,"fltCat":"VFR","clouds":[{"cover":"CLR"}]"#),
        Report(name: "VRB over limit CHECK", json: #""rawOb":"METAR KDEN 231539Z VRB14G18KT 10SM CLR 15/M02 A3001","wdir":"VRB","wspd":14,"wgst":18,"visib":"10+","fltCat":"VFR","clouds":[{"cover":"CLR"}]"#),
        Report(name: "low ceiling NO-GO", json: #""rawOb":"METAR KDEN 231539Z 25008KT 3SM BR OVC008 10/09 A3001","wdir":250,"wspd":8,"visib":"3","fltCat":"IFR","clouds":[{"cover":"OVC","base":800}]"#),
        Report(name: "no wind group CHECK", json: #""rawOb":"METAR KDEN 231539Z 10SM CLR 15/M02 A3001","visib":"10+","fltCat":"VFR","clouds":[{"cover":"CLR"}]"#),
    ]

    @Test(arguments: reports)
    func widgetPathMatchesAppPath(_ report: Report) throws {
        let obs = Int(now.timeIntervalSince1970) - 12 * 60
        let json = #"{"obsTime":\#(obs),"icaoId":"KDEN",\#(report.json)}"#
        let raw = try JSONDecoder().decode(RawMetar.self, from: Data(json.utf8))
        let metar = try MetarParser.parse(raw: raw)
        let snapshot = try #require(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KDEN"))
        // Through JSON, as the widget reads it from the App Group.
        let stored = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: JSONEncoder().encode(snapshot))

        let app = GoNoGoEvaluator.evaluate(vfrDay, AlertConditions(from: metar), previousSide: nil,
                                           icao: "KDEN", now: now)
        let widget = VerdictEngine.evaluate(GoNoGoEvaluator.limits(for: vfrDay), AlertConditions(snapshot: stored),
                                            runways: RunwayService.shared.runways(for: "KDEN"), now: now)
        #expect(widget.outcome == app.outcome)
        #expect(widget.failingLines == app.failingLines)
        #expect(widget.uncheckedFactors == app.uncheckedFactors)
        #expect(widget.notes == app.notes)
    }

    // MARK: - Ceiling: no ceiling vs not reported

    @Test func ceilingReportedTravelsInTheSnapshot() throws {
        let clear = try snapshot(#""rawOb":"METAR KDEN 231539Z 25008KT 10SM CLR 15/M02 A3001","wdir":250,"wspd":8,"visib":"10+","fltCat":"VFR","clouds":[{"cover":"CLR"}]"#)
        #expect(clear.ceilingReported == true)
        #expect(AlertConditions(snapshot: clear).ceiling == .none)
    }

    /// A snapshot written before `ceilingReported` existed: a nil ceiling is not "no ceiling", so a
    /// ceiling minimum is CHECK, never a false GO.
    @Test func legacySnapshotWithoutCeilingIsCheck() throws {
        let clear = try snapshot(#""rawOb":"METAR KDEN 231539Z 25008KT 10SM CLR 15/M02 A3001","wdir":250,"wspd":8,"visib":"10+","fltCat":"VFR","clouds":[{"cover":"CLR"}]"#)
        var dict = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clear)) as? [String: Any])
        dict.removeValue(forKey: "ceilingReported")
        let legacy = try JSONDecoder().decode(WidgetWeatherSnapshot.self,
                                              from: JSONSerialization.data(withJSONObject: dict))
        #expect(legacy.ceilingReported == nil)
        let v = VerdictEngine.evaluate(GoNoGoEvaluator.limits(for: vfrDay), AlertConditions(snapshot: legacy),
                                       runways: RunwayService.shared.runways(for: "KDEN"), now: now)
        #expect(v.outcome == .check)
        #expect(v.uncheckedFactors == ["ceiling not reported"])
    }

    /// Timeline: the same snapshot at the entry dates goes current -> late (neutral) -> no verdict.
    @Test func verdictFollowsTheTimelineEntries() throws {
        let s = try snapshot(#""rawOb":"METAR KDEN 231539Z 25008KT 10SM CLR 15/M02 A3001","wdir":250,"wspd":8,"visib":"10+","fltCat":"VFR","clouds":[{"cover":"CLR"}]"#)
        let limits = GoNoGoEvaluator.limits(for: vfrDay)
        let profile = GoNoGoEvaluator.snapshot(of: vfrDay)
        func shown(_ minutesAfterObs: Int) -> VerdictDisplay {
            let at = s.observationTime.addingTimeInterval(TimeInterval(minutesAfterObs * 60))
            let v = VerdictEngine.evaluate(limits, AlertConditions(snapshot: s),
                                           runways: RunwayService.shared.runways(for: "KDEN"), now: at)
            return VerdictDisplay(v, profile: profile)
        }
        #expect(shown(64).tone == .go)
        #expect(shown(65).tone == .neutral && shown(65).headline == "GO")
        #expect(shown(75).headline == "GO")
        #expect(shown(76).headline == "No current METAR")
        // The timeline schedules an entry at each of those instants.
        let dates = s.ageChangeDates(after: s.observationTime.addingTimeInterval(60))
        for m in [65, 76] {
            #expect(dates.contains(s.observationTime.addingTimeInterval(TimeInterval(m * 60))))
        }
    }

    private func snapshot(_ fields: String) throws -> WidgetWeatherSnapshot {
        let obs = Int(now.timeIntervalSince1970) - 12 * 60
        let json = #"{"obsTime":\#(obs),"icaoId":"KDEN",\#(fields)}"#
        let raw = try JSONDecoder().decode(RawMetar.self, from: Data(json.utf8))
        return try #require(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KDEN"))
    }
}
