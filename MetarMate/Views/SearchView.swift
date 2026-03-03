import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var airportVM: AirportViewModel
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if searchText.count < 2 {
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
                        NavigationLink(destination: WeatherDetailView(airport: airport)) {
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
}
