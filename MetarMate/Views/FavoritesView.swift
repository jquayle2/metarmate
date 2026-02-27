import SwiftUI
import SwiftData

struct FavoritesView: View {
    @EnvironmentObject var airportVM: AirportViewModel
    @Query(sort: \AirportFavorite.addedDate, order: .reverse) var favorites: [AirportFavorite]
    @Environment(\.modelContext) var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableView(
                        "No Favorites",
                        systemImage: "star",
                        description: Text("Add airports from Search or Nearest to see them here.")
                    )
                } else {
                    List {
                        ForEach(favorites) { fav in
                            NavigationLink(destination: WeatherDetailView(airport: fav.asAirport)) {
                                AirportRowView(airport: fav.asAirport, metar: nil, distance: nil)
                            }
                        }
                        .onDelete(perform: deleteFavorites)
                    }
                }
            }
            .navigationTitle("Favorites")
            .toolbar {
                EditButton()
            }
        }
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(favorites[index])
        }
    }
}
