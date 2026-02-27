import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var airportVM = AirportViewModel()
    @StateObject private var locationService = LocationService.shared

    var body: some View {
        TabView {
            NearestAirportsView()
                .tabItem {
                    Label("Nearest", systemImage: "location.circle.fill")
                }
                .environmentObject(airportVM)
                .environmentObject(locationService)

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .environmentObject(airportVM)

            FavoritesView()
                .tabItem {
                    Label("Favorites", systemImage: "star.fill")
                }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            locationService.requestPermission()
            locationService.startUpdating()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: AirportFavorite.self, inMemory: true)
}
