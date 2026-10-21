import Testing
import Foundation
@testable import MetarMate

// TAF time logic (audit #13/#14): one "what is forecast at time t" helper — prevailing base/FM with
// BECMG applied once its window ends, TEMPO/PROB returned separately, nothing current outside the
// TAF's validity — and the TAF category rule when one axis isn't forecast. Synthetic TAFs in NOAA's
// JSON shape, hours counted from t0.
struct TafTimeLogicTests {

    private static let t0 = 1783634400   // 2026-07-09 22:00Z
    private func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: TimeInterval(Self.t0) + hours * 3600) }
    private func e(_ hours: Double) -> Int { Self.t0 + Int(hours * 3600) }

    private func taf(_ fcsts: String, validHours: Double = 24) throws -> Taf {
        let json = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T21:40:00.000Z","validTimeFrom":\#(e(0)),"validTimeTo":\#(e(validHours)),"rawTAF":"synthetic","fcsts":[\#(fcsts)]}"#
        return try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
    }

    private func metar(hours: Double, visib: String, clouds: String, cat: String) throws -> Metar {
        let json = #"{"icaoId":"KZZZ","obsTime":\#(e(hours)),"temp":15,"dewp":10,"wdir":200,"wspd":6,"visib":\#(visib),"altim":1013,"rawOb":"METAR KZZZ synthetic","clouds":\#(clouds),"fltCat":"\#(cat)"}"#
        return try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }

    // Periods
    private var vfrBase: String { #"{"timeFrom":\#(e(0)),"timeTo":\#(e(6)),"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]}"# }
    private var ifrFM6: String { #"{"timeFrom":\#(e(6)),"timeTo":\#(e(24)),"fcstChange":"FM","wdir":180,"wspd":10,"visib":2,"clouds":[{"cover":"OVC","base":800}]}"# }
    private var lifrTempo2to4: String { #"{"timeFrom":\#(e(2)),"timeTo":\#(e(4)),"fcstChange":"TEMPO","visib":0.5,"clouds":[{"cover":"OVC","base":300}]}"# }

    // MARK: - Period selection

    @Test func periodSelectionAtBoundaries() throws {
        let t = try taf([vfrBase, ifrFM6].joined(separator: ","))
        #expect(t.forecast(at: at(0))?.prevailing.flightCategory == .vfr)          // validFrom is inclusive
        #expect(t.forecast(at: at(6) - 1)?.prevailing.flightCategory == .vfr)
        #expect(t.forecast(at: at(6))?.prevailing.flightCategory == .ifr)          // FM takes over at its time
        #expect(t.forecast(at: at(24) - 1)?.prevailing.flightCategory == .ifr)
        #expect(t.forecast(at: at(-0.01)) == nil)                                   // before validity
        #expect(t.forecast(at: at(24)) == nil)                                      // validTo is exclusive
    }

    @Test func expiredTafIsNeverCurrent() throws {
        let t = try taf([vfrBase, ifrFM6].joined(separator: ","))
        #expect(t.currentForecast(at: at(24)) == nil)
        #expect(t.currentForecast(at: at(30)) == nil)
        #expect(t.remainingTimeline(at: at(30)).isEmpty)
        #expect(TafHeroBrief.build(t, now: at(30)).map(\.text).joined() == "This TAF has expired.")
    }

    @Test func upcomingTafWithinTwoHoursUsesItsFirstPeriod() throws {
        let t = try taf([vfrBase, ifrFM6].joined(separator: ","))
        #expect(t.currentForecast(at: at(-1))?.flightCategory == .vfr)
        #expect(t.currentForecast(at: at(-3)) == nil)
    }

    // MARK: - BECMG

    // Base VFR; BECMG 04–06 (complete at 06) to IFR. The change is prevailing only once its window ends.
    private var becmgToIFR: String { #"{"timeFrom":\#(e(4)),"timeTo":\#(e(24)),"timeBec":\#(e(6)),"fcstChange":"BECMG","wdir":180,"wspd":12,"visib":2,"clouds":[{"cover":"OVC","base":800}]}"# }

    @Test func becmgBeforeDuringAfter() throws {
        let t = try taf([#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]}"#, becmgToIFR].joined(separator: ","))
        #expect(t.forecast(at: at(3))?.prevailing.flightCategory == .vfr)   // before
        #expect(t.forecast(at: at(5))?.prevailing.flightCategory == .vfr)   // during the change window
        let after = try #require(t.forecast(at: at(6))?.prevailing)        // after: the change is prevailing
        #expect(after.flightCategory == .ifr)
        #expect(after.type == .becmg)
        #expect(after.fromTime == at(6))
        #expect(t.forecast(at: at(6))?.overlays.isEmpty == true)            // a BECMG is never an overlay
        #expect(t.currentForecast(at: at(10))?.flightCategory == .ifr)
    }

    @Test func becmgInheritsWhatItOmits() throws {
        // BECMG states only wind; visibility and sky persist from the prevailing base.
        let t = try taf([#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":3,"clouds":[{"cover":"BKN","base":1500}]}"#,
                         #"{"timeFrom":\#(e(2)),"timeTo":\#(e(24)),"timeBec":\#(e(3)),"fcstChange":"BECMG","wdir":250,"wspd":15,"wgst":25,"visib":"","clouds":[]}"#]
            .joined(separator: ","))
        let p = try #require(t.forecast(at: at(4))?.prevailing)
        #expect(p.wind?.gust == 25)
        #expect(p.visibility == .exact(3))
        #expect(ForecastRules.ceilingFeet(p) == 1500)
        #expect(p.flightCategory == .mvfr)
    }

    @Test func becmgChainLikeMilitaryTafs() throws {
        // NOAA gives each BECMG timeTo = the next BECMG's start; the change persists until superseded.
        let t = try taf([#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"FEW","base":12000}]}"#,
                         #"{"timeFrom":\#(e(0)),"timeTo":\#(e(1)),"timeBec":\#(e(1)),"fcstChange":"BECMG","wdir":110,"wspd":10,"visib":"6+","clouds":[{"cover":"BKN","base":2500}]}"#,
                         #"{"timeFrom":\#(e(1)),"timeTo":\#(e(24)),"timeBec":\#(e(2)),"fcstChange":"BECMG","wdir":120,"wspd":16,"visib":"6+","clouds":[{"cover":"SCT","base":8000}]}"#]
            .joined(separator: ","))
        #expect(t.forecast(at: at(0.5))?.prevailing.flightCategory == .vfr)
        #expect(t.forecast(at: at(1.5))?.prevailing.flightCategory == .mvfr)   // first change holds through the second window
        #expect(t.forecast(at: at(2))?.prevailing.flightCategory == .vfr)
    }

    // MARK: - Overlays stay separate

    @Test func tempoNeverLeaksIntoPrevailing() throws {
        let t = try taf([vfrBase, ifrFM6, lifrTempo2to4].joined(separator: ","))
        let c = try #require(t.forecast(at: at(3)))
        #expect(c.prevailing.flightCategory == .vfr)
        #expect(c.overlays.map(\.type) == [.tempo])
        #expect(c.overlays.first?.flightCategory == .lifr)
        #expect(t.forecast(at: at(4))?.overlays.isEmpty == true)                  // TEMPO over at its toTime
        #expect(t.prevailingTimeline.map(\.type) == [.base, .fm])
    }

    @Test func prob30TempoKeepsItsProbability() throws {
        let t = try taf([vfrBase, #"{"timeFrom":\#(e(2)),"timeTo":\#(e(4)),"fcstChange":"TEMPO","probability":30,"visib":2,"wxString":"TSRA","clouds":[{"cover":"BKN","base":3000,"type":"CB"}]}"#]
            .joined(separator: ","))
        let c = try #require(t.forecast(at: at(3)))
        #expect(c.overlays.map(\.type) == [.prob30])
        #expect(c.prevailing.type == .base)
    }

    @Test func forecastTrendComparesPrevailingNotTempo() throws {
        // A TEMPO starts before the next FM (NOAA lists periods in time order); the trend must compare
        // against the FM (IFR), not the TEMPO (LIFR).
        let t = try taf([vfrBase, lifrTempo2to4, ifrFM6].joined(separator: ","))
        let m = try metar(hours: 1, visib: #""10+""#, clouds: #"[{"cover":"SCT","base":5000}]"#, cat: "VFR")
        let trend = ForecastTrend.derive(metar: m, taf: t, now: at(1))
        #expect(trend.forecastCategory == .ifr)
    }

    @Test func verificationScoresAgainstPrevailingNotExpiredTempo() throws {
        // Observation at 05:00 (after the 02–04 TEMPO ended) is scored against the VFR base.
        let t = try taf([vfrBase, ifrFM6, lifrTempo2to4].joined(separator: ","))
        let current = try metar(hours: 5.5, visib: #""10+""#, clouds: #"[{"cover":"SCT","base":5000}]"#, cat: "VFR")
        let past = try metar(hours: 5, visib: #""10+""#, clouds: #"[{"cover":"SCT","base":5000}]"#, cat: "VFR")
        let v = try #require(TafVerification.derive(metars: [current, past], taf: t))
        #expect(v.points.count == 1)
        #expect(v.points.first?.forecastCategory == .vfr)
        #expect(v.categoryAccuracyPct == 100)
    }

    @Test func verificationSkipsObservationsOutsideValidity() throws {
        let t = try taf([vfrBase, ifrFM6].joined(separator: ","), validHours: 6)
        let current = try metar(hours: 8, visib: #""10+""#, clouds: "[]", cat: "VFR")
        let late = try metar(hours: 7, visib: #""10+""#, clouds: "[]", cat: "VFR")
        #expect(TafVerification.derive(metars: [current, late], taf: t) == nil)
    }

    // MARK: - Hero narrates from now

    @Test func heroNarratesFromThePeriodCoveringNow() throws {
        // IFR until 06, VFR after. At 08:00 the IFR period is over — not "IFR now, improving".
        let t = try taf([#"{"timeFrom":\#(e(0)),"timeTo":\#(e(6)),"wdir":200,"wspd":6,"visib":2,"clouds":[{"cover":"OVC","base":800}]}"#,
                         #"{"timeFrom":\#(e(6)),"timeTo":\#(e(24)),"fcstChange":"FM","wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]}"#]
            .joined(separator: ","))
        let early = TafHeroBrief.build(t, now: at(1)).map(\.text).joined()
        #expect(early.contains("IFR now"))
        let later = TafHeroBrief.build(t, now: at(8)).map(\.text).joined()
        #expect(!later.contains("IFR"))
        #expect(later.contains("VFR"))
    }

    @Test func heroIgnoresEndedTempo() throws {
        let tsTempo = #"{"timeFrom":\#(e(1)),"timeTo":\#(e(2)),"fcstChange":"TEMPO","visib":"6+","wxString":"TSRA","clouds":[{"cover":"BKN","base":8000,"type":"CB"}]}"#
        let t = try taf([#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]}"#, tsTempo]
            .joined(separator: ","))
        #expect(TafHeroBrief.build(t, now: at(0.5)).contains { $0.text.contains("TEMPO") })
        #expect(!TafHeroBrief.build(t, now: at(3)).contains { $0.text.contains("TEMPO") })
    }

    // MARK: - #14 category with one axis not forecast

    @Test func oneUnknownAxisKeepsKnownLowerBound() throws {
        // Visibility not forecast, ceiling 700 ft: IFR stands, labeled.
        let t = try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":700}]}"#)
        let p = try #require(t.forecasts.first)
        #expect(p.flightCategory == .ifr)
        #expect(p.unforecastAxis == "visibility")
        #expect(TafHeroBrief.build(t, now: at(1)).map(\.text).joined().contains("visibility not forecast"))
    }

    @Test func oneUnknownAxisThatAllowsVFRIsUnknown() throws {
        // Visibility 6+ with no sky forecast, and a 5,000 ft ceiling with no visibility: neither is VFR.
        let noSky = try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"6+","clouds":[]}"#)
        #expect(noSky.forecasts.first?.flightCategory == .unknown)
        #expect(noSky.forecasts.first?.unforecastAxis == "clouds")
        let noVis = try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":5000}]}"#)
        #expect(noVis.forecasts.first?.flightCategory == .unknown)
        // A stated clear sky is a known axis.
        let skc = try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SKC","base":null}]}"#)
        #expect(skc.forecasts.first?.flightCategory == .vfr)
    }

    @Test func cavokNscIsAStatedClearSky() throws {
        // LFPG 211700Z: "25012KT CAVOK" — NOAA decodes CAVOK as visib "6+" with cover NSC.
        let t = try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":250,"wspd":12,"visib":"6+","clouds":[{"cover":"NSC","base":null,"type":null}]}"#)
        let p = try #require(t.forecasts.first)
        #expect(p.flightCategory == .vfr)
        #expect(p.clouds.first?.coverage == .noSignificantCloud)
        #expect(ForecastRules.ceilingFeet(p) == nil)
    }

    @Test func cloudsCarryIntoOverlaysThatOmitThem() throws {
        // IFR base (OVC007, 2 SM); wind-only TEMPO (KLSV/KINS style: visib "", clouds []). The TEMPO
        // keeps the prevailing ceiling and visibility — it is not VFR.
        let t = try taf([#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":2,"clouds":[{"cover":"OVC","base":700}]}"#,
                         #"{"timeFrom":\#(e(2)),"timeTo":\#(e(4)),"fcstChange":"TEMPO","wdir":120,"wspd":16,"wgst":28,"visib":"","clouds":[]}"#]
            .joined(separator: ","))
        let tempo = try #require(t.forecasts.first { $0.type == .tempo })
        #expect(ForecastRules.ceilingFeet(tempo) == 700)
        #expect(tempo.visibility == .exact(2))
        #expect(tempo.flightCategory == .ifr)
        #expect(tempo.wind?.gust == 28)
    }
}
