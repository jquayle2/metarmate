import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \AirportFavorite.addedDate, order: .reverse) private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext
    @State private var favMetars: [String: Metar] = [:]
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Favorites Yet")
                            .font(.headline)
                        Text("Star an airport to add it here")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(favorites) { fav in
                            let airport = fav.asAirport
                            NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                AirportRowView(
                                    airport: airport,
                                    metar: favMetars[airport.icao],
                                    distance: nil
                                )
                            }
                            .listRowBackground(Color(.systemGray6).opacity(0.2))
                        }
                        .onDelete(perform: deleteFavorites)
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await fetchMetars()
                    }
                    .overlay {
                        if isLoading && favMetars.isEmpty {
                            ProgressView()
                        }
                    }
                }
            }
            .navigationTitle("Favorites")
        }
        .task {
            await fetchMetars()
        }
        .onChange(of: favorites.map { $0.icao }) {
            Task { await fetchMetars() }
        }
    }

    private func fetchMetars() async {
        guard !favorites.isEmpty else { return }
        isLoading = true
        let icaos = favorites.filter { $0.hasMetar }.map { $0.icao }
        guard !icaos.isEmpty else { isLoading = false; return }
        if let metars = try? await WeatherService.shared.fetchMetars(for: icaos) {
            favMetars = metars
        }
        isLoading = false
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(favorites[index])
        }
    }
}
