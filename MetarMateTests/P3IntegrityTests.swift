import Testing
import Foundation
@testable import MetarMate

// A2 Step 5: P3 data-integrity items (Jeff, Oct 23: all six in A2).
@MainActor
struct P3IntegrityTests {

    /// NOAA sends M1/4SM as plain 0.25; the report's own group says it's LESS than 1/4.
    @Test func lessThanQuarterMile() throws {
        let m = try MissingDataTests.metar(#""temp":10,"dewp":10,"altim":1013,"wdir":0,"wspd":0,"visib":0.25,"clouds":[{"cover":"OVC","base":100}],"fltCat":"LIFR""#,
                                           raw: "METAR KTST 231551Z 00000KT M1/4SM FG VV001 10/10 A2991")
        #expect(m.visibility == .lessThan(0.25))
        #expect(m.visibility.displayNumber == "<1/4")
        #expect(m.visibility.exactSM == nil)   // no exact magnitude for deltas
        #expect(FlightCategory.forVisibility(try #require(m.visibility.lowerBoundSM)) == .lifr)
        #expect(SiriReportWording.conditionsLine(metar: m).contains("Vis <1/4 sm"))
        let airport = Airport(icao: "KTST", iata: nil, name: "Test", latitude: 36, longitude: -115, elevation: 100)
        #expect(WidgetWeatherSnapshot.from(airport: airport, metar: m, trend: nil, tafVerification: nil).visibilityDisplay == "<1/4")
    }

    /// An exact 1/4 SM (no M) stays exact, and Siri no longer says "0 miles".
    @Test func exactQuarterMileIsSpokenAsAFraction() throws {
        let m = try MissingDataTests.metar(#""temp":10,"dewp":10,"altim":1013,"wdir":0,"wspd":0,"visib":0.25,"fltCat":"LIFR""#,
                                           raw: "METAR KTST 231551Z 00000KT 1/4SM FG VV001 10/10 A2991")
        #expect(m.visibility == .exact(0.25))
        #expect(SiriReportWording.conditionsLine(metar: m).contains("Vis 1/4 sm"))
    }

    /// Snapshots written before visibilityIsLessThan existed still decode (widget App Group).
    @Test func legacySnapshotStillDecodes() throws {
        let m = try MissingDataTests.metar(MissingDataTests.full)
        let airport = Airport(icao: "KTST", iata: nil, name: "Test", latitude: 36, longitude: -115, elevation: 100)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            WidgetWeatherSnapshot.from(airport: airport, metar: m, trend: nil, tafVerification: nil))) as! [String: Any]
        json.removeValue(forKey: "visibilityIsLessThan")
        let decoded = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.visibilityIsLessThan == nil)
    }

    /// A PROB group with no percentage isn't assumed PROB30.
    @Test func probWithoutNumberIsNotProb30() throws {
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"synthetic","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200,"wdir":200,"wspd":8,"visib":"6+","clouds":[{"cover":"SKC"}]},{"timeFrom":1792760400,"timeTo":1792767600,"fcstChange":"PROB","visib":2}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let prob = try #require(taf.forecasts.last)
        #expect(prob.type == .prob)
        #expect(prob.type.isProbability)
        #expect(prob.type.rawValue == "PROB")
    }

    /// `metars.first ?? metars[0]` trapped on an empty list.
    @Test func emptyHistoryDoesNotTrap() {
        let t = WeatherTrend.derive(metars: [], taf: nil)
        #expect(t.overall == .unknown)
    }

    /// Steady/mixed draw level, unknown draws no direction; VoiceOver says which.
    @Test func trendArrowHeadings() {
        #expect(ColorRules.trendStyle(.improving).heading == .up)
        #expect(ColorRules.trendStyle(.steady).heading == .level)
        #expect(ColorRules.trendStyle(.deteriorating).heading == .down)
        #expect(ColorRules.trendStyle(.unknown).heading == .unknown)
        #expect(TrendArrowView(direction: .unknown).accessibilityText == "Trend unknown")
        #expect(TrendArrowView(direction: .improving, mixed: true).accessibilityText == "Trend mixed")
    }
}
