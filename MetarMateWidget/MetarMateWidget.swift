import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct MetarMateEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetWeatherSnapshot?

    static var placeholder: MetarMateEntry {
        MetarMateEntry(date: .now, snapshot: nil)
    }
}

// MARK: - Timeline Provider

struct MetarMateProvider: TimelineProvider {
    func placeholder(in context: Context) -> MetarMateEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (MetarMateEntry) -> Void) {
        let snapshot = WidgetDataManager.mostRecent()
        completion(MetarMateEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MetarMateEntry>) -> Void) {
        let snapshot = WidgetDataManager.mostRecent()
        let entry = MetarMateEntry(date: .now, snapshot: snapshot)

        // Refresh in 30 minutes — aligns roughly with METAR update cadence
        // The main app writes fresh snapshots on every fetch, so the widget
        // just needs to wake up and re-read periodically.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Lock Screen Circular Widget (Category Badge)
// Shows flight category as a colored circle — the most glanceable format.

struct LockScreenCircularView: View {
    let snapshot: WidgetWeatherSnapshot?

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

    private func trendColor(_ trend: TrendDirection) -> Color {
        switch trend {
        case .improving: return .green
        case .steady: return .gray
        case .deteriorating: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - Lock Screen Inline Widget
// Single line: "KVGT VFR 230° 15G22kt ↑"

struct LockScreenInlineView: View {
    let snapshot: WidgetWeatherSnapshot?

    var body: some View {
        if let snap = snapshot {
            let arrow = trendArrow(snap.trendDirection)
            Text("\(snap.icao) \(snap.flightCategory.rawValue) \(snap.windDisplayString) \(arrow)")
        } else {
            Text("MetarMate")
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
}

// MARK: - Home Screen Small Widget
// Airport + category badge + wind + trend

struct HomeScreenSmallView: View {
    let snapshot: WidgetWeatherSnapshot?

    var body: some View {
        if let snap = snapshot {
            VStack(alignment: .leading, spacing: 4) {
                // Airport ID + category badge
                HStack(spacing: 4) {
                    Text(snap.icao)
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                    Text(snap.flightCategory.rawValue)
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(snap.flightCategory.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                // Wind
                HStack(spacing: 4) {
                    Image(systemName: "wind")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(snap.windDisplayString)
                        .font(.system(.callout, design: .monospaced))
                }

                // Gust spread (if gusty)
                if let gust = snap.windGust {
                    let spread = gust - snap.windSpeed
                    Text("Gust spread: \(spread) kt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Trend
                HStack(spacing: 3) {
                    Image(systemName: snap.trendDirection.systemImage)
                        .font(.caption2)
                        .foregroundStyle(trendColor(snap.trendDirection))
                    Text(snap.trendHeadline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Advisory indicator
                if snap.isAdvisory {
                    Text("~Advisory")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.orange)
                }

                // Staleness
                if snap.isStale {
                    Text("Data may be stale")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "airplane.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Open MetarMate\nto load weather")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func trendColor(_ trend: TrendDirection) -> Color {
        switch trend {
        case .improving: return .green
        case .steady: return .gray
        case .deteriorating: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - Widget Configurations

struct MetarMateLockScreenCircular: Widget {
    let kind = "MetarMateLockScreenCircular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MetarMateProvider()) { entry in
            LockScreenCircularView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Flight Category")
        .description("Category badge for your last viewed airport.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct MetarMateLockScreenRectangular: Widget {
    let kind = "MetarMateLockScreenRectangular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MetarMateProvider()) { entry in
            LockScreenRectangularView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Airport Weather")
        .description("Airport ID, category, wind, and trend at a glance.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct MetarMateLockScreenInline: Widget {
    let kind = "MetarMateLockScreenInline"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MetarMateProvider()) { entry in
            LockScreenInlineView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Weather Inline")
        .description("One-line airport weather summary.")
        .supportedFamilies([.accessoryInline])
    }
}

struct MetarMateHomeSmall: Widget {
    let kind = "MetarMateHomeSmall"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MetarMateProvider()) { entry in
            if #available(iOS 17.0, *) {
                HomeScreenSmallView(snapshot: entry.snapshot)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                HomeScreenSmallView(snapshot: entry.snapshot)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Airport Weather")
        .description("Wind, category, and trend for your last viewed airport.")
        .supportedFamilies([.systemSmall])
    }
}
