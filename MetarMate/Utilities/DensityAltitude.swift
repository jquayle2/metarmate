import Foundation

// MARK: - Density Altitude Calculator
// All the math a pilot actually needs for performance planning.

struct DensityAltitudeResult {
    let pressureAltitudeFt: Int
    let densityAltitudeFt: Int
    let isaDeviationC: Double       // OAT minus ISA standard temp at that altitude
    let hpLossPercent: Double       // normally aspirated engine power loss vs sea level std day
    let performancePenaltyFt: Int   // DA above field elevation (the extra DA penalty)

    // Human-readable strings
    var densityAltitudeText: String {
        "\(densityAltitudeFt.formatted()) ft MSL"
    }

    var isaDeviationText: String {
        let sign = isaDeviationC >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", isaDeviationC))°C ISA"
    }

    var hpLossText: String {
        String(format: "~%.0f%% power loss", hpLossPercent)
    }

    var penaltyText: String {
        let sign = performancePenaltyFt >= 0 ? "+" : ""
        return "\(sign)\(performancePenaltyFt.formatted()) ft above field"
    }

    var summary: String {
        if densityAltitudeFt < 2000 && abs(isaDeviationC) < 10 {
            return "Performance near normal. Standard day conditions."
        } else if hpLossPercent < 10 {
            return "Slight performance reduction. Check POH for your aircraft."
        } else if hpLossPercent < 20 {
            return "Noticeable performance reduction. Verify takeoff/climb performance."
        } else {
            return "Significant performance reduction. Carefully verify POH limits before flight."
        }
    }
}

struct DensityAltitude {
    /// Calculate density altitude given METAR data and airport field elevation.
    /// - Parameters:
    ///   - temperatureC: OAT in Celsius from METAR
    ///   - dewpointC: Dewpoint in Celsius from METAR
    ///   - altimeterInHg: Altimeter setting in inHg from METAR
    ///   - fieldElevationFt: Airport field elevation in feet MSL
    static func calculate(
        temperatureC: Double,
        dewpointC: Double,
        altimeterInHg: Double,
        fieldElevationFt: Int
    ) -> DensityAltitudeResult {

        // Pressure altitude = field elevation + 1000 * (29.92 - altimeter)
        let pressureAlt = Double(fieldElevationFt) + 1000.0 * (29.92 - altimeterInHg)

        // ISA standard temperature at pressure altitude: 15°C - 2°C per 1000 ft
        let isaTempC = 15.0 - (2.0 * pressureAlt / 1000.0)

        // ISA deviation
        let isaDeviation = temperatureC - isaTempC

        // Density altitude = pressure altitude + 120 * (OAT - ISA temp)
        let densityAlt = pressureAlt + 120.0 * isaDeviation

        // Normally aspirated HP loss: ~3% per 1000 ft DA above sea level
        // (turbo/turbocharged engines are much less affected — future enhancement)
        let hpLoss = max(0, densityAlt / 1000.0 * 3.0)

        // Penalty above field: how much extra DA the pilot "feels" vs just being at elevation
        let penaltyFt = Int(densityAlt) - fieldElevationFt

        return DensityAltitudeResult(
            pressureAltitudeFt: Int(pressureAlt.rounded()),
            densityAltitudeFt: Int(densityAlt.rounded()),
            isaDeviationC: isaDeviation,
            hpLossPercent: hpLoss,
            performancePenaltyFt: penaltyFt
        )
    }
}
