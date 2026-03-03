import SwiftUI
import Combine
import CoreLocation

struct NearbyAirportsView: View {
    let referenceAirport: Airport

    @StateObject private var vm = NearbyAirportsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.airports.isEmpty {
                    ProgressView("Finding nearby airports…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.airports.isEmpty {
                    ContentUnavailableView("No Airports Found",
                                          systemImage: "airplane",
                                          description: Text("No airports found near \(referenceAirport.icao)"))
                } else {
                    List {
                        ForEach(vm.airports) { airport in
                            NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                AirportRowView(
                                    airport: airport,
                                    metar: vm.metars[airport.icao],
                                    distance: vm.distanceFromUser(to: airport)
                                )
                            }
                            .listRowBackground(Color(.systemGray6).opacity(0.2))
                        }

                        if vm.canLoadMore {
                            Button {
                                vm.loadMore()
                            } label: {
                                HStack {
                                    Spacer()
                                    if vm.isLoadingMore {
                                        ProgressView()
                                    } else {
                                        Text("Load more airports")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(vm.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await vm.load(reference: referenceAirport)
        }
    }
}

// MARK: - ViewModel
@MainActor
class NearbyAirportsViewModel: ObservableObject {
    @Published var airports: [Airport] = []
    @Published var metars: [String: Metar] = [:]
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var canLoadMore = false
    @Published var navigationTitle = "Nearby Airports"

    private let pageSize = 10
    private var allNearby: [Airport] = []
    private var currentPage = 0
    private var referenceAirport: Airport?

    private let airportService = AirportService.shared
    private let weatherService = WeatherService.shared
    private let locationService = LocationService.shared

    func load(reference: Airport) async {
        referenceAirport = reference
        isLoading = true

        let refLocation = CLLocation(latitude: reference.latitude, longitude: reference.longitude)

        // Distance from user to the reference airport
        if let userLoc = locationService.currentLocation {
            let distToRef = reference.distance(from: userLoc)
            let nm = distToRef / 1852.0
            navigationTitle = "Near \(reference.icao) (\(formatNm(nm)))"
        } else {
            navigationTitle = "Near \(reference.icao)"
        }

        // Get 50 nearest — we'll page through them
        allNearby = airportService.nearest(to: refLocation, count: 50)
            .filter { $0.icao != reference.icao }  // exclude the reference airport itself

        currentPage = 0
        airports = []
        await loadNextPage()
        isLoading = false
    }

    func loadMore() {
        guard !isLoadingMore else { return }
        Task {
            isLoadingMore = true
            await loadNextPage()
            isLoadingMore = false
        }
    }

    private func loadNextPage() async {
        let start = currentPage * pageSize
        let end = min(start + pageSize, allNearby.count)
        guard start < end else {
            canLoadMore = false
            return
        }

        let newAirports = Array(allNearby[start..<end])
        airports.append(contentsOf: newAirports)
        currentPage += 1
        canLoadMore = end < allNearby.count

        // Fetch METARs for METAR airports in this page
        let icaos = newAirports.filter { $0.hasMetar }.map { $0.icao }
        if !icaos.isEmpty, let fetched = try? await weatherService.fetchMetars(for: icaos) {
            metars.merge(fetched) { _, new in new }
        }
    }

    func distanceFromUser(to airport: Airport) -> String? {
        guard let userLoc = locationService.currentLocation else { return nil }
        let dist = airport.distance(from: userLoc)
        return dist.distanceNmString
    }

    private func formatNm(_ nm: Double) -> String {
        nm >= 10 ? "\(Int(nm.rounded())) nm" : String(format: "%.1f nm", nm)
    }
}
