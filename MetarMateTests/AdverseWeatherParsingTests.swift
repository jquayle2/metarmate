import Testing
import Foundation
@testable import MetarMate

// Regression coverage for MetarParser / TafParser against REAL adverse-weather observations
// pulled live from aviationweather.gov on 2026-07-09 (see docs/AUDIT_metar_taf_findings.md and
// MetarMateTests/Fixtures/adverse_*.json for the full corpus). Every raw string below is a
// verbatim NOAA observation, not hand-written.
//
// Findings that reflect CURRENT BUGS are wrapped in `withKnownIssue` so this suite stays green
// until Jeff triages them; each will flip to a hard failure the moment the fix lands (delete the
// wrapper then). Findings that are already CORRECT (e.g. the 4b61a4b phantom-weather fix) assert
// normally.
struct AdverseWeatherParsingTests {

    // MARK: - decode helpers (exercise the exact app decode + parse path)

    private func metar(_ json: String) throws -> Metar {
        let raw = try JSONDecoder().decode(RawMetar.self, from: Data(json.utf8))
        return try MetarParser.parse(raw: raw)
    }
    private func taf(_ json: String) throws -> Taf {
        let raw = try JSONDecoder().decode(RawTaf.self, from: Data(json.utf8))
        return try TafParser.parse(raw: raw)
    }

    // Real observations (verbatim NOAA JSON, trimmed to parse-relevant fields).
    private enum Obs {
        // EFHK 2220Z: FG VV002, 300 m vis (LIFR). Indefinite 200 ft ceiling encoded as OVX + vertVis.
        static let efhkOVX = #"{"icaoId":"EFHK","obsTime":1783635600,"temp":14,"dewp":14,"wdir":360,"wspd":3,"visib":0.19,"altim":1012,"rawOb":"METAR EFHK 092220Z 36003KT 330V030 0300 FG VV002 14/14 Q1012","clouds":[{"cover":"OVX","base":200}],"wxString":"FG","fltCat":"LIFR"}"#
        // KMSS 2141Z: 1 3/4SM +RA BR (IFR). Fractional visibility fidelity.
        static let kmssHeavyRain = #"{"icaoId":"KMSS","obsTime":1783633260,"temp":20.6,"dewp":20.6,"wdir":70,"wspd":4,"visib":1.75,"altim":1008.5,"rawOb":"SPECI KMSS 092141Z AUTO 07004KT 1 3/4SM +RA BR FEW004 BKN034 OVC080 21/21 A2978","clouds":[{"cover":"FEW","base":400},{"cover":"BKN","base":3400},{"cover":"OVC","base":8000}],"wxString":"+RA BR","fltCat":"IFR"}"#
        // KPUB 2153Z: 3/4SM +TSRA SQ, 31021G58KT (LIFR). Squall + tornado-adjacent gusts.
        static let kpubSquall = #"{"icaoId":"KPUB","obsTime":1783633980,"temp":21.1,"dewp":12.2,"wdir":310,"wspd":21,"wgst":58,"visib":0.75,"altim":1016.7,"rawOb":"METAR KPUB 092153Z 31021G58KT 3/4SM +TSRA SQ FEW028 BKN100 21/12 A3002","clouds":[{"cover":"FEW","base":2800},{"cover":"BKN","base":10000}],"wxString":"+TSRA SQ","fltCat":"LIFR"}"#
        // KTPA 2153Z: TS at VFR (thunderstorm does not change flight category).
        static let ktpaThunder = #"{"icaoId":"KTPA","obsTime":1783633980,"temp":35,"dewp":23.3,"wdir":270,"wspd":8,"wgst":17,"visib":"10+","altim":1018,"rawOb":"METAR KTPA 092153Z 27008G17KT 10SM TS FEW060CB FEW250 35/23 A3006","clouds":[{"cover":"FEW","base":6000},{"cover":"FEW","base":25000}],"wxString":"TS","fltCat":"VFR"}"#
        // Substring-collision idents with EMPTY wxString — must NOT fabricate phenomena (4b61a4b).
        static let ksnaClear = #"{"icaoId":"KSNA","obsTime":1783633980,"temp":22.8,"dewp":16.7,"wdir":200,"wspd":12,"visib":"10+","altim":1011.6,"rawOb":"METAR KSNA 092153Z 20012KT 10SM FEW011 23/17 A2987","clouds":[{"cover":"FEW","base":1100}],"fltCat":"VFR"}"#
        static let kictClear = #"{"icaoId":"KICT","obsTime":1783633980,"temp":35,"dewp":21.7,"wdir":350,"wspd":6,"visib":"10+","altim":1010.2,"rawOb":"METAR KICT 092153Z 35006KT 10SM FEW120 FEW200 35/22 A2983","clouds":[{"cover":"FEW","base":12000},{"cover":"FEW","base":20000}],"fltCat":"VFR"}"#
        // KABR 2153Z: no wind group at all (wdir & wspd absent).
        static let kabrNoWind = #"{"icaoId":"KABR","obsTime":1783633980,"temp":27.2,"dewp":18.9,"visib":"10+","altim":1011.9,"rawOb":"METAR KABR 092153Z AUTO 10SM CLR 27/19 A2988","clouds":[],"fltCat":"VFR"}"#

