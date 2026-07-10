import Testing
import Foundation
@testable import MetarMate

// Parity coverage for the widget's RawMetar -> WidgetWeatherSnapshot builder
// (`WidgetWeatherSnapshot.from(rawMetar:icao:)`), covering the branches Finding 14 is about:
// P6SM / "6+" / "10+" / numeric visibility, VV003, OVX-with-no-base ceiling, missing wind, VRB
// wind, and a missing flight category.
//
// These are written FIRST against the verbatim duplicate parser, then the builder's internals are
// swapped to MetarParser.parse (commit 9). The nine valid-observation cases below assert the SAME
// WidgetWeatherSnapshot field values through both implementations and must stay byte-identical
// across the swap. The tenth case (`unparseableMetarMissingStationIdReturnsNil`) is the ONLY one
// permitted to change: the duplicate fabricates a snapshot from an icaoId-less METAR; after the
// swap MetarParser.parse throws and the builder returns nil (Finding 14's behavior change).
struct WidgetSnapshotParityTests {

    private func rawMetar(_ json: String) throws -> RawMetar {
        try JSONDecoder().decode(RawMetar.self, from: Data(json.utf8))
    }
    // Every valid fixture carries icaoId + rawOb so MetarParser.parse succeeds after the swap.
    private func snapshot(_ json: String, icao: String = "KTST") throws -> WidgetWeatherSnapshot {
        try #require(WidgetWeatherSnapshot.from(rawMetar: rawMetar(json), icao: icao))
    }

    // MARK: - Visibility branches

    @Test func p6smVisibilityMapsToSix() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT P6SM FEW040 20/10 A2992","visib":"P6SM","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(s.visibility == 6)
        #expect(s.visibilityReported == true)
    }

    @Test func sixPlusVisibilityMapsToSix() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 6+ FEW040 20/10 A2992","visib":"6+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(s.visibility == 6)
        #expect(s.visibilityReported == true)
    }

    @Test func tenPlusVisibilityMapsToTen() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(s.visibility == 10)
        #expect(s.visibilityReported == true)
    }

    @Test func plainNumericVisibilityPassesThrough() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 3 1/2SM BR BKN020 20/18 A2992","visib":3.5,"wdir":270,"wspd":8,"fltCat":"MVFR"}"#)
        #expect(s.visibility == 3.5)
        #expect(s.visibilityReported == true)
    }

    // MARK: - Ceiling branches (OVX / vertVis)

    @Test func ovxWithBaseYieldsCeiling() throws {
        // VV003 as NOAA sends it: cover OVX + a base + vertVis.
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 00000KT 1/2SM FG VV003 05/05 A2997","visib":0.5,"wdir":0,"wspd":0,"vertVis":3,"clouds":[{"cover":"OVX","base":300}],"fltCat":"LIFR"}"#)
        #expect(s.ceilingFeet == 300)
    }

    @Test func ovxWithNoBaseUsesVertVis() throws {
        // OVX layer with NO base — ceiling must come from the top-level vertVis field.
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 00000KT 1/2SM FG VV003 05/05 A2997","visib":0.5,"wdir":0,"wspd":0,"vertVis":3,"clouds":[{"cover":"OVX"}],"fltCat":"LIFR"}"#)
        #expect(s.ceilingFeet == 300)
    }

    // MARK: - Wind branches

    @Test func missingWindGroupIsUnreportedNotCalm() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z AUTO 10SM CLR 27/19 A2988","visib":"10+","fltCat":"VFR"}"#)
        #expect(s.windReported == false)
        #expect(s.windSpeed == 0)
        #expect(s.windDirection == nil)
        #expect(s.windIsVariable == false)
        #expect(s.windDisplayString == "—")   // pilot-facing render: unreported wind, not "Calm"
    }

    @Test func vrbWindIsVariableWithNoDirection() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z VRB08KT 10SM CLR 20/10 A2992","visib":"10+","wdir":"VRB","wspd":8,"fltCat":"VFR"}"#)
        #expect(s.windIsVariable == true)
        #expect(s.windReported == true)
        #expect(s.windDirection == nil)
        #expect(s.windSpeed == 8)
    }

    // MARK: - Flight category

    @Test func missingFlightCategoryIsUnknownNotVFR() throws {
        let s = try snapshot(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8}"#)
        #expect(s.flightCategory == .unknown)
    }

    // MARK: - The one case permitted to change at the swap (Finding 14)

    // POST-SWAP (the one permitted flip): an icaoId-less METAR is unparseable, so MetarParser.parse
    // throws and the builder returns nil — the widget shows no snapshot rather than fabricating one
    // from `icaoId ?? icao`. This assertion was FLIPPED from the pre-swap version, which expected a
    // fabricated snapshot with `icao == "KPASS"` (the duplicate's total-parse behavior). See
    // Finding 14: de-duplication removed the widget's total-parse fallback. No other parity test
    // changed across the swap.
    @Test func unparseableMetarMissingStationIdReturnsNil() throws {
        let raw = try rawMetar(#"{"rawOb":"METAR ????? 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KPASS") == nil)
    }
}
