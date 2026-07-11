import Foundation

// MARK: - Canned adverse-weather fixtures (A1–A13, T1–T4)
//
// The corpus from docs/PRE_MERGE_TEST_PLAN.md, authored as STRUCTURED NOAA JSON — because the real
// parser reads NOAA's decoded fields (visib/wdir/clouds/wxString/fltCat/fcsts), NOT the raw string.
// Each fixture is decoded + parsed through SimulatedDecode (the same seam as the live fetch) so a
// parse failure surfaces honestly; there are NO `?? <number>` fallbacks anywhere in this file.
//
// Each fixture injects a 3-OBSERVATION history (newest first; obsTime now / −60 min / −120 min) so
// the trend engine — which needs ≥2 obs — produces a real OBSERVED summary instead of "Unknown".
// The `minAgo:0` observation is the CURRENT one under test; its structured fields match the audited
// case exactly, so nothing about the current render changes. The two priors trend INTO the current
// condition (adverse cases deteriorate: visibility dropping, ceiling lowering, winds building; benign
// VFR cases stay steady). Altimeter is held constant across a fixture's obs to avoid a spurious
// pressure-trend note.
//
// NOTE (expected, not a bug): a greater-than visibility (P6SM/P10SM → .greaterThan) has no ordered
// trend — it's excluded from the visibility-trend axis (which then reads "Unknown") rather than
// fabricating a comparable number. That's the Finding-15 discipline; the OBSERVED *summary* still
// populates. So A1/A3/A7/A8/A13 showing trend vis=Unknown is correct — do not "fix" it.
//
// METAR category (`fltCat`) is a PASSTHROUGH — MetarParser reads it verbatim and never computes it.
// So A1–A12's `fltCat` is set to NOAA's real value for that ob (flagged per-row in the plan). TAF
// category IS computed by TafParser.calculateFlightCategory, so T1–T4 OMIT any category hint and let
// the ceiling/visibility drive it — that is the thing under test (esp. T4).
//
// T1–T4 are TAF cases, but the production detail view only renders the TAF section when a METAR is
// present (`if let metar = vm.metar`). Rather than change that production gating, each TAF is paired
// with a scaffolding METAR history (same ident) so the screen renders. The scaffold's CURRENT category
// is MATCHED to the TAF's FIRST period (a real station's METAR ≈ its TAF's current period) so the
// screen doesn't LEAD with a chip that contradicts the case under test. Scaffolds carry NO weather
// phenomena — their category comes from vis/ceiling only, so nothing bleeds into the TAF case. The
// scaffold is not the thing under test; TAF-sourcing is proven structurally in
// SimulatedBannerSnapshotTests.

struct InjectionFixture: Identifiable {
    let id: String            // "A1"
    let title: String         // "A1 · P6SM string"
    let subtitle: String      // "expect '6+ SM' (never '6 SM')"
    let airport: Airport
    let make: () throws -> SimulatedInjection
}

enum MetarInjectionFixtures {

    // Shared synthetic airport. Elevation matters only for A13 (density-altitude marker), so that one
    // gets its own high-elevation field; the rest share a modest elevation. Read-only value type —
    // constructing it never touches the bundled DB or SwiftData.
    private static func airport(_ icao: String, elevation: Int = 433, name: String) -> Airport {
        Airport(icao: icao, iata: nil, name: name,
                latitude: 39.0, longitude: -104.6, elevation: elevation, hasMetar: true)
    }

    // Epoch (seconds) offset from now — hours for TAF period times, minutes (via ob) for obs history.
    private static func epoch(_ hoursFromNow: Double) -> Int {
        Int(Date().addingTimeInterval(hoursFromNow * 3600).timeIntervalSince1970)
    }

