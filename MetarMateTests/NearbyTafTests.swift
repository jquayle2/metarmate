import Testing
import Foundation
@testable import MetarMate

// Nearby-TAF lookup and selection (D#13–17), against the live `taf?bbox=` response around KBVU from
// Oct 21, 2026 (lat,lon order; trimmed to each TAF's first period). Reference distances/bearings were
// computed independently (haversine, R = 3440.065 nm): KHND 13.44 nm 274.8°, KLAS 16.58 nm 296.9°,
// KLSV 19.31 nm 333.9°, KVGT 22.75 nm 314.5°, KIFP 50.10 nm 163.0°, KINS 55.59 nm 313.9°.
@MainActor
struct NearbyTafTests {

    private static let liveBbox = #"[{"icaoId":"KLAS","name":"Las Vegas/Reid Intl","lat":36.07188,"lon":-115.16343,"elev":662,"issueTime":"2026-10-21T17:28:00.000Z","validTimeFrom":1792605600,"validTimeTo":1792713600,"rawTAF":"TAF KLAS 211728Z 2118/2224 12008KT P6SM FEW080 FEW120 FM212100 12012G2","fcsts":[{"timeFrom":1792605600,"timeTo":1792616400,"wdir":120,"wspd":8,"visib":"6+","clouds":[{"cover":"FEW","base":8000,"type":null},{"cover":"FEW","base":12000,"type":null}]}]},{"icaoId":"KVGT","name":"Las Vegas/North Arpt","lat":36.21205,"lon":-115.19396,"elev":664,"issueTime":"2026-10-21T17:28:00.000Z","validTimeFrom":1792605600,"validTimeTo":1792692000,"rawTAF":"TAF KVGT 211728Z 2118/2218 10007KT P6SM FEW080 FEW120 FM212000 11011KT","fcsts":[{"timeFrom":1792605600,"timeTo":1792612800,"wdir":100,"wspd":7,"visib":"6+","clouds":[{"cover":"FEW","base":8000,"type":null},{"cover":"FEW","base":12000,"type":null}]}]},{"icaoId":"KIFP","name":"Bullhead City Intl","lat":35.14871,"lon":-114.561067,"elev":210,"issueTime":"2026-10-21T17:28:00.000Z","validTimeFrom":1792605600,"validTimeTo":1792692000,"rawTAF":"TAF KIFP 211728Z 2118/2218 16007KT P6SM SCT100 FM211900 18015G25KT P6S","fcsts":[{"timeFrom":1792605600,"timeTo":1792609200,"wdir":160,"wspd":7,"visib":"6+","clouds":[{"cover":"SCT","base":10000,"type":null}]}]},{"icaoId":"KHND","name":"Henderson Exec","lat":35.96575,"lon":-115.13433,"elev":740,"issueTime":"2026-10-21T17:28:00.000Z","validTimeFrom":1792605600,"validTimeTo":1792692000,"rawTAF":"TAF KHND 211728Z 2118/2218 15011KT P6SM FEW080 FEW100 FM212000 16016G2","fcsts":[{"timeFrom":1792605600,"timeTo":1792612800,"wdir":150,"wspd":11,"visib":"6+","clouds":[{"cover":"FEW","base":8000,"type":null},{"cover":"FEW","base":10000,"type":null}]}]},{"icaoId":"KINS","name":"Indian Springs/Creech AFB","lat":36.586,"lon":-115.69,"elev":954,"issueTime":"2026-10-21T16:20:00.000Z","validTimeFrom":1792598400,"validTimeTo":1792695600,"rawTAF":"TAF AMD KINS 211620Z 2116/2219 VRB06KT 9999 FEW120 QNH2992INS BECMG 21","fcsts":[{"timeFrom":1792598400,"timeTo":1792695600,"wdir":"VRB","wspd":6,"visib":"6+","clouds":[{"cover":"FEW","base":12000,"type":null}]}]},{"icaoId":"KLSV","name":"Nellis AFB","lat":36.236,"lon":-115.034,"elev":563,"issueTime":"2026-10-21T15:00:00.000Z","validTimeFrom":1792594800,"validTimeTo":1792702800,"rawTAF":"TAF KLSV 211500Z 2115/2221 09012KT 9999 FEW080 SCT150 QNH2989INS BECMG","fcsts":[{"timeFrom":1792594800,"timeTo":1792609200,"wdir":90,"wspd":12,"visib":"6+","clouds":[{"cover":"FEW","base":8000,"type":null},{"cover":"SCT","base":15000,"type":null}]}]}]"#

    private static let kbvu = (lat: 35.947161, lon: -114.858799, elevFt: 2146)
    private static let kvgt = (lat: 36.209074, lon: -115.193982, elevFt: 2205)
    private let now = Date(timeIntervalSince1970: 1792609200)   // Oct 21, 2026 19Z — every live TAF current

