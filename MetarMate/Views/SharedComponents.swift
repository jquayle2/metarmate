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

    if let ceiling = metar.ceilingFeet {
        let layer = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })
        let cov = layer?.coverage.rawValue ?? "BKN"
        parts.append("\(cov) \(ceiling / 100)")
    } else {
        parts.append("CLR")
    }

    let vis = !metar.visibilityReported ? "—" : (metar.visibility >= 10 ? "10+SM" : "\(String(format: "%g", metar.visibility))SM")
    parts.append(vis)

    let wind = metar.wind
    if wind.speed == 0 {
        parts.append("Calm")
    } else {
        let dir = wind.isVariable ? "VRB" : String(format: "%03d", wind.direction ?? 0)
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
        HStack(spacing: 14) {
            // Status rail — solid flight-category color for a real METAR; a dashed neutral
            // rail marks estimated/advisory airports (never painted orange).
            Group {
                if isAdvisory {
                    DashedRail(color: Brand.slate)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(railColor)
                }
            }
            .frame(width: 3)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: ICAO + IATA · distance + chevron
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
                    Text("›")
                        .font(.system(size: 16))
                        .foregroundColor(Brand.monoDim2)
                }

                // Line 2: airport name
                Text(airport.name)
                    .font(.avenir(14.5, .demibold))
                    .foregroundColor(Brand.fog2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // Line 3: mono conditions strip / advisory
                conditionsLine
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
        if let ceiling = metar.ceilingFeet {
            let layer = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })
            let cov = layer?.coverage.rawValue ?? "BKN"
            parts.append("\(cov) \(ceiling / 100)")
        } else {
            parts.append("CLR")
        }
        let vis = !metar.visibilityReported ? "—" : (metar.visibility >= 10 ? "10+SM" : "\(String(format: "%g", metar.visibility))SM")
        parts.append(vis)
        return parts.joined(separator: " · ")
    }

    /// Wind token for the mono strip — CALM (green), or DDD@spd[Ggust] colored by gust rule.
    private func windToken(_ wind: Wind) -> String {
        if wind.speed == 0 { return "CALM" }
        let dir = wind.isVariable ? "VRB" : String(format: "%03d", wind.direction ?? 0)
        if let gust = wind.gust { return "\(dir)@\(wind.speed)G\(gust)" }
        return "\(dir)@\(wind.speed)"
    }
}
