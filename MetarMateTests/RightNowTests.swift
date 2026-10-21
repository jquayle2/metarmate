import Testing
import Foundation
@testable import MetarMate

// "Right now" beside a borrowed TAF (D#16) and the hero leading with this field when it's worse.
// "Worse" = Forecast Deviation Strip thresholds: lower category, ceiling > 300 ft lower, visibility
// > 0.5 SM lower (ignored when both > 5 SM), sustained or peak wind > 5 kt higher. Missing items
// are "not reported" and never count as better; a report over 75 min stops the comparison.
@MainActor
struct RightNowTests {

    private let now = Date(timeIntervalSince1970: 1792609200)   // Oct 21, 2026 19Z

    /// A METAR `minutesAgo` before now. `clouds` is a JSON array; `raw` lets a test state CLR.
    private func metar(_ id: String, minutesAgo: Int = 10, cat: String = "VFR", visib: String = "10",
                       clouds: String = #"[{"cover":"BKN","base":6000}]"#, wind: String = #""wdir":320,"wspd":6"#,
                       raw: String? = nil) throws -> Metar {
        let json = #"{"icaoId":"\#(id)","obsTime":\#(1792609200 - minutesAgo * 60),"temp":15,"dewp":5,\#(wind.isEmpty ? "" : wind + ",")"visib":\#(visib),"altim":1013,"rawOb":"\#(raw ?? "METAR \(id) synthetic")","clouds":\#(clouds),"fltCat":"\#(cat)"}"#
        return try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }

    private func compare(_ here: Metar, _ there: Metar) -> WorseHere.Result {
        WorseHere.compare(here: ComparableConditions(metar: here), there: ComparableConditions(metar: there))
    }

    // MARK: - Thresholds

