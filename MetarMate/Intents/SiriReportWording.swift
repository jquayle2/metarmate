import Foundation

// MARK: - Siri report wording
// The spoken dialog and result-card line for FlyingWeatherIntent. Report age follows D#4
// (DECISIONS_2026-10 #4) with the widget's boundaries (WidgetWeatherSnapshot.reportAge):
//   current  → "As of 16 minutes ago, Kingman is VFR. …"
//   65–75 min → "The latest Kingman report is 68 minutes old. Kingman was VFR. …"
//   76+ min  → "There's no current METAR for Kingman. The last report is 80 minutes old."
//              No category, conditions, trend or verdict.
enum SiriReportWording {

    // MARK: - Age

    /// Whole minutes since the observation, truncated like the widget; a future obs time is 0.
    static func ageMinutes(observationTime: Date, at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(observationTime) / 60))
    }

    /// Spoken age: minutes under 2 h, then hours and minutes (D#4).
    static func spokenAge(minutes: Int) -> String {
        if minutes < 120 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        if m == 0 { return hours }
        return "\(hours) \(m == 1 ? "1 minute" : "\(m) minutes")"
    }

    /// Card age, same breakpoints as spokenAge: "16 min", "2 h 10 min".
    static func shortAge(minutes: Int) -> String {
        if minutes < 120 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: - Dialog

    /// `borrowed`: the nearby TAF standing in for this field's (D#14). Named whenever the forecast
    /// is voiced, so a nearby station's forecast never sounds like this field's.
    static func dialog(airportName: String, metar: Metar, trend: WeatherTrend,
                       borrowed: (source: TafSource, ownExpired: Bool, stationName: String)? = nil,
                       at date: Date) -> String {
        let minutes = ageMinutes(observationTime: metar.observationTime, at: date)
        var parts: [String] = []

        switch WidgetWeatherSnapshot.reportAge(observationTime: metar.observationTime, at: date) {
        case .noCurrent:
            return "There's no current METAR for \(airportName). The last report is \(spokenAge(minutes: minutes)) old."
        case .late:
            parts.append("The latest \(airportName) report is \(spokenAge(minutes: minutes)) old.")
            parts.append("\(airportName) was \(metar.flightCategory.rawValue).")
        case .current:
            let asOf = minutes == 0 ? "less than a minute" : spokenAge(minutes: minutes)
            parts.append("As of \(asOf) ago, \(airportName) is \(metar.flightCategory.rawValue).")
        }

        // Ceiling
        switch metar.ceiling {
        case .feet(let ceiling):
            let coverageWord = metar.clouds.ceilingLayer?.coverage == .overcast ? "overcast" : "broken"
            parts.append("Ceiling \(coverageWord) at \(ceiling) feet.")
        case .notReported:
            // No sky group is sky not reported, never unlimited (audit #6). NOAA sends no layers
            // for CLR, so an empty list alone isn't "not reported" (Metar.skyReported).
            parts.append("Sky condition not reported.")
        case .none:
            parts.append("Ceiling unlimited.")
        }

        // Visibility — omit the spoken sentence entirely when the station didn't report it
        // (never voice a fabricated value); still voice present weather if any.
        let wxSuffix = metar.weatherPhenomena.isEmpty ? "" : " in \(WeatherDecoder.decodeAll(metar.weatherPhenomena).lowercased())"
        switch metar.visibility {
        case .exact(let v):
            parts.append("Visibility \(String(format: "%.0f", v)) miles\(wxSuffix).")
        case .greaterThan(let v):
            parts.append("Visibility \(String(format: "%.0f", v)) or more miles\(wxSuffix).")
        case .unknown:
            // Never voice a fabricated value; still voice present weather if any.
            if !metar.weatherPhenomena.isEmpty {
                let wx = WeatherDecoder.decodeAll(metar.weatherPhenomena).lowercased()
                parts.append("\(wx.prefix(1).uppercased())\(wx.dropFirst()) observed.")
            }
        }

        // Wind
        parts.append(windPhrase(metar.wind))

        // Trend — use observed if we have enough history, otherwise forecast
        if trend.observed.overall != .unknown {
            parts.append("Conditions are \(trend.observed.overall.rawValue.lowercased()).")
        } else if trend.forecast.overall != .unknown {
            let conditions = trend.forecast.overall.rawValue.lowercased()
            if let borrowed {
                parts.append(NearbyTaf.spokenBorrowedForecast(fieldName: airportName, stationName: borrowed.stationName,
                                                              source: borrowed.source, ownExpired: borrowed.ownExpired,
                                                              conditions: conditions))
            } else {
                parts.append("Forecast shows conditions \(conditions).")
            }
        } else {
            parts.append("No trend data available.")
        }

        return parts.joined(separator: " ")
    }

    static func windPhrase(_ wind: Wind) -> String {
        guard wind.isReported else { return "Wind not reported." }   // nil ≠ calm
        if wind.speed == 0 && !wind.isVariable {
            return "Wind calm."
        }
        let dir: String
        if wind.isVariable {
            dir = "variable"
        } else if let d = wind.direction {
            dir = "\(d)"
        } else {
            return "Wind direction not reported, \(wind.speed) knots" + (wind.gust.map { ", gusting \($0)" } ?? "") + "."
        }
        var phrase = "Wind \(dir) at \(wind.speed) knots"
        if let gust = wind.gust {
            phrase += ", gusting \(gust)"
        }
        return phrase + "."
    }

    // MARK: - Result card

    /// Category shown on the card: none (unknown) once the report is no longer current.
    static func cardCategory(metar: Metar, at date: Date) -> FlightCategory {
        if case .noCurrent = WidgetWeatherSnapshot.reportAge(observationTime: metar.observationTime, at: date) {
            return .unknown
        }
        return metar.flightCategory
    }

    static func summaryLine(metar: Metar, at date: Date) -> String {
        let minutes = ageMinutes(observationTime: metar.observationTime, at: date)
        switch WidgetWeatherSnapshot.reportAge(observationTime: metar.observationTime, at: date) {
        case .noCurrent:
            return "No current METAR · last report \(shortAge(minutes: minutes)) ago"
        case .late:
            return "Late · \(shortAge(minutes: minutes)) ago · \(conditionsLine(metar: metar))"
        case .current:
            return "\(shortAge(minutes: minutes)) ago · \(conditionsLine(metar: metar))"
        }
    }

    static func conditionsLine(metar: Metar) -> String {
        let vis: String
        switch metar.visibility {
        case .exact(let v):       vis = String(format: "Vis %.0f sm", v)
        case .greaterThan(let v): vis = "Vis \(String(format: "%.0f", v))+ sm"
        case .unknown:            vis = "Vis —"
        }
        let windStr: String
        if !metar.wind.isReported {
            windStr = "—"
        } else if metar.wind.speed == 0 {
            windStr = "Calm"
        } else {
            windStr = "\(metar.wind.speed)kt"
        }
        return "\(skyText(metar)) · \(vis) · Wind \(windStr)"
    }

    /// "Sky clear" only when the report says CLR/SKC and nothing else; FEW/SCT is "No ceiling"
    /// (Oct 22: KIGM FEW055 SCT100 read "Sky clear"); no cloud group is "Sky not reported" (audit #6).
    static func skyText(_ metar: Metar) -> String {
        if let c = metar.ceilingFeet { return "Ceil \(c / 100 * 100)ft" }
        let words = metar.noCeilingWords
        return words == "Clear" ? "Sky clear" : words
    }
}
