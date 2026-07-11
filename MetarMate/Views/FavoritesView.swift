import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \AirportFavorite.addedDate, order: .forward) private var favorites: [AirportFavorite]
    @ObservedObject private var store = StoreManager.shared
    @EnvironmentObject private var weatherCache: WeatherCache
    @State private var showProSheet = false

    private var sortedFavorites: [AirportFavorite] {
        let byDate = favorites.sorted { $0.addedDate < $1.addedDate }
        let dateIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: byDate.enumerated().map { ($1.icao, $0) }
        )
        return byDate.sorted {
            let a = $0.sortOrder ?? dateIndex[$0.icao] ?? 0
            let b = $1.sortOrder ?? dateIndex[$1.icao] ?? 0
            if a == b { return $0.addedDate < $1.addedDate }
            return a < b
        }
    }
    @Environment(\.modelContext) private var modelContext
    @State private var favMetars: [String: Metar] = [:]
    @State private var favAdvisories: [String: AdvisoryWeather] = [:]
    @State private var isLoading = false
    @State private var editMode: EditMode = .inactive
    @State private var showInjectionHarness = false   // Test Harness (Debug/TestFlight only)

    var body: some View {
        NavigationStack {
            Group {
                if FeatureFlags.favoritesRequirePro && !store.isProUser {
                    proRequiredView
                } else if favorites.isEmpty {
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
                        ForEach(sortedFavorites) { fav in
                            let airport = fav.asAirport
                            NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                AirportRowView(
                                    airport: airport,
                                    metar: favMetars[airport.icao],
                                    distance: nil,
                                    advisory: favAdvisories[airport.icao]
                                )
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                        }
                        .onDelete(perform: deleteFavorites)
                        .onMove(perform: moveFavorites)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                    .refreshable {
                        await fetchMetars(force: true)
                    }
                    .overlay {
                        if isLoading && favMetars.isEmpty {
                            ProgressView()
                        }
                    }
                }
            }
            .background(IsobarBackground())
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Test Harness entry (Debug/TestFlight only): a 5-second long-press on the header
                // opens the METAR Injection screen. The gesture is convenience; the receipt check on
                // TestHarnessGate.isAvailable is the actual boundary — this ToolbarItem is absent
                // entirely in an App Store production build, so the header renders the plain title.
                if TestHarnessGate.isAvailable {
                    ToolbarItem(placement: .principal) {
                        Text("Favorites")
                            .font(.headline)
                            .foregroundColor(Brand.cloud)
                            .contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 5) { showInjectionHarness = true }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !favorites.isEmpty {
                        Button(editMode == .active ? "Done" : "Edit") {
                            withAnimation {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showInjectionHarness) {
                MetarInjectionHarnessView()
            }
        }
        .task {
            await fetchMetars()
        }
        .onChange(of: favorites.map { $0.icao }) {
            Task { await fetchMetars() }
        }
    }

    /// Read-through the shared cache: seed the render dicts from fresh cached weather, fetch only
    /// the misses, then write the fetched results back. `force` (pull-to-refresh) skips the cache
    /// seed so every favorite is re-fetched and the cache overwritten.
    private func fetchMetars(force: Bool = false) async {
        guard !favorites.isEmpty else { return }
        isLoading = true

        // 1. Seed render dicts from fresh cache (makes a tab revisit instant, no fetch).
        var metars: [String: Metar] = [:]
        var advisories: [String: AdvisoryWeather] = [:]
        if !force {
            for fav in favorites {
                if let m = weatherCache.freshMetar(for: fav.icao) { metars[fav.icao] = m }
                if let a = weatherCache.freshAdvisory(for: fav.icao) { advisories[fav.icao] = a }
            }
            favMetars = metars
            favAdvisories = advisories
        }

        // 2. METARs for the misses among reporting stations + resolvable LIDs (36K→K36K),
        //    mapped back to the id. On force, `metars` is empty so all are fetched.
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for fav in favorites where fav.hasMetar || WeatherService.noaaCandidate(for: fav.icao) != nil {
            if metars[fav.icao] != nil { continue }   // fresh cached METAR — skip
            let id = WeatherService.noaaCandidate(for: fav.icao) ?? fav.icao
            noaaIds.append(id); noaaToOriginal[id] = fav.icao
        }
        if !noaaIds.isEmpty, let fetched = try? await WeatherService.shared.fetchMetars(for: noaaIds) {
            var mapped: [String: Metar] = [:]
            for (k, m) in fetched { mapped[noaaToOriginal[k] ?? k] = m }
            weatherCache.store(metars: mapped)
            for (k, m) in mapped { metars[k] = m }
        }
        favMetars = metars

        // 3. Advisory estimates for genuinely station-less favorites still lacking any weather.
        let advisoryTargets = favorites
            .filter { metars[$0.icao] == nil && advisories[$0.icao] == nil && !$0.hasMetar }
            .map { $0.asAirport }
        let fetchedAdvisories = await withTaskGroup(of: (String, AdvisoryWeather?).self) { group in
            for a in advisoryTargets {
                group.addTask { (a.icao, try? await OpenMeteoService.shared.fetchAdvisory(for: a)) }
            }
            var result: [String: AdvisoryWeather] = [:]
            for await (icao, adv) in group { if let adv { result[icao] = adv } }
            return result
        }
        if !fetchedAdvisories.isEmpty {
            weatherCache.store(advisories: fetchedAdvisories)
            for (k, v) in fetchedAdvisories { advisories[k] = v }
        }
        favAdvisories = advisories
        isLoading = false
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sortedFavorites[index])
        }
    }

    private func moveFavorites(from source: IndexSet, to destination: Int) {
        var reordered = sortedFavorites
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, fav) in reordered.enumerated() {
            fav.sortOrder = index
        }
    }

    private var proRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.circle")
                .font(.system(size: 56))
                .foregroundColor(.yellow.opacity(0.7))
            Text("Favorites requires Pro")
                .font(.title3.bold())
            Text("Save unlimited airports for instant access with MetarMate Pro.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showProSheet = true
            } label: {
                Text("Upgrade to Pro — $8.99")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.cyan)
                    .cornerRadius(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showProSheet) {
            ProUpgradeView(mode: .pro)
        }
    }
}
