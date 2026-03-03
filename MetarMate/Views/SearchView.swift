import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @Query private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var historyMetars: [String: Metar] = [:]

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
                                                          distance: nil)
                                        }
                                        .listRowBackground(Color(.systemGray6).opacity(0.2))
                                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            let isFav = favorites.contains(where: { $0.icao == airport.icao })
                                            Button {
                                                if isFav {
                                                    airportVM.removeFavorite(airport, favorites: favorites, context: modelContext)
                                                } else {
                                                    airportVM.addFavorite(airport, context: modelContext)
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
                                          distance: nil)
                        }
                        .listRowBackground(Color(.systemGray6).opacity(0.2))
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: "ICAO, IATA, or airport name")
            .onChange(of: searchText) {
                airportVM.searchText = searchText
            }
        }
    }

    private func loadHistoryMetars() async {
        let icaos = airportVM.searchHistory
            .compactMap { AirportService.shared.airport(icao: $0.icao) }
            .filter { $0.hasMetar }
            .map { $0.icao }
        guard !icaos.isEmpty else { return }
        if let metars = try? await WeatherService.shared.fetchMetars(for: icaos) {
            historyMetars = metars
        }
    }
}
