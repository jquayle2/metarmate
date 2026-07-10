import Foundation

// MARK: - TAF Forecast Period
struct TafForecast: Identifiable, Codable {
    var id = UUID()
    var type: ForecastType
    var fromTime: Date
    var toTime: Date
    var wind: Wind?
    var visibility: Visibility   // .exact / .greaterThan (P6SM/P10SM) / .unknown — see Visibility
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

    // Base/FM periods only — the ones rendered as decoded plain-English blocks.
    // Same filtering as currentForecast; does not alter its semantics.
    var baseForecasts: [TafForecast] {
        forecasts.filter { $0.type == .base || $0.type == .fm }
    }

    // TEMPO/BECMG/PROB overlays — surfaced in TAF Pilot Notes, not in the period blocks.
    var overlayForecasts: [TafForecast] {
        forecasts.filter { $0.type == .tempo || $0.type == .becmg || $0.type == .prob30 || $0.type == .prob40 }
    }
}
