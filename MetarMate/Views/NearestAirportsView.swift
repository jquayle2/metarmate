import SwiftUI
import CoreLocation

struct NearestAirportsView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @EnvironmentObject private var locationService: LocationService
    @State private var lastUpdated: Date? = nil

    private var nearestSubtitle: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10))
                Text("Sorted by distance")
                    .font(.caption)
                if let updated = lastUpdated {
                    Text("· Updated \(updated, style: .relative) ago")
                        .font(.caption)
                }
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .textCase(nil)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if locationService.authorizationStatus == .denied ||
                   locationService.authorizationStatus == .restricted {
                    locationDeniedView
                } else if airportVM.isLoadingNearest && airportVM.nearestAirports.isEmpty {
                    ProgressView("Finding nearest airports…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if airportVM.nearestAirports.isEmpty {
                    ContentUnavailableView(
                        "No Airports Found",
                        systemImage: "airplane.circle",
                        description: Text("No airports within 100 nm")
                    )
                } else {
                    List {
                        Section(header: nearestSubtitle) {}
                            .listRowInsets(EdgeInsets())
                            .listSectionSeparator(.hidden)
                        ForEach(airportVM.nearestAirports) { airport in
                            NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                AirportRowView(
                                    airport: airport,
                                    metar: airportVM.nearestMetars[airport.icao],
                                    distance: airportVM.distance(to: airport)
                                )
                            }
                            .listRowBackground(Color(.systemGray6).opacity(0.2))
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await airportVM.loadNearestAirports()
                        lastUpdated = Date()
                    }
                }
            }
            .navigationTitle("Nearest Airports")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if airportVM.isLoadingNearest {
                        ProgressView()
                    }
                }
            }
        }
        .task {
            await airportVM.loadNearestAirports()
            lastUpdated = Date()
        }
        .onChange(of: locationService.currentLocation) {
            Task {
                await airportVM.loadNearestAirports()
                lastUpdated = Date()
            }
        }
    }

    private var locationDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Location Access Required")
                .font(.headline)
            Text("MetarMate needs your location to find nearby airports.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
