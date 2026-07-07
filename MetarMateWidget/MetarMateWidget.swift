import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared helpers

private func trendColor(_ trend: TrendDirection) -> Color {
    switch trend {
    case .improving: return .green
    case .steady: return .gray
    case .deteriorating: return .red
    case .unknown: return .gray
    }
}

private func trendArrow(_ trend: TrendDirection) -> String {
    switch trend {
    case .improving: return "\u{2191}"
    case .steady: return "\u{2192}"
    case .deteriorating: return "\u{2193}"
    case .unknown: return ""
    }
}

private func tafColor(_ pct: Int) -> Color {
    if pct >= 80 { return .green }
    if pct >= 60 { return .yellow }
    return .red
}

/// Compact ceiling string for small widget: "1.4K" instead of "1,400"
private func compactCeiling(_ ft: Int) -> String {
    if ft >= 10000 { return "\(ft / 1000)K" }
    if ft >= 1000 { return String(format: "%.1fK", Double(ft) / 1000.0) }
    return "\(ft)"
}

/// Short trend label for small widget — avoids truncation
private func shortTrendLabel(_ headline: String) -> String {
    let map: [String: String] = [
        "Stable Conditions": "Stable",
        "No Trend Data": "No Data",
        "Deterioration Forecast": "Fcst: Down",
        "Improvement Forecast": "Fcst: Up",
        "Wind Decreasing": "Wind Down",
    ]
    if let short = map[headline] { return short }
    if headline.hasPrefix("Ceiling Rising") { return "Ceil Up" }
    if headline.hasPrefix("Ceiling Falling") { return "Ceil Down" }
    if headline.hasPrefix("Visibility Increasing") { return "Vis Up" }
    if headline.hasPrefix("Visibility Decreasing") { return "Vis Down" }
    if headline.hasPrefix("Wind Increasing") { return "Wind Up" }
    return headline
}

/// Relative age string: "2m ago", "1h ago"
private func ageString(_ date: Date) -> String {
    let secs = Date().timeIntervalSince(date)
    if secs < 120 { return "Just now" }
    if secs < 3600 { return "\(Int(secs / 60))m ago" }
    return "\(Int(secs / 3600))h ago"
}

/// Deep link opened by MetarMateApp.onOpenURL to jump straight to this airport's detail page —
/// a tap outside the widget's interactive buttons follows this instead of just opening the app
/// to wherever it was last left.
private func detailURL(for snapshot: WidgetWeatherSnapshot?) -> URL? {
    guard let snapshot else { return nil }
    return URL(string: "metarmate://airport/\(snapshot.icao)")
}

// SelectAirportIntent is defined in MetarMate/Intents/SelectAirportIntent.swift

// MARK: - Timeline Entry

struct MetarMateEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetWeatherSnapshot?
    let requestedICAO: String?  // non-nil when user selected an airport but no data exists yet

    static var placeholder: MetarMateEntry {
        MetarMateEntry(date: .now, snapshot: nil, requestedICAO: nil)
    }
}

// MARK: - Lightweight NOAA fetch for widget extension
// Avoids importing WeatherService/MetarParser (too heavy for extension).
// Fetches a single METAR and builds a WidgetWeatherSnapshot directly.

private enum WidgetFetcher {
    static let baseURL = "https://aviationweather.gov/api/data"