    private func live() throws -> [NearbyTafCandidate] {
        WeatherService.tafCandidates(from: try JSONDecoder().decode([RawTaf].self, from: Data(Self.liveBbox.utf8)))
    }

    private func only(_ ids: Set<String>, _ cs: [NearbyTafCandidate]) -> [NearbyTafCandidate] {
        cs.filter { ids.contains($0.taf.stationId) }
    }

    /// The same candidate with its TAF's validity moved.
    private func moved(_ c: NearbyTafCandidate, from: Date? = nil, to: Date? = nil, issued: Date? = nil) -> NearbyTafCandidate {
        var taf = c.taf
        if let from { taf.validFrom = from }
        if let to { taf.validTo = to }
        if let issued { taf.issueTime = issued }
        return NearbyTafCandidate(taf: taf, latitude: c.latitude, longitude: c.longitude, elevationMeters: c.elevationMeters, name: c.name)
    }

    private func select(_ cs: [NearbyTafCandidate], field: (lat: Double, lon: Double, elevFt: Int) = kbvu,
                        excluding: Set<String> = ["KBVU"]) -> (taf: Taf, source: TafSource)? {
        NearbyTaf.select(from: cs, fieldLatitude: field.lat, fieldLongitude: field.lon, fieldElevationFt: field.elevFt,
                         excluding: excluding, at: now)
    }

    // MARK: - Selection

