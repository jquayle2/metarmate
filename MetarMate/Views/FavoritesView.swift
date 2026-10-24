import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \AirportFavorite.addedDate, order: .forward) private var favorites: [AirportFavorite]
    @ObservedObject private var store = StoreManager.shared
    @EnvironmentObject private var weatherCache: WeatherCache
    @State private var showProSheet = false

    private var sortedFavorites: [AirportFavorite] {
        AirportFavorite.ordered(favorites)
    }
    @Environment(\.modelContext) private var modelContext
    @State private var favRows: [String: RowWeather] = [:]
    @State private var loadSeq = 0   // .task, onChange and pull can overlap; only the newest load publishes
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
                                AirportRowView(airport: airport, distance: nil,
                                               state: favRows[airport.icao] ?? .loading,
                                               onRetry: { Task { await fetchMetars() } })
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
                        // Own Task, as in NearestAirportsView, so no view update can cancel the pull.
                        await Task { await fetchMetars(force: true) }.value
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
            // Test Harness entry (Debug/TestFlight only): FIVE taps on this chip open the METAR
            // Injection screen. Moved OFF the nav-bar header — the top ~20 pt screen edge is where
            // iOS's system gesture gate wins ("System gesture gate timed out"), which starved the old
            // long-press so the app's recognizer never fired. A 5-tap target inside the content area,
            // clear of the top edge, competes with no system gesture. The receipt check on
            // TestHarnessGate.isAvailable is UNCHANGED and remains the actual App Store boundary — this
            // whole inset is absent in a production build, so it can't be reached or seen there.
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
        }
        .task {
            await fetchMetars()
        }
        .onChange(of: favorites.map { $0.icao }) {
            Task { await fetchMetars() }
        }
    }

    /// Rows from fresh cache; only the misses are fetched (RowWeatherLoader), with retries and the
    /// estimate only on a confirmed no METAR. `force` (pull-to-refresh) re-fetches every favorite.
    private func fetchMetars(force: Bool = false) async {
        guard !favorites.isEmpty else { return }
        loadSeq += 1
        let seq = loadSeq
        let airports = sortedFavorites.map { $0.asAirport }
        await RowWeatherLoader.load(list: "favorites", airports: airports, current: favRows, force: force) { rows in
            if seq == loadSeq { favRows = rows }
        }
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
