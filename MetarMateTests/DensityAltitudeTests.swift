import Testing
import Foundation
@testable import MetarMate

// Density altitude: one shared function, humid (virtual temperature from the dewpoint), dry only
// when the dewpoint is missing, nil when temperature or pressure is missing. Method: NWS El Paso
// density-altitude calculation (Brice & Hall, weather.gov/epz/wxcalc_densityaltitude).
struct DensityAltitudeTests {

    // MARK: - ForeFlight ground truth (table-driven; add rows as samples come in)

    /// One observed case: METAR temp/dewpoint (°C), altimeter (inHg), field elevation (ft) and
    /// the density altitude ForeFlight showed for it at the time.
    struct ForeFlightSample: CustomTestStringConvertible {
        let station: String
        let date: String
        let tempC: Double
        let dewpointC: Double
        let altimeterInHg: Double
        let elevationFt: Int
        let foreFlightFt: Int
        var testDescription: String { "\(station) \(date)" }
    }

    static let foreFlightSamples: [ForeFlightSample] = [
        // KIGM 19/13 A2996, field 3,449 ft (Oct 22 2026, Jeff). Old dry formula showed 4,706.
        ForeFlightSample(station: "KIGM", date: "2026-10-22", tempC: 19, dewpointC: 13,
                         altimeterInHg: 29.96, elevationFt: 3449, foreFlightFt: 4884),
    ]

    @Test(arguments: foreFlightSamples)
    func matchesForeFlight(_ s: ForeFlightSample) throws {
        let da = try #require(DensityAltitude.calculate(temperatureC: s.tempC, dewpointC: s.dewpointC,
                                                        altimeterInHg: s.altimeterInHg,
                                                        fieldElevationFt: s.elevationFt))
        #expect(abs(da.densityAltitudeFt - s.foreFlightFt) <= 30,
                "\(s.station): \(da.densityAltitudeFt) ft vs ForeFlight \(s.foreFlightFt) ft")
    }

    // MARK: - Standard atmosphere (ICAO ISA: 15 °C, 29.92 inHg at sea level, -1.98 °C/1000 ft)

    @Test func isaSeaLevelDryIsZero() throws {
        let da = try #require(DensityAltitude.calculate(temperatureC: 15, dewpointC: nil,
                                                        altimeterInHg: 29.92, fieldElevationFt: 0))
        #expect(abs(da.densityAltitudeFt) <= 30)
        #expect(abs(da.pressureAltitudeFt) <= 5)
    }

    @Test func isaAt5000FtDryEqualsPressureAltitude() throws {
        let da = try #require(DensityAltitude.calculate(temperatureC: 15 - 1.98 * 5, dewpointC: nil,
                                                        altimeterInHg: 29.92, fieldElevationFt: 5000))
        #expect(abs(da.pressureAltitudeFt - 5000) <= 10)
        #expect(abs(da.densityAltitudeFt - 5000) <= 30)
    }

    // MARK: - Hot and dry

    /// KLAS-type summer day, 42/-5 A2990, field 2,181 ft. FAA rule of thumb (PHAK FAA-H-8083-25C
    /// ch. 4: PA + 120 ft per °C above ISA) gives 5,969 ft; the rule runs a few hundred feet high in
    /// heat, so this only bounds it. The point: it's ~5,800 ft amber, not the ~900 ft a 0 °C
    /// default produced (audit #8).
    @Test func hotDryDay() throws {
        let da = try #require(DensityAltitude.calculate(temperatureC: 42, dewpointC: -5,
                                                        altimeterInHg: 29.90, fieldElevationFt: 2181))
        #expect(da.densityAltitudeFt > 5500 && da.densityAltitudeFt <= 5969)
        #expect(daSeverity(densityAltitudeFt: da.densityAltitudeFt) == .amber)
    }

    // MARK: - Missing inputs

    /// No dewpoint: dry air, which is denser, so a lower DA than the same day with KIGM's humidity.
    @Test func dewpointMissingUsesDryAir() throws {
        let dry = try #require(DensityAltitude.calculate(temperatureC: 19, dewpointC: nil,
                                                         altimeterInHg: 29.96, fieldElevationFt: 3449))
        let humid = try #require(DensityAltitude.calculate(temperatureC: 19, dewpointC: 13,
                                                           altimeterInHg: 29.96, fieldElevationFt: 3449))
        #expect(dry.densityAltitudeFt < humid.densityAltitudeFt)
        #expect(abs(dry.densityAltitudeFt - 4677) <= 5)
    }

    @Test func temperatureMissingIsNil() {
        #expect(DensityAltitude.calculate(temperatureC: nil, dewpointC: 13,
                                          altimeterInHg: 29.96, fieldElevationFt: 3449) == nil)
    }

    @Test func altimeterMissingIsNil() {
        #expect(DensityAltitude.calculate(temperatureC: 19, dewpointC: 13,
                                          altimeterInHg: nil, fieldElevationFt: 3449) == nil)
    }

    /// The advisory path (Open-Meteo station pressure) goes through the same function: feeding it
    /// the station pressure the METAR path derives gives the same answer.
    @Test func stationPressurePathMatchesAltimeterPath() throws {
        let p = DensityAltitude.stationPressureHpa(altimeterInHg: 29.96, fieldElevationFt: 3449)
        let a = try #require(DensityAltitude.calculate(temperatureC: 19, dewpointC: 13,
                                                       altimeterInHg: 29.96, fieldElevationFt: 3449))
        let b = try #require(DensityAltitude.calculate(temperatureC: 19, dewpointC: 13,
                                                       stationPressureHpa: p, fieldElevationFt: 3449))
        #expect(a.densityAltitudeFt == b.densityAltitudeFt)
    }
}
