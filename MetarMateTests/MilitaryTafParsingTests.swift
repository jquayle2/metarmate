import Testing
import Foundation
@testable import MetarMate

// Military TAFs (Step 2 of the nearby-TAF work: the fallback pulls more stations, KLSV/KINS nearby).
// Live NOAA JSON for KINS, KLSV and KNKX from Oct 21, 2026 (verbatim, trimmed to the fields the app
// reads plus altimeter/turbulence/temperature to show they're ignored; full responses in
// Fixtures/military_tafs.json). They lean on BECMG, QNH…INS, TX/TN, 5xxxxx turbulence groups,
// 9999/9000 metric visibility, NSW and OMTNS.
@MainActor
struct MilitaryTafParsingTests {

    private enum Live {
        static let kins = #"{"icaoId":"KINS","issueTime":"2026-10-21T16:20:00.000Z","validTimeFrom":1792598400,"validTimeTo":1792695600,"rawTAF":"TAF AMD KINS 211620Z 2116/2219 VRB06KT 9999 FEW120 QNH2992INS BECMG 2116/2117 11010G15KT 9999 SCT100 QNH2992INS BECMG 2117/2118 11012G21KT 9999 SCT100 510009 QNH2986INS TEMPO 2118/2120 12016G28KT 520009 BECMG 2119/2120 12016G28KT 9999 BKN080 520009 QNH2977INS TSRA OMTNS TEMPO 2120/2124 13018G31KT VCSH BECMG 2200/2201 11010G15KT 9999 SCT080 QNH2978INS TEMPO 2201/2204 12012G21KT 510009 BECMG 2210/2211 25009KT 9999 SCT080 QNH2980INS BECMG 2214/2215 25010G15KT 9999 BKN050 QNH2981INS SHRA OMTNS TX26/2122Z TN18/2116Z","fcsts":[{"timeFrom":1792598400,"timeTo":1792695600,"timeBec":null,"fcstChange":null,"probability":null,"wdir":"VRB","wspd":6,"wgst":null,"visib":"6+","clouds":[{"cover":"FEW","base":12000,"type":null}],"wxString":null,"altim":1013,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792598400,"timeTo":1792602000,"timeBec":1792602000,"fcstChange":"BECMG","probability":null,"wdir":110,"wspd":10,"wgst":15,"visib":"6+","clouds":[{"cover":"SCT","base":10000,"type":null}],"wxString":null,"altim":1013,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792602000,"timeTo":1792609200,"timeBec":1792605600,"fcstChange":"BECMG","probability":null,"wdir":110,"wspd":12,"wgst":21,"visib":"6+","clouds":[{"cover":"SCT","base":10000,"type":null}],"wxString":null,"altim":1011,"icgTurb":[{"impactVar":"TURB","intensity":1,"minAlt":null,"maxAlt":9000}],"temp":[],"notDecoded":null},{"timeFrom":1792605600,"timeTo":1792612800,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":120,"wspd":16,"wgst":28,"visib":"","clouds":[],"wxString":null,"altim":null,"icgTurb":[{"impactVar":"TURB","intensity":2,"minAlt":null,"maxAlt":9000}],"temp":[],"notDecoded":null},{"timeFrom":1792609200,"timeTo":1792627200,"timeBec":1792612800,"fcstChange":"BECMG","probability":null,"wdir":120,"wspd":16,"wgst":28,"visib":"6+","clouds":[{"cover":"BKN","base":8000,"type":null}],"wxString":"TSRA","altim":1008,"icgTurb":[{"impactVar":"TURB","intensity":2,"minAlt":null,"maxAlt":9000}],"temp":[],"notDecoded":null},{"timeFrom":1792612800,"timeTo":1792627200,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":130,"wspd":18,"wgst":31,"visib":"","clouds":[],"wxString":"VCSH","altim":null,"icgTurb":[],"temp":[],"notDecoded":"OMTNS "},{"timeFrom":1792627200,"timeTo":1792663200,"timeBec":1792630800,"fcstChange":"BECMG","probability":null,"wdir":110,"wspd":10,"wgst":15,"visib":"6+","clouds":[{"cover":"SCT","base":8000,"type":null}],"wxString":"TSRA","altim":1009,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792630800,"timeTo":1792641600,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":120,"wspd":12,"wgst":21,"visib":"","clouds":[],"wxString":null,"altim":null,"icgTurb":[{"impactVar":"TURB","intensity":1,"minAlt":null,"maxAlt":9000}],"temp":[],"notDecoded":null},{"timeFrom":1792663200,"timeTo":1792677600,"timeBec":1792666800,"fcstChange":"BECMG","probability":null,"wdir":250,"wspd":9,"wgst":null,"visib":"6+","clouds":[{"cover":"SCT","base":8000,"type":null}],"wxString":"TSRA","altim":1009,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792677600,"timeTo":1792695600,"timeBec":1792681200,"fcstChange":"BECMG","probability":null,"wdir":250,"wspd":10,"wgst":15,"visib":"6+","clouds":[{"cover":"BKN","base":5000,"type":null}],"wxString":"SHRA","altim":1010,"icgTurb":[],"temp":[{"validTime":1792620000,"surfaceTemp":26,"maxOrMin":"MAX"},{"validTime":1792598400,"surfaceTemp":18,"maxOrMin":"MIN"}],"notDecoded":null}]}"#
        static let klsv = #"{"icaoId":"KLSV","issueTime":"2026-10-21T15:00:00.000Z","validTimeFrom":1792594800,"validTimeTo":1792702800,"rawTAF":"TAF KLSV 211500Z 2115/2221 09012KT 9999 FEW080 SCT150 QNH2989INS BECMG 2119/2120 09010G20KT 9999 SCT080 BKN150 510009 QNH2976INS TEMPO 2122/2202 09015G25KT 520009 BECMG 2207/2208 06008KT 9999 SCT100 BKN150 QNH2982INS BECMG 2213/2214 21012KT 9000 -SHRA BKN080 QNH2976INS TX29/2123Z TN17/2214Z","fcsts":[{"timeFrom":1792594800,"timeTo":1792609200,"timeBec":null,"fcstChange":null,"probability":null,"wdir":90,"wspd":12,"wgst":null,"visib":"6+","clouds":[{"cover":"FEW","base":8000,"type":null},{"cover":"SCT","base":15000,"type":null}],"wxString":null,"altim":1012,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792609200,"timeTo":1792652400,"timeBec":1792612800,"fcstChange":"BECMG","probability":null,"wdir":90,"wspd":10,"wgst":20,"visib":"6+","clouds":[{"cover":"SCT","base":8000,"type":null},{"cover":"BKN","base":15000,"type":null}],"wxString":null,"altim":1008,"icgTurb":[{"impactVar":"TURB","intensity":1,"minAlt":null,"maxAlt":9000}],"temp":[],"notDecoded":null},{"timeFrom":1792620000,"timeTo":1792634400,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":90,"wspd":15,"wgst":25,"visib":"","clouds":[],"wxString":null,"altim":null,"icgTurb":[{"impactVar":"TURB","intensity":2,"minAlt":null,"maxAlt":9000}],"temp":[],"notDecoded":null},{"timeFrom":1792652400,"timeTo":1792674000,"timeBec":1792656000,"fcstChange":"BECMG","probability":null,"wdir":60,"wspd":8,"wgst":null,"visib":"6+","clouds":[{"cover":"SCT","base":10000,"type":null},{"cover":"BKN","base":15000,"type":null}],"wxString":null,"altim":1010,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792674000,"timeTo":1792702800,"timeBec":1792677600,"fcstChange":"BECMG","probability":null,"wdir":210,"wspd":12,"wgst":null,"visib":5.59,"clouds":[{"cover":"BKN","base":8000,"type":null}],"wxString":"-SHRA","altim":1008,"icgTurb":[],"temp":[{"validTime":1792623600,"surfaceTemp":29,"maxOrMin":"MAX"},{"validTime":1792677600,"surfaceTemp":17,"maxOrMin":"MIN"}],"notDecoded":null}]}"#
        static let knkx = #"{"icaoId":"KNKX","issueTime":"2026-10-21T16:00:00.000Z","validTimeFrom":1792598400,"validTimeTo":1792706400,"rawTAF":"TAF KNKX 211600Z 2116/2222 VRB06KT 9999 SCT016 SCT070 QNH2986INS FM211930 19010G20KT 9999 SCT030 QNH2983INS FM220100 18008KT 9999 BKN030 OVC070 QNH2984INS TEMPO 2205/2209 18006KT 9000 -RA BR OVC012 BECMG 2211/2213 VRB04KT 9999 NSW BKN030 QNH2989INS FM221800 18006G16KT 9999 BKN030 QNH2991INS TX27/2119Z TN17/2214Z","fcsts":[{"timeFrom":1792598400,"timeTo":1792611000,"timeBec":null,"fcstChange":null,"probability":null,"wdir":"VRB","wspd":6,"wgst":null,"visib":"6+","clouds":[{"cover":"SCT","base":1600,"type":null},{"cover":"SCT","base":7000,"type":null}],"wxString":null,"altim":1011,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792611000,"timeTo":1792630800,"timeBec":null,"fcstChange":"FM","probability":null,"wdir":190,"wspd":10,"wgst":20,"visib":"6+","clouds":[{"cover":"SCT","base":3000,"type":null}],"wxString":null,"altim":1010,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792630800,"timeTo":1792666800,"timeBec":null,"fcstChange":"FM","probability":null,"wdir":180,"wspd":8,"wgst":null,"visib":"6+","clouds":[{"cover":"BKN","base":3000,"type":null},{"cover":"OVC","base":7000,"type":null}],"wxString":null,"altim":1011,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792645200,"timeTo":1792659600,"timeBec":null,"fcstChange":"TEMPO","probability":null,"wdir":180,"wspd":6,"wgst":null,"visib":5.59,"clouds":[{"cover":"OVC","base":1200,"type":null}],"wxString":"-RA BR","altim":null,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792666800,"timeTo":1792692000,"timeBec":1792674000,"fcstChange":"BECMG","probability":null,"wdir":"VRB","wspd":4,"wgst":null,"visib":"6+","clouds":[{"cover":"BKN","base":3000,"type":null}],"wxString":"NSW","altim":1012,"icgTurb":[],"temp":[],"notDecoded":null},{"timeFrom":1792692000,"timeTo":1792706400,"timeBec":null,"fcstChange":"FM","probability":null,"wdir":180,"wspd":6,"wgst":16,"visib":"6+","clouds":[{"cover":"BKN","base":3000,"type":null}],"wxString":null,"altim":1013,"icgTurb":[],"temp":[{"validTime":1792609200,"surfaceTemp":27,"maxOrMin":"MAX"},{"validTime":1792677600,"surfaceTemp":17,"maxOrMin":"MIN"}],"notDecoded":null}]}"#
    }

