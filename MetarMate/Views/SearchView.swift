import SwiftUI

struct SearchView: View {
    @EnvironmentObject var airportVM: AirportViewModel

    var body: some View {
        NavigationStack {
            List {
                if airportVM.searchText.isEmpty {
                    ContentUnavailableView(
                        "Search Airports",
                        systemImage: "magnifyingglass",
                        description: Text("Search by ICAO, IATA code, or airport name.")
                    )
                } else if airportVM.searchResults.isEmpty {
                    Text("No airports found for \"\(airportVM.searchText)\"")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(airportVM.searchResults) { airport in
                        NavigationLink(destination: WeatherDetailView(airport: airport)) {
                            AirportRowView(airport: airport, metar: nil, distance: nil)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $airportVM.searchText, prompt: "KLAS, LAX, Denver…")
        }
    }
}
