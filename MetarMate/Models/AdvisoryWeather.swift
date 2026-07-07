import Foundation

// MARK: - Fog Risk
enum FogRisk: String, Codable {
    case low      = "Low"
    case moderate = "Moderate"
    case high     = "High"

    var sfSymbol: String {
        switch self {
        case .low:      return "sun.max"
        case .moderate: return "cloud.fog"
        case .high:     return "cloud.fog.fill"
        }
    }
}

// MARK: - Advisory Trends (derived from 6-hour history window)
// Uses the existing TrendDirection enum from WeatherTrend.swift.
// Convention: "improving" = better for flight (pressure rising, vis improving, T-D spread widening)
//             "deteriorating" = worse for flight (wind rising, moisture increasing)
struct AdvisoryTrends: Codable {
    let pressure:          TrendDirection   // rising pressure → improving
    let windSpeed:         TrendDirection   // rising wind    → deteriorating
    let tdSpread:          TrendDirection   // rising spread  → improving (drying out)
    let visibility:        TrendDirection   // rising vis     → improving
    let pressureDeltaHpa:  Double?          // hPa change (end − start) over 6h window
    let windDeltaKt:       Double?          // kt change over 6h window
    let tdSpreadDeltaC:    Double?          // °C change over 6h window
    let visibilityDeltaKm: Double?          // km change over 6h window
}

// MARK: - Advisory Forecast Hour
// One entry in the 6-hour ahead hourly array.
struct AdvisoryForecastHour: Codable, Identifiable {
    var id: Date { time }
    let time:               Date
    let temperatureC:       Double
    let dewpointC:          Double?
    let windSpeedKt:        Double
    let windGustKt:         Double?
    let windDirectionDeg:   Int?
    let cloudCoverPercent:  Int
    let precipitationMm:    Double
    let visibilityKm:       Double?
    let pressureHpa:        Double?

    var temperatureF:    Double   { temperatureC * 9/5 + 32 }
    var dewpointF:       Double?  { dewpointC.map { $0 * 9/5 + 32 } }
    var visibilityMiles: Double?  { visibilityKm.map { $0 * 0.621371 } }
    var pressureInHg:    Double?  { pressureHpa.map { $0 * 0.02953 } }
    var windSpeedKtRounded: Int   { Int(windSpeedKt.rounded()) }
    var windGustKtRounded:  Int?  { windGustKt.map { Int($0.rounded()) } }
    /// Gust per METAR/FAA convention — reported only when ≥ 10 kt above the sustained wind.
    var reportableGustKt: Int? {
        guard let g = windGustKtRounded, g - windSpeedKtRounded >= 10 else { return nil }
        return g
    }
    /// Direction snapped to nearest 10° (METAR convention; north = 360, not 000).
    var windDirectionRounded10: Int? {
        windDirectionDeg.map { d in
            let r = ((d + 5) / 10) * 10 % 360
            return r == 0 ? 360 : r
        }
    }
    var cloudCoverDescription: String { AdvisoryWeather.cloudCoverDesc(cloudCoverPercent) }
    var precipDescription:     String { AdvisoryWeather.precipDesc(precipitationMm) }

    var estimatedFlightCategory: FlightCategory {
        AdvisoryWeather.estimateFlightCategory(
            visibilityKm: visibilityKm,
            cloudCoverPercent: cloudCoverPercent
        )
    }
}

// MARK: - Advisory Weather
// Non-official weather from Open-Meteo for airports without METAR stations.
// Provides decision-support context ONLY — NOT certified aviation weather.
struct AdvisoryWeather: Codable {
    let airport:                   Airport
    let fetchTime:                 Date

    // MARK: Current conditions
    let temperatureC:              Double
    let dewpointC:                 Double?
    let windSpeedKt:               Double
    let windGustKt:                Double?
    let windDirectionDeg:          Int?
    let cloudCoverPercent:         Int
    let precipitationMm:           Double
    let precipitationProbability:  Int?
    let pressureHpa:               Double?
    let visibilityKm:              Double?

    // MARK: Derived data
    let trends:   AdvisoryTrends?          // nil when history window unavailable
    let forecast: [AdvisoryForecastHour]   // next 6 hours; may be empty

    // MARK: - Computed aviation values

    /// Altimeter setting (inHg) estimated from station pressure, corrected to sea level.
    nonisolated var altimeterInHg: Double? {
        guard let hpa = pressureHpa else { return nil }
        let elevM = Double(airport.elevation) * 0.3048
        // P₀ = P_station × (1 + 2.25577×10⁻⁵ × h)^5.25588
        let corrected = hpa * pow(1.0 + 0.0000225577 * elevM, 5.25588)
        return corrected * 0.02953
    }

    /// Density altitude in feet, using pressure altitude + ISA temperature correction.
    var densityAltitudeFt: Double? {
        guard let hpa = pressureHpa else { return nil }
        let elevFt   = Double(airport.elevation)
        let stdTempC = 15.0 - (2.0 * elevFt / 1000.0)          // ISA std temp at elevation
        // Open-Meteo `surface_pressure` is station pressure at field elevation, so the
        // barometric formula already yields pressure altitude referenced to sea level —
        // do NOT add elevFt again (that double-counts the field elevation).
        let pressAltFt = 145366.45 * (1.0 - pow(hpa / 1013.25, 0.190284))
        return pressAltFt + 120.0 * (temperatureC - stdTempC)
    }

