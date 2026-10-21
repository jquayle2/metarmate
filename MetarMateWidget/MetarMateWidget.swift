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

/// Observation time in the detail view's convention (local, then Zulu hour): "2:53 PM  (21Z)".
/// Same output as WeatherDetailView.historyTimeLabel, which isn't in the widget target.
/// Static so the formatters aren't re-allocated on every widget render.
private enum ObsTimeFormat {
    static let local: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        // autoupdating, not .current: this formatter is static, so a snapshot of the zone would
        // go stale if the device changes time zone while the extension process is alive.
        f.timeZone = .autoupdatingCurrent
        return f
    }()
    static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(_ date: Date) -> String {
        "\(local.string(from: date))  (\(utc.string(from: date)))"
    }
}

// MARK: - Report age presentation (DECISIONS_2026-10 #4)
// Shared by every family so the states can't drift. Late: conditions stay, with a warning.
// No current report: no category, no conditions, only the age. Text names the source (METAR or
// Advisory) so a stale advisory is never shown as, or without, its age.

private let noCurrentGrey = Color.gray

private extension WidgetWeatherSnapshot {
    var sourceNoun: String { isAdvisory ? "Advisory" : "METAR" }

    /// "METAR late: 68 min old"
    func lateText(minutes: Int) -> String { "\(sourceNoun) late: \(minutes) min old" }

    /// "No current METAR" / "No current advisory"
    var noCurrentText: String { isAdvisory ? "No current advisory" : "No current METAR" }

    /// "Last report 2 h 10 min ago"
    func lastReportText(minutes: Int) -> String {
        "Last report \(WidgetWeatherSnapshot.ageText(minutes: minutes)) ago"
    }

    /// Category colour, or grey once there's no current report.
    func categoryColor(_ age: ReportAge) -> Color {
        if case .noCurrent = age { return noCurrentGrey }
        return flightCategory.swiftUIColor
    }

    /// Category label, or "—" once there's no current report.
    func categoryLabel(_ age: ReportAge) -> String {
        if case .noCurrent = age { return "—" }
        return flightCategory.rawValue
    }
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

    static func fetchSnapshot(icao: String) async -> (snapshot: WidgetWeatherSnapshot?, outcome: String) {
        guard let url = URL(string: "\(baseURL)/metar?ids=\(icao)&format=json&hours=2") else { return (nil, "bad URL") }
        do {
            // Bypass the URL cache (a refresh must hit NOAA) and fail fast instead of the 60 s
            // default — the extension's run time is limited.
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (nil, "no HTTP response") }
            guard http.statusCode == 200 else { return (nil, "HTTP \(http.statusCode)") }
            let raws = try JSONDecoder().decode([RawMetar].self, from: data)
            guard let raw = raws.first else { return (nil, "no reports") }
            // Snapshot builder lives on WidgetWeatherSnapshot (shared + unit-testable); nil = the
            // observation couldn't be parsed, propagated the same as a fetch/decode failure.
            guard let snapshot = WidgetWeatherSnapshot.from(rawMetar: raw, icao: icao) else {
                return (nil, "unparseable: \(raw.rawOb ?? "no rawOb")")
            }
            return (snapshot, "ok obs \(WidgetDiag.zulu(snapshot.observationTime))")
        } catch let error as URLError {
            return (nil, "URLError \(error.code.rawValue)")
        } catch {
            return (nil, "error: \(error.localizedDescription)")
        }
    }

}

// MARK: - Run diagnostics
// Every provider run appends one line to an App Group ring buffer (WidgetDataManager.appendDiag),
// readable off the device, so a stuck widget shows whether WidgetKit stopped calling us or the
// fetch is failing. Line: "<run time Z> <kind> <ICAO> <configured|fallback> <outcome>".

enum WidgetDiag {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let zuluFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ddHHmm'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func zulu(_ date: Date) -> String { zuluFormatter.string(from: date) }

    static func record(kind: String, icao: String?, configured: Bool, outcome: String) {
        let line = "\(formatter.string(from: .now)) \(kind) \(icao ?? "-") \(configured ? "configured" : "fallback") \(outcome)"
        WidgetDataManager.appendDiag(line)
    }
}

// MARK: - Configurable Timeline Provider