        // KORD TAF excerpt: a base FM period + a PROB30 TSRA period (NOAA sends fcstChange="PROB").
        static let kordProbTaf = #"{"icaoId":"KORD","issueTime":"2026-07-09T22:15:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"TAF KORD PROB30 excerpt","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":250,"wspd":9,"visib":"6+","clouds":[{"cover":"SCT","base":3500,"type":null},{"cover":"BKN","base":12000,"type":null}]},{"timeFrom":1783641600,"timeTo":1783648800,"fcstChange":"PROB","probability":30,"visib":2,"wxString":"TSRA BR","clouds":[{"cover":"BKN","base":3500,"type":"CB"}]}]}"#
    }

    // MARK: - Finding 1 (HIGH): OVX / vertical-visibility obscuration dropped -> ceiling lost

    // NOAA encodes an indefinite ceiling (raw "VV002") as cover:"OVX" + a top-level vertVis field.
    // CloudCoverage has no "OVX" case, so parseClouds drops the layer and ceilingFeet is nil — the
    // app shows NO ceiling for a 200 ft LIFR fog obscuration. (RawMetar also never reads vertVis.)
    @Test func ovxObscurationYieldsIndefiniteCeiling() throws {
        let m = try metar(Obs.efhkOVX)
        withKnownIssue("Finding 1: OVX/VV obscuration dropped — VV002 should give a ~200 ft ceiling, got nil") {
            #expect(m.ceilingFeet == 200)
            #expect(m.clouds.contains { $0.coverage == .verticalVisibility })
        }
    }

    // MARK: - Finding 6 (LOW): fractional / metric visibility fidelity — currently CORRECT

    // Confirms the brief's predicted #1 failure (Double("1/2") -> nil -> 10.0) does NOT occur:
    // NOAA delivers fractional & metric visibility already normalized to SM numbers.
    @Test func fractionalVisibilityParsesExactly() throws {
        #expect(try metar(Obs.kmssHeavyRain).visibility == 1.75)   // raw "1 3/4SM"
        let kpubVis = try metar(Obs.kpubSquall).visibility
        #expect(kpubVis == 0.75)                                   // raw "3/4SM"
        let efhkVis = try metar(Obs.efhkOVX).visibility
        #expect(efhkVis == 0.19)                                   // raw "0300" (metric -> SM)
    }

    // MARK: - Finding 2 (HIGH): PROB30/PROB40 periods mis-typed as .base

    // NOAA sends fcstChange="PROB" (+ separate probability); ForecastType has raw values
    // "PROB30"/"PROB40", so the match fails and the period defaults to .base — a 30% TSRA/IFR
    // window is injected into the FIRM forecast timeline (hero, currentForecast, IFR-onset notes),
    // while overlayForecasts (which filters .prob30/.prob40) never sees it.
    @Test func probPeriodIsClassifiedAsOverlayNotBase() throws {
        let t = try taf(Obs.kordProbTaf)
        // The convective TSRA period should be an overlay, not a firm base period.
        let probIsBase = t.baseForecasts.contains { $0.weatherPhenomena.contains("TSRA") }
        withKnownIssue("Finding 2: PROB period mis-typed as .base — appears in baseForecasts") {
            #expect(!probIsBase)
            #expect(t.overlayForecasts.contains { $0.weatherPhenomena.contains("TSRA") })
        }
    }

