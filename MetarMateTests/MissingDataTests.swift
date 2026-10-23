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
        #expect(!notes.contains { $0.text.contains("inHg") })   // no low-pressure note off 29.92
        // D#10: the missing fields get the symmetric "not reported" note instead.
        #expect(notes.contains { $0.text == "Altimeter not reported — no altimeter group in this observation" })
        #expect(notes.contains { $0.text == "Temperature and dewpoint not reported — no density altitude or fog check" })
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

    // MARK: - #10: wind direction / speed

    /// `///25KT` (NOAA: no wdir, wspd 25): direction unknown, not 000° and not variable. At a
    /// north runway, 000° read as a straight headwind, "XW 0 kt".
    @Test func missingDirectionWithSpeedIsUnknownNotNorth() throws {
        let m = try Self.metar(#""temp":19,"wspd":25,"visib":"10+","fltCat":"VFR""#,
                               raw: "METAR KTST 231551Z AUTO ///25KT 10SM CLR 19/13 A2996")
        #expect(m.wind.isReported)
        #expect(m.wind.speed == 25)
        #expect(m.wind.direction == nil)
        #expect(!m.wind.isVariable)
        #expect(m.wind.directionCode == "///")
        #expect(m.wind.displayString == "Direction not reported, 25kt")
        let c = AlertConditions(from: m)
        #expect(c.windDirection == nil && !c.windIsVariable && c.windSpeed == 25)
    }

    /// `wdir:null` with a speed — the shape NOAA sends for a direction sensor dropout.
    @Test func nullDirectionWithSpeedIsUnknown() throws {
        let m = try Self.metar(#""wdir":null,"wspd":12,"wgst":20"#)
        #expect(m.wind.direction == nil && !m.wind.isVariable && m.wind.speed == 12 && m.wind.gust == 20)
    }

    /// Direction with no speed: the wind can't be evaluated, so it's "not reported", not 0 kt.
    @Test func directionWithoutSpeedIsNotReported() throws {
        let m = try Self.metar(#""wdir":270"#)
        #expect(!m.wind.isReported)
    }

    @Test func variableWindStillVariable() throws {
        let m = try Self.metar(#""wdir":"VRB","wspd":22,"wgst":32"#,
                               raw: "METAR KTST 231551Z VRB22G32KT 10SM CLR 19/13 A2996")
        #expect(m.wind.isVariable && m.wind.direction == nil && m.wind.directionCode == "VRB")
        #expect(AlertConditions(from: m).windIsVariable)
    }

    @Test func tafMissingDirectionIsUnknown() throws {
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"TAF KTST 231120Z 2312/2412 ///15KT P6SM SKC","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200,"wspd":15,"visib":"6+","clouds":[{"cover":"SKC"}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let wind = try #require(taf.forecasts.first?.wind)
        #expect(wind.direction == nil && !wind.isVariable && wind.speed == 15)
    }

    // MARK: - #12 / #6: cloud base and sky condition

    /// `BKN///` (NOAA: cover BKN, no base). Was 0 ft: LIFR, a "Ceiling 0 ft" note, "Ceiling Falling".
    @Test(arguments: [#"[{"cover":"BKN"}]"#, #"[{"cover":"BKN","base":null}]"#])
    func missingCloudBaseIsNotZeroFeet(_ clouds: String) throws {
        let m = try Self.metar(Self.full.replacingOccurrences(of: #""clouds":[]"#, with: #""clouds":\#(clouds)"#),
                               raw: "METAR KTST 231551Z AUTO 20008KT 10SM BKN/// 19/13 A2996")
        #expect(m.clouds.first?.altitude == nil)
        #expect(m.ceiling == .notReported)
        #expect(m.ceilingFeet == nil)
        let notes = MetarPilotNotes.build(metar: m, history: [m])
        #expect(!notes.contains { $0.text.contains("0 ft") || $0.text.contains("LIFR") })
        #expect(notes.contains { $0.text == "Ceiling not reported — a cloud layer has no base" })
        let earlier = try Self.metar(Self.full.replacingOccurrences(of: #""clouds":[]"#, with: #""clouds":[{"cover":"BKN","base":4000}]"#),
                                     raw: "METAR KTST 231451Z AUTO 20008KT 10SM BKN040 19/13 A2996", obsTime: Self.obs - 3600)
        #expect(ObservedTrend.derive(from: [m, earlier]).ceiling == .unknown)
    }

    /// Live NOAA, Oct 23 2026: KIGM `10SM CLR` arrives as `clouds: []`. A stated clear sky is
    /// "no ceiling", not "not reported" (Siri said "Sky condition not reported" for it).
    @Test func statedClearWithNoLayersIsClear() throws {
        let m = try Self.metar(Self.full)   // raw "... 10SM CLR ..."
        #expect(m.skyReported)
        #expect(m.ceiling == .none)
        #expect(m.skyCode == "CLR")
        #expect(m.noCeilingWords == "Clear")
        #expect(SiriReportWording.skyText(m) == "Sky clear")
    }

    /// No sky group at all: unknown, never unlimited (was 99,000 ft in go/no-go).
    @Test func missingSkyGroupIsNotReported() throws {
        let m = try Self.metar(Self.full, raw: "METAR KTST 231551Z AUTO 20008KT 10SM 19/13 A2996")
        #expect(!m.skyReported)
        #expect(m.ceiling == .notReported)
        #expect(m.skyCode == "Sky —")
        #expect(SiriReportWording.skyText(m) == "Sky not reported")
        #expect(AlertConditions(from: m).ceiling == .notReported)
    }

    /// FEW/SCT only: no ceiling, but never "Clear"/"CLR" (F18).
    @Test func fewScatteredIsNoCeilingNotClear() throws {
        let m = try Self.metar(Self.full.replacingOccurrences(of: #""clouds":[]"#, with: #""clouds":[{"cover":"FEW","base":5500},{"cover":"SCT","base":10000}]"#),
                               raw: "METAR KTST 231551Z 20008KT 10SM FEW055 SCT100 19/13 A2996")
        #expect(m.ceiling == .none)
        #expect(m.skyCode == "FEW 55")
        #expect(m.noCeilingWords == "No ceiling")
        #expect(SiriReportWording.skyText(m) == "No ceiling")
    }

    /// The ceiling is the LOWEST BKN/OVC/VV layer, whatever the list order (P3 `.first` vs `.min()`).
    @Test func ceilingIsLowestLayerNotFirst() throws {
        let m = try Self.metar(Self.full.replacingOccurrences(of: #""clouds":[]"#, with: #""clouds":[{"cover":"OVC","base":2500},{"cover":"BKN","base":1200}]"#),
                               raw: "METAR KTST 231551Z 20008KT 10SM BKN012 OVC025 19/13 A2996")
        #expect(m.ceilingFeet == 1200)
        #expect(m.ceilingCoverage == "BKN")
    }

    /// A no-base layer above a known ceiling leaves that ceiling standing; below it, unknown.
    @Test func noBaseLayerOrdering() throws {
        let above = try Self.metar(Self.full.replacingOccurrences(of: #""clouds":[]"#, with: #""clouds":[{"cover":"BKN","base":1000},{"cover":"OVC"}]"#),
                                   raw: "METAR KTST 231551Z 20008KT 10SM BKN010 OVC/// 19/13 A2996")
        #expect(above.ceiling == .feet(1000))
        let below = try Self.metar(Self.full.replacingOccurrences(of: #""clouds":[]"#, with: #""clouds":[{"cover":"BKN"},{"cover":"OVC","base":3000}]"#),
                                   raw: "METAR KTST 231551Z 20008KT 10SM BKN/// OVC030 19/13 A2996")
        #expect(below.ceiling == .notReported)
    }

    /// TAF period with a no-base BKN and P6SM: the sky axis is unknown, so VFR vis alone can't
    /// vouch for the period (it was LIFR at "0 ft").
    @Test func tafNoBaseLayerCategory() throws {
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"TAF KTST 231120Z 2312/2412 20008KT P6SM BKN///","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200,"wdir":200,"wspd":8,"visib":"6+","clouds":[{"cover":"BKN"}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let period = try #require(taf.forecasts.first)
        #expect(period.ceiling == .notReported)
        #expect(period.flightCategory == .unknown)
    }

    /// A METAR with no sky group against a TAF ceiling is not "Ceiling cleared" and isn't scored.
    @Test func verificationSkipsUnknownSky() throws {
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"TAF KTST 231120Z 2312/2412 20008KT P6SM BKN020","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200,"wdir":200,"wspd":8,"visib":"6+","clouds":[{"cover":"BKN","base":2000}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let newest = try Self.metar(Self.full, raw: "METAR KTST 231551Z AUTO 20008KT 10SM 19/13 A2996")
        let older = try Self.metar(Self.full, raw: "METAR KTST 231451Z AUTO 20008KT 10SM 19/13 A2996", obsTime: Self.obs - 3600)
        let v = try #require(TafVerification.derive(metars: [newest, older], taf: taf))
        let point = try #require(v.points.first)
        #expect(!point.ceilingReported)
        #expect(!point.divergenceText.contains("Ceiling cleared"))
        #expect(v.ceilingSampleCount == 0)
    }

    // MARK: - #15: observation time

    /// No obsTime: the time comes from the report's own 231551Z group, never "now".
    @Test func missingObsTimeUsesReportGroup() throws {
        let now = Date(timeIntervalSince1970: TimeInterval(Self.obs + 3 * 3600))   // 3 h later
        let json = #"{"icaoId":"KTST","rawOb":"METAR KTST 231551Z AUTO 20008KT 10SM CLR 19/13 A2996","temp":19}"#
        let m = try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)), now: now)
        #expect(m.observationTime == Date(timeIntervalSince1970: TimeInterval(Self.obs)))
        #expect(m.observationTime < now.addingTimeInterval(-3 * 3600 + 1))
    }

    /// No time anywhere: the report can't be placed in time, so it isn't used (was Date(): fresh).
    @Test func noTimeAtAllIsNotUsed() throws {
        #expect(throws: (any Error).self) {
            try Self.metar(Self.full, raw: "METAR KTST AUTO 20008KT 10SM CLR 19/13 A2996", obsTime: nil)
        }
    }

    /// A report from the 31st read on the 1st belongs to the previous month.
    @Test func reportGroupMonthRollover() throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 20)))
        let t = try #require(MetarParser.reportTimeGroup(in: "METAR KTST 312351Z 20008KT", now: now))
        #expect(t == utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 51)))
        #expect(MetarParser.reportTimeGroup(in: "METAR KTST 312551Z 20008KT", now: now) == nil)   // hour 25
    }

    @Test func tafMissingIssueTimeUsesReportGroup() throws {
        let json = #"{"icaoId":"KTST","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"TAF KTST 231120Z 2312/2412 20008KT P6SM SKC","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200,"wdir":200,"wspd":8,"visib":"6+","clouds":[{"cover":"SKC"}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)),
                                      now: Date(timeIntervalSince1970: TimeInterval(Self.obs)))
        #expect(taf.issueTime == Date(timeIntervalSince1970: 1792754400))   // 2026-10-23 11:20Z
    }

    // MARK: - #9: visibility trend against "10+", unknown overall

    private static func visMetar(_ visib: String, hoursAgo: Double, clouds: String = "[]", sky: String = "CLR") throws -> Metar {
        try metar(#""temp":19,"dewp":13,"altim":1014.6,"wdir":200,"wspd":8,"visib":\#(visib),"clouds":\#(clouds),"fltCat":"VFR""#,
                  raw: "METAR KTST 231551Z 20008KT \(sky) 19/13 A2996", obsTime: obs - Int(hoursAgo * 3600))
    }

    /// Audit #9: `10+` -> `1.5 FU` read "Stable Conditions" (headline, widget, Siri). An interval
    /// ordering sees >10 -> 1.5 as a decrease.
    @Test func greaterThanTenToOneAndHalfIsDecreasing() throws {
        let newest = try Self.visMetar("1.5", hoursAgo: 0)
        let oldest = try Self.visMetar(#""10+""#, hoursAgo: 2)
        let trend = WeatherTrend.derive(metars: [newest, oldest], taf: nil)
        #expect(trend.observed.visibility == .deteriorating)
        #expect(trend.observed.overall == .deteriorating)
        #expect(trend.headline.hasPrefix("Visibility Decreasing"))
    }

    @Test func intervalsThatCantBeOrderedStayUnknownOrSteady() {
        #expect(TrendThresholds.visibilityTrend(old: .greaterThan(6), new: .exact(8)) == .steady)    // both 6+
        #expect(TrendThresholds.visibilityTrend(old: .exact(3), new: .greaterThan(6)) == .improving)
        #expect(TrendThresholds.visibilityTrend(old: .unknown, new: .exact(2)) == .unknown)
    }

    /// No visibility and no sky group in either report: unknown, never "steady"/"Stable" — even
    /// with the wind changing.
    @Test func bothAxesUnknownIsUnknownNotSteady() throws {
        let newest = try Self.metar(#""temp":19,"wdir":200,"wspd":25"#, raw: "METAR KTST 231551Z AUTO 20025KT 19/13 A2996")
        let oldest = try Self.metar(#""temp":19,"wdir":200,"wspd":8"#, raw: "METAR KTST 231351Z AUTO 20008KT 19/13 A2996",
                                    obsTime: Self.obs - 7200)
        let trend = WeatherTrend.derive(metars: [newest, oldest], taf: nil)
        #expect(trend.observed.overall == .unknown)
        #expect(trend.overall == .unknown)
        #expect(trend.headline != "Stable Conditions")
    }

    /// Forecast trend: METAR 10+ vs a TAF period forecasting 2 SM is a forecast decrease.
    @Test func forecastTrendOrdersGreaterThan() throws {
        let start = Self.obs - 1800
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":\#(start),"validTimeTo":\#(start + 86400),"rawTAF":"synthetic","fcsts":[{"timeFrom":\#(start),"timeTo":\#(start + 7200),"wdir":200,"wspd":8,"visib":"6+","clouds":[{"cover":"SKC"}]},{"timeFrom":\#(start + 7200),"timeTo":\#(start + 86400),"fcstChange":"FM","wdir":200,"wspd":8,"visib":2,"clouds":[{"cover":"SKC"}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let f = ForecastTrend.derive(metar: try Self.visMetar(#""10+""#, hoursAgo: 0), taf: taf,
                                     now: Date(timeIntervalSince1970: TimeInterval(Self.obs)))
        #expect(f.visibility == .deteriorating)
        #expect(f.overall == .deteriorating)
    }

    // MARK: - #18: one category function

    /// FAA/NWS: MVFR is ceiling 1,000-3,000 ft and visibility 3-5 SM, both INCLUSIVE.
    @Test func boundariesAreMVFRInclusive() {
        #expect(FlightCategory.forCeiling(3000) == .mvfr)
        #expect(FlightCategory.forCeiling(3100) == .vfr)
        #expect(FlightCategory.forCeiling(499) == .lifr)
        #expect(FlightCategory.forCeiling(200) == .lifr)   // Synoptic color used < 200 for LIFR
        #expect(FlightCategory.forCeiling(300) == .lifr)
        #expect(FlightCategory.forVisibility(5) == .mvfr)
        #expect(FlightCategory.forVisibility(5.5) == .vfr)
        #expect(FlightCategory.forVisibility(0.75) == .lifr)
    }

    /// Advisory (Open-Meteo) estimate: 5 SM is MVFR (was VFR); with no visibility, a lone
    /// "no ceiling" from cloud cover can't vouch for VFR.
    @Test func advisoryCategoryUsesSharedThresholds() {
        #expect(AdvisoryWeather.estimateFlightCategory(visibilityKm: 5 / 0.621371, cloudCoverPercent: 0) == .mvfr)
        #expect(AdvisoryWeather.estimateFlightCategory(visibilityKm: 16, cloudCoverPercent: 100) == .vfr)
        #expect(AdvisoryWeather.estimateFlightCategory(visibilityKm: nil, cloudCoverPercent: 60) == .mvfr)   // ~3,000 ft
        #expect(AdvisoryWeather.estimateFlightCategory(visibilityKm: nil, cloudCoverPercent: 10) == .unknown)
    }

    /// TAF period BKN030 P6SM is MVFR (the shared function, same as before for the TAF).
    @Test func tafCeilingAtThreeThousandIsMVFR() throws {
        let json = #"{"icaoId":"KTST","issueTime":"2026-10-23T11:20:00.000Z","validTimeFrom":1792756800,"validTimeTo":1792843200,"rawTAF":"synthetic","fcsts":[{"timeFrom":1792756800,"timeTo":1792843200,"wdir":200,"wspd":8,"visib":"6+","clouds":[{"cover":"BKN","base":3000}]}]}"#
        let taf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        #expect(taf.forecasts.first?.flightCategory == .mvfr)
    }

    // MARK: - D#10: symmetric "not reported" notes

    @Test func missingFieldsGetSymmetricNotes() throws {
        let m = try Self.metar(#""temp":19,"dewp":13,"altim":1014.6,"wspd":25"#,
                               raw: "METAR KTST 231551Z AUTO ///25KT 19/13 A2996")
        let texts = MetarPilotNotes.build(metar: m, history: [m]).map(\.text)
        #expect(texts.contains("Wind direction not reported — crosswind can't be computed"))
        #expect(texts.contains("Visibility not reported — no visibility group in this observation"))
        #expect(texts.contains("Ceiling not reported — no sky condition group in this observation"))
        let missing = MetarPilotNotes.build(metar: m, history: [m]).filter { $0.text.contains("not reported") }
        #expect(Set(missing.map(\.severity)) == [.caution])   // same treatment for every field
    }

    // MARK: - D#11 (F17): hazards in the history line

    @Test func hazardsListed() {
        #expect(WeatherDecoder.hazards(["+TSRA", "BR"]) == ["Heavy Thunderstorm Rain"])
        #expect(WeatherDecoder.hazards(["+FC"]) == ["Tornado/Waterspout"])
        #expect(WeatherDecoder.hazards(["SQ", "GR", "-FZRA", "FZFG", "RA"]) == ["Squall", "Hail", "Light Freezing Rain"])
    }
}
