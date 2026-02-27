import Foundation
import SwiftUI
import SwiftData
import CoreLocation

// MARK: - Airport View Model
@MainActor
class AirportViewModel: ObservableObject {
    @Published var nearestAirports: [Airport] = []
    @Published var searchResults: [Airport] = []
    @Published var searchText: String = "" {
        didSet { performSearch() }
    }
    @Published var isLoadingNearest = false
    @Published var nearestMetars: [String: Metar] = [:]

    private let airportService = AirportService.shared
    private let weatherService = WeatherService.shared
    private let locationService = LocationService.shared

    // MARK: - Search
    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        searchResults = airportService.search(query: searchText)
    }

    // MARK: - Nearest Airports
    func loadNearestAirports() async {
        guard let location = locationService.currentLocation else { return }
        isLoadingNearest = true

        nearestAirports = airportService.nearest(to: location, count: 15)

        // Fetch METARs for nearest airports
        let icaos = nearestAirports.map { $0.icao }
        if let metars = try? await weatherService.fetchMetars(for: icaos) {
            nearestMetars = metars
        }
        isLoadingNearest = false
    }

    func distance(to airport: Airport) -> String? {
        guard let location = locationService.currentLocation else { return nil }
        let dist = airport.distance(from: location)
        return dist.nmString
    }

    // MARK: - Favorites helpers (work with @Query in views)
    func isFavorite(_ airport: Airport, favorites: [AirportFavorite]) -> Bool {
        favorites.contains(where: { $0.icao == airport.icao })
    }

    func addFavorite(_ airport: Airport, context: ModelContext) {
        let fav = AirportFavorite(from: airport)
        context.insert(fav)
    }

    func removeFavorite(_ airport: Airport, favorites: [AirportFavorite], context: ModelContext) {
        if let fav = favorites.first(where: { $0.icao == airport.icao }) {
            context.delete(fav)
        }
    }
}