    // MARK: - Finding 3 (LOW): TAF empty-string visibility -> fail-unsafe 10.0 default

    // parseVisibility returns nil for visib:"" (correct), but calculateFlightCategory does
    // `vis ?? 10.0`, so an unknown TAF visibility silently becomes 10 SM / VFR on the vis axis.
    @Test func tafUnknownVisibilityDefaultsToTenSMExposingFailUnsafe() throws {
        // Construct a period with unknown vis and a low (IFR) ceiling to show the default's reach.
        let json = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic empty-vis probe","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":700,"type":null}]}]}"#
        let t = try taf(json)
        let p = try #require(t.forecasts.first)
        #expect(p.visibility == nil)                 // parseVisibility correctly reports unknown
        #expect(p.flightCategory == .ifr)            // here the 700 ft ceiling drives IFR anyway
        // But with NO ceiling either, unknown vis alone lands on VFR — the fail-unsafe default:
        let clear = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":"","clouds":[]}]}"#
        let clearCat = try taf(clear).forecasts.first?.flightCategory
        withKnownIssue("Finding 3: unknown TAF visibility defaults to 10 SM -> VFR instead of surfacing unknown") {
            #expect(clearCat == .unknown)
        }
    }

    // MARK: - Finding 4 (MEDIUM): phantom-weather fix holds on live data (CONFIRMATION)

    // The 4b61a4b strict-grammar fix: substring-collision idents with empty wxString must produce
    // zero phenomena (KSNA no longer -> "Snow", KICT no longer -> "Ice Crystals").
    @Test func collisionIdentsProduceNoPhantomWeather() throws {
        #expect(try metar(Obs.ksnaClear).weatherPhenomena.isEmpty)
        #expect(try metar(Obs.kictClear).weatherPhenomena.isEmpty)
    }

    // Real present weather is still parsed when actually present.
    @Test func realPresentWeatherStillParsed() throws {
        #expect(try metar(Obs.kpubSquall).weatherPhenomena == ["+TSRA", "SQ"])
        #expect(try metar(Obs.ktpaThunder).weatherPhenomena == ["TS"])
    }

    // MARK: - Finding 7 (LOW): missing wind group rendered as calm

    // A METAR with no wind group parses to direction 0 / speed 0 — indistinguishable from real calm.
    @Test func missingWindGroupRendersAsCalm() throws {
        let m = try metar(Obs.kabrNoWind)
        // Documents current behavior; the safer outcome is an explicit "unknown wind" signal.
        #expect(m.wind.speed == 0)
        #expect(m.wind.isVariable == false)
        withKnownIssue("Finding 7: missing wind group looks identical to calm (dir 0, spd 0)") {
            #expect(m.wind.direction == nil)   // preferred: nil direction to signal "unknown"
        }
    }

    // MARK: - Finding 8 (LOW): flight-category boundary alignment

    // WeatherDecoder decodes every real adverse code correctly (item #5 battery). Spot-check the
    // convective/frozen-precip codes that would matter at adverse stations.
    @Test func weatherDecoderHandlesAdverseCodes() {
        #expect(WeatherDecoder.decode("+TSRA") == "Heavy Thunderstorm Rain")
        #expect(WeatherDecoder.decode("FZRA") == "Freezing Rain")
        #expect(WeatherDecoder.decode("-FZRA") == "Light Freezing Rain")
        #expect(WeatherDecoder.decode("BLSN") == "Blowing Snow")
        #expect(WeatherDecoder.decode("VCTS") == "Thunderstorm in Vicinity")
        #expect(WeatherDecoder.decode("SQ") == "Squall")
        #expect(WeatherDecoder.decode("+FC") == "Tornado/Waterspout")
    }
}
