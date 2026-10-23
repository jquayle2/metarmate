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
    // One Nearest load at a time: a new one (.task, a 2 nm move, pull-to-refresh) cancels the one
    // running, and only the newest load writes rows. Two overlapping loads used to fire 13 estimate
    // requests each and the slower one overwrote the other's rows.
    private var nearestTask: Task<Void, Never>?
    private var nearestLoadSeq = 0
    private var nearestLoadedAt: CLLocation?   // where the current rows were loaded for
    static let nearestReloadDistanceMeters: CLLocationDistance = 2 * 1852   // 2 nm

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

    /// The failed rows' retry button: fetch the search results' weather again (fresh rows are skipped).
    func retrySearchWeather() async {
        await fetchSearchMetars()
    }

    private func fetchSearchMetars() async {
        await RowWeatherLoader.load(list: "search", airports: searchResults, current: searchRows, force: false) { [weak self] rows in
            self?.searchRows = rows
        }
    }

    // MARK: - Nearest Airports
    /// Rows show fresh cached weather at once, else what they showed, else loading; then the misses
    /// are fetched (RowWeatherLoader). `force` (pull-to-refresh) fetches every row. Cancels a load
    /// already running; cancelling the caller (the view's .task) cancels this load.
    func loadNearestAirports(force: Bool = false) async {
        nearestTask?.cancel()
        let task = Task { await self.runNearestLoad(force: force) }
        nearestTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Whether a location update should reload Nearest: only after a move of 2 nm or more from where
    /// the rows were loaded (GPS refinements arrive far more often, each used to start a full load).
    func shouldReloadNearest(for location: CLLocation?) -> Bool {
        Self.movedEnoughToReload(from: nearestLoadedAt, to: location)
    }

    nonisolated static func movedEnoughToReload(from loadedAt: CLLocation?, to location: CLLocation?) -> Bool {
        guard let location else { return false }
        guard let loadedAt else { return true }
        return location.distance(from: loadedAt) >= nearestReloadDistanceMeters
    }

    private func runNearestLoad(force: Bool) async {
        guard let location = locationService.currentLocation else { return }
        nearestLoadSeq += 1
        let seq = nearestLoadSeq
        isLoadingNearest = true
        nearestLoadedAt = location
        Log.load.info("[rows] nearest load #\(seq, privacy: .public) START force=\(force, privacy: .public)")

        nearestAirports = airportService.nearest(to: location, count: 15)
        await RowWeatherLoader.load(list: "nearest #\(seq)", airports: nearestAirports, current: nearestRows, force: force) { [weak self] rows in
            // Only the newest load writes, and it merges: rows it hasn't reached keep their value.
            guard let self, seq == self.nearestLoadSeq else { return }
            self.nearestRows.merge(rows) { _, new in new }
        }
        if seq == nearestLoadSeq { isLoadingNearest = false }
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
