import SwiftUI
import CoreLocation

// MARK: - FlightCategory Display
extension FlightCategory {
    var displayName: String {
        switch self {
        case .vfr:     return "VFR"
        case .mvfr:    return "MVFR"
        case .ifr:     return "IFR"
        case .lifr:    return "LIFR"
        case .unknown: return "UNKN"
        }
    }
}

// MARK: - TrendDirection Color
extension TrendDirection {
    var color: Color {
        switch self {
        case .improving:     return .green
        case .steady:        return Color(.systemGray)
        case .deteriorating: return .red
        case .unknown:       return Color(.systemGray3)
        }
    }
}

// MARK: - FlightCategoryBadge
struct FlightCategoryBadge: View {
    let category: FlightCategory

    private var fontSize: CGFloat {
        switch category {
        case .mvfr, .lifr, .unknown: return 9
        default: return 11
        }
    }

    var body: some View {
        Text(category.displayName)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(category.swiftUIColor)
            .clipShape(Capsule())
            .fixedSize()
            .dynamicTypeSize(...DynamicTypeSize.xLarge)   // inline chrome pill
    }
}

// MARK: - TrendIndicator
struct TrendIndicator: View {
    let direction: TrendDirection
    let label: String
    var delta: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: direction.systemImage)
                .foregroundColor(direction.color)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(direction.rawValue)
                .font(.subheadline.bold())
                .foregroundColor(direction.color)
            if let delta = delta {
                Text(delta)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Quick Weather Summary
func quickWeatherSummary(metar: Metar) -> String {
    var parts: [String] = []

    parts.append(metar.skyCode)   // never "CLR" for FEW/SCT or a missing sky group

    let vis = metar.visibility.displayNumber.map { "\($0)SM" } ?? "—"   // .exact(6)->"6SM", .greaterThan(6)->"6+SM", .unknown->"—"
    parts.append(vis)

    let wind = metar.wind
    if !wind.isReported {
        parts.append("—")   // wind not reported (nil ≠ calm)
    } else if wind.speed == 0 {
        parts.append("Calm")
    } else {
        let dir = wind.directionCode
        if let gust = wind.gust {
            parts.append("\(dir)@\(wind.speed)G\(gust)")
        } else {
            parts.append("\(dir)@\(wind.speed)")
        }
    }

    return parts.joined(separator: " · ")
}

/// A vertical dashed rail — the structural "estimated/advisory" cue for station-less
/// airports (Rule 5: provenance is shown with shape, not a semantic color).
struct DashedRail: View {
    var color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: geo.size.width / 2, y: 1))
                p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height - 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: geo.size.width, lineCap: .round, dash: [4, 5]))
        }
    }
}

// MARK: - AirportRowView (Visual Refresh — badge 3A)
struct AirportRowView: View {
    let airport: Airport
    let metar: Metar?
    let distance: String?
    /// Estimated (Open-Meteo) conditions for genuinely station-less airports.
    var advisory: AdvisoryWeather? = nil
    /// Row state from RowWeatherLoader (Nearest, Search, Recents). When set it decides the rail and
    /// line 3 and `metar` / `advisory` are ignored; nil keeps the older lists (Favorites, Nearby
    /// sheet) as they were.
    var state: RowWeather? = nil
    /// Retry for a failed row: a small trailing button, on failed rows only.
    var onRetry: (() -> Void)? = nil
    /// The row's own ›. Only for a NavigationLink outside a List (Nearest's ScrollView): in a List
    /// the link already draws its chevron, and both showed.
    var showsChevron = false

    private var railColor: Color {
        // A resolved METAR (incl. numeric LIDs like 36K→K36K) drives the category color.
        if let metar = metar {
            return ColorRules.flightCategoryColor(metar.flightCategory)
        }
        return ColorRules.railColor(hasMetar: airport.hasMetar, category: .unknown)
    }

    /// Genuinely station-less airport running on estimated (Open-Meteo) data. Provenance is
    /// shown structurally (dashed rail + ~ tilde), NOT with a semantic color (Rule 5).
    private var isAdvisory: Bool { metar == nil && !airport.hasMetar }

    var body: some View {
        if let state {
            // Re-evaluated every minute so a reading crosses the 75-min cutoff on time, without a fetch.
            TimelineView(.everyMinute) { context in
                row(StateDisplay(state, airport: airport, at: context.date))
            }
        } else {
            row(nil)
        }
    }

