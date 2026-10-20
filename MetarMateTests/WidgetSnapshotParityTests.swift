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
    // Every valid fixture carries icaoId + rawOb so MetarParser.parse succeeds after the swap, and
    // obsTime, which the builder requires (launch-hardening A1; NOAA always sends it).
    private func snapshot(_ json: String, icao: String = "KTST") throws -> WidgetWeatherSnapshot {
        try #require(WidgetWeatherSnapshot.from(rawMetar: rawMetar(json), icao: icao))
    }

    // MARK: - Visibility branches

    @Test func p6smVisibilityMapsToSix() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT P6SM FEW040 20/10 A2992","visib":"P6SM","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(s.visibility == 6)
        #expect(s.visibilityReported == true)
    }

    @Test func sixPlusVisibilityMapsToSix() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 6+ FEW040 20/10 A2992","visib":"6+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(s.visibility == 6)
        #expect(s.visibilityReported == true)
    }

    @Test func tenPlusVisibilityMapsToTen() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(s.visibility == 10)
        #expect(s.visibilityReported == true)
    }

    @Test func plainNumericVisibilityPassesThrough() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 3 1/2SM BR BKN020 20/18 A2992","visib":3.5,"wdir":270,"wspd":8,"fltCat":"MVFR"}"#)
        #expect(s.visibility == 3.5)
        #expect(s.visibilityReported == true)
    }

    // MARK: - Ceiling branches (OVX / vertVis)

    @Test func ovxWithBaseYieldsCeiling() throws {
        // VV003 as NOAA sends it: cover OVX + a base + vertVis.
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 00000KT 1/2SM FG VV003 05/05 A2997","visib":0.5,"wdir":0,"wspd":0,"vertVis":3,"clouds":[{"cover":"OVX","base":300}],"fltCat":"LIFR"}"#)
        #expect(s.ceilingFeet == 300)
    }

    @Test func ovxWithNoBaseUsesVertVis() throws {
        // OVX layer with NO base — ceiling must come from the top-level vertVis field.
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 00000KT 1/2SM FG VV003 05/05 A2997","visib":0.5,"wdir":0,"wspd":0,"vertVis":3,"clouds":[{"cover":"OVX"}],"fltCat":"LIFR"}"#)
        #expect(s.ceilingFeet == 300)
    }

    // MARK: - Wind branches

    @Test func missingWindGroupIsUnreportedNotCalm() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z AUTO 10SM CLR 27/19 A2988","visib":"10+","fltCat":"VFR"}"#)
        #expect(s.windReported == false)
        #expect(s.windSpeed == 0)
        #expect(s.windDirection == nil)
        #expect(s.windIsVariable == false)
        #expect(s.windDisplayString == "—")   // pilot-facing render: unreported wind, not "Calm"
    }

    @Test func vrbWindIsVariableWithNoDirection() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z VRB08KT 10SM CLR 20/10 A2992","visib":"10+","wdir":"VRB","wspd":8,"fltCat":"VFR"}"#)
        #expect(s.windIsVariable == true)
        #expect(s.windReported == true)
        #expect(s.windDirection == nil)
        #expect(s.windSpeed == 8)
    }

    // MARK: - Flight category

    @Test func missingFlightCategoryIsUnknownNotVFR() throws {
        let s = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8}"#)
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
        let raw = try rawMetar(#"{"obsTime":1760046780,"rawOb":"METAR ????? 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KPASS") == nil)
    }

    // NEW (commit 10): the snapshot carries the greater-than distinction so the lock screen renders
    // "6+" vs "6". The snapshot .visibility stays a Double (unchanged); the bit is the addition.
    @Test func p6smSetsVisibilityIsGreaterThanBit() throws {
        let p6sm = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT P6SM FEW040 20/10 A2992","visib":"6+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(p6sm.visibility == 6)                    // Double unchanged (the floor)
        #expect(p6sm.visibilityIsGreaterThan == true)
        #expect(p6sm.visibilityDisplay == "6+")

        let exact3 = try snapshot(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 3SM BR BKN020 20/18 A2992","visib":3,"wdir":270,"wspd":8,"fltCat":"MVFR"}"#)
        #expect(exact3.visibilityIsGreaterThan == false)
        #expect(exact3.visibilityDisplay == "3")
    }

    // MARK: - Missing observation time (launch-hardening A1)

    // MetarParser substitutes Date() for a missing obsTime, which would make the report look fresh
    // forever; the builder returns nil instead so the widget keeps its cached snapshot.
    @Test func missingObsTimeReturnsNil() throws {
        let raw = try rawMetar(#"{"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#)
        #expect(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KTST") == nil)
    }
}

// Report-age states and timeline instants (DECISIONS_2026-10 #4): late from 65 min, no current
// report from 75 min, measured from the observation time at the supplied date.
struct WidgetReportAgeTests {

    private func snapshot() throws -> WidgetWeatherSnapshot {
        let raw = try JSONDecoder().decode(RawMetar.self, from: Data(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#.utf8))
        return try #require(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KTST"))
    }

    private func at(_ s: WidgetWeatherSnapshot, minutes: Double) -> WidgetWeatherSnapshot.ReportAge {
        s.reportAge(at: s.observationTime.addingTimeInterval(minutes * 60))
    }

    @Test func boundaries() throws {
        let s = try snapshot()
        #expect(at(s, minutes: -5) == .current)
        #expect(at(s, minutes: 64 + 59.0 / 60) == .current)
        #expect(at(s, minutes: 65) == .late(minutes: 65))
        #expect(at(s, minutes: 74 + 59.0 / 60) == .late(minutes: 74))
        #expect(at(s, minutes: 75) == .noCurrent(minutes: 75))
        #expect(at(s, minutes: 130) == .noCurrent(minutes: 130))
    }

    @Test func ageChangeDatesCoverEveryTransition() throws {
        let s = try snapshot()
        let minutes = s.ageChangeDates(after: s.observationTime)
            .map { Int($0.timeIntervalSince(s.observationTime) / 60) }
        #expect(minutes.first == 65)
        #expect(minutes.contains(75))
        #expect(Array(minutes.prefix(11)) == Array(65...75))
        #expect(minutes.last == 720)
        // Only future instants are returned.
        let later = s.ageChangeDates(after: s.observationTime.addingTimeInterval(100 * 60))
        #expect(later.allSatisfy { $0 > s.observationTime.addingTimeInterval(100 * 60) })
        #expect(s.ageChangeDates(after: s.observationTime.addingTimeInterval(720 * 60)).isEmpty)
    }

    @Test func ageText() {
        #expect(WidgetWeatherSnapshot.ageText(minutes: 68) == "1 h 8 min")
        #expect(WidgetWeatherSnapshot.ageText(minutes: 59) == "59 min")
        #expect(WidgetWeatherSnapshot.ageText(minutes: 120) == "2 h")
        #expect(WidgetWeatherSnapshot.ageText(minutes: 130) == "2 h 10 min")
        #expect(WidgetWeatherSnapshot.ageText(minutes: 720) == "12+ h")
    }
}

// Widget-refresh merge (launch-hardening A1): the app's trend, TAF accuracy and forecast
// deviation are reused only for the same observation; otherwise they're omitted.
struct WidgetRefreshMergeTests {

    private func live() throws -> WidgetWeatherSnapshot {
        let raw = try JSONDecoder().decode(RawMetar.self, from: Data(#"{"obsTime":1760046780,"icaoId":"KTST","rawOb":"METAR KTST 092153Z 27008KT 10SM CLR 20/10 A2992","visib":"10+","wdir":270,"wspd":8,"fltCat":"VFR"}"#.utf8))
        return try #require(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KTST"))
    }

    /// An app-written snapshot for `observationTime`, with trend/TAF/deviation filled in.
    private func appSnapshot(_ s: WidgetWeatherSnapshot, observationTime: Date) -> WidgetWeatherSnapshot {
        WidgetWeatherSnapshot(
            icao: s.icao, iata: "TST", airportName: "Test Field", flightCategory: s.flightCategory,
            windDirection: s.windDirection, windSpeed: s.windSpeed, windGust: s.windGust,
            windIsVariable: s.windIsVariable, windReported: s.windReported,
            visibility: s.visibility, visibilityReported: s.visibilityReported,
            visibilityIsGreaterThan: s.visibilityIsGreaterThan, ceilingFeet: s.ceilingFeet,
            temperature: s.temperature, dewpoint: s.dewpoint, altimeter: s.altimeter,
            trendDirection: .deteriorating, trendHeadline: "Ceiling Falling",
            tafAccuracyPct: 82, forecastWindDivergenceKt: 7, forecastCeilingDivergenceFt: -500,
            forecastVisibilityDivergenceSM: -1.5, isAdvisory: false,
            observationTime: observationTime, snapshotTime: observationTime
        )
    }

    @Test func liveFetchHasNoTrend() throws {
        #expect(try live().hasTrend == false)
    }

    @Test func sameObservationKeepsAppAnalysis() throws {
        let l = try live()
        let merged = WidgetWeatherSnapshot.merge(live: l, cached: appSnapshot(l, observationTime: l.observationTime))
        #expect(merged.hasTrend)
        #expect(merged.trendHeadline == "Ceiling Falling")
        #expect(merged.trendDirection == .deteriorating)
        #expect(merged.tafAccuracyPct == 82)
        #expect(merged.forecastWindDivergenceKt == 7)
        #expect(merged.forecastCeilingDivergenceFt == -500)
        #expect(merged.forecastVisibilityDivergenceSM == -1.5)
        #expect(merged.airportName == "Test Field")
    }

    @Test func olderObservationOmitsAppAnalysis() throws {
        let l = try live()
        let older = l.observationTime.addingTimeInterval(-3600)
        let merged = WidgetWeatherSnapshot.merge(live: l, cached: appSnapshot(l, observationTime: older))
        #expect(merged.hasTrend == false)
        #expect(merged.trendDirection == .unknown)
        #expect(merged.tafAccuracyPct == nil)
        #expect(merged.forecastWindDivergenceKt == nil)
        #expect(merged.forecastCeilingDivergenceFt == nil)
        #expect(merged.forecastVisibilityDivergenceSM == nil)
        #expect(merged.observationTime == l.observationTime)
        #expect(merged.airportName == "Test Field")   // identity still comes from the cache
    }

    @Test func noCacheIsLive() throws {
        let l = try live()
        let merged = WidgetWeatherSnapshot.merge(live: l, cached: nil)
        #expect(merged.hasTrend == false)
        #expect(merged.observationTime == l.observationTime)
    }
}
