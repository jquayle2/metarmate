import SwiftUI
import CoreLocation

struct NearestAirportsView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @EnvironmentObject private var locationService: LocationService
    @State private var lastUpdated: Date? = nil

    // MARK: Title block (badge 3A)
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackedLabel(text: "Around You", color: Brand.accentOrange, size: 10, tracking: 3.0)
                .padding(.bottom, 8)
            Text("Nearest Airports")
                .font(.avenir(34, .heavy))
                .foregroundColor(Brand.cloud)
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Brand.slate)
                Group {
                    if let updated = lastUpdated {
                        Text("Sorted by distance · updated \(updated, style: .relative) ago")
                    } else {
                        Text("Sorted by distance")
                    }
                }
                .font(.avenir(12.5, .demibold))
                .foregroundColor(Brand.slate)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 14)
    }

    var body: some View {
        NavigationStack {
            Group {
                if locationService.authorizationStatus == .denied ||
                   locationService.authorizationStatus == .restricted {
                    stateColumn { locationDeniedView }
                } else if airportVM.isLoadingNearest && airportVM.nearestAirports.isEmpty {
                    stateColumn {
                        ProgressView("Finding nearest airports…")
                            .tint(Brand.accentOrange)
                            .foregroundColor(Brand.slate)
                            .padding(.top, 80)
                    }
                } else if airportVM.nearestAirports.isEmpty {
                    stateColumn {
                        ContentUnavailableView(
                            "No Airports Found",
                            systemImage: "airplane.circle",
                            description: Text("No airports within 100 nm")
                        )
                        .padding(.top, 60)
                    }
                } else {
                    airportList
                }
            }
            .brandGround()
            .toolbar(.hidden, for: .navigationBar)
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

    private var airportList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                titleBlock
                ForEach(Array(airportVM.nearestAirports.enumerated()), id: \.element.id) { idx, airport in
                    NavigationLink {
                        WeatherDetailView(airport: airport)
                    } label: {
                        AirportRowView(
                            airport: airport,
                            metar: airportVM.nearestMetars[airport.icao],
                            distance: airportVM.distance(to: airport),
                            advisory: airportVM.nearestAdvisories[airport.icao]
                        )
                    }
                    .buttonStyle(.plain)
                    if idx < airportVM.nearestAirports.count - 1 {
                        Rectangle()
                            .fill(Brand.rowDivider)
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await airportVM.loadNearestAirports(force: true)
            lastUpdated = Date()
        }
    }

    /// Title block + arbitrary state content, on the brand ground.
    private func stateColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                titleBlock
                content()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var locationDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(Brand.slate)
            Text("Location Access Required")
                .font(.avenir(18, .bold))
                .foregroundColor(Brand.cloud)
            Text("MetarMate needs your location to find nearby airports.")
                .font(.subheadline)
                .foregroundColor(Brand.slate)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accentOrange)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
