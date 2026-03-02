import Foundation

// MARK: - Advisory Weather
// Non-official weather data from Open-Meteo for airports without METAR stations.
// Used for decision-support only — not certified aviation weather.

struct AdvisoryWeather {
    let airport: Airport
    let fetchTime: Date

    let temperatureC: Double
    let dewpointC: Double?
    let windSpeedKt: Double
    let windGustKt: Double?
    let windDirectionDeg: Int?

    let cloudCoverPercent: Int
    let precipitationMm: Double
    let precipitationProbability: Int?

    let pressureHpa: Double?
    let visibilityKm: Double?

    var relativeHumidityPercent: Int? {
        guard let dp = dewpointC else { return nil }
        let rh = 100 * exp((17.625 * dp) / (243.04 + dp)) / exp((17.625 * temperatureC) / (243.04 + temperatureC))
        return Int(rh.rounded())
    }

    var windSpeedKtRounded: Int { Int(windSpeedKt.rounded()) }
    var windGustKtRounded: Int? { windGustKt.map { Int($0.rounded()) } }

    var cloudCoverDescription: String {
        switch cloudCoverPercent {
        case 0...12:  return "SKC"
        case 13...37: return "FEW"
        case 38...62: return "SCT"
        case 63...87: return "BKN"
        default:       return "OVC"
        }
    }

    var precipDescription: String {
        if precipitationMm >= 4.0 { return "Heavy precipitation" }
        if precipitationMm >= 1.0 { return "Moderate precipitation" }
        if precipitationMm >= 0.1 { return "Light precipitation" }
        return "No precipitation"
    }

    var temperatureF: Double { temperatureC * 9/5 + 32 }
    var dewpointF: Double? { dewpointC.map { $0 * 9/5 + 32 } }

    var pressureInHg: Double? { pressureHpa.map { $0 * 0.02953 } }
    var visibilityMiles: Double? { visibilityKm.map { $0 * 0.621371 } }
}