    /// One observation JSON for a fixture's history. `wind` is a JSON fragment
    /// (`#""wdir":250,"wspd":8"#`, or `""` for a missing wind group). `visib` is the JSON value
    /// verbatim (`"0.5"` or `#""P6SM""#`). `clouds` is the JSON array verbatim. `wx`/`altim`/`vertVis`
    /// are omitted when nil. `minAgo` sets obsTime relative to now (0 = the current obs under test).
    private static func ob(_ icao: String, minAgo: Double, wind: String, visib: String, clouds: String,
                           temp: Int, dewp: Int, altim: Int?, fltCat: String,
                           wx: String? = nil, vertVis: Int? = nil, raw: String) -> String {
        var p: [String] = ["\"icaoId\":\"\(icao)\"", "\"obsTime\":\(epoch(-minAgo / 60))"]
        if !wind.isEmpty { p.append(wind) }
        p.append("\"visib\":\(visib)")
        p.append("\"temp\":\(temp)")
        p.append("\"dewp\":\(dewp)")
        if let altim { p.append("\"altim\":\(altim)") }
        if let vertVis { p.append("\"vertVis\":\(vertVis)") }
        if let wx { p.append("\"wxString\":\"\(wx)\"") }
        p.append("\"clouds\":\(clouds)")
        p.append("\"fltCat\":\"\(fltCat)\"")
        p.append("\"rawOb\":\"\(raw)\"")
        return "{" + p.joined(separator: ",") + "}"
    }

    private static func metarSeries(_ obs: [String]) throws -> SimulatedInjection {
        SimulatedInjection(metars: try SimulatedDecode.parseMetars(json: "[" + obs.joined(separator: ",") + "]"),
                           taf: nil)
    }

    private static func tafInjection(scaffold: [String], tafJSON: String) throws -> SimulatedInjection {
        SimulatedInjection(metars: try SimulatedDecode.parseMetars(json: "[" + scaffold.joined(separator: ",") + "]"),
                           taf: try SimulatedDecode.parseTaf(json: tafJSON))
    }

    // MARK: - The corpus

    static var all: [InjectionFixture] { metars + tafs }

