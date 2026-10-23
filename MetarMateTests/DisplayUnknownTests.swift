import Testing
import Foundation
@testable import MetarMate

// A2 Step 4: unknown is never shown as good (audit #16, F18). View-only changes (the unknown TAF
// card's neutral rail, the widget's "Fcst on target", the F16 chip color) are build-verified and
// on the device-test list; the derivations behind them are tested here.
@MainActor
struct DisplayUnknownTests {

    private func period(_ fields: String) throws -> TafForecast {
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"synthetic","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200\#(fields.isEmpty ? "" : "," + fields)}]}"#
        return try #require(TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8))).forecasts.first)
    }

    /// A period that doesn't forecast wind or sky: "—", never "Calm" / "CLR".
    @Test func limitingFactorUnknownIsDash() throws {
        let f = ForecastRules.limitingFactor(for: try period(#""visib":2"#))
        #expect(f.windSpeedKt == nil)
        #expect(f.ceilingText == "—")
    }

    /// FEW/SCT only is "NO CIG", never "CLR" (F18); a stated SKC is "CLR".
    @Test func limitingFactorSkyText() throws {
        #expect(ForecastRules.limitingFactor(for: try period(#""visib":"6+","clouds":[{"cover":"SCT","base":4000}]"#)).ceilingText == "NO CIG")
        #expect(ForecastRules.limitingFactor(for: try period(#""visib":"6+","clouds":[{"cover":"SKC"}]"#)).ceilingText == "CLR")
        #expect(ForecastRules.limitingFactor(for: try period(#""visib":"6+","clouds":[{"cover":"OVC","base":800}]"#)).ceilingText == "800")
    }

    private func metar(cat: String, wind: String, clouds: String, minutesAgo: Int) throws -> Metar {
        try MissingDataTests.metar(#""temp":19,"dewp":13,"altim":1014.6,\#(wind),"visib":"10+","clouds":\#(clouds),"fltCat":"\#(cat)""#,
                                   raw: "METAR KTST synthetic 19/13 A2996",
                                   obsTime: MissingDataTests.obs - minutesAgo * 60)
    }

    /// Audit #16: VFR -> IFR with the same wind read "Steady over the last 2 hrs".
    @Test func categoryChangeIsNeverSteady() throws {
        let newest = try metar(cat: "IFR", wind: #""wdir":200,"wspd":8"#, clouds: #"[{"cover":"OVC","base":700}]"#, minutesAgo: 0)
        let oldest = try metar(cat: "VFR", wind: #""wdir":200,"wspd":8"#, clouds: #"[{"cover":"BKN","base":6000}]"#, minutesAgo: 120)
        let tail = WeatherDetailView.historyTrendTail([newest, oldest], window: "2 hrs")
        #expect(tail == "VFR to IFR over the last 2 hrs.")
    }

    @Test func steadyNeedsSteadyConditions() throws {
        let a = try metar(cat: "VFR", wind: #""wdir":200,"wspd":8"#, clouds: #"[{"cover":"BKN","base":6000}]"#, minutesAgo: 0)
        let b = try metar(cat: "VFR", wind: #""wdir":200,"wspd":8"#, clouds: #"[{"cover":"BKN","base":6000}]"#, minutesAgo: 120)
        #expect(WeatherDetailView.historyTrendTail([a, b], window: "2 hrs") == "Steady over the last 2 hrs.")
        // Wind not reported at one end: no "Steady" claim.
        let c = try metar(cat: "VFR", wind: #""temp":19"#, clouds: #"[{"cover":"BKN","base":6000}]"#, minutesAgo: 0)
        #expect(WeatherDetailView.historyTrendTail([c, b], window: "2 hrs") == "")
    }

    // MARK: - #19: TAF wind notes

    /// Audit #19: `TEMPO 30035G50KT` had no wind mention (only base periods with a gust >= 15 were
    /// scanned), and a strong steady wind never counted.
    @Test func tafWindNotesCoverOverlaysAndSteadyWind() throws {
        let start = MissingDataTests.obs - 1800
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":\#(start),"validTimeTo":\#(start + 86400),"rawTAF":"synthetic","fcsts":[{"timeFrom":\#(start),"timeTo":\#(start + 21600),"wdir":200,"wspd":10,"visib":"6+","clouds":[{"cover":"SKC"}]},{"timeFrom":\#(start + 3600),"timeTo":\#(start + 7200),"fcstChange":"TEMPO","wdir":300,"wspd":35,"wgst":50},{"timeFrom":\#(start + 21600),"timeTo":\#(start + 86400),"fcstChange":"FM","wdir":270,"wspd":22,"visib":"6+","clouds":[{"cover":"SKC"}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let periods = ForecastRules.windNotePeriods(taf, now: Date(timeIntervalSince1970: TimeInterval(MissingDataTests.obs)))
        #expect(periods.contains { $0.type == .tempo && $0.wind?.gust == 50 })
        #expect(periods.contains { $0.type == .fm && $0.wind?.speed == 22 })
        #expect(!periods.contains { $0.wind?.speed == 10 })
        #expect(ForecastRules.notableWind(Wind(direction: 300, speed: 35, gust: 50, isVariable: false))?.isWarning == true)
        #expect(ForecastRules.notableWind(Wind(direction: 300, speed: 10, gust: 14, isVariable: false)) == nil)
    }
}
