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
