import Foundation

// MARK: - TAF Parser
struct TafParser {
    nonisolated static func parse(raw: RawTaf) throws -> Taf {
        guard let icao = raw.icaoId else { throw WeatherError.parseError("Missing station ID") }
        guard let rawText = raw.rawTAF else { throw WeatherError.parseError("Missing raw TAF text") }

        let issueTime: Date
        if let str = raw.issueTime {
            issueTime = parseDate(str) ?? Date()
        } else {
            issueTime = Date()
        }

        let validFrom = raw.validTimeFrom.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? issueTime
        let validTo = raw.validTimeTo.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? issueTime.addingTimeInterval(86400)

        let forecasts = parseForecastPeriods(raw.fcsts ?? [], rawText: rawText)

        return Taf(
            rawText: rawText,
            stationId: icao,
            issueTime: issueTime,
            validFrom: validFrom,
            validTo: validTo,
            forecasts: forecasts
        )
    }

    // MARK: - Parse forecast periods from the fcsts array
    nonisolated private static func parseForecastPeriods(_ fcsts: [[String: AnyCodable]], rawText: String) -> [TafForecast] {
        return fcsts.compactMap { dict -> TafForecast? in
            guard let fromEpoch = dict["timeFrom"]?.value as? Int,
                  let toEpoch = dict["timeTo"]?.value as? Int else { return nil }

            let from = Date(timeIntervalSince1970: TimeInterval(fromEpoch))
            let to = Date(timeIntervalSince1970: TimeInterval(toEpoch))

            let typeStr = dict["fcstType"]?.value as? String ?? "BASE"
            let type = TafForecast.ForecastType(rawValue: typeStr) ?? .base

            let wdir = dict["wdir"]?.value as? String
            let wspd = dict["wspd"]?.value as? Int
            let wgst = dict["wgst"]?.value as? Int
            let wind: Wind? = wspd != nil ? Wind(
                direction: Int(wdir ?? "0"),
                speed: wspd!,
                gust: wgst,
                isVariable: wdir == "VRB"
            ) : nil

            let visStr = dict["visib"]?.value as? String
            let vis = visStr.flatMap { Double($0 == "6+" ? "6" : $0) }

            let cat = FlightCategory(rawValue: dict["flightCategory"]?.value as? String ?? "") ?? .unknown
            let wx = (dict["wxString"]?.value as? String)?.components(separatedBy: " ") ?? []

            return TafForecast(
                type: type,
                fromTime: from,
                toTime: to,
                wind: wind,
                visibility: vis,
                clouds: [],
                weatherPhenomena: wx,
                flightCategory: cat
            )
        }
    }

    nonisolated private static func parseDate(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: str)
    }
}
