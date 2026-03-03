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

// MARK: - Configurable Timeline Provider

struct ConfigurableProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MetarMateEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectAirportIntent, in context: Context) async -> MetarMateEntry {
        let icao = configuration.airportCode?.uppercased()
        let snapshot = resolveSnapshot(for: configuration)
        return MetarMateEntry(date: .now, snapshot: snapshot, requestedICAO: snapshot == nil ? icao : nil)
    }

    func timeline(for configuration: SelectAirportIntent, in context: Context) async -> Timeline<MetarMateEntry> {
        let icao = configuration.airportCode?.uppercased()
        let snapshot = resolveSnapshot(for: configuration)
        let entry = MetarMateEntry(date: .now, snapshot: snapshot, requestedICAO: snapshot == nil ? icao : nil)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func resolveSnapshot(for configuration: SelectAirportIntent) -> WidgetWeatherSnapshot? {
        if let code = configuration.airportCode, !code.isEmpty {
            let icao = code.uppercased().trimmingCharacters(in: .whitespaces)
            return WidgetDataManager.load(icao: icao)
        }
        return WidgetDataManager.mostRecent()
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
        if let snap = snapshot {
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
                            .font(.system(.title3, design: .monospaced, weight: .bold))
                        Text(snap.flightCategory.rawValue)
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(snap.flightCategory.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
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
        if let snap = snapshot {
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
        }
        .configurationDisplayName("Airport Weather Detail")
        .description("Wind, trend, forecast deviation, and TAF accuracy.")
        .supportedFamilies([.systemMedium])
    }
}
