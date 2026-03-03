import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if searchText.count < 2 {
                    if airportVM.searchHistory.isEmpty {
                        // Empty state — no history yet
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
                        // Recent searches list
                        List {
                            Section {
                                ForEach(airportVM.searchHistory) { entry in
                                    NavigationLink(destination: historyDestination(entry)) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .foregroundColor(.secondary)
                                                .font(.subheadline)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.icao)
                                                    .font(.subheadline.bold())
                                                Text(entry.name)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .listRowBackground(Color(.systemGray6).opacity(0.2))
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            airportVM.removeHistoryEntry(entry)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
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

    // Look up the airport from the local database to navigate to it from history
    @ViewBuilder
    private func historyDestination(_ entry: AirportViewModel.SearchHistoryEntry) -> some View {
        if let airport = AirportService.shared.airport(icao: entry.icao) {
            WeatherDetailView(airport: airport)
                .onAppear { airportVM.recordSearch(airport) }
        } else {
            // Fallback — should rarely happen
            ContentUnavailableView("Airport Not Found",
                systemImage: "airplane.departure",
                description: Text("\(entry.icao) is no longer in the local database."))
        }
    }
}
