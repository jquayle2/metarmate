import Foundation

// MARK: - TAF Parser
struct TafParser {
    nonisolated static func parse(raw: RawTaf, now: Date = Date()) throws -> Taf {
        guard let icao = raw.icaoId else { throw WeatherError.parseError("Missing station ID") }
        guard let rawText = raw.rawTAF else { throw WeatherError.parseError("Missing raw TAF text") }

        // Issue time: NOAA's issueTime, else the TAF's own DDHHMMZ group. Never Date() (audit #15);
        // with neither, the TAF can't be placed in time and isn't used.
        let issueTime: Date
        if let str = raw.issueTime, let parsed = parseDate(str) {
            issueTime = parsed
        } else if let stated = MetarParser.reportTimeGroup(in: rawText, now: now) {
            issueTime = stated
        } else {
            throw WeatherError.parseError("Missing TAF issue time")
        }

        // Validity: NOAA's fields, else the TAF's own validity group ("2318/2424"). Never an assumed
        // 24 h or "valid from issue" (Jeff, Oct 23); with neither, the TAF isn't used.
        let stated = validityGroup(in: rawText, issueTime: issueTime)
        guard let validFrom = raw.validTimeFrom.map({ Date(timeIntervalSince1970: TimeInterval($0)) }) ?? stated?.from,
              let validTo = raw.validTimeTo.map({ Date(timeIntervalSince1970: TimeInterval($0)) }) ?? stated?.to
        else { throw WeatherError.parseError("Missing TAF validity") }

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

    // MARK: - Parse forecast periods
    nonisolated private static func parseForecastPeriods(_ fcsts: [[String: AnyCodable]], rawText: String) -> [TafForecast] {
        var result: [TafForecast] = []
        // Raw change groups, used only when they line up one-to-one with NOAA's periods (see OMTNS).
        let groups = rawChangeGroups(rawText)
        let aligned = groups.count == fcsts.count
        var carriedOMTNS: Set<String> = []
        // The prevailing visibility and sky, carried forward into change groups that omit them.
        var prevailingVis: Visibility = .unknown
        var prevailingClouds: [CloudLayer] = []
        var prevailingWind: Wind?

        for (index, dict) in fcsts.enumerated() {
            guard let fromEpoch = dict["timeFrom"]?.value as? Int,
                  let toEpoch = dict["timeTo"]?.value as? Int else { continue }

            let from = Date(timeIntervalSince1970: TimeInterval(fromEpoch))
            let to = Date(timeIntervalSince1970: TimeInterval(toEpoch))

            // API uses "fcstChange" not "fcstType". NOAA sends PROB groups as fcstChange "PROB"
            // with the percentage in a separate `probability` field — NOT "PROB30"/"PROB40", so a
            // rawValue match fails and the period would silently become .base (a 30-40% window
            // injected into the firm hero/currentForecast timeline). Map it explicitly.
            // A "PROB30 TEMPO" arrives as fcstChange "TEMPO" with a probability — keep the probability.
            let typeStr = dict["fcstChange"]?.value as? String
            let prob = dict["probability"]?.value as? Int
            let type: TafForecast.ForecastType
            if typeStr == "PROB" || (typeStr == "TEMPO" && prob != nil) {
                type = prob == 40 ? .prob40 : prob == 30 ? .prob30 : .prob   // no number: not assumed PROB30
            } else if let typeStr, let parsed = TafForecast.ForecastType(rawValue: typeStr) {
                type = parsed
            } else {
                type = .base
            }

            // BECMG: when the gradual change is complete (it becomes prevailing then).
            let becomingTime = (dict["timeBec"]?.value as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }

            // A change group states only what changes; whatever it omits (visibility, sky, and for
            // a BECMG the wind) is the prevailing condition, not 10 SM VFR or a clear sky. Base/FM
            // periods and BECMG (which becomes the persistent state) update the prevailing values;
            // TEMPO/PROB are transient overlays and must not.
            let persists = type == .base || type == .fm || type == .becmg

            // Wind — wdir can be Int or String ("VRB")
            var wind = parseWind(dict)
            if wind == nil, type == .becmg { wind = prevailingWind }
            if persists, let wind { prevailingWind = wind }

            // Clouds — API returns full cloud data in TAF forecasts; empty = omitted
            var clouds = parseClouds(dict)
            if clouds.isEmpty { clouds = prevailingClouds }   // may itself be empty (sky not forecast)
            if persists { prevailingClouds = clouds }

            let ownVis = parseVisibility(dict)   // .unknown when the period omits visibility
            let vis: Visibility
            if ownVis.isKnown {
                vis = ownVis
                if persists { prevailingVis = ownVis }
            } else {
                vis = prevailingVis   // carry the prevailing forward (may itself be .unknown)
            }

            // Calculate flight category from visibility and ceiling
            let cat = calculateFlightCategory(visibility: vis, clouds: clouds)

            // Weather phenomena. NSW ("no significant weather") ends the weather; it isn't one.
            var wx = (dict["wxString"]?.value as? String)?.components(separatedBy: " ").filter { !$0.isEmpty && $0 != "NSW" } ?? []
            if aligned {
                let tokens = groups[index]
                let stated = wx.contains { tokens.contains($0) }   // else NOAA carried it from an earlier group
                let omtns: Set<String> = stated
                    ? Set(tokens.indices.dropFirst().filter { tokens[$0] == "OMTNS" }.map { tokens[$0 - 1] })
                    : (persists ? carriedOMTNS : [])
                if persists { carriedOMTNS = wx.isEmpty ? [] : omtns }
                wx = wx.map { omtns.contains($0) ? "\($0) OMTNS" : $0 }
            }

            result.append(TafForecast(
                type: type,
                fromTime: from,
                toTime: to,
                becomingTime: becomingTime,
                wind: wind,
                visibility: vis,
                clouds: clouds,
                weatherPhenomena: wx,
                flightCategory: cat
            ))
        }
        return result
    }

    // MARK: - Wind parsing (handles Int or String wdir)
    nonisolated private static func parseWind(_ dict: [String: AnyCodable]) -> Wind? {
        guard let wspd = dict["wspd"]?.value as? Int else { return nil }
        let wgst = dict["wgst"]?.value as? Int

        // Speed with no direction: direction unknown (nil, not variable), never 000° (audit #10).
        guard let wdirValue = dict["wdir"]?.value else {
            return Wind(direction: nil, speed: wspd, gust: wgst, isVariable: false)
        }

        if let dirString = wdirValue as? String {
            if dirString == "VRB" {
                return Wind(direction: nil, speed: wspd, gust: wgst, isVariable: true)
            }
            return Wind(direction: Int(dirString), speed: wspd, gust: wgst, isVariable: false)
        }

        if let dirInt = wdirValue as? Int {
            return Wind(direction: dirInt, speed: wspd, gust: wgst, isVariable: false)
        }

        if let dirDouble = wdirValue as? Double {
            return Wind(direction: Int(dirDouble), speed: wspd, gust: wgst, isVariable: false)
        }

        return Wind(direction: nil, speed: wspd, gust: wgst, isVariable: false)
    }

    // MARK: - Visibility parsing
    nonisolated private static func parseVisibility(_ dict: [String: AnyCodable]) -> Visibility {
        guard let value = dict["visib"]?.value else { return .unknown }
        if let str = value as? String {
            let s = str.trimmingCharacters(in: .whitespaces).uppercased()
            // The ONLY constructors of .greaterThan — NOAA's greater-than strings at 6 and 10.
            if s == "6+"  || s == "P6SM"  { return .greaterThan(6) }
            if s == "10+" || s == "P10SM" { return .greaterThan(10) }
            if let d = Double(s) { return .exact(d) }
            return .unknown
        }
        if let num = value as? Double { return .exact(num) }
        if let num = value as? Int { return .exact(Double(num)) }
        return .unknown
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

            var altitudeHundreds: Int?   // nil = base not forecast, never 0 ft (audit #12)
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

    // MARK: - Weather over the mountains (OMTNS)
    // US military TAFs qualify weather with OMTNS: "TSRA OMTNS" is thunderstorms over the mountains,
    // not at the station. NOAA's decode drops the qualifier (it lands in `notDecoded` on the NEXT
    // period) and carries the bare TSRA into later groups. So the raw TAF is split into change
    // groups, and only when those line up one-to-one with NOAA's periods is a weather code followed
    // by OMTNS kept as "<code> OMTNS" (decoded "… over mountains"), including where NOAA carries it.
    // Otherwise NOAA's decode stands, which reads it at the station (the cautious side).
    nonisolated static func rawChangeGroups(_ raw: String) -> [[String]] {
        var groups: [[String]] = [[]]
        var previous = ""
        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            let isFM = token.hasPrefix("FM") && token.count == 8 && token.dropFirst(2).allSatisfy(\.isNumber)
            // "PROB30 TEMPO" is one group; the TEMPO doesn't start another.
            let startsGroup = token == "BECMG" || token.hasPrefix("PROB") || isFM
                || (token == "TEMPO" && !previous.hasPrefix("PROB"))
            if startsGroup { groups.append([]) }
            groups[groups.count - 1].append(token)
            previous = token
        }
        return groups
    }

    /// The TAF's validity group, the first DDHH/DDHH token ("2318/2424"; hour 24 is midnight at
    /// the end of that day), placed in time against the issue time: the issue time's month, or
    /// the next month when the day has wrapped (issued on the 31st, valid 0100/0124).
    nonisolated static func validityGroup(in rawText: String, issueTime: Date) -> (from: Date, to: Date)? {
        guard let token = rawText.split(separator: " ").first(where: { t in
            t.count == 9 && t.dropFirst(4).first == "/" && t.filter(\.isNumber).count == 8
        }) else { return nil }
        let digits = token.compactMap(\.wholeNumberValue)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func date(day: Int, hour: Int) -> Date? {
            guard (1...31).contains(day), (0...24).contains(hour) else { return nil }
            for monthsAhead in 0...1 {
                guard let month = utc.date(byAdding: .month, value: monthsAhead,
                                           to: utc.date(from: utc.dateComponents([.year, .month], from: issueTime))!)
                else { continue }
                var parts = utc.dateComponents([.year, .month], from: month)
                parts.day = day; parts.hour = 0
                // Reject a day the month doesn't have (date(from:) would roll it over).
                guard let midnight = utc.date(from: parts), utc.component(.day, from: midnight) == day else { continue }
                let d = midnight.addingTimeInterval(TimeInterval(hour * 3600))
                if d >= issueTime.addingTimeInterval(-86400) { return d }   // not before the issue day
            }
            return nil
        }
        guard let from = date(day: digits[0] * 10 + digits[1], hour: digits[2] * 10 + digits[3]),
              let to = date(day: digits[4] * 10 + digits[5], hour: digits[6] * 10 + digits[7]),
              to > from else { return nil }
        return (from, to)
    }

    nonisolated private static func parseDate(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    // MARK: - Flight category from visibility + ceiling
    nonisolated private static func calculateFlightCategory(visibility: Visibility, clouds: [CloudLayer]) -> FlightCategory {
        // Ceiling = lowest BKN, OVC, or VV layer (FEW/SCT don't count). The sky axis is known only
        // when clouds were forecast: no layers at all means "not forecast", while a stated clear sky
        // (SKC/NSC) or FEW/SCT only is a known "no ceiling". A ceiling layer with no base leaves the
        // sky axis unknown. .greaterThan(n) thresholds on its floor n (NOAA emits it only at 6/10,
        // both VFR). Shared thresholds and one-axis rule: FlightCategory.from (audit #14/#18).
        FlightCategory.from(ceiling: clouds.ceilingStatus(skyReported: !clouds.isEmpty),
                            visibilitySM: visibility.lowerBoundSM)
    }
}