    static func fetchSnapshot(icao: String) async -> WidgetWeatherSnapshot? {
        guard let url = URL(string: "\(baseURL)/metar?ids=\(icao)&format=json&hours=2") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let raws = try JSONDecoder().decode([RawMetar].self, from: data)
            guard let raw = raws.first else { return nil }
            return buildSnapshot(from: raw, icao: icao)
        } catch {
            return nil
        }
    }

    private static func buildSnapshot(from raw: RawMetar, icao: String) -> WidgetWeatherSnapshot {
        let stationId = raw.icaoId ?? icao
        let fltCat = FlightCategory(rawValue: raw.fltCat ?? "VFR") ?? .vfr

        let windDir = parseWindDirection(raw.wdir)
        let windSpd = raw.wspd ?? 0
        let windGst = raw.wgst
        let isVariable = isVRB(raw.wdir)

        let vis = parseVisibility(raw.visib)

        let ceilingFt = parseCeiling(raw.clouds)

        let obsDate: Date
        if let epoch = raw.obsTime {
            obsDate = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else {
            obsDate = Date()
        }

        return WidgetWeatherSnapshot(
            icao: stationId,
            iata: nil,
            airportName: raw.name ?? stationId,
            flightCategory: fltCat,
            windDirection: windDir,
            windSpeed: windSpd,
            windGust: windGst,
            windIsVariable: isVariable,
            visibility: vis,
            ceilingFeet: ceilingFt,
            temperature: raw.temp.map { Int($0) },
            dewpoint: raw.dewp.map { Int($0) },
            altimeter: raw.altim.map { $0 * 0.02953 },
            trendDirection: .unknown,
            trendHeadline: "Widget Refresh",
            tafAccuracyPct: nil,
            forecastWindDivergenceKt: nil,
            forecastCeilingDivergenceFt: nil,
            forecastVisibilityDivergenceSM: nil,
            isAdvisory: false,
            observationTime: obsDate,
            snapshotTime: Date()
        )
    }

    private static func parseWindDirection(_ wdir: AnyCodable?) -> Int? {
        guard let w = wdir?.value else { return nil }
        if let i = w as? Int { return i }
        if let d = w as? Double { return Int(d) }
        if let s = w as? String, let i = Int(s) { return i }
        return nil
    }

    private static func isVRB(_ wdir: AnyCodable?) -> Bool {
        guard let w = wdir?.value else { return false }
        if let s = w as? String, s.uppercased() == "VRB" { return true }
        return false
    }

    private static func parseVisibility(_ visib: AnyCodable?) -> Double {
        guard let v = visib?.value else { return 10 }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String {
            if s.contains("10+") || s.contains("P6") || s.contains("6+") { return 10 }
            if let d = Double(s) { return d }
        }
        return 10
    }

    private static func parseCeiling(_ clouds: [[String: AnyCodable]]?) -> Int? {
        guard let layers = clouds else { return nil }
        for layer in layers {
            guard let coverVal = layer["cover"]?.value as? String else { continue }
            let cover = coverVal.uppercased()
            if cover == "BKN" || cover == "OVC" || cover == "VV" {
                if let baseVal = layer["base"]?.value {
                    if let i = baseVal as? Int { return i }
                    if let d = baseVal as? Double { return Int(d) }
                }
            }
        }
        return nil
    }
}

// MARK: - Configurable Timeline Provider

