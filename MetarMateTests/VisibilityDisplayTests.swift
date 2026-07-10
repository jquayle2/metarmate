import Testing
import Foundation
@testable import MetarMate

// The display bug commit 10 kills: no parsed-visibility formatter may render "+" for an .exact
// value, and none may drop the "+" for a .greaterThan. Every parsed-display formatter routes
// through Visibility.displayNumber (the %g core), so testing that core proves they agree; the two
// standalone formatters (TafFormat.visText, the widget's visibilityDisplay) and the SharedComponents
// strip are also tested directly.
struct VisibilityDisplayTests {

    private func metar(_ json: String) throws -> Metar {
        try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }

    @Test func displayNumberCore() {
        #expect(Visibility.exact(6).displayNumber == "6")          // exactly 6 -> "6", NEVER "6+"
        #expect(Visibility.greaterThan(6).displayNumber == "6+")   // P6SM -> "6+"
        #expect(Visibility.exact(1.5).displayNumber == "1.5")
        #expect(Visibility.exact(10).displayNumber == "10")        // exact 10 -> "10", not "10+"
        #expect(Visibility.greaterThan(10).displayNumber == "10+") // P10SM -> "10+"
        #expect(Visibility.unknown.displayNumber == nil)
    }

    @Test func tafVisTextExactVsGreaterThan() {
        #expect(TafFormat.visText(.exact(6)) == "6 SM")            // the site that used to print "6+" for a real 6
        #expect(TafFormat.visText(.greaterThan(6)) == "6+ SM")
        #expect(TafFormat.visText(.unknown) == "—")
    }

    // SharedComponents strip (the free quickWeatherSummary) through the real parse path.
    @Test func sharedComponentsStripDistinguishesSixFromP6SM() throws {
        let exact6 = try metar(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 6SM FEW040 20/10 A2992","visib":6,"wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        let p6sm   = try metar(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT P6SM FEW040 20/10 A2992","visib":"6+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(quickWeatherSummary(metar: exact6).contains("6SM"))
        #expect(!quickWeatherSummary(metar: exact6).contains("6+SM"))   // exactly-6 is NOT "6+SM"
        #expect(quickWeatherSummary(metar: p6sm).contains("6+SM"))      // P6SM IS "6+SM"
    }

    @Test func widgetVisibilityDisplayCarriesGreaterThan() {
        func snap(_ sm: Double, gt: Bool, reported: Bool = true) -> WidgetWeatherSnapshot {
            WidgetWeatherSnapshot(
                icao: "K", iata: nil, airportName: "K", flightCategory: .vfr,
                windDirection: 270, windSpeed: 8, windGust: nil, windIsVariable: false, windReported: true,
                visibility: sm, visibilityReported: reported, visibilityIsGreaterThan: gt,
                ceilingFeet: nil, temperature: 20, dewpoint: 10, altimeter: 29.92,
                trendDirection: .unknown, trendHeadline: "", tafAccuracyPct: nil,
                forecastWindDivergenceKt: nil, forecastCeilingDivergenceFt: nil, forecastVisibilityDivergenceSM: nil,
                isAdvisory: false, observationTime: Date(), snapshotTime: Date())
        }
        #expect(snap(6, gt: true).visibilityDisplay == "6+")   // lock-screen shows "6+" for P6SM
        #expect(snap(6, gt: false).visibilityDisplay == "6")   // and "6" for an exact 6
        #expect(snap(0, gt: false, reported: false).visibilityDisplay == "—")
    }
}
