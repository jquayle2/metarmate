import Foundation

// MARK: - Canned adverse-weather fixtures (A1–A13, T1–T4)
//
// The corpus from docs/PRE_MERGE_TEST_PLAN.md, authored as STRUCTURED NOAA JSON — because the real
// parser reads NOAA's decoded fields (visib/wdir/clouds/wxString/fltCat/fcsts), NOT the raw string.
// Each fixture is decoded + parsed through SimulatedDecode (the same seam as the live fetch) so a
// parse failure surfaces honestly; there are NO `?? <number>` fallbacks anywhere in this file.
//
// METAR category (`fltCat`) is a PASSTHROUGH — MetarParser reads it verbatim and never computes it.
// So A1–A12's `fltCat` is set to NOAA's real value for that ob (flagged per-row in the plan). TAF
// category IS computed by TafParser.calculateFlightCategory, so T1–T4 OMIT any category hint and let
// the ceiling/visibility drive it — that is the thing under test (esp. T4).
//
// T1–T4 are TAF cases, but the production detail view only renders the TAF section when a METAR is
// present (`if let metar = vm.metar`). Rather than change that production gating, each TAF is paired
// with a scaffolding METAR (same ident) so the screen renders. The scaffold's category is MATCHED to
// the TAF's FIRST period (a real station's METAR ≈ its TAF's current period) so the screen doesn't
// LEAD with a chip that contradicts the case under test. Scaffolds carry NO weather phenomena — their
// category comes from vis/ceiling only, so nothing bleeds into the TAF case. The scaffold is not the
// thing under test; TAF-sourcing is proven structurally in SimulatedBannerSnapshotTests.

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

    private static func metarInjection(_ json: String) throws -> SimulatedInjection {
        SimulatedInjection(metars: [try SimulatedDecode.parseMetar(json: json)], taf: nil)
    }

    // Scaffolds a TAF fixture so the detail view renders its TAF section. The scaffold's category is
    // MATCHED to the TAF's FIRST period (a real station's METAR ≈ its TAF's current period), so the
    // screen doesn't LEAD with a chip that contradicts the case under test. Scaffolds carry NO weather
    // phenomena — their category comes from vis/ceiling only, so no injected weather bleeds into the
    // TAF case. Because the scaffold and the TAF may now agree on category, TAF-sourcing is proven
    // structurally in SimulatedBannerSnapshotTests (the hero takes only a Taf; category tracks the
    // ceiling), NOT by category inequality.
    private static func tafInjection(icao: String, scaffoldJSON: String, tafJSON: String) throws -> SimulatedInjection {
        SimulatedInjection(metars: [try SimulatedDecode.parseMetar(json: scaffoldJSON)],
                           taf: try SimulatedDecode.parseTaf(json: tafJSON))
    }

    // Epoch (seconds) offset from now, for TAF period times so labels read sensibly.
    private static func epoch(_ hoursFromNow: Double) -> Int {
        Int(Date().addingTimeInterval(hoursFromNow * 3600).timeIntervalSince1970)
    }

    // MARK: - The corpus

    static var all: [InjectionFixture] { metars + tafs }

    static let metars: [InjectionFixture] = [
        InjectionFixture(
            id: "A1", title: "A1 · P6SM (string)",
            subtitle: "visibility → “6+ SM” (never “6 SM”). fltCat VFR passthrough.",
            airport: airport("KA01", name: "A1 P6SM string (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA01","wdir":250,"wspd":8,"visib":"P6SM","temp":20,"dewp":10,"altim":1013,"rawOb":"METAR KA01 251953Z 25008KT P6SM FEW050 20/10 A2992","clouds":[{"cover":"FEW","base":5000}],"fltCat":"VFR"}]"#) }
        ),
        InjectionFixture(
            id: "A2", title: "A2 · 6 (number)",
            subtitle: "visibility → “6 SM” (never “6+ SM”). Must differ from A1.",
            airport: airport("KA02", name: "A2 six exact (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA02","wdir":250,"wspd":8,"visib":6,"temp":20,"dewp":10,"altim":1013,"rawOb":"METAR KA02 251953Z 25008KT 6SM FEW050 20/10 A2992","clouds":[{"cover":"FEW","base":5000}],"fltCat":"VFR"}]"#) }
        ),
        InjectionFixture(
            id: "A3", title: "A3 · P10SM (string)",
            subtitle: "visibility → “10+ SM”. fltCat VFR passthrough.",
            airport: airport("KA03", name: "A3 P10SM string (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA03","wdir":250,"wspd":8,"visib":"P10SM","temp":20,"dewp":10,"altim":1013,"rawOb":"METAR KA03 251953Z 25008KT 10SM FEW050 20/10 A2992","clouds":[{"cover":"FEW","base":5000}],"fltCat":"VFR"}]"#) }
        ),
        InjectionFixture(
            id: "A4", title: "A4 · LIFR fog (OVX/VV002)",
            subtitle: "vis 0.5 SM, ceiling ~200 ft, LIFR → magenta. Category passthrough.",
            airport: airport("KA04", name: "A4 LIFR fog (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA04","wdir":360,"wspd":3,"visib":0.5,"temp":14,"dewp":14,"altim":1012,"rawOb":"METAR KA04 251953Z 36003KT 1/2SM FG VV002 14/14 A2989","clouds":[{"cover":"OVX","base":200}],"wxString":"FG","fltCat":"LIFR"}]"#) }
        ),
        InjectionFixture(
            id: "A5", title: "A5 · IFR mist (OVC004)",
            subtitle: "vis 2 SM, ceiling 400 ft, IFR → red. Category passthrough.",
            airport: airport("KA05", name: "A5 IFR mist (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA05","wdir":90,"wspd":6,"visib":2,"temp":18,"dewp":17,"altim":1010,"rawOb":"METAR KA05 251953Z 09006KT 2SM BR OVC004 18/17 A2983","clouds":[{"cover":"OVC","base":400}],"wxString":"BR","fltCat":"IFR"}]"#) }
        ),
        InjectionFixture(
            id: "A6", title: "A6 · OVX vertVis-only (VV001)",
            subtitle: "ceiling ~100 ft derived from vertVis (NOT dropped/blank).",
            airport: airport("KA06", name: "A6 vertVis ceiling (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA06","wdir":0,"wspd":0,"visib":0.25,"temp":5,"dewp":5,"vertVis":1,"altim":1015,"rawOb":"METAR KA06 251953Z 00000KT 1/4SM FG VV001 05/05 A2997","clouds":[{"cover":"OVX"}],"wxString":"FG","fltCat":"LIFR"}]"#) }
        ),
        InjectionFixture(
            id: "A7", title: "A7 · missing wind group",
            subtitle: "wind → “—” + “Wind not reported” note. NOT “Calm”.",
            airport: airport("KA07", name: "A7 no wind (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA07","visib":"P6SM","temp":25,"dewp":15,"altim":1013,"rawOb":"METAR KA07 251953Z AUTO P6SM FEW040 25/15 A2992","clouds":[{"cover":"FEW","base":4000}],"fltCat":"VFR"}]"#) }
        ),
        InjectionFixture(
            id: "A8", title: "A8 · genuine calm (00000KT)",
            subtitle: "wind → “Calm”, reported. Must differ from A7.",
            airport: airport("KA08", name: "A8 calm (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA08","wdir":0,"wspd":0,"visib":"P6SM","temp":22,"dewp":10,"altim":1013,"rawOb":"METAR KA08 251953Z 00000KT P6SM FEW040 22/10 A2992","clouds":[{"cover":"FEW","base":4000}],"fltCat":"VFR"}]"#) }
        ),
        InjectionFixture(
            id: "A9", title: "A9 · TSRA + CB, gust 25",
            subtitle: "present-wx chip RED (TS); gust caution amber.",
            airport: airport("KA09", name: "A9 thunderstorm (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA09","wdir":180,"wspd":15,"wgst":25,"visib":4,"temp":24,"dewp":20,"altim":1008,"rawOb":"METAR KA09 251953Z 18015G25KT 4SM TSRA BKN025CB 24/20 A2977","clouds":[{"cover":"BKN","base":2500,"type":"CB"}],"wxString":"TSRA","fltCat":"MVFR"}]"#) }
        ),
        InjectionFixture(
            id: "A10", title: "A10 · SQ +RA (squall)",
            subtitle: "present-wx chip RED (SQ escalated, commit 11).",
            airport: airport("KA10", name: "A10 squall (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA10","wdir":270,"wspd":25,"wgst":40,"visib":3,"temp":19,"dewp":15,"altim":1005,"rawOb":"METAR KA10 251953Z 27025G40KT 3SM SQ +RA SCT015 19/15 A2968","clouds":[{"cover":"SCT","base":1500}],"wxString":"SQ +RA","fltCat":"MVFR"}]"#) }
        ),
        InjectionFixture(
            id: "A11", title: "A11 · +FC (funnel cloud)",
            subtitle: "present-wx chip RED (+FC escalated, commit 11).",
            airport: airport("KA11", name: "A11 funnel cloud (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA11","wdir":200,"wspd":10,"visib":2,"temp":26,"dewp":22,"altim":1004,"rawOb":"METAR KA11 251953Z 20010KT 2SM +FC BKN015 26/22 A2965","clouds":[{"cover":"BKN","base":1500}],"wxString":"+FC","fltCat":"IFR"}]"#) }
        ),
        InjectionFixture(
            id: "A12", title: "A12 · -FZRA at +2°C",
            subtitle: "icing note fires at +2°C surface temp — demonstrates temp-independence (commit 11, RED).",
            airport: airport("KA12", name: "A12 freezing rain warm (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA12","wdir":90,"wspd":8,"visib":1,"temp":2,"dewp":1,"altim":1006,"rawOb":"METAR KA12 251953Z 09008KT 1SM -FZRA OVC008 02/01 A2971","clouds":[{"cover":"OVC","base":800}],"wxString":"-FZRA","fltCat":"IFR"}]"#) }
        ),
        InjectionFixture(
            id: "A13", title: "A13 · no altimeter (Finding 15)",
            subtitle: "DOCUMENTED DEFECT: DA renders a fabricated 29.92-derived value. Expected-WRONG marker — do not “fix”.",
            airport: airport("KA13", elevation: 5355, name: "A13 no-altim DA marker (SIM)"),
            make: { try metarInjection(#"[{"icaoId":"KA13","wdir":230,"wspd":6,"visib":"P6SM","temp":32,"dewp":5,"rawOb":"METAR KA13 251953Z 23006KT 10SM FEW120 32/05","clouds":[{"cover":"FEW","base":12000}],"fltCat":"VFR"}]"#) }
        ),
    ]

    static var tafs: [InjectionFixture] {
        [
            InjectionFixture(
                id: "T1", title: "T1 · improving LIFR→IFR",
                subtitle: "hero says “improving”, NOT “improving to IFR” (commit 11).",
                airport: airport("KT01", name: "T1 improving (SIM)"),
                make: {
                    // Scaffold matches the TAF's first period (LIFR); no phenomena — LIFR from vis/ceiling.
                    let scaffold = #"[{"icaoId":"KT01","wdir":360,"wspd":5,"visib":0.5,"temp":9,"dewp":9,"altim":1013,"rawOb":"METAR KT01 251953Z 36005KT 1/2SM OVC003 09/09 A2992 (SIMULATED SCAFFOLD)","clouds":[{"cover":"OVC","base":300}],"fltCat":"LIFR"}]"#
                    let json = #"""
                    [{"icaoId":"KT01","validTimeFrom":\#(epoch(-1)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT01 improving LIFR→IFR (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-1)),"timeTo":\#(epoch(2)),"wdir":360,"wspd":5,"visib":0.5,"clouds":[{"cover":"OVC","base":300}]},
                      {"timeFrom":\#(epoch(2)),"timeTo":\#(epoch(24)),"fcstChange":"FM","wdir":20,"wspd":8,"visib":2,"clouds":[{"cover":"OVC","base":800}]}
                    ]}]
                    """#
                    return try tafInjection(icao: "KT01", scaffoldJSON: scaffold, tafJSON: json)
                }
            ),
            InjectionFixture(
                id: "T2", title: "T2 · PROB40 TSRA overlay",
                subtitle: "PROB period typed probabilistic (overlay), not a firm base forecast.",
                airport: airport("KT02", name: "T2 PROB40 (SIM)"),
                make: {
                    // Scaffold matches the TAF's first (base) period: VFR, no phenomena.
                    let scaffold = #"[{"icaoId":"KT02","wdir":250,"wspd":6,"visib":"P6SM","temp":20,"dewp":8,"altim":1015,"rawOb":"METAR KT02 251953Z 25006KT P6SM FEW060 20/08 A2998 (SIMULATED SCAFFOLD)","clouds":[{"cover":"FEW","base":6000}],"fltCat":"VFR"}]"#
                    let json = #"""
                    [{"icaoId":"KT02","validTimeFrom":\#(epoch(-0.5)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT02 base VFR + PROB40 TSRA (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-0.5)),"timeTo":\#(epoch(24)),"wdir":250,"wspd":8,"visib":"P6SM","clouds":[{"cover":"SCT","base":4000}]},
                      {"timeFrom":\#(epoch(3)),"timeTo":\#(epoch(6)),"fcstChange":"PROB","probability":40,"visib":2,"wxString":"TSRA","clouds":[{"cover":"BKN","base":3500,"type":"CB"}]}
                    ]}]
                    """#
                    return try tafInjection(icao: "KT02", scaffoldJSON: scaffold, tafJSON: json)
                }
            ),
            InjectionFixture(
                id: "T3", title: "T3 · clearing IFR→VFR",
                subtitle: "hero reflects the improvement; doesn’t claim IFR throughout.",
                airport: airport("KT03", name: "T3 clearing (SIM)"),
                make: {
                    // Scaffold matches the TAF's first period (IFR); no phenomena — IFR from vis/ceiling.
                    let scaffold = #"[{"icaoId":"KT03","wdir":90,"wspd":6,"visib":2,"temp":12,"dewp":11,"altim":1010,"rawOb":"METAR KT03 251953Z 09006KT 2SM OVC008 12/11 A2983 (SIMULATED SCAFFOLD)","clouds":[{"cover":"OVC","base":800}],"fltCat":"IFR"}]"#
                    let json = #"""
                    [{"icaoId":"KT03","validTimeFrom":\#(epoch(-1)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT03 clearing IFR→VFR (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-1)),"timeTo":\#(epoch(3)),"wdir":90,"wspd":6,"visib":2,"clouds":[{"cover":"OVC","base":800}]},
                      {"timeFrom":\#(epoch(3)),"timeTo":\#(epoch(24)),"fcstChange":"FM","wdir":270,"wspd":8,"visib":"P6SM","clouds":[{"cover":"SCT","base":5000}]}
                    ]}]
                    """#
                    return try tafInjection(icao: "KT03", scaffoldJSON: scaffold, tafJSON: json)
                }
            ),
            InjectionFixture(
                id: "T4", title: "T4 · unknown vis + ceiling",
                subtitle: "category driven by the CEILING, not fabricated VFR. The real category-computation test.",
                airport: airport("KT04", name: "T4 ceiling-driven category (SIM)"),
                make: {
                    // Scaffold matches the TAF's computed first-period category (IFR); no phenomena, so
                    // the screen leads with an IFR chip coherent with the TAF hero. The TAF period below
                    // still computes IFR from its own ceiling with UNKNOWN vis — that's the case under test.
                    let scaffold = #"[{"icaoId":"KT04","wdir":200,"wspd":6,"visib":2,"temp":15,"dewp":13,"altim":1011,"rawOb":"METAR KT04 251953Z 20006KT 2SM OVC008 15/13 A2986 (SIMULATED SCAFFOLD)","clouds":[{"cover":"OVC","base":800}],"fltCat":"IFR"}]"#
                    let json = #"""
                    [{"icaoId":"KT04","validTimeFrom":\#(epoch(-1)),"validTimeTo":\#(epoch(24)),"rawTAF":"TAF KT04 empty vis + BKN007 (SIMULATED)","fcsts":[
                      {"timeFrom":\#(epoch(-1)),"timeTo":\#(epoch(24)),"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":700}]}
                    ]}]
                    """#
                    return try tafInjection(icao: "KT04", scaffoldJSON: scaffold, tafJSON: json)
                }
            ),
        ]
    }

    // MARK: - Live spot-check airports (Section 2)
    // Real idents that trigger a NORMAL live fetch — clearly labeled LIVE so a VFR-today result is
    // never mistaken for a guaranteed-adverse injection. These are NOT simulated (no banner).
    static let liveSpotCheckICAOs: [String] = ["KJFK", "KORD", "KDEN", "KSEA", "KATL"]
}
