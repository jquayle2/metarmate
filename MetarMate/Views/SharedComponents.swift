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

// MARK: - AirportRowView
struct AirportRowView: View {
    let airport: Airport
    let metar: Metar?
    let distance: String?

    private var categoryColor: Color {
        guard airport.hasMetar else { return .orange }
        return metar?.flightCategory.swiftUIColor ?? .gray
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left-edge flight category strip
            Rectangle()
                .fill(categoryColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.vertical, 6)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // ICAO prominent, IATA small and secondary
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(airport.icao)
                            .font(.system(.headline, design: .default).weight(.bold))
                            .foregroundColor(.primary)
                        if let iata = airport.iata, !iata.isEmpty {
                            Text(iata)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }

                    Text(airport.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if !airport.hasMetar {
                        Text("Advisory weather only")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else if let metar = metar {
                        airportWeatherSummaryRow(metar: metar)
                    }
                }

                Spacer()

                // Distance — visually secondary
                if let distance = distance {
                    Text(distance)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                        .fontWeight(.regular)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)
        }
    }

    // Wind color for airport list — orange/red only, matching detail view thresholds
    private func airportWindColor(_ wind: Wind) -> Color? {
        let speed = wind.speed
        let gust = wind.gust ?? 0
        let spread = gust - speed
        if gust >= 20 || speed >= 25 || spread >= 15 { return .red }
        if gust >= 15 || speed >= 20 || spread >= 10 { return .orange }
        return nil
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

    private func windString(wind: Wind) -> String {
        if wind.speed == 0 { return "Calm" }
        let dir = wind.isVariable ? "VRB" : String(format: "%03d", wind.direction ?? 0)
        if let gust = wind.gust { return "\(dir)@\(wind.speed)G\(gust)" }
        return "\(dir)@\(wind.speed)"
    }

    private func airportWeatherSummaryRow(metar: Metar) -> some View {
        let skyVis = skyVisString(metar: metar)
        let windStr = windString(wind: metar.wind)
        let windColor = airportWindColor(metar.wind)

        return HStack(spacing: 0) {
            Text(skyVis)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let color = windColor {
                Text(" · ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(windStr)
                    .font(.caption)
                    .foregroundColor(color)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } else {
                Text(" · \(windStr)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
