import SwiftUI
import Combine
import CoreLocation
import os

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

        // Diagnostics only: log the resolved origin airport/coordinate + source.
        let originSource = locationService.currentLocation != nil ? "GPS" : "fallback"
        Log.load.info("[nearbySheet] origin \(reference.icao, privacy: .public) lat=\(reference.latitude, privacy: .public) lon=\(reference.longitude, privacy: .public) source=\(originSource, privacy: .public)")

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

        // Diagnostics only: log the display row list state after this page is appended.
        if let ref = referenceAirport, let nearest = airports.first {
            let originLoc = CLLocation(latitude: ref.latitude, longitude: ref.longitude)
            let nearestNm = nearest.distance(from: originLoc) / 1852.0
            Log.load.info("[nearbySheet] rows=\(self.airports.count, privacy: .public) origin=\(ref.icao, privacy: .public) nearest=\(nearest.icao, privacy: .public) \(String(format: "%.1f", nearestNm), privacy: .public) nm")
        }

        currentPage += 1
        canLoadMore = end < allNearby.count

        // Fetch METARs for METAR airports in this page
        let icaos = newAirports.filter { $0.hasMetar }.map { $0.icao }
        guard !icaos.isEmpty else {
            Log.load.info("[nearbySheet] page \(self.currentPage, privacy: .public): no hasMetar airports to fetch")
            return
        }
        let fetchStart = DispatchTime.now()
        do {
            let fetched = try await weatherService.fetchMetars(for: icaos)
            metars.merge(fetched) { _, new in new }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - fetchStart.uptimeNanoseconds) / 1_000_000
            Log.load.info("[nearbySheet] page \(self.currentPage, privacy: .public): \(fetched.count, privacy: .public)/\(icaos.count, privacy: .public) METARs in \(String(format: "%.0f", ms), privacy: .public) ms")
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - fetchStart.uptimeNanoseconds) / 1_000_000
            Log.load.error("[nearbySheet] page \(self.currentPage, privacy: .public): batch METAR FAILED after \(String(format: "%.0f", ms), privacy: .public) ms — \(icaos.count, privacy: .public) rows will show 'METAR unavailable' — \(String(describing: error), privacy: .public)")
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