    static var metars: [InjectionFixture] {
        [
            InjectionFixture(
                id: "A1", title: "A1 · P6SM (string)",
                subtitle: "visibility → “6+ SM” (never “6 SM”). fltCat VFR passthrough.",
                airport: airport("KA01", name: "A1 P6SM string (SIM)"),
                make: { try metarSeries([
                    ob("KA01", minAgo: 0,   wind: #""wdir":250,"wspd":8"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":5000}]"#, temp: 20, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA01 25008KT P6SM FEW050 20/10 A2992"),
                    ob("KA01", minAgo: 60,  wind: #""wdir":250,"wspd":8"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":5000}]"#, temp: 20, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA01 25008KT P6SM FEW050 20/10 A2992"),
                    ob("KA01", minAgo: 120, wind: #""wdir":240,"wspd":7"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4800}]"#, temp: 19, dewp:  9, altim: 1013, fltCat: "VFR", raw: "METAR KA01 24007KT P6SM FEW048 19/09 A2992"),
                ]) }
            ),
            InjectionFixture(
                id: "A2", title: "A2 · 6 (number)",
                subtitle: "visibility → “6 SM” (never “6+ SM”). Must differ from A1.",
                airport: airport("KA02", name: "A2 six exact (SIM)"),
                make: { try metarSeries([
                    ob("KA02", minAgo: 0,   wind: #""wdir":250,"wspd":8"#, visib: "6", clouds: #"[{"cover":"FEW","base":5000}]"#, temp: 20, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA02 25008KT 6SM FEW050 20/10 A2992"),
                    ob("KA02", minAgo: 60,  wind: #""wdir":250,"wspd":8"#, visib: "6", clouds: #"[{"cover":"FEW","base":5000}]"#, temp: 20, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA02 25008KT 6SM FEW050 20/10 A2992"),
                    ob("KA02", minAgo: 120, wind: #""wdir":240,"wspd":7"#, visib: "6", clouds: #"[{"cover":"FEW","base":4800}]"#, temp: 19, dewp:  9, altim: 1013, fltCat: "VFR", raw: "METAR KA02 24007KT 6SM FEW048 19/09 A2992"),
                ]) }
            ),
            InjectionFixture(
                id: "A3", title: "A3 · P10SM (string)",
                subtitle: "visibility → “10+ SM”. fltCat VFR passthrough.",
                airport: airport("KA03", name: "A3 P10SM string (SIM)"),
                make: { try metarSeries([
                    ob("KA03", minAgo: 0,   wind: #""wdir":250,"wspd":8"#, visib: #""P10SM""#, clouds: #"[{"cover":"FEW","base":5000}]"#, temp: 20, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA03 25008KT 10SM FEW050 20/10 A2992"),
                    ob("KA03", minAgo: 60,  wind: #""wdir":250,"wspd":8"#, visib: #""P10SM""#, clouds: #"[{"cover":"FEW","base":5000}]"#, temp: 20, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA03 25008KT 10SM FEW050 20/10 A2992"),
                    ob("KA03", minAgo: 120, wind: #""wdir":240,"wspd":7"#, visib: #""P10SM""#, clouds: #"[{"cover":"FEW","base":4800}]"#, temp: 19, dewp:  9, altim: 1013, fltCat: "VFR", raw: "METAR KA03 24007KT 10SM FEW048 19/09 A2992"),
                ]) }
            ),
            InjectionFixture(
                id: "A4", title: "A4 · LIFR fog (OVX/VV002)",
                subtitle: "vis 0.5 SM, ceiling ~200 ft, LIFR → magenta. Category passthrough. (Trend: fog closing in.)",
                airport: airport("KA04", name: "A4 LIFR fog (SIM)"),
                make: { try metarSeries([
                    ob("KA04", minAgo: 0,   wind: #""wdir":360,"wspd":3"#, visib: "0.5", clouds: #"[{"cover":"OVX","base":200}]"#, temp: 14, dewp: 14, altim: 1012, fltCat: "LIFR", wx: "FG", raw: "METAR KA04 36003KT 1/2SM FG VV002 14/14 A2989"),
                    ob("KA04", minAgo: 60,  wind: #""wdir":350,"wspd":4"#, visib: "1",   clouds: #"[{"cover":"OVC","base":500}]"#, temp: 14, dewp: 13, altim: 1012, fltCat: "IFR",  wx: "BR", raw: "METAR KA04 35004KT 1SM BR OVC005 14/13 A2989"),
                    ob("KA04", minAgo: 120, wind: #""wdir":340,"wspd":5"#, visib: "3",   clouds: #"[{"cover":"BKN","base":1200}]"#, temp: 15, dewp: 12, altim: 1012, fltCat: "MVFR", raw: "METAR KA04 34005KT 3SM BKN012 15/12 A2989"),
                ]) }
            ),
            InjectionFixture(
                id: "A5", title: "A5 · IFR mist (OVC007)",
                subtitle: "vis 2 SM, ceiling 700 ft, IFR → red. Category passthrough. (Trend: lowering.)",
                airport: airport("KA05", name: "A5 IFR mist (SIM)"),
                // Ceiling is 700 ft (IFR), NOT 400 ft: a 400 ft ceiling is LIFR (<500), which would
                // disagree with the passthrough fltCat "IFR" and the computed pilot note. 700 ft makes
                // A5 a clean IFR on BOTH axes (vis 2 SM + ceiling 700 ft) — the tier between A4 (LIFR).
                make: { try metarSeries([
                    ob("KA05", minAgo: 0,   wind: #""wdir":90,"wspd":6"#,  visib: "2", clouds: #"[{"cover":"OVC","base":700}]"#,  temp: 18, dewp: 17, altim: 1010, fltCat: "IFR",  wx: "BR", raw: "METAR KA05 09006KT 2SM BR OVC007 18/17 A2983"),
                    ob("KA05", minAgo: 60,  wind: #""wdir":90,"wspd":7"#,  visib: "4", clouds: #"[{"cover":"OVC","base":1500}]"#, temp: 18, dewp: 16, altim: 1010, fltCat: "MVFR", wx: "BR", raw: "METAR KA05 09007KT 4SM BR OVC015 18/16 A2983"),
                    ob("KA05", minAgo: 120, wind: #""wdir":100,"wspd":8"#, visib: "6", clouds: #"[{"cover":"BKN","base":3000}]"#, temp: 19, dewp: 15, altim: 1010, fltCat: "MVFR", raw: "METAR KA05 10008KT 6SM BKN030 19/15 A2983"),
                ]) }
            ),
            InjectionFixture(
                id: "A6", title: "A6 · OVX vertVis-only (VV001)",
                subtitle: "ceiling ~100 ft derived from vertVis (NOT dropped/blank). (Trend: fog closing in.)",
                airport: airport("KA06", name: "A6 vertVis ceiling (SIM)"),
                make: { try metarSeries([
                    ob("KA06", minAgo: 0,   wind: #""wdir":0,"wspd":0"#,  visib: "0.25", clouds: #"[{"cover":"OVX"}]"#,          temp: 5, dewp: 5, altim: 1015, fltCat: "LIFR", wx: "FG", vertVis: 1, raw: "METAR KA06 00000KT 1/4SM FG VV001 05/05 A2997"),
                    ob("KA06", minAgo: 60,  wind: #""wdir":0,"wspd":0"#,  visib: "0.5",  clouds: #"[{"cover":"OVC","base":300}]"#, temp: 5, dewp: 5, altim: 1015, fltCat: "LIFR", wx: "FG", raw: "METAR KA06 00000KT 1/2SM FG OVC003 05/05 A2997"),
                    ob("KA06", minAgo: 120, wind: #""wdir":350,"wspd":3"#, visib: "2",    clouds: #"[{"cover":"OVC","base":800}]"#, temp: 6, dewp: 4, altim: 1015, fltCat: "IFR",  wx: "BR", raw: "METAR KA06 35003KT 2SM BR OVC008 06/04 A2997"),
                ]) }
            ),
            InjectionFixture(
                id: "A7", title: "A7 · missing wind group",
                subtitle: "wind → “—” + “Wind not reported” note. NOT “Calm”. (Wind absent across history.)",
                airport: airport("KA07", name: "A7 no wind (SIM)"),
                make: { try metarSeries([
                    ob("KA07", minAgo: 0,   wind: "", visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4000}]"#, temp: 25, dewp: 15, altim: 1013, fltCat: "VFR", raw: "METAR KA07 AUTO P6SM FEW040 25/15 A2992"),
                    ob("KA07", minAgo: 60,  wind: "", visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4000}]"#, temp: 25, dewp: 15, altim: 1013, fltCat: "VFR", raw: "METAR KA07 AUTO P6SM FEW040 25/15 A2992"),
                    ob("KA07", minAgo: 120, wind: "", visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4200}]"#, temp: 24, dewp: 15, altim: 1013, fltCat: "VFR", raw: "METAR KA07 AUTO P6SM FEW042 24/15 A2992"),
                ]) }
            ),
            InjectionFixture(
                id: "A8", title: "A8 · genuine calm (00000KT)",
                subtitle: "wind → “Calm”, reported. Must differ from A7.",
                airport: airport("KA08", name: "A8 calm (SIM)"),
                make: { try metarSeries([
                    ob("KA08", minAgo: 0,   wind: #""wdir":0,"wspd":0"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4000}]"#, temp: 22, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA08 00000KT P6SM FEW040 22/10 A2992"),
                    ob("KA08", minAgo: 60,  wind: #""wdir":0,"wspd":0"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4000}]"#, temp: 22, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA08 00000KT P6SM FEW040 22/10 A2992"),
                    ob("KA08", minAgo: 120, wind: #""wdir":0,"wspd":0"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":4200}]"#, temp: 21, dewp: 10, altim: 1013, fltCat: "VFR", raw: "METAR KA08 00000KT P6SM FEW042 21/10 A2992"),
                ]) }
            ),
            InjectionFixture(
                id: "A9", title: "A9 · TSRA + CB, gust 25",
                subtitle: "present-wx chip RED (TS); gust caution amber. (Trend: storm building.)",
                airport: airport("KA09", name: "A9 thunderstorm (SIM)"),
                make: { try metarSeries([
                    ob("KA09", minAgo: 0,   wind: #""wdir":180,"wspd":15,"wgst":25"#, visib: "4", clouds: #"[{"cover":"BKN","base":2500,"type":"CB"}]"#, temp: 24, dewp: 20, altim: 1008, fltCat: "MVFR", wx: "TSRA", raw: "METAR KA09 18015G25KT 4SM TSRA BKN025CB 24/20 A2977"),
                    ob("KA09", minAgo: 60,  wind: #""wdir":170,"wspd":12,"wgst":18"#, visib: "6", clouds: #"[{"cover":"SCT","base":4500}]"#,              temp: 25, dewp: 20, altim: 1008, fltCat: "VFR",  raw: "METAR KA09 17012G18KT 6SM SCT045 25/20 A2977"),
                    ob("KA09", minAgo: 120, wind: #""wdir":160,"wspd":8"#,           visib: "8", clouds: #"[{"cover":"FEW","base":6000}]"#,              temp: 26, dewp: 19, altim: 1008, fltCat: "VFR",  raw: "METAR KA09 16008KT 8SM FEW060 26/19 A2977"),
                ]) }
            ),
            InjectionFixture(
                id: "A10", title: "A10 · SQ +RA (squall)",
                subtitle: "present-wx chip RED (SQ escalated, commit 11). (Trend: winds building.)",
                airport: airport("KA10", name: "A10 squall (SIM)"),
                make: { try metarSeries([
                    ob("KA10", minAgo: 0,   wind: #""wdir":270,"wspd":25,"wgst":40"#, visib: "3", clouds: #"[{"cover":"SCT","base":1500}]"#, temp: 19, dewp: 15, altim: 1005, fltCat: "MVFR", wx: "SQ +RA", raw: "METAR KA10 27025G40KT 3SM SQ +RA SCT015 19/15 A2968"),
                    ob("KA10", minAgo: 60,  wind: #""wdir":260,"wspd":18,"wgst":28"#, visib: "5", clouds: #"[{"cover":"SCT","base":2500}]"#, temp: 19, dewp: 16, altim: 1005, fltCat: "MVFR", wx: "+RA",    raw: "METAR KA10 26018G28KT 5SM +RA SCT025 19/16 A2968"),
                    ob("KA10", minAgo: 120, wind: #""wdir":250,"wspd":12"#,          visib: "8", clouds: #"[{"cover":"FEW","base":4000}]"#, temp: 20, dewp: 15, altim: 1005, fltCat: "VFR",  wx: "-RA",    raw: "METAR KA10 25012KT 8SM -RA FEW040 20/15 A2968"),
                ]) }
            ),
            InjectionFixture(
                id: "A11", title: "A11 · +FC (funnel cloud)",
                subtitle: "present-wx chip RED (+FC escalated, commit 11). (Trend: convection deepening.)",
                airport: airport("KA11", name: "A11 funnel cloud (SIM)"),
                make: { try metarSeries([
                    ob("KA11", minAgo: 0,   wind: #""wdir":200,"wspd":10"#,          visib: "2", clouds: #"[{"cover":"BKN","base":1500}]"#, temp: 26, dewp: 22, altim: 1004, fltCat: "IFR",  wx: "+FC",  raw: "METAR KA11 20010KT 2SM +FC BKN015 26/22 A2965"),
                    ob("KA11", minAgo: 60,  wind: #""wdir":200,"wspd":12,"wgst":20"#, visib: "3", clouds: #"[{"cover":"BKN","base":2000,"type":"CB"}]"#, temp: 26, dewp: 21, altim: 1004, fltCat: "MVFR", wx: "TSRA", raw: "METAR KA11 20012G20KT 3SM TSRA BKN020CB 26/21 A2965"),
                    ob("KA11", minAgo: 120, wind: #""wdir":190,"wspd":10"#,          visib: "5", clouds: #"[{"cover":"SCT","base":3000}]"#, temp: 27, dewp: 20, altim: 1004, fltCat: "MVFR", wx: "VCTS", raw: "METAR KA11 19010KT 5SM VCTS SCT030 27/20 A2965"),
                ]) }
            ),
            InjectionFixture(
                id: "A12", title: "A12 · -FZRA at +2°C",
                subtitle: "icing note fires at +2°C surface temp — temp-independence (commit 11, RED). (Trend: onset.)",
                airport: airport("KA12", name: "A12 freezing rain warm (SIM)"),
                make: { try metarSeries([
                    ob("KA12", minAgo: 0,   wind: #""wdir":90,"wspd":8"#, visib: "1", clouds: #"[{"cover":"OVC","base":800}]"#,  temp: 2, dewp: 1, altim: 1006, fltCat: "IFR",  wx: "-FZRA", raw: "METAR KA12 09008KT 1SM -FZRA OVC008 02/01 A2971"),
                    ob("KA12", minAgo: 60,  wind: #""wdir":90,"wspd":8"#, visib: "2", clouds: #"[{"cover":"OVC","base":1200}]"#, temp: 3, dewp: 1, altim: 1006, fltCat: "MVFR", wx: "-RA",   raw: "METAR KA12 09008KT 2SM -RA OVC012 03/01 A2971"),
                    ob("KA12", minAgo: 120, wind: #""wdir":80,"wspd":6"#, visib: "4", clouds: #"[{"cover":"BKN","base":2500}]"#, temp: 4, dewp: 2, altim: 1006, fltCat: "MVFR", raw: "METAR KA12 08006KT 4SM BKN025 04/02 A2971"),
                ]) }
            ),
            InjectionFixture(
                id: "A13", title: "A13 · no altimeter (Finding 15)",
                subtitle: "DOCUMENTED DEFECT: DA renders a fabricated 29.92-derived value. Expected-WRONG marker — do not “fix”.",
                airport: airport("KA13", elevation: 5355, name: "A13 no-altim DA marker (SIM)"),
                make: { try metarSeries([
                    ob("KA13", minAgo: 0,   wind: #""wdir":230,"wspd":6"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":12000}]"#, temp: 32, dewp: 5, altim: nil, fltCat: "VFR", raw: "METAR KA13 23006KT 10SM FEW120 32/05"),
                    ob("KA13", minAgo: 60,  wind: #""wdir":230,"wspd":6"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":12000}]"#, temp: 31, dewp: 5, altim: nil, fltCat: "VFR", raw: "METAR KA13 23006KT 10SM FEW120 31/05"),
                    ob("KA13", minAgo: 120, wind: #""wdir":220,"wspd":6"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":12000}]"#, temp: 32, dewp: 4, altim: nil, fltCat: "VFR", raw: "METAR KA13 22006KT 10SM FEW120 32/04"),
                ]) }
            ),
        ]
    }

    static var tafs: [InjectionFixture] {
        [
            InjectionFixture(
                id: "T1", title: "T1 · improving LIFR→IFR",
                subtitle: "hero says “improving”, NOT “improving to IFR” (commit 11).",
                airport: airport("KT01", name: "T1 improving (SIM)"),
                make: {
                    // Scaffold history matches the TAF's first period (current LIFR); no phenomena.
                    let scaffold = [
                        ob("KT01", minAgo: 0,   wind: #""wdir":360,"wspd":5"#, visib: "0.5", clouds: #"[{"cover":"OVC","base":300}]"#, temp: 9,  dewp: 9, altim: 1013, fltCat: "LIFR", raw: "METAR KT01 36005KT 1/2SM OVC003 09/09 A2992 (SIM SCAFFOLD)"),
                        ob("KT01", minAgo: 60,  wind: #""wdir":350,"wspd":5"#, visib: "1",   clouds: #"[{"cover":"OVC","base":500}]"#, temp: 9,  dewp: 8, altim: 1013, fltCat: "IFR",  raw: "METAR KT01 35005KT 1SM OVC005 09/08 A2992 (SIM SCAFFOLD)"),
                        ob("KT01", minAgo: 120, wind: #""wdir":350,"wspd":6"#, visib: "2",   clouds: #"[{"cover":"OVC","base":800}]"#, temp: 10, dewp: 8, altim: 1013, fltCat: "IFR",  raw: "METAR KT01 35006KT 2SM OVC008 10/08 A2992 (SIM SCAFFOLD)"),
                    ]
                    let json = #"""
                    [{"icaoId":"KT01","validTimeFrom":\#(epoch(-1)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT01 improving LIFR→IFR (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-1)),"timeTo":\#(epoch(2)),"wdir":360,"wspd":5,"visib":0.5,"clouds":[{"cover":"OVC","base":300}]},
                      {"timeFrom":\#(epoch(2)),"timeTo":\#(epoch(24)),"fcstChange":"FM","wdir":20,"wspd":8,"visib":2,"clouds":[{"cover":"OVC","base":800}]}
                    ]}]
                    """#
                    return try tafInjection(scaffold: scaffold, tafJSON: json)
                }
            ),
            InjectionFixture(
                id: "T2", title: "T2 · PROB40 TSRA overlay",
                subtitle: "PROB period typed probabilistic (overlay), not a firm base forecast.",
                airport: airport("KT02", name: "T2 PROB40 (SIM)"),
                make: {
                    // Scaffold history matches the TAF's first (base) period: VFR, no phenomena.
                    let scaffold = [
                        ob("KT02", minAgo: 0,   wind: #""wdir":250,"wspd":6"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":6000}]"#, temp: 20, dewp: 8, altim: 1015, fltCat: "VFR", raw: "METAR KT02 25006KT P6SM FEW060 20/08 A2998 (SIM SCAFFOLD)"),
                        ob("KT02", minAgo: 60,  wind: #""wdir":250,"wspd":6"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":6000}]"#, temp: 20, dewp: 8, altim: 1015, fltCat: "VFR", raw: "METAR KT02 25006KT P6SM FEW060 20/08 A2998 (SIM SCAFFOLD)"),
                        ob("KT02", minAgo: 120, wind: #""wdir":240,"wspd":6"#, visib: #""P6SM""#, clouds: #"[{"cover":"FEW","base":6000}]"#, temp: 19, dewp: 8, altim: 1015, fltCat: "VFR", raw: "METAR KT02 24006KT P6SM FEW060 19/08 A2998 (SIM SCAFFOLD)"),
                    ]
                    let json = #"""
                    [{"icaoId":"KT02","validTimeFrom":\#(epoch(-0.5)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT02 base VFR + PROB40 TSRA (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-0.5)),"timeTo":\#(epoch(24)),"wdir":250,"wspd":8,"visib":"P6SM","clouds":[{"cover":"SCT","base":4000}]},
                      {"timeFrom":\#(epoch(3)),"timeTo":\#(epoch(6)),"fcstChange":"PROB","probability":40,"visib":2,"wxString":"TSRA","clouds":[{"cover":"BKN","base":3500,"type":"CB"}]}
                    ]}]
                    """#
                    return try tafInjection(scaffold: scaffold, tafJSON: json)
                }
            ),
            InjectionFixture(
                id: "T3", title: "T3 · clearing IFR→VFR",
                subtitle: "hero reflects the improvement; doesn’t claim IFR throughout.",
                airport: airport("KT03", name: "T3 clearing (SIM)"),
                make: {
                    // Scaffold history matches the TAF's first period (current IFR); no phenomena.
                    let scaffold = [
                        ob("KT03", minAgo: 0,   wind: #""wdir":90,"wspd":6"#,  visib: "2", clouds: #"[{"cover":"OVC","base":800}]"#,  temp: 12, dewp: 11, altim: 1010, fltCat: "IFR",  raw: "METAR KT03 09006KT 2SM OVC008 12/11 A2983 (SIM SCAFFOLD)"),
                        ob("KT03", minAgo: 60,  wind: #""wdir":90,"wspd":6"#,  visib: "3", clouds: #"[{"cover":"OVC","base":1200}]"#, temp: 12, dewp: 10, altim: 1010, fltCat: "MVFR", raw: "METAR KT03 09006KT 3SM OVC012 12/10 A2983 (SIM SCAFFOLD)"),
                        ob("KT03", minAgo: 120, wind: #""wdir":80,"wspd":7"#,  visib: "5", clouds: #"[{"cover":"BKN","base":2500}]"#, temp: 13, dewp: 10, altim: 1010, fltCat: "MVFR", raw: "METAR KT03 08007KT 5SM BKN025 13/10 A2983 (SIM SCAFFOLD)"),
                    ]
                    let json = #"""
                    [{"icaoId":"KT03","validTimeFrom":\#(epoch(-1)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT03 clearing IFR→VFR (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-1)),"timeTo":\#(epoch(3)),"wdir":90,"wspd":6,"visib":2,"clouds":[{"cover":"OVC","base":800}]},
                      {"timeFrom":\#(epoch(3)),"timeTo":\#(epoch(24)),"fcstChange":"FM","wdir":270,"wspd":8,"visib":"P6SM","clouds":[{"cover":"SCT","base":5000}]}
                    ]}]
                    """#
                    return try tafInjection(scaffold: scaffold, tafJSON: json)
                }
            ),
            InjectionFixture(
                id: "T4", title: "T4 · unknown vis + ceiling",
                subtitle: "category driven by the CEILING, not fabricated VFR. The real category-computation test.",
                airport: airport("KT04", name: "T4 ceiling-driven category (SIM)"),
                make: {
                    // Scaffold history matches the TAF's computed first-period category (IFR); no phenomena.
                    let scaffold = [
                        ob("KT04", minAgo: 0,   wind: #""wdir":200,"wspd":6"#, visib: "2", clouds: #"[{"cover":"OVC","base":800}]"#,  temp: 15, dewp: 13, altim: 1011, fltCat: "IFR",  raw: "METAR KT04 20006KT 2SM OVC008 15/13 A2986 (SIM SCAFFOLD)"),
                        ob("KT04", minAgo: 60,  wind: #""wdir":200,"wspd":6"#, visib: "3", clouds: #"[{"cover":"OVC","base":1500}]"#, temp: 15, dewp: 12, altim: 1011, fltCat: "MVFR", raw: "METAR KT04 20006KT 3SM OVC015 15/12 A2986 (SIM SCAFFOLD)"),
                        ob("KT04", minAgo: 120, wind: #""wdir":190,"wspd":7"#, visib: "5", clouds: #"[{"cover":"BKN","base":3000}]"#, temp: 16, dewp: 12, altim: 1011, fltCat: "MVFR", raw: "METAR KT04 19007KT 5SM BKN030 16/12 A2986 (SIM SCAFFOLD)"),
                    ]
                    let json = #"""
                    [{"icaoId":"KT04","validTimeFrom":\#(epoch(-1)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT04 empty vis + BKN007 (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-1)),"timeTo":\#(epoch(24)),"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":700}]}
                    ]}]
                    """#
                    return try tafInjection(scaffold: scaffold, tafJSON: json)
                }
            ),
        ]
    }

    // MARK: - Live spot-check airports (Section 2)
    // Real idents that trigger a NORMAL live fetch — clearly labeled LIVE so a VFR-today result is
    // never mistaken for a guaranteed-adverse injection. These are NOT simulated (no banner).
    static let liveSpotCheckICAOs: [String] = ["KJFK", "KORD", "KDEN", "KSEA", "KATL"]
}