    /// `display` is the state row's content; nil renders the older metar / advisory inputs.
    private func row(_ display: StateDisplay?) -> some View {
        HStack(spacing: 14) {
            // Status rail — solid flight-category color for a current METAR; a dashed neutral
            // rail marks estimated/advisory airports (never painted orange); solid neutral for a
            // row with no current reading (loading, stale, retrying, failed, no METAR).
            Group {
                if display?.dashedRail ?? isAdvisory {
                    DashedRail(color: Brand.slate)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(display?.railColor ?? railColor)
                }
            }
            .frame(width: 3)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: ICAO + IATA · distance (+ chevron)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(airport.icao)
                        .font(.avenir(19, .heavy))
                        .tracking(0.4)
                        .foregroundColor(Brand.cloud)
                    Spacer(minLength: 8)
                    if let distance = distance {
                        Text(distance)
                            .font(.brandMono(13, weight: .medium))
                            .foregroundColor(Brand.slate)
                    }
                    if showsChevron {
                        Text("›")
                            .font(.system(size: 16))
                            .foregroundColor(Brand.monoDim2)
                    }
                }

                // Line 2: airport name
                Text(airport.name)
                    .font(.avenir(14.5, .demibold))
                    .foregroundColor(Brand.fog2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // Line 3: mono conditions strip / advisory
                Group {
                    if let display { stateLine(display) } else { conditionsLine }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var conditionsLine: some View {
        // METAR-first: a fetched METAR (including a resolved numeric LID) always wins over
        // the airport's static hasMetar flag, so 36K→K36K shows real conditions.
        if let metar = metar {
            (Text("\(skyVisString(metar: metar)) · ")
                .foregroundColor(Brand.monoDim)
             + Text(windToken(metar.wind))
                .foregroundColor(ColorRules.windCodeColor(metar.wind)))
                .font(.brandMono(13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else if let adv = advisory {
            // Estimated conditions read neutral (leading "~" + the dashed rail carry the
            // "advisory" meaning); only the gust portion goes orange (Rule 5).
            advisoryConditions(adv)
                .font(.brandMono(13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else if !airport.hasMetar {
            Text("Advisory weather only")
                .font(.avenir(12.5, .bold))
                .foregroundColor(Brand.slate)
        } else {
            Text("METAR unavailable")
                .font(.brandMono(13, weight: .medium))
                .foregroundColor(Brand.monoDim2)
        }
    }

    /// Line 3 for a state row: the reading (dimmed with its observation age when it isn't current),
    /// or the state's note; the retry button on a failed row.
    private func stateLine(_ display: StateDisplay) -> some View {
        HStack(spacing: 8) {
            Group {
                if let metar = display.metar {
                    if display.isCurrent {
                        (Text("\(skyVisString(metar: metar)) · ")
                            .foregroundColor(Brand.monoDim)
                         + Text(windToken(metar.wind))
                            .foregroundColor(ColorRules.windCodeColor(metar.wind)))
                    } else {
                        // Not current: no category or wind color, so it can't read as current.
                        Text("\(skyVisString(metar: metar)) · \(windToken(metar.wind))")
                            .foregroundColor(Brand.monoDim2.opacity(0.7))
                        + Text(display.ageSuffix).foregroundColor(Brand.slate)
                    }
                } else if let adv = display.advisory {
                    if display.isCurrent {
                        advisoryConditions(adv)
                    } else {
                        Text(advisoryConditionsPlain(adv)).foregroundColor(Brand.monoDim2.opacity(0.7))
                    }
                } else {
                    Text(display.note ?? "—").foregroundColor(Brand.monoDim2)
                }
            }
            .font(.brandMono(13, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if let note = display.note, display.metar != nil || display.advisory != nil {
                Text("· \(note)")
                    .font(.brandMono(12, weight: .medium))
                    .foregroundColor(Brand.slate)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, display.showRetry ? 32 : 0)   // room for the retry button
        .overlay(alignment: .trailing) {
            if display.showRetry, let onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Brand.fog2)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)   // its own tap target inside the row's NavigationLink
                .accessibilityLabel("Retry \(airport.icao) weather")
            }
        }
    }

    /// The advisory strip as plain text (no colors), for a reading that isn't current.
    private func advisoryConditionsPlain(_ adv: AdvisoryWeather) -> String {
        var parts = ["~\(adv.cloudCoverDescription)"]
        if let mi = adv.visibilityMiles { parts.append(mi >= 10 ? "~10+SM" : "~\(Int(mi.rounded()))SM") }
        if adv.windSpeedKtRounded == 0 {
            parts.append("~CALM")
        } else {
            let dir = adv.windDirectionRounded10.map { String(format: "%03d", $0) } ?? "VRB"
            parts.append("~\(dir)@\(adv.windSpeedKtRounded)" + (adv.reportableGustKt.map { "G\($0)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }

    /// "~SCT · ~9SM · ~130@10G18" — estimated Open-Meteo data. Sky/vis read neutral (the ~
    /// tilde + dashed rail carry "estimated"); the whole wind token is colored by the same
    /// wind rule as a real METAR row, so advisory and station rows read identically.
    private func advisoryConditions(_ adv: AdvisoryWeather) -> Text {
        var t = Text("~\(adv.cloudCoverDescription)").foregroundColor(Brand.monoDim)
        if let mi = adv.visibilityMiles {
            let v = mi >= 10 ? "10+SM" : "\(Int(mi.rounded()))SM"
            t = t + Text(" · ~\(v)").foregroundColor(Brand.monoDim)
        }
        let windText: String
        if adv.windSpeedKtRounded == 0 {
            windText = "~CALM"
        } else {
            let dir = adv.windDirectionRounded10.map { String(format: "%03d", $0) } ?? "VRB"
            windText = "~\(dir)@\(adv.windSpeedKtRounded)" + (adv.reportableGustKt.map { "G\($0)" } ?? "")
        }
        let windColor = ColorRules.windColor(speedKt: adv.windSpeedKtRounded, gustKt: adv.reportableGustKt)
        return t + Text(" · \(windText)").foregroundColor(windColor)
    }

    private func skyVisString(metar: Metar) -> String {
        var parts: [String] = []
        parts.append(metar.skyCode)   // never "CLR" for FEW/SCT or a missing sky group
        let vis = metar.visibility.displayNumber.map { "\($0)SM" } ?? "—"   // .exact(6)->"6SM", .greaterThan(6)->"6+SM", .unknown->"—"
        parts.append(vis)
        return parts.joined(separator: " · ")
    }

    /// What a state row shows at `now`. A METAR reads as current (category rail, colored wind) only
    /// when it's the loaded reading and not over the 75-min cutoff (D#4, from observation time); a
    /// stale reading, or one kept through retrying / a failure, is dimmed with its age on a neutral
    /// rail. Loading, no METAR, retrying and failed with nothing to show are neutral text.
    struct StateDisplay {
        var metar: Metar?
        var advisory: AdvisoryWeather?
        var isCurrent = false
        var note: String?
        var showRetry = false
        var ageSuffix = ""
        var dashedRail = false

        var railColor: Color {
            guard isCurrent, let metar else { return Brand.slate }
            return ColorRules.flightCategoryColor(metar.flightCategory)
        }

        init(_ state: RowWeather, airport: Airport, at now: Date) {
            dashedRail = !airport.hasMetar
            switch state {
            case .loading:
                note = "—"
            case .noProduct:
                note = airport.hasMetar ? "No current METAR" : "Advisory weather only"
            case .loaded(let reading):
                show(reading, loaded: true, at: now)
            case .retrying(let last):
                note = "Retrying…"
                if let last { show(last, loaded: false, at: now) }
            case .failed(let last):
                showRetry = true
                if let last { show(last, loaded: false, at: now) } else { note = "Couldn't reach weather service" }
            }
        }

        private mutating func show(_ reading: RowReading, loaded: Bool, at now: Date) {
            switch reading {
            case .metar(let m):
                metar = m
                dashedRail = false
                let age = WidgetWeatherSnapshot.reportAge(observationTime: m.observationTime, at: now)
                if case .noCurrent = age { isCurrent = false } else { isCurrent = loaded }
                if !isCurrent {
                    let minutes = max(0, Int(now.timeIntervalSince(m.observationTime) / 60))
                    ageSuffix = " · \(WidgetWeatherSnapshot.ageText(minutes: minutes)) old"
                }
            case .advisory(let a):
                advisory = a
                dashedRail = true
                isCurrent = loaded
            }
        }
    }

    /// Wind token for the mono strip — CALM (green), or DDD@spd[Ggust] colored by gust rule.
    private func windToken(_ wind: Wind) -> String {
        guard wind.isReported else { return "—" }   // wind not reported (nil ≠ calm)
        if wind.speed == 0 { return "CALM" }
        let dir = wind.directionCode
        if let gust = wind.gust { return "\(dir)@\(wind.speed)G\(gust)" }
        return "\(dir)@\(wind.speed)"
    }
}

extension AirportRowView {
    /// A row driven by RowWeatherLoader state (Nearest, Search, Recents).
    init(airport: Airport, distance: String?, state: RowWeather, onRetry: (() -> Void)?, showsChevron: Bool = false) {
        self.init(airport: airport, metar: nil, distance: distance, advisory: nil, state: state, onRetry: onRetry,
                  showsChevron: showsChevron)
    }
}
