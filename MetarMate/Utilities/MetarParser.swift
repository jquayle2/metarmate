import Foundation

// MARK: - METAR Parser
// Parses aviationweather.gov JSON responses into Metar structs
struct MetarParser {
    nonisolated static func parse(raw: RawMetar) throws -> Metar {
        guard let icao = raw.icaoId else { throw WeatherError.parseError("Missing station ID") }
        guard let rawText = raw.rawOb else { throw WeatherError.parseError("Missing raw METAR text") }

        let obsTime: Date
        if let epoch = raw.obsTime {
            obsTime = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else {
            obsTime = Date()
        }

        let wind = parseWind(wdir: raw.wdir, wspd: raw.wspd, wgst: raw.wgst)
        let visibility = parseVisibility(raw.visib)
        let clouds = parseClouds(raw.clouds)
        let phenomena = parseWeatherPhenomena(raw.wxString, rawOb: rawText)

        let temp = Int(raw.temp ?? 0)
        let dewp = Int(raw.dewp ?? 0)

        // API returns altim in hPa — convert to inHg
        let altimInHg: Double
        if let hpa = raw.altim {
            altimInHg = hpa * 0.02953
        } else {
            altimInHg = 29.92
        }

        // API uses "fltCat" field
        let category = FlightCategory(rawValue: raw.fltCat ?? "") ?? .unknown

        return Metar(
            rawText: rawText,
            stationId: icao,
            observationTime: obsTime,
            wind: wind,
            visibility: visibility,
            clouds: clouds,
            temperature: temp,
            dewpoint: dewp,
            altimeter: altimInHg,
            flightCategory: category,
            weatherPhenomena: phenomena
        )
    }

    // MARK: - Wind
    // API returns wdir as Int (degrees) or String ("VRB")
    nonisolated private static func parseWind(wdir: AnyCodable?, wspd: Int?, wgst: Int?) -> Wind {
        let speed = wspd ?? 0
        let gust = wgst

        guard let wdirValue = wdir?.value else {
            return Wind(direction: 0, speed: speed, gust: gust, isVariable: false)
        }

        if let dirString = wdirValue as? String {
            if dirString == "VRB" {
                return Wind(direction: nil, speed: speed, gust: gust, isVariable: true)
            }
            let dir = Int(dirString) ?? 0
            return Wind(direction: dir, speed: speed, gust: gust, isVariable: false)
        }

        if let dirInt = wdirValue as? Int {
            return Wind(direction: dirInt, speed: speed, gust: gust, isVariable: false)
        }

        if let dirDouble = wdirValue as? Double {
            return Wind(direction: Int(dirDouble), speed: speed, gust: gust, isVariable: false)
        }

        return Wind(direction: 0, speed: speed, gust: gust, isVariable: false)
    }

    // MARK: - Visibility
    // API returns visib as String ("10+", "6") or sometimes a number
    nonisolated private static func parseVisibility(_ vis: AnyCodable?) -> Double {
        guard let value = vis?.value else { return 10.0 }

        if let str = value as? String {
            if str == "10+" || str == "P6SM" { return 10.0 }
            if str == "6+" { return 6.0 }
            return Double(str) ?? 10.0
        }
        if let num = value as? Double { return num }
        if let num = value as? Int { return Double(num) }
        return 10.0
    }

    // MARK: - Clouds
    // API returns base in feet AGL (e.g. 25000), not hundreds
    nonisolated private static func parseClouds(_ clouds: [[String: AnyCodable]]?) -> [CloudLayer] {
        guard let clouds = clouds else { return [] }
        return clouds.compactMap { dict -> CloudLayer? in
            guard let coverageStr = dict["cover"]?.value as? String,
                  let coverage = CloudCoverage(rawValue: coverageStr) else { return nil }

            // API gives base in feet; CloudLayer stores hundreds of feet
            var altitudeHundreds = 0
            if let base = dict["base"]?.value as? Int {
                altitudeHundreds = base / 100
            } else if let base = dict["base"]?.value as? Double {
                altitudeHundreds = Int(base) / 100
            }

            let typeStr = dict["type"]?.value as? String ?? ""
            return CloudLayer(coverage: coverage, altitude: altitudeHundreds, isCumulonimbus: typeStr == "CB")
        }
    }

    // MARK: - Weather Phenomena
    // Prefer the wxString field from the API; fall back to parsing rawOb
    nonisolated private static func parseWeatherPhenomena(_ wxString: String?, rawOb: String) -> [String] {
        if let wx = wxString, !wx.isEmpty {
            return wx.components(separatedBy: " ").filter { !$0.isEmpty }
        }

        // Fallback: scan raw METAR for known wx codes
        let wxCodes = ["TS", "RA", "SN", "GR", "BR", "FG", "HZ", "DU", "SA",
                       "FC", "SQ", "SS", "DS", "FU", "VA", "PL", "GS", "IC",
                       "UP", "DZ", "SG", "FZRA", "FZDZ", "FZFG"]
        let tokens = rawOb.components(separatedBy: " ")
        return tokens.filter { token in
            let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            return wxCodes.contains(where: { clean.contains($0) }) &&
                   !token.hasPrefix("A") && !token.hasPrefix("Q") && !token.hasPrefix("RMK")
        }
    }
}