    /// Fog risk from T-D spread and cloud cover percentage.
    var fogRisk: FogRisk {
        guard let dp = dewpointC else { return .low }
        let spread = temperatureC - dp
        if spread <= 2.0 && cloudCoverPercent >= 75 { return .high }
        if spread <= 4.0 && cloudCoverPercent >= 50 { return .moderate }
        return .low
    }

    /// Heuristic flight category — NOT authoritative. Ceiling approximated from cloud %.
    nonisolated var estimatedFlightCategory: FlightCategory {
        AdvisoryWeather.estimateFlightCategory(
            visibilityKm: visibilityKm,
            cloudCoverPercent: cloudCoverPercent
        )
    }

    // MARK: - Convenience

    var relativeHumidityPercent: Int? {
        guard let dp = dewpointC else { return nil }
        let rh = 100.0 * exp((17.625 * dp) / (243.04 + dp)) /
                         exp((17.625 * temperatureC) / (243.04 + temperatureC))
        return Int(rh.rounded())
    }

    var tdSpreadC: Double? { dewpointC.map { temperatureC - $0 } }

    nonisolated var windSpeedKtRounded: Int  { Int(windSpeedKt.rounded()) }
    nonisolated var windGustKtRounded:  Int? { windGustKt.map { Int($0.rounded()) } }

    /// Gust per METAR/FAA convention — reported only when the peak exceeds the sustained wind
    /// by ≥ 10 kt (peak-to-lull). Open-Meteo always returns a max-instantaneous gust, so below
    /// that threshold it is NOT a reportable gust. nil = no gust.
    nonisolated var reportableGustKt: Int? {
        guard let g = windGustKtRounded, g - windSpeedKtRounded >= 10 else { return nil }
        return g
    }

    /// Advisory wind direction snapped to the nearest 10° (METAR convention;
    /// north shows 360, never 000). Sources like Open-Meteo report to the exact
    /// degree (e.g. 212°), which looks out of place next to real METARs.
    nonisolated var windDirectionRounded10: Int? {
        windDirectionDeg.map { d in
            let r = ((d + 5) / 10) * 10 % 360
            return r == 0 ? 360 : r
        }
    }

    var cloudCoverDescription: String { AdvisoryWeather.cloudCoverDesc(cloudCoverPercent) }
    var precipDescription:     String { AdvisoryWeather.precipDesc(precipitationMm) }

    var temperatureF:     Double  { temperatureC * 9/5 + 32 }
    var dewpointF:        Double? { dewpointC.map { $0 * 9/5 + 32 } }
    var pressureInHg:     Double? { pressureHpa.map { $0 * 0.02953 } }
    nonisolated var visibilityMiles:  Double? { visibilityKm.map { $0 * 0.621371 } }

    // MARK: - Static helpers (shared with AdvisoryForecastHour)

    /// Estimates FlightCategory from visibility and cloud cover %.
    /// Cloud cover % from NWP models is unreliable for ceiling estimation — it can read OVC
    /// in perfectly clear desert conditions due to grid aliasing and orographic effects.
    /// Rule: if visibility is solidly VFR (>=5 SM), visibility wins — cloud cover alone
    /// cannot push the category below VFR. Only use cloud cover when visibility is
    /// marginal or unknown, as a secondary signal.
    nonisolated static func estimateFlightCategory(visibilityKm: Double?, cloudCoverPercent: Int) -> FlightCategory {
        let visMi = visibilityKm.map { $0 * 0.621371 }

        // Visibility check first — most reliable NWP parameter
        if let v = visMi {
            if v < 1.0 { return .lifr }
            if v < 3.0 { return .ifr }
            if v < 5.0 { return .mvfr }
            // Vis >=5 SM = solidly VFR. Cloud cover % from NWP is too unreliable
            // to push below VFR when visibility confirms clear conditions.
            return .vfr
        }

        // No visibility data — fall back to cloud cover heuristic only
        let approxCeilingFt: Int?
        switch cloudCoverPercent {
        case 75...:    approxCeilingFt = 1500
        case 50..<75:  approxCeilingFt = 3000
        default:       approxCeilingFt = nil
        }
        if let c = approxCeilingFt, c < 500  { return .lifr }
        if let c = approxCeilingFt, c < 1000 { return .ifr }
        if let c = approxCeilingFt, c < 3000 { return .mvfr }
        return .vfr
    }

    static func cloudCoverDesc(_ pct: Int) -> String {
        switch pct {
        case 0...12:  return "SKC"
        case 13...37: return "FEW"
        case 38...62: return "SCT"
        case 63...87: return "BKN"
        default:       return "OVC"
        }
    }

    static func precipDesc(_ mm: Double) -> String {
        if mm >= 4.0 { return "Heavy precipitation" }
        if mm >= 1.0 { return "Moderate precipitation" }
        if mm >= 0.1 { return "Light precipitation" }
        return "No precipitation"
    }
}
