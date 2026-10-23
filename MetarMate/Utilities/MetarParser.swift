import Foundation

// MARK: - METAR Parser
// Parses aviationweather.gov JSON responses into Metar structs
struct MetarParser {
    nonisolated static func parse(raw: RawMetar, now: Date = Date()) throws -> Metar {
        guard let icao = raw.icaoId else { throw WeatherError.parseError("Missing station ID") }
        guard let rawText = raw.rawOb else { throw WeatherError.parseError("Missing raw METAR text") }

        // Observation time: NOAA's obsTime, else the report's own DDHHMMZ group. Never Date(): a
        // report with no time looked fresh and sorted newest (audit #15). With neither, the report
        // can't be placed in time at all, so it isn't used.
        let obsTime: Date
        if let epoch = raw.obsTime {
            obsTime = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else if let stated = reportTimeGroup(in: rawText, now: now) {
            obsTime = stated
        } else {
            throw WeatherError.parseError("Missing observation time")
        }

        let wind = parseWind(wdir: raw.wdir, wspd: raw.wspd, wgst: raw.wgst)
        // .unknown when absent/unrecognized — never a fabricated number (see Visibility). NOAA
        // sends M1/4SM as plain 0.25, so "less than" comes from the report's own group (P3).
        let parsedVisibility = parseVisibility(raw.visib)
        let visibility = lessThanGroup(in: rawText) ?? parsedVisibility
        let clouds = parseClouds(raw.clouds, vertVis: raw.vertVis)
        let phenomena = parseWeatherPhenomena(raw.wxString, rawOb: rawText)

        // Round toward nearest, not toward zero: a raw -0.6 C is -1 C, not 0. Missing stays nil.
        let temp = raw.temp.map { Int($0.rounded()) }
        let dewp = raw.dewp.map { Int($0.rounded()) }

        // API returns altim in hPa — convert to inHg. Missing stays nil.
        let altimInHg = raw.altim.map { $0 * 0.02953 }

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
            weatherPhenomena: phenomena,
            preciseTemperatureC: raw.temp,
            preciseDewpointC: raw.dewp
        )
    }

    // MARK: - Report time group
    /// The first DDHHMMZ group in a METAR/TAF ("231551Z"), resolved to the most recent such UTC
    /// time not more than an hour after `now` (so a report from the 31st read on the 1st lands in
    /// the previous month). nil when the text has no such group or it isn't a valid time.
    nonisolated static func reportTimeGroup(in rawText: String, now: Date) -> Date? {
        let body = rawText.components(separatedBy: " RMK").first ?? rawText
        guard let token = body.split(separator: " ").first(where: { t in
            t.count == 7 && t.hasSuffix("Z") && t.dropLast().allSatisfy(\.isNumber)
        }) else { return nil }
        let digits = token.dropLast().compactMap { $0.wholeNumberValue }
        let day = digits[0] * 10 + digits[1], hour = digits[2] * 10 + digits[3], minute = digits[4] * 10 + digits[5]
        guard (1...31).contains(day), hour < 24, minute < 60 else { return nil }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let nowParts = utc.dateComponents([.year, .month], from: now)
        for monthsBack in 0...2 {
            guard let monthStart = utc.date(from: nowParts),
                  let month = utc.date(byAdding: .month, value: -monthsBack, to: monthStart) else { continue }
            var parts = utc.dateComponents([.year, .month], from: month)
            parts.day = day; parts.hour = hour; parts.minute = minute
            // Reject a day the month doesn't have (date(from:) would roll it into the next month).
            guard let date = utc.date(from: parts), utc.component(.day, from: date) == day else { continue }
            if date <= now.addingTimeInterval(3600) { return date }
        }
        return nil
    }

    // MARK: - Wind
    // API returns wdir as Int (degrees) or String ("VRB")
    nonisolated private static func parseWind(wdir: AnyCodable?, wspd: Int?, wgst: Int?) -> Wind {
        // A missing wind group (neither direction nor speed reported) is UNKNOWN, not calm.
        // Flag it so callers render "—" and a "wind not reported" note instead of 00000KT.
        if wdir?.value == nil && wspd == nil {
            return Wind(direction: nil, speed: 0, gust: nil, isVariable: false, isReported: false)
        }

        // A direction with no speed can't be evaluated either: wind not reported.
        guard let speed = wspd else {
            return Wind(direction: nil, speed: 0, gust: nil, isVariable: false, isReported: false)
        }
        let gust = wgst

        // Speed with no direction (`///25KT`): the speed is real, the direction is unknown (nil,
        // not variable) — never 000°, which read as a straight-down-the-runway wind (audit #10).
        guard let wdirValue = wdir?.value else {
            return Wind(direction: nil, speed: speed, gust: gust, isVariable: false)
        }

        if let dirString = wdirValue as? String {
            if dirString == "VRB" {
                return Wind(direction: nil, speed: speed, gust: gust, isVariable: true)
            }
            return Wind(direction: Int(dirString), speed: speed, gust: gust, isVariable: false)
        }

        if let dirInt = wdirValue as? Int {
            return Wind(direction: dirInt, speed: speed, gust: gust, isVariable: false)
        }

        if let dirDouble = wdirValue as? Double {
            return Wind(direction: Int(dirDouble), speed: speed, gust: gust, isVariable: false)
        }

        return Wind(direction: nil, speed: speed, gust: gust, isVariable: false)
    }

