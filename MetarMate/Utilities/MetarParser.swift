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
    // Filter out remark codes that aren't actual weather
    nonisolated private static func parseWeatherPhenomena(_ wxString: String?, rawOb: String) -> [String] {
        let raw: [String]
        if let wx = wxString, !wx.isEmpty {
            raw = wx.components(separatedBy: " ").filter { !$0.isEmpty }
        } else {
            // Match a real METAR present-weather group, not a substring. A group is:
            //   optional intensity (+ / - / VC), then either a descriptor followed by one or
            //   more phenomena codes, or bare phenomena, or a standalone TS/SH (e.g. "TS",
            //   "VCTS", "VCSH") — and nothing else.
            // A substring scan is unsafe: the station ident alone would match (KSNA contains
            // "SN" -> phantom "Snow"; KICT -> "Ice Crystals"; KBGR -> "Hail"; ~556 idents affected).
            let phen = "(DZ|RA|SN|SG|IC|PL|GR|GS|UP|BR|FG|FU|VA|DU|SA|HZ|PY|PO|SQ|FC|SS|DS)"
            let desc = "(MI|PR|BC|DR|BL|SH|TS|FZ)"
            let pattern = "^(\\+|-|VC)?(\(desc)\(phen)+|\(phen)+|TS|SH)$"
            let regex = try? NSRegularExpression(pattern: pattern)
            // Present weather appears in the body only — never scan the remarks section.
            let body = rawOb.components(separatedBy: " RMK").first ?? rawOb
            let tokens = body.components(separatedBy: " ").filter { !$0.isEmpty }
            raw = tokens.filter { token in
                let upper = token.uppercased()
                // A bare descriptor/intensity with no phenomena isn't a weather group.
                guard let regex = regex else { return false }
                let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
                return regex.firstMatch(in: upper, range: range) != nil
            }
        }

        // Filter out remark-type codes that aren't actual weather phenomena
        let remarkCodes: Set<String> = [
            "TSNO", "PNO", "RVRNO", "SLPNO", "FZRANO", "VISNO",
            "CHINO", "PWINO", "PRESRR", "PRESFR"
        ]
        return raw.filter { !remarkCodes.contains($0.uppercased()) }
    }
}

// MARK: - Weather Phenomena Decoder
// Translates METAR weather codes to plain English
struct WeatherDecoder {

    static func decode(_ code: String) -> String {
        let upper = code.uppercased()

        // Check for exact match first
        if let exact = descriptions[upper] { return exact }

        // Parse intensity + descriptor + type
        var remaining = upper
        var parts: [String] = []

        // Intensity prefix
        if remaining.hasPrefix("+") {
            parts.append("Heavy")
            remaining = String(remaining.dropFirst())
        } else if remaining.hasPrefix("-") {
            parts.append("Light")
            remaining = String(remaining.dropFirst())
        } else if remaining.hasPrefix("VC") {
            parts.append("Vicinity")
            remaining = String(remaining.dropFirst(2))
        }

        // Descriptors (2-char codes that modify the type)
        let descriptors: [(String, String)] = [
            ("MI", "Shallow"), ("PR", "Partial"), ("BC", "Patches"),
            ("DR", "Low Drifting"), ("BL", "Blowing"), ("SH", "Showers"),
            ("TS", "Thunderstorm"), ("FZ", "Freezing")
        ]
        for (abbr, desc) in descriptors {
            if remaining.hasPrefix(abbr) {
                parts.append(desc)
                remaining = String(remaining.dropFirst(abbr.count))
                break
            }
        }

        // Precipitation / obscuration types
        let types: [(String, String)] = [
            ("RA", "Rain"), ("SN", "Snow"), ("DZ", "Drizzle"),
            ("PL", "Ice Pellets"), ("GR", "Hail"), ("GS", "Small Hail"),
            ("SG", "Snow Grains"), ("IC", "Ice Crystals"), ("UP", "Unknown Precip"),
            ("FG", "Fog"), ("BR", "Mist"), ("HZ", "Haze"),
            ("FU", "Smoke"), ("DU", "Dust"), ("SA", "Sand"),
            ("VA", "Volcanic Ash"), ("PY", "Spray"),
            ("SQ", "Squall"), ("FC", "Funnel Cloud"),
            ("SS", "Sandstorm"), ("DS", "Duststorm"),
            ("PO", "Dust Whirls")
        ]
        for (abbr, name) in types {
            if remaining.contains(abbr) {
                parts.append(name)
                remaining = remaining.replacingOccurrences(of: abbr, with: "")
            }
        }

        if parts.isEmpty { return code }
        return parts.joined(separator: " ")
    }

    static func decodeAll(_ codes: [String]) -> String {
        codes.map { decode($0) }.joined(separator: ", ")
    }

    // Common exact matches
    private static let descriptions: [String: String] = [
        "RA": "Rain", "+RA": "Heavy Rain", "-RA": "Light Rain",
        "SN": "Snow", "+SN": "Heavy Snow", "-SN": "Light Snow",
        "DZ": "Drizzle", "+DZ": "Heavy Drizzle", "-DZ": "Light Drizzle",
        "FG": "Fog", "BR": "Mist", "HZ": "Haze", "FU": "Smoke",
        "FZRA": "Freezing Rain", "+FZRA": "Heavy Freezing Rain", "-FZRA": "Light Freezing Rain",
        "FZDZ": "Freezing Drizzle", "+FZDZ": "Heavy Freezing Drizzle", "-FZDZ": "Light Freezing Drizzle",
        "FZFG": "Freezing Fog",
        "TSRA": "Thunderstorm Rain", "+TSRA": "Heavy Thunderstorm Rain",
        "TSSN": "Thunderstorm Snow", "+TSSN": "Heavy Thunderstorm Snow",
        "TSPL": "Thunderstorm Ice Pellets",
        "TSGR": "Thunderstorm Hail", "+TSGR": "Heavy Thunderstorm Hail",
        "TS": "Thunderstorm",
        "SQ": "Squall", "FC": "Funnel Cloud", "+FC": "Tornado/Waterspout",
        "SS": "Sandstorm", "DS": "Duststorm",
        "BLSN": "Blowing Snow", "BLDU": "Blowing Dust", "BLSA": "Blowing Sand",
        "DRSN": "Low Drifting Snow", "DRDU": "Low Drifting Dust",
        "SHRA": "Rain Showers", "+SHRA": "Heavy Rain Showers", "-SHRA": "Light Rain Showers",
        "SHSN": "Snow Showers", "+SHSN": "Heavy Snow Showers", "-SHSN": "Light Snow Showers",
        "SHGR": "Hail Showers",
        "PL": "Ice Pellets", "+PL": "Heavy Ice Pellets", "-PL": "Light Ice Pellets",
        "GR": "Hail", "+GR": "Heavy Hail",
        "GS": "Small Hail", "IC": "Ice Crystals", "SG": "Snow Grains",
        "UP": "Unknown Precipitation",
        "VCFG": "Fog in Vicinity", "VCTS": "Thunderstorm in Vicinity",
        "VCSH": "Showers in Vicinity",
        "MIFG": "Shallow Fog", "PRFG": "Partial Fog", "BCFG": "Fog Patches"
    ]
}