    private func taf(_ json: String, rawTAF: String? = nil) throws -> Taf {
        var data = Data(json.utf8)
        if let rawTAF, var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["rawTAF"] = rawTAF
            data = try JSONSerialization.data(withJSONObject: object)
        }
        return try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: data))
    }

    // Oct 21–22, 2026, hour Z.
    private func z(_ day: Int, _ hour: Int) -> Date {
        Date(timeIntervalSince1970: 1792598400 + TimeInterval((day - 21) * 24 + hour - 16) * 3600)   // 21 16Z
    }

    @Test func kinsParsesEveryGroup() throws {
        let t = try taf(Live.kins)
        #expect(t.forecasts.map(\.type) == [.base, .becmg, .becmg, .tempo, .becmg, .tempo, .becmg, .tempo, .becmg, .becmg])
        #expect(t.forecasts[1].becomingTime == z(21, 17))
        #expect(t.forecasts.allSatisfy { $0.flightCategory == .vfr })            // 9999 → 6+, ceilings ≥ 5,000 ft
        #expect(t.forecasts.first?.wind?.isVariable == true)                      // VRB06KT
        // QNH…INS, TX/TN and 5xxxxx turbulence groups never become weather.
        let wx = t.forecasts.flatMap(\.weatherPhenomena)
        #expect(!wx.contains { $0.contains("QNH") || $0.contains("INS") || $0.hasPrefix("TX") || $0.hasPrefix("TN") || $0.hasPrefix("5") })
        // Wind-only TEMPO (12016G28KT 520009) keeps the prevailing sky and visibility.
        let tempo = t.forecasts[3]
        #expect(tempo.wind?.gust == 28)
        #expect(tempo.visibility == .greaterThan(6))
        #expect(!tempo.clouds.isEmpty)
    }

    @Test func kinsPrevailingFollowsBecmg() throws {
        let t = try taf(Live.kins)
        #expect(t.forecast(at: z(21, 16) + 1800)?.prevailing.type == .base)
        let c = try #require(t.forecast(at: z(21, 17) + 1800))                    // BECMG 2116/2117 complete…
        #expect(c.prevailing.wind?.gust == 15)
        #expect(c.overlays.map(\.type) == [.becmg])                                // …BECMG 2117/2118 under way
        let evening = try #require(t.forecast(at: z(21, 20) + 1800)?.prevailing)  // BECMG 2119/2120 complete
        #expect(ForecastRules.ceilingFeet(evening) == 8000)
        #expect(evening.weatherPhenomena == ["TSRA OMTNS"])
        #expect(t.forecast(at: z(22, 19)) == nil)                                  // validTo 2219
    }

    @Test func omtnsIsOverTheMountainsNotAtTheStation() throws {
        let t = try taf(Live.kins)
        #expect(t.forecasts[4].weatherPhenomena == ["TSRA OMTNS"])   // BECMG 2119/2120 … TSRA OMTNS
        #expect(t.forecasts[6].weatherPhenomena == ["TSRA OMTNS"])   // NOAA carries the TSRA; the qualifier goes with it
        #expect(t.forecasts[8].weatherPhenomena == ["TSRA OMTNS"])
        #expect(t.forecasts[9].weatherPhenomena == ["SHRA OMTNS"])   // BECMG 2214/2215 … SHRA OMTNS
        #expect(t.forecasts[5].weatherPhenomena == ["VCSH"])         // TEMPO VCSH: not qualified
        #expect(WeatherDecoder.decode("TSRA OMTNS") == WeatherDecoder.decode("TSRA") + " over mountains")
        #expect(TafHeroBrief.plainWeather(["TSRA OMTNS"]) == "thunderstorms with rain over mountains")
        // Kept, never dropped: it still counts as convective.
        #expect(TafFormat.hasConvectiveOrHeavy(t.forecasts[4]))
        let hero = TafHeroBrief.build(t, now: z(21, 18) + 1800).map(\.text).joined()
        #expect(hero.contains("becoming thunderstorms with rain over mountains"))
    }

    @Test func omtnsFallsBackToNoaaWhenRawDoesNotLineUp() throws {
        // Without raw groups matching NOAA's periods, NOAA's decode stands: TS at the station (cautious).
        let t = try taf(Live.kins, rawTAF: "TAF KINS raw text unavailable")
        #expect(t.forecasts[4].weatherPhenomena == ["TSRA"])
    }

    @Test func klsvMetricVisibilityAndWindOnlyTempo() throws {
        let t = try taf(Live.klsv)
        #expect(t.forecasts.map(\.type) == [.base, .becmg, .tempo, .becmg, .becmg])
        let last = try #require(t.forecasts.last)                                   // 9000 -SHRA BKN080
        #expect(last.visibility == .exact(5.59))
        #expect(last.flightCategory == .vfr)
        #expect(last.weatherPhenomena == ["-SHRA"])
        #expect(ForecastRules.ceilingFeet(t.forecasts[2]) == 15000)                 // TEMPO keeps BKN150
    }

    @Test func knkxNswEndsTheWeather() throws {
        let t = try taf(Live.knkx)
        #expect(t.forecasts.map(\.type) == [.base, .fm, .fm, .tempo, .becmg, .fm])
        #expect(t.forecasts[3].weatherPhenomena == ["-RA", "BR"])
        #expect(t.forecasts[3].flightCategory == .mvfr)                             // OVC012
        #expect(t.forecasts[4].weatherPhenomena.isEmpty)                            // BECMG … NSW
    }

    @Test func rawChangeGroupsMatchNoaaPeriods() {
        // LFPG 211700Z: PROB30 TEMPO and PROB40 TEMPO are one group each, as NOAA decodes them.
        let lfpg = "TAF LFPG 211700Z 2118/2224 25012KT CAVOK TX15/2215Z TN08/2202Z TEMPO 2207/2213 22015G25KT PROB30 TEMPO 2207/2210 BKN014 PROB40 TEMPO 2213/2219 4000 -RA"
        #expect(TafParser.rawChangeGroups(lfpg).map(\.first) == ["TAF", "TEMPO", "PROB30", "PROB40"])
        // US style: PROB30 without TEMPO, FMddhhmm.
        let kord = "TAF KORD 092215Z 0922/1024 25009KT P6SM SCT035 PROB30 1000/1002 2SM TSRA FM100200 02009KT P6SM VCSH SCT020"
        #expect(TafParser.rawChangeGroups(kord).map(\.first) == ["TAF", "PROB30", "FM100200"])
    }
}