    @Test func lowerCategoryIsWorse() throws {
        let r = compare(try metar("KBCE", cat: "IFR", visib: "5", clouds: #"[{"cover":"OVC","base":700}]"#),
                        try metar("KCDC"))
        #expect(r.isWorse)
        #expect(r.reasons.first == "IFR here, VFR there")
    }

    @Test func ceilingMoreThan300ftLower() throws {
        let there = try metar("KCDC", clouds: #"[{"cover":"BKN","base":6000}]"#)
        #expect(!compare(try metar("KBCE", clouds: #"[{"cover":"BKN","base":5700}]"#), there).isWorse)   // 300: not more than
        #expect(compare(try metar("KBCE", clouds: #"[{"cover":"BKN","base":5600}]"#), there).isWorse)    // 400
        // A ceiling here and none there (stated clear) is worse; the reverse is not.
        let clear = try metar("KCDC", clouds: "[]", raw: "METAR KCDC 211850Z 32006KT 10SM CLR 15/05 A2992")
        #expect(compare(try metar("KBCE"), clear).isWorse)
        #expect(!compare(clear, try metar("KBCE")).isWorse)
    }

    @Test func visibilityMoreThanHalfMileLowerUnlessBothAboveFive() throws {
        let there = try metar("KCDC", visib: "3")
        #expect(!compare(try metar("KBCE", visib: "2.5"), there).isWorse)   // 0.5: not more than
        #expect(compare(try metar("KBCE", visib: "2.25"), there).isWorse)   // 0.75
        // Both above 5 SM: differences don't count.
        #expect(!compare(try metar("KBCE", visib: "6"), try metar("KCDC", visib: #""10+""#)).isWorse)
        #expect(compare(try metar("KBCE", visib: "4"), try metar("KCDC", visib: #""10+""#)).isWorse)
    }

    @Test func sustainedAndPeakWindComparedSeparately() throws {
        let there = try metar("KCDC", wind: #""wdir":320,"wspd":10"#)
        #expect(!compare(try metar("KBCE", wind: #""wdir":320,"wspd":15"#), there).isWorse)              // +5
        #expect(compare(try metar("KBCE", wind: #""wdir":320,"wspd":16"#), there).isWorse)               // +6
        // Same sustained, gust 16 here vs no gust (peak 10) there: peak +6.
        let gusty = compare(try metar("KBCE", wind: #""wdir":320,"wspd":10,"wgst":16"#), there)
        #expect(gusty.reasons == ["gusts 6 kt stronger"])
    }

    @Test func betterHereSaysNothing() throws {
        let r = compare(try metar("KBCE"), try metar("KCDC", cat: "IFR", visib: "2", clouds: #"[{"cover":"OVC","base":700}]"#))
        #expect(!r.isWorse)
        #expect(r.reasons.isEmpty)
    }

    @Test func missingItemsAreNotReportedNeverBetter() throws {
        // Visibility and wind missing here; KCDC at 1 SM. Missing never counts as better (no claim),
        // and it's named, so the empty warning isn't read as "fine here".
        let here = try metar("KBCE", visib: #""""#, wind: "")
        let there = try metar("KCDC", cat: "IFR", visib: "1")
        let r = compare(here, there)
        #expect(r.notReportedHere == ["visibility", "wind"])
        #expect(!r.reasons.contains { $0.contains("visibility") || $0.contains("wind") })
        // Sky with no cloud group and no CLR: not reported, not "no ceiling".
        let noSky = ComparableConditions(metar: try metar("KBCE", clouds: "[]"))
        #expect(noSky.ceiling == .notReported)
        let row = RightNow.make(fieldId: "KBCE", field: here, stationId: "KCDC", station: there, at: now)
        #expect(row.notReportedLines.contains("Visibility not reported at KBCE"))
        #expect(row.notReportedLines.contains("Wind not reported at KBCE"))
    }

    // MARK: - Not current

    @Test func notCurrentReportStopsTheComparison() throws {
        let field = try metar("KBCE", cat: "IFR", visib: "5", clouds: #"[{"cover":"OVC","base":700}]"#)
        let stale = RightNow.make(fieldId: "KBCE", field: field, stationId: "KCDC",
                                  station: try metar("KCDC", minutesAgo: 76), at: now)
        #expect(stale.notCurrent == ["KCDC report not current"])
        #expect(stale.comparison == nil)
        let missing = RightNow.make(fieldId: "KBCE", field: nil, stationId: "KCDC", station: try metar("KCDC"), at: now)
        #expect(missing.notCurrent == ["KBCE report not current"])
        #expect(missing.comparison == nil)
        // Late (65–75 min) still compares (D#4: still shown).
        let late = RightNow.make(fieldId: "KBCE", field: field, stationId: "KCDC",
                                 station: try metar("KCDC", minutesAgo: 70), at: now)
        #expect(late.notCurrent.isEmpty)
        #expect(late.comparison?.isWorse == true)
    }

    @Test func summaryNeverInventsNumbers() throws {
        #expect(RightNow.summary(try metar("KBCE", visib: "5", clouds: #"[{"cover":"OVC","base":700}]"#, wind: #""wdir":150,"wspd":5"#))
                == "ceiling 700 ft · vis 5 SM · wind 5 kt")
        #expect(RightNow.summary(try metar("KBCE", visib: #""""#, clouds: "[]", wind: ""))
                == "ceiling not reported · vis not reported · wind not reported")
    }

    // MARK: - Hero leads with this field when it's worse than the TAF's current period

    private func kcdcTaf() throws -> Taf {
        let t18 = 1792605600
        let json = #"{"icaoId":"KCDC","issueTime":"2026-10-21T17:20:00.000Z","validTimeFrom":\#(t18),"validTimeTo":\#(t18 + 86400),"rawTAF":"synthetic","fcsts":[{"timeFrom":\#(t18),"timeTo":\#(t18 + 86400),"wdir":320,"wspd":6,"visib":"6+","clouds":[{"cover":"BKN","base":6000}]},{"timeFrom":\#(t18 + 3600),"timeTo":\#(t18 + 21600),"fcstChange":"PROB","probability":30,"wdir":"VRB","wspd":15,"wgst":30,"visib":6,"wxString":"-TSRA","clouds":[{"cover":"OVC","base":6000,"type":"CB"}]}]}"#
        return try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
    }
    private let kcdc = TafSource(stationId: "KCDC", name: nil, distanceNm: 45, bearing: "W", elevationDifferenceFt: -2003, isBorrowed: true)

    @Test func heroLeadsWithThisFieldWhenWorse() throws {
        let taf = try kcdcTaf()
        let kbce = try metar("KBCE", cat: "IFR", visib: "5", clouds: #"[{"cover":"OVC","base":700}]"#)
        let lead = RightNow.heroLead(fieldId: "KBCE", field: kbce, taf: taf, source: kcdc, at: now)
        #expect(lead.stationLabel == "KCDC (45 nm W)")
        #expect(lead.fieldLead?.id == "KBCE" && lead.fieldLead?.category == .ifr)
        let segs = TafHeroBrief.build(taf, now: now, stationLabel: lead.stationLabel, fieldLead: lead.fieldLead)
        let hero = segs.map(\.text).joined()
        #expect(hero.hasPrefix("KBCE is IFR now. KCDC (45 nm W) forecasts VFR, but PROB30 thunderstorms with light rain "))
        #expect(segs.contains { $0.text == "IFR now." && $0.color == ColorRules.flightCategoryColor(.ifr) })
    }

    @Test func noLeadWhenNotWorseNotCurrentOrUnknown() throws {
        let taf = try kcdcTaf()
        let same = RightNow.heroLead(fieldId: "KBCE", field: try metar("KBCE"), taf: taf, source: kcdc, at: now)
        #expect(same.stationLabel == "KCDC" && same.fieldLead == nil)
        let stale = try metar("KBCE", minutesAgo: 80, cat: "IFR", visib: "5", clouds: #"[{"cover":"OVC","base":700}]"#)
        #expect(RightNow.heroLead(fieldId: "KBCE", field: stale, taf: taf, source: kcdc, at: now).fieldLead == nil)
        let unknown = try metar("KBCE", cat: "UNKN", visib: "5", clouds: #"[{"cover":"OVC","base":700}]"#)
        #expect(RightNow.heroLead(fieldId: "KBCE", field: unknown, taf: taf, source: kcdc, at: now).fieldLead == nil)
        #expect(RightNow.heroLead(fieldId: "KBCE", field: nil, taf: taf, source: kcdc, at: now).fieldLead == nil)
    }

    // MARK: - The forecast trend's station METAR must be current (75 min)

    @Test func forecastTrendNeedsACurrentStationReport() throws {
        let taf = try kcdcTaf()
        let field = [try metar("KBCE", minutesAgo: 5), try metar("KBCE", minutesAgo: 35)]
        let status = TafStatus.borrowed(kcdc, ownExpired: false)
        let stale = NearbyTaf.derive(fieldHistory: field, taf: taf, status: status,
                                     stationHistory: [try metar("KCDC", minutesAgo: 80)], at: now)
        #expect(stale.trend.forecast.overall == .unknown)
        let late = NearbyTaf.derive(fieldHistory: field, taf: taf, status: status,
                                    stationHistory: [try metar("KCDC", minutesAgo: 70)], at: now)
        #expect(late.trend.forecast.overall != .unknown)
    }
}
