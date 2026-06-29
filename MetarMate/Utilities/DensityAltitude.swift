import Foundation

// MARK: - Density Altitude severity (single source of truth)
// One band definition keyed to ABSOLUTE density altitude (feet), used everywhere:
// color, icon, the section visibility gate, and Performance auto-expand. Keep these in
// one place so they are trivially tunable.
//
// Color scale (LOCKED — wind-axis discipline; this is a labeled performance metric, NOT
// flight category and NOT go/no-go):
//   green  < AMBER_DA_FT
//   amber  AMBER_DA_FT ..< RED_DA_FT
//   red    >= RED_DA_FT
// Bands are on ABSOLUTE density altitude in feet, NOT the penalty above field. The HP-loss %
// shown elsewhere is a normally-aspirated estimate, informational only, and does NOT drive color.
// This DELIBERATELY replaces the old HP-loss 10/20/30 scale.

let AMBER_DA_FT = 5000   // ~light-aircraft performance gets marginal (AOPA/FAA anchor)
let RED_DA_FT   = 8000   // ~30% power loss territory for normally-aspirated singles

enum DASeverity { case green, amber, red }

func daSeverity(densityAltitudeFt: Int) -> DASeverity {
    if densityAltitudeFt >= RED_DA_FT   { return .red }
    if densityAltitudeFt >= AMBER_DA_FT { return .amber }
    return .green
}

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

    /// Estimated takeoff roll increase as a percentage vs sea level standard day.
    /// Uses rule of thumb: every 10% power loss ≈ 20% longer ground roll.
    /// Formula: (1.2 ^ (hpLoss/10) - 1) * 100, rounded to nearest 5%.
    /// Only meaningful at orange/red (20%+ loss) — below that, POH numbers cover it.
    var takeoffRollIncreasePercent: Int? {
        guard hpLossPercent >= 20 else { return nil }
        let raw = (pow(1.2, hpLossPercent / 10.0) - 1.0) * 100.0
        return Int((raw / 5.0).rounded() * 5)
    }

    var takeoffRollText: String? {
        guard let pct = takeoffRollIncreasePercent else { return nil }
        return "Est. takeoff roll ~+\(pct)% vs std day"
    }

    var penaltyText: String {
        let sign = performancePenaltyFt >= 0 ? "+" : ""
        return "\(sign)\(performancePenaltyFt.formatted()) ft above field"
    }

    var summary: String {
        if densityAltitudeFt < 2000 && abs(isaDeviationC) < 10 {
            return "Performance near normal. Standard day conditions."
        } else if hpLossPercent < 10 {
            return "Minor performance reduction. Check POH for your aircraft."
        } else if hpLossPercent < 20 {
            return "Noticeable reduction. Verify takeoff distance and climb rate."
        } else if hpLossPercent < 30 {
            return "Significant reduction. Density altitude briefing required. Review POH limits carefully."
        } else {
            return "Severe performance penalty. Aircraft may be near or beyond performance limits. Do not depart without thorough POH analysis."
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
