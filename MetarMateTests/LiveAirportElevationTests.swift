import Testing
import Foundation
@testable import MetarMate

// A station that isn't in the bundled airports list is built from NOAA METAR metadata, whose
// `elev` is meters (live, Oct 23 2026: KDEN 1656, KIGM 1045). Airport.elevation is feet.
// A missing `elev` is "not reported" (nil), never 0 ft.
@MainActor
struct LiveAirportElevationTests {

    private func raw(elev: Int?) throws -> RawMetar {
        let elevField = elev.map { #","elev":\#($0)"# } ?? ""
        let json = #"{"icaoId":"KTST","rawOb":"METAR KTST 231551Z 20008KT 10SM CLR 19/13 A2996","name":"Test Field","lat":36.2,"lon":-115.2\#(elevField)}"#
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
        let elevationFt = try #require(airport.elevation)
        let da = try #require(DensityAltitude.calculate(temperatureC: 19, dewpointC: 13, altimeterInHg: 29.96,
                                                        fieldElevationFt: elevationFt))
        #expect(da.densityAltitudeFt > 4700 && da.densityAltitudeFt < 5000)
    }

    @Test func missingElevIsNotReported() throws {
        #expect(AirportService.liveAirport(from: try raw(elev: nil), stationId: "KTST").elevation == nil)
        #expect(AirportService.liveAirport(from: try raw(elev: 0), stationId: "KTST").elevation == 0)   // reported 0 m stays 0
    }

    // MARK: - Favorites: stored 0 ft

    /// A favorite of a non-bundled airport stored a missing NOAA elevation as 0: it reads back as
    /// not reported. A bundled 0 ft field (KGAO) and any non-zero value are kept.
    @Test func favoriteZeroElevation() {
        let store = AirportService.shared
        #expect(!store.isBundled(icao: "KTST") && store.isBundled(icao: "KGAO"))
        #expect(store.airport(icao: "KGAO")?.elevation == 0)

        let liveZero = AirportFavorite(from: Airport(icao: "KTST", iata: nil, name: "Test", latitude: 36.2,
                                                     longitude: -115.2, elevation: nil))
        #expect(liveZero.elevation == 0)          // storage unchanged: no schema change
        #expect(liveZero.asAirport.elevation == nil)

        let liveKnown = AirportFavorite(from: Airport(icao: "KTST", iata: nil, name: "Test", latitude: 36.2,
                                                      longitude: -115.2, elevation: 2146))
        #expect(liveKnown.asAirport.elevation == 2146)

        let bundledZero = AirportFavorite(from: store.airport(icao: "KGAO")!)
        #expect(bundledZero.asAirport.elevation == 0)
    }

    /// Encoded with no elevation (a cached live airport), decodes back to nil.
    @Test func airportCodableKeepsNotReported() throws {
        let a = Airport(icao: "KTST", iata: nil, name: "Test", latitude: 1, longitude: 2, elevation: nil)
        let back = try JSONDecoder().decode(Airport.self, from: JSONEncoder().encode(a))
        #expect(back.elevation == nil)
    }
}
