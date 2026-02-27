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
        return now >= validFrom && now <= validTo
    }

    var currentForecast: TafForecast? {
        let now = Date()
        return forecasts.last(where: { $0.fromTime <= now })
    }
}