    @Test func kbvuBorrowsKhnd13nmWest() throws {
        let pick = try #require(select(try live()))
        #expect(pick.taf.stationId == "KHND")
        #expect(pick.source == TafSource(stationId: "KHND", name: "Henderson Exec", distanceNm: 13, bearing: "W",
                                         elevationDifferenceFt: 2428 - 2146, isBorrowed: true))
    }

    @Test func distanceAndBearingMatchReference() {
        let nm = NearbyTaf.distanceNm(Self.kbvu.lat, Self.kbvu.lon, 35.96575, -115.13433)
        #expect(abs(nm - 13.437) < 0.01)
        let deg = NearbyTaf.bearingDegrees(Self.kbvu.lat, Self.kbvu.lon, 35.96575, -115.13433)
        #expect(abs(deg - 274.8) < 0.1)
    }

    @Test func fiftyNmCap() throws {
        let cs = try live()
        // KIFP 50.10 nm rounds to 50: in. KINS 55.59 nm: out.
        let kifp = try #require(select(only(["KIFP"], cs)))
        #expect(kifp.source.distanceNm == 50)
        #expect(kifp.source.bearing == "S")
        #expect(select(only(["KINS"], cs)) == nil)
        // Straight north of KBVU: 50.4 nm rounds to 50 (in), 50.6 nm to 51 (out).
        let base = try #require(only(["KHND"], cs).first)
        func north(_ nm: Double) -> NearbyTafCandidate {
            NearbyTafCandidate(taf: base.taf, latitude: Self.kbvu.lat + nm * 180 / (.pi * 3440.065), longitude: Self.kbvu.lon,
                               elevationMeters: base.elevationMeters, name: base.name)
        }
        #expect(select([north(50.4)])?.source.distanceNm == 50)
        #expect(select([north(50.6)]) == nil)
    }

    @Test func noTafWithinFiftyNm() throws {
        #expect(select([]) == nil)
        #expect(select(only(["KINS"], try live())) == nil)
    }

    @Test func expiredTafIsExcluded() throws {
        let cs = try live().map { $0.taf.stationId == "KHND" ? moved($0, to: now - 60) : $0 }
        #expect(select(cs)?.source.stationId == "KLAS")   // next nearest, 17 nm NW
        #expect(select(cs)?.source.distanceNm == 17)
        #expect(select(cs)?.source.bearing == "NW")
    }

    @Test func candidateStartingWithinTwoHoursIsEligible() throws {
        // Issued ahead of its validity (KVGT 1728Z valid 1800Z): counts as current, same as the field's own.
        let soon = try live().map { $0.taf.stationId == "KHND" ? moved($0, from: now + 1800) : $0 }
        #expect(select(soon)?.source.stationId == "KHND")
        // Starting in 3 hours isn't current yet.
        let later = try live().map { $0.taf.stationId == "KHND" ? moved($0, from: now + 3 * 3600) : $0 }
        #expect(select(later)?.source.stationId == "KLAS")
    }

    @Test func fieldNeverBorrowsItself() throws {
        // KVGT's own TAF is in the box; it's excluded, and KLSV (7.9 nm E) beats KLAS (8.4 nm S).
        let pick = try #require(select(try live(), field: Self.kvgt, excluding: ["KVGT"]))
        #expect(pick.source.stationId == "KLSV")
        #expect(pick.source.distanceNm == 8)
        #expect(pick.source.bearing == "E")
    }

    @Test func latestIssuedTafPerStation() throws {
        let khnd = try #require(only(["KHND"], try live()).first)
        let older = moved(khnd, issued: khnd.taf.issueTime - 3600)
        var amended = khnd.taf
        amended.rawText = "TAF AMD KHND"
        let newer = NearbyTafCandidate(taf: amended, latitude: khnd.latitude, longitude: khnd.longitude,
                                       elevationMeters: khnd.elevationMeters, name: khnd.name)
        #expect(select([newer, older])?.taf.rawText == "TAF AMD KHND")
        #expect(select([older, newer])?.taf.rawText == "TAF AMD KHND")
    }

    @Test func unknownStationElevationIsNil() throws {
        let khnd = try #require(only(["KHND"], try live()).first)
        let noElev = NearbyTafCandidate(taf: khnd.taf, latitude: khnd.latitude, longitude: khnd.longitude,
                                        elevationMeters: nil, name: khnd.name)
        #expect(select([noElev])?.source.elevationDifferenceFt == nil)
    }

    // MARK: - Whether to borrow

    @Test func ownTafStartingWithinTwoHoursIsNotBorrowed() throws {
        let own = try #require(only(["KHND"], try live()).first).taf
        var soon = own
        soon.validFrom = now + 1800                               // issued 30 min before its validity
        #expect(NearbyTaf.needsBorrow(.found(soon), at: now) == false)
        #expect(NearbyTaf.needsBorrow(.found(own), at: now) == false)
        var expired = own
        expired.validTo = now - 60
        #expect(NearbyTaf.needsBorrow(.found(expired), at: now) == true)   // expired own TAF: borrow
        #expect(NearbyTaf.needsBorrow(.none, at: now) == true)
        #expect(NearbyTaf.needsBorrow(.failed, at: now) == false)          // never on a failed request
    }

    @Test func ownTafOutcomeFromTheRequest() {
        func isNone(_ o: NearbyTaf.OwnTaf) -> Bool { if case .none = o { return true }; return false }
        func isFailed(_ o: NearbyTaf.OwnTaf) -> Bool { if case .failed = o { return true }; return false }
        #expect(isNone(NearbyTaf.outcome(of: .failure(WeatherError.noContent))))   // 204
        #expect(isNone(NearbyTaf.outcome(of: .failure(WeatherError.noData))))      // 200 with []
        #expect(isFailed(NearbyTaf.outcome(of: .failure(URLError(.timedOut)))))
        #expect(isFailed(NearbyTaf.outcome(of: .failure(WeatherError.httpStatus(503)))))
    }

    // MARK: - Resolve: own TAF, borrowed, none, unavailable

    private final class Calls { var count = 0 }
    private var kbvuField: (ids: Set<String>, latitude: Double, longitude: Double, elevationFt: Int) {
        (["KBVU"], Self.kbvu.lat, Self.kbvu.lon, Self.kbvu.elevFt)
    }

    @Test func ownCurrentTafWinsWithoutALookup() async throws {
        let cs = try live()
        let own = try #require(only(["KHND"], cs).first).taf   // stands in for a field's own current TAF
        let calls = Calls()
        let r = await NearbyTaf.resolve(own: .found(own), field: kbvuField, at: now) { calls.count += 1; return cs }
        #expect(r.status == .own)
        #expect(r.taf?.stationId == "KHND")
        #expect(calls.count == 0)   // a TAF that appears replaces the borrowed one on the next refresh
    }

    @Test func noOwnTafBorrowsNearest() async throws {
        let cs = try live()
        let r = await NearbyTaf.resolve(own: .none, field: kbvuField, at: now) { cs }
        #expect(r.taf?.stationId == "KHND")
        guard case .borrowed(let source, let ownExpired) = r.status else { Issue.record("not borrowed"); return }
        #expect(source.distanceNm == 13 && source.bearing == "W")
        #expect(ownExpired == false)
    }

    @Test func expiredOwnTafBorrowsAndSaysSo() async throws {
        let cs = try live()
        var expired = try #require(only(["KLAS"], cs).first).taf
        expired.validTo = now - 60
        let r = await NearbyTaf.resolve(own: .found(expired), field: kbvuField, at: now) { cs }
        #expect(r.status.isBorrowed)
        if case .borrowed(let source, let ownExpired) = r.status {
            #expect(ownExpired)
            #expect(NearbyTaf.substitutionLine(fieldId: "KBVU", source: source, ownExpired: ownExpired)
                    == "No current TAF for KBVU · using KHND (13 nm W)")
        }
    }

    @Test func failedRequestOrLookupNeverBorrows() async throws {
        let cs = try live()
        let calls = Calls()
        let failed = await NearbyTaf.resolve(own: .failed, field: kbvuField, at: now) { calls.count += 1; return cs }
        #expect(failed.taf == nil)
        #expect(failed.status == .unavailable)
        #expect(calls.count == 0)
        let lookupFailed = await NearbyTaf.resolve(own: .none, field: kbvuField, at: now) { throw URLError(.timedOut) }
        #expect(lookupFailed.taf == nil)
        #expect(lookupFailed.status == .unavailable)
        let noPosition = await NearbyTaf.resolve(own: .none, field: nil, at: now) { calls.count += 1; return cs }
        #expect(noPosition.status == .unavailable)
        #expect(calls.count == 0)
    }

    @Test func nothingWithinFiftyNm() async throws {
        let kins = only(["KINS"], try live())
        let r = await NearbyTaf.resolve(own: .none, field: kbvuField, at: now) { kins }
        #expect(r.taf == nil)
        #expect(r.status == .noneWithin50nm(ownExpired: false))
    }

    // MARK: - Lookup cache (~10 min per field)

    @Test func candidateCacheKeepsTenMinutes() throws {
        let cs = try live()
        var cache = NearbyTafCandidateCache()
        cache.store(cs, for: "KBVU", at: now)
        #expect(cache.candidates(for: "KBVU", at: now + 5 * 60)?.count == cs.count)    // the 5-min refresh: no new request
        #expect(cache.candidates(for: "KBVU", at: now + 599)?.count == cs.count)
        #expect(cache.candidates(for: "KBVU", at: now + 600) == nil)
        #expect(cache.candidates(for: "KVGT", at: now) == nil)                          // per field
        cache.removeAll()                                                               // pull-to-refresh
        #expect(cache.candidates(for: "KBVU", at: now) == nil)
    }

    // MARK: - Wording (D#14, D#17)

    private func source(_ nm: Int, elevation: Int? = nil) -> TafSource {
        TafSource(stationId: "KHND", name: nil, distanceNm: nm, bearing: "W", elevationDifferenceFt: elevation, isBorrowed: true)
    }

    @Test func substitutionLine() {
        #expect(NearbyTaf.substitutionLine(fieldId: "KBVU", source: source(13), ownExpired: false)
                == "No TAF for KBVU · using KHND (13 nm W)")
        let emphasized = NearbyTaf.substitutionParts(fieldId: "KBVU", source: source(13), ownExpired: false)
            .filter(\.emphasized).map(\.text)
        #expect(emphasized == ["No TAF for KBVU", "KHND"])
    }

    @Test func distanceTiersAtTheBoundaries() {
        #expect(NearbyTaf.cautions(for: source(10)) == [])
        #expect(NearbyTaf.cautions(for: source(11)) == ["TAF site 11 nm away. Local conditions may differ."])
        #expect(NearbyTaf.cautions(for: source(25)) == ["TAF site 25 nm away. Local conditions may differ."])
        #expect(NearbyTaf.cautions(for: source(26)) == ["TAF site 26 nm away. Conditions here may be quite different."])
        #expect(NearbyTaf.cautions(for: source(50)) == ["TAF site 50 nm away. Conditions here may be quite different."])
    }

    @Test func elevationCaution() {
        #expect(NearbyTaf.cautions(for: source(5, elevation: 999)) == [])
        #expect(NearbyTaf.cautions(for: source(5, elevation: -999)) == [])
        #expect(NearbyTaf.cautions(for: source(5, elevation: 1000)) == ["TAF site is 1,000 ft higher."])
        // KIFP from KBVU: 1,457 ft lower, 50 nm — both cautions.
        #expect(NearbyTaf.cautions(for: source(50, elevation: -1457))
                == ["TAF site 50 nm away. Conditions here may be quite different.", "TAF site is 1,500 ft lower."])
    }

    @Test func heroNamesABorrowedStation() throws {
        let khnd = try #require(only(["KHND"], try live()).first).taf
        let segs = TafHeroBrief.build(khnd, now: now, stationLabel: "KHND")
        #expect(segs.first == HeroSegment(text: "KHND forecasts ", color: Brand.slate))
        #expect(TafHeroBrief.build(khnd, now: now).first?.text.hasPrefix("KHND") == false)
    }

    // A borrowed TAF's hero says what the site forecasts and never "now": "VFR now" in green under
    // an IFR badge reads as this field's conditions (KBCE IFR, KCDC forecast VFR, Oct 21).
    @Test func borrowedHeroNeverSaysNow() throws {
        let t0 = 1792605600   // Oct 21, 2026 18Z
        func e(_ h: Double) -> Int { t0 + Int(h * 3600) }
        let at = Date(timeIntervalSince1970: TimeInterval(t0) + 1800)
        func taf(_ fcsts: String) throws -> Taf {
            let json = #"{"icaoId":"KCDC","issueTime":"2026-10-21T17:20:00.000Z","validTimeFrom":\#(e(0)),"validTimeTo":\#(e(24)),"rawTAF":"synthetic","fcsts":[\#(fcsts)]}"#
            return try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        }
        let vfr = #"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":320,"wspd":6,"visib":"6+","clouds":[{"cover":"BKN","base":6000}]}"#
        // KCDC 211720Z shape: VFR base + PROB30 -TSRA OVC060CB.
        let kcdc = try taf(vfr + "," + #"{"timeFrom":\#(e(1)),"timeTo":\#(e(6)),"fcstChange":"PROB","probability":30,"wdir":"VRB","wspd":15,"wgst":30,"visib":6,"wxString":"-TSRA","clouds":[{"cover":"OVC","base":6000,"type":"CB"}]}"#)
        let hero = TafHeroBrief.build(kcdc, now: at, stationLabel: "KCDC").map(\.text).joined()
        #expect(hero.hasPrefix("KCDC forecasts VFR, but PROB30 thunderstorms with light rain "))

        // Every hero shape, borrowed: told as the site's forecast, no "now".
        let ifr = #"{"timeFrom":\#(e(0)),"timeTo":\#(e(6)),"wdir":200,"wspd":6,"visib":2,"clouds":[{"cover":"OVC","base":800}]}"#
        let shapes: [Taf] = [
            kcdc,
            try taf(vfr),                                                                         // steady
            try taf(ifr + "," + #"{"timeFrom":\#(e(6)),"timeTo":\#(e(24)),"fcstChange":"FM","wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]}"#),   // improving
            try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(6)),"wdir":200,"wspd":6,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]},"# + #"{"timeFrom":\#(e(6)),"timeTo":\#(e(24)),"fcstChange":"FM","wdir":200,"wspd":6,"visib":2,"clouds":[{"cover":"OVC","base":800}]}"#),   // worsening
            try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":15,"wgst":25,"visib":"6+","clouds":[{"cover":"SCT","base":5000}]}"#),   // gusty
            try taf(#"{"timeFrom":\#(e(0)),"timeTo":\#(e(24)),"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":700}]}"#),   // lower bound
        ]
        for t in shapes {
            let text = TafHeroBrief.build(t, now: at, stationLabel: "KCDC").map(\.text).joined()
            #expect(text.hasPrefix("KCDC forecasts "), "\(text)")
            #expect(!text.contains(" now"), "\(text)")
            #expect(!text.contains("KCDC forecasts At"), "\(text)")   // "at least", lowercase after "forecasts"
        }
        #expect(TafHeroBrief.build(shapes[5], now: at, stationLabel: "KCDC").map(\.text).joined()
                .hasPrefix("KCDC forecasts at least IFR the entire forecast period."))
        // The field's own TAF keeps "now".
        #expect(TafHeroBrief.build(kcdc, now: at).map(\.text).joined().hasPrefix("VFR now, but PROB30"))
    }

    // MARK: - Verification and trend against the TAF station's own METARs (D#15)

    // KHND TAF from 18Z: VFR until 21Z, then FM IFR (OVC008). KHND reports VFR (no ceiling); KBVU
    // reports IFR (OVC008) — so comparing with the wrong field's METAR gives different answers.
    private let t18 = 1792605600
    private func khndTaf() throws -> Taf {
        let json = #"{"icaoId":"KHND","issueTime":"2026-10-21T17:20:00.000Z","validTimeFrom":\#(t18),"validTimeTo":\#(t18 + 86400),"rawTAF":"synthetic","fcsts":[{"timeFrom":\#(t18),"timeTo":\#(t18 + 10800),"wdir":150,"wspd":11,"visib":"6+","clouds":[{"cover":"FEW","base":8000}]},{"timeFrom":\#(t18 + 10800),"timeTo":\#(t18 + 86400),"fcstChange":"FM","wdir":160,"wspd":16,"visib":2,"clouds":[{"cover":"OVC","base":800}]}]}"#
        return try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
    }
    private func metar(_ id: String, minutesBeforeNow: Int, ifr: Bool) throws -> Metar {
        let obs = 1792609200 - minutesBeforeNow * 60
        let wx = ifr ? #""visib":2,"clouds":[{"cover":"OVC","base":800}],"fltCat":"IFR""# : #""visib":10,"clouds":[{"cover":"FEW","base":8000}],"fltCat":"VFR""#
        let json = #"{"icaoId":"\#(id)","obsTime":\#(obs),"temp":20,"dewp":5,"wdir":150,"wspd":10,"altim":1013,"rawOb":"METAR \#(id) synthetic",\#(wx)}"#
        return try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }
    private var borrowedKhnd: TafStatus {
        .borrowed(TafSource(stationId: "KHND", name: nil, distanceNm: 13, bearing: "W", elevationDifferenceFt: 282, isBorrowed: true), ownExpired: false)
    }

    @Test func borrowedTafIsVerifiedAgainstItsOwnStation() throws {
        let field = [try metar("KBVU", minutesBeforeNow: 0, ifr: true), try metar("KBVU", minutesBeforeNow: 30, ifr: true)]
        let station = [try metar("KHND", minutesBeforeNow: 0, ifr: false), try metar("KHND", minutesBeforeNow: 30, ifr: false)]
        let d = NearbyTaf.derive(fieldHistory: field, taf: try khndTaf(), status: borrowedKhnd, stationHistory: station, at: now)

        // Accuracy/deviation: KHND forecast vs KHND actual (VFR vs VFR), not KBVU's IFR.
        let v = try #require(d.verification)
        #expect(v.points.map(\.actualCategory) == [.vfr])
        #expect(v.categoryAccuracyPct == 100)

        // Forecast trend: KHND now (no ceiling) vs the FM OVC008 → ceiling deteriorating. Against
        // KBVU's OVC008 it would read steady.
        #expect(d.trend.forecast.ceiling == .deteriorating)
        #expect(d.trend.forecast.forecastCategory == .ifr)
        // The observed half stays this field's.
        #expect(d.trend.observed.metarCount == 2)

        // Widget snapshot: the same results; the widget names the station (borrowedTafStation).
        #expect(d.snapshotTrend.forecast.ceiling == .deteriorating)
        #expect(d.snapshotVerification?.categoryAccuracyPct == 100)
    }

    // KBCE (Oct 21): ceiling 3,900 → 700 ft here; KCDC, 45 nm away, reports and forecasts VFR. The
    // summary must not read "deteriorating but expected to stabilize" as if it were one place.
    @Test func borrowedTrendNeverBlendsHereWithTheTafSite() throws {
        func ob(_ id: String, _ minutesAgo: Int, ceiling: Int, cat: String) throws -> Metar {
            let json = #"{"icaoId":"\#(id)","obsTime":\#(1792609200 - minutesAgo * 60),"temp":8,"dewp":7,"wdir":150,"wspd":5,"visib":5,"altim":1013,"rawOb":"METAR \#(id) synthetic","clouds":[{"cover":"OVC","base":\#(ceiling)}],"fltCat":"\#(cat)"}"#
            return try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
        }
        let kbce = [try ob("KBCE", 0, ceiling: 700, cat: "IFR"), try ob("KBCE", 60, ceiling: 2000, cat: "MVFR"),
                    try ob("KBCE", 120, ceiling: 3900, cat: "VFR")]
        let kcdcJSON = #"{"icaoId":"KCDC","issueTime":"2026-10-21T17:20:00.000Z","validTimeFrom":\#(t18),"validTimeTo":\#(t18 + 86400),"rawTAF":"synthetic","fcsts":[{"timeFrom":\#(t18),"timeTo":\#(t18 + 86400),"wdir":320,"wspd":6,"visib":"6+","clouds":[{"cover":"BKN","base":6000}]}]}"#
        let kcdcTaf = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(kcdcJSON.utf8)))
        let kcdcNow = try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(
            #"{"icaoId":"KCDC","obsTime":1792608900,"temp":15,"dewp":2,"wdir":320,"wspd":6,"visib":"10+","altim":1013,"rawOb":"METAR KCDC synthetic","clouds":[{"cover":"BKN","base":6000}],"fltCat":"VFR"}"#.utf8)))
        let status = TafStatus.borrowed(TafSource(stationId: "KCDC", name: nil, distanceNm: 45, bearing: "W",
                                                  elevationDifferenceFt: -2003, isBorrowed: true), ownExpired: false)
        let d = NearbyTaf.derive(fieldHistory: kbce, taf: kcdcTaf, status: status, stationHistory: [kcdcNow], at: now)

        #expect(d.trend.observed.overall == .deteriorating)
        #expect(d.trend.forecast.overall == .steady)
        #expect(d.trend.summaryText == "Conditions here have been deteriorating. KCDC's forecast is steady.")
        #expect(d.trend.forecast.summaryText == "KCDC forecasts conditions to be steady for the current period.")
        #expect(d.trend.overall == .deteriorating)
        // The station's forecast never makes it look better here: steady here + KCDC improving stays steady.
        #expect(!d.trend.summaryText.contains("expected"))
        // Own TAF: the blended wording is unchanged.
        #expect(WeatherTrend.derive(metars: kbce, taf: kcdcTaf, forecastMetar: kcdcNow, now: now).summaryText
                == "Conditions have been deteriorating but are expected to stabilize.")
        // Period rows: "current" for a borrowed TAF, "now" for the field's own.
        #expect(TafFormat.currentPeriodTag(tafIsUpcoming: false, borrowed: true) == "current")
        #expect(TafFormat.currentPeriodTag(tafIsUpcoming: false, borrowed: false) == "now")
        #expect(TafFormat.currentPeriodTag(tafIsUpcoming: true, borrowed: true) == "next")
    }

    @Test func borrowedForecastNeverImprovesTheOverallTrend() throws {
        // Steady here, KHND's forecast improving (IFR now there → VFR later): overall stays steady.
        let field = [try metar("KBVU", minutesBeforeNow: 0, ifr: false), try metar("KBVU", minutesBeforeNow: 30, ifr: false)]
        let json = #"{"icaoId":"KHND","issueTime":"2026-10-21T17:20:00.000Z","validTimeFrom":\#(t18),"validTimeTo":\#(t18 + 86400),"rawTAF":"synthetic","fcsts":[{"timeFrom":\#(t18),"timeTo":\#(t18 + 10800),"wdir":160,"wspd":16,"visib":2,"clouds":[{"cover":"OVC","base":800}]},{"timeFrom":\#(t18 + 10800),"timeTo":\#(t18 + 86400),"fcstChange":"FM","wdir":150,"wspd":8,"visib":7,"clouds":[{"cover":"FEW","base":8000}]}]}"#
        let improving = try TafParser.parse(raw: JSONDecoder().decode(RawTaf.self, from: Data(json.utf8)))
        let station = [try metar("KHND", minutesBeforeNow: 0, ifr: true)]
        let d = NearbyTaf.derive(fieldHistory: field, taf: improving, status: borrowedKhnd, stationHistory: station, at: now)
        #expect(d.trend.forecast.overall == .improving)
        #expect(d.trend.observed.overall != .improving)
        #expect(d.trend.overall == d.trend.observed.overall)
    }

    @Test func borrowedTafWithoutStationReportsNeverUsesThisField() throws {
        let field = [try metar("KBVU", minutesBeforeNow: 0, ifr: true), try metar("KBVU", minutesBeforeNow: 30, ifr: true)]
        let d = NearbyTaf.derive(fieldHistory: field, taf: try khndTaf(), status: borrowedKhnd, stationHistory: [], at: now)
        #expect(d.verification == nil)
        #expect(d.trend.forecast.overall == .unknown)
    }

    @Test func ownTafIsVerifiedAgainstThisField() throws {
        let field = [try metar("KHND", minutesBeforeNow: 0, ifr: true), try metar("KHND", minutesBeforeNow: 30, ifr: true)]
        let d = NearbyTaf.derive(fieldHistory: field, taf: try khndTaf(), status: .own, stationHistory: [], at: now)
        #expect(d.verification?.points.map(\.actualCategory) == [.ifr])
        #expect(d.trend.forecast.ceiling == .steady)            // field OVC008 vs FM OVC008
        #expect(d.snapshotVerification?.categoryAccuracyPct == d.verification?.categoryAccuracyPct)
    }

    // MARK: - Widget and Siri (D#14: same wording)

    private func widgetSnapshot(headline: String = "Deterioration Forecast") throws -> WidgetWeatherSnapshot {
        let raw = try JSONDecoder().decode(RawMetar.self, from: Data(#"{"obsTime":1792608900,"icaoId":"KBVU","rawOb":"METAR KBVU 211855Z 17015G21KT 10SM FEW060 29/12 A2992","visib":"10+","wdir":170,"wspd":15,"wgst":21,"fltCat":"VFR"}"#.utf8))
        let base = try #require(WidgetWeatherSnapshot.from(rawMetar: raw, icao: "KBVU"))
        return WidgetWeatherSnapshot(
            icao: base.icao, iata: base.iata, airportName: base.airportName, flightCategory: base.flightCategory,
            windDirection: base.windDirection, windSpeed: base.windSpeed, windGust: base.windGust,
            windIsVariable: base.windIsVariable, visibility: base.visibility, ceilingFeet: base.ceilingFeet,
            temperature: base.temperature, dewpoint: base.dewpoint, altimeter: base.altimeter,
            trendDirection: .deteriorating, trendHeadline: headline, tafAccuracyPct: 78,
            borrowedTafStation: "KHND", borrowedTafLine: "No TAF for KBVU · using KHND (13 nm W)",
            forecastWindDivergenceKt: nil, forecastCeilingDivergenceFt: nil, forecastVisibilityDivergenceSM: nil,
            isAdvisory: false, observationTime: base.observationTime, snapshotTime: base.snapshotTime)
    }

    @Test func widgetNamesTheBorrowedStation() throws {
        let borrowed = try widgetSnapshot()
        #expect(borrowed.trendHeadlineLabeled == "Deterioration Forecast · KHND TAF")
        #expect(try widgetSnapshot(headline: "Wind Increasing (+13 kt)").trendHeadlineLabeled == "Wind Increasing (+13 kt)")
        var own = borrowed
        own.borrowedTafStation = nil
        #expect(own.trendHeadlineLabeled == "Deterioration Forecast")
    }

    @Test func widgetMergeKeepsBorrowedLabelsOnlyForTheSameObservation() throws {
        let cached = try widgetSnapshot()
        let same = WidgetWeatherSnapshot.merge(live: cached, cached: cached)
        #expect(same.borrowedTafStation == "KHND")
        #expect(same.borrowedTafLine == "No TAF for KBVU · using KHND (13 nm W)")
        let newerRaw = try JSONDecoder().decode(RawMetar.self, from: Data(#"{"obsTime":1792612500,"icaoId":"KBVU","rawOb":"METAR KBVU 211955Z 17012KT 10SM FEW060 28/12 A2991","visib":"10+","wdir":170,"wspd":12,"fltCat":"VFR"}"#.utf8))
        let newer = WidgetWeatherSnapshot.merge(live: try #require(WidgetWeatherSnapshot.from(rawMetar: newerRaw, icao: "KBVU")), cached: cached)
        #expect(newer.borrowedTafStation == nil)
        #expect(newer.tafAccuracyPct == nil)
    }

    @Test func olderSnapshotsWithoutBorrowedFieldsStillDecode() throws {
        let data = try JSONEncoder().encode(try widgetSnapshot())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["borrowedTafStation"] = nil
        object["borrowedTafLine"] = nil
        let decoded = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.borrowedTafStation == nil)
        #expect(decoded.tafAccuracyPct == 78)
    }

    @Test func siriSaysWhereTheForecastComesFrom() {
        let khnd = TafSource(stationId: "KHND", name: "Henderson Exec", distanceNm: 13, bearing: "W", elevationDifferenceFt: 282, isBorrowed: true)
        #expect(NearbyTaf.spokenBorrowedForecast(fieldName: "Boulder City Municipal", stationName: "Henderson Executive",
                                                 source: khnd, ownExpired: false, conditions: "steady")
                == "There's no TAF for Boulder City Municipal. The forecast from Henderson Executive, 13 miles west, shows conditions steady.")
        #expect(NearbyTaf.spokenBorrowedForecast(fieldName: "Boulder City Municipal", stationName: "Henderson Executive",
                                                 source: khnd, ownExpired: true, conditions: "deteriorating")
                .hasPrefix("There's no current TAF for Boulder City Municipal."))
        let one = TafSource(stationId: "KXYZ", name: nil, distanceNm: 1, bearing: "NW", elevationDifferenceFt: nil, isBorrowed: true)
        #expect(NearbyTaf.spokenBorrowedForecast(fieldName: "A", stationName: "B", source: one, ownExpired: false, conditions: "steady")
                .contains("B, 1 mile northwest, shows"))
    }

    // The full Siri answer: report age per D#4 first, then the borrowed sentence only where the
    // forecast is voiced (no observed trend); with an observed trend, nothing about any TAF.
    @Test func siriDialogNamesTheBorrowedForecastAfterTheReportAge() throws {
        let m = try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(#"{"obsTime":1792608900,"icaoId":"KBVU","rawOb":"METAR KBVU 211855Z 17015G21KT 10SM FEW060 29/12 A2992","visib":"10+","wdir":170,"wspd":15,"wgst":21,"clouds":[{"cover":"FEW","base":6000}],"fltCat":"VFR"}"#.utf8)))
        let khnd = TafSource(stationId: "KHND", name: "Henderson Exec", distanceNm: 13, bearing: "W", elevationDifferenceFt: 282, isBorrowed: true)
        let borrowed = (source: khnd, ownExpired: false, stationName: "Henderson Executive")
        let at = m.observationTime.addingTimeInterval(16 * 60)
        var trend = WeatherTrend.derive(metars: [m], taf: nil, now: at)
        #expect(trend.observed.overall == .unknown)
        trend.forecast.overall = .deteriorating
        let spoken = SiriReportWording.dialog(airportName: "Boulder City Municipal", metar: m, trend: trend, borrowed: borrowed, at: at)
        #expect(spoken.hasPrefix("As of 16 minutes ago, Boulder City Municipal is VFR."))
        #expect(spoken.hasSuffix("There's no TAF for Boulder City Municipal. The forecast from Henderson Executive, 13 miles west, shows conditions deteriorating."))
        #expect(!spoken.contains("Forecast shows"))

        trend.observed.overall = .steady
        let observed = SiriReportWording.dialog(airportName: "Boulder City Municipal", metar: m, trend: trend, borrowed: borrowed, at: at)
        #expect(!observed.contains("TAF") && !observed.contains("Henderson"))
    }

    // MARK: - Units and geometry

    @Test func elevationMetersToFeet() {
        #expect(NearbyTaf.feet(fromMeters: 662) == 2172)   // KLAS
        #expect(NearbyTaf.feet(fromMeters: 740) == 2428)   // KHND
    }

    @Test func compassSectors() {
        #expect(NearbyTaf.compass8(0) == "N")
        #expect(NearbyTaf.compass8(22.4) == "N")
        #expect(NearbyTaf.compass8(22.5) == "NE")
        #expect(NearbyTaf.compass8(292.4) == "W")
        #expect(NearbyTaf.compass8(337.5) == "N")
        #expect(NearbyTaf.compass8(359.9) == "N")
    }

    @Test func boundingBoxIsLatLonCovering50nm() {
        #expect(NearbyTaf.boundingBox(latitude: Self.kbvu.lat, longitude: Self.kbvu.lon) == "35.1138,-115.8882,36.7805,-113.8294")
    }
}
