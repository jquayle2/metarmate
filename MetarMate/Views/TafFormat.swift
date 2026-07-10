import Foundation

// MARK: - TAF formatting helpers (pure)
// Single source of truth for the small, stateless TAF time/severity/text formatters shared by the
// hero brief (TafHeroBrief) and the TAF Pilot Notes / strip code in WeatherDetailView. Extracted
// here so TafHeroBrief.build can be a pure, unit-testable function; the View keeps its existing
// helper names as one-line delegators so every other call site stays unchanged.
enum TafFormat {

    // Local wall-clock, e.g. "3:00 PM".
    static func localClock(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    // Day-of-week disambiguation for a forecast time relative to now's local calendar day.
    // "" = today, " tomorrow" = next local day, " MMM d" = further out.
    static func daySuffix(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "" }
        if days == 1 { return " tomorrow" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        df.timeZone = .current
        return " \(df.string(from: date))"
    }

    // Full point-in-time label, e.g. "3:00 PM local" / "9:00 AM local tomorrow".
    static func timeLabel(_ date: Date) -> String {
        "\(localClock(date)) local\(daySuffix(date))"
    }

    // Window label for an overlay group, e.g. "3:00 PM–9:00 AM local tomorrow"
    // (day suffix keyed off the window start).
    static func windowLabel(from: Date, to: Date) -> String {
        "\(localClock(from))–\(localClock(to)) local\(daySuffix(from))"
    }

    // Coarse time-of-day phrasing for the hero wind-caution tail, e.g. "midday tomorrow",
    // "this afternoon", "tomorrow morning". Deliberately vague (Option B) — the exact gust
    // number and time live in the TAF Pilot Notes card below.
    static func coarseWhen(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let partOfDay: String
        switch hour {
        case 5..<11:  partOfDay = "morning"
        case 11..<14: partOfDay = "midday"
        case 14..<18: partOfDay = "afternoon"
        case 18..<22: partOfDay = "evening"
        default:      partOfDay = "overnight"
        }
        let suffix = daySuffix(date).trimmingCharacters(in: .whitespaces)
        if suffix.isEmpty {
            // Today: "this morning/afternoon/evening" reads naturally, but "this midday"
            // and "this overnight" don't — those stand alone.
            switch partOfDay {
            case "midday":    return "midday"
            case "overnight": return "overnight"
            default:          return "this \(partOfDay)"
            }
        }
        if suffix == "tomorrow" { return "\(partOfDay) tomorrow" }
        return "\(partOfDay) \(suffix)"
    }

    // .exact(6) -> "6 SM" (never "6+"), .greaterThan(6) -> "6+ SM", .unknown -> "—".
    static func visText(_ vis: Visibility) -> String {
        vis.displayNumber.map { "\($0) SM" } ?? "—"
    }

    // Heavy precip or thunderstorm in a period's phenomena — escalates overlay severity to warning.
    static func hasConvectiveOrHeavy(_ period: TafForecast) -> Bool {
        period.weatherPhenomena.contains { code in
            let c = code.uppercased()
            return c.contains("TS") || c.contains("GR") || c.hasPrefix("+") || c.contains("FC") || c.contains("FZ")
        }
        || period.clouds.contains { $0.isCumulonimbus }
    }

    static func categorySeverity(_ cat: FlightCategory) -> Int {
        switch cat {
        case .vfr: return 0
        case .mvfr: return 1
        case .ifr: return 2
        case .lifr: return 3
        case .unknown: return 0
        }
    }
}
