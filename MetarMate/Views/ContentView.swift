import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var airportVM = AirportViewModel()
    @StateObject private var locationService = LocationService.shared
    @StateObject private var weatherCache = WeatherCache.shared
    @State private var selectedTab: Int

    init() {
        _selectedTab = State(initialValue: LayoutPreferences.shared.startingTab.tabIndex)
        ContentView.applyBrandAppearance()
    }

    /// Brand chrome (visual refresh): navy nav bars, dark translucent tab bar with the
    /// single orange accent on the active item. Configured once via appearance proxies.
    static func applyBrandAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(Brand.bezel).withAlphaComponent(0.82)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = UIColor(Brand.accentOrange)
            item.selected.titleTextAttributes = [.foregroundColor: UIColor(Brand.accentOrange)]
            item.normal.iconColor = UIColor(Brand.slate)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(Brand.slate)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Brand.navy)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(Brand.cloud)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Brand.cloud)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
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

            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "bell.fill")
                }
                .tag(3)

            CrosswindTabView()
                .tabItem {
                    Label("XWind", systemImage: "wind")
                }
                .tag(4)
        }
        .environmentObject(weatherCache)
        .tint(Brand.accentOrange)
        // Guardrail against total layout breakage at the largest accessibility sizes. The
        // goal is that the normal range through .accessibility1 reflows cleanly — this cap is
        // a floor, not a substitute for that. FUTURE: support sizes beyond .accessibility1.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
