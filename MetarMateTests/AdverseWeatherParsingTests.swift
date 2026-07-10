import Testing
import Foundation
@testable import MetarMate

// Regression coverage for MetarParser / TafParser against REAL adverse-weather observations
// pulled live from aviationweather.gov on 2026-07-09 (see docs/AUDIT_metar_taf_findings.md and
// MetarMateTests/Fixtures/adverse_*.json for the full corpus). Every raw string below is a
// verbatim NOAA observation, not hand-written.
//
// The HIGH/adverse findings (F1 OVX ceiling, F2 PROB overlays, F7 unknown-vis category, F8 missing
// wind, F9 color boundaries) are now FIXED and assert directly — the `withKnownIssue` scaffolding
// that tracked them pre-fix has been removed. Confirmations (e.g. the 4b61a4b phantom-weather fix)
// assert normally.
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
        // Negative control for the missing-wind case: a REAL 00000KT calm — wdir & wspd present as 0.
        // Must be distinguishable from kabrNoWind (isReported true, renders "Calm", not "—").
        static let calmWind = #"{"icaoId":"KFAR","obsTime":1783633980,"temp":22,"dewp":10,"wdir":0,"wspd":0,"visib":"10+","altim":1013,"rawOb":"METAR KFAR 092153Z 00000KT 10SM CLR 22/10 A2992","clouds":[],"fltCat":"VFR"}"#

        // F9 exact-boundary probes (synthetic TAF periods; FAA: 5 SM and 3000 ft are MVFR, not VFR).
        // vis exactly 5.0 SM, no ceiling -> MVFR on the vis axis.
        static let tafVis5Boundary = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic vis 5.0 boundary","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":5,"clouds":[]}]}"#
        // ceiling exactly 3000 ft (BKN030), vis unlimited -> MVFR on the ceiling axis.
        static let tafCeil3000Boundary = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic ceiling 3000 boundary","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"BKN","base":3000,"type":null}]}]}"#

        // KORD TAF excerpt: a base FM period + a PROB30 TSRA period (NOAA sends fcstChange="PROB").
        static let kordProbTaf = #"{"icaoId":"KORD","issueTime":"2026-07-09T22:15:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"TAF KORD PROB30 excerpt","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":250,"wspd":9,"visib":"6+","clouds":[{"cover":"SCT","base":3500,"type":null},{"cover":"BKN","base":12000,"type":null}]},{"timeFrom":1783641600,"timeTo":1783648800,"fcstChange":"PROB","probability":30,"visib":2,"wxString":"TSRA BR","clouds":[{"cover":"BKN","base":3500,"type":"CB"}]}]}"#

        // MARK: commit-8 fixtures

        // F3 — freezing precip. -FZRA at +1 C (temp ABOVE 0): the icing note must still fire.
        static let fzraWarm = #"{"icaoId":"KROC","obsTime":1783633980,"temp":1,"dewp":0,"wdir":90,"wspd":8,"visib":2,"altim":1005,"rawOb":"METAR KROC 092153Z 09008KT 2SM -FZRA OVC008 01/00 A2967","clouds":[{"cover":"OVC","base":800}],"wxString":"-FZRA","fltCat":"IFR"}"#
        // F3 — FZRA reported ALONGSIDE FZFG in the same ob. The icing note must fire (not be
        // suppressed by the FZFG entry); the FZFG suppression applies per-token, not to the ob.
        static let fzraWithFzfg = #"{"icaoId":"KART","obsTime":1783633980,"temp":0,"dewp":0,"wdir":100,"wspd":6,"visib":0.5,"altim":1004,"rawOb":"METAR KART 092153Z 10006KT 1/2SM FZRA FZFG OVC003 00/00 A2964","clouds":[{"cover":"OVC","base":300}],"wxString":"FZRA FZFG","fltCat":"LIFR"}"#
        // F3 — -FZRA with NO temperature field at all. Missing temp must NOT read as "not freezing"
        // (the ?? shape in a different costume) — the note fires off the FZ precip, not the temp.
        static let fzraNoTemp = #"{"icaoId":"KGTB","obsTime":1783633980,"wdir":90,"wspd":10,"visib":1,"altim":1006,"rawOb":"METAR KGTB 092153Z 09010KT 1SM -FZRA OVC006","clouds":[{"cover":"OVC","base":600}],"wxString":"-FZRA","fltCat":"IFR"}"#

        // F5 — a cumulonimbus cloud (type CB) with NO thunderstorm in wxString. Must reach .danger.
        static let cbNoThunder = #"{"icaoId":"KBOS","obsTime":1783633980,"temp":20,"dewp":15,"wdir":200,"wspd":10,"visib":"10+","altim":1013,"rawOb":"METAR KBOS 092153Z 20010KT 10SM FEW040CB 20/15 A2992","clouds":[{"cover":"FEW","base":4000,"type":"CB"}],"fltCat":"VFR"}"#

        // F1 — SYNTHETIC OVX obscuration with NO base, only a top-level vertVis (the fallback branch
        // the live corpus never hits — KDUJ/EFHK/NZDN all carry base). VV003 -> 300 ft ceiling.
        static let ovxVertVisOnly = #"{"icaoId":"KDUJ","obsTime":1783633980,"temp":5,"dewp":5,"wdir":0,"wspd":0,"visib":0.5,"vertVis":3,"altim":1015,"rawOb":"METAR KDUJ 092153Z 00000KT 1/2SM FG VV003 05/05 A2997","clouds":[{"cover":"OVX"}],"wxString":"FG","fltCat":"LIFR"}"#

        // F7 — TAF whose CURRENT (first) period specifies neither visibility nor ceiling -> .unknown.
        static let tafFirstUnknown = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic first-period unknown","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":"","clouds":[]}]}"#

        // F4 — benign (VFR) base + a non-low convective TEMPO TSRA overlay. Hero must surface the
        // TEMPO clause on the CAUTION axis (amber), never a flight-category color.
        static let tafBenignBaseTempoTS = #"{"icaoId":"KMCO","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"benign base + TEMPO TSRA","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":90,"wspd":8,"visib":"6+","clouds":[{"cover":"SCT","base":4000,"type":null}]},{"timeFrom":1783641600,"timeTo":1783645200,"fcstChange":"TEMPO","visib":"6+","wxString":"TSRA","clouds":[{"cover":"BKN","base":8000,"type":"CB"}]}]}"#
        // F4 — WORSENING base (VFR -> IFR) + a TEMPO TSRA overlay. Hero keeps the worst-base story
        // (IFR lead on the category axis) AND appends the overlay clause on the caution axis.
        static let tafWorseningBaseTempoTS = #"{"icaoId":"KMCO","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"worsening base + TEMPO TSRA","fcsts":[{"timeFrom":1783634400,"timeTo":1783641600,"wdir":90,"wspd":8,"visib":"6+","clouds":[{"cover":"SCT","base":4000,"type":null}]},{"timeFrom":1783645200,"timeTo":1783728000,"fcstChange":"FM","wdir":100,"wspd":10,"visib":2,"clouds":[{"cover":"BKN","base":800,"type":null}]},{"timeFrom":1783648800,"timeTo":1783652400,"fcstChange":"TEMPO","visib":"6+","wxString":"TSRA","clouds":[{"cover":"BKN","base":8000,"type":"CB"}]}]}"#
    }

    // MARK: - Finding 1 (HIGH): OVX / vertical-visibility obscuration dropped -> ceiling lost

    // NOAA encodes an indefinite ceiling (raw "VV002") as cover:"OVX" + a top-level vertVis field.
    // CloudCoverage has no "OVX" case, so parseClouds drops the layer and ceilingFeet is nil — the
    // app shows NO ceiling for a 200 ft LIFR fog obscuration. (RawMetar also never reads vertVis.)
    // FIXED (commit 1cd1144): OVX + top-level vertVis is now read into a .verticalVisibility layer.
    @Test func ovxObscurationYieldsIndefiniteCeiling() throws {
        let m = try metar(Obs.efhkOVX)
        #expect(m.ceilingFeet == 200)                                     // VV002 -> 200 ft indefinite ceiling
        #expect(m.clouds.contains { $0.coverage == .verticalVisibility }) // layer no longer dropped
    }

    // MARK: - Finding 6 (LOW): fractional / metric visibility fidelity — currently CORRECT

    // Confirms the brief's predicted #1 failure (Double("1/2") -> nil -> 10.0) does NOT occur:
    // NOAA delivers fractional & metric visibility already normalized to SM numbers.
    @Test func fractionalVisibilityParsesExactly() throws {
        #expect(try metar(Obs.kmssHeavyRain).visibility == .exact(1.75))   // raw "1 3/4SM"
        #expect(try metar(Obs.kpubSquall).visibility == .exact(0.75))      // raw "3/4SM"
        #expect(try metar(Obs.efhkOVX).visibility == .exact(0.19))         // raw "0300" (metric -> SM)
    }

    // MARK: - Finding 2 (HIGH): PROB30/PROB40 periods mis-typed as .base

    // NOAA sends fcstChange="PROB" (+ separate probability); ForecastType has raw values
    // "PROB30"/"PROB40", so the match fails and the period defaults to .base — a 30% TSRA/IFR
    // window is injected into the FIRM forecast timeline (hero, currentForecast, IFR-onset notes),
    // while overlayForecasts (which filters .prob30/.prob40) never sees it.
    // FIXED (commit 8d783ec): fcstChange="PROB" + probability now maps to .prob30/.prob40 overlays.
    @Test func probPeriodIsClassifiedAsOverlayNotBase() throws {
        let t = try taf(Obs.kordProbTaf)
        // The convective TSRA period is an overlay, not a firm base period.
        #expect(!t.baseForecasts.contains { $0.weatherPhenomena.contains("TSRA") })
        #expect(t.overlayForecasts.contains { $0.weatherPhenomena.contains("TSRA") })
    }

    // MARK: - Finding 3 (LOW): TAF empty-string visibility -> fail-unsafe 10.0 default

    // parseVisibility returns nil for visib:"" (correct), but calculateFlightCategory does
    // `vis ?? 10.0`, so an unknown TAF visibility silently becomes 10 SM / VFR on the vis axis.
    // FIXED (commit 8d783ec): calculateFlightCategory no longer does `vis ?? 10.0`; an unknown TAF
    // visibility with no ceiling is now .unknown, not a fabricated 10 SM VFR.
    @Test func tafUnknownVisibilityYieldsUnknownCategoryNotVFR() throws {
        // A low (IFR) ceiling still drives IFR when vis is unknown.
        let json = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic empty-vis probe","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":700,"type":null}]}]}"#
        let t = try taf(json)
        let p = try #require(t.forecasts.first)
        #expect(p.visibility == .unknown)            // parseVisibility reports unknown
        #expect(p.flightCategory == .ifr)            // 700 ft ceiling drives IFR
        // With NEITHER vis nor ceiling known, the category is .unknown (was 10 SM VFR pre-fix).
        let clear = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"synthetic","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":"","clouds":[]}]}"#
        #expect(try taf(clear).forecasts.first?.flightCategory == .unknown)
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

    // MARK: - Finding 8 (audit): missing wind group is UNKNOWN, not calm (FIXED, commit 6dc9b00)

    // Five surfaces, asserted independently — a missing wind group must be distinguishable from a
    // real 00000KT calm everywhere it is consumed, not merely flagged on the model.
    @Test @MainActor func missingWindGroupIsUnknownNotCalm() throws {
        let m = try metar(Obs.kabrNoWind)

        // (1) the parsed wind is flagged unreported — not a fabricated 00000KT.
        #expect(m.wind.isReported == false)

        // (2) the decoded wind renders "—", not "Calm". quickWeatherSummary is the public render
        // path; the view's private windText mirrors it. KABR reports vis ("10+"), so the only "—"
        // in the summary is the wind token.
        let summary = quickWeatherSummary(metar: m)
        #expect(summary.contains("—"))
        #expect(!summary.contains("Calm"))

        // (3) the "wind not reported" pilot note fires (extracted MetarPilotNotes.build).
        let notes = MetarPilotNotes.build(metar: m, history: [])
        #expect(notes.contains { $0.text.contains("Wind not reported") && $0.severity == .caution })

        // (4) AlertConditions carries nil windSpeed — the input that skips the wind criteria.
        #expect(AlertConditions(from: m).windSpeed == nil)

        // (5) GoNoGo: with nil windSpeed, strict wind limits are INERT — identical verdict and
        // failingFactors to a profile with no wind limits at all (i.e. the wind factors were not
        // evaluated). Observable through existing surfaces. NB: a skipped factor and a passing
        // 0-kt factor remain indistinguishable via Verdict — see audit Finding 13 (open).
        let c = AlertConditions(from: m)
        let strict = MinimumsProfile(name: "strict", maxGustKt: 1, maxSustainedWindKt: 1)
        let noWindLimits = MinimumsProfile(name: "noWindLimits")
        let v1 = GoNoGoEvaluator.evaluate(strict, c, previousSide: nil, icao: "KABR")
        let v2 = GoNoGoEvaluator.evaluate(noWindLimits, c, previousSide: nil, icao: "KABR")
        #expect(v1.shouldFire == v2.shouldFire)
        #expect(v1.failingFactors == v2.failingFactors)
        #expect(!v1.failingFactors.contains { $0.lowercased().contains("wind") || $0.lowercased().contains("gust") })
    }

    // Negative control: a REAL 00000KT calm is reported (isReported true) and still renders "Calm".
    // The whole point of Finding 8 is that these two states are distinguishable.
    @Test func realCalmIsReportedAndRendersCalm() throws {
        let m = try metar(Obs.calmWind)
        #expect(m.wind.isReported == true)
        #expect(m.wind.speed == 0)
        let summary = quickWeatherSummary(metar: m)
        #expect(summary.contains("Calm"))
        #expect(!summary.contains("—"))   // vis is reported ("10+"), so no "—" from any field
    }

    // MARK: - WeatherDecoder battery (audit item #5 / Finding 10)

    // WeatherDecoder decodes every real adverse code correctly. Spot-check the convective/frozen-
    // precip codes that would matter at adverse stations.
    @Test func weatherDecoderHandlesAdverseCodes() {
        #expect(WeatherDecoder.decode("+TSRA") == "Heavy Thunderstorm Rain")
        #expect(WeatherDecoder.decode("FZRA") == "Freezing Rain")
        #expect(WeatherDecoder.decode("-FZRA") == "Light Freezing Rain")
        #expect(WeatherDecoder.decode("BLSN") == "Blowing Snow")
        #expect(WeatherDecoder.decode("VCTS") == "Thunderstorm in Vicinity")
        #expect(WeatherDecoder.decode("SQ") == "Squall")
        #expect(WeatherDecoder.decode("+FC") == "Tornado/Waterspout")
    }

    // MARK: - Finding 9 (audit): category color boundaries match calculateFlightCategory (FIXED)

    // The color functions (ColorRules) and the category function (TafParser.calculateFlightCategory,
    // private — exercised via the public parse path) must AGREE at the FAA MVFR boundary: 5 SM and
    // 3000 ft are MVFR, not VFR. Pre-fix the colors used `< 5` / `< 3000` and read VFR-green there.
    @Test func categoryColorsAgreeWithFlightCategoryAtBoundary() throws {
        // Visibility axis: exactly 5.0 SM.
        #expect(ColorRules.visibilityColor(5.0) == Brand.mvfrBlue)   // MVFR-blue…
        #expect(ColorRules.visibilityColor(5.0) != Brand.vfrGreen)   // …not VFR-green (the old bug)
        #expect(try taf(Obs.tafVis5Boundary).forecasts.first?.flightCategory == .mvfr)

        // Ceiling axis: exactly 3000 ft.
        #expect(ColorRules.ceilingColor(3000) == Brand.mvfrBlue)
        #expect(ColorRules.ceilingColor(3000) != Brand.vfrGreen)
        #expect(try taf(Obs.tafCeil3000Boundary).forecasts.first?.flightCategory == .mvfr)
    }

    // MARK: - Finding 3 (audit): freezing-precip icing note fires regardless of temp (FIXED)

    // Asserts the icing note FIRES (existence), NOT its severity — the red-vs-amber tier is a CFII
    // call (deferred #1); asserting .severity here would quietly ratify an unmade decision.
    @Test func freezingPrecipIcingNoteFiresRegardlessOfTemp() throws {
        func fires(_ json: String) throws -> Bool {
            try MetarPilotNotes.build(metar: metar(json), history: [])
                .contains { $0.text.contains("Freezing precipitation") }
        }
        #expect(try fires(Obs.fzraWarm))      // -FZRA at +1 C — not suppressed above 0
        #expect(try fires(Obs.fzraWithFzfg))  // FZRA alongside FZFG — not suppressed by the FZFG token
        #expect(try fires(Obs.fzraNoTemp))    // -FZRA with no temp field — missing temp ≠ "not freezing"
    }

    // MARK: - Finding 5 (audit): TS/CB reach the red (.danger) tier on the METAR side (FIXED)

    // TS/CB were routed to .danger in commit 627a2a8 — a landed decision. Deliberately does NOT
    // assert SQ (deferred #2) or +FC (deferred #3) severity; those escalations are unmade (CFII).
    @Test func thunderstormAndCumulonimbusReachDangerTier() throws {
        let tsNotes = try MetarPilotNotes.build(metar: metar(Obs.ktpaThunder), history: [])
        #expect(tsNotes.contains { $0.text.contains("Thunderstorm") && $0.severity == .danger })
        let cbNotes = try MetarPilotNotes.build(metar: metar(Obs.cbNoThunder), history: [])
        #expect(cbNotes.contains { $0.text.contains("Cumulonimbus") && $0.severity == .danger })
    }

    // MARK: - Finding 1 (audit): OVX obscuration with only vertVis (no base) — synthetic (FIXED)

    // The live corpus always carried a `base`; this exercises the fallback branch where the OVX
    // layer has no base and the ceiling must come from the top-level vertVis field.
    @Test func ovxVertVisOnlyYieldsCeilingFromVertVis() throws {
        let m = try metar(Obs.ovxVertVisOnly)
        #expect(m.ceilingFeet == 300)                                     // VV003 via vertVis, no base
        #expect(m.clouds.contains { $0.coverage == .verticalVisibility })
    }

    // MARK: - Finding 7 (audit): hero short-circuits when the current period is undetermined (FIXED)

    @Test func heroShortCircuitsOnUnknownCurrentPeriod() throws {
        let segs = TafHeroBrief.build(try taf(Obs.tafFirstUnknown))
        #expect(segs.count == 1)                                          // short-circuit — one segment
        #expect(segs.first?.text.contains("Forecast incomplete") == true)
        #expect(segs.first?.color == Brand.slate)                         // neutral, not a category color
    }

    // MARK: - Finding 4 (audit): hero surfaces significant TEMPO/PROB overlays (FIXED)

    // The overlay hazard must appear in the hero AND on the CAUTION axis (amber / valueRed-when-low),
    // never tinted with a flight-category color. Asserts the color on the segment carrying the clause
    // (per design: the category axis and the caution axis must never be collapsed).
    @Test func heroSurfacesTempoOverlayOnCautionAxis() throws {
        // Benign (VFR) base: "VFR now, but TEMPO … " — TEMPO clause on the caution axis.
        let benign = TafHeroBrief.build(try taf(Obs.tafBenignBaseTempoTS))
        let benignTempo = try #require(benign.first { $0.text.contains("TEMPO") })
        #expect(benignTempo.color == Brand.cautionOrange)   // amber caution axis…
        #expect(benignTempo.color != Brand.vfrGreen)        // …not the VFR category color
        #expect(benignTempo.color != Brand.mvfrBlue)
        #expect(benign.contains { $0.text.contains("now,") })   // the base contrast is preserved

        // Worsening base (VFR -> IFR): worst-base IFR lead (category axis) + overlay (caution axis).
        let worsening = TafHeroBrief.build(try taf(Obs.tafWorseningBaseTempoTS))
        #expect(worsening.contains { $0.text.contains("IFR by") && $0.color == Brand.valueRed })
        let worseTempo = try #require(worsening.first { $0.text.contains("TEMPO") })
        #expect(worseTempo.color == Brand.cautionOrange)
    }

    // MARK: - Finding 10 (audit): WeatherDecoder dict-audit — every key decodes

    // Walk EVERY key in the exact-match table; each must decode to a non-empty, non-passthrough
    // description. Per the audit method: if a key has no real decode path this FAILS and reports
    // it — we do NOT paper over it by adding a decode here.
    @Test func weatherDecoderDictAuditEveryKeyDecodes() {
        var offenders: [String] = []
        var walked = 0
        for (key, _) in WeatherDecoder.descriptions {
            walked += 1
            let decoded = WeatherDecoder.decode(key)
            if decoded.isEmpty || decoded == key { offenders.append(key) }
        }
        // Prove EVERY key was walked (not a subset): iterated count must equal the dict size.
        #expect(walked == WeatherDecoder.descriptions.count, "walked \(walked) of \(WeatherDecoder.descriptions.count) keys")
        #expect(offenders.isEmpty, "codes with empty/passthrough decode: \(offenders.sorted())")
    }
}
