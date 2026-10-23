import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \AirportFavorite.addedDate, order: .forward) private var favorites: [AirportFavorite]
    @EnvironmentObject private var weatherCache: WeatherCache

    private var sortedFavorites: [AirportFavorite] {
        AirportFavorite.ordered(favorites)
    }
    @Environment(\.modelContext) private var modelContext
    @State private var favMetars: [String: Metar] = [:]
    @State private var favAdvisories: [String: AdvisoryWeather] = [:]
    @State private var isLoading = false
    @State private var editMode: EditMode = .inactive
    #if DEBUG || TESTFLIGHT
    @State private var showInjectionHarness = false   // Test Harness (Debug/TestFlight only)
    #endif

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
            #if DEBUG || TESTFLIGHT
            // Test Harness entry (Debug/TestFlight only): FIVE taps on this chip open the METAR
            // Injection screen. Moved OFF the nav-bar header — the top ~20 pt screen edge is where
            // iOS's system gesture gate wins ("System gesture gate timed out"), which starved the old
            // long-press so the app's recognizer never fired. A 5-tap target inside the content area,
            // clear of the top edge, competes with no system gesture. This whole inset is compiled only
            // into Debug and TestFlight builds (audit #21); TestHarnessGate.isAvailable is a second,
            // runtime layer inside those builds.
            .safeAreaInset(edge: .bottom) {
                if TestHarnessGate.isAvailable {
                    HStack(spacing: 6) {
                        Image(systemName: "ladybug.fill")
                        Text("METAR Injection — tap 5×")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .contentShape(Capsule())
                    .onTapGesture(count: 5) { showInjectionHarness = true }
                    .padding(.bottom, 4)
                    .accessibilityElement(children: .combine)   // one queryable element for the UITest
                    .accessibilityIdentifier("harnessEntryChip")
                }
            }
            .fullScreenCover(isPresented: $showInjectionHarness) {
                MetarInjectionHarnessView()
            }
            #endif
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
}
