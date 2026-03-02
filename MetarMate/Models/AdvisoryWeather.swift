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
    var altimeterInHg: Double? {
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
        let pressAltFt = elevFt + 145366.45 * (1.0 - pow(hpa / 1013.25, 0.190284))
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
    var estimatedFlightCategory: FlightCategory {
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

    var windSpeedKtRounded: Int  { Int(windSpeedKt.rounded()) }
    var windGustKtRounded:  Int? { windGustKt.map { Int($0.rounded()) } }

    var cloudCoverDescription: String { AdvisoryWeather.cloudCoverDesc(cloudCoverPercent) }
    var precipDescription:     String { AdvisoryWeather.precipDesc(precipitationMm) }

    var temperatureF:     Double  { temperatureC * 9/5 + 32 }
    var dewpointF:        Double? { dewpointC.map { $0 * 9/5 + 32 } }
    var pressureInHg:     Double? { pressureHpa.map { $0 * 0.02953 } }
    var visibilityMiles:  Double? { visibilityKm.map { $0 * 0.621371 } }

    // MARK: - Static helpers (shared with AdvisoryForecastHour)

    /// Estimates FlightCategory from visibility and cloud cover %.
    /// Cloud cover → ceiling: ≥75% (OVC) ≈ 1500 ft; 50–74% (BKN) ≈ 3000 ft; <50% = no ceiling.
    static func estimateFlightCategory(visibilityKm: Double?, cloudCoverPercent: Int) -> FlightCategory {
        let visMi = visibilityKm.map { $0 * 0.621371 }
        let approxCeilingFt: Int?
        switch cloudCoverPercent {
        case 75...:    approxCeilingFt = 1500
        case 50..<75:  approxCeilingFt = 3000
        default:       approxCeilingFt = nil
        }
        if let v = visMi, v < 1.0                { return .lifr }
        if let c = approxCeilingFt, c < 500      { return .lifr }
        if let v = visMi, v < 3.0                { return .ifr }
        if let c = approxCeilingFt, c < 1000     { return .ifr }
        if let v = visMi, v < 5.0                { return .mvfr }
        if let c = approxCeilingFt, c < 3000     { return .mvfr }
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
