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

    let vis = metar.visibility >= 10 ? "10+SM" : "\(String(format: "%g", metar.visibility))SM"
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

// MARK: - AirportRowView (Visual Refresh — badge 3A)
struct AirportRowView: View {
    let airport: Airport
    let metar: Metar?
    let distance: String?
    /// Estimated (Open-Meteo) conditions for genuinely station-less airports.
    var advisory: AdvisoryWeather? = nil

    private var railColor: Color {
        // A resolved METAR (incl. numeric LIDs like 36K→K36K) drives the category color;
        // only genuinely station-less airports get the advisory (caution-orange) rail.
        if let metar = metar {
            return ColorRules.flightCategoryColor(metar.flightCategory)
        }
        return ColorRules.railColor(hasMetar: airport.hasMetar, category: .unknown)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Status rail — flight-category color, full row height.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(railColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: ICAO + IATA · distance + chevron
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(airport.icao)
                        .font(.avenir(19, .heavy))
                        .tracking(0.4)
                        .foregroundColor(Brand.cloud)
                    if let iata = airport.iata, !iata.isEmpty {
                        Text(iata)
                            .font(.avenir(11, .bold))
                            .tracking(1.1)
                            .foregroundColor(Brand.monoDim)
                    }
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
        } else if let adv = advisory {
            // Estimated conditions — leading "~" marks the whole strip as advisory.
            Text(advisorySummary(adv))
                .font(.brandMono(13, weight: .medium))
                .foregroundColor(Brand.cautionOrange)
                .lineLimit(1)
        } else if !airport.hasMetar {
            Text("Advisory weather only")
                .font(.avenir(12.5, .bold))
                .foregroundColor(Brand.cautionOrange)
        } else {
            Text("METAR unavailable")
                .font(.brandMono(13, weight: .medium))
                .foregroundColor(Brand.monoDim2)
        }
    }

    /// "~SCT · ~9SM · ~130@10G18" — estimated summary from Open-Meteo advisory data.
    private func advisorySummary(_ adv: AdvisoryWeather) -> String {
        var parts: [String] = [adv.cloudCoverDescription]
        if let mi = adv.visibilityMiles {
            parts.append(mi >= 10 ? "10+SM" : "\(Int(mi.rounded()))SM")
        }
        if adv.windSpeedKtRounded == 0 {
            parts.append("CALM")
        } else {
            let dir = adv.windDirectionDeg.map { String(format: "%03d", $0) } ?? "VRB"
            if let g = adv.windGustKtRounded, g > adv.windSpeedKtRounded {
                parts.append("\(dir)@\(adv.windSpeedKtRounded)G\(g)")
            } else {
                parts.append("\(dir)@\(adv.windSpeedKtRounded)")
            }
        }
        return "~" + parts.joined(separator: " · ~")
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
        let vis = metar.visibility >= 10 ? "10+SM" : "\(String(format: "%g", metar.visibility))SM"
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
