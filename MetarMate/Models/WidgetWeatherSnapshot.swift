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
    let ceilingFeet: Int?           // AGL; nil = no ceiling
    let temperature: Int?           // Celsius
    let dewpoint: Int?              // Celsius
    let altimeter: Double?          // inHg

    // Trend
    let trendDirection: TrendDirection
    let trendHeadline: String       // e.g. "Wind Increasing (+8 kt)"

    // TAF accuracy (the widget differentiator)
    let tafAccuracyPct: Int?        // category accuracy; nil = no TAF

    // Forecast deviation (for medium widget)
    let forecastWindDivergenceKt: Int?
    let forecastCeilingDivergenceFt: Int?
    let forecastVisibilityDivergenceSM: Double?

    // Data source
    let isAdvisory: Bool            // true = Open-Meteo estimate, not official METAR
    let observationTime: Date       // when the METAR was observed (or advisory fetched)
    let snapshotTime: Date          // when the app wrote this snapshot

    // MARK: - Staleness
    var isStale: Bool {
        Date().timeIntervalSince(snapshotTime) > 3600   // older than 1 hour
    }

    var age: TimeInterval {
        Date().timeIntervalSince(observationTime)
    }

    // MARK: - Wind display (replicates Wind.displayString for widget use)
    var windDisplayString: String {
        if windReported == false { return "—" }
        if windSpeed == 0 { return "Calm" }
        let dir = windIsVariable ? "VRB" : "\(windDirection ?? 0)\u{00B0}"
        let base = "\(dir) \(windSpeed)kt"
        if let g = windGust { return "\(base) G\(g)" }
        return base
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
            visibility: metar.visibility,
            visibilityReported: metar.visibilityReported,
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
            observationTime: advisory.fetchTime,
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
        guard let metar = try? MetarParser.parse(raw: raw) else { return nil }

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
            visibility: metar.visibility,
            visibilityReported: metar.visibilityReported,
            ceilingFeet: metar.ceilingFeet,
            // temp/dewp/altimeter are read from `raw` (NOT `metar`) on purpose: Metar's fields are
            // non-optional and substitute 0 °C / 29.92 inHg for missing values (Finding 15), which
            // would fabricate a reading here. `raw.*.map` preserves nil = unknown.
            temperature: raw.temp.map { Int($0.rounded()) },
            dewpoint: raw.dewp.map { Int($0.rounded()) },
            altimeter: raw.altim.map { $0 * 0.02953 },
            trendDirection: .unknown,
            trendHeadline: "Widget Refresh",
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
