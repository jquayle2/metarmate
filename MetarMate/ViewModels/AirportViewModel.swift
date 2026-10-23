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
    @Published var nearestMetars: [String: Metar] = [:]
    @Published var searchMetars: [String: Metar] = [:]
    // Estimated conditions for genuinely station-less (advisory) airports.
    @Published var nearestAdvisories: [String: AdvisoryWeather] = [:]
    @Published var searchAdvisories: [String: AdvisoryWeather] = [:]

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
        // Official stations AND short/numeric LIDs that may publish under a K-ICAO (36K→K36K).
        let metarAirports = searchResults.filter { $0.hasMetar || WeatherService.noaaCandidate(for: $0.icao) != nil }
        guard !metarAirports.isEmpty else { return }

        // Build lookup: NOAA ICAO -> original airport ICAO (e.g. KCMA -> CMA)
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for airport in metarAirports {
            let code = airport.icao.uppercased()
            let id = WeatherService.noaaCandidate(for: code) ?? code
            noaaIds.append(id)
            noaaToOriginal[id] = code
        }

        let fetchedMetars: [String: Metar]?
        do { fetchedMetars = try await weatherService.fetchMetars(for: noaaIds) } catch {
            Log.load.error("[rows] search results METAR batch: \(FetchLog.classify(error), privacy: .public) — rows keep no METAR")
            fetchedMetars = nil
        }
        if let metars = fetchedMetars {
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
        let advisoryTargets = searchResults.filter { searchMetars[$0.icao] == nil && !$0.hasMetar }
        searchAdvisories = await fetchAdvisories(for: advisoryTargets)
        Self.logRows("search", airports: searchResults, metars: searchMetars, advisories: searchAdvisories)
    }

    /// Diagnostics: what each row will render now, so a "METAR unavailable" / "Advisory weather only"
    /// row can be matched to the fetch that left it empty. Mirrors AirportRowView's conditionsLine.
    static func logRows(_ list: String, airports: [Airport], metars: [String: Metar], advisories: [String: AdvisoryWeather]) {
        var unavailable: [String] = [], advisoryOnly: [String] = []
        for a in airports where metars[a.icao] == nil && advisories[a.icao] == nil {
            if a.hasMetar { unavailable.append(a.icao) } else { advisoryOnly.append(a.icao) }
        }
        let filled = airports.count - unavailable.count - advisoryOnly.count
        Log.load.info("[rows] \(list, privacy: .public): \(filled, privacy: .public)/\(airports.count, privacy: .public) with weather; 'METAR unavailable'=[\(unavailable.joined(separator: ","), privacy: .public)] 'Advisory weather only'=[\(advisoryOnly.joined(separator: ","), privacy: .public)] cancelled=\(Task.isCancelled, privacy: .public)")
    }

    /// Fetch Open-Meteo advisory conditions for station-less airports, in parallel.
    private func fetchAdvisories(for airports: [Airport]) async -> [String: AdvisoryWeather] {
        guard !airports.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, AdvisoryWeather?).self) { group in
            for a in airports {
                group.addTask { (a.icao, try? await OpenMeteoService.shared.fetchAdvisory(for: a)) }
            }
            var result: [String: AdvisoryWeather] = [:]
            for await (icao, adv) in group { if let adv { result[icao] = adv } }
            return result
        }
    }

    // MARK: - Nearest Airports
    /// Read-through the shared cache: seed the published dicts from fresh cached weather, fetch
    /// only the misses, then write results back. `force` (pull-to-refresh) skips the cache seed
    /// so every nearby airport is re-fetched and the cache overwritten. GPS/location logic and
    /// the LID-normalization untouched.
    func loadNearestAirports(force: Bool = false) async {
        guard let location = locationService.currentLocation else { return }
        isLoadingNearest = true
        nearestLoadSeq += 1; nearestLoadsInFlight += 1
        let seq = nearestLoadSeq
        defer { nearestLoadsInFlight -= 1 }
        Log.load.info("[rows] nearest load #\(seq, privacy: .public) START force=\(force, privacy: .public) overlapping=\(self.nearestLoadsInFlight - 1, privacy: .public)")

        nearestAirports = airportService.nearest(to: location, count: 15)

        // Seed from fresh cache first (instant on tab revisit).
        var metars: [String: Metar] = [:]
        var advisories: [String: AdvisoryWeather] = [:]
        if !force {
            for a in nearestAirports {
                if let m = WeatherCache.shared.freshMetar(for: a.icao) { metars[a.icao] = m }
                if let adv = WeatherCache.shared.freshAdvisory(for: a.icao) { advisories[a.icao] = adv }
            }
            nearestMetars = metars
            nearestAdvisories = advisories
        }
        // Rows are on screen from here, before any fetch returns.
        Self.logRows("nearest #\(seq) published before fetch", airports: nearestAirports, metars: metars, advisories: advisories)

        // Fetch METARs only for the misses among airports with official reporting stations.
        // K-prefix 3-letter FAA codes for NOAA lookup, then map results back.
        let metarNearby = nearestAirports.filter { $0.hasMetar || WeatherService.noaaCandidate(for: $0.icao) != nil }
        var nearNoaaToOrig: [String: String] = [:]
        var nearNoaaIds: [String] = []
        for airport in metarNearby {
            let code = airport.icao.uppercased()
            if metars[code] != nil { continue }   // fresh cached METAR — skip
            let id = WeatherService.noaaCandidate(for: code) ?? code
            nearNoaaIds.append(id)
            nearNoaaToOrig[id] = code
        }
        var nearFetched: [String: Metar]?
        if !nearNoaaIds.isEmpty {
            do { nearFetched = try await weatherService.fetchMetars(for: nearNoaaIds) } catch {
                Log.load.error("[rows] nearest #\(seq, privacy: .public) METAR batch: \(FetchLog.classify(error), privacy: .public) — \(nearNoaaIds.count, privacy: .public) rows keep no METAR")
            }
        }
        if let fetched = nearFetched {
            var mapped: [String: Metar] = [:]
            for (key, metar) in fetched {
                mapped[nearNoaaToOrig[key] ?? key] = metar
            }
            WeatherCache.shared.store(metars: mapped)
            for (k, m) in mapped { metars[k] = m }
        }
        nearestMetars = metars

        let advisoryTargets = nearestAirports.filter {
            metars[$0.icao] == nil && advisories[$0.icao] == nil && !$0.hasMetar
        }
        let fetchedAdv = await fetchAdvisories(for: advisoryTargets)
        if !fetchedAdv.isEmpty {
            WeatherCache.shared.store(advisories: fetchedAdv)
            for (k, v) in fetchedAdv { advisories[k] = v }
        }
        nearestAdvisories = advisories
        Self.logRows("nearest #\(seq) DONE", airports: nearestAirports, metars: metars, advisories: advisories)
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
