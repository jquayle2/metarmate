import Testing
import Foundation
import CoreLocation
@testable import MetarMate

// Siri hands-free (launch checklist section 4, #25; docs/handoffs/SIRI_HANDS_FREE_handoff.md).
// Wording: report age per D#4 with the widget's boundaries, and "No ceiling" vs "Sky clear" from
// the Oct 22 Kingman device test (KIGM 221551Z AUTO VRB03KT 10SM FEW055 SCT100 read "Sky clear").
@MainActor
struct SiriReportWordingTests {

    // Verbatim from the device test; JSON trimmed to parse-relevant fields.
    private static let kigm = #"{"icaoId":"KIGM","obsTime":1792684260,"temp":19,"dewp":13,"wdir":"VRB","wspd":3,"visib":"10+","altim":1014,"rawOb":"KIGM 221551Z AUTO VRB03KT 10SM FEW055 SCT100 19/13 A2996","clouds":[{"cover":"FEW","base":5500},{"cover":"SCT","base":10000}],"fltCat":"VFR"}"#
    private static let clr = #"{"icaoId":"KIGM","obsTime":1792684260,"temp":19,"dewp":13,"wdir":270,"wspd":8,"visib":"10+","altim":1014,"rawOb":"KIGM 221551Z 27008KT 10SM CLR 19/13 A2996","clouds":[{"cover":"CLR"}],"fltCat":"VFR"}"#
    private static let noClouds = #"{"icaoId":"KIGM","obsTime":1792684260,"temp":19,"dewp":13,"wdir":270,"wspd":8,"visib":"10+","altim":1014,"rawOb":"KIGM 221551Z 27008KT 10SM 19/13 A2996","fltCat":"VFR"}"#

    private func metar(_ json: String) throws -> Metar {
        try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }
    private func at(_ m: Metar, minutes: Double) -> Date {
        m.observationTime.addingTimeInterval(minutes * 60)
    }
    private func dialog(_ m: Metar, minutes: Double) -> String {
        SiriReportWording.dialog(airportName: "Kingman", metar: m,
                                 trend: WeatherTrend.derive(metars: [m], taf: nil), at: at(m, minutes: minutes))
    }

    // MARK: - Sky

    @Test func fewScatteredIsNoCeilingNotSkyClear() throws {
        let m = try metar(Self.kigm)
        #expect(SiriReportWording.skyText(m) == "No ceiling")
        #expect(SiriReportWording.summaryLine(metar: m, at: at(m, minutes: 16)) == "16 min ago · No ceiling · Vis 10+ sm · Wind 3kt")
    }

    @Test func clrIsSkyClear() throws {
        #expect(SiriReportWording.skyText(try metar(Self.clr)) == "Sky clear")
    }

    // Audit #6: no cloud group is sky not reported, never "No ceiling" or "Ceiling unlimited".
    @Test func missingCloudGroupIsSkyNotReported() throws {
        let m = try metar(Self.noClouds)
        #expect(SiriReportWording.skyText(m) == "Sky not reported")
        #expect(SiriReportWording.summaryLine(metar: m, at: at(m, minutes: 16)) == "16 min ago · Sky not reported · Vis 10+ sm · Wind 8kt")
        let spoken = dialog(m, minutes: 16)
        #expect(spoken.contains("Sky condition not reported."))
        #expect(!spoken.contains("Ceiling unlimited"))
    }

    // MARK: - Age (64 current, 65 and 75 late, 76 no current)

    @Test func age64IsCurrent() throws {
        let m = try metar(Self.kigm)
        #expect(dialog(m, minutes: 64).hasPrefix("As of 64 minutes ago, Kingman is VFR. Ceiling unlimited."))
        #expect(SiriReportWording.summaryLine(metar: m, at: at(m, minutes: 64)).hasPrefix("64 min ago · "))
        #expect(SiriReportWording.cardCategory(metar: m, at: at(m, minutes: 64)) == .vfr)
    }

    @Test func age65IsLatePastTense() throws {
        let m = try metar(Self.kigm)
        #expect(dialog(m, minutes: 65).hasPrefix("The latest Kingman report is 65 minutes old. Kingman was VFR. Ceiling unlimited."))
        #expect(SiriReportWording.summaryLine(metar: m, at: at(m, minutes: 65)).hasPrefix("Late · 65 min ago · No ceiling"))
        #expect(SiriReportWording.cardCategory(metar: m, at: at(m, minutes: 65)) == .vfr)
    }

    @Test func age75IsStillLate() throws {
        let m = try metar(Self.kigm)
        #expect(dialog(m, minutes: 75 + 59.0 / 60).hasPrefix("The latest Kingman report is 75 minutes old. Kingman was VFR."))
    }

    @Test func age76HasNoCurrentReportAndNoConditions() throws {
        let m = try metar(Self.kigm)
        let spoken = dialog(m, minutes: 76)
        #expect(spoken == "There's no current METAR for Kingman. The last report is 76 minutes old.")
        #expect(!spoken.contains("VFR"))
        #expect(SiriReportWording.summaryLine(metar: m, at: at(m, minutes: 76)) == "No current METAR · last report 76 min ago")
        #expect(SiriReportWording.cardCategory(metar: m, at: at(m, minutes: 76)) == .unknown)
    }

    @Test func ageOverTwoHoursIsHoursAndMinutes() {
        #expect(SiriReportWording.spokenAge(minutes: 119) == "119 minutes")
        #expect(SiriReportWording.spokenAge(minutes: 130) == "2 hours 10 minutes")
        #expect(SiriReportWording.spokenAge(minutes: 180) == "3 hours")
        #expect(SiriReportWording.shortAge(minutes: 130) == "2 h 10 min")
    }

    @Test func freshReportSaysLessThanAMinute() throws {
        let m = try metar(Self.kigm)
        #expect(dialog(m, minutes: 0.5).hasPrefix("As of less than a minute ago, Kingman is VFR."))
    }
}

// Airport resolution with no tap: nearest METAR station, and 3-char LIDs.
@MainActor
struct SiriAirportResolverTests {

    // Kingman AZ, about 1 nm from KIGM (the Oct 22 device-test position).
    static let nearKingman = CLLocation(latitude: 35.26, longitude: -113.92)

    @Test func nearestIsAMetarStation() throws {
        let nearest = try #require(SiriAirportResolver.nearestMetarStation(to: Self.nearKingman))
        #expect(nearest.icao == "KIGM")
        #expect(nearest.hasMetar)
    }

    @Test func threeCharLidResolvesWithKPrefix() async throws {
        let cma = try #require(await FlyingWeatherIntent.airportForIdent("CMA"))
        #expect(cma.icao == "KCMA")
        let k36 = try #require(await FlyingWeatherIntent.airportForIdent("36K"))
        #expect(k36.icao == "36K")
        #expect(WeatherService.noaaCandidate(for: k36.icao) == "K36K")
    }

    @Test func oPrefixedIdentsStillResolve() async throws {
        #expect(await FlyingWeatherIntent.airportForIdent("OL7")?.icao == "0L7")
    }
}
