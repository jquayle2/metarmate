import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @Query private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var historyRows: [String: RowWeather] = [:]

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
                                                          distance: nil,
                                                          state: historyRows[entry.icao] ?? .loading,
                                                          onRetry: { Task { await loadHistoryMetars() } })
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
                                          distance: nil,
                                          state: airportVM.searchRows[airport.icao] ?? .loading,
                                          onRetry: { Task { await airportVM.retrySearchWeather() } })
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

    /// History rows read through the shared cache: fresh cached weather shows at once, only the
    /// misses are fetched (RowWeatherLoader), so returning to Search shows history weather instantly.
    /// (The live search itself is user-driven and fetches on demand.)
    private func loadHistoryMetars() async {
        let airports = airportVM.searchHistory
            .compactMap { AirportService.shared.airport(icao: $0.icao) }
        await RowWeatherLoader.load(list: "recents", airports: airports, current: historyRows, force: false) { rows in
            historyRows = rows
        }
    }
}
