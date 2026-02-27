import SwiftUI

struct NearestAirportsView: View {
    @EnvironmentObject var airportVM: AirportViewModel
    @StateObject private var locationService = LocationService.shared

    var body: some View {
        NavigationStack {
            Group {
                if airportVM.isLoadingNearest {
                    ProgressView("Finding nearby airports…")
                } else if airportVM.nearestAirports.isEmpty {
                    ContentUnavailableView(
                        "No Airports Found",
                        systemImage: "airplane.circle",
                        description: Text("Allow location access to find airports near you.")
                    )
                } else {
                    List(airportVM.nearestAirports) { airport in
                        NavigationLink(destination: WeatherDetailView(airport: airport)) {
                            AirportRowView(
                                airport: airport,
                                metar: airportVM.nearestMetars[airport.icao],
                                distance: airportVM.distance(to: airport)
                            )
                        }
                    }
                }
            }
            .navigationTitle("Nearest Airports")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Task { await airportVM.loadNearestAirports() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await airportVM.loadNearestAirports()
            }
            .refreshable {
                await airportVM.loadNearestAirports()
            }
        }
    }
}

// MARK: - Airport Row
struct AirportRowView: View {
    let airport: Airport
    let metar: Metar?
    let distance: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(airport.icao)
                        .font(.headline)
                    if let iata = airport.iata {
                        Text("/ \(iata)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(airport.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let dist = distance {
                    Text(dist)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let metar = metar {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(metar.flightCategory.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(metar.flightCategory.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
                    Text("\(metar.visibility.visibilityString)sm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
