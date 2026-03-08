import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var airportVM = AirportViewModel()
    @StateObject private var locationService = LocationService.shared
    @State private var selectedTab: Int

    init() {
        _selectedTab = State(initialValue: LayoutPreferences.shared.startingTab.tabIndex)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NearestAirportsView()
                .tabItem {
                    Label("Nearest", systemImage: "location.circle.fill")
                }
                .tag(0)
                .environmentObject(airportVM)
                .environmentObject(locationService)

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(1)
                .environmentObject(airportVM)

            FavoritesView()
                .tabItem {
                    Label("Favorites", systemImage: "star.fill")
                }
                .tag(2)
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