struct ConfigurableProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MetarMateEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectAirportIntent, in context: Context) async -> MetarMateEntry {
        let (snapshot, requestedICAO) = await loadSnapshot(for: configuration, kind: context.isPreview ? "preview" : "snapshot")
        return MetarMateEntry(date: .now, snapshot: snapshot, requestedICAO: requestedICAO)
    }

    func timeline(for configuration: SelectAirportIntent, in context: Context) async -> Timeline<MetarMateEntry> {
        let loaded = await loadSnapshot(for: configuration, kind: "timeline")
        let requestedICAO = loaded.requestedICAO

        // One entry now, plus one at each future instant the report's age state or text changes
        // (late at obs+65, no current METAR over obs+75, then the "last report" age), so the
        // widget goes late/stale on time even when WidgetKit denies the next reload.
        let now = Date.now
        #if DEBUG
        let snapshot = debugForcedAge(loaded.snapshot, now: now)
        #else
        let snapshot = loaded.snapshot
        #endif
        let futureDates = snapshot?.ageChangeDates(after: now) ?? []
        let entries = ([now] + futureDates).map {
            MetarMateEntry(date: $0, snapshot: snapshot, requestedICAO: requestedICAO)
        }
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: now)!
        return Timeline(entries: entries, policy: .after(nextUpdate))
    }

    #if DEBUG
    /// DEBUG only: when the harness has set a forced report age, re-date the snapshot so it is
    /// exactly that old at `now`. Display only; the saved snapshot keeps its real observation time.
    private func debugForcedAge(_ snapshot: WidgetWeatherSnapshot?, now: Date) -> WidgetWeatherSnapshot? {
        let minutes = WidgetDataManager.debugForcedObsAgeMinutes()
        guard minutes > 0, let snapshot else { return snapshot }
        return snapshot.withObservationTime(now.addingTimeInterval(-TimeInterval(minutes * 60)))
    }
    #endif

    /// The airport to show and fetch: the configured one, or (unconfigured widget) the airport
    /// most recently written to the App Group, i.e. the last one viewed in the app. Either way the
    /// widget fetches live; an unconfigured widget used to replay the cache and never refreshed.
    private func loadSnapshot(for configuration: SelectAirportIntent, kind: String) async -> (snapshot: WidgetWeatherSnapshot?, requestedICAO: String?) {
        let configured = resolveICAO(for: configuration)
        guard let icao = configured ?? WidgetDataManager.mostRecent()?.icao else {
            WidgetDiag.record(kind: kind, icao: nil, configured: false, outcome: "no airport")
            return (nil, nil)
        }
        let cached = WidgetDataManager.load(icao: icao)
        let fetched = await WidgetFetcher.fetchSnapshot(icao: icao)
        WidgetDiag.record(kind: kind, icao: icao, configured: configured != nil, outcome: fetched.outcome)
        if let live = fetched.snapshot {
            let merged = WidgetWeatherSnapshot.merge(live: live, cached: cached)
            WidgetDataManager.save(snapshot: merged, reload: false)
            return (merged, nil)
        }
        // "Waiting for data" only for an airport the user chose; the fallback always has a cache.
        return (cached, cached == nil && configured != nil ? icao : nil)
    }

    private func resolveICAO(for configuration: SelectAirportIntent) -> String? {
        guard let code = configuration.airportCode, !code.isEmpty else { return nil }
        return code.uppercased().trimmingCharacters(in: .whitespaces)
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
    let date: Date

    var body: some View {
        if let snap = snapshot {
            let age = snap.reportAge(at: date)
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(snap.categoryLabel(age))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(snap.categoryColor(age))
                    Text(snap.icao)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            // Late: too small for text, so a "!" marks it.
            .overlay(alignment: .topTrailing) {
                if case .late = age {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
    let date: Date

    var body: some View {
        if let snap = snapshot {
            let age = snap.reportAge(at: date)
            HStack(spacing: 6) {
                // Left: category color strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(snap.categoryColor(age))
                    .frame(width: 4)

                if case .noCurrent(let minutes) = age {
                    // No current report: the age replaces the conditions.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.icao)
                            .font(.system(.headline, design: .monospaced, weight: .bold))
                        Text(snap.noCurrentText)
                            .font(.system(.caption, weight: .semibold))
                        Text(snap.lastReportText(minutes: minutes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        // Top row: ICAO + category
                        HStack(spacing: 4) {
                            Text(snap.icao)
                                .font(.system(.headline, design: .monospaced, weight: .bold))
                            Text(snap.flightCategory.rawValue)
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(snap.flightCategory.swiftUIColor)
                            Spacer()
                            if case .late(let minutes) = age {
                                Text("LATE \(minutes)m")
                                    .font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(.orange)
                            } else if let pct = snap.tafAccuracyPct {
                                Text("TAF \(pct)%")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Bottom row: wind + trend
                        HStack(spacing: 4) {
                            Text(snap.windDisplayString)
                                .font(.system(.caption, design: .monospaced))
                            if snap.hasTrend {
                                Image(systemName: snap.trendDirection.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(trendColor(snap.trendDirection))
                            }
                            Spacer()
                        }
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
    let date: Date

    var body: some View {
        if let snap = snapshot {
            switch snap.reportAge(at: date) {
            case .current:
                let arrow = trendArrow(snap.trendDirection)
                Text("\(snap.icao) \(snap.flightCategory.rawValue) \(snap.windDisplayString) \(arrow)")
            case .late(let minutes):
                Text("\(snap.icao) · late \(minutes)m")
            case .noCurrent:
                Text("\(snap.icao) · \(snap.isAdvisory ? "no current advisory" : "no current METAR")")
            }
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
    let date: Date

    var body: some View {
        if !WidgetDataManager.loadProStatus() {
            ProRequiredView()
        } else if let snap = snapshot {
            let age = snap.reportAge(at: date)
            HStack(spacing: 0) {
                // Left-edge category strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(snap.categoryColor(age))
                    .frame(width: 4)
                    .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 5) {
                    // Airport ID + category badge
                    HStack(spacing: 5) {
                        Text(snap.icao)
                            .font(.system(.subheadline, design: .monospaced, weight: .bold))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(snap.categoryLabel(age))
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(snap.categoryColor(age), in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        Button(intent: RefreshWidgetIntent()) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if case .noCurrent(let minutes) = age {
                        // No current report: the age replaces the conditions and trend.
                        Text(snap.noCurrentText)
                            .font(.system(.caption, weight: .semibold))
                        Text(snap.lastReportText(minutes: minutes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    } else {
                        smallConditions(snap)
                    }

                    // Observation time centered at bottom; replaced by the warning when late.
                    if case .late(let minutes) = age {
                        Text("\(snap.sourceNoun) late · \(minutes) min")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text(ObsTimeFormat.string(snap.observationTime))
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

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

    /// Wind, visibility/ceiling and trend: shown while the report is current or late.
    @ViewBuilder
    private func smallConditions(_ snap: WidgetWeatherSnapshot) -> some View {
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
                Text(snap.visibilityDisplay)
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

        // Trend (full width); omitted when the app hasn't analysed this observation
        if snap.hasTrend {
            HStack(spacing: 3) {
                Image(systemName: snap.trendDirection.systemImage)
                    .font(.caption2)
                    .foregroundStyle(trendColor(snap.trendDirection))
                Text(shortTrendLabel(snap.trendHeadline))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Widget Configurations

struct MetarMateLockScreenCircular: Widget {
    let kind = "MetarMateLockScreenCircular"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectAirportIntent.self, provider: ConfigurableProvider()) { entry in
            LockScreenCircularView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO, date: entry.date)
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
            LockScreenRectangularView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO, date: entry.date)
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
            LockScreenInlineView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO, date: entry.date)
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
            HomeScreenSmallView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO, date: entry.date)
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
    let date: Date

    var body: some View {
        if !WidgetDataManager.loadProStatus() {
            ProRequiredView()
        } else if let snap = snapshot {
            let age = snap.reportAge(at: date)
            HStack(spacing: 0) {
                // Left-edge category strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(snap.categoryColor(age))
                    .frame(width: 4)
                    .padding(.trailing, 10)

                // Left column: identity + conditions
                VStack(alignment: .leading, spacing: 5) {
                    // Airport + category badge
                    HStack(spacing: 6) {
                        Text(snap.icao)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                        Text(snap.categoryLabel(age))
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(snap.categoryColor(age), in: RoundedRectangle(cornerRadius: 4))
                    }

                    if case .noCurrent(let minutes) = age {
                        // No current report: the age replaces the conditions.
                        Text(snap.noCurrentText)
                            .font(.system(.callout, weight: .semibold))
                        Text(snap.lastReportText(minutes: minutes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        mediumConditions(snap)
                    }

                    Spacer(minLength: 0)

                    // Bottom: observation time (the warning when late) + advisory
                    HStack(spacing: 6) {
                        if case .late(let minutes) = age {
                            Text(snap.lateText(minutes: minutes))
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(.orange)
                        } else {
                            Text(ObsTimeFormat.string(snap.observationTime))
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(.tertiary)
                        }
                        if snap.isAdvisory {
                            Text("~Advisory")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer(minLength: 8)

                // Right column: trend + forecast deviation + TAF, only while there's a current
                // (or late) report to describe.
                if case .noCurrent = age {
                    EmptyView()
                } else {
                    trendColumn(snap)
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

    /// Wind, gust spread, ceiling and visibility: shown while the report is current or late.
    @ViewBuilder
    private func mediumConditions(_ snap: WidgetWeatherSnapshot) -> some View {
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
            Label(snap.visibilityReported == false ? "—" : "\(snap.visibilityDisplay) SM", systemImage: "eye")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func trendColumn(_ snap: WidgetWeatherSnapshot) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            // Trend headline; omitted when the app hasn't analysed this observation
            if snap.hasTrend {
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
            HomeScreenMediumView(snapshot: entry.snapshot, requestedICAO: entry.requestedICAO, date: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(detailURL(for: entry.snapshot))
        }
        .configurationDisplayName("Airport Weather Detail")
        .description("Wind, trend, forecast deviation, and TAF accuracy.")
        .supportedFamilies([.systemMedium])
    }
}

#if DEBUG
// MARK: - Previews (DEBUG only)
// Each family steps through current (20 min), late (68 min), no current METAR (2 h 10 min) and an
// advisory with no current data. States come from the entry date vs observation time, exactly as
// the live timeline renders them.

private enum WidgetPreviewData {
    static let now = Date()

    static func metar(ageMinutes: Int) -> WidgetWeatherSnapshot {
        WidgetWeatherSnapshot(
            icao: "KVGT", iata: "VGT", airportName: "North Las Vegas", flightCategory: .mvfr,
            windDirection: 210, windSpeed: 15, windGust: 25, windIsVariable: false, windReported: true,
            visibility: 4, visibilityReported: true, ceilingFeet: 2_500,
            temperature: 18, dewpoint: 9, altimeter: 29.92,
            trendDirection: .deteriorating, trendHeadline: "Ceiling Falling",
            tafAccuracyPct: 78, forecastWindDivergenceKt: 8, forecastCeilingDivergenceFt: -600,
            forecastVisibilityDivergenceSM: nil, isAdvisory: false,
            observationTime: now.addingTimeInterval(-TimeInterval(ageMinutes * 60)), snapshotTime: now
        )
    }

    static func advisory(ageMinutes: Int) -> WidgetWeatherSnapshot {
        WidgetWeatherSnapshot(
            icao: "L15", iata: nil, airportName: "Henderson Field", flightCategory: .vfr,
            windDirection: 180, windSpeed: 8, windGust: nil, windIsVariable: false, windReported: true,
            visibility: 10, visibilityReported: true, ceilingFeet: nil,
            temperature: 20, dewpoint: 5, altimeter: nil,
            trendDirection: .steady, trendHeadline: "Advisory Data",
            tafAccuracyPct: nil, forecastWindDivergenceKt: nil, forecastCeilingDivergenceFt: nil,
            forecastVisibilityDivergenceSM: nil, isAdvisory: true,
            observationTime: now.addingTimeInterval(-TimeInterval(ageMinutes * 60)), snapshotTime: now
        )
    }

    static var entries: [MetarMateEntry] {
        [
            MetarMateEntry(date: now, snapshot: metar(ageMinutes: 20), requestedICAO: nil),
            MetarMateEntry(date: now, snapshot: metar(ageMinutes: 68), requestedICAO: nil),
            MetarMateEntry(date: now, snapshot: metar(ageMinutes: 130), requestedICAO: nil),
            MetarMateEntry(date: now, snapshot: advisory(ageMinutes: 68), requestedICAO: nil),
            MetarMateEntry(date: now, snapshot: advisory(ageMinutes: 130), requestedICAO: nil),
        ]
    }
}

#Preview("Small", as: .systemSmall) {
    MetarMateHomeSmall()
} timeline: {
    for entry in WidgetPreviewData.entries { entry }
}

#Preview("Medium", as: .systemMedium) {
    MetarMateHomeMedium()
} timeline: {
    for entry in WidgetPreviewData.entries { entry }
}

#Preview("Lock circular", as: .accessoryCircular) {
    MetarMateLockScreenCircular()
} timeline: {
    for entry in WidgetPreviewData.entries { entry }
}

#Preview("Lock rectangular", as: .accessoryRectangular) {
    MetarMateLockScreenRectangular()
} timeline: {
    for entry in WidgetPreviewData.entries { entry }
}

#Preview("Lock inline", as: .accessoryInline) {
    MetarMateLockScreenInline()
} timeline: {
    for entry in WidgetPreviewData.entries { entry }
}
#endif