    // MARK: - Visibility
    // Returns nil when visibility is absent or unrecognized. Callers must NOT invent 10 SM — that
    // silently rendered a LIFR half-mile as VFR. NOAA delivers fractional/metric visibility already
    // normalized to SM numbers (verified live: 3/4SM -> 0.75, metric 0150 m -> 0.09); the only
    // strings it emits are "10+"/"6+". The fractional-string branch is defensive for a form NOAA
    // does not currently send.
    nonisolated private static func parseVisibility(_ vis: AnyCodable?) -> Visibility {
        guard let value = vis?.value else { return .unknown }
        if let num = value as? Double { return .exact(num) }
        if let num = value as? Int { return .exact(Double(num)) }
        if let str = value as? String {
            let s = str.trimmingCharacters(in: .whitespaces).uppercased()
            // The ONLY constructors of .greaterThan — NOAA's greater-than strings at 6 and 10.
            // Every other input below is .exact; an absent/unrecognized value is .unknown. So
            // .greaterThan(n) is reachable only for n ∈ {6, 10}.
            if s == "10+" || s == "P10SM" { return .greaterThan(10) }
            if s == "6+"  || s == "P6SM"  { return .greaterThan(6) }
            if let d = Double(s) { return .exact(d) }
            if let f = parseFractionalSM(s) { return s.hasPrefix("M") ? .lessThan(f) : .exact(f) }
        }
        return .unknown
    }

    /// The report's "M1/4SM"-style group (less than), if it has one.
    nonisolated private static func lessThanGroup(in rawText: String) -> Visibility? {
        let body = rawText.components(separatedBy: " RMK").first ?? rawText
        guard let token = body.split(separator: " ").first(where: { $0.hasPrefix("M") && $0.hasSuffix("SM") }),
              let v = parseFractionalSM(String(token)) else { return nil }
        return .lessThan(v)
    }

    // Defensive fractional visibility: "1/2", "1 1/4SM", "M1/4SM" -> Double; nil if not a fraction.
    nonisolated private static func parseFractionalSM(_ raw: String) -> Double? {
        var s = raw
        if s.hasSuffix("SM") { s = String(s.dropLast(2)) }
        if s.hasPrefix("M") { s = String(s.dropFirst()) }   // "M" = less than; use the bound value
        s = s.trimmingCharacters(in: .whitespaces)
        func frac(_ t: Substring) -> Double? {
            let f = t.split(separator: "/")
            if f.count == 2, let n = Double(f[0]), let d = Double(f[1]), d != 0 { return n / d }
            return Double(t)
        }
        let parts = s.split(separator: " ")
        if parts.count == 2, let whole = Double(parts[0]), let fr = frac(parts[1]) { return whole + fr }
        if parts.count == 1 { return frac(parts[0]) }
        return nil
    }

    // MARK: - Clouds
    // API returns base in feet AGL (e.g. 25000), not hundreds
    nonisolated private static func parseClouds(_ clouds: [[String: AnyCodable]]?, vertVis: Int? = nil) -> [CloudLayer] {
        guard let clouds = clouds else { return [] }
        return clouds.compactMap { dict -> CloudLayer? in
            guard let coverageStr = dict["cover"]?.value as? String else { return nil }
            // NOAA encodes an indefinite ceiling (raw "VVnnn") as cover "OVX" plus a sibling
            // vertVis field — NOT as cover "VV". Map it onto .verticalVisibility so the obscuration
            // becomes a real ceiling (dropping it silently hid 100-200 ft LIFR fog ceilings).
            let coverKey = (coverageStr == "OVX") ? "VV" : coverageStr
            guard let coverage = CloudCoverage(rawValue: coverKey) else { return nil }

            // API gives base in feet; CloudLayer stores hundreds of feet. No base (BKN///) stays
            // nil — never 0 ft, which read as LIFR, a "0 ft" note and "Ceiling Falling" (audit #12).
            var altitudeHundreds: Int?
            if let base = dict["base"]?.value as? Int {
                altitudeHundreds = base / 100
            } else if let base = dict["base"]?.value as? Double {
                altitudeHundreds = Int(base) / 100
            } else if coverage == .verticalVisibility, let vv = vertVis {
                // Obscuration layer with no base — fall back to vertVis (already in hundreds of feet).
                altitudeHundreds = vv
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

        // Military "over the mountains" qualifier, kept on TAF weather by TafParser ("TSRA OMTNS").
        if upper.hasSuffix(" OMTNS") { return decode(String(code.dropLast(6))) + " over mountains" }

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
        // Consume 2-char phenomena codes left-to-right from the FRONT (hasPrefix), never
        // `contains`: a substring scan is the same shape that fabricated phantom weather (KSNA ->
        // "Snow") and it mis-orders compound codes ("SNRA" -> "Rain Snow"). Every type code is a
        // distinct 2-char token, so prefix matching is unambiguous; stop at the first unknown
        // remainder rather than looping.
        while !remaining.isEmpty {
            guard let match = types.first(where: { remaining.hasPrefix($0.0) }) else { break }
            parts.append(match.1)
            remaining = String(remaining.dropFirst(match.0.count))
        }

        if parts.isEmpty { return code }
        return parts.joined(separator: " ")
    }

    /// D#11 (F17): the hazardous present weather that must show wherever an observation is
    /// summarized, decoded: thunderstorms (incl. VCTS), squalls, funnel cloud / tornado, hail, and
    /// freezing precipitation. Freezing fog is not precipitation and isn't listed.
    static func hazards(_ codes: [String]) -> [String] {
        codes.filter { code in
            let c = code.uppercased()
            return c.contains("TS") || c.contains("SQ") || c.contains("FC") || c.contains("GR")
                || (c.contains("FZ") && !c.contains("FZFG"))
        }.map(decode)
    }

    static func decodeAll(_ codes: [String]) -> String {
        codes.map { decode($0) }.joined(separator: ", ")
    }

    // Common exact matches. Internal (not private) so the F10 dict-audit test can walk every key
    // and assert each decodes to a non-empty, non-passthrough description — widening access to
    // existing data, not adding test-only API.
    static let descriptions: [String: String] = [
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
