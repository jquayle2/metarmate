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
        case .steady:        return .yellow
        case .deteriorating: return .red
        case .unknown:       return .gray
        }
    }
}

// MARK: - FlightCategoryBadge
struct FlightCategoryBadge: View {
    let category: FlightCategory

    var body: some View {
        Text(category.displayName)
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(category.swiftUIColor)
            .clipShape(Capsule())
    }
}

// MARK: - TrendIndicator
struct TrendIndicator: View {
    let direction: TrendDirection
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: direction.systemImage)
                .foregroundColor(direction.color)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(direction.rawValue)
                .font(.subheadline.bold())
                .foregroundColor(direction.color)
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

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(metar?.flightCategory.swiftUIColor ?? Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(airport.icao)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if let iata = airport.iata, !iata.isEmpty {
                        Text(iata)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(airport.name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let metar = metar {
                    Text(quickWeatherSummary(metar: metar))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let distance = distance {
                Text(distance)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