struct ConfigurableProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MetarMateEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectAirportIntent, in context: Context) async -> MetarMateEntry {
        let icao = resolveICAO(for: configuration)
        if let icao {
            let cached = WidgetDataManager.load(icao: icao)
            if let live = await WidgetFetcher.fetchSnapshot(icao: icao) {
                let merged = mergeWithCached(live: live, cached: cached)
                WidgetDataManager.save(snapshot: merged)
                return MetarMateEntry(date: .now, snapshot: merged, requestedICAO: nil)
            }
            return MetarMateEntry(date: .now, snapshot: cached, requestedICAO: cached == nil ? icao : nil)
        }
        let cached = WidgetDataManager.mostRecent()
        return MetarMateEntry(date: .now, snapshot: cached, requestedICAO: nil)
    }

    func timeline(for configuration: SelectAirportIntent, in context: Context) async -> Timeline<MetarMateEntry> {
        let icao = resolveICAO(for: configuration)
        var snapshot: WidgetWeatherSnapshot?
        var requestedICAO: String?

        if let icao {
            let cached = WidgetDataManager.load(icao: icao)
            if let live = await WidgetFetcher.fetchSnapshot(icao: icao) {
                let merged = mergeWithCached(live: live, cached: cached)
                WidgetDataManager.save(snapshot: merged)
                snapshot = merged
            } else {
                snapshot = cached
                if snapshot == nil { requestedICAO = icao }
            }
        } else {
            snapshot = WidgetDataManager.mostRecent()
        }

        let entry = MetarMateEntry(date: .now, snapshot: snapshot, requestedICAO: requestedICAO)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func resolveICAO(for configuration: SelectAirportIntent) -> String? {
        guard let code = configuration.airportCode, !code.isEmpty else { return nil }
        return code.uppercased().trimmingCharacters(in: .whitespaces)
    }

    private func mergeWithCached(live: WidgetWeatherSnapshot, cached: WidgetWeatherSnapshot?) -> WidgetWeatherSnapshot {
        guard let cached else { return live }
        return WidgetWeatherSnapshot(
            icao: live.icao,
            iata: cached.iata ?? live.iata,
            airportName: cached.airportName.count > live.airportName.count ? cached.airportName : live.airportName,
            flightCategory: live.flightCategory,
            windDirection: live.windDirection,
            windSpeed: live.windSpeed,
            windGust: live.windGust,
            windIsVariable: live.windIsVariable,
            visibility: live.visibility,
            ceilingFeet: live.ceilingFeet,
            temperature: live.temperature,
            dewpoint: live.dewpoint,
            altimeter: live.altimeter,
            trendDirection: live.trendDirection != .unknown ? live.trendDirection : cached.trendDirection,
            trendHeadline: live.trendHeadline != "Widget Refresh" ? live.trendHeadline : cached.trendHeadline,
            tafAccuracyPct: cached.tafAccuracyPct,
            forecastWindDivergenceKt: cached.forecastWindDivergenceKt,
            forecastCeilingDivergenceFt: cached.forecastCeilingDivergenceFt,
            forecastVisibilityDivergenceSM: cached.forecastVisibilityDivergenceSM,
            isAdvisory: live.isAdvisory,
            observationTime: live.observationTime,
            snapshotTime: live.snapshotTime
        )
    }
}

/// "Pro required" placeholder shown in home screen widgets for free users
private struct ProRequiredView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Pro Required")
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Upgrade in\nMetarMate")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lock Screen Circular Widget (Category Badge)
// Shows flight category as a colored circle — the most glanceable format.

struct LockScreenCircularView: View {
    let snapshot: WidgetWeatherSnapshot?
    let requestedICAO: String?

