import Foundation

// MARK: - Widget Weather Snapshot
// Lightweight, flat struct written by the main app and read by the widget extension.
// Stored as JSON in the App Group's UserDefaults, keyed by airport ICAO.
// Designed to carry exactly what widget views need — nothing more.

nonisolated struct WidgetWeatherSnapshot: Codable, Sendable {
    // Airport identity
    let icao: String
    let iata: String?
    let airportName: String

    // Flight category (the single most important datum)
    let flightCategory: FlightCategory

    // Wind
    let windDirection: Int?
    let windSpeed: Int              // knots sustained
    let windGust: Int?              // knots
    let windIsVariable: Bool
    // Bool? not Bool = true, for the same persisted-JSON reason as visibilityReported below: a
    // missing wind group is UNKNOWN, not 00000KT calm. Legacy snapshots decode nil = treat as
    // reported. Consumers must use `== false ? "—" : value`, never `?? true`.
    var windReported: Bool? = nil

    // Conditions
    let visibility: Double          // statute miles; meaningful only when visibilityReported != false
    // Bool? not Bool = true — this type is decoded from persisted JSON, where synthesized Decodable
    // throws on a missing key rather than using the default. Legacy snapshots decode nil = treat as
    // reported. Consumers must use `== false ? "—" : value`, never `?? true`. Do not "simplify" to Bool.
    var visibilityReported: Bool? = nil
    // Whether `visibility` is a greater-than (P6SM/"6+") vs an exact report, so the lock screen can
    // render "6+" vs "6". Defaulted + decode-safe, same idiom as windReported/visibilityReported —
    // the persisted snapshot stays a Double; this bit carries the parsed Visibility's distinction.
    var visibilityIsGreaterThan: Bool = false
    let ceilingFeet: Int?           // AGL; nil = no ceiling
    let temperature: Int?           // Celsius
    let dewpoint: Int?              // Celsius
    let altimeter: Double?          // inHg

    // Trend
    let trendDirection: TrendDirection
    let trendHeadline: String       // e.g. "Wind Increasing (+8 kt)"

    // TAF accuracy (the widget differentiator)
    let tafAccuracyPct: Int?        // category accuracy; nil = no TAF
    // Borrowed TAF (D#14): the station whose TAF the trend forecast, accuracy and deviation come
    // from, and the substitution line ("No TAF for KBVU · using KHND (13 nm W)"). nil = own TAF.
    var borrowedTafStation: String? = nil
    var borrowedTafLine: String? = nil

    // Forecast deviation (for medium widget)
    let forecastWindDivergenceKt: Int?
    let forecastCeilingDivergenceFt: Int?
    let forecastVisibilityDivergenceSM: Double?

    // Data source
    let isAdvisory: Bool            // true = Open-Meteo estimate, not official METAR
    let observationTime: Date       // when the METAR was observed (advisory: its valid time)
    let snapshotTime: Date          // when the app wrote this snapshot

    // MARK: - Report age (DECISIONS_2026-10 #4)
    // Age comes from observationTime, never from when the snapshot was fetched or written. It is
    // evaluated at a supplied date (the timeline entry's), not Date(), so entries scheduled for
    // the future render the state they're scheduled for.
    enum ReportAge: Equatable {
        case current
        case late(minutes: Int)        // 65 through 75 min: warn, conditions still shown
        case noCurrent(minutes: Int)   // over 75 min (76+ whole minutes): conditions withheld
    }

    static let lateAfterMinutes = 65
    static let noCurrentAfterMinutes = 75

    func reportAge(at date: Date) -> ReportAge {
        Self.reportAge(observationTime: observationTime, at: date)
    }

    /// The one 65/75-minute rule for any report (widgets, Siri, the app's "Right now" row, a
    /// borrowed TAF station's METAR), from its observation time.
    static func reportAge(observationTime: Date, at date: Date) -> ReportAge {
        // Whole minutes, truncated: 64:59 is still current, 75:59 still late (D#4 "over 75").
        // A future obs time (clock skew) is current.
        let minutes = Int(date.timeIntervalSince(observationTime) / 60)
        if minutes > noCurrentAfterMinutes { return .noCurrent(minutes: minutes) }
        if minutes >= lateAfterMinutes { return .late(minutes: minutes) }
        return .current
    }

    /// The instants after `date` at which the rendered age changes, for timeline entries. The
    /// widget can't re-render without an entry, and a reload isn't guaranteed. Per minute through
    /// the late window and into no-current at 76 (so "68 min" is exact), every 5 min to 3 h,
    /// every 30 min to 12 h. From 12 h the text is "12+ h" and never changes.
    func ageChangeDates(after date: Date) -> [Date] {
        let minutes = Array(Self.lateAfterMinutes...(Self.noCurrentAfterMinutes + 1))
            + Array(stride(from: 80, through: 180, by: 5))
            + Array(stride(from: 210, through: 720, by: 30))
        return minutes
            .map { observationTime.addingTimeInterval(TimeInterval($0 * 60)) }
            .filter { $0 > date }
    }

    // MARK: - Reload scheduling
    // WidgetKit grants a limited number of reloads per widget per day, so ask for them when a new
    // report can exist. Stations report on their own cycle: hourly for most ASOS, every 20 min for
    // many AWOS (KBVU :15/:35/:55). First ask a few minutes after the next one is due (obs +
    // interval + 4 min; hourly when the interval is unknown), then every 10 min until obs + 2 h (a
    // late or missed report), then every 30 min while the station stays silent. Advisory
    // snapshots have no METAR cadence: 30 min.
    static let defaultReportIntervalMinutes = 60
    static let reportGraceMinutes = 4
    static let retryMinutes = 10
    static let retryUntilMinutes = 120
    static let silentStationMinutes = 30

    func nextReloadDate(after now: Date, reportIntervalMinutes: Int? = nil) -> Date {
        if isAdvisory { return now.addingTimeInterval(TimeInterval(Self.silentStationMinutes * 60)) }
        let interval = reportIntervalMinutes ?? Self.defaultReportIntervalMinutes
        let expected = observationTime.addingTimeInterval(TimeInterval((interval + Self.reportGraceMinutes) * 60))
        if expected > now { return expected }
        let retryUntil = observationTime.addingTimeInterval(TimeInterval(Self.retryUntilMinutes * 60))
        let step = now < retryUntil ? Self.retryMinutes : Self.silentStationMinutes
        return now.addingTimeInterval(TimeInterval(step * 60))
    }

    /// The station's routine reporting interval, from the two newest routine METARs (SPECIs are
    /// off-cycle and skipped). nil when it can't be told or looks implausible (outside 10–70 min).
    nonisolated static func reportIntervalMinutes(from raws: [RawMetar]) -> Int? {
        let routine = raws
            .filter { !($0.rawOb ?? "").hasPrefix("SPECI") }
            .compactMap(\.obsTime)
        let times = Array(Set(routine)).sorted(by: >)
        guard times.count >= 2 else { return nil }
        let minutes = (times[0] - times[1]) / 60
        return (10...70).contains(minutes) ? minutes : nil
    }

    /// Age for the "Last report … ago" line: "2 h", "2 h 10 min", or "12+ h". The late state
    /// shows plain minutes ("68 min") instead.
    static func ageText(minutes: Int) -> String {
        if minutes >= 720 { return "12+ h" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: - Trend availability
    // A snapshot built by the widget's own fetch has no trend analysis (only the app computes one)
    // and carries this headline as the marker. Views omit the trend row for it.
    static let widgetRefreshHeadline = "Widget Refresh"

    var hasTrend: Bool { trendHeadline != Self.widgetRefreshHeadline }

    /// The trend headline, naming a borrowed TAF's station when the headline comes from its
    /// forecast ("Deterioration Forecast · KHND TAF"; Jeff, Oct 21).
    var trendHeadlineLabeled: String {
        guard let station = borrowedTafStation, trendHeadline.hasSuffix("Forecast") else { return trendHeadline }
        return "\(trendHeadline) · \(station) TAF"
    }

    // MARK: - Wind display (replicates Wind.displayString for widget use)
    var windDisplayString: String {
        if windReported == false { return "—" }
        if windSpeed == 0 { return "Calm" }
        let dir = windIsVariable ? "VRB" : windDirection.map { "\($0)\u{00B0}" } ?? "///"
        let base = "\(dir) \(windSpeed)kt"
        if let g = windGust { return "\(base) G\(g)" }
        return base
    }

    // Visibility display carrying the greater-than distinction: "—" (not reported), "6+" (P6SM),
    // "6" (exact). Formats the number plainly (no `>=10 -> "10+"` threshold, which would double the
    // "+" for a greater-than-10 or fake a "+" onto an exact 10).
    var visibilityDisplay: String {
        if visibilityReported == false { return "—" }
        let n = visibility == Double(Int(visibility)) ? "\(Int(visibility))" : String(format: "%.1f", visibility)
        return visibilityIsGreaterThan ? "\(n)+" : n
    }

    // MARK: - Build from METAR app state
    nonisolated static func from(
        airport: Airport,
        metar: Metar,
        trend: WeatherTrend?,
        tafVerification: TafVerification?
    ) -> WidgetWeatherSnapshot {
        let latestPoint = tafVerification?.points.first

        return WidgetWeatherSnapshot(
            icao: airport.icao,
            iata: airport.iata,
            airportName: airport.name,
            flightCategory: metar.flightCategory,
            windDirection: metar.wind.direction,
            windSpeed: metar.wind.speed,
            windGust: metar.wind.gust,
            windIsVariable: metar.wind.isVariable,
            windReported: metar.wind.isReported,
            visibility: metar.visibility.lowerBoundSM ?? 0,
            visibilityReported: metar.visibility.isKnown,
            visibilityIsGreaterThan: metar.visibility.isGreaterThan,
            ceilingFeet: metar.ceilingFeet,
            temperature: metar.temperature,
            dewpoint: metar.dewpoint,
            altimeter: metar.altimeter,
            trendDirection: trend?.overall ?? .unknown,
            trendHeadline: trend?.headline ?? "No Trend Data",
            tafAccuracyPct: tafVerification?.categoryAccuracyPct,
            forecastWindDivergenceKt: latestPoint?.windDivergenceKt,
            forecastCeilingDivergenceFt: latestPoint?.ceilingDivergenceFt,
            forecastVisibilityDivergenceSM: latestPoint?.visibilityDivergenceSM,
            isAdvisory: false,
            observationTime: metar.observationTime,
            snapshotTime: Date()
        )
    }

    // MARK: - Build from Advisory app state
    nonisolated static func fromAdvisory(
        airport: Airport,
        advisory: AdvisoryWeather
    ) -> WidgetWeatherSnapshot {
        return WidgetWeatherSnapshot(
            icao: airport.icao,
            iata: airport.iata,
            airportName: airport.name,
            flightCategory: advisory.estimatedFlightCategory,
            windDirection: advisory.windDirectionDeg,
            windSpeed: advisory.windSpeedKtRounded,
            windGust: advisory.windGustKtRounded,
            windIsVariable: false,
            windReported: true,
            visibility: advisory.visibilityMiles ?? 10,
            visibilityReported: advisory.visibilityMiles != nil,
            ceilingFeet: nil,
            temperature: Int(advisory.temperatureC),
            dewpoint: advisory.dewpointC.map { Int($0) },
            altimeter: advisory.altimeterInHg,
            trendDirection: advisory.trends?.visibility ?? .unknown,
            trendHeadline: "Advisory Data",
            tafAccuracyPct: nil,
            forecastWindDivergenceKt: nil,
            forecastCeilingDivergenceFt: nil,
            forecastVisibilityDivergenceSM: nil,
            isAdvisory: true,
            // The advisory's own valid time when Open-Meteo provides it; fetch time only if not.
            observationTime: advisory.validTime ?? advisory.fetchTime,
            snapshotTime: Date()
        )
    }

    // MARK: - Build from a raw NOAA METAR (widget fetch path)
    // Lives here (shared by the app + widget targets) rather than privately in the widget so it is
    // unit-testable. De-duplicated (Finding 14): the wind/visibility/ceiling/category/obsTime parse
    // is delegated to MetarParser — the single source of truth — instead of a widget-local copy.
    // Returns nil when the observation can't be parsed: a widget must not render a fabricated
    // snapshot from an unparseable METAR (this replaces the old total `icaoId ?? icao` fallback).
    nonisolated static func from(rawMetar raw: RawMetar, icao: String) -> WidgetWeatherSnapshot? {
        // No obs time → nil, so the widget keeps its cached snapshot. MetarParser substitutes
        // Date() for a missing obsTime (fixed in A2), which would make this report look fresh
        // forever and defeat the late/no-current states.
        guard raw.obsTime != nil, let metar = try? MetarParser.parse(raw: raw) else { return nil }

        return WidgetWeatherSnapshot(
            icao: metar.stationId,
            iata: nil,
            airportName: raw.name ?? metar.stationId,
            flightCategory: metar.flightCategory,
            windDirection: metar.wind.direction,
            windSpeed: metar.wind.speed,
            windGust: metar.wind.gust,
            windIsVariable: metar.wind.isVariable,
            windReported: metar.wind.isReported,
            visibility: metar.visibility.lowerBoundSM ?? 0,
            visibilityReported: metar.visibility.isKnown,
            visibilityIsGreaterThan: metar.visibility.isGreaterThan,
            ceilingFeet: metar.ceilingFeet,
            temperature: metar.temperature,
            dewpoint: metar.dewpoint,
            altimeter: metar.altimeter,
            trendDirection: .unknown,
            trendHeadline: Self.widgetRefreshHeadline,
            tafAccuracyPct: nil,
            forecastWindDivergenceKt: nil,
            forecastCeilingDivergenceFt: nil,
            forecastVisibilityDivergenceSM: nil,
            isAdvisory: false,
            observationTime: metar.observationTime,
            snapshotTime: Date()
        )
    }
}

// MARK: - Widget-refresh merge
extension WidgetWeatherSnapshot {
    /// Combine a widget-fetched snapshot with the app-written one for the same airport. Current
    /// conditions always come from `live`. Trend, TAF accuracy and forecast deviation are
    /// computed by the app for one specific METAR, so they're reused only when the cached
    /// snapshot describes the same observation. Otherwise they're omitted, never shown beside a
    /// newer report.
    nonisolated static func merge(live: WidgetWeatherSnapshot, cached: WidgetWeatherSnapshot?) -> WidgetWeatherSnapshot {
        guard let cached else { return live }
        let sameObservation = cached.observationTime == live.observationTime
        return WidgetWeatherSnapshot(
            icao: live.icao,
            iata: cached.iata ?? live.iata,
            airportName: cached.airportName.count > live.airportName.count ? cached.airportName : live.airportName,
            flightCategory: live.flightCategory,
            windDirection: live.windDirection,
            windSpeed: live.windSpeed,
            windGust: live.windGust,
            windIsVariable: live.windIsVariable,
            windReported: live.windReported,
            visibility: live.visibility,
            visibilityReported: live.visibilityReported,
            visibilityIsGreaterThan: live.visibilityIsGreaterThan,
            ceilingFeet: live.ceilingFeet,
            temperature: live.temperature,
            dewpoint: live.dewpoint,
            altimeter: live.altimeter,
            trendDirection: sameObservation ? cached.trendDirection : live.trendDirection,
            trendHeadline: sameObservation ? cached.trendHeadline : live.trendHeadline,
            tafAccuracyPct: sameObservation ? cached.tafAccuracyPct : nil,
            borrowedTafStation: sameObservation ? cached.borrowedTafStation : nil,
            borrowedTafLine: sameObservation ? cached.borrowedTafLine : nil,
            forecastWindDivergenceKt: sameObservation ? cached.forecastWindDivergenceKt : nil,
            forecastCeilingDivergenceFt: sameObservation ? cached.forecastCeilingDivergenceFt : nil,
            forecastVisibilityDivergenceSM: sameObservation ? cached.forecastVisibilityDivergenceSM : nil,
            isAdvisory: live.isAdvisory,
            observationTime: live.observationTime,
            snapshotTime: live.snapshotTime
        )
    }
}

#if DEBUG
// MARK: - Debug: re-dated copy (DEBUG builds only)
// For the widget's forced-report-age override and its previews. Compiled out of Release.
extension WidgetWeatherSnapshot {
    nonisolated func withObservationTime(_ observationTime: Date) -> WidgetWeatherSnapshot {
        WidgetWeatherSnapshot(
            icao: icao, iata: iata, airportName: airportName, flightCategory: flightCategory,
            windDirection: windDirection, windSpeed: windSpeed, windGust: windGust,
            windIsVariable: windIsVariable, windReported: windReported,
            visibility: visibility, visibilityReported: visibilityReported,
            visibilityIsGreaterThan: visibilityIsGreaterThan, ceilingFeet: ceilingFeet,
            temperature: temperature, dewpoint: dewpoint, altimeter: altimeter,
            trendDirection: trendDirection, trendHeadline: trendHeadline,
            tafAccuracyPct: tafAccuracyPct, forecastWindDivergenceKt: forecastWindDivergenceKt,
            forecastCeilingDivergenceFt: forecastCeilingDivergenceFt,
            forecastVisibilityDivergenceSM: forecastVisibilityDivergenceSM,
            isAdvisory: isAdvisory, observationTime: observationTime, snapshotTime: snapshotTime
        )
    }
}
#endif

// MARK: - Widget Airport Configuration
// Tracks which airport a widget instance should display.
// Stored in App Group UserDefaults, keyed by widget instance ID.

nonisolated struct WidgetAirportConfig: Codable, Sendable {
    let icao: String
    let iata: String?
    let name: String
    let hasMetar: Bool

    static func from(_ airport: Airport) -> WidgetAirportConfig {
        WidgetAirportConfig(
            icao: airport.icao,
            iata: airport.iata,
            name: airport.name,
            hasMetar: airport.hasMetar
        )
    }
}
