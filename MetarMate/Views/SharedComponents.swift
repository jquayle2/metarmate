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

    var body: some View {
        HStack(spacing: 12) {
            if airport.hasMetar {
                Circle()
                    .fill(metar?.flightCategory.swiftUIColor ?? Color.gray)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 10))
                    .frame(width: 10, height: 10)
            }

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
                if !airport.hasMetar {
                    Text("Advisory weather only")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if let metar = metar {
                    airportWeatherSummaryRow(metar: metar)
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

    // Wind color for airport list — orange/red only, matching detail view thresholds
    private func airportWindColor(_ wind: Wind) -> Color? {
        let speed = wind.speed
        let gust = wind.gust ?? 0
        let spread = gust - speed
        if gust >= 20 || speed >= 25 || spread >= 15 { return .red }
        if gust >= 15 || speed >= 20 || spread >= 10 { return .orange }
        return nil
    }

    @ViewBuilder
    private func airportWeatherSummaryRow(metar: Metar) -> some View {
        let wind = metar.wind
        let windColor = airportWindColor(wind)

        // Build sky+vis portion (always neutral)
        var skyVisParts: [String] = []
        if let ceiling = metar.ceilingFeet {
            let layer = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })
            let cov = layer?.coverage.rawValue ?? "BKN"
            skyVisParts.append("\(cov) \(ceiling / 100)")
        } else {
            skyVisParts.append("CLR")
        }
        let vis = metar.visibility >= 10 ? "10+SM" : "\(String(format: "%g", metar.visibility))SM"
        skyVisParts.append(vis)

        // Build wind portion
        var windStr = ""
        if wind.speed == 0 {
            windStr = "Calm"
        } else {
            let dir = wind.isVariable ? "VRB" : String(format: "%03d", wind.direction ?? 0)
            if let gust = wind.gust {
                windStr = "\(dir)@\(wind.speed)G\(gust)"
            } else {
                windStr = "\(dir)@\(wind.speed)"
            }
        }

        HStack(spacing: 0) {
            Text(skyVisParts.joined(separator: " · "))
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