    var body: some View {
        if let snap = snapshot {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(snap.flightCategory.rawValue)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(snap.flightCategory.swiftUIColor)
                    Text(snap.icao)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "airplane")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Lock Screen Rectangular Widget (Full Summary)
// Shows airport ID, category, wind, and trend arrow.

struct LockScreenRectangularView: View {
    let snapshot: WidgetWeatherSnapshot?
    let requestedICAO: String?

    var body: some View {
        if let snap = snapshot {
            HStack(spacing: 6) {
                // Left: category color strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(snap.flightCategory.swiftUIColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 2) {
                    // Top row: ICAO + category
                    HStack(spacing: 4) {
                        Text(snap.icao)
                            .font(.system(.headline, design: .monospaced, weight: .bold))
                        Text(snap.flightCategory.rawValue)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(snap.flightCategory.swiftUIColor)
                        Spacer()
                        if let pct = snap.tafAccuracyPct {
                            Text("TAF \(pct)%")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Bottom row: wind + trend
                    HStack(spacing: 4) {
                        Text(snap.windDisplayString)
                            .font(.system(.caption, design: .monospaced))
                        Image(systemName: snap.trendDirection.systemImage)
                            .font(.caption2)
                            .foregroundStyle(trendColor(snap.trendDirection))
                        Spacer()
                    }
                }
            }
        } else {
            HStack {
                Image(systemName: "airplane")
                    .foregroundStyle(.secondary)
                Text("Open MetarMate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Lock Screen Inline Widget
// Single line: "KVGT VFR 230° 15G22kt ↑"

struct LockScreenInlineView: View {
    let snapshot: WidgetWeatherSnapshot?
    let requestedICAO: String?

    var body: some View {
        if let snap = snapshot {
            let arrow = trendArrow(snap.trendDirection)
            Text("\(snap.icao) \(snap.flightCategory.rawValue) \(snap.windDisplayString) \(arrow)")
        } else {
            Text("MetarMate")
        }
    }
}

// MARK: - Home Screen Small Widget
// Airport + category badge + wind + trend

struct HomeScreenSmallView: View {
    let snapshot: WidgetWeatherSnapshot?
    let requestedICAO: String?

    var body: some View {
        if !WidgetDataManager.loadProStatus() {
            ProRequiredView()
        } else if let snap = snapshot {
            HStack(spacing: 0) {
                // Left-edge category strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(snap.flightCategory.swiftUIColor)
                    .frame(width: 4)
                    .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 5) {
                    // Airport ID + category badge
                    HStack(spacing: 5) {
                        Text(snap.icao)
                            .font(.system(.subheadline, design: .monospaced, weight: .bold))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(snap.flightCategory.rawValue)
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(snap.flightCategory.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        Button(intent: RefreshWidgetIntent()) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Wind
                    HStack(spacing: 4) {
                        Image(systemName: "wind")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(snap.windDisplayString)
                            .font(.system(.callout, design: .monospaced))
                    }

                    // Visibility + ceiling
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Image(systemName: "eye")
                                .font(.system(size: 9))
                            Text(snap.visibility.visibilityString)
                                .font(.system(.caption2, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        if let ceil = snap.ceilingFeet {
                            HStack(spacing: 2) {
                                Image(systemName: "cloud")
                                    .font(.system(size: 9))
                                Text(compactCeiling(ceil))
                                    .font(.system(.caption2, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)

                    // Trend (full width)
                    HStack(spacing: 3) {
                        Image(systemName: snap.trendDirection.systemImage)
                            .font(.caption2)
                            .foregroundStyle(trendColor(snap.trendDirection))
                        Text(shortTrendLabel(snap.trendHeadline))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Age centered at bottom
                    Text(ageString(snap.observationTime))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // Advisory indicator
                    if snap.isAdvisory {
                        Text("~Advisory")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "airplane.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                if let icao = requestedICAO {
                    Text("Open \(icao)\nin MetarMate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Open MetarMate\nto load weather")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Widget Configurations

struct MetarMateLockScreenCircular: Widget {
    let kind = "MetarMateLockScreenCircular"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAirportIntent.self, provider: ConfigurableProvider()) { entry in
            LockScreenCircularView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Flight Category")
        .description("Category badge for a selected airport.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct MetarMateLockScreenRectangular: Widget {
    let kind = "MetarMateLockScreenRectangular"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAirportIntent.self, provider: ConfigurableProvider()) { entry in
            LockScreenRectangularView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Airport Weather")
        .description("Airport ID, category, wind, and trend at a glance.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct MetarMateLockScreenInline: Widget {
    let kind = "MetarMateLockScreenInline"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAirportIntent.self, provider: ConfigurableProvider()) { entry in
            LockScreenInlineView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Weather Inline")
        .description("One-line airport weather summary.")
        .supportedFamilies([.accessoryInline])
    }
}

struct MetarMateHomeSmall: Widget {
    let kind = "MetarMateHomeSmall"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAirportIntent.self, provider: ConfigurableProvider()) { entry in
            HomeScreenSmallView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(detailURL(for: entry.snapshot))
        }
        .configurationDisplayName("Airport Weather")
        .description("Wind, category, and trend for a selected airport.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Home Screen Medium Widget
// Full summary: wind, category, trend headline, forecast deviation, TAF accuracy.

struct HomeScreenMediumView: View {
    let snapshot: WidgetWeatherSnapshot?
    let requestedICAO: String?

    var body: some View {
        if !WidgetDataManager.loadProStatus() {
            ProRequiredView()
        } else if let snap = snapshot {
            HStack(spacing: 0) {
                // Left-edge category strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(snap.flightCategory.swiftUIColor)
                    .frame(width: 4)
                    .padding(.trailing, 10)

                // Left column: identity + conditions
                VStack(alignment: .leading, spacing: 5) {
                    // Airport + category badge
                    HStack(spacing: 6) {
                        Text(snap.icao)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                        Text(snap.flightCategory.rawValue)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(snap.flightCategory.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
                    }

                    // Wind
                    HStack(spacing: 4) {
                        Image(systemName: "wind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(snap.windDisplayString)
                            .font(.system(.callout, design: .monospaced, weight: .medium))
                    }

                    // Gust spread
                    if let gust = snap.windGust {
                        let spread = gust - snap.windSpeed
                        Text("Gust spread: \(spread) kt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Conditions row
                    HStack(spacing: 10) {
                        if let ceil = snap.ceilingFeet {
                            Label("\(ceil.formatted()) ft", systemImage: "cloud")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Label("\(snap.visibility.visibilityString) SM", systemImage: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    // Bottom: age + advisory
                    HStack(spacing: 6) {
                        Text(ageString(snap.observationTime))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if snap.isAdvisory {
                            Text("~Advisory")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer(minLength: 8)

                // Right column: trend + forecast deviation + TAF
                VStack(alignment: .trailing, spacing: 5) {
                    // Trend headline
                    HStack(spacing: 3) {
                        Image(systemName: snap.trendDirection.systemImage)
                            .font(.caption)
                            .foregroundStyle(trendColor(snap.trendDirection))
                        Text(snap.trendHeadline)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(trendColor(snap.trendDirection))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Forecast deviation lines
                    let hasDeviations = hasAnyDeviation(snap)
                    if hasDeviations {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let windDiv = snap.forecastWindDivergenceKt, abs(windDiv) > 5 {
                                deviationRow(
                                    label: "Wind",
                                    value: "\(windDiv > 0 ? "+" : "")\(windDiv) kt",
                                    severity: abs(windDiv) > 10 ? .significant : .minor
                                )
                            }
                            if let ceilDiv = snap.forecastCeilingDivergenceFt, abs(ceilDiv) > 300 {
                                deviationRow(
                                    label: "Ceil",
                                    value: "\(ceilDiv > 0 ? "+" : "")\(ceilDiv) ft",
                                    severity: abs(ceilDiv) > 800 ? .significant : .minor
                                )
                            }
                            if let visDiv = snap.forecastVisibilityDivergenceSM, abs(visDiv) > 0.5 {
                                deviationRow(
                                    label: "Vis",
                                    value: "\(visDiv > 0 ? "+" : "")\(String(format: "%g", visDiv)) SM",
                                    severity: abs(visDiv) > 2.0 ? .significant : .minor
                                )
                            }
                        }
                    } else if snap.tafAccuracyPct != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text("Fcst on target")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer(minLength: 0)

                    // TAF accuracy
                    if let pct = snap.tafAccuracyPct {
                        HStack(spacing: 3) {
                            Text("TAF")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text("\(pct)%")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(tafColor(pct))
                        }
                    }

                    // Staleness
                    if snap.isStale {
                        Text("Stale data")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                // Its own fixed-width slot, not an overlay, so it can't sit on top of the trend
                // headline that's already anchored at this row's top-trailing corner.
                VStack(spacing: 0) {
                    Button(intent: RefreshWidgetIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "airplane.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                if let icao = requestedICAO {
                    Text("Open \(icao) in MetarMate to load weather")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Open MetarMate to load weather")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hasAnyDeviation(_ snap: WidgetWeatherSnapshot) -> Bool {
        if let w = snap.forecastWindDivergenceKt, abs(w) > 5 { return true }
        if let c = snap.forecastCeilingDivergenceFt, abs(c) > 300 { return true }
        if let v = snap.forecastVisibilityDivergenceSM, abs(v) > 0.5 { return true }
        return false
    }

    private enum DeviationSeverity { case minor, significant }

    private func deviationRow(label: String, value: String, severity: DeviationSeverity) -> some View {
        HStack(spacing: 3) {
            Image(systemName: severity == .significant ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                .font(.system(size: 8))
                .foregroundStyle(severity == .significant ? .red : .yellow)
            Text("\(label): \(value)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(severity == .significant ? .red : .yellow)
        }
    }
}

struct MetarMateHomeMedium: Widget {
    let kind = "MetarMateHomeMedium"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAirportIntent.self, provider: ConfigurableProvider()) { entry in
            HomeScreenMediumView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(detailURL(for: entry.snapshot))
        }
        .configurationDisplayName("Airport Weather Detail")
        .description("Wind, trend, forecast deviation, and TAF accuracy.")
        .supportedFamilies([.systemMedium])
    }
}
