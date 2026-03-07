import Foundation

// MARK: - TAF Forecast Period
struct TafForecast: Identifiable, Codable {
    var id = UUID()
    var type: ForecastType
    var fromTime: Date
    var toTime: Date
    var wind: Wind?
    var visibility: Double?
    var clouds: [CloudLayer]
    var weatherPhenomena: [String]
    var flightCategory: FlightCategory

    enum ForecastType: String, Codable {
        case base = "BASE"
        case fm = "FM"
        case tempo = "TEMPO"
        case becmg = "BECMG"
        case prob30 = "PROB30"
        case prob40 = "PROB40"
    }
}

// MARK: - TAF
struct Taf: Identifiable, Codable {
    var id: String { stationId + issueTime.ISO8601Format() }
    var rawText: String
    var stationId: String
    var issueTime: Date
    var validFrom: Date
    var validTo: Date
    var forecasts: [TafForecast]

    var isValid: Bool {
        let now = Date()
        // Valid if active, or starts within 2 hours
        return now <= validTo && (now >= validFrom || validFrom.timeIntervalSinceNow < 7200)
    }

    var currentForecast: TafForecast? {
        let now = Date()
        // Find the base period (FM or BASE) currently active — skip TEMPO/BECMG/PROB overlays
        let basePeriods = forecasts.filter { $0.type == .base || $0.type == .fm }
        if let current = basePeriods.last(where: { $0.fromTime <= now }) {
            return current
        }
        // TAF hasn't started yet — if it begins within 2 hours, use the first base period
        if let first = basePeriods.first, first.fromTime.timeIntervalSinceNow < 7200 {
            return first
        }
        return nil
    }
}
