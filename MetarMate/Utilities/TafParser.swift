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

        let forecasts = parseForecastPeriods(raw.fcsts ?? [])

        return Taf(
            rawText: rawText,
            stationId: icao,
            issueTime: issueTime,
            validFrom: validFrom,
            validTo: validTo,
            forecasts: forecasts
        )
    }

    // MARK: - Parse forecast periods
    nonisolated private static func parseForecastPeriods(_ fcsts: [[String: AnyCodable]]) -> [TafForecast] {
        return fcsts.compactMap { dict -> TafForecast? in
            guard let fromEpoch = dict["timeFrom"]?.value as? Int,
                  let toEpoch = dict["timeTo"]?.value as? Int else { return nil }

            let from = Date(timeIntervalSince1970: TimeInterval(fromEpoch))
            let to = Date(timeIntervalSince1970: TimeInterval(toEpoch))

            // API uses "fcstChange" not "fcstType"
            let typeStr = dict["fcstChange"]?.value as? String
            let type: TafForecast.ForecastType
            if let typeStr = typeStr, let parsed = TafForecast.ForecastType(rawValue: typeStr) {
                type = parsed
            } else {
                type = .base
            }

            // Wind — wdir can be Int or String ("VRB")
            let wind = parseWind(dict)

            // Visibility
            let vis = parseVisibility(dict)

            // Clouds — API returns full cloud data in TAF forecasts
            let clouds = parseClouds(dict)

            // Calculate flight category from visibility and ceiling
            let cat = calculateFlightCategory(visibility: vis, clouds: clouds)

            // Weather phenomena
            let wx = (dict["wxString"]?.value as? String)?.components(separatedBy: " ").filter { !$0.isEmpty } ?? []

            return TafForecast(
                type: type,
                fromTime: from,
                toTime: to,
                wind: wind,
                visibility: vis,
                clouds: clouds,
                weatherPhenomena: wx,
                flightCategory: cat
            )
        }
    }

    // MARK: - Wind parsing (handles Int or String wdir)
    nonisolated private static func parseWind(_ dict: [String: AnyCodable]) -> Wind? {
        guard let wspd = dict["wspd"]?.value as? Int else { return nil }
        let wgst = dict["wgst"]?.value as? Int

        guard let wdirValue = dict["wdir"]?.value else {
            return Wind(direction: 0, speed: wspd, gust: wgst, isVariable: false)
        }

        if let dirString = wdirValue as? String {
            if dirString == "VRB" {
                return Wind(direction: nil, speed: wspd, gust: wgst, isVariable: true)
            }
            return Wind(direction: Int(dirString) ?? 0, speed: wspd, gust: wgst, isVariable: false)
        }

        if let dirInt = wdirValue as? Int {
            return Wind(direction: dirInt, speed: wspd, gust: wgst, isVariable: false)
        }

        if let dirDouble = wdirValue as? Double {
            return Wind(direction: Int(dirDouble), speed: wspd, gust: wgst, isVariable: false)
        }

        return Wind(direction: 0, speed: wspd, gust: wgst, isVariable: false)
    }

    // MARK: - Visibility parsing
    nonisolated private static func parseVisibility(_ dict: [String: AnyCodable]) -> Double? {
        guard let value = dict["visib"]?.value else { return nil }
        if let str = value as? String {
            if str == "6+" || str == "P6SM" { return 6.0 }
            if str == "10+" { return 10.0 }
            return Double(str)
        }
        if let num = value as? Double { return num }
        if let num = value as? Int { return Double(num) }
        return nil
    }

    // MARK: - Cloud parsing (base in feet from API, store as hundreds)
    nonisolated private static func parseClouds(_ dict: [String: AnyCodable]) -> [CloudLayer] {
        guard let cloudsValue = dict["clouds"]?.value else { return [] }

        // The clouds field is an array of dicts, but comes through AnyCodable
        // We need to handle it as an array of [String: Any]
        guard let cloudsArray = cloudsValue as? [[String: Any]] else { return [] }

        // Indefinite ceiling: TAF carries it as cover "OVX" / a top-level vertVis field (hundreds
        // of feet), same as METAR — map OVX onto .verticalVisibility so it becomes a real ceiling.
        let vertVis = dict["vertVis"]?.value as? Int

        return cloudsArray.compactMap { cloud -> CloudLayer? in
            guard let coverStr = cloud["cover"] as? String else { return nil }
            let coverKey = (coverStr == "OVX") ? "VV" : coverStr
            guard let coverage = CloudCoverage(rawValue: coverKey) else { return nil }

            var altitudeHundreds = 0
            if let base = cloud["base"] as? Int {
                altitudeHundreds = base / 100
            } else if let base = cloud["base"] as? Double {
                altitudeHundreds = Int(base) / 100
            } else if coverage == .verticalVisibility, let vv = vertVis {
                altitudeHundreds = vv
            }

            let typeStr = cloud["type"] as? String ?? ""
            return CloudLayer(coverage: coverage, altitude: altitudeHundreds, isCumulonimbus: typeStr == "CB")
        }
    }

    nonisolated private static func parseDate(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    // MARK: - Flight category from visibility + ceiling
    nonisolated private static func calculateFlightCategory(visibility: Double?, clouds: [CloudLayer]) -> FlightCategory {
        let vis = visibility ?? 10.0

        // Ceiling = lowest BKN, OVC, or VV layer (FEW/SCT don't count)
        let ceilingFeet: Int? = clouds
            .first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
            .map { $0.altitude * 100 }

        // LIFR: ceiling < 500 OR visibility < 1
        if let ceil = ceilingFeet, ceil < 500 { return .lifr }
        if vis < 1.0 { return .lifr }

        // IFR: ceiling 500-999 OR visibility 1-2.99
        if let ceil = ceilingFeet, ceil < 1000 { return .ifr }
        if vis < 3.0 { return .ifr }

        // MVFR: ceiling 1000-3000 OR visibility 3-5
        if let ceil = ceilingFeet, ceil <= 3000 { return .mvfr }
        if vis <= 5.0 { return .mvfr }

        // VFR: ceiling > 3000 AND visibility > 5
        return .vfr
    }
}
