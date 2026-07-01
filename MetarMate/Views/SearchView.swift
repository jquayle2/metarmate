import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
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
            .searchable(text: $searchText, prompt: "ICAO, IATA, or airport name")
            .onChange(of: searchText) {
                airportVM.searchText = searchText
            }
        }
    }

    private func loadHistoryMetars() async {
        let airports = airportVM.searchHistory
            .compactMap { AirportService.shared.airport(icao: $0.icao) }

        // METARs for reporting stations + resolvable LIDs (36K→K36K), mapped back to the id.
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for a in airports where a.hasMetar || WeatherService.noaaCandidate(for: a.icao) != nil {
            let id = WeatherService.noaaCandidate(for: a.icao) ?? a.icao
            noaaIds.append(id); noaaToOriginal[id] = a.icao
        }
        if !noaaIds.isEmpty, let metars = try? await WeatherService.shared.fetchMetars(for: noaaIds) {
            var mapped: [String: Metar] = [:]
            for (k, m) in metars { mapped[noaaToOriginal[k] ?? k] = m }
            historyMetars = mapped
        }

        // Advisory estimates for the genuinely station-less recents.
        let advisoryTargets = airports.filter { historyMetars[$0.icao] == nil && !$0.hasMetar }
        historyAdvisories = await withTaskGroup(of: (String, AdvisoryWeather?).self) { group in
            for a in advisoryTargets {
                group.addTask { (a.icao, try? await OpenMeteoService.shared.fetchAdvisory(for: a)) }
            }
            var result: [String: AdvisoryWeather] = [:]
            for await (icao, adv) in group { if let adv { result[icao] = adv } }
            return result
        }
    }
}
