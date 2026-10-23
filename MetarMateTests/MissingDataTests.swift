import Testing
import Foundation
@testable import MetarMate

// A2: a missing METAR field is "not reported", never a value (D#2; audit #6, #8, #10, #12, #15).
// METARs here are NOAA aviationweather.gov JSON shapes; omitted keys are what NOAA sends when the
// group is missing from the report.
@MainActor
struct MissingDataTests {

    static let obs = 1792770660   // Oct 23, 2026 15:51Z

    /// A METAR from NOAA-shaped JSON. `fields` are raw JSON key/value pairs (omit a key = missing).
    static func metar(_ fields: String, raw: String = "METAR KTST 231551Z AUTO 10SM CLR 19/13 A2996",
                      obsTime: Int? = obs) throws -> Metar {
        let time = obsTime.map { #""obsTime":\#($0),"# } ?? ""
        let json = #"{"icaoId":"KTST",\#(time)"rawOb":"\#(raw)"\#(fields.isEmpty ? "" : "," + fields)}"#
        return try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }

    static let full = #""temp":19,"dewp":13,"altim":1014.6,"wdir":200,"wspd":8,"visib":"10+","clouds":[],"fltCat":"VFR""#

    // MARK: - #8 / F15: temperature, dewpoint, altimeter

    @Test func missingTempDewAltimParseAsNil() throws {
        let m = try Self.metar(#""wdir":200,"wspd":8,"visib":"10+","clouds":[],"fltCat":"VFR""#)
        #expect(m.temperature == nil)
        #expect(m.dewpoint == nil)
        #expect(m.altimeter == nil)
    }

    @Test func reportedTempDewAltimStillParse() throws {
        let m = try Self.metar(Self.full)
        #expect(m.temperature == 19)
        #expect(m.dewpoint == 13)
        #expect(abs((m.altimeter ?? 0) - 29.96) < 0.01)
    }

    /// KLAS-type 42 °C day with the temperature group missing: no density altitude at all (was
    /// computed off 0 °C, ~900 ft green).
    @Test func missingTemperatureMeansNoDensityAltitude() throws {
        let m = try Self.metar(#""dewp":-5,"altim":1012.5,"wspd":5,"wdir":200"#)
        #expect(DensityAltitude.calculate(temperatureC: m.temperature.map(Double.init),
                                          dewpointC: m.dewpoint.map(Double.init),
                                          altimeterInHg: m.altimeter, fieldElevationFt: 2181) == nil)
    }

    /// A report without an altimeter between two at 30.10 was a 0.18 inHg "drop" to 29.92 ->
    /// "Pressure falling rapidly". Missing altimeters are left out of the trend.
    @Test func missingAltimeterDoesNotFakeFallingPressure() throws {
        let older = try Self.metar(Self.full.replacingOccurrences(of: "1014.6", with: "1019.3"),
                                   obsTime: Self.obs - 7200)
        let middle = try Self.metar(Self.full.replacingOccurrences(of: "1014.6", with: "1019.3"),
                                    obsTime: Self.obs - 3600)
        let newest = try Self.metar(#""temp":19,"dewp":13,"wdir":200,"wspd":8"#)
        let trend = try #require(HistoryRules.pressureTrend(from: [newest, middle, older]))
        #expect(trend.state == .steady)
        #expect(!trend.isRapid)
        #expect(HistoryRules.pressureTrend(from: [newest, older]) == nil)   // one real sample: no trend
    }

    @Test func missingTempDewNoFogOrLowAltimeterNote() throws {
        let m = try Self.metar(#""wdir":200,"wspd":8,"visib":"10+","fltCat":"VFR""#)
        let notes = MetarPilotNotes.build(metar: m, history: [m])
        #expect(!notes.contains { $0.text.contains("spread") })
        #expect(!notes.contains { $0.text.contains("Near-freezing") })
        #expect(!notes.contains { $0.text.contains("Altimeter") })
    }

    /// The app-written widget snapshot carries nil, not 0 °C / 29.92.
    @Test func widgetSnapshotKeepsMissingAsNil() throws {
        let m = try Self.metar(#""wdir":200,"wspd":8,"visib":"10+","fltCat":"VFR""#)
        let airport = Airport(icao: "KTST", iata: nil, name: "Test", latitude: 36, longitude: -115, elevation: 2000)
        let snap = WidgetWeatherSnapshot.from(airport: airport, metar: m, trend: nil, tafVerification: nil)
        #expect(snap.temperature == nil)
        #expect(snap.dewpoint == nil)
        #expect(snap.altimeter == nil)
    }
}
