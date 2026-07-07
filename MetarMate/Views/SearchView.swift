import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @EnvironmentObject private var weatherCache: WeatherCache
    @Query private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var historyMetars: [String: Metar] = [:]
    @State private var historyAdvisories: [String: AdvisoryWeather] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if searchText.count < 2 {
                    if airportVM.searchHistory.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "airplane.departure")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("Search Airports")
                                .font(.headline)
                            Text("Enter an ICAO code, IATA code, or airport name")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            Section {
                                ForEach(airportVM.searchHistory) { entry in
                                    if let airport = AirportService.shared.airport(icao: entry.icao) {
                                        NavigationLink(destination: WeatherDetailView(airport: airport)
                                            .onAppear { airportVM.recordSearch(airport) }
                                        ) {
                                            AirportRowView(airport: airport,
                                                          metar: historyMetars[entry.icao],
                                                          distance: nil,
                                                          advisory: historyAdvisories[entry.icao])
                                        }
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            let isFav = favorites.contains(where: { $0.icao == airport.icao })
                                            Button {
                                                if isFav {
                                                    airportVM.removeFavorite(airport, favorites: favorites, context: modelContext)
                                                } else {
                                                    airportVM.addFavorite(airport, context: modelContext, existingFavorites: favorites)
                                                }
                                            } label: {
                                                Label(isFav ? "Unfavorite" : "Favorite",
                                                      systemImage: isFav ? "star.slash.fill" : "star.fill")
                                            }
                                            .tint(isFav ? .gray : .yellow)
                                        }
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                airportVM.removeHistoryEntry(entry)
                                            } label: {
                                                Label("Remove", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("Recent")
                                    Spacer()
                                    Button("Clear") {
                                        withAnimation { airportVM.clearSearchHistory() }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .task(id: airportVM.searchHistory.map(\.icao).joined()) {
                            await loadHistoryMetars()
                        }
                    }
                } else if airportVM.isResolvingStation {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Looking up station \(searchText.uppercased())…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if airportVM.searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(airportVM.searchResults) { airport in
                        NavigationLink(destination: WeatherDetailView(airport: airport)
                            .onAppear { airportVM.recordSearch(airport) }
                        ) {
                            AirportRowView(airport: airport,
                                          metar: airportVM.searchMetars[airport.icao],
                                          distance: nil,
                                          advisory: airportVM.searchAdvisories[airport.icao])
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(IsobarBackground())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ICAO, IATA, or airport name")
            .onChange(of: searchText) {
                airportVM.searchText = searchText
            }
        }
    }

    /// Read-through the shared cache for the history rows: seed from fresh cached weather, fetch
    /// only the misses, write results back — so returning to Search shows history weather
    /// instantly. (The live search itself is user-driven and fetches on demand, unchanged.)
    private func loadHistoryMetars() async {
        let airports = airportVM.searchHistory
            .compactMap { AirportService.shared.airport(icao: $0.icao) }

        // Seed from fresh cache first.
        var metars: [String: Metar] = [:]
        var advisories: [String: AdvisoryWeather] = [:]
        for a in airports {
            if let m = weatherCache.freshMetar(for: a.icao) { metars[a.icao] = m }
            if let adv = weatherCache.freshAdvisory(for: a.icao) { advisories[a.icao] = adv }
        }
        historyMetars = metars
        historyAdvisories = advisories

        // METARs for the misses among reporting stations + resolvable LIDs (36K→K36K).
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for a in airports where a.hasMetar || WeatherService.noaaCandidate(for: a.icao) != nil {
            if metars[a.icao] != nil { continue }   // fresh cached METAR — skip
            let id = WeatherService.noaaCandidate(for: a.icao) ?? a.icao
            noaaIds.append(id); noaaToOriginal[id] = a.icao
        }
        if !noaaIds.isEmpty, let fetched = try? await WeatherService.shared.fetchMetars(for: noaaIds) {
            var mapped: [String: Metar] = [:]
            for (k, m) in fetched { mapped[noaaToOriginal[k] ?? k] = m }
            weatherCache.store(metars: mapped)
            for (k, m) in mapped { metars[k] = m }
        }
        historyMetars = metars

        // Advisory estimates for the genuinely station-less recents still lacking weather.
        let advisoryTargets = airports.filter {
            metars[$0.icao] == nil && advisories[$0.icao] == nil && !$0.hasMetar
        }
        let fetchedAdvisories = await withTaskGroup(of: (String, AdvisoryWeather?).self) { group in
            for a in advisoryTargets {
                group.addTask { (a.icao, try? await OpenMeteoService.shared.fetchAdvisory(for: a)) }
            }
            var result: [String: AdvisoryWeather] = [:]
            for await (icao, adv) in group { if let adv { result[icao] = adv } }
            return result
        }
        if !fetchedAdvisories.isEmpty {
            weatherCache.store(advisories: fetchedAdvisories)
            for (k, v) in fetchedAdvisories { advisories[k] = v }
        }
        historyAdvisories = advisories
    }
}
