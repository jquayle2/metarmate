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
    // One density-altitude calculation for the whole app (METAR detail, advisory weather).
    // Humid air is less dense than dry air at the same temperature, so the dewpoint goes in as
    // virtual temperature. Reference: NWS El Paso density-altitude method (Brice & Hall, "Density
    // Altitude", weather.gov/epz/wxcalc_densityaltitude): station pressure from the altimeter
    // setting, vapor pressure from the dewpoint (Tetens), virtual temperature, then
    //   DA = 145442.16 * (1 - (17.326 * P_inHg / Tv_Rankine) ^ 0.235).
    // Ground truth: KIGM 19/13 A2996, field 3,449 ft, Oct 22 2026 -> ForeFlight 4,884 ft; this
    // gives 4,887 ft (the old dry 120 ft/degree rule of thumb gave 4,707).
    // Dry air (vapor pressure 0) only when the dewpoint is missing. Missing temperature or
    // pressure -> nil: no density altitude at all, never one computed off 0 °C or 29.92.

    /// From a METAR: OAT, dewpoint (°C), altimeter setting (inHg) and field elevation (ft MSL).
    static func calculate(
        temperatureC: Double?,
        dewpointC: Double?,
        altimeterInHg: Double?,
        fieldElevationFt: Int
    ) -> DensityAltitudeResult? {
        guard let altimeterInHg else { return nil }
        return calculate(temperatureC: temperatureC, dewpointC: dewpointC,
                         stationPressureHpa: stationPressureHpa(altimeterInHg: altimeterInHg,
                                                                fieldElevationFt: fieldElevationFt),
                         fieldElevationFt: fieldElevationFt)
    }

    /// From station pressure (hPa at field elevation), e.g. Open-Meteo's surface_pressure.
    static func calculate(
        temperatureC: Double?,
        dewpointC: Double?,
        stationPressureHpa: Double?,
        fieldElevationFt: Int
    ) -> DensityAltitudeResult? {
        guard let temperatureC, let p = stationPressureHpa, p > 0 else { return nil }

        // Pressure altitude from station pressure (standard atmosphere).
        let pressureAlt = 145366.45 * (1.0 - pow(p / 1013.25, 0.190284))

        // ISA standard temperature at pressure altitude: 15°C - 2°C per 1000 ft
        let isaTempC = 15.0 - (2.0 * pressureAlt / 1000.0)
        let isaDeviation = temperatureC - isaTempC

        // Virtual temperature: vapor pressure e (hPa) from the dewpoint; 0 when it's missing.
        let e = dewpointC.map { 6.1078 * pow(10.0, 7.5 * $0 / (237.3 + $0)) } ?? 0
        let tvK = (temperatureC + 273.15) / (1.0 - (e / p) * (1.0 - 0.622))
        let pInHg = p / 33.8639
        let densityAlt = 145442.16 * (1.0 - pow(17.326 * pInHg / (tvK * 1.8), 0.235))

        // Normally aspirated power loss via the density-ratio (sigma) model. At WOT with mixture
        // properly leaned, max available power tracks the air-density ratio sigma (mass airflow).
        // Per the ISA troposphere:  sigma = (1 - 6.87535e-6 * DA_ft) ^ 4.2561,  loss = (1 - sigma).
        // Clamp the base to >= 0 (tropopause ~36,089 ft) so extreme/garbage DA never yields NaN.
        // (Turbo/turbocharged engines are much less affected — future enhancement.)
        let sigmaBase = max(0, 1.0 - 6.87535e-6 * densityAlt)
        let sigma = pow(sigmaBase, 4.2561)
        let hpLoss = max(0, (1.0 - sigma) * 100.0)

        // Penalty above field: how much extra DA the pilot "feels" vs just being at elevation
        let penaltyFt = Int(densityAlt.rounded()) - fieldElevationFt

        return DensityAltitudeResult(
            pressureAltitudeFt: Int(pressureAlt.rounded()),
            densityAltitudeFt: Int(densityAlt.rounded()),
            isaDeviationC: isaDeviation,
            hpLossPercent: hpLoss,
            performancePenaltyFt: penaltyFt
        )
    }

    /// Station pressure (hPa) from the altimeter setting and field elevation (NWS formula).
    static func stationPressureHpa(altimeterInHg: Double, fieldElevationFt: Int) -> Double {
        let altHpa = altimeterInHg * 33.8639
        let elevM = Double(fieldElevationFt) * 0.3048
        return pow(pow(altHpa, 0.190263) - 8.417286e-5 * elevM, 1.0 / 0.190263)
    }
}

// Advisory (Open-Meteo) density altitude through the same function. Here rather than in
// AdvisoryWeather.swift because that file is also compiled into the widget, which doesn't
// include this one.
extension AdvisoryWeather {
    /// Density altitude in feet. Open-Meteo `surface_pressure` is station pressure at field elevation.
    /// nil when the field elevation isn't reported (advisory airports are bundled, so it always is).
    var densityAltitudeFt: Double? {
        guard let elevationFt = airport.elevation else { return nil }
        return DensityAltitude.calculate(temperatureC: temperatureC, dewpointC: dewpointC,
                                         stationPressureHpa: pressureHpa,
                                         fieldElevationFt: elevationFt)
            .map { Double($0.densityAltitudeFt) }
    }
}
