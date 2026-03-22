import Foundation
import Combine
import SwiftUI
import SwiftData
import CoreLocation

// MARK: - Airport View Model
@MainActor
class AirportViewModel: ObservableObject {
    @Published var nearestAirports: [Airport] = []
    @Published var searchResults: [Airport] = []
    @Published var isResolvingStation = false
    @Published var searchText: String = "" {
        didSet { performSearch() }
    }
    @Published var isLoadingNearest = false
    @Published var nearestMetars: [String: Metar] = [:]
    @Published var searchMetars: [String: Metar] = [:]

    // MARK: - Search History
    private static let historyKey = "searchHistory"
    private static let maxHistory = 10

    struct SearchHistoryEntry: Codable, Identifiable, Equatable {
        var id: String { icao }
        let icao: String
        let name: String
    }

    @Published var searchHistory: [SearchHistoryEntry] = {
        guard let data = UserDefaults.standard.data(forKey: AirportViewModel.historyKey),
              let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }()

    func recordSearch(_ airport: Airport) {
        let entry = SearchHistoryEntry(icao: airport.icao, name: airport.name)
        var history = searchHistory.filter { $0.icao != airport.icao }
        history.insert(entry, at: 0)
        if history.count > Self.maxHistory { history = Array(history.prefix(Self.maxHistory)) }
        searchHistory = history
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    func clearSearchHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    func removeHistoryEntry(_ entry: SearchHistoryEntry) {
        searchHistory.removeAll { $0.icao == entry.icao }
        if let data = try? JSONEncoder().encode(searchHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private var searchMetarTask: Task<Void, Never>? = nil

    private let airportService = AirportService.shared
    private let weatherService = WeatherService.shared
    private let locationService = LocationService.shared

    // MARK: - Search
    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            searchMetars = [:]
            return
        }
        let local = airportService.search(query: searchText)
        searchResults = local

        // For short queries that look like station IDs with no local match,
        // attempt a live NOAA lookup (handles T78, 5T6, and other FAA identifiers)
        let q = searchText.uppercased()
        let looksLikeStationId = (2...5).contains(q.count) && q.allSatisfy { $0.isLetter || $0.isNumber }
        if local.isEmpty && looksLikeStationId {
            isResolvingStation = true
            Task {
                if let resolved = await airportService.resolveUnknownStation(q) {
                    searchResults = [resolved]
                }
                isResolvingStation = false
                await fetchSearchMetars()
            }
        } else {
            isResolvingStation = false
            // Debounce METAR fetch — wait 0.5s for typing to settle
            searchMetarTask?.cancel()
            searchMetarTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await fetchSearchMetars()
            }
        }
    }

    private func fetchSearchMetars() async {
        let metarAirports = searchResults.filter { $0.hasMetar }
        guard !metarAirports.isEmpty else { return }

        // Build lookup: NOAA ICAO -> original airport ICAO (e.g. KCMA -> CMA)
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for airport in metarAirports {
            let code = airport.icao.uppercased()
            if code.count == 3, code.allSatisfy({ $0.isLetter }), !code.hasPrefix("K") {
                let kCode = "K\(code)"
                noaaIds.append(kCode)
                noaaToOriginal[kCode] = code
            } else {
                noaaIds.append(code)
                noaaToOriginal[code] = code
            }
        }

        if let metars = try? await weatherService.fetchMetars(for: noaaIds) {
            // Map results back to original airport ICAO codes
            var mapped: [String: Metar] = [:]
            for (key, metar) in metars {
                if let original = noaaToOriginal[key] {
                    mapped[original] = metar
                } else {
                    mapped[key] = metar
                }
            }
            searchMetars = mapped
        }
    }

    // MARK: - Nearest Airports
    func loadNearestAirports() async {
        guard let location = locationService.currentLocation else { return }
        isLoadingNearest = true

        nearestAirports = airportService.nearest(to: location, count: 15)

        // Fetch METARs only for airports with official reporting stations
        // K-prefix 3-letter FAA codes for NOAA lookup, then map results back
        let metarNearby = nearestAirports.filter { $0.hasMetar }
        var nearNoaaToOrig: [String: String] = [:]
        var nearNoaaIds: [String] = []
        for airport in metarNearby {
            let code = airport.icao.uppercased()
            if code.count == 3, code.allSatisfy({ $0.isLetter }), !code.hasPrefix("K") {
                let kCode = "K\(code)"
                nearNoaaIds.append(kCode)
                nearNoaaToOrig[kCode] = code
            } else {
                nearNoaaIds.append(code)
                nearNoaaToOrig[code] = code
            }
        }
        if let metars = try? await weatherService.fetchMetars(for: nearNoaaIds) {
            var mapped: [String: Metar] = [:]
            for (key, metar) in metars {
                mapped[nearNoaaToOrig[key] ?? key] = metar
            }
            nearestMetars = mapped
        }
        isLoadingNearest = false
    }

    func distance(to airport: Airport) -> String? {
        guard let location = locationService.currentLocation else { return nil }
        let dist = airport.distance(from: location)
        return dist.distanceNmString
    }

    // MARK: - Favorites helpers (work with @Query in views)
    func isFavorite(_ airport: Airport, favorites: [AirportFavorite]) -> Bool {
        favorites.contains(where: { $0.icao == airport.icao })
    }

    func addFavorite(_ airport: Airport, context: ModelContext, existingFavorites: [AirportFavorite] = []) {
        let nextOrder = (existingFavorites.compactMap(\.sortOrder).max() ?? -1) + 1
        let fav = AirportFavorite(from: airport, sortOrder: nextOrder)
        context.insert(fav)
    }

    func removeFavorite(_ airport: Airport, favorites: [AirportFavorite], context: ModelContext) {
        if let fav = favorites.first(where: { $0.icao == airport.icao }) {
            context.delete(fav)
        }
    }
}
