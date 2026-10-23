import Foundation
import Combine
import SwiftUI
import SwiftData
import CoreLocation
import os

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
    // Row weather (METAR, advisory estimate, or loading / no product / retrying / failed), keyed by airport id.
    @Published var nearestRows: [String: RowWeather] = [:]
    @Published var searchRows: [String: RowWeather] = [:]

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
    // Diagnostics: loadNearestAirports runs from .task, every location change and pull-to-refresh,
    // and nothing stops two from overlapping. Counted so the logs show when they do.
    private var nearestLoadSeq = 0
    private var nearestLoadsInFlight = 0

    private let airportService = AirportService.shared
    private let locationService = LocationService.shared

    // MARK: - Search
    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            searchRows = [:]
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
        await RowWeatherLoader.load(list: "search", airports: searchResults, current: searchRows, force: false) { [weak self] rows in
            self?.searchRows = rows
        }
    }

    // MARK: - Nearest Airports
    /// Rows show fresh cached weather at once, else what they showed, else loading; then the misses
    /// are fetched (RowWeatherLoader). `force` (pull-to-refresh) fetches every row.
    func loadNearestAirports(force: Bool = false) async {
        guard let location = locationService.currentLocation else { return }
        isLoadingNearest = true
        nearestLoadSeq += 1; nearestLoadsInFlight += 1
        let seq = nearestLoadSeq
        defer { nearestLoadsInFlight -= 1 }
        Log.load.info("[rows] nearest load #\(seq, privacy: .public) START force=\(force, privacy: .public) overlapping=\(self.nearestLoadsInFlight - 1, privacy: .public)")

        nearestAirports = airportService.nearest(to: location, count: 15)
        await RowWeatherLoader.load(list: "nearest #\(seq)", airports: nearestAirports, current: nearestRows, force: force) { [weak self] rows in
            self?.nearestRows = rows
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
