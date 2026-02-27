import Foundation

// MARK: - METAR Parser
// Parses raw aviationweather.gov JSON responses into Metar structs
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
        let phenomena = parseWeatherPhenomena(rawText)

        let temp = Int(raw.temp ?? 0)
        let dewp = Int(raw.dewp ?? 0)
        let altim = raw.altim ?? 29.92

        let category = FlightCategory(rawValue: raw.flightCategory ?? "") ?? .unknown

        return Metar(
            rawText: rawText,
            stationId: icao,
            observationTime: obsTime,
            wind: wind,
            visibility: visibility,
            clouds: clouds,
            temperature: temp,
            dewpoint: dewp,
            altimeter: altim,
            flightCategory: category,
            weatherPhenomena: phenomena
        )
    }

    // MARK: - Private helpers
    nonisolated private static func parseWind(wdir: String?, wspd: Int?, wgst: Int?) -> Wind {
        let speed = wspd ?? 0
        let gust = wgst
        if wdir == "VRB" {
            return Wind(direction: nil, speed: speed, gust: gust, isVariable: true)
        }
        let dir = Int(wdir ?? "0") ?? 0
        return Wind(direction: dir, speed: speed, gust: gust, isVariable: false)
    }

    nonisolated private static func parseVisibility(_ vis: String?) -> Double {
        guard let vis = vis else { return 10.0 }
        if vis == "10+" { return 10.0 }
        return Double(vis) ?? 10.0
    }

    nonisolated private static func parseClouds(_ clouds: [[String: AnyCodable]]?) -> [CloudLayer] {
        guard let clouds = clouds else { return [] }
        return clouds.compactMap { dict -> CloudLayer? in
            guard let coverageStr = dict["cover"]?.value as? String,
                  let coverage = CloudCoverage(rawValue: coverageStr) else { return nil }
            let altitude = dict["base"]?.value as? Int ?? 0
            let cbStr = dict["cloudType"]?.value as? String ?? ""
            return CloudLayer(coverage: coverage, altitude: altitude, isCumulonimbus: cbStr == "CB")
        }
    }

    nonisolated private static func parseWeatherPhenomena(_ raw: String) -> [String] {
        let wxCodes = ["TS", "RA", "SN", "GR", "BR", "FG", "HZ", "DU", "SA",
                       "FC", "SQ", "SS", "DS", "FU", "VA", "PL", "GS", "IC", "UP"]
        let tokens = raw.components(separatedBy: " ")
        return tokens.filter { token in
            wxCodes.contains(where: { token.contains($0) }) &&
            !token.hasPrefix("A") && !token.hasPrefix("Q")
        }
    }
}
