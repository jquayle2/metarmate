import Testing
import Foundation
@testable import MetarMate

// A station that isn't in the bundled airports list is built from NOAA METAR metadata, whose
// `elev` is meters (live, Oct 23 2026: KDEN 1656, KIGM 1045). Airport.elevation is feet.
struct LiveAirportElevationTests {

    private func raw(elev: Int) throws -> RawMetar {
        let json = #"{"icaoId":"KTST","rawOb":"METAR KTST 231551Z 20008KT 10SM CLR 19/13 A2996","name":"Test Field","lat":36.2,"lon":-115.2,"elev":\#(elev)}"#
        return try JSONDecoder().decode(RawMetar.self, from: Data(json.utf8))
    }

    @Test func fallbackAirportElevationIsFeet() throws {
        let airport = AirportService.liveAirport(from: try raw(elev: 1000), stationId: "KTST")
        #expect(airport.elevation == 3281)   // 1,000 m, not 1,000 ft
    }

    /// The DA a fallback airport gets: KIGM's NOAA elev 1045 m is ~3,428 ft, so 19/13 A2996 is
    /// ~4,860 ft DA — not the ~2,400 ft it read with 1,045 taken as feet.
    @Test func fallbackAirportDensityAltitude() throws {
        let airport = AirportService.liveAirport(from: try raw(elev: 1045), stationId: "KIGM")
        let da = try #require(DensityAltitude.calculate(temperatureC: 19, dewpointC: 13, altimeterInHg: 29.96,
                                                        fieldElevationFt: airport.elevation))
        #expect(da.densityAltitudeFt > 4700 && da.densityAltitudeFt < 5000)
    }
}
